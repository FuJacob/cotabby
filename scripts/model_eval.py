#!/usr/bin/env python3
"""Automate model qualification using the production phrase replay, never a second scorer.

This process owns candidate acquisition, sequential scheduling and policy decisions. The existing
phrase_eval CLI owns build integrity and Swift owns inference/scoring. Every invocation creates
immutable evidence; a failed or missing stage can never become an inclusion recommendation.
"""
import argparse
import hashlib
import fcntl
import json
import math
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import urllib.request

import phrase_eval
import hf_model_discovery

ROOT = Path(__file__).resolve().parents[1]
# Screening and validation use disjoint phrase IDs. Character validation also exercises prefixes
# inside a word, where a model may load successfully yet produce unusable autocomplete seams.
STAGES = [
    ("smoke", "word", "screen", 2),
    ("screen", "word", "screen", 20),
    ("heldout", "word", "heldout", None),
    ("midword", "character", "heldout", 10),
]


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def candidates(args):
    """Resolve explicit manifest paths relative to that manifest, and discover folders in order."""
    entries = []
    if args.manifest:
        entries = json.loads(args.manifest.read_text())["models"]
        for entry in entries:
            if "path" in entry:
                entry["path"] = str((args.manifest.resolve().parent / entry["path"]).resolve())
    for directory in args.models_dir:
        for path in sorted(directory.resolve().glob("*.gguf")):
            if path.resolve() != args.baseline.resolve():
                entries.append({"id": path.stem, "path": str(path.resolve())})
    if getattr(args, "discover_hf", False):
        args.discovery = hf_model_discovery.discover(
            max_candidates=args.max_candidates, max_repositories=args.hf_search_limit,
            max_model_bytes=int(args.max_model_gib * 1024**3),
            max_download_bytes=int(args.max_download_gib * 1024**3),
            excluded_hashes=[sha256(args.baseline)] if args.baseline.is_file() else [])
        entries.extend(args.discovery["models"])
    seen = set()
    for entry in entries:
        name = entry.get("id", "")
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,120}", name) or name in seen or name == "baseline":
            raise ValueError(f"Invalid, reserved or duplicate model id: {name!r}")
        seen.add(name)
        if ("path" in entry) == ("url" in entry):
            raise ValueError(f"{name}: supply exactly one path or URL")
        if "url" in entry and (not entry["url"].startswith("https://") or
                                not re.fullmatch(r"[a-f0-9]{64}", entry.get("sha256", ""))):
            raise ValueError(f"{name}: downloads require HTTPS and a lowercase SHA-256")
    if not entries and not getattr(args, "discover_hf", False):
        raise ValueError("No candidate GGUFs found; supply --models-dir or --manifest")
    return entries


def acquire(entry, output, max_bytes):
    """Bound downloads and verify bytes before inference; partial files never become models."""
    if "path" in entry:
        path = Path(entry["path"])
    else:
        max_bytes = min(max_bytes, entry.get("sizeBytes", max_bytes))
        path = output / (entry["id"] + ".gguf")
        partial = path.with_suffix(".partial")
        try:
            with urllib.request.urlopen(entry["url"], timeout=60) as response, partial.open("xb") as stream:
                if not response.geturl().startswith("https://"):
                    raise ValueError("Download redirected away from HTTPS")
                size = 0
                while block := response.read(1024 * 1024):
                    size += len(block)
                    if size > max_bytes:
                        raise ValueError("Download exceeds model file budget")
                    stream.write(block)
            if sha256(partial) != entry["sha256"]:
                raise ValueError("Downloaded model SHA-256 mismatch")
            partial.rename(path)
        finally:
            partial.unlink(missing_ok=True)
    if path.suffix.lower() != ".gguf" or not path.is_file() or path.stat().st_size > max_bytes:
        raise ValueError("Model missing, not GGUF, or exceeds model file budget")
    with path.open("rb") as stream:
        if stream.read(4) != b"GGUF":
            raise ValueError("Model has no GGUF header (possibly an HTML error page)")
    digest = sha256(path)
    if entry.get("sha256", digest) != digest:
        raise ValueError("Model SHA-256 mismatch")
    if entry.get("sizeBytes", path.stat().st_size) != path.stat().st_size:
        raise ValueError("Model size differs from discovered metadata")
    return path.resolve(), digest


def launch(command, log, timeout):
    """Kill the entire build/test process group on timeout so the next model has an idle GPU."""
    with log.open("w") as stream:
        process = subprocess.Popen(command, cwd=ROOT, stdout=stream, stderr=subprocess.STDOUT,
                                   start_new_session=True)
        try:
            code = process.wait(timeout=timeout)
        except BaseException:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
            raise
    if code:
        raise RuntimeError(f"Replay exited {code}; inspect {log}")


