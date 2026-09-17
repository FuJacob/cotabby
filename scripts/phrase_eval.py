#!/usr/bin/env python3
"""Plan, run, and compare Cotabby's fixed local next-word benchmark.

Swift owns replay and scoring. This standard-library CLI only selects inputs, launches the
app-hosted test with explicit environment settings, and compares its versioned JSON reports.
"""
import argparse
import collections
import copy
import datetime
import hashlib
import json
import math
import os
import pathlib
import platform
import plistlib
import re
import signal
import subprocess
import sys
import time
import uuid

ROOT = pathlib.Path(__file__).resolve().parents[1]
CORPUS = ROOT / "CotabbyTests/Fixtures/phrase-prediction-1337.json"
DERIVED = ROOT / "build/DerivedData"
BASELINES = ROOT / "benchmarks/phrase-prediction"
CATEGORIES = ("conversation", "science", "entertainment", "work", "technology", "everyday", "travel")
WORD = re.compile(r"[^\W_]+(?:['’\-][^\W_]+)*", re.UNICODE)


def read_selection(args):
    corpus = json.loads(CORPUS.read_text())
    phrases = corpus["phrases"]
    if (corpus["version"] != 2 or corpus["language"] != "en"
            or len(phrases) != 1337
            or len({p["id"] for p in phrases}) != 1337
            or len({p["text"].strip().lower() for p in phrases}) != 1337
            or collections.Counter(p["category"] for p in phrases) != dict.fromkeys(CATEGORIES, 191)
            or any(len(WORD.findall(p["text"])) < 3 for p in phrases)):
        raise ValueError("Invalid corpus: expected 1337 unique phrases, 191 per category, at least three words each")
    screens = [p.get("scenario", {}).get("screenText", "") for p in phrases]
    if len(set(screens)) != 1337 or any(len(screen) < 40 or len(screen) > 4000 for screen in screens):
        raise ValueError("Every phrase requires a distinct bounded screen scenario")
    folded = lambda text: " ".join(WORD.findall(text.lower()))
    for phrase in phrases:
        scene = phrase["scenario"]
        if folded(phrase["text"]) in folded(scene["screenText"] + " " + scene["documentPrefix"]):
            raise ValueError(f"Reference sentence leaked into screen context: {phrase['id']}")
    selected = [p for p in phrases if (not args.category or p["category"] == args.category)
                and (not args.phrase or p["id"] == args.phrase)]
    per_category = getattr(args, "per_category", None)
    if per_category is not None:
        if per_category < 1:
            raise ValueError("--per-category must be positive")
        counts = collections.Counter()
        balanced = []
        for phrase in selected:
            counts[phrase["category"]] += 1
            if counts[phrase["category"]] <= per_category:
                balanced.append(phrase)
        selected = balanced
    if args.limit is not None:
        if args.limit < 1:
            raise ValueError("--limit must be positive")
        selected = selected[:args.limit]
    if not selected:
        raise ValueError("No phrases match the selection")
    return corpus, selected


def checkpoint_counts(phrases, mode, context):
    """Share the workload denominator between planning and live progress."""
    counts = collections.Counter()
    for phrase in phrases:
        words = WORD.findall(phrase["text"])[1:]
        counts[phrase["category"]] += (len(words) if mode == "word" else sum(map(len, words))) * (2 if context == "paired" else 1)
    return counts


def show_plan(args):
    _, phrases = read_selection(args)
    context = getattr(args, "context", "paired")
    counts = checkpoint_counts(phrases, args.mode, context)
    print(f"{len(phrases)} phrases; {sum(counts.values()):,} prediction checkpoints; mode={args.mode}; context={context}")
    for category, count in sorted(counts.items()):
        print(f"  {category}: {count:,} checkpoints")
    print("Primary score: exact next word before its first letter; suppressed output is a miss.")
    return phrases


def git_output(*arguments):
    return subprocess.check_output(["git", *arguments], cwd=ROOT, text=True)


def inject_environment(value, environment):
    """Support both legacy and TestConfigurations xctestrun layouts without moving TESTROOT."""
    count = 0
    if isinstance(value, dict):
        if "CotabbyTests.xctest" in str(value.get("TestBundlePath", "")):
            value.setdefault("EnvironmentVariables", {}).update(environment)
            count += 1
        else:
            for item in value.values():
                count += inject_environment(item, environment)
    elif isinstance(value, list):
        for item in value:
            count += inject_environment(item, environment)
    return count


