"""Validate paired experiment uncertainty and diagnostic boundaries without inference."""
import copy
import importlib.util
import pathlib
import unittest

SPEC = importlib.util.spec_from_file_location(
    "analyze_phrase_experiments", pathlib.Path(__file__).resolve().parents[1] / "analyze_phrase_experiments.py")
analysis = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(analysis)


def report(outcomes, *, paired=False, typed_characters=()):
    """Build synthetic outcomes whose phrase clusters and uncertainty are known in advance."""
    def metrics(observations):
        n, correct = len(observations), sum(o["correct"] for o in observations)
        return dict(checkpoints=n, correct=correct, shown=n, errors=0, accuracy=correct / n,
                    coverage=1, precisionWhenShown=correct / n,
                    latencyP50Milliseconds=10, latencyP95Milliseconds=20)

    def summary(phrases):
        observations = [o for p in phrases for o in p["observations"]]
        return {"all": metrics(observations),
                "nextWord": metrics([o for o in observations if o["checkpoint"]["typedCharacters"] == 0]),
                "phraseCount": len(phrases)}

    phrases = []
    conditions = ("none", "screen") if paired else ("screen",)
    for phrase_id, values in outcomes.items():
        for condition in conditions:
            observations = [dict(checkpoint=dict(wordIndex=i + 1, typedCharacters=typed_characters[i] if typed_characters else 0, prefix="A ",
                                                  typedWordPrefix="", expectedWord="word"),
                                 correct=bool(value), raw="word" if value else "wrong", wasShown=True,
                                 shown="word" if value else "wrong", latencyMilliseconds=10)
                            for i, value in enumerate(values)]
            phrases.append(dict(phrase=dict(id=phrase_id, category=phrase_id.split("-")[0]),
                                condition=condition, observations=observations,
                                all=metrics(observations), nextWord=metrics([
                                    o for o in observations if o["checkpoint"]["typedCharacters"] == 0])))
    aggregates = {}
    for condition in conditions:
        selected = [p for p in phrases if p["condition"] == condition]
        categories = {p["phrase"]["category"] for p in selected}
        aggregates[condition] = dict(suite=summary(selected), categories={
            c: summary([p for p in selected if p["phrase"]["category"] == c]) for c in categories})
    return dict(schemaVersion=2, errorCount=0, metadata=dict(corpusSHA256="fixed", mode="character" if typed_characters else "word",
                contextMode="paired" if paired else "screen", seed=42), phrases=phrases, conditions=aggregates)


