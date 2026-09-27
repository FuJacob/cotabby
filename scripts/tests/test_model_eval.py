"""Exercise qualification gates and campaign failure isolation without model-sized downloads."""
import argparse
import copy
import json
import io
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import model_eval


def report():
    metric = {"accuracy": .4, "coverage": .8, "latencyP95Milliseconds": 200}
    suite = {"nextWord": dict(metric), "all": dict(metric)}
    phrase = {"phrase": {"id": "a"}, "condition": "none", "observations": [{"checkpoint": 1}],
              "nextWord": dict(metric)}
    return {"schemaVersion": 2, "metadata": {"corpusSHA256": "corpus", "mode": "word", "seed": 42,
            "contextMode": "paired", "workerCount": 1, "configuration": {"modelSHA256": "baseline"}},
            "conditions": {c: {"suite": copy.deepcopy(suite), "categories": {}}
                           for c in ("none", "screen")}, "phrases": [phrase], "errorCount": 0}


def policy():
    return argparse.Namespace(max_accuracy_drop_pp=1, max_coverage_drop_pp=5, max_p95_ms=500, max_category_drop_pp=5)


class GateTests(unittest.TestCase):
    def test_equivalent_scores_with_different_models_pass(self):
        candidate = report()
        candidate["metadata"]["configuration"]["modelSHA256"] = "candidate"
        self.assertTrue(model_eval.evaluate(report(), candidate, policy())["passed"])

    def test_regressions_in_either_context_or_midword_fail(self):
        for condition in ("none", "screen"):
            for scope in ("all", "nextWord"):
                for field, value in (("accuracy", .1), ("coverage", .1), ("latencyP95Milliseconds", 600)):
                    candidate = report()
                    candidate["conditions"][condition]["suite"][scope][field] = value
                    self.assertFalse(model_eval.evaluate(report(), candidate, policy())["passed"])

    def test_smoke_does_not_reject_noisy_small_sample_accuracy(self):
        candidate = report()
        candidate["conditions"]["none"]["suite"]["nextWord"]["accuracy"] = 0
        self.assertTrue(model_eval.evaluate(report(), candidate, policy(), smoke=True)["passed"])

    def test_category_regression_cannot_hide_in_good_aggregate(self):
        baseline, candidate = report(), report()
        baseline["conditions"]["none"]["categories"]["work"] = {"nextWord": {"accuracy": .5}}
        candidate["conditions"]["none"]["categories"]["work"] = {"nextWord": {"accuracy": .3}}
        self.assertFalse(model_eval.evaluate(baseline, candidate, policy())["passed"])

    def test_missing_nonfinite_and_incomparable_evidence_never_pass(self):
        for mutate in (
            lambda r: r.update(errorCount=1),
            lambda r: r["metadata"].update(seed=99),
            lambda r: r["metadata"].update(workerCount=3),
            lambda r: r["metadata"]["configuration"].update(temperature=.9),
            lambda r: r["conditions"]["none"]["suite"]["all"].pop("accuracy"),
            lambda r: r["conditions"]["screen"]["suite"]["nextWord"].update(accuracy=float("nan")),
            lambda r: r.update(phrases=[]),
        ):
            candidate = report()
            mutate(candidate)
            with self.assertRaises(ValueError):
                model_eval.evaluate(report(), candidate, policy())


