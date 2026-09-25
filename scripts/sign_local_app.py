#!/usr/bin/env python3
"""Sign a local dev/test app outside Documents/iCloud, then replace the build product.

Xcode's compile output stays in repo-scoped DerivedData. A temporary metadata-free
copy is the signing boundary because a file provider can restore FinderInfo while
codesign is running. Fastlane verify and build_and_run.sh call this helper; release
packaging keeps its own hardened, timestamped, notarized signing path.
"""
import argparse
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile


def run(*args):
    subprocess.run(args, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--identity", required=True)
    parser.add_argument("--testing", action="store_true")
    parser.add_argument("--debug", action="store_true")
    args = parser.parse_args()
    original = args.app.resolve()
    if original.suffix != ".app" or not (original / "Contents/Info.plist").is_file():
        parser.error("Expected a built .app bundle")
    with tempfile.TemporaryDirectory(prefix="cohamster-local-sign-") as temporary:
        app = Path(temporary) / original.name
        run("ditto", "--norsrc", "--noextattr", str(original), str(app))
        run("xattr", "-cr", str(app))
        # Sign leaf Mach-O files first, followed by their containing code bundles.
        # Don't follow symlinks: versioned frameworks expose the same binary twice.
        magic = {b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf",
                 b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca",
                 b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca"}
        candidates = []
        for path in app.rglob("*"):
            if path.is_symlink():
                continue
            if path.is_dir() and path.suffix in (".app", ".framework", ".xpc", ".xctest"):
                candidates.append(path)
            elif path.is_file():
                with path.open("rb") as stream:
                    if stream.read(4) in magic:
                        candidates.append(path)
        sign = ["codesign", "--force", "--options", "runtime", "--timestamp=none", "--sign", args.identity]
        for path in sorted(candidates, key=lambda item: len(item.parts), reverse=True):
            run(*sign, str(path))
        entitlements = {}
        if args.debug or args.testing:
            entitlements["com.apple.security.get-task-allow"] = True
        if args.testing:
            # XCTest injects its runner libraries into the host. Only the temporary
            # test build gets this entitlement; production packages never use it.
            entitlements["com.apple.security.cs.disable-library-validation"] = True
        entitlement_file = Path(temporary) / "local.entitlements"
        entitlement_file.write_bytes(plistlib.dumps(entitlements))
        run(*sign, "--entitlements", str(entitlement_file), str(app))
        run("codesign", "--verify", "--deep", "--strict", str(app))
        # Preserve the existing product until a complete valid signature exists.
        shutil.rmtree(original)
        run("ditto", "--norsrc", "--noextattr", str(app), str(original))
        run("codesign", "--verify", "--deep", "--strict", str(original))


if __name__ == "__main__":
    main()