def evaluate(baseline, candidate, args, *, smoke=False):
    """Fail closed on incomparable or undefined evidence; thresholds are explicit policy."""
    phrase_eval.comparison_rows(baseline, candidate)
    for report in (baseline, candidate):
        if report["metadata"].get("workerCount") != 1 or set(report["conditions"]) != {"none", "screen"}:
            raise ValueError("Qualification requires paired context and one worker")
    old_config = dict(baseline["metadata"]["configuration"])
    new_config = dict(candidate["metadata"]["configuration"])
    old_config.pop("modelSHA256", None)
    new_config.pop("modelSHA256", None)
    if old_config != new_config:
        raise ValueError("Generation configuration changed between models")
    reasons, metrics = [], {}
    for condition in ("none", "screen"):
        metrics[condition] = {}
        # In character mode 'all' includes partially typed words; nextWord alone misses that risk.
        for scope in ("nextWord", "all"):
            old = baseline["conditions"][condition]["suite"][scope]
            new = candidate["conditions"][condition]["suite"][scope]
            values = [old.get("accuracy"), new.get("accuracy"), old.get("coverage"), new.get("coverage"),
                      new.get("latencyP95Milliseconds")]
            if any(not isinstance(v, (int, float)) or not math.isfinite(v) for v in values):
                raise ValueError(f"Missing/nonfinite metrics: {condition}/{scope}")
            accuracy_delta = 100 * (new["accuracy"] - old["accuracy"])
            coverage_delta = 100 * (new["coverage"] - old["coverage"])
            metrics[condition][scope] = {"accuracyDeltaPP": accuracy_delta, "coverageDeltaPP": coverage_delta,
                                         "p95Milliseconds": new["latencyP95Milliseconds"]}
            if not smoke and accuracy_delta < -args.max_accuracy_drop_pp:
                reasons.append(f"{condition}/{scope}: accuracy regression {accuracy_delta:.2f} pp")
            if not smoke and coverage_delta < -args.max_coverage_drop_pp:
                reasons.append(f"{condition}/{scope}: coverage regression {coverage_delta:.2f} pp")
            if new["coverage"] <= 0:
                reasons.append(f"{condition}/{scope}: no usable suggestions")
            if new["latencyP95Milliseconds"] > args.max_p95_ms:
                reasons.append(f"{condition}/{scope}: p95 exceeds {args.max_p95_ms:g} ms")
        if not smoke:
            for category, old_category in baseline["conditions"][condition]["categories"].items():
                new_category = candidate["conditions"][condition]["categories"][category]
                old_accuracy = old_category["nextWord"].get("accuracy")
                new_accuracy = new_category["nextWord"].get("accuracy")
                if any(not isinstance(v, (int, float)) or not math.isfinite(v) for v in (old_accuracy, new_accuracy)):
                    raise ValueError(f"Missing category evidence: {category}")
                delta = 100 * (new_accuracy - old_accuracy)
                if delta < -args.max_category_drop_pp:
                    reasons.append(f"{condition}/{category}: accuracy regression {delta:.2f} pp")
    return {"passed": not reasons, "reasons": reasons, "metrics": metrics}


def replay(entry, path, digest, stage, args, reuse):
    name, mode, split, count = stage
    run = args.output / entry["id"] / name
    run.parent.mkdir(exist_ok=True)
    command = [sys.executable, str(ROOT / "scripts/phrase_eval.py"), "run", "--model", str(path),
               "--output", str(run), "--label", entry["id"] + "-" + name, "--mode", mode,
               "--context", "paired", "--workers", "1", "--seed", "42", "--split", split,
               "--split-seed", "1337", "--screen-per-category", "20"]
    if count:
        command += ["--per-category", str(count)]
    if args.workspace:
        command += ["--workspace", str(args.workspace.resolve())]
    if reuse:
        command += ["--skip-build"]
    print(f"Evaluating {entry['id']}: {name}; log: {run.parent / (name + '.log')}", flush=True)
    launch(command, run.parent / (name + ".log"), args.timeout_seconds)
    report = json.loads((run / "report.json").read_text())
    if report["metadata"]["configuration"]["modelSHA256"] != digest:
        raise ValueError("Replay model identity does not match acquired model")
    return report


def save(args, result):
    # Atomic replacement keeps a partial campaign inspectable after interruption.
    path = args.output / "qualification.json"
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(result, indent=2, allow_nan=False) + "\n")
    temporary.replace(path)
    lines = ["# Model qualification", "", "Synthetic English autocomplete; same-machine latency. "
             "Passing is benchmark qualification, not automatic catalog publication.", ""]
    if result.get("error"):
        lines.append(result["error"])
    for item in result["models"]:
        lines.append(f"- **{item['id']}**: {item['status']}")
        for stage, outcome in item.get("stages", {}).items():
            lines.append(f"  - {stage}: " + ("passed" if outcome["passed"] else "; ".join(outcome["reasons"])))
            for condition, scopes in outcome.get("metrics", {}).items():
                metric = scopes["all"]
                lines.append(f"    - {condition}: accuracy {metric['accuracyDeltaPP']:+.2f} pp; "
                             f"coverage {metric['coverageDeltaPP']:+.2f} pp; p95 {metric['p95Milliseconds']:.0f} ms")
        if item.get("error"):
            lines.append(f"  - {item['error']}")
    (args.output / "qualification.md").write_text("\n".join(lines) + "\n")


