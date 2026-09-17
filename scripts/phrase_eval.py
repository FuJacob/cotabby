#!/usr/bin/env python3
"""Plan, run, and compare Cotabby's fixed local next-word benchmark.

Swift owns replay and scoring. This standard-library CLI only selects inputs, launches the
app-hosted test with explicit environment settings, and compares its versioned JSON reports.
"""
import argparse
import collections
import datetime
import hashlib
import json
import pathlib
import platform
import plistlib
import re
import subprocess
import sys
import uuid

ROOT = pathlib.Path(__file__).resolve().parents[1]
CORPUS = ROOT / "CotabbyTests/Fixtures/phrase-prediction-1337.json"
DERIVED = ROOT / "build/DerivedData"
CATEGORIES = ("conversation", "science", "entertainment", "work", "technology", "everyday", "travel")
WORD = re.compile(r"[^\W_]+(?:['’\-][^\W_]+)*", re.UNICODE)


def read_selection(args):
    corpus = json.loads(CORPUS.read_text())
    phrases = corpus["phrases"]
    if (corpus["version"] != 1 or corpus["language"] != "en"
            or len(phrases) != 1337
            or len({p["id"] for p in phrases}) != 1337
            or len({p["text"].strip().lower() for p in phrases}) != 1337
            or collections.Counter(p["category"] for p in phrases) != dict.fromkeys(CATEGORIES, 191)
            or any(len(WORD.findall(p["text"])) < 3 for p in phrases)):
        raise ValueError("Invalid corpus: expected 1337 unique phrases, 191 per category, at least three words each")
    selected = [p for p in phrases if (not args.category or p["category"] == args.category)
                and (not args.phrase or p["id"] == args.phrase)]
    if args.limit is not None:
        if args.limit < 1:
            raise ValueError("--limit must be positive")
        selected = selected[:args.limit]
    if not selected:
        raise ValueError("No phrases match the selection")
    return corpus, selected


def show_plan(args):
    _, phrases = read_selection(args)
    counts = collections.Counter()
    for phrase in phrases:
        words = WORD.findall(phrase["text"])[1:]
        counts[phrase["category"]] += len(words) if args.mode == "word" else sum(map(len, words))
    print(f"{len(phrases)} phrases; {sum(counts.values()):,} prediction checkpoints; mode={args.mode}")
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


def logged_command(command, log):
    print("Running:", " ".join(map(str, command)), flush=True)
    print(f"Log: {log}", flush=True)
    with log.open("w") as stream:
        result = subprocess.run(list(map(str, command)), cwd=ROOT, stdout=stream, stderr=subprocess.STDOUT)
    if result.returncode:
        print("\n".join(log.read_text(errors="replace").splitlines()[-35:]), file=sys.stderr)
        raise RuntimeError(f"Command failed ({result.returncode}); see {log}")


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
        "gitStatus": git_output("status", "--short"), "mode": args.mode,
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
        "COTABBY_PHRASE_EVAL": "1", "COTABBY_PHRASE_MODE": args.mode,
        "COTABBY_PHRASE_OUTPUT": str(output), "COTABBY_PHRASE_LABEL": args.label,
    }
    for key, value in (("COTABBY_PHRASE_CATEGORY", args.category), ("COTABBY_PHRASE_ID", args.phrase),
                       ("COTABBY_PHRASE_LIMIT", args.limit), ("COTABBY_EVAL_MODEL_PATH", args.model)):
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
        ], output / "test.log")
    finally:
        prepared.unlink(missing_ok=True)
    report_path = output / "report.json"
    if not report_path.exists():
        raise RuntimeError("No report was produced; check test.log for a skipped or interrupted benchmark")
    report = json.loads(report_path.read_text())
    if [p["phrase"]["id"] for p in report["phrases"]] != manifest["phraseIDs"]:
        raise RuntimeError("Executed phrase selection does not match the requested selection")
    print((output / "summary.txt").read_text())
    print(f"Report: {report_path}")


def percent(value):
    return "n/a" if value is None else f"{value * 100:.2f}%"


def comparison_rows(before, after):
    """Reject mismatched inputs; model/config differences are intentional tuning dimensions."""
    for key in ("schemaVersion",):
        if before[key] != after[key] or before[key] != 1:
            raise ValueError(f"Cannot compare different or unsupported {key}")
    for key in ("corpusSHA256", "mode", "seed"):
        if before["metadata"][key] != after["metadata"][key]:
            raise ValueError(f"Cannot compare runs with different {key}")
    def identity(report):
        return [(p["phrase"], [o["checkpoint"] for o in p["observations"]]) for p in report["phrases"]]
    if identity(before) != identity(after):
        raise ValueError("Cannot compare different phrase selections or checkpoint sequences")
    if before["suite"]["all"]["errors"] or after["suite"]["all"]["errors"]:
        raise ValueError("Cannot compare runs with inference errors; repair the failed run first")
    rows = [("SUITE", before["suite"]["nextWord"], after["suite"]["nextWord"])]
    rows += [(name, before["categories"][name]["nextWord"], after["categories"][name]["nextWord"])
             for name in sorted(before["categories"])]
    rows += [(a["phrase"]["id"], a["nextWord"], b["nextWord"])
             for a, b in zip(before["phrases"], after["phrases"])]
    return rows


def compare(args):
    before = json.loads(args.before.read_text())
    after = json.loads(args.after.read_text())
    rows = comparison_rows(before, after)
    for field in ("model", "configuration"):
        if before["metadata"][field] != after["metadata"][field]:
            print(f"Changed {field}: {before['metadata'][field]} -> {after['metadata'][field]}")
    print("Next-word accuracy (percentage-point change):")
    for name, old, new in rows:
        delta = None if old.get("accuracy") is None or new.get("accuracy") is None else 100 * (new.get("accuracy") - old.get("accuracy"))
        change = "n/a" if delta is None else f"{delta:+.2f} pp"
        print(f"{name:24} {percent(old.get('accuracy')):>8} -> {percent(new.get('accuracy')):>8}  {change}")
    print("Equal-category score:", percent(before["meanCategoryNextWordAccuracy"]), "->", percent(after["meanCategoryNextWordAccuracy"]))
    print("Coverage:", percent(before["suite"]["nextWord"]["coverage"]), "->", percent(after["suite"]["nextWord"]["coverage"]))
    print("Precision when shown:", percent(before["suite"]["nextWord"].get("precisionWhenShown")), "->", percent(after["suite"]["nextWord"].get("precisionWhenShown")))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("plan", "run"):
        command = commands.add_parser(name)
        command.add_argument("--mode", choices=("word", "character"), default="word")
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
    args = parser.parse_args()
    try:
        {"plan": show_plan, "run": run, "compare": compare}[args.command](args)
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Error: {error}\n")


if __name__ == "__main__":
    main()
