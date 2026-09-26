#!/usr/bin/env python3
"""Plan, run, and compare Cotabby's fixed local next-word benchmark.

Swift owns replay and scoring. This standard-library CLI only selects inputs, launches the
app-hosted test with explicit environment settings, and compares its versioned JSON reports.
"""
import argparse
import collections
import contextlib
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
import tempfile
import time
import uuid
import xml.etree.ElementTree as ET

ROOT = pathlib.Path(__file__).resolve().parents[1]
CORPUS = ROOT / "CotabbyTests/Fixtures/phrase-prediction-1337.json"
DERIVED = ROOT / "build/DerivedData"
BASELINES = ROOT / "benchmarks/phrase-prediction"
CATEGORIES = ("conversation", "science", "entertainment", "work", "technology", "everyday", "travel")
WORD = re.compile(r"[^\W_]+(?:['’\-][^\W_]+)*", re.UNICODE)
SAMPLING_FIELDS = {
    "temperature": ("temperature", "COTABBY_PHRASE_TEMPERATURE"),
    "repetition_penalty": ("repetitionPenalty", "COTABBY_PHRASE_REPETITION_PENALTY"),
    "top_k": ("topK", "COTABBY_PHRASE_TOP_K"),
    "top_p": ("topP", "COTABBY_PHRASE_TOP_P"),
    "min_p": ("minP", "COTABBY_PHRASE_MIN_P"),
}


def sampling_overrides(args):
    """Validate test-only knobs before building; native Options validates them independently.

    An omitted knob inherits the current product default. Explicit values are saved separately
    from the native report's effective configuration, so a stale test build cannot silently ignore
    an experiment. Nonzero seeds avoid the wrapper's randomized-seed sentinel.
    """
    values = {field: getattr(args, field, None) for field in SAMPLING_FIELDS}
    values["seed"] = getattr(args, "seed", None)
    bounds = {"temperature": (0, 100), "repetition_penalty": (0, 100),
              "top_k": (0, 2**31 - 1), "top_p": (0, 1), "min_p": (0, 1),
              "seed": (1, 2**32 - 2)}
    for field, value in values.items():
        if value is None:
            continue
        low, high = bounds[field]
        if not math.isfinite(value) or not low <= value <= high or (field == "repetition_penalty" and value == 0):
            raise ValueError(f"Invalid --{field.replace('_', '-')}: {value}")
        if field in ("top_k", "seed") and not isinstance(value, int):
            raise ValueError(f"--{field.replace('_', '-')} must be an integer")
    return {field: value for field, value in values.items() if value is not None}


def partition_phrases(phrases, args):
    """Choose a balanced, result-independent split using the same SHA-256 recipe as Swift.

    The partition is made from the complete corpus before category/ID filters. Hash order also
    determines any per-category cap within a partition; returned replay order remains corpus order.
    This lets a small held-out run grow later without changing its existing members.
    """
    split = getattr(args, "split", "all")
    seed = getattr(args, "split_seed", 1337)
    count = getattr(args, "screen_per_category", 20)
    if split not in ("all", "screen", "heldout"):
        raise ValueError("--split must be all, screen, or heldout")
    if not isinstance(seed, int) or not 0 <= seed <= 2**32 - 1:
        raise ValueError("--split-seed must be an unsigned 32-bit integer")
    if not isinstance(count, int) or not 1 <= count < 191:
        raise ValueError("--screen-per-category must be between 1 and 190")
    if split == "all":
        return phrases
    ranked = sorted(phrases, key=lambda p: (hashlib.sha256(f"{seed}:{p['id']}".encode()).hexdigest(), p["id"]))
    counts = collections.Counter()
    selected = []
    for phrase in ranked:
        counts[phrase["category"]] += 1
        in_screen = counts[phrase["category"]] <= count
        if in_screen == (split == "screen"):
            selected.append(phrase)
    return selected