def run(args, entries):
    args.output.mkdir(parents=True, exist_ok=False)
    downloads = args.output / "models"
    downloads.mkdir()
    result = {"version": 1, "policy": {key: value for key, value in vars(args).items()
               if isinstance(value, (int, float, str, bool))}, "candidates": entries, "models": [],
              "baseline": str(args.baseline.resolve()), "stages": STAGES}
    if getattr(args, "discovery", None) is not None:
        (args.output / "discovery.json").write_text(json.dumps(args.discovery, indent=2) + "\n")
        result["discoveryReport"] = "discovery.json"
    save(args, result)
    if not entries:
        result["error"] = "No eligible Hugging Face candidates; inspect discovery.json for search failures or skips"
        save(args, result)
        return 2
    baseline_entry = {"id": "baseline", "path": str(args.baseline.resolve())}
    max_bytes = int(args.max_model_gib * 1024 ** 3)
    baseline_path, baseline_hash = acquire(baseline_entry, downloads, max_bytes)
    result["baselineSHA256"] = baseline_hash
    baseline_reports = {}
    reuse = False
    for entry in entries:
        item = {"id": entry["id"], "status": "running", "stages": {}}
        result["models"].append(item)
        save(args, result)
        try:
            path, digest = acquire(entry, downloads, max_bytes)
            item.update(sha256=digest, sizeBytes=path.stat().st_size)
            if digest == baseline_hash:
                raise ValueError("Candidate is identical to baseline; provide a different model")
            for stage in STAGES:
                name = stage[0]
                if name not in baseline_reports:
                    # Infrastructure/baseline failures abort the campaign, not reject every model.
                    try:
                        baseline_reports[name] = replay(baseline_entry, baseline_path, baseline_hash, stage, args, reuse)
                        reuse = True
                    except Exception as error:
                        item["status"] = "blocked-baseline"
                        item["error"] = str(error)
                        save(args, result)
                        return 2
                report = replay(entry, path, digest, stage, args, reuse)
                outcome = evaluate(baseline_reports[name], report, args, smoke=name == "smoke")
                item["stages"][name] = outcome
                save(args, result)
                if not outcome["passed"]:
                    item["status"] = "rejected"
                    break
            else:
                item["status"] = "qualified"
        except Exception as error:
            item["status"] = "failed"
            item["error"] = f"{type(error).__name__}: {error}"
        except KeyboardInterrupt:
            item["status"] = "interrupted"
            save(args, result)
            raise
        save(args, result)
    return 0 if any(item["status"] == "qualified" for item in result["models"]) else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", required=True, type=Path)
    parser.add_argument("--models-dir", action="append", default=[], type=Path)
    parser.add_argument("--manifest", type=Path)
    parser.add_argument("--discover-hf", action="store_true", help="Discover public Hugging Face base GGUFs; automatic when no local sources are supplied")
    parser.add_argument("--max-candidates", type=int, default=6)
    parser.add_argument("--hf-search-limit", type=int, default=120, help="Maximum repository metadata inspections")
    parser.add_argument("--max-download-gib", type=float, default=16, help="Total planned Hugging Face discovery downloads")
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--workspace", type=Path)
    parser.add_argument("--plan", action="store_true", help="Inspect candidates and stages without downloads or inference")
    parser.add_argument("--max-model-gib", type=float, default=8)
    parser.add_argument("--max-p95-ms", type=float, default=500)
    parser.add_argument("--max-accuracy-drop-pp", type=float, default=1)
    parser.add_argument("--max-coverage-drop-pp", type=float, default=5)
    parser.add_argument("--max-category-drop-pp", type=float, default=5)
    parser.add_argument("--timeout-seconds", type=float, default=14400, help="Maximum time per replay including build")
    args = parser.parse_args()
    args.discover_hf = args.discover_hf or (not args.manifest and not args.models_dir)
    if not 1 <= args.max_candidates <= 100 or not 1 <= args.hf_search_limit <= 1000:
        parser.error("Candidate count must be 1–100 and search limit 1–1000")
    for key in ("max_download_gib", "max_model_gib", "max_p95_ms", "timeout_seconds", "max_accuracy_drop_pp", "max_coverage_drop_pp", "max_category_drop_pp"):
        value = getattr(args, key)
        if not math.isfinite(value) or value < 0 or (key not in ("max_accuracy_drop_pp", "max_coverage_drop_pp", "max_category_drop_pp") and value == 0):
            parser.error(f"Invalid {key}")
    args.output = args.output.resolve()
    try:
        entries = candidates(args)
        if args.plan:
            print(json.dumps({"baseline": str(args.baseline), "candidates": entries, "stages": STAGES, "discovery": getattr(args, "discovery", None)}, indent=2))
            return 0
        # Campaigns share a native build and GPU. An advisory lock prevents this CLI from
        # racing itself; unrelated apps/build tools must still be kept idle by the operator.
        lock_path = ROOT / "build/model-eval.lock"
        lock_path.parent.mkdir(exist_ok=True)
        with lock_path.open("a") as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise ValueError("Another model qualification campaign is already running")
            return run(args, entries)
    except (ValueError, OSError, KeyError) as error:
        parser.error(str(error))


if __name__ == "__main__":
    sys.exit(main())
