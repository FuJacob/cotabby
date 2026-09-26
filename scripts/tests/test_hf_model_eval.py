"""Prove discovery can select complete, bounded artifacts without executing repository code."""
import argparse
import copy
from pathlib import Path
import sys
import json
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import hf_model_discovery as hf
import model_eval


def repository(name="publisher/tiny-base-GGUF", upstream="maker/tiny-base", digest="b" * 64, size=100):
    return {"id": name, "sha": "a" * 40, "pipeline_tag": "text-generation", "gated": False,
            "tags": ["base_model:" + upstream, "license:apache-2.0"], "cardData": {"language": ["en"]},
            "siblings": [{"rfilename": "tiny-base.Q4_K_M.gguf", "size": size,
                          "lfs": {"sha256": digest, "size": size}}]}


class DiscoveryTests(unittest.TestCase):
    def discover(self, infos, **limits):
        def fetch(url):
            if "/revision/" in url:
                return next(copy.deepcopy(info) for info in infos if "/" + info["id"] + "/" in url)
            return copy.deepcopy(infos)
        return hf.discover(fetch=fetch, **limits)

    def test_revision_hash_size_and_license_are_preserved(self):
        audit = self.discover([repository()])
        entry = audit["models"][0]
        self.assertIn("/resolve/" + "a" * 40 + "/", entry["url"])
        self.assertEqual(entry["sha256"], "b" * 64)
        self.assertEqual(entry["sizeBytes"], 100)
        self.assertEqual(entry["hf"]["licenseTags"], ["license:apache-2.0"])

    def test_chat_ancestry_is_not_mistaken_for_a_base_checkpoint(self):
        for info in (repository("pub/tiny-base-instruct-GGUF"),
                     repository(upstream="maker/tiny-chat"), repository("pub/tiny-GGUF", "maker/tiny")):
            self.assertEqual(self.discover([info])["models"], [])

    def test_gated_nonenglish_nontext_and_invalid_revision_are_skipped(self):
        for change in ({"gated": "auto"}, {"private": True}, {"pipeline_tag": "text-to-image"}, {"pipeline_tag": None},
                       {"cardData": {"language": "pt"}}, {"sha": "main"}):
            audit = self.discover([repository() | change])
            self.assertEqual(audit["models"], [])
            self.assertTrue(audit["decisions"][0]["reason"])

    def test_specialized_image_and_summarizer_names_do_not_pass_text_tag(self):
        for name in ("pub/t5-base-summarization-GGUF", "pub/Ministral-Base-Image-TE-sdcpp-GGUF"):
            self.assertEqual(self.discover([repository(name)])["models"], [])

    def test_size_hash_shards_and_projectors_are_rejected(self):
        for change in ({"size": 2000}, {"lfs": {}},
                       {"rfilename": "tiny-base.Q4_K_M-00001-of-00002.gguf"},
                       {"rfilename": "mmproj-tiny-base.Q4_K_M.gguf"},
                       {"lfs": {"sha256": "b" * 64, "size": 99}}):
            info = repository()
            info["siblings"][0].update(change)
            self.assertEqual(self.discover([info], max_model_bytes=1000)["models"], [])

    def test_quant_preference_and_one_upstream_per_campaign(self):
        info = repository()
        higher = copy.deepcopy(info["siblings"][0])
        higher["rfilename"] = "tiny-base.Q6_K.gguf"
        info["siblings"].insert(0, higher)
        audit = self.discover([info, repository("another/tiny-base-i1-GGUF")])
        self.assertEqual(len(audit["models"]), 1)
        self.assertEqual(audit["models"][0]["hf"]["quantization"], "Q4_K_M")

    def test_count_total_download_and_hash_deduplication(self):
        infos = [repository(), repository("pub/other-base-GGUF", "maker/other-base", "c" * 64)]
        self.assertEqual(len(self.discover(infos, max_candidates=1)["models"]), 1)
        self.assertEqual(len(self.discover(infos, max_download_bytes=150)["models"]), 1)
        infos[1]["siblings"][0]["lfs"]["sha256"] = "b" * 64
        self.assertEqual(len(self.discover(infos)["models"]), 1)

    def test_popular_feed_gets_a_slot_alongside_recent_uploads(self):
        recent = repository()
        popular = repository("pub/popular-base-GGUF", "maker/popular-base", "c" * 64)
        def fetch(url):
            if "/revision/" in url:
                return popular if "popular-base" in url else recent
            return [popular] if "sort=downloads" in url else [recent]
        audit = hf.discover(fetch=fetch, max_candidates=2)
        self.assertEqual(len(audit["models"]), 2)
        self.assertTrue(all("pipeline_tag=text-generation" in row["url"] for row in audit["searches"]))

    def test_exact_baseline_hash_is_excluded(self):
        self.assertEqual(self.discover([repository()], excluded_hashes=["b" * 64])["models"], [])

    def test_empty_discovery_writes_failure_audit_without_starting_inference(self):
        with tempfile.TemporaryDirectory() as directory:
            args = argparse.Namespace(output=Path(directory) / "run", baseline=Path("missing.gguf"),
                                      discovery={"models": [], "searches": [{"error": "offline"}]})
            with mock.patch.object(model_eval, "replay") as replay:
                self.assertEqual(model_eval.run(args, []), 2)
                replay.assert_not_called()
            self.assertEqual(json.loads((args.output / "discovery.json").read_text()), args.discovery)
            self.assertIn("No eligible", (args.output / "qualification.md").read_text())

    def test_detail_revision_drift_never_becomes_download(self):
        info = repository()
        def fetch(url):
            return (info | {"sha": "c" * 40}) if "/revision/" in url else [info]
        audit = hf.discover(fetch=fetch)
        self.assertEqual(audit["models"], [])
        self.assertIn("revision", audit["decisions"][0]["reason"])

    def test_search_errors_are_visible_not_silent_empty_success(self):
        def fetch(url):
            raise OSError("network unavailable")
        audit = hf.discover(fetch=fetch)
        self.assertEqual(audit["models"], [])
        self.assertTrue(all("error" in row for row in audit["searches"]))

    def test_cli_discovery_manifest_is_consumed_by_existing_pipeline(self):
        audit = self.discover([repository()])
        args = argparse.Namespace(manifest=None, models_dir=[], baseline=Path("baseline.gguf"),
                                  discover_hf=True, max_candidates=6, hf_search_limit=120,
                                  max_model_gib=8, max_download_gib=16)
        with mock.patch.object(hf, "discover", return_value=audit):
            self.assertEqual(model_eval.candidates(args), audit["models"])
        self.assertEqual(args.discovery, audit)


if __name__ == "__main__":
    unittest.main()
