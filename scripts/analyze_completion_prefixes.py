#!/usr/bin/env python3
"""Compare how far displayed completions follow the reference, using full phrase reports.

Usage: python3 scripts/analyze_completion_prefixes.py BEFORE AFTER [--markdown]

This offline diagnostic supplements the unchanged Swift next-word score. The first word always
uses observation.correct; subsequent words use approximate lexical matching against the remaining
reference. Extra continuation after the reference ends is unknown and is never penalized. Output
contains aggregates only, so this tool does not reveal validation phrases, prompts, or predictions.
"""

import argparse
import importlib.util
import json
import pathlib
import sys

# Load the sibling validator directly so CLI and unittest callers share one integrity boundary
# without relying on the working directory or modifying the process's module search path.
_SPEC = importlib.util.spec_from_file_location(
    "phrase_experiment_analysis", pathlib.Path(__file__).with_name("analyze_phrase_experiments.py"))
experiments = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(experiments)


def correct_prefix_length(observation, reference_words):
    """Return a censored run of correct words, anchored to the authoritative first-word score.

    A false Swift score cannot be rescued by searching later in the continuation. If Python and
    Swift disagree about the first word's tokenization, keep Swift's one point but make no claim
    about later alignment. This is deliberately stricter than simply splitting all visible words.
    """
    if "correct" not in observation or not isinstance(observation["correct"], bool):
        raise ValueError("Full reports with authoritative observation.correct are required")
    if not observation["correct"]:
        return 0, False
    shown = observation.get("shown")
    if not isinstance(shown, str) or not shown.strip():
        raise ValueError("A correct observation must include its displayed continuation")
    matches = list(experiments.WORD.finditer(shown))
    first = experiments.diagnostic_word(shown, observation["checkpoint"])
    if not matches or first != experiments.fold(reference_words[0]):
        return 1, True
    length = 1
    for expected, match in zip(reference_words[1:], matches[1:]):
        # A dangling apostrophe/hyphen can still become part of the word. Do not count a prefix
        # fragment such as "word-" as the complete later target "word".
        if match.end() < len(shown) and shown[match.end()] in "'’-":
            break
        if experiments.fold(match.group()) != experiments.fold(expected):
            break
        length += 1
    return length, False


def records(report):
    """Validate phrase-local reference alignment without printing the reference text."""
    indexed = experiments.index_phrases(report)
    result = []
    for (_, condition), phrase in indexed.items():
        reference_words = experiments.WORD.findall(phrase["phrase"]["text"])
        seen = set()
        for observation in phrase["observations"]:
            checkpoint = observation["checkpoint"]
            if checkpoint["typedCharacters"] != 0:
                continue
            index = checkpoint["wordIndex"]
            if type(index) is not int or not 1 <= index < len(reference_words) or index in seen:
                raise ValueError("Invalid or duplicate word-boundary reference index")
            seen.add(index)
            if checkpoint.get("typedWordPrefix", ""):
                raise ValueError("A word-boundary checkpoint cannot contain a typed word prefix")
            if experiments.fold(checkpoint["expectedWord"]) != experiments.fold(reference_words[index]):
                raise ValueError("Checkpoint expected word does not match its reference index")
            remaining = reference_words[index:]
            length, disagreement = correct_prefix_length(observation, remaining)
            result.append({"condition": condition, "category": phrase["phrase"]["category"],
                           "length": length, "remaining": len(remaining),
                           "firstWordParserDisagreement": disagreement})
        if seen != set(range(1, len(reference_words))):
            raise ValueError("Missing zero-letter checkpoints for the complete reference")
    return result


