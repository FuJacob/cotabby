"""Check eligibility, censoring, and authoritative first-word behavior without inference."""
import copy
import importlib.util
import pathlib
import unittest

SPEC = importlib.util.spec_from_file_location(
    "analyze_completion_prefixes", pathlib.Path(__file__).resolve().parents[1] / "analyze_completion_prefixes.py")
analysis = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(analysis)


def observation(shown, expected, correct):
    return {"checkpoint": {"wordIndex": 1, "typedCharacters": 0, "typedWordPrefix": "",
                           "expectedWord": expected, "prefix": "Start "},
            "shown": shown, "raw": shown or "", "correct": correct, "wasShown": bool(shown)}


def report(text, completions, scores, *, partial=False):
    words = analysis.experiments.WORD.findall(text)
    observations = []
    for index, (shown, correct) in enumerate(zip(completions, scores), start=1):
        o = observation(shown, words[index], correct)
        o["checkpoint"].update(wordIndex=index, prefix=" ".join(words[:index]) + " ")
        observations.append(o)
    if partial:
        extra = copy.deepcopy(observations[0])
        extra["checkpoint"].update(typedCharacters=1, typedWordPrefix=words[1][0])
        observations.insert(1, extra)

    def metrics(values):
        n = len(values)
        correct, shown = sum(o["correct"] for o in values), sum(o["wasShown"] for o in values)
        return dict(checkpoints=n, correct=correct, shown=shown, errors=0,
                    accuracy=correct / n, coverage=shown / n)

    all_metrics = metrics(observations)
    next_metrics = metrics([o for o in observations if o["checkpoint"]["typedCharacters"] == 0])
    phrase = {"phrase": {"id": "science-1", "category": "science", "text": text},
              "condition": "screen", "observations": observations, "all": all_metrics, "nextWord": next_metrics}
    aggregate = {"phraseCount": 1, "all": all_metrics, "nextWord": next_metrics}
    return {"schemaVersion": 2, "errorCount": 0,
            "metadata": {"corpusSHA256": "fixed", "seed": 42,
                         "mode": "character" if partial else "word", "contextMode": "screen"},
            "phrases": [phrase], "conditions": {"screen": {"suite": aggregate, "categories": {"science": aggregate}}}}


class CompletionPrefixTests(unittest.TestCase):
    def test_first_right_second_wrong_stops_before_later_matching_words(self):
        o = observation("alpha wrong gamma", "alpha", True)
        self.assertEqual(analysis.correct_prefix_length(o, ["alpha", "beta", "gamma"]), (1, False))

    def test_first_word_cannot_be_rescored_or_searched_ahead(self):
        for shown in ("alphabet beta", "wrong alpha beta", "alpha beta"):
            o = observation(shown, "alpha", False)
            self.assertEqual(analysis.correct_prefix_length(o, ["alpha", "beta"]), (0, False))
        # Even a Python parsing disagreement cannot overwrite the authoritative first-word hit.
        o = observation("!alpha beta", "alpha", True)
        self.assertEqual(analysis.correct_prefix_length(o, ["alpha", "beta"]), (1, True))

    def test_case_apostrophes_internal_hyphens_and_terminal_punctuation(self):
        o = observation("DON’T, co-op! Tomorrow", "don't", True)
        self.assertEqual(analysis.correct_prefix_length(o, ["don't", "co-op"]), (2, False))
        o = observation("First dont later", "First", True)
        self.assertEqual(analysis.correct_prefix_length(o, ["First", "don't", "later"]), (1, False))
        o = observation("First co-op-", "First", True)
        self.assertEqual(analysis.correct_prefix_length(o, ["First", "co-op"]), (1, False))

    def test_unknown_continuation_after_reference_end_is_not_penalized(self):
        o = observation("alpha beta unrelated extra words", "alpha", True)
        self.assertEqual(analysis.correct_prefix_length(o, ["alpha", "beta"]), (2, False))

    def test_eligibility_changes_near_the_end_of_the_reference(self):
        value = report("Start alpha beta gamma", ["alpha beta wrong", "beta gamma extra", "wrong"], [True, True, False])
        result = analysis.compare(value, value)["conditions"]["screen"]["suite"]["before"]
        self.assertAlmostEqual(result["meanCorrectPrefixWords"], 4 / 3)
        self.assertEqual(result["probabilityPrefixAtLeast"], {
            "1": {"eligibleCheckpoints": 3, "successes": 2, "probability": 2 / 3},
            "2": {"eligibleCheckpoints": 2, "successes": 2, "probability": 1},
            "3": {"eligibleCheckpoints": 1, "successes": 0, "probability": 0}})

    def test_no_eligible_three_word_tail_is_undefined_not_zero(self):
        value = report("Start alpha beta", ["alpha beta", "beta"], [True, True])
        result = analysis.compare(value, value)["conditions"]["screen"]["suite"]
        self.assertIsNone(result["before"]["probabilityPrefixAtLeast"]["3"]["probability"])
        self.assertIsNone(result["deltaProbabilityPrefixAtLeast"]["3"])

    def test_paired_comparison_distinguishes_first_word_and_longer_tail_gains(self):
        before = report("Start alpha beta", ["alpha wrong", "wrong"], [True, False])
        after = report("Start alpha beta", ["alpha beta", "beta extra"], [True, True])
        result = analysis.compare(before, after)["conditions"]["screen"]["suite"]
        self.assertEqual(result["deltaMeanCorrectPrefixWords"], 1)
        self.assertEqual(result["deltaProbabilityPrefixAtLeast"], {"1": .5, "2": 1, "3": None})

    def test_character_partial_checkpoints_do_not_enter_the_diagnostic(self):
        value = report("Start alpha beta", ["alpha beta", "wrong"], [True, False], partial=True)
        result = analysis.compare(value, value)["conditions"]["screen"]["suite"]["before"]
        self.assertEqual(result["checkpoints"], 2)
        self.assertEqual(result["probabilityPrefixAtLeast"]["1"]["probability"], .5)

    def test_bad_reference_indices_and_expected_words_are_rejected(self):
        original = report("Start alpha beta", ["alpha beta", "beta"], [True, True])
        for key, value in (("wordIndex", 0), ("wordIndex", 10), ("expectedWord", "wrong")):
            changed = copy.deepcopy(original)
            changed["phrases"][0]["observations"][0]["checkpoint"][key] = value
            with self.assertRaises(ValueError):
                analysis.records(changed)

    def test_compact_and_mismatched_reports_are_rejected(self):
        before = report("Start alpha beta", ["alpha beta", "beta"], [True, True])
        after = copy.deepcopy(before)
        after["metadata"]["seed"] = 7
        with self.assertRaisesRegex(ValueError, "seed"):
            analysis.compare(before, after)
        for o in before["phrases"][0]["observations"]:
            del o["correct"]
        with self.assertRaisesRegex(ValueError, "Full reports"):
            analysis.records(before)


if __name__ == "__main__":
    unittest.main()
