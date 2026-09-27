"""Verify test-DMG cleanup cannot touch another build's products."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class TestDMGOwnershipTests(unittest.TestCase):
    def test_each_invocation_cleans_only_its_own_directory(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            shared = root / 'build/DerivedData'
            shared.mkdir(parents=True)
            sentinel = shared / 'existing-product'
            sentinel.write_text('another build')
            scripts = root / 'scripts'
            scripts.mkdir()
            probe = scripts / 'probe.sh'
            setup = (ROOT / 'scripts/build_test_dmg.sh').read_text().split('APP_PATH=', 1)[0]
            probe.write_text(setup + 'printf "%s\\n" "$DERIVED_DATA"\nread -r release\n')
            processes = []
            try:
                for _ in range(2):
                    processes.append(subprocess.Popen(
                        ['bash', str(probe)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                        stderr=subprocess.PIPE, text=True, env={**os.environ, 'TMPDIR': str(root)}))
                paths = [Path(process.stdout.readline().strip()) for process in processes]
                self.assertNotEqual(paths[0], paths[1])
                for path in paths:
                    self.assertNotEqual(path, shared)
                    self.assertTrue(path.is_dir())
                    self.assertEqual(path.parent.resolve(), root.resolve())
            finally:
                for process in processes:
                    _, errors = process.communicate('\n', timeout=10)
                    self.assertEqual(process.returncode, 0, errors)
            self.assertTrue(all(not path.exists() for path in paths))
            self.assertEqual(sentinel.read_text(), 'another build')
