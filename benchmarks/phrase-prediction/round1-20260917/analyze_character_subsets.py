#!/usr/bin/env python3
"""Round-local aggregate analysis of the registered, frozen character-mode pair.

Swift's recorded correct/wasShown flags remain authoritative. This helper separates
zero-letter boundaries from positive-letter checkpoints without lexical rescoring.
The completed full-word pair pins source/configuration provenance and supplies exact
boundary checkpoints; ASCII target expansion verifies the complete character replay.
No app execution, corpus editing, prompt inspection, or candidate selection occurs.
"""
import argparse
import collections
import copy
import datetime
import hashlib
import importlib.util
import json
import math
from pathlib import Path
import re
import sys
import unittest

SCRIPT = Path(__file__).resolve()
ROUND = SCRIPT.parent
REPO = SCRIPT.parents[3]
SUBSETS = ("wordBoundary", "partialOnly", "all")
IDENTITY_FIELDS = ("prompt", "screenExcerpt", "raw", "shown", "wasShown", "predictedWord", "suppression", "correct")
FIELDS = {"temperature": "temperature", "repetition_penalty": "repetitionPenalty",
          "top_k": "topK", "top_p": "topP", "min_p": "minP"}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def load_analyzer(path):
    spec = importlib.util.spec_from_file_location("character_subset_existing_analyzer", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def file_hash(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read_run(path):
    report_path = path / "report.json" if path.is_dir() else path
    manifest_path = report_path.with_name("manifest.json")
    return (json.loads(report_path.read_text()), json.loads(manifest_path.read_text()),
            {str(p.resolve()): file_hash(p) for p in (report_path, manifest_path)})


def included(observation, subset):
    typed = observation["checkpoint"]["typedCharacters"]
    return subset == "all" or (typed == 0 if subset == "wordBoundary" else typed > 0)


def counts(observations):
    n = len(observations)
    correct = sum(o["correct"] for o in observations)
    shown = sum(o["wasShown"] for o in observations)
    return {"checkpoints": n, "correct": correct, "shown": shown, "errors": 0,
            "accuracy": correct / n if n else None, "coverage": shown / n if n else None,
            "precisionWhenShown": correct / shown if shown else None}


def check_metrics(expected, actual, location):
    for key in ("checkpoints", "correct", "shown", "errors"):
        require(type(actual.get(key)) is int and actual[key] == expected[key],
                f"Inconsistent {location}.{key}")


def validate_report(report, manifest, analyzer, *, character):
    index = analyzer.index_phrases(report)
    metadata = report["metadata"]
    require(report["errorCount"] == 0, "Inference errors invalidate this comparison")
    require(metadata["mode"] == ("character" if character else "word"), "Wrong replay mode")
    require(metadata["contextMode"] == "paired" and set(report["conditions"]) == {"none", "screen"},
            "Expected both paired context conditions")
    for field in ("mode", "contextMode", "corpusSHA256", "workerCount"):
        require(manifest.get(field) == metadata.get(field), f"Manifest/report mismatch: {field}")
    require(manifest.get("label") == metadata.get("runLabel"), "Manifest/report label mismatch")
    require(manifest.get("modelPath") == metadata.get("model"), "Manifest/report model path mismatch")
    for field in ("sourceSHA256", "productSHA256"):
        require(re.fullmatch(r"[0-9a-f]{64}", manifest.get("build", {}).get(field, "")) is not None,
                f"Missing valid recorded {field}")
    if "buildInputs" in manifest:
        require(manifest["buildInputs"]["sourceSHA256"] == manifest["build"]["sourceSHA256"],
                "Build input/source fingerprint disagreement")
    for field in ("modelSHA256",):
        require(re.fullmatch(r"[0-9a-f]{64}", metadata["configuration"].get(field, "")) is not None,
                f"Missing valid {field}")
    for field, value in manifest["samplingOverrides"].items():
        actual = metadata["seed"] if field == "seed" else metadata["configuration"].get(FIELDS[field])
        require(actual is not None and math.isclose(float(actual), value, rel_tol=1e-12, abs_tol=1e-12),
                f"Requested/effective sampler mismatch: {field}")
    ids = manifest["phraseIDs"]
    require(len(ids) == len(set(ids)), "Duplicate manifest phrase ID")
    require(set(index) == {(pid, c) for pid in ids for c in ("none", "screen")},
            "Report does not contain the full manifest phrase selection")
    for key, phrase in index.items():
        observations = phrase["observations"]
        identities = []
        for o in observations:
            require(type(o.get("correct")) is bool and type(o.get("wasShown")) is bool,
                    "Full authoritative observation flags are required")
            require(not o["correct"] or o["wasShown"], "Correct observation cannot be suppressed")
            require(not o.get("error"), "Observation contains an inference error")
            cp = o["checkpoint"]
            require(type(cp["typedCharacters"]) is int and cp["typedCharacters"] >= 0,
                    "Invalid typedCharacters")
            identities.append((cp["wordIndex"], cp["typedCharacters"]))
        require(len(identities) == len(set(identities)), "Duplicate checkpoint identity")
        for metric, subset in (("all", "all"), ("nextWord", "wordBoundary")):
            check_metrics(counts([o for o in observations if included(o, subset)]), phrase[metric],
                          f"phrase {key} {metric}")
    for condition, aggregate in report["conditions"].items():
        selected = [p for (_, c), p in index.items() if c == condition]
        categories = {p["phrase"]["category"] for p in selected}
        require(set(aggregate["categories"]) == categories, "Category summaries do not match records")
        for category in [None, *sorted(categories)]:
            group = [p for p in selected if category is None or p["phrase"]["category"] == category]
            summary = aggregate["suite"] if category is None else aggregate["categories"][category]
            require(summary["phraseCount"] == len(group), "Incomplete category phrase count")
            for metric, subset in (("all", "all"), ("nextWord", "wordBoundary")):
                expected = counts([o for p in group for o in p["observations"] if included(o, subset)])
                check_metrics(expected, summary[metric], f"{condition}/{category or 'suite'}/{metric}")
    for pid in ids:
        left, right = index[(pid, "none")], index[(pid, "screen")]
        require(left["phrase"] == right["phrase"], "Context conditions have different phrase definitions")
        require([o["checkpoint"] for o in left["observations"]] ==
                [o["checkpoint"] for o in right["observations"]],
                "Context conditions have different checkpoint identities")
    return index


def expanded_checkpoints(word_phrase):
    """Expand already-authoritative boundaries, never retokenize or rescore text.

    This registered corpus has ASCII target words. Fail rather than approximate
    Swift grapheme slicing if this one-off helper is pointed at another corpus.
    Prefixes themselves may be Unicode and remain copied exactly.
    """
    result = []
    for observation in word_phrase["observations"]:
        boundary = observation["checkpoint"]
        word = boundary["expectedWord"]
        require(word and word.isascii(), "Checkpoint expansion requires ASCII target words")
        require(boundary["typedCharacters"] == 0 and boundary["typedWordPrefix"] == "",
                "Reference is not a zero-letter boundary")
        for offset in range(len(word)):
            result.append({**boundary, "typedCharacters": offset, "typedWordPrefix": word[:offset],
                           "prefix": boundary["prefix"] + word[:offset]})
    return result


def validate_registered_pair(before, after, bm, am, references, registration, analyzer):
    old = validate_report(before, bm, analyzer, character=True)
    new = validate_report(after, am, analyzer, character=True)
    analyzer.validate_pair(before, after)
    plan = registration["plan"]
    require(plan["mode"] == "character" and plan["context"] == "paired" and plan["split"] == "all",
            "This helper requires the registered paired all-split character replay")
    args = plan["extraArgs"]
    require(len(args) == 2 and args[0] == "--per-category", "Unexpected registered selection arguments")
    cap = int(args[1])
    require(cap > 0, "Invalid registered category cap")
    ref_before, ref_after = references
    analyzer.validate_pair(ref_before[0], ref_after[0])
    require(before["metadata"]["model"] == after["metadata"]["model"]
            and before["metadata"]["configuration"]["modelSHA256"]
            == after["metadata"]["configuration"]["modelSHA256"], "Paired model identity differs")
    expected_ids = None
    for report, manifest, ref, index, policy in (
            (before, bm, ref_before, old, registration["baseline"]),
            (after, am, ref_after, new, registration["candidate"])):
        rr, rm = ref
        ref_index = validate_report(rr, rm, analyzer, character=False)
        require(manifest["build"]["sourceSHA256"] == rm["build"]["sourceSHA256"],
                "Character source fingerprint differs from its frozen reference")
        for field in ("corpusSHA256", "corpusVersion", "seed", "workerCount", "model", "configuration"):
            require(report["metadata"].get(field) == rr["metadata"].get(field),
                    f"Character/reference metadata differs: {field}")
        require(manifest["samplingOverrides"] == policy == rm["samplingOverrides"],
                "Sampler does not match registration and frozen reference")
        require(report["metadata"]["workerCount"] == plan["workers"], "Unregistered worker count")
        require(manifest["selection"] == {"split": plan["split"], "splitSeed": plan["splitSeed"],
                "screenPerCategory": plan["screenPerCategory"], "perCategory": cap, "limit": None},
                "Selection does not match registration")
        require(rm["selection"]["split"] == "all" and rm["selection"]["perCategory"] is None
                and rm["selection"]["limit"] is None, "Reference is not the full all-split suite")
        category_counts = collections.Counter()
        selected = []
        for pid in rm["phraseIDs"]:
            category = ref_index[(pid, "none")]["phrase"]["category"]
            category_counts[category] += 1
            if category_counts[category] <= cap:
                selected.append(pid)
        require(all(n >= cap for n in category_counts.values()), "Reference lacks registered category cap")
        require(manifest["phraseIDs"] == selected, "Character selection/order differs from registered corpus order")
        require(expected_ids is None or expected_ids == selected, "References select different phrases")
        expected_ids = selected
        for key, phrase in index.items():
            ref_phrase = ref_index[key]
            require(phrase["phrase"] == ref_phrase["phrase"], "Character/reference phrase content differs")
            require([o["checkpoint"] for o in phrase["observations"]] == expanded_checkpoints(ref_phrase),
                    "Character checkpoint replay is incomplete or differs from reference")
    before_config, after_config = before["metadata"]["configuration"], after["metadata"]["configuration"]
    config_delta = {k for k in before_config.keys() | after_config.keys()
                    if before_config.get(k) != after_config.get(k)}
    require(config_delta == {"repetitionPenalty"}, "Frozen pair changed an unexpected effective setting")
    return old, new


def aggregate_pair(old, new, subset):
    result = {}
    for condition in ("none", "screen"):
        categories = sorted({p["phrase"]["category"] for (_, c), p in old.items() if c == condition})
        rows = {}
        for category in [None, *categories]:
            keys = [key for key, phrase in old.items() if key[1] == condition
                    and (category is None or phrase["phrase"]["category"] == category)]
            a = [o for key in keys for o in old[key]["observations"] if included(o, subset)]
            b = [o for key in keys for o in new[key]["observations"] if included(o, subset)]
            x, y = counts(a), counts(b)
            gains = sum(not u["correct"] and v["correct"] for u, v in zip(a, b))
            losses = sum(u["correct"] and not v["correct"] for u, v in zip(a, b))
            require(x["checkpoints"] == y["checkpoints"], "Subset denominator disagreement")
            require(y["correct"] - x["correct"] == gains - losses, "Paired accounting disagreement")
            rows[category or "suite"] = {"phraseCount": len(keys), "before": x, "after": y,
                "pairedGains": gains, "pairedLosses": losses,
                "accuracyDelta": y["accuracy"] - x["accuracy"] if a else None,
                "coverageDelta": y["coverage"] - x["coverage"] if a else None}
        result[condition] = rows
    return result


def partial_bootstrap(old, new, analyzer, samples, seed):
    """Reuse the audited bootstrap with only each phrase's partial-checkpoint counts.

    Every sampled cluster retains all positive-letter observations in that phrase.
    Both conditions share each draw. Never resample individual character positions.
    """
    projected = []
    for index in (old, new):
        view = {}
        for key, phrase in index.items():
            partial = counts([o for o in phrase["observations"] if included(o, "partialOnly")])
            require(partial["checkpoints"] > 0,
                    "A phrase has no partial checkpoints; projection requires positive phrase denominators")
            view[key] = {"phrase": phrase["phrase"], "all": partial}
        projected.append(view)
    result = analyzer.paired_statistics(*projected, samples=samples, seed=seed, metric="all")
    result["metric"] = "partialOnly"
    result["denominator"] = "Only checkpoints where typedCharacters > 0; whole phrases are the resampling unit"
    return result


def boundary_identity(character_index, word_report, analyzer):
    """Compare recorded outputs for the same boundary under different replay histories.

    Mode is not passed to request construction. Equal boundaries should make equal
    requests, while cache/decode batch history and OS spelling sessions can differ.
    Differences are evidence to investigate, never rescored successes or failures.
    """
    word_index = analyzer.index_phrases(word_report)
    counters = collections.defaultdict(collections.Counter)
    for key, phrase in character_index.items():
        reference = word_index[key]
        reference_observations = {o["checkpoint"]["wordIndex"]: o for o in reference["observations"]}
        first_word = reference["observations"][0]["checkpoint"]["wordIndex"]
        category = phrase["phrase"]["category"]
        for char in phrase["observations"]:
            if char["checkpoint"]["typedCharacters"] != 0:
                continue
            word = reference_observations[char["checkpoint"]["wordIndex"]]
            require(char["checkpoint"] == word["checkpoint"], "Boundary identity has different task inputs")
            require(isinstance(char.get("raw"), str) and isinstance(word.get("raw"), str),
                    "Full raw output is required for boundary identity diagnostics")
            changed = {field: char.get(field) != word.get(field) for field in IDENTITY_FIELDS}
            same_input = not changed["prompt"] and not changed["screenExcerpt"]
            position = "firstBoundary" if char["checkpoint"]["wordIndex"] == first_word else "laterBoundaries"
            for group in ("suite", f"category/{category}", f"position/{position}"):
                row = counters[(key[1], group)]
                row["checkpoints"] += 1
                row["identicalAllComparedFields"] += not any(changed.values())
                row["anyComparedFieldMismatch"] += any(changed.values())
                for field, mismatch in changed.items():
                    row[field + "Mismatch"] += mismatch
                row["rawMismatchWithSameRecordedInput"] += same_input and changed["raw"]
                row["shownMismatchWithSameRecordedInputAndRaw"] += same_input and not changed["raw"] and changed["shown"]
                row["correctMismatchWithSameShown"] += not changed["shown"] and changed["correct"]
                row["characterCorrectGain"] += not word["correct"] and char["correct"]
                row["characterCorrectLoss"] += word["correct"] and not char["correct"]
    conditions = {}
    for condition in ("none", "screen"):
        conditions[condition] = {"suite": dict(counters[(condition, "suite")]), "categories": {}, "positions": {}}
        for (context, group), value in sorted(counters.items()):
            if context != condition or group == "suite": continue
            kind, name = group.split("/", 1)
            conditions[condition]["categories" if kind == "category" else "positions"][name] = dict(value)
    return {"direction": "full word-mode reference → character-mode zero-letter checkpoints",
            "comparedFields": list(IDENTITY_FIELDS), "ignoredFields": ["latencyMilliseconds"],
            "conditions": conditions,
            "interpretation": "No intentional mode-dependent request behavior; mismatches indicate replay-history, numerical, OS postprocessing, or provenance effects to investigate, not changed benchmark scores."}


def markdown(result):
    lines = ["# Frozen character-pair subset analysis", "",
        "All correctness and display counts use Swift report flags. No lexical rescoring was performed.", "",
        "`wordBoundary` means typedCharacters == 0; `partialOnly` means typedCharacters > 0; `all` is their disjoint union. Suppressed predictions remain misses in every denominator.", "",
        "| Subset / context | Checkpoints | Correct before → after | Accuracy before → after | Δ pp | Shown before → after | Gains / losses |",
        "|---|---:|---:|---:|---:|---:|---:|"]
    for subset, conditions in result["subsets"].items():
        for condition, rows in conditions.items():
            row = rows["suite"]; a, b = row["before"], row["after"]
            lines.append(f"| {subset} / {condition} | {a['checkpoints']:,} | {a['correct']:,} → {b['correct']:,} | {a['accuracy']:.2%} → {b['accuracy']:.2%} | {100*row['accuracyDelta']:+.3f} | {a['shown']:,} → {b['shown']:,} | {row['pairedGains']:,} / {row['pairedLosses']:,} |")
    lines += ["", "## Partial-word uncertainty", "",
        f"{result['partialBootstrap']['samples']:,} paired category-stratified whole-phrase resamples, fixed bootstrap seed {result['partialBootstrap']['seed']}. Character checkpoints within a phrase remain together, and screen/no-screen share every sampled phrase draw.", "",
        "| Context / group | Partial-only Δ pp | 95% interval, pp |", "|---|---:|---:|"]
    intervals = result["partialBootstrap"]["accuracyDeltaIntervals"]
    for condition, rows in result["subsets"]["partialOnly"].items():
        for category, row in rows.items():
            low, high = intervals[f"{condition}/{category}"]
            lines.append(f"| {condition} / {category} | {100*row['accuracyDelta']:+.3f} | [{100*low:+.3f}, {100*high:+.3f}] |")
    for subset, conditions in result["subsets"].items():
        lines += ["", f"## {subset} category denominators", "",
                  "| Context / category | Checkpoints | Correct before → after | Shown before → after | Δ pp | Gains / losses |",
                  "|---|---:|---:|---:|---:|---:|"]
        for condition, rows in conditions.items():
            for category, row in rows.items():
                if category == "suite": continue
                a, b = row["before"], row["after"]
                lines.append(f"| {condition} / {category} | {a['checkpoints']:,} | {a['correct']:,} → {b['correct']:,} | {a['shown']:,} → {b['shown']:,} | {100*row['accuracyDelta']:+.3f} | {row['pairedGains']:,} / {row['pairedLosses']:,} |")
    lines += ["", "## Word-mode versus character-mode boundary identity", "",
        "Each configuration is compared only with its own frozen full-word run, on the character run's overlapping zero-letter checkpoints. Exact recorded prompt, excerpt, raw, shown, visibility, predicted word, suppression, and correctness values are compared; latency is ignored. Counts describe disagreements and do not replace either score.", "",
        "| Configuration / context | Boundaries | Any mismatch | Prompt / excerpt mismatch | Raw mismatch, same input | Shown mismatch, same input + raw | Correct mismatch | Character gains / losses |",
        "|---|---:|---:|---:|---:|---:|---:|---:|"]
    for label, identity in result["wordModeBoundaryIdentity"].items():
        for condition, groups in identity["conditions"].items():
            row = groups["suite"]
            lines.append(f"| {label} / {condition} | {row['checkpoints']:,} | {row['anyComparedFieldMismatch']:,} | {row['promptMismatch']:,} / {row['screenExcerptMismatch']:,} | {row['rawMismatchWithSameRecordedInput']:,} | {row['shownMismatchWithSameRecordedInputAndRaw']:,} | {row['correctMismatch']:,} | {row['characterCorrectGain']:,} / {row['characterCorrectLoss']:,} |")
    lines += ["", "| Configuration / context / position | Boundaries | Raw mismatch, same input | Correct mismatch |",
              "|---|---:|---:|---:|"]
    for label, identity in result["wordModeBoundaryIdentity"].items():
        for condition, groups in identity["conditions"].items():
            for position, row in groups["positions"].items():
                lines.append(f"| {label} / {condition} / {position} | {row['checkpoints']:,} | {row['rawMismatchWithSameRecordedInput']:,} | {row['correctMismatch']:,} |")
    lines += ["", "The first boundary follows an explicit phrase/context cache reset in both modes; later boundaries follow different generation histories. There is no deliberate mode-specific prompt or sampler policy at zero-letter checkpoints. Different KV restoration/decode batching and worker/spelling-session histories mean a mismatch is not by itself proof of a cache bug. Per-category and per-field counts are retained in JSON."]
    lines += ["", "## Interpretation and provenance", "", *[f"- {x}" for x in result["limitations"]], "",
        "The JSON companion records report, manifest, registration, helper, and existing-analyzer SHA-256 hashes, plus both source and binary fingerprints. These are recorded provenance checks, not a cryptographic attestation of a historical execution."]
    return "\n".join(lines) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("before", type=Path, nargs="?")
    parser.add_argument("after", type=Path, nargs="?")
    parser.add_argument("--before-reference", type=Path, default=ROUND / "full42-baseline")
    parser.add_argument("--after-reference", type=Path, default=ROUND / "full42-finalist")
    parser.add_argument("--registration", type=Path, default=ROUND / "character150-plan.json")
    parser.add_argument("--analyzer", type=Path, default=REPO / "scripts/analyze_phrase_experiments.py")
    parser.add_argument("--samples", type=int, default=20000)
    parser.add_argument("--bootstrap-seed", type=int, default=1337)
    parser.add_argument("--output-prefix", type=Path)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        global TEST_ANALYZER
        TEST_ANALYZER = load_analyzer(args.analyzer)
        suite = unittest.defaultTestLoader.loadTestsFromTestCase(SubsetTests)
        return 0 if unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful() else 1
    require(args.before is not None and args.after is not None and args.output_prefix is not None,
            "Provide before, after, and --output-prefix")
    require(args.samples >= 100, "Use at least 100 bootstrap samples")
    analyzer = load_analyzer(args.analyzer)
    before, bm, hashes = read_run(args.before)
    after, am, after_hashes = read_run(args.after); hashes.update(after_hashes)
    references = []
    for path in (args.before_reference, args.after_reference):
        report, manifest, source_hashes = read_run(path)
        references.append((report, manifest)); hashes.update(source_hashes)
    registration = json.loads(args.registration.read_text())
    for path in (args.registration, args.analyzer, SCRIPT):
        hashes[str(path.resolve())] = file_hash(path)
    old, new = validate_registered_pair(before, after, bm, am, references, registration, analyzer)
    subsets = {subset: aggregate_pair(old, new, subset) for subset in SUBSETS}
    for condition in ("none", "screen"):
        for category in subsets["all"][condition]:
            for side in ("before", "after"):
                for field in ("checkpoints", "correct", "shown"):
                    require(subsets["wordBoundary"][condition][category][side][field]
                            + subsets["partialOnly"][condition][category][side][field]
                            == subsets["all"][condition][category][side][field], "Subset partition failed")
    result = {"generatedUTC": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "purpose": "Frozen character-pair diagnostics; no retuning or lexical rescoring",
        "labels": [before["metadata"]["runLabel"], after["metadata"]["runLabel"]],
        "samplingSeed": before["metadata"]["seed"], "subsets": subsets,
        "partialBootstrap": partial_bootstrap(old, new, analyzer, args.samples, args.bootstrap_seed),
        "wordModeBoundaryIdentity": {
            "baseline": boundary_identity(old, references[0][0], analyzer),
            "finalist": boundary_identity(new, references[1][0], analyzer)},
        "sourceSHA256": hashes, "builds": {"before": bm["build"], "after": am["build"]},
        "modelSHA256": before["metadata"]["configuration"]["modelSHA256"],
        "limitations": [
            "Partial-only estimates are separate from the primary zero-letter word-boundary score; an all-checkpoint improvement cannot establish partial-word non-regression.",
            "Intervals describe phrase-sampling uncertainty in this selected synthetic corpus, not runtime noise, semantic utility, or general writing accuracy.",
            "This registered subset is the first 150 corpus-order phrases per category, including screening phrases; it is not a new untouched held-out writing set.",
            "Category intervals and three subset summaries are descriptive and are not corrected for multiple comparisons or screening selection.",
            "All scoring uses the frozen snapshot's display policy; concurrently edited production completion behavior requires separate integration validation.",
            "No latency inference is made from these three-worker runs. Production seed robustness is evaluated separately; this pair uses seed 42."]}
    # Read all inputs and validate before writing; never overwrite a source file accidentally.
    outputs = [args.output_prefix.with_suffix(suffix).resolve() for suffix in (".json", ".md")]
    require(not any(str(path) in hashes for path in outputs), "Output would overwrite an input")
    outputs[0].write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    outputs[1].write_text(markdown(result))
    print(f"Validated complete pair; wrote {outputs[0]} and {outputs[1]}")
    return 0


def fixture_pair(outcomes_before=None, outcomes_after=None):
    """Artificial flags make score accounting testable without reading live results."""
    before_values = outcomes_before or {"a-1": [False, True, True], "a-2": [False, True, True],
                                       "b-1": [False, True, True], "b-2": [False, True, True]}
    after_values = outcomes_after or {pid: [True, False, False] for pid in before_values}
    reports = []
    for label, values, penalty, source in (("baseline", before_values, 1.05, "a"),
                                          ("finalist", after_values, 1.025, "b")):
        records = []
        for pid, flags in values.items():
            for condition in ("none", "screen"):
                observations = [{"checkpoint": {"wordIndex": 1, "typedCharacters": i,
                    "prefix": "A " + "cat"[:i], "typedWordPrefix": "cat"[:i], "expectedWord": "cat"},
                    "correct": flag, "wasShown": True, "prompt": "A " + "cat"[:i],
                    "raw": "cat" if flag else "dog", "shown": "cat" if flag else "dog"}
                    for i, flag in enumerate(flags)]
                records.append({"phrase": {"id": pid, "category": pid[0]}, "condition": condition,
                    "observations": observations, "all": counts(observations),
                    "nextWord": counts(observations[:1])})
        conditions = {}
        for condition in ("none", "screen"):
            selected = [p for p in records if p["condition"] == condition]
            def summary(group):
                obs = [o for p in group for o in p["observations"]]
                return {"phraseCount": len(group), "all": counts(obs),
                        "nextWord": counts([o for o in obs if included(o, "wordBoundary")])}
            conditions[condition] = {"suite": summary(selected), "categories": {
                c: summary([p for p in selected if p["phrase"]["category"] == c]) for c in ("a", "b")}}
        policy = {"temperature": .1, "repetition_penalty": penalty, "top_k": 20,
                  "top_p": .7, "min_p": .08, "seed": 42}
        config = {FIELDS[k]: str(v) for k, v in policy.items() if k != "seed"}
        config["modelSHA256"] = "c" * 64
        metadata = {"mode": "character", "contextMode": "paired", "corpusSHA256": "d" * 64,
                    "corpusVersion": 2, "seed": 42, "workerCount": 3, "model": "test.gguf",
                    "configuration": config, "runLabel": label}
        report = {"schemaVersion": 2, "errorCount": 0, "metadata": metadata,
                  "conditions": conditions, "phrases": records}
        manifest = {**{k: metadata[k] for k in ("mode", "contextMode", "corpusSHA256", "workerCount")},
            "label": label, "modelPath": "test.gguf", "phraseIDs": list(values),
            "samplingOverrides": policy, "selection": {"split": "all", "splitSeed": 1337,
                "screenPerCategory": 20, "perCategory": 2, "limit": None},
            "build": {"sourceSHA256": source * 64, "productSHA256": source * 64}}
        reports.append((report, manifest))
    references = copy.deepcopy(reports)
    for report, manifest in references:
        report["metadata"]["mode"] = manifest["mode"] = "word"
        manifest["selection"]["perCategory"] = None
        for phrase in report["phrases"]:
            phrase["observations"] = phrase["observations"][:1]
            phrase["all"] = copy.deepcopy(phrase["nextWord"])
        for aggregate in report["conditions"].values():
            for summary in [aggregate["suite"], *aggregate["categories"].values()]:
                summary["all"] = copy.deepcopy(summary["nextWord"])
    registration = {"baseline": reports[0][1]["samplingOverrides"], "candidate": reports[1][1]["samplingOverrides"],
        "plan": {"mode": "character", "context": "paired", "split": "all", "splitSeed": 1337,
                 "screenPerCategory": 20, "workers": 3, "extraArgs": ["--per-category", "2"]}}
    return reports, references, registration


class SubsetTests(unittest.TestCase):
    def setUp(self):
        self.reports, self.references, self.registration = fixture_pair()

    def validate(self):
        (b, bm), (a, am) = self.reports
        return validate_registered_pair(b, a, bm, am, self.references, self.registration, TEST_ANALYZER)

    def test_boundary_gains_do_not_hide_partial_regression(self):
        old, new = self.validate()
        self.assertEqual(aggregate_pair(old, new, "wordBoundary")["screen"]["suite"]["accuracyDelta"], 1)
        partial = aggregate_pair(old, new, "partialOnly")["screen"]["suite"]
        self.assertEqual(partial["accuracyDelta"], -1)
        self.assertEqual(partial["before"]["checkpoints"], 8)
        self.assertEqual((partial["pairedGains"], partial["pairedLosses"]), (0, 8))

    def test_projected_bootstrap_keeps_all_partial_checkpoints_in_each_phrase(self):
        old, new = self.validate()
        result = partial_bootstrap(old, new, TEST_ANALYZER, 100, 1337)
        self.assertEqual(result["accuracyDeltaIntervals"]["screen/suite"], [-1, -1])
        self.assertEqual(result["accuracyDeltaIntervals"]["contextLift"], [0, 0])
        self.assertEqual(result, partial_bootstrap(old, new, TEST_ANALYZER, 100, 1337))

    def test_positive_all_checkpoint_score_can_coexist_with_partial_regression(self):
        before = {p: [False, p == "a-1", False] for p in ("a-1", "a-2", "b-1", "b-2")}
        after = {p: [True, False, False] for p in before}
        self.reports, self.references, self.registration = fixture_pair(before, after)
        old, new = self.validate()
        self.assertGreater(aggregate_pair(old, new, "all")["screen"]["suite"]["accuracyDelta"], 0)
        partial = aggregate_pair(old, new, "partialOnly")["screen"]["suite"]
        self.assertEqual(partial["accuracyDelta"], -1 / 8)
        self.assertEqual((partial["pairedGains"], partial["pairedLosses"]), (0, 1))

    def test_identical_flags_have_no_transitions_or_bootstrap_width(self):
        values = {p: [False, True, False] for p in ("a-1", "a-2", "b-1", "b-2")}
        self.reports, self.references, self.registration = fixture_pair(values, values)
        old, new = self.validate()
        row = aggregate_pair(old, new, "partialOnly")["none"]["suite"]
        self.assertEqual((row["pairedGains"], row["pairedLosses"]), (0, 0))
        self.assertEqual(partial_bootstrap(old, new, TEST_ANALYZER, 100, 3)["accuracyDeltaIntervals"]["none/suite"], [0, 0])

    def test_partial_bootstrap_uses_phrase_clusters_not_character_trials(self):
        before = {p: [False, False, False] for p in ("a-1", "a-2", "b-1", "b-2")}
        after = {p: [False, p.endswith("1"), p.endswith("1")] for p in before}
        self.reports, self.references, self.registration = fixture_pair(before, after)
        old, new = self.validate()
        ci = partial_bootstrap(old, new, TEST_ANALYZER, 2000, 42)["accuracyDeltaIntervals"]["screen/a"]
        self.assertEqual(ci, [0, 1])

    def test_rejects_model_source_seed_and_selection_mismatch(self):
        mutations = [lambda r: r[1]["build"].update(sourceSHA256="f" * 64),
            lambda r: r[0]["metadata"]["configuration"].update(modelSHA256="f" * 64),
            lambda r: r[0]["metadata"].update(seed=99),
            lambda r: r[1]["selection"].update(perCategory=1)]
        for mutate in mutations:
            with self.subTest(mutate=mutate):
                self.setUp(); mutate(self.reports[1])
                with self.assertRaises(ValueError): self.validate()

    def test_rejects_boolean_strings_errors_and_false_aggregates(self):
        mutations = [lambda r: r["phrases"][0]["observations"][0].update(correct="false"),
            lambda r: r.update(errorCount=1),
            lambda r: r["phrases"][0]["observations"][0].update(error="failed"),
            lambda r: r["conditions"]["screen"]["categories"]["a"]["all"].update(correct=999)]
        for mutate in mutations:
            with self.subTest(mutate=mutate):
                self.setUp(); mutate(self.reports[1][0])
                with self.assertRaises(ValueError): self.validate()

    def test_rejects_missing_and_changed_checkpoints(self):
        self.reports[1][0]["phrases"][0]["observations"].pop()
        with self.assertRaises(ValueError): self.validate()
        self.setUp()
        self.reports[1][0]["phrases"][0]["observations"][1]["checkpoint"]["prefix"] = "different"
        with self.assertRaises(ValueError): self.validate()

    def test_rejects_both_runs_missing_same_character_checkpoint(self):
        # Even mutually consistent, internally repaired aggregates must match the
        # full character expansion of the independent reference boundaries.
        for report, manifest in self.reports:
            for phrase in report["phrases"]:
                phrase["observations"].pop()
                phrase["all"] = counts(phrase["observations"])
            for condition, aggregate in report["conditions"].items():
                for category in [None, "a", "b"]:
                    selected = [p for p in report["phrases"] if p["condition"] == condition and
                                (category is None or p["phrase"]["category"] == category)]
                    summary = aggregate["suite"] if category is None else aggregate["categories"][category]
                    summary["all"] = counts([o for p in selected for o in p["observations"]])
        with self.assertRaisesRegex(ValueError, "incomplete or differs"): self.validate()

    def test_suppressed_observations_remain_in_denominator(self):
        old, new = self.validate()
        for index in (old, new):
            for phrase in index.values():
                for observation in phrase["observations"]:
                    observation["correct"] = False; observation["wasShown"] = False
        row = aggregate_pair(old, new, "partialOnly")["screen"]["suite"]
        self.assertEqual((row["after"]["checkpoints"], row["after"]["shown"], row["after"]["correct"]), (8, 0, 0))

    def test_non_ascii_target_expansion_fails_closed(self):
        phrase = copy.deepcopy(self.references[0][0]["phrases"][0])
        phrase["observations"][0]["checkpoint"]["expectedWord"] = "café"
        with self.assertRaisesRegex(ValueError, "ASCII"): expanded_checkpoints(phrase)

    def test_boundary_identity_ignores_latency_and_partial_outputs(self):
        old, _ = self.validate()
        for phrase in old.values():
            for o in phrase["observations"]:
                o["latencyMilliseconds"] = 999
                if o["checkpoint"]["typedCharacters"] > 0:
                    o["raw"] = "changed partial only"
        result = boundary_identity(old, self.references[0][0], TEST_ANALYZER)
        row = result["conditions"]["screen"]["suite"]
        self.assertEqual((row["checkpoints"], row["anyComparedFieldMismatch"]), (4, 0))

    def test_boundary_identity_distinguishes_generation_display_and_score_changes(self):
        old, _ = self.validate()
        raw = old[("a-1", "screen")]["observations"][0]
        raw["raw"] = "different generation"
        shown = old[("a-2", "screen")]["observations"][0]
        shown["shown"] = "different display"
        score = old[("b-1", "screen")]["observations"][0]
        score["correct"] = True
        result = boundary_identity(old, self.references[0][0], TEST_ANALYZER)
        row = result["conditions"]["screen"]["suite"]
        self.assertEqual(row["anyComparedFieldMismatch"], 3)
        self.assertEqual(row["rawMismatchWithSameRecordedInput"], 1)
        self.assertEqual(row["shownMismatchWithSameRecordedInputAndRaw"], 1)
        self.assertEqual(row["correctMismatchWithSameShown"], 1)
        self.assertEqual((row["characterCorrectGain"], row["characterCorrectLoss"]), (1, 0))


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, KeyError, OSError, TypeError) as error:
        print(f"Character subset analysis rejected: {error}", file=sys.stderr)
        sys.exit(2)
