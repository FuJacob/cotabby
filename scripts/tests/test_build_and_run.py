"""Exercise process identity filtering without stopping or launching real apps.

The launch script must select the development identity while leaving production
and unrelated apps alone. Fixtures use real bundle plists and replace only process enumeration.
"""
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


@unittest.skipUnless(sys.platform == "darwin", "uses macOS PlistBuddy")
class LaunchIdentityTests(unittest.TestCase):
    def test_only_development_processes_are_selected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for folder, bundle_id in (("dev", "com.jacobfu.tabby.dev"),
                                      ("production", "com.jacobfu.tabby"),
                                      ("other", "org.example.other")):
                name = "Cotabby Dev"
                contents = root / folder / f"{name}.app" / "Contents"
                contents.mkdir(parents=True)
                (contents / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": bundle_id}))
            commands = root / "bin"
            commands.mkdir()
            (commands / "pgrep").write_text(
                '#!/bin/bash\ncase "$2" in\n'
                '"Cotabby Dev") printf "101\\n102\\n103\\n104\\n";;\n'
                'esac\n')
            (commands / "ps").write_text(
                '#!/bin/bash\ncase "$3" in\n'
                '101) echo "$FIXTURE_ROOT/dev/Cotabby Dev.app/Contents/MacOS/Cotabby Dev";;\n'
                '102) echo "$FIXTURE_ROOT/production/Cotabby Dev.app/Contents/MacOS/Cotabby Dev";;\n'
                '103) echo "$FIXTURE_ROOT/other/Cotabby Dev.app/Contents/MacOS/Cotabby Dev";;\n'
                '104) exit 1;;\nesac\n')
            for command in commands.iterdir():
                command.chmod(0o755)
            script = (ROOT / "scripts/build_and_run.sh").read_text()
            function = script.split("dev_pids() {", 1)[1].split("\n}", 1)[0]
            probe = 'set -euo pipefail\nAPP_NAME="Cotabby Dev"\nBUNDLE_ID=com.jacobfu.tabby.dev\n'
            probe += "dev_pids() {" + function + "\n}\ndev_pids\n"
            result = subprocess.run(["bash", "-c", probe], check=True, capture_output=True, text=True,
                                    env={**os.environ, "FIXTURE_ROOT": str(root),
                                         "PATH": str(commands) + os.pathsep + os.environ["PATH"]})
            self.assertEqual(result.stdout.splitlines(), ["101"])
