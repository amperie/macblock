import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


@unittest.skipUnless(sys.platform == 'darwin' and shutil.which('swiftc'), 'Requires macOS and Swift')
class InstallerSetupTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory()
        cls.binary = str(Path(cls.temporary.name) / 'setup')
        subprocess.run(['swiftc', '-module-cache-path', str(Path(cls.temporary.name) / 'cache'),
                        'packaging/Setup.swift', '-o', cls.binary], check=True, capture_output=True)

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def test_credentials_reject_wrong_origins_and_invalid_or_shared_tokens(self):
        base = dict(serverURL='https://orbit.side-forge.com', deviceToken='d' * 40, activityToken='a' * 40)
        cases = [(base, True), (dict(base, serverURL='http://example.com'), False),
                 (dict(base, serverURL='https://user@example.com'), False),
                 (dict(base, serverURL='https://example.com/path'), False),
                 (dict(base, serverURL='https://example.com/#token=secret'), False),
                 (dict(base, activityToken='d' * 40), False),
                 (dict(base, deviceToken='short'), False),
                 (dict(base, deviceToken='d' * 40 + '\n'), False)]
        for payload, valid in cases:
            with self.subTest(payload=payload):
                result = subprocess.run([self.binary, '--check-input'], input=json.dumps(payload),
                                        text=True, capture_output=True)
                self.assertEqual(result.returncode, 0 if valid else 1, result.stderr)
                self.assertNotIn(payload['deviceToken'], result.stdout + result.stderr)

    def test_configuration_rejects_unprivileged_caller(self):
        import os
        if os.getuid() == 0:
            self.skipTest('This check requires an unprivileged caller')
        result = subprocess.run([self.binary, '--configure', 'root'], input='', text=True, capture_output=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn('administrator authorization', result.stderr)

    def test_oversized_input_is_rejected(self):
        result = subprocess.run([self.binary, '--check-input'], input='x' * 8193, text=True, capture_output=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn('too large', result.stderr)