class AcquisitionTests(unittest.TestCase):
    def test_header_size_and_hash_checks(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = root / "test.gguf"
            path.write_bytes(b"GGUFtest")
            entry = {"path": str(path)}
            self.assertEqual(model_eval.acquire(entry, root, 8)[1], model_eval.sha256(path))
            for change, limit in (({"sha256": "bad"}, 8), ({}, 7)):
                with self.assertRaises(ValueError):
                    model_eval.acquire(entry | change, root, limit)
            path.write_bytes(b"HTMLtest")
            with self.assertRaises(ValueError):
                model_eval.acquire(entry, root, 8)

    def test_manifest_downloads_require_integrity_and_safe_ids(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "manifest.json"
            args = argparse.Namespace(manifest=path, models_dir=[], baseline=Path("baseline.gguf"))
            for entry in ({"id": "../escape", "path": "x.gguf"},
                          {"id": "x", "url": "https://example.org/x.gguf"},
                          {"id": "x", "url": "http://example.org/x.gguf", "sha256": "a" * 64}):
                path.write_text(json.dumps({"models": [entry]}))
                with self.assertRaises(ValueError):
                    model_eval.candidates(args)

    def test_download_integrity_failure_removes_partial_file(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            entry = {"id": "new", "url": "https://example.org/new.gguf", "sha256": "a" * 64}
            response = io.BytesIO(b"GGUFtest")
            response.geturl = lambda: entry["url"]
            with mock.patch.object(model_eval.urllib.request, "urlopen", return_value=response):
                with self.assertRaisesRegex(ValueError, "SHA-256 mismatch"):
                    model_eval.acquire(entry, root, 100)
            self.assertEqual(list(root.iterdir()), [])

    def test_folder_discovery_excludes_baseline(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in ("baseline.gguf", "new.gguf", "ignored.txt"):
                (root / name).touch()
            args = argparse.Namespace(manifest=None, models_dir=[root], baseline=root / "baseline.gguf")
            self.assertEqual([e["id"] for e in model_eval.candidates(args)], ["new"])

    def test_timeout_terminates_process_group(self):
        with tempfile.TemporaryDirectory() as directory:
            with mock.patch.object(model_eval.subprocess, "Popen") as popen, mock.patch.object(model_eval.os, "killpg") as kill:
                process = popen.return_value
                process.pid = 123
                process.wait.side_effect = [subprocess.TimeoutExpired("test", 1), 0]
                with self.assertRaises(subprocess.TimeoutExpired):
                    model_eval.launch(["test"], Path(directory) / "log", 1)
                kill.assert_called_once_with(123, model_eval.signal.SIGTERM)


class CampaignTests(unittest.TestCase):
    def campaign(self, root):
        args = policy()
        args.output = root / "results"
        args.baseline = root / "baseline.gguf"
        args.max_model_gib = 1
        args.workspace = None
        args.timeout_seconds = 1
        return args

    def test_failed_candidate_does_not_prevent_next_candidate_qualification(self):
        with tempfile.TemporaryDirectory() as directory:
            args = self.campaign(Path(directory))
            def acquire(entry, *_):
                path = Path(directory) / (entry["id"] + ".gguf")
                path.write_bytes(b"GGUF")
                return path, entry["id"]
            def replay(entry, *_):
                if entry["id"] == "broken":
                    raise RuntimeError("unsupported architecture")
                return report()
            with mock.patch.object(model_eval, "acquire", side_effect=acquire), \
                    mock.patch.object(model_eval, "replay", side_effect=replay) as runner:
                self.assertEqual(model_eval.run(args, [{"id": "broken"}, {"id": "good"}]), 0)
            results = json.loads((args.output / "qualification.json").read_text())
            self.assertEqual([r["status"] for r in results["models"]], ["failed", "qualified"])
            self.assertEqual(len(results["models"][1]["stages"]), 4)
            baseline_calls = [call for call in runner.call_args_list if call.args[0]["id"] == "baseline"]
            self.assertEqual(len(baseline_calls), 4)

    def test_replay_adapter_pins_settings_and_checks_model_identity(self):
        with tempfile.TemporaryDirectory() as directory:
            args = self.campaign(Path(directory))
            args.output.mkdir()
            args.workspace = Path(directory) / "local.xcworkspace"
            evidence = report()
            evidence["metadata"]["configuration"]["modelSHA256"] = "digest"
            def launch(command, log, timeout):
                self.assertIn("--skip-build", command)
                self.assertEqual(command[command.index("--workers") + 1], "1")
                self.assertEqual(command[command.index("--mode") + 1], "character")
                self.assertEqual(command[command.index("--split") + 1], "heldout")
                self.assertEqual(command[command.index("--context") + 1], "paired")
                run = Path(command[command.index("--output") + 1])
                run.mkdir()
                (run / "report.json").write_text(json.dumps(evidence))
            with mock.patch.object(model_eval, "launch", side_effect=launch):
                result = model_eval.replay({"id": "new"}, args.baseline, "digest", model_eval.STAGES[3], args, True)
                self.assertEqual(result, evidence)
                with self.assertRaisesRegex(ValueError, "identity"):
                    model_eval.replay({"id": "wrong"}, args.baseline, "other", model_eval.STAGES[3], args, True)

    def test_baseline_failure_blocks_campaign(self):
        with tempfile.TemporaryDirectory() as directory:
            args = self.campaign(Path(directory))
            args.baseline.write_bytes(b"GGUFbaseline")
            candidate = Path(directory) / "new.gguf"
            candidate.write_bytes(b"GGUFnew")
            with mock.patch.object(model_eval, "replay", side_effect=RuntimeError("build failed")):
                self.assertEqual(model_eval.run(args, [{"id": "new", "path": str(candidate)}]), 2)
            result = json.loads((args.output / "qualification.json").read_text())
            self.assertEqual(result["models"][0]["status"], "blocked-baseline")


if __name__ == "__main__":
    unittest.main()