def read_selection(args):
    corpus_path = getattr(args, "corpus", None) or CORPUS
    canonical = not getattr(args, "corpus", None)
    corpus = json.loads(corpus_path.read_text())
    phrases = corpus["phrases"]
    if (corpus["version"] != 2 or corpus["language"] != "en"
            or not corpus.get("provenance")
            or not phrases
            or (canonical and len(phrases) != 1337)
            or len({p["id"] for p in phrases}) != len(phrases)
            or len({p["text"].strip().lower() for p in phrases}) != len(phrases)
            or not set(p["category"] for p in phrases).issubset(CATEGORIES)
            or (canonical and collections.Counter(p["category"] for p in phrases) != dict.fromkeys(CATEGORIES, 191))
            or any(not p["id"] or p["text"] != p["text"].strip() or len(WORD.findall(p["text"])) < 3 for p in phrases)):
        raise ValueError("Invalid corpus: expected 1337 unique phrases, 191 per category, at least three words each")
    screens = [p.get("scenario", {}).get("screenText", "") for p in phrases]
    if len(set(screens)) != len(phrases) or any(len(screen) < 40 or len(screen) > 4000 for screen in screens):
        raise ValueError("Every phrase requires a distinct bounded screen scenario")
    folded = lambda text: " ".join(WORD.findall(text.lower()))
    for phrase in phrases:
        scene = phrase["scenario"]
        if not all(scene.get(key) for key in ("applicationName", "bundleIdentifier", "kind")):
            raise ValueError("Incomplete surface scenario")
        if folded(phrase["text"]) in folded(scene["screenText"] + " " + scene["documentPrefix"]):
            raise ValueError(f"Reference sentence leaked into screen context: {phrase['id']}")
    selected = [p for p in partition_phrases(phrases, args) if (not args.category or p["category"] == args.category)
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
    selected_ids = {p["id"] for p in selected}
    selected = [p for p in phrases if p["id"] in selected_ids]
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
    overrides = sampling_overrides(args)
    _, phrases = read_selection(args)
    context = getattr(args, "context", "paired")
    workers = min(getattr(args, "workers", 3), len(phrases))
    counts = checkpoint_counts(phrases, args.mode, context)
    print(f"{len(phrases)} phrases; {sum(counts.values()):,} prediction checkpoints; mode={args.mode}; context={context}; workers={workers}")
    for category, count in sorted(counts.items()):
        print(f"  {category}: {count:,} checkpoints")
    print("Primary score: exact next word before its first letter; suppressed output is a miss.")
    print(f"Selection: split={getattr(args, 'split', 'all')}; split seed={getattr(args, 'split_seed', 1337)}; screen phrases/category={getattr(args, 'screen_per_category', 20)}")
    print(f"Prompt: {getattr(args, 'prompt_variant', 'production')}; profile: {getattr(args, 'profile', 'plain')}; word count: {getattr(args, 'word_count', None) or 'product default'}")
    if overrides:
        print("Sampling overrides:", json.dumps(overrides, sort_keys=True))
    return phrases


def validate_sampling_report(report, overrides):
    """Reject effective settings that differ from the requested experimental settings."""
    metadata = report["metadata"]
    for field, requested in overrides.items():
        actual = metadata.get("seed") if field == "seed" else metadata["configuration"].get(SAMPLING_FIELDS[field][0])
        try:
            matches = math.isclose(float(actual), requested, rel_tol=1e-12, abs_tol=1e-12)
        except (TypeError, ValueError):
            matches = False
        if not matches:
            raise RuntimeError(f"Executed sampling {field}={actual} does not match requested {requested}; rebuild the test bundle")


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
        self.workers = None

    def status(self):
        now = time.monotonic()
        metadata = self.output / "metadata.json"
        if self.started is None and metadata.exists():
            # Metadata is written after model loading, just before replay. Translate its fixed
            # timestamp once; use a monotonic clock thereafter so clock adjustments cannot skew ETA.
            self.started = now - max(0, time.time() - metadata.stat().st_mtime)
            self.workers = json.loads(metadata.read_text()).get("workerCount", 1)
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
        if self.workers is not None:
            base += f" | workers {self.workers}"
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


def build_input_snapshot(workspace=None):
    """Separate resolver-owned locks from app/test/native/config inputs in one source snapshot.

    Only repository source inputs are enumerated: ignored model files, caches and generated native
    build trees cannot invalidate a sampler-only run or make hashing scale with model size. Local
    package references must be Git checkouts so their tracked/untracked source list is auditable.
    Only canonical package lock paths may change during explicit dependency resolution. A file
    merely named Package.resolved inside app/test fixtures is still an ordinary protected input.
    """
    roots = [(ROOT, ["Cotabby", "CotabbyTests", "Cotabby.xcodeproj", "project.yml", "CotabbyInfo.plist", "Config"])]
    inputs = set((ROOT / "Config").glob("*.xcconfig"))
    package_locks = {ROOT / "Cotabby.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"}
    if workspace:
        workspace = workspace.resolve()
        document = workspace / "contents.xcworkspacedata"
        inputs.add(document)
        package_locks.add(workspace / "xcshareddata/swiftpm/Package.resolved")
        for reference in ET.parse(document).iter("FileRef"):
            location = reference.attrib.get("location", "")
            kind, _, value = location.partition(":")
            if kind == "absolute":
                path = pathlib.Path(value)
            elif kind in ("group", "container"):
                path = workspace.parent / value
            else:
                raise ValueError(f"Unsupported workspace reference for build reuse: {location}")
            path = path.resolve()
            if (path / "Package.swift").is_file():
                roots.append((path, []))
                package_locks.add(path / "Package.resolved")
    # Signing.local.xcconfig is intentionally gitignored but still changes the built app host.
    # Resolved package versions can also live in a generated, ignored workspace directory.
    for repository, paths in roots:
        names = subprocess.check_output(["git", "ls-files", "-co", "--exclude-standard", "-z", "--", *paths],
                                        cwd=repository).decode().split("\0")
        for name in sorted(set(filter(None, names))):
            path = repository / name
            if not path.is_file() or any(part in ("xcuserdata", ".build", "build") for part in pathlib.Path(name).parts):
                continue
            # Package source dependencies can contain checked-in release binaries. Their build
            # selection is covered by Package.swift; source builds are covered by the files below.
            if repository != ROOT and path.suffix.lower() not in (".swift", ".c", ".cc", ".cpp", ".h", ".hh", ".hpp", ".m", ".mm", ".metal", ".cmake", ".txt", ".json", ".modulemap", ".sh"):
                continue
            inputs.add(path)
    full_digest, source_digest = hashlib.sha256(), hashlib.sha256()
    locks = {}
    for path in sorted(inputs | package_locks):
        file_digest = None
        if path.is_file():
            digest = hashlib.sha256()
            with path.open("rb") as stream:
                while chunk := stream.read(1_048_576):
                    digest.update(chunk)
            file_digest = digest.hexdigest()
        record = str(path).encode() + b"\0" + (file_digest or "missing").encode() + b"\0"
        full_digest.update(record)
        if path in package_locks:
            locks[str(path)] = file_digest
        else:
            source_digest.update(record)
    return {"sourceSHA256": full_digest.hexdigest(), "nonLockSourceSHA256": source_digest.hexdigest(),
            "packageLocks": locks}


def build_input_fingerprint(workspace=None):
    return build_input_snapshot(workspace)["sourceSHA256"]


def prepare_build_inputs(workspace, project, output, *, skip_build):
    """Resolve before freezing compilation inputs, rejecting concurrent non-lock source edits.

    A first Xcode workspace resolution legitimately creates Package.resolved. Record that change
    separately rather than weakening the compilation guard. Build reuse never invokes resolution:
    even lock-only changes must invalidate an existing build instead of silently changing its inputs.
    """
    before = build_input_snapshot(workspace)
    if skip_build:
        return before
    record_path = output / "resolution-inputs.json"
    record = {"before": before, "status": "resolving"}
    record_path.write_text(json.dumps(record, indent=2) + "\n")
    try:
        logged_command([
            "xcodebuild", "-resolvePackageDependencies", *project, "-scheme", "Cotabby", "-configuration", "Release",
            "-destination", "platform=macOS", "-derivedDataPath", DERIVED, "-skipPackageUpdates",
        ], output / "resolution.log")
        # Resolving is not complete until its resulting inputs can be captured. A concurrent
        # malformed workspace edit or failed file read must not leave durable evidence "resolving".
        after = build_input_snapshot(workspace)
    except BaseException as error:
        record.update(status="failed", error={"type": type(error).__name__, "message": str(error)})
        record_path.write_text(json.dumps(record, indent=2) + "\n")
        raise
    stable = before["nonLockSourceSHA256"] == after["nonLockSourceSHA256"]
    record.update(after=after, status="resolved" if stable else "rejected-source-change")
    record_path.write_text(json.dumps(record, indent=2) + "\n")
    if not stable:
        raise RuntimeError("App, test, native, or configuration inputs changed during dependency resolution; retry with a stable checkout")
    return after


@contextlib.contextmanager
def sign_test_hosts(products, output):
    """Stage and ad-hoc sign a disposable XCTest host outside file-provider managed folders.

    Incremental unsigned builds can retain stale seals. File providers can also reattach Finder
    metadata immediately after xattr cleanup under Documents, invalidating a new seal. A clean
    temporary copy avoids both, needs no developer identity, and never changes the installed app
    or the binaries fingerprinted for build reuse. The context manager removes it even on failure.
    """
    source = products / "Release/Cotabby.app"
    if not source.is_dir():
        raise RuntimeError("No Release test host found for ad-hoc signing")
    entitlements = output / "test-host.entitlements"
    entitlements.write_bytes(plistlib.dumps({"com.apple.security.get-task-allow": True,
        "com.apple.security.cs.disable-library-validation": True}))
    with tempfile.TemporaryDirectory(prefix="cohamster-eval-", dir="/private/tmp") as staging:
        host = pathlib.Path(staging) / "Cotabby.app"
        logged_command(["ditto", "--norsrc", "--noextattr", source, host], output / "sign-copy.log")
        logged_command(["xattr", "-cr", host], output / "sign-attributes.log")
        logged_command(["codesign", "--force", "--deep", "--sign", "-", "--timestamp=none",
                        "--options", "runtime", "--entitlements", entitlements, host], output / "sign.log")
        logged_command(["codesign", "--verify", "--deep", "--strict", host], output / "sign-verify.log")
        try:
            yield host
        finally:
            # XCTest launches through launchd, outside xcodebuild's process group. Interrupting
            # that group alone can leave a blocked host (and its model) alive. Match only this
            # disposable executable, never the installed Cotabby app or another replay.
            executable = host / "Contents/MacOS/Cotabby"
            subprocess.run(["pkill", "-TERM", "-f", "^" + re.escape(str(executable)) + "( |$)"],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)


def retarget_test_host(value, host):
    """Preserve __TESTROOT__/__TESTHOST__ semantics while pointing XCTest at the signed copy."""
    count = 0
    if isinstance(value, dict):
        if "CotabbyTests.xctest" in str(value.get("TestBundlePath", "")):
            old = value["TestHostPath"]
            value["TestHostPath"] = str(host)
            value["DependentProductPaths"] = [p.replace(old, str(host)) for p in value.get("DependentProductPaths", [])]
            # XCTest adds product-directory overrides ahead of the app's own rpaths. Leaving
            # these behind defeats staging: dyld can reopen file-provider-managed frameworks
            # under Documents and stall before main(). Use the verified embedded copies instead.
            product_root = str(pathlib.PurePosixPath(old).parent)
            framework_root = str(host / "Contents/Frameworks")
            for section in ("EnvironmentVariables", "TestingEnvironmentVariables"):
                for key, item in value.get(section, {}).items():
                    if not isinstance(item, str):
                        continue
                    if "DYLD_" in key:
                        value[section][key] = item.replace(product_root + "/PackageFrameworks", framework_root).replace(product_root, framework_root)
                    elif key == "__XCODE_BUILT_PRODUCTS_DIR_PATHS":
                        value[section][key] = item.replace(product_root, str(host.parent))
            count += 1
        else:
            count += sum(retarget_test_host(child, host) for child in value.values())
    elif isinstance(value, list):
        count += sum(retarget_test_host(child, host) for child in value)
    return count


def build_product_fingerprint(source):
    """Detect replacement of the app-hosted test binaries after the recorded successful build."""
    products = source.parent
    binaries = sorted(p for p in products.glob("Release/**/*.app/Contents/MacOS/*") if p.is_file())
    binaries += sorted(p for p in products.glob("Release/**/*.xctest/Contents/MacOS/*") if p.is_file())
    if not binaries:
        raise RuntimeError("No Release app/test binaries found for build fingerprint")
    digest = hashlib.sha256(source.read_bytes())
    for path in binaries:
        digest.update(str(path.relative_to(products)).encode() + b"\0")
        with path.open("rb") as stream:
            while chunk := stream.read(1_048_576):
                digest.update(chunk)
    return digest.hexdigest()


def run(args):
    if getattr(args, "runtime_checks", False) and args.model is None:
        raise ValueError("--runtime-checks requires --model so native checks cannot skip or use a different model")
    phrases = show_plan(args)
    corpus_path = getattr(args, "corpus", None) or CORPUS
    overrides = sampling_overrides(args)
    workers = min(args.workers, len(phrases))
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
        "corpusSHA256": hashlib.sha256(corpus_path.read_bytes()).hexdigest(),
        "phraseIDs": [p["id"] for p in phrases], "platform": platform.platform(),
        "modelPath": str(args.model.resolve()) if args.model else "app runtime default",
        "workerCount": workers,
        "promptVariant": getattr(args, "prompt_variant", "production"),
        "profile": getattr(args, "profile", "plain"),
        "wordCountPreset": getattr(args, "word_count", None) or "product default",
        "corpusPath": str(corpus_path.resolve()),
        "samplingOverrides": overrides,
        "selection": {"split": args.split, "splitSeed": args.split_seed, "screenPerCategory": args.screen_per_category,
                      "perCategory": args.per_category, "limit": args.limit},
    }
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    patch_arguments = ("diff", "HEAD", "--", "Cotabby", "CotabbyTests", "Cotabby.xcodeproj", "CotabbyInfo.plist", "Config", "project.yml", "scripts")
    (output / "working-tree.patch").write_text(git_output(*patch_arguments))
    print(f"Results: {output}", flush=True)
    project = ["-workspace", args.workspace.resolve()] if args.workspace else ["-project", ROOT / "Cotabby.xcodeproj"]
    build_marker = DERIVED / "phrase-eval-build.json"
    initial_git = {key: manifest[key] for key in ("gitCommit", "gitStatus")}
    prepared_inputs = prepare_build_inputs(args.workspace, project, output, skip_build=args.skip_build)
    source_fingerprint = prepared_inputs["sourceSHA256"]
    if hashlib.sha256(corpus_path.read_bytes()).hexdigest() != manifest["corpusSHA256"]:
        raise RuntimeError("Corpus changed after phrase selection; retry with a stable checkout")
    # The manifest/patch now describe the inputs about to compile, including newly generated pins.
    # Keep launch provenance as well; a rejected setup never masquerades as a completed benchmark.
    manifest["gitAtStart"] = initial_git
    manifest["gitCommit"] = git_output("rev-parse", "HEAD").strip()
    manifest["gitStatus"] = git_output("status", "--short")
    manifest["buildInputs"] = prepared_inputs
    (output / "working-tree.patch").write_text(git_output(*patch_arguments))
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    if build_input_fingerprint(args.workspace) != source_fingerprint:
        raise RuntimeError("Source inputs changed while recording build provenance; retry with a stable checkout")
    prior_build = json.loads(build_marker.read_text()) if args.skip_build and build_marker.exists() else None
    if args.skip_build and (not prior_build or prior_build.get("sourceSHA256") != source_fingerprint):
        raise RuntimeError("--skip-build requires a recorded successful build with unchanged source inputs; run once without it")
    if not args.skip_build:
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
    product_fingerprint = build_product_fingerprint(source)
    if args.skip_build and prior_build.get("productSHA256") != product_fingerprint:
        raise RuntimeError("--skip-build found changed app/test binaries; rebuild before evaluating")
    if build_input_fingerprint(args.workspace) != source_fingerprint:
        raise RuntimeError("Source inputs changed during build setup; retry with a stable checkout")
    build_record = {"sourceSHA256": source_fingerprint, "productSHA256": product_fingerprint,
                    "xctestrun": str(source), "reused": args.skip_build}
    if not args.skip_build:
        build_marker.write_text(json.dumps(build_record, indent=2) + "\n")
    else:
        print("Reusing verified app/test build; source inputs and binary fingerprints match.", flush=True)
    manifest["build"] = build_record
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    with sign_test_hosts(products, output) as host:
        configuration = plistlib.loads(source.read_bytes())
        if retarget_test_host(configuration, host) != 1:
            raise RuntimeError("Expected exactly one app-hosted CotabbyTests target")
        if build_product_fingerprint(source) != product_fingerprint:
            raise RuntimeError("App/test binaries changed while staging the test host")
        environment = {
            "COTABBY_PHRASE_EVAL": "1", "COTABBY_PHRASE_MODE": args.mode, "COTABBY_PHRASE_CONTEXT": args.context,
            "COTABBY_PHRASE_OUTPUT": str(output), "COTABBY_PHRASE_LABEL": args.label,
            "COTABBY_PHRASE_WORKERS": str(workers),
            "COTABBY_PHRASE_PROMPT_VARIANT": getattr(args, "prompt_variant", "production"),
            "COTABBY_PHRASE_PROFILE": getattr(args, "profile", "plain"),
            "COTABBY_PHRASE_SPLIT": args.split, "COTABBY_PHRASE_SPLIT_SEED": str(args.split_seed),
            "COTABBY_PHRASE_SCREEN_PER_CATEGORY": str(args.screen_per_category),
        }
        if getattr(args, "word_count", None):
            environment["COTABBY_PHRASE_WORD_COUNT"] = args.word_count
        typing_artifact = host.parent / "typing.json"
        if getattr(args, "runtime_checks", False):
            environment["COTABBY_TYPING_OUTPUT"] = str(typing_artifact)
            # The native integration suite prefers TEST_MODEL_PATH over EVAL_MODEL_PATH.
            # Override both, rather than inheriting an unrelated developer test selection.
            environment["COTABBY_TEST_MODEL_PATH"] = str(args.model.resolve())
        if getattr(args, "corpus", None):
            # The disposable host should not need Documents access to read a custom fixture.
            # Freeze the same bytes we fingerprinted, beside the staged app, for this replay.
            staged_corpus = host.parent / "corpus.json"
            corpus_bytes = args.corpus.read_bytes()
            if hashlib.sha256(corpus_bytes).hexdigest() != manifest["corpusSHA256"]:
                raise RuntimeError("Corpus changed before staging; retry with stable inputs")
            staged_corpus.write_bytes(corpus_bytes)
            environment["COTABBY_PHRASE_CORPUS"] = str(staged_corpus)
        for field, value in overrides.items():
            environment["COTABBY_PHRASE_SEED" if field == "seed" else SAMPLING_FIELDS[field][1]] = str(value)
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
                *(["-only-testing:CotabbyTests/LlamaRuntimeCoreIntegrationTests",
                   "-only-testing:CotabbyTests/LlamaTypingSessionEvalTests"] if getattr(args, "runtime_checks", False) else []),
                "-parallel-testing-enabled", "NO", "-test-timeouts-enabled", "NO",
            ], output / "test.log", ReplayProgress(output, sum(checkpoint_counts(phrases, args.mode, args.context).values())))
        finally:
            prepared.unlink(missing_ok=True)
        if getattr(args, "runtime_checks", False):
            if not typing_artifact.is_file():
                raise RuntimeError("No typing report was produced; check test.log for skipped tests")
            (output / "typing.json").write_bytes(typing_artifact.read_bytes())
    report_path = output / "report.json"
    if not report_path.exists():
        raise RuntimeError("No report was produced; check test.log for a skipped or interrupted benchmark")
    report = json.loads(report_path.read_text())
    validate_sampling_report(report, overrides)
    for field, attribute in (("promptVariant", "prompt_variant"), ("profile", "profile")):
        if hasattr(args, attribute) and report["metadata"].get("configuration", {}).get(field) != getattr(args, attribute):
            raise RuntimeError(f"Test host ignored {attribute}; rebuild the test bundle")
    if getattr(args, "word_count", None) and report["metadata"].get("configuration", {}).get("wordCountPreset") != args.word_count:
        raise RuntimeError("Test host ignored word-count preset; rebuild the test bundle")
    if hashlib.sha256(corpus_path.read_bytes()).hexdigest() != manifest["corpusSHA256"]:
        raise RuntimeError("Corpus changed during replay; do not use this run")
    if "corpusSHA256" in report["metadata"] and report["metadata"]["corpusSHA256"] != manifest["corpusSHA256"]:
        raise RuntimeError("Test host used a different corpus; rebuild the test bundle")
    if report["metadata"].get("workerCount", 1) != workers:
        raise RuntimeError("Executed worker count does not match the requested worker count")
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
    provenance["workerCount"] = metadata.get("workerCount", 1)
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
    old_workers = before["metadata"].get("workerCount", 1)
    new_workers = after["metadata"].get("workerCount", 1)
    print(f"Workers: {old_workers} -> {new_workers}. Parallel latency includes contention; use one worker for interactive latency measurements.")
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
        command.add_argument("--corpus", type=pathlib.Path, help="Explicit version-2 regression corpus; default is the canonical 1337 scenarios")
        command.add_argument("--prompt-variant", choices=("production", "content-only", "compact-surface", "compact-language"), default="production", help="Test-only ablation: content-only omits surface/profile/language hints, retaining screen text")
        command.add_argument("--word-count", choices=("2-4", "4-7", "7-12", "12-20"), help="Explicit completion length; omitted inherits product defaults")
        command.add_argument("--profile", choices=("plain", "personalized"), default="plain", help="personalized includes a synthetic name and English language preference")
        command.add_argument("--mode", choices=("word", "character"), default="word")
        command.add_argument("--context", choices=("none", "screen", "paired"), default="paired")
        command.add_argument("--workers", type=int, choices=(1, 2, 3), default=3,
                             help="Independent inference workers (default: 3); use 1 for uncontended latency")
        command.add_argument("--per-category", type=int, help="N scenarios per selected category; corpus order for all, hash order within a split")
        command.add_argument("--split", choices=("all", "screen", "heldout"), default="all",
                             help="Deterministic balanced screen or its disjoint held-out complement")
        command.add_argument("--split-seed", type=int, default=1337, help="Unsigned 32-bit SHA-256 partition seed, independent of sampling")
        command.add_argument("--screen-per-category", type=int, default=20, help="Screen partition size per category (1–190; default: 20)")
        command.add_argument("--category", choices=CATEGORIES)
        command.add_argument("--phrase", help="Stable phrase ID, e.g. conversation-001")
        command.add_argument("--limit", type=int, help="First N phrases after filtering (smoke tests only)")
        command.add_argument("--temperature", type=float, help="Test-only temperature override (0 enables native greedy decoding)")
        command.add_argument("--repetition-penalty", type=float, help="Test-only repetition penalty; 1 disables the penalty")
        command.add_argument("--top-k", type=int, help="Test-only top-k; 0 disables top-k filtering")
        command.add_argument("--top-p", type=float, help="Test-only nucleus sampling probability (0–1)")
        command.add_argument("--min-p", type=float, help="Test-only relative probability cutoff (0–1)")
        command.add_argument("--seed", type=int, help="Fixed test sampling seed (1–4294967294); default: 42")
        if name == "run":
            command.add_argument("--model", type=pathlib.Path, help="Local GGUF; defaults to app runtime model")
            command.add_argument("--workspace", type=pathlib.Path, help="Optional workspace for a local CotabbyInference checkout")
            command.add_argument("--output", type=pathlib.Path, help="New results directory; never overwrites a previous run")
            command.add_argument("--label", default="baseline")
            command.add_argument("--runtime-checks", action="store_true", help="Also verify cache restoration, cancellation and streamed typing with the selected model")
            command.add_argument("--skip-build", action="store_true",
                                 help="Reuse a successful CLI build only if source and app/test fingerprints still match")
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