def duration(seconds):
    minutes, seconds = divmod(math.ceil(max(0, seconds)), 60)
    hours, minutes = divmod(minutes, 60)
    return f"{hours:02}:{minutes:02}:{seconds:02}"


class ReplayProgress:
    """The CLI owns this journal reader for one run; Swift remains the scoring authority.

    Read only appended bytes and wait for complete JSONL records. Counting observations includes
    both context conditions and character checkpoints, without depending on buffered Xcode output.
    """

    def __init__(self, output, total):
        self.output, self.total = output, total
        self.offset, self.pending, self.completed = 0, b"", 0
        self.seen = set()
        self.started = None
        self.latest = ""

    def status(self):
        now = time.monotonic()
        metadata = self.output / "metadata.json"
        if self.started is None and metadata.exists():
            # Metadata is written after model loading, just before replay. Translate its fixed
            # timestamp once; use a monotonic clock thereafter so clock adjustments cannot skew ETA.
            self.started = now - max(0, time.time() - metadata.stat().st_mtime)
        journal = self.output / "phrases.jsonl"
        if journal.exists():
            with journal.open("rb") as stream:
                stream.seek(self.offset)
                lines = (self.pending + stream.read()).split(b"\n")
                self.offset = stream.tell()
            self.pending = lines.pop()
            for line in lines:
                result = json.loads(line)
                key = (result["phrase"]["id"], result["condition"])
                if key in self.seen:
                    raise ValueError(f"Duplicate replay result: {key}")
                self.seen.add(key)
                self.completed += len(result["observations"])
                self.latest = f"{key[0]} [{key[1]}]"
        if self.completed > self.total:
            raise ValueError("Replay exceeded the planned checkpoint count")
        base = f"Replay {100 * self.completed / self.total:5.1f}% | {self.completed:,}/{self.total:,} predictions"
        if self.started is None:
            return base + " | ETA estimating (launching test / loading model)"
        elapsed = max(0, now - self.started)
        if self.completed == self.total:
            return base + f" | elapsed {duration(elapsed)} | ETA 00:00:00 | finalizing report / checking test result"
        eta = duration(elapsed * (self.total - self.completed) / self.completed) if self.completed and elapsed else "estimating"
        return base + f" | elapsed {duration(elapsed)} | ETA {eta}" + (f" | {self.latest}" if self.latest else "")


def logged_command(command, log, progress=None):
    print("Running:", " ".join(map(str, command)), flush=True)
    print(f"Log: {log}", flush=True)
    started = time.monotonic()
    last_update = -math.inf
    terminal = sys.stdout.isatty()
    def display():
        status = progress.status() if progress else f"Building | elapsed {duration(time.monotonic() - started)} | replay ETA available after predictions begin"
        print(("\r\033[K" if terminal else "") + status, end="" if terminal else "\n", flush=True)

    with log.open("w") as stream:
        process = subprocess.Popen(list(map(str, command)), cwd=ROOT, stdout=stream,
                                   stderr=subprocess.STDOUT, start_new_session=True)
        try:
            while True:
                if time.monotonic() - last_update >= (1 if terminal else 5):
                    display()
                    last_update = time.monotonic()
                try:
                    process.wait(timeout=0.25)
                    break
                except subprocess.TimeoutExpired:
                    pass
            display()
        except BaseException:
            # Ctrl-C must stop the child build/test too; leave its durable journal for diagnosis.
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
            raise
        finally:
            if terminal:
                print(flush=True)
    if process.returncode:
        print("\n".join(log.read_text(errors="replace").splitlines()[-35:]), file=sys.stderr)
        raise RuntimeError(f"Command failed ({process.returncode}); see {log}")