class PhraseExperimentAnalysisTests(unittest.TestCase):
    def test_identical_runs_have_zero_delta_and_zero_width_interval(self):
        value = report({"science-1": [0, 1, 0], "science-2": [1, 0], "work-1": [1]})
        result = analysis.compare(value, copy.deepcopy(value), samples=100)
        self.assertEqual(result["bootstrap"]["accuracyDeltaIntervals"]["screen/suite"], [0, 0])
        self.assertEqual(result["deltas"]["screen"]["suite"]["transitions"]["improved"], 0)

    def test_whole_phrase_sampling_preserves_correlated_checkpoints(self):
        before = report({"science-1": [0] * 10, "science-2": [0] * 10})
        after = report({"science-1": [1] * 10, "science-2": [0] * 10})
        result = analysis.compare(before, after, samples=1000, seed=42)
        # There are two independent phrase clusters, not twenty independent checkpoints.
        self.assertEqual(result["bootstrap"]["accuracyDeltaIntervals"]["screen/suite"], [0, 1])
        self.assertEqual(result["deltas"]["screen"]["suite"]["accuracy"], .5)

    def test_category_stratification_keeps_each_category_represented(self):
        before = report({"science-1": [0], "work-1": [0] * 9})
        after = report({"science-1": [1], "work-1": [0] * 9})
        result = analysis.compare(before, after, samples=100)
        self.assertEqual(result["bootstrap"]["accuracyDeltaIntervals"]["screen/suite"], [.1, .1])

    def test_shared_condition_draws_preserve_identical_context_lift(self):
        before = report({"science-1": [0, 0], "science-2": [0, 0]}, paired=True)
        after = report({"science-1": [1, 1], "science-2": [0, 0]}, paired=True)
        result = analysis.compare(before, after, samples=200, seed=19)
        self.assertEqual(result["bootstrap"]["accuracyDeltaIntervals"]["contextLift"], [0, 0])
        self.assertEqual(result, analysis.compare(before, after, samples=200, seed=19))

    def test_mismatches_and_incomplete_reports_are_rejected(self):
        before = report({"science-1": [0, 1]})
        changes = [lambda r: r["metadata"].update(seed=7),
                   lambda r: r["phrases"][0]["observations"][0]["checkpoint"].update(expectedWord="other"),
                   lambda r: r["phrases"].append(r["phrases"][0]),
                   lambda r: r["phrases"][0]["observations"].pop(),
                   lambda r: r.update(errorCount=1)]
        for mutate in changes:
            after = copy.deepcopy(before)
            mutate(after)
            with self.assertRaises(ValueError):
                analysis.compare(before, after, samples=100)

    def test_compact_baseline_preserves_cluster_comparison_without_fake_diagnostics(self):
        before = report({"science-1": [0, 1]})
        after = report({"science-1": [1, 1]})
        for phrase in before["phrases"]:
            phrase["observations"] = [{"checkpoint": o["checkpoint"]} for o in phrase["observations"]]
        result = analysis.compare(before, after, samples=100)
        self.assertEqual(result["bootstrap"]["accuracyDeltaIntervals"]["screen/suite"], [.5, .5])
        self.assertEqual(result["before"]["conditions"]["screen"]["diagnostics"], {})
        self.assertEqual(result["deltas"]["screen"]["suite"]["transitions"], {})

    def test_diagnostic_word_respects_the_caret_and_punctuation(self):
        partial = dict(typedWordPrefix="sched")
        self.assertEqual(analysis.diagnostic_word("ule later", partial), "schedule")
        self.assertIsNone(analysis.diagnostic_word(" ule later", partial))
        self.assertIsNone(analysis.diagnostic_word(".word", {}))
        self.assertIsNone(analysis.diagnostic_word("word-", {}))
        self.assertEqual(analysis.diagnostic_word(" Don’t worry", {}), "don't")

    def test_suppression_audit_does_not_replace_authoritative_score(self):
        value = report({"science-1": [0]})
        o = value["phrases"][0]["observations"][0]
        o.update(raw="word", shown=None, wasShown=False, suppression="seam-guard")
        # Update only shown counts; correctness remains the original Swift-authoritative miss.
        for metric in ("all", "nextWord"):
            value["phrases"][0][metric]["shown"] = 0
            value["conditions"]["screen"]["suite"][metric]["shown"] = 0
        result = analysis.audit(value)
        self.assertEqual(result["conditions"]["screen"]["diagnostics"]["rawCorrectDisplayIncorrectApproximate"], 1)
        self.assertEqual(result["conditions"]["screen"]["suite"]["nextWord"]["correct"], 0)

    def test_too_few_bootstrap_samples_are_rejected(self):
        value = report({"science-1": [0, 1]})
        with self.assertRaises(ValueError):
            analysis.compare(value, value, samples=1)

    def test_character_metric_changes_denominator_and_transition_population(self):
        before = report({"science-1": [1, 0, 0]}, typed_characters=(0, 1, 2))
        after = report({"science-1": [0, 1, 1]}, typed_characters=(0, 1, 2))
        boundary = analysis.compare(before, after, samples=100)
        all_points = analysis.compare(before, after, samples=100, metric="all")
        self.assertEqual(boundary["metric"], "nextWord")
        self.assertEqual(boundary["bootstrap"]["accuracyDeltaIntervals"]["screen/suite"], [-1, -1])
        self.assertEqual(boundary["deltas"]["screen"]["suite"]["transitions"], {
            "pairedObservationsAvailable": 1, "improved": 0, "regressed": 1})
        self.assertEqual(all_points["metric"], "all")
        self.assertEqual(all_points["bootstrap"]["metric"], "all")
        self.assertEqual(all_points["bootstrap"]["accuracyDeltaIntervals"]["screen/suite"], [1 / 3, 1 / 3])
        self.assertAlmostEqual(all_points["deltas"]["screen"]["suite"]["accuracy"], 1 / 3)
        self.assertEqual(all_points["deltas"]["screen"]["suite"]["transitions"], {
            "pairedObservationsAvailable": 3, "improved": 2, "regressed": 1})
        self.assertEqual(boundary["after"]["conditions"]["screen"]["diagnostics"]["observationsAvailable"], 1)
        self.assertEqual(all_points["after"]["conditions"]["screen"]["diagnostics"]["observationsAvailable"], 3)
        self.assertIn("all (every recorded checkpoint)", analysis.markdown(all_points))

    def test_all_metric_context_lift_uses_all_checkpoint_scores(self):
        value = report({"science-1": [0, 0, 0]}, paired=True, typed_characters=(0, 1, 2))
        screen = report({"science-1": [0, 1, 1]}, paired=True, typed_characters=(0, 1, 2))
        value["phrases"][1] = screen["phrases"][1]
        value["conditions"]["screen"] = screen["conditions"]["screen"]
        # Existing v2 contextLift is specifically the zero-letter score; it must not leak into all.
        value["contextLift"] = {"suiteAccuracyDelta": 0}
        self.assertEqual(analysis.audit(value)["contextLift"]["suiteAccuracyDelta"], 0)
        all_points = analysis.audit(value, metric="all")
        self.assertAlmostEqual(all_points["contextLift"]["suiteAccuracyDelta"], 2 / 3)
        self.assertEqual(all_points["contextLift"]["improvedCheckpoints"], 2)
        self.assertEqual(all_points["contextLift"]["regressedCheckpoints"], 0)

    def test_invalid_metric_is_rejected_in_library_entrypoints(self):
        value = report({"science-1": [0, 1]})
        with self.assertRaisesRegex(ValueError, "Metric"):
            analysis.compare(value, value, samples=100, metric="partial")
        with self.assertRaisesRegex(ValueError, "Metric"):
            analysis.audit(value, metric="partial")


if __name__ == "__main__":
    unittest.main()
