#!/usr/bin/env python3
"""Own the temporary GitHub runner keychain; release credentials never enter the checkout.

The workflow calls setup before Fastlane and cleanup in an always() step. Its original
keychain search list is saved outside the repository, so cleanup also works after a
partially failed setup. This helper is intentionally limited to GitHub-hosted jobs.
"""
import base64
import json
import os
from pathlib import Path
import secrets
import shlex
import subprocess
import sys


def run(*args):
    result = subprocess.run(args, capture_output=True, text=True)
    if result.returncode:
        # CalledProcessError includes argv, which can contain an app-specific password.
        raise SystemExit(f"Credential setup failed: {args[0]} {args[1]} (exit {result.returncode})")
    return result.stdout


def main():
    if os.environ.get("GITHUB_ACTIONS") != "true":
        raise SystemExit("This helper is only for GitHub Actions; use your local Keychain otherwise.")
    mode = sys.argv[1] if len(sys.argv) == 2 else ""
    if mode not in ("setup", "cleanup"):
        raise SystemExit("usage: ci_keychain.py setup|cleanup")
    temporary = Path(os.environ["RUNNER_TEMP"])
    keychain = temporary / "cohamster-signing.keychain-db"
    previous = temporary / "cohamster-keychains.json"
    certificate = temporary / "cohamster-signing.p12"
    if mode == "cleanup":
        certificate.unlink(missing_ok=True)
        if previous.exists():
            run("security", "list-keychains", "-d", "user", "-s", *json.loads(previous.read_text()))
        if keychain.exists():
            run("security", "delete-keychain", str(keychain))
        previous.unlink(missing_ok=True)
        return

    required = ("APPLE_CERTIFICATE_P12_BASE64", "APPLE_CERTIFICATE_PASSWORD", "APPLE_ID", "APPLE_APP_SPECIFIC_PASSWORD")
    missing = [name for name in required if not os.environ.get(name)]
    if missing:
        raise SystemExit("Missing GitHub environment secrets: " + ", ".join(missing))
    if previous.exists() or keychain.exists():
        raise SystemExit("Temporary signing state already exists; run cleanup before setup.")
    original = shlex.split(run("security", "list-keychains", "-d", "user"))
    previous.write_text(json.dumps(original))
    password = secrets.token_urlsafe(32)
    try:
        encoded = "".join(os.environ["APPLE_CERTIFICATE_P12_BASE64"].split())
        certificate.write_bytes(base64.b64decode(encoded, validate=True))
        certificate.chmod(0o600)
        run("security", "create-keychain", "-p", password, str(keychain))
        run("security", "set-keychain-settings", "-lut", "21600", str(keychain))
        run("security", "unlock-keychain", "-p", password, str(keychain))
        run("security", "import", str(certificate), "-P", os.environ["APPLE_CERTIFICATE_PASSWORD"],
            "-k", str(keychain), "-T", "/usr/bin/codesign", "-T", "/usr/bin/security")
        run("security", "set-key-partition-list", "-S", "apple-tool:,apple:,codesign:",
            "-s", "-k", password, str(keychain))
        run("security", "list-keychains", "-d", "user", "-s", str(keychain), *original)
        run("xcrun", "notarytool", "store-credentials", "CoHamster-CI", "--keychain", str(keychain),
            "--apple-id", os.environ["APPLE_ID"], "--team-id", "8RN882MNR5",
            "--password", os.environ["APPLE_APP_SPECIFIC_PASSWORD"])
    finally:
        certificate.unlink(missing_ok=True)


if __name__ == "__main__":
    main()
