#!/usr/bin/env python3
"""Summarize or compare completed phrase reports without changing Swift's scoring.

Usage: python3 scripts/analyze_phrase_experiments.py BEFORE [AFTER] [--metric nextWord|all] [--markdown]

This offline boundary owns experiment statistics, not model execution or product decisions.
It consumes immutable report.json files, validates paired checkpoint identities, and emits only
aggregate diagnostics. It deliberately prints no reference phrases, prompts, or completions, so
held-out validation can remain uninspected. Use the full local reports for observation diagnostics;
compact Git baseline exports still support phrase-cluster confidence intervals.
"""

import argparse
import collections
import json
import math
import pathlib
import random
import re
import sys
import unicodedata

WORD = re.compile(r"[^\W_]+(?:['’\-][^\W_]+)*", re.UNICODE)


def validate_metric(metric):
    if metric not in ("nextWord", "all"):
        raise ValueError("Metric must be nextWord or all")


def includes_checkpoint(observation, metric):
    return metric == "all" or observation["checkpoint"]["typedCharacters"] == 0


def fold(word):
    return unicodedata.normalize("NFC", word).lower().replace("’", "'")


def diagnostic_word(text, checkpoint):
    """Approximate the Swift caret-aware matcher only for raw-output loss diagnostics.

    Authoritative accuracy always comes from the Swift report. Python's Unicode word classes
    can differ from ICU's; counts from this helper must not be treated as rescored benchmarks.
    Joining at the caret rejects split words, leading punctuation, and dangling apostrophes.
    """
    if not text or not text.strip():
        return None
    typed = checkpoint.get("typedWordPrefix", "")
    if typed and text[0].isspace():
        return None
    joined = typed + text
    match = WORD.search(joined)
    if not match or joined[:match.start()].strip():
        return None
    if match.end() < len(joined) and joined[match.end()] in "'’-":
        return None
    return fold(match.group())


def index_phrases(report):
    if report.get("schemaVersion") != 2:
        raise ValueError("Expected a version 2 report")
    indexed = {}
    for phrase in report["phrases"]:
        key = (phrase["phrase"]["id"], phrase["condition"])
        if key in indexed:
            raise ValueError(f"Duplicate phrase-condition record: {key}")
        indexed[key] = phrase
    if not indexed:
        raise ValueError("Empty reports are not completed comparisons")
    for condition, aggregate in report["conditions"].items():
        phrases = [p for (_, c), p in indexed.items() if c == condition]
        if len(phrases) != aggregate["suite"]["phraseCount"]:
            raise ValueError(f"Incomplete phrase count for {condition}")
        for metric in ("all", "nextWord"):
            for count in ("checkpoints", "correct", "shown", "errors"):
                if sum(p[metric][count] for p in phrases) != aggregate["suite"][metric][count]:
                    raise ValueError(f"Inconsistent {condition} {metric}.{count}")
        for phrase in phrases:
            if len(phrase["observations"]) != phrase["all"]["checkpoints"]:
                raise ValueError("Incomplete checkpoint records")
    if {c for _, c in indexed} != set(report["conditions"]):
        raise ValueError("Unexpected condition records")
    return indexed


def validate_pair(before, after):
    """A paired delta is meaningful only when each checkpoint has the same task input."""
    old, new = index_phrases(before), index_phrases(after)
    for field in ("corpusSHA256", "mode", "contextMode", "seed"):
        if before["metadata"].get(field) != after["metadata"].get(field):
            raise ValueError(f"Cannot compare different {field}")
    if before["errorCount"] or after["errorCount"]:
        raise ValueError("Cannot compare runs with inference errors")
    if old.keys() != new.keys():
        raise ValueError("Cannot compare different phrase selections")
    for key in old:
        a, b = old[key], new[key]
        if a["phrase"] != b["phrase"] or [o["checkpoint"] for o in a["observations"]] != [o["checkpoint"] for o in b["observations"]]:
            raise ValueError(f"Cannot compare different checkpoints: {key}")
    return old, new