def run(args):
    phrases = show_plan(args)
    if platform.system() != "Darwin":
        raise ValueError("Live evaluation requires macOS and Xcode")
    if args.model and (not args.model.is_file() or args.model.suffix.lower() != ".gguf"):
        raise ValueError("--model must name an existing GGUF file")
    if args.workspace and not args.workspace.exists():
        raise ValueError("--workspace does not exist")
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    output = (args.output or ROOT / "build/eval/phrases" / f"{stamp}-{uuid.uuid4().hex[:8]}").resolve()
    output.mkdir(parents=True, exist_ok=False)
    manifest = {
        "startedUTC": stamp, "label": args.label, "gitCommit": git_output("rev-parse", "HEAD").strip(),
        "gitStatus": git_output("status", "--short"), "mode": args.mode, "contextMode": args.context,
        "corpusSHA256": hashlib.sha256(CORPUS.read_bytes()).hexdigest(),
        "phraseIDs": [p["id"] for p in phrases], "platform": platform.platform(),
        "modelPath": str(args.model.resolve()) if args.model else "app runtime default",
    }
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    (output / "working-tree.patch").write_text(git_output("diff", "HEAD", "--", "Cotabby", "CotabbyTests", "project.yml", "scripts"))
    print(f"Results: {output}", flush=True)
    project = ["-workspace", args.workspace.resolve()] if args.workspace else ["-project", ROOT / "Cotabby.xcodeproj"]
    logged_command([
        "xcodebuild", "build-for-testing", *project, "-scheme", "Cotabby", "-configuration", "Release",
        "-destination", "platform=macOS", "-derivedDataPath", DERIVED,
        "CODE_SIGNING_ALLOWED=NO", "ENABLE_TESTABILITY=YES", "ONLY_ACTIVE_ARCH=YES",
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) RUN_LLAMA_EVAL", "-skipPackageUpdates",
    ], output / "build.log")
    products = DERIVED / "Build/Products"
    candidates = [p for p in products.glob("Cotabby_*.xctestrun") if "phrase-eval-" not in p.name]
    if not candidates:
        raise RuntimeError("Build produced no Cotabby xctestrun file")
    source = max(candidates, key=lambda p: p.stat().st_mtime_ns)
    configuration = plistlib.loads(source.read_bytes())
    environment = {
        "COTABBY_PHRASE_EVAL": "1", "COTABBY_PHRASE_MODE": args.mode, "COTABBY_PHRASE_CONTEXT": args.context,
        "COTABBY_PHRASE_OUTPUT": str(output), "COTABBY_PHRASE_LABEL": args.label,
    }
    for key, value in (("COTABBY_PHRASE_CATEGORY", args.category), ("COTABBY_PHRASE_ID", args.phrase),
                       ("COTABBY_PHRASE_LIMIT", args.limit), ("COTABBY_PHRASE_PER_CATEGORY", args.per_category), ("COTABBY_EVAL_MODEL_PATH", args.model)):
        if value is not None:
            environment[key] = str(value.resolve() if isinstance(value, pathlib.Path) else value)
    if inject_environment(configuration, environment) != 1:
        raise RuntimeError("Expected exactly one CotabbyTests target in xctestrun")
    # __TESTROOT__ is relative to the plist, so keep the temporary copy beside the original.
    prepared = products / f"Cotabby_phrase-eval-{uuid.uuid4().hex}.xctestrun"
    prepared.write_bytes(plistlib.dumps(configuration))
    try:
        logged_command([
            "xcodebuild", "test-without-building", "-xctestrun", prepared,
            "-destination", "platform=macOS", "-derivedDataPath", DERIVED,
            "-only-testing:CotabbyTests/PhrasePredictionEvalTests/testReplayCorpus",
            "-parallel-testing-enabled", "NO", "-test-timeouts-enabled", "NO",
        ], output / "test.log", ReplayProgress(output, sum(checkpoint_counts(phrases, args.mode, args.context).values())))
    finally:
        prepared.unlink(missing_ok=True)
    report_path = output / "report.json"
    if not report_path.exists():
        raise RuntimeError("No report was produced; check test.log for a skipped or interrupted benchmark")
    report = json.loads(report_path.read_text())
    conditions = ["none", "screen"] if args.context == "paired" else [args.context]
    expected = [(phrase["id"], condition) for phrase in phrases for condition in conditions]
    actual = [(p["phrase"]["id"], p["condition"]) for p in report["phrases"]]
    if sorted(actual) != sorted(expected):
        raise RuntimeError("Executed phrase selection does not match the requested selection")
    if report["errorCount"]:
        raise RuntimeError("Report contains inference errors; do not use this run as a baseline")
    print("Complete: replay and report validation passed.")
    print((output / "summary.txt").read_text())
    print(f"Report: {report_path}")