def summarize(values):
    count = len(values)
    if not count:
        raise ValueError("No eligible word-boundary observations")
    probabilities = {}
    for words in (1, 2, 3):
        eligible = [v for v in values if v["remaining"] >= words]
        successes = sum(v["length"] >= words for v in eligible)
        probabilities[str(words)] = {
            "eligibleCheckpoints": len(eligible), "successes": successes,
            "probability": successes / len(eligible) if eligible else None,
        }
    return {"checkpoints": count,
            "meanCorrectPrefixWords": sum(v["length"] for v in values) / count,
            "probabilityPrefixAtLeast": probabilities,
            "firstWordParserDisagreements": sum(v["firstWordParserDisagreement"] for v in values)}


def compare(before, after):
    experiments.validate_pair(before, after)
    old, new = records(before), records(after)
    result = {
        "diagnostic": "strict lexical reference-prefix length from displayed word-boundary continuations",
        "beforeLabel": before["metadata"].get("runLabel"),
        "afterLabel": after["metadata"].get("runLabel"),
        "conditions": {},
        "limitations": [
            "Supplemental lexical diagnostic; the authoritative primary score remains Swift next-word accuracy.",
            "First-word correctness defers to observation.correct; later words use approximate Python tokenization and folding.",
            "Reference-ended continuations are censored: additional output after the reference ends is unknown, not incorrect.",
            "P(prefix >= k) includes only checkpoints with at least k remaining reference words; denominators differ across k.",
            "Mean prefix length is capped by the remaining reference and is comparable only on matching checkpoints.",
            "This is not a semantic-quality judgment, accepted-keystroke measure, or user typing simulation.",
        ],
    }
    for condition in sorted(before["conditions"]):
        rows = {}
        categories = sorted(before["conditions"][condition]["categories"])
        for category in ["suite", *categories]:
            selected = lambda values: [v for v in values if v["condition"] == condition
                                       and (category == "suite" or v["category"] == category)]
            a, b = summarize(selected(old)), summarize(selected(new))
            probability_deltas = {}
            for k, x in a["probabilityPrefixAtLeast"].items():
                y = b["probabilityPrefixAtLeast"][k]
                if x["eligibleCheckpoints"] != y["eligibleCheckpoints"]:
                    raise ValueError("Eligible reference-prefix denominators do not match")
                probability_deltas[k] = (y["probability"] - x["probability"]
                                         if x["probability"] is not None else None)
            rows[category] = {
                "before": a, "after": b,
                "deltaMeanCorrectPrefixWords": b["meanCorrectPrefixWords"] - a["meanCorrectPrefixWords"],
                "deltaProbabilityPrefixAtLeast": probability_deltas,
            }
        result["conditions"][condition] = rows
    return result


def markdown(result):
    lines = ["Supplemental strict lexical prefix diagnostic; not the primary score.", "",
             "| Condition / category | Mean correct-prefix words | P(≥1) | P(≥2) | P(≥3) |",
             "|---|---:|---:|---:|---:|"]
    for condition, rows in result["conditions"].items():
        for category, row in rows.items():
            a, b = row["before"], row["after"]
            cells = []
            for k in ("1", "2", "3"):
                x, y = a["probabilityPrefixAtLeast"][k], b["probabilityPrefixAtLeast"][k]
                cells.append(f"{100*x['probability']:.2f}% → {100*y['probability']:.2f}% (n={x['eligibleCheckpoints']})"
                             if x["eligibleCheckpoints"] else "n/a (n=0)")
            lines.append(f"| {condition} / {category} | {a['meanCorrectPrefixWords']:.3f} → "
                         f"{b['meanCorrectPrefixWords']:.3f} | " + " | ".join(cells) + " |")
    return "\n".join(lines) + "\n\n" + "\n".join(f"- {line}" for line in result["limitations"])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("before", type=pathlib.Path)
    parser.add_argument("after", type=pathlib.Path)
    parser.add_argument("--markdown", action="store_true")
    args = parser.parse_args()
    try:
        result = compare(json.loads(args.before.read_text()), json.loads(args.after.read_text()))
        print(markdown(result) if args.markdown else json.dumps(result, indent=2, sort_keys=True))
    except (OSError, ValueError, KeyError) as error:
        print(f"Analysis failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