def audit(report, *, metric="nextWord"):
    validate_metric(metric)
    index_phrases(report)
    result = {"metric": metric, "label": report["metadata"].get("runLabel"),
              "workerCount": report["metadata"].get("workerCount", 1),
              "configuration": report["metadata"].get("configuration", {}),
              "conditions": {}, "errorCount": report["errorCount"]}
    for condition, aggregate in sorted(report["conditions"].items()):
        observations = [o for p in report["phrases"] if p["condition"] == condition
                        for o in p["observations"] if includes_checkpoint(o, metric)]
        diagnostics = collections.Counter()
        suppressions = collections.Counter()
        for observation in observations:
            if "correct" not in observation or "raw" not in observation:
                continue
            diagnostics["observationsAvailable"] += 1
            raw, shown = observation["raw"], observation.get("shown")
            diagnostics["rawDisplayChanged"] += raw != shown
            diagnostics["emptyRaw"] += not raw.strip()
            diagnostics["notShown"] += not observation["wasShown"]
            if observation.get("suppression"):
                suppressions[observation["suppression"]] += 1
            raw_correct = diagnostic_word(raw, observation["checkpoint"]) == fold(observation["checkpoint"]["expectedWord"])
            diagnostics["rawCorrectDisplayIncorrectApproximate"] += raw_correct and not observation["correct"]
            diagnostics["rawIncorrectDisplayCorrectApproximate"] += not raw_correct and observation["correct"]
        result["conditions"][condition] = {
            "suite": aggregate["suite"], "categories": aggregate["categories"],
            "diagnostics": dict(diagnostics), "suppressions": dict(suppressions),
        }
    if metric == "nextWord" and "contextLift" in report:
        result["contextLift"] = {k: v for k, v in report["contextLift"].items() if k != "byPhrase"}
    elif metric == "all" and {"none", "screen"} <= report["conditions"].keys():
        none, screen = report["conditions"]["none"], report["conditions"]["screen"]
        result["contextLift"] = {
            "suiteAccuracyDelta": screen["suite"][metric]["accuracy"] - none["suite"][metric]["accuracy"],
            "byCategory": {category: screen["categories"][category][metric]["accuracy"]
                           - none["categories"][category][metric]["accuracy"] for category in none["categories"]},
        }
        paired = index_phrases(report)
        if {pid for pid, c in paired if c == "none"} != {pid for pid, c in paired if c == "screen"}:
            raise ValueError("Cannot compute context lift across different phrase selections")
        transitions = collections.Counter()
        for (phrase_id, condition), phrase in paired.items():
            if condition != "none" or (phrase_id, "screen") not in paired:
                continue
            other = paired[(phrase_id, "screen")]["observations"]
            if [o["checkpoint"] for o in phrase["observations"]] != [o["checkpoint"] for o in other]:
                raise ValueError("Cannot compute context lift across different checkpoints")
            for before, after in zip(phrase["observations"], other):
                if "correct" not in before or "correct" not in after:
                    continue
                transitions["improvedCheckpoints"] += not before["correct"] and after["correct"]
                transitions["regressedCheckpoints"] += before["correct"] and not after["correct"]
        result["contextLift"].update(transitions)
    return result


def percentile(values, probability):
    ordered = sorted(values)
    return ordered[max(0, math.ceil(len(ordered) * probability) - 1)]


def paired_statistics(old, new, *, samples=2000, seed=1337, metric="nextWord"):
    """Resample whole phrases within categories, preserving all conditions in each draw.

    Checkpoints in a phrase share text and context, so treating them as independent trials would
    understate uncertainty. Category-stratified phrase sampling preserves the benchmark mix.
    These descriptive intervals measure fixture sampling uncertainty, not native-runtime noise,
    and are not corrected for selecting a winner from multiple screened configurations.
    """
    validate_metric(metric)
    if samples < 100:
        raise ValueError("Use at least 100 bootstrap samples")
    conditions = sorted({c for _, c in old})
    groups = collections.defaultdict(list)
    for phrase_id in sorted({pid for pid, _ in old}):
        available = [c for c in conditions if (phrase_id, c) in old]
        if available != conditions:
            raise ValueError("Conditions must contain matching phrase sets")
        category = old[(phrase_id, conditions[0])]["phrase"]["category"]
        values = []
        for condition in conditions:
            a, b = old[(phrase_id, condition)][metric], new[(phrase_id, condition)][metric]
            if a["checkpoints"] != b["checkpoints"] or not a["checkpoints"]:
                raise ValueError("Checkpoint denominators must match and be positive")
            values.append((a["checkpoints"], b["correct"] - a["correct"]))
        groups[category].append(values)
    distributions = {(condition, category): [] for condition in conditions for category in ["suite", *sorted(groups)]}
    lift = []
    rng = random.Random(seed)
    for _ in range(samples):
        totals = [[0, 0] for _ in conditions]
        for category, phrases in sorted(groups.items()):
            counts = [[0, 0] for _ in conditions]
            for values in rng.choices(phrases, k=len(phrases)):
                for i, (denominator, delta) in enumerate(values):
                    counts[i][0] += denominator
                    counts[i][1] += delta
            for i, condition in enumerate(conditions):
                distributions[(condition, category)].append(counts[i][1] / counts[i][0])
                totals[i][0] += counts[i][0]
                totals[i][1] += counts[i][1]
        suite_deltas = {}
        for i, condition in enumerate(conditions):
            suite_deltas[condition] = totals[i][1] / totals[i][0]
            distributions[(condition, "suite")].append(suite_deltas[condition])
        if "screen" in conditions and "none" in conditions:
            lift.append(suite_deltas["screen"] - suite_deltas["none"])
    intervals = {f"{condition}/{category}": [percentile(v, .025), percentile(v, .975)]
                 for (condition, category), v in distributions.items()}
    if lift:
        intervals["contextLift"] = [percentile(lift, .025), percentile(lift, .975)]
    return {"metric": metric, "samples": samples, "seed": seed, "confidence": .95,
            "method": "paired category-stratified phrase-cluster percentile bootstrap",
            "accuracyDeltaIntervals": intervals}