def percent(value):
    return "n/a" if value is None else f"{value * 100:.2f}%"


def save_baseline(args):
    """Export one completed run for Git; local journals remain the detailed diagnostic record.

    Preserve comparison inputs and every aggregate, but discard bulky per-prediction output.
    This separate export boundary prevents a failed or partial run from becoming a baseline.
    """
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,99}", args.name):
        raise ValueError("Baseline name must use 1–100 letters, digits, dots, underscores or hyphens, starting with a letter or digit")
    source = args.run.resolve()
    report = json.loads((source / "report.json").read_text())
    manifest = json.loads((source / "manifest.json").read_text())
    comparison_rows(report, report)  # Reject unsupported reports and inference errors first.
    if report.get("baselineFormatVersion"):
        raise ValueError("Export from the original completed run, not another baseline")
    metadata = report["metadata"]
    for field in ("mode", "contextMode", "corpusSHA256"):
        if metadata[field] != manifest[field]:
            raise ValueError(f"Run manifest and report disagree on {field}")
    if metadata["mode"] not in ("word", "character") or metadata["contextMode"] not in ("none", "screen", "paired"):
        raise ValueError("Unsupported checkpoint or context mode")
    conditions = ("none", "screen") if metadata["contextMode"] == "paired" else (metadata["contextMode"],)
    expected = [(phrase_id, condition) for phrase_id in manifest["phraseIDs"] for condition in conditions]
    actual = [(result["phrase"]["id"], result["condition"]) for result in report["phrases"]]
    if not expected or len(set(expected)) != len(expected) or sorted(actual) != sorted(expected):
        raise ValueError("Cannot save an incomplete or duplicate phrase selection")
    for result in report["phrases"]:
        expected_count = sum(checkpoint_counts([result["phrase"]], metadata["mode"], "none").values())
        if len(result["observations"]) != expected_count or result["all"]["checkpoints"] != expected_count:
            raise ValueError(f"Incomplete checkpoints for {result['phrase']['id']}")
    summary = (source / "summary.txt").read_text()
    compact = copy.deepcopy(report)
    compact["baselineFormatVersion"] = 1
    # Checkpoints and fixture scenarios are the comparator's exact input identity. Retaining them
    # means a compact baseline can be compared directly with an ordinary full report.
    for result in compact["phrases"]:
        result["observations"] = [{"checkpoint": item["checkpoint"]} for item in result["observations"]]
    compact["metadata"]["model"] = pathlib.Path(metadata["model"]).name
    provenance = {key: manifest[key] for key in (
        "startedUTC", "label", "gitCommit", "gitStatus", "mode", "contextMode", "corpusSHA256", "phraseIDs", "platform"
    )}
    provenance["modelFile"] = compact["metadata"]["model"]
    provenance["sourceReportSHA256"] = hashlib.sha256((source / "report.json").read_bytes()).hexdigest()
    provenance["baselineName"] = args.name
    # Encode before creating the immutable destination, so invalid inputs leave no baseline folder.
    encoded = json.dumps(compact, indent=2, sort_keys=True) + "\n"
    encoded_provenance = json.dumps(provenance, indent=2, sort_keys=True) + "\n"
    destination = BASELINES / args.name
    destination.mkdir(parents=True, exist_ok=False)
    (destination / "report.json").write_text(encoded)
    (destination / "manifest.json").write_text(encoded_provenance)
    (destination / "summary.txt").write_text(summary)
    print(f"Saved baseline: {destination} ({len(manifest['phraseIDs'])} phrases, context={metadata['contextMode']})")
    print("Ready for git add / commit / push. Full observations and logs remain in the original run directory.")