def compare(before, after, *, samples=2000, seed=1337, metric="nextWord"):
    validate_metric(metric)
    old, new = validate_pair(before, after)
    result = {"metric": metric, "before": audit(before, metric=metric), "after": audit(after, metric=metric),
              "bootstrap": paired_statistics(old, new, samples=samples, seed=seed, metric=metric), "deltas": {}}
    for condition in sorted(before["conditions"]):
        rows = {}
        a, b = before["conditions"][condition], after["conditions"][condition]
        for category in ["suite", *sorted(a["categories"])]:
            x = (a[category] if category == "suite" else a["categories"][category])[metric]
            y = (b[category] if category == "suite" else b["categories"][category])[metric]
            rows[category] = {key: y[key] - x[key] for key in ("correct", "accuracy", "coverage")}
            for key in ("precisionWhenShown", "latencyP50Milliseconds", "latencyP95Milliseconds"):
                if key in x and key in y:
                    rows[category][key] = y[key] - x[key]
            transitions = collections.Counter()
            for key, phrase in old.items():
                if key[1] != condition or (category != "suite" and phrase["phrase"]["category"] != category):
                    continue
                for x, y in zip(phrase["observations"], new[key]["observations"]):
                    if not includes_checkpoint(x, metric) or "correct" not in x or "correct" not in y:
                        continue
                    transitions["pairedObservationsAvailable"] += 1
                    transitions["improved"] += not x["correct"] and y["correct"]
                    transitions["regressed"] += x["correct"] and not y["correct"]
            rows[category]["transitions"] = dict(transitions)
        result["deltas"][condition] = rows
    result["limitations"] = [
        "Intervals are descriptive fixture uncertainty, not runtime repeatability or proof of general writing improvement.",
        "Screening several candidates introduces selection bias; validate finalists on an untouched subset.",
        "Raw-output correctness is approximate Python diagnostics; Swift report scores remain authoritative.",
        "Latency with parallel workers includes contention; use matching one-worker runs for interactive latency.",
    ]
    return result


def markdown(result):
    if "deltas" not in result:
        return json.dumps(result, indent=2, sort_keys=True)
    metric_label = "nextWord (zero-letter word boundaries)" if result["metric"] == "nextWord" else "all (every recorded checkpoint)"
    lines = [f"Metric: **{metric_label}**.", "",
             "| Condition / category | Accuracy change | 95% interval | Gains / losses | p95 change |",
             "|---|---:|---:|---:|---:|"]
    for condition, rows in result["deltas"].items():
        for category, values in rows.items():
            interval = result["bootstrap"]["accuracyDeltaIntervals"][f"{condition}/{category}"]
            transitions = values["transitions"]
            flips = f"{transitions.get('improved', 0)} / {transitions.get('regressed', 0)}" if transitions else "unavailable"
            latency = f"{values['latencyP95Milliseconds']:+.1f} ms" if "latencyP95Milliseconds" in values else "n/a"
            lines.append(f"| {condition} / {category} | {100 * values['accuracy']:+.3f} pp | "
                         f"[{100 * interval[0]:+.3f}, {100 * interval[1]:+.3f}] pp | {flips} | {latency} |")
    return "\n".join(lines) + "\n\n" + "\n".join(f"- {line}" for line in result["limitations"])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("before", type=pathlib.Path)
    parser.add_argument("after", type=pathlib.Path, nargs="?")
    parser.add_argument("--bootstrap-samples", type=int, default=2000)
    parser.add_argument("--seed", type=int, default=1337, help="Bootstrap seed; does not change inference")
    parser.add_argument("--metric", choices=("nextWord", "all"), default="nextWord",
                        help="Accuracy population: zero-letter word boundaries (default) or all recorded checkpoints, including partial words")
    parser.add_argument("--markdown", action="store_true")
    args = parser.parse_args()
    try:
        before = json.loads(args.before.read_text())
        result = compare(before, json.loads(args.after.read_text()), samples=args.bootstrap_samples,
                         seed=args.seed, metric=args.metric) if args.after else audit(before, metric=args.metric)
        print(markdown(result) if args.markdown else json.dumps(result, indent=2, sort_keys=True))
    except (OSError, ValueError, KeyError) as error:
        print(f"Analysis failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