def comparison_rows(before, after):
    """Reject mismatched inputs; model/config differences are intentional tuning dimensions."""
    for key in ("schemaVersion",):
        if before[key] != after[key] or before[key] != 2:
            raise ValueError(f"Cannot compare different or unsupported {key}")
    for key in ("corpusSHA256", "mode", "seed", "contextMode"):
        if before["metadata"][key] != after["metadata"][key]:
            raise ValueError(f"Cannot compare runs with different {key}")
    def identity(report):
        return [(p["phrase"], p["condition"], [o["checkpoint"] for o in p["observations"]]) for p in report["phrases"]]
    if identity(before) != identity(after):
        raise ValueError("Cannot compare different phrase selections or checkpoint sequences")
    if before["errorCount"] or after["errorCount"]:
        raise ValueError("Cannot compare runs with inference errors; repair the failed run first")
    rows = []
    for condition in sorted(before["conditions"]):
        old, new = before["conditions"][condition], after["conditions"][condition]
        rows.append((f"SUITE [{condition}]", old["suite"]["nextWord"], new["suite"]["nextWord"]))
        rows += [(f"{name} [{condition}]", old["categories"][name]["nextWord"], new["categories"][name]["nextWord"])
                 for name in sorted(old["categories"])]
    rows += [(f"{a['phrase']['id']} [{a['condition']}]", a["nextWord"], b["nextWord"])
             for a, b in zip(before["phrases"], after["phrases"])]
    return rows


def compare(args):
    before = json.loads(args.before.read_text())
    after = json.loads(args.after.read_text())
    rows = comparison_rows(before, after)
    for field in ("model", "configuration"):
        old, new = before["metadata"][field], after["metadata"][field]
        changed = pathlib.Path(old).name != pathlib.Path(new).name if field == "model" else old != new
        if changed:
            print(f"Changed {field}: {before['metadata'][field]} -> {after['metadata'][field]}")
    print("Next-word accuracy (percentage-point change):")
    for name, old, new in rows:
        delta = None if old.get("accuracy") is None or new.get("accuracy") is None else 100 * (new.get("accuracy") - old.get("accuracy"))
        change = "n/a" if delta is None else f"{delta:+.2f} pp"
        print(f"{name:24} {percent(old.get('accuracy')):>8} -> {percent(new.get('accuracy')):>8}  {change}")
    print("Equal-category score:", percent(before["meanCategoryNextWordAccuracy"]), "->", percent(after["meanCategoryNextWordAccuracy"]))
    print("Coverage:", percent(before["suite"]["nextWord"]["coverage"]), "->", percent(after["suite"]["nextWord"]["coverage"]))
    print("Precision when shown:", percent(before["suite"]["nextWord"].get("precisionWhenShown")), "->", percent(after["suite"]["nextWord"].get("precisionWhenShown")))

    for label, report in (("Before", before), ("After", after)):
        if lift := report.get("contextLift"):
            print(f"{label} screen-context lift: {100 * lift['suiteAccuracyDelta']:+.2f} pp; "
                  f"helped {lift['improvedCheckpoints']}, harmed {lift['regressedCheckpoints']}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("plan", "run"):
        command = commands.add_parser(name)
        command.add_argument("--mode", choices=("word", "character"), default="word")
        command.add_argument("--context", choices=("none", "screen", "paired"), default="paired")
        command.add_argument("--per-category", type=int, help="First N scenarios in each selected category; useful for balanced smoke tests")
        command.add_argument("--category", choices=CATEGORIES)
        command.add_argument("--phrase", help="Stable phrase ID, e.g. conversation-001")
        command.add_argument("--limit", type=int, help="First N phrases after filtering (smoke tests only)")
        if name == "run":
            command.add_argument("--model", type=pathlib.Path, help="Local GGUF; defaults to app runtime model")
            command.add_argument("--workspace", type=pathlib.Path, help="Optional workspace for a local CotabbyInference checkout")
            command.add_argument("--output", type=pathlib.Path, help="New results directory; never overwrites a previous run")
            command.add_argument("--label", default="baseline")
    command = commands.add_parser("compare")
    command.add_argument("before", type=pathlib.Path)
    command.add_argument("after", type=pathlib.Path)
    command = commands.add_parser("save-baseline", help="Export a completed run to the versioned benchmarks folder")
    command.add_argument("run", type=pathlib.Path, help="Completed run directory containing report.json, manifest.json and summary.txt")
    command.add_argument("--name", required=True, help="New immutable baseline folder name")
    args = parser.parse_args()
    try:
        {"plan": show_plan, "run": run, "compare": compare, "save-baseline": save_baseline}[args.command](args)
    except KeyboardInterrupt:
        parser.exit(130, "Interrupted; completed phrase records and logs remain in the results directory.\n")
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Error: {error}\n")


if __name__ == "__main__":
    main()
