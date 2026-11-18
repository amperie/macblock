import json
import os
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

        source = Path('packaging/Setup.swift').read_text().split('umask(0o077)')[0]
        harness = Path(cls.temporary.name) / 'main.swift'
        harness.write_text(source + '\ndo {\n    if CommandLine.arguments[1] == "monitor-payload" {\n        let credentials = try readInput()\n        let data = try JSONEncoder().encode(MonitorCredentials(serverURL: credentials.serverURL, activityToken: credentials.activityToken))\n        FileHandle.standardOutput.write(data)\n    } else {\n        try checkExistingConfiguration(settings: URL(fileURLWithPath: CommandLine.arguments[1]), cache: URL(fileURLWithPath: CommandLine.arguments[2]), serverURL: CommandLine.arguments[3])\n    }\n} catch { exit(1) }\n')
        cls.harness = str(Path(cls.temporary.name) / 'setup-check')
        subprocess.run(['swiftc', '-module-cache-path', str(Path(cls.temporary.name) / 'cache'),
                        str(harness), '-o', cls.harness], check=True, capture_output=True)

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

    def test_monitor_payload_does_not_receive_device_credential(self):
        credentials = dict(serverURL='https://orbit.side-forge.com', deviceToken='d' * 40, activityToken='a' * 40)
        result = subprocess.run([self.harness, 'monitor-payload'], input=json.dumps(credentials), text=True, capture_output=True, check=True)
        payload = json.loads(result.stdout)
        self.assertEqual(set(payload), {'serverURL', 'activityToken'})
        self.assertNotIn(credentials['deviceToken'], result.stdout)
        accepted = subprocess.run([self.binary, '--check-monitor-input'], input=result.stdout, text=True, capture_output=True)
        self.assertEqual(accepted.returncode, 0)

    def test_fragmented_credential_pipe_is_read_to_eof(self):
        import time
        body = json.dumps(dict(serverURL='https://orbit.side-forge.com', deviceToken='d' * 40, activityToken='a' * 40))
        process = subprocess.Popen([self.binary, '--check-input'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            process.stdin.write(body[:20]); process.stdin.flush()
            time.sleep(0.05)
            process.stdin.write(body[20:]); process.stdin.close(); process.stdin = None
            _, error = process.communicate(timeout=5)
            self.assertEqual(process.returncode, 0, error)
        finally:
            if process.poll() is None:
                process.kill(); process.communicate()

    def test_cached_policy_cannot_be_reassigned_after_missing_or_corrupt_settings(self):
        with tempfile.TemporaryDirectory() as directory:
            settings = Path(directory) / 'settings.json'
            cache = Path(directory) / 'policy.json'
            def check(expected):
                result = subprocess.run([self.harness, str(settings), str(cache), 'https://orbit.side-forge.com'], capture_output=True)
                self.assertEqual(result.returncode, expected)
            check(0)
            cache.write_text('{}')
            check(1)
            settings.write_text('bad JSON')
            check(1)
            settings.write_text('{}')
            check(1)
            settings.write_text(json.dumps(dict(serverURL='https://other.example', deviceToken='d' * 40)))
            check(1)
            settings.write_text(json.dumps(dict(serverURL='https://ORBIT.side-forge.com:443/', deviceToken='d' * 40)))
            check(0)


@unittest.skipUnless(sys.platform == 'darwin' and os.environ.get('ORBIT_TEST_PACKAGE'), 'Set ORBIT_TEST_PACKAGE to verify a built installer')
class PackagePayloadTests(unittest.TestCase):
    def test_universal_payload_permissions_and_checksum(self):
        import hashlib
        import os
        import plistlib
        archive = Path(os.environ['ORBIT_TEST_PACKAGE']).resolve()
        checksum = Path(str(archive) + '.sha256').read_text().split()
        self.assertEqual(checksum, [hashlib.sha256(archive.read_bytes()).hexdigest(), archive.name])
        with tempfile.TemporaryDirectory() as directory:
            extracted = Path(directory) / 'extracted'
            subprocess.run(['/usr/bin/ditto', '-x', '-k', str(archive), str(extracted)], check=True, capture_output=True)
            bundle = extracted / 'Orbit-Installer'
            self.assertEqual({path.name for path in bundle.iterdir()}, {'Orbit.pkg', 'OrbitSetup', 'Install Orbit.command', 'README.txt'})
            expanded = Path(directory) / 'expanded'
            subprocess.run(['/usr/sbin/pkgutil', '--expand-full', str(bundle / 'Orbit.pkg'), str(expanded)], check=True, capture_output=True)
            payload = expanded / 'Payload'
            for name in ['Library', 'Library/PrivilegedHelperTools', 'Library/LaunchDaemons', 'usr', 'usr/local', 'usr/local/libexec']:
                self.assertEqual((payload / name).stat().st_mode & 0o777, 0o755, name)
            for name in ['Library/PrivilegedHelperTools/orbit-agent', 'usr/local/libexec/orbit-foreground', 'usr/local/libexec/orbit-setup']:
                binary = payload / name
                self.assertEqual(binary.stat().st_mode & 0o777, 0o755)
                subprocess.run(['/usr/bin/lipo', str(binary), '-verify_arch', 'arm64', 'x86_64'], check=True, capture_output=True)
                subprocess.run(['/usr/bin/codesign', '--verify', '--strict', str(binary)], check=True, capture_output=True)
            daemon = payload / 'Library/LaunchDaemons/com.side-forge.orbit.agent.plist'
            self.assertEqual(daemon.stat().st_mode & 0o777, 0o644)
            properties = plistlib.loads(daemon.read_bytes())
            self.assertEqual(properties['ProgramArguments'], ['/Library/PrivilegedHelperTools/orbit-agent'])
            self.assertTrue(properties['RunAtLoad'])
            self.assertTrue(properties['KeepAlive'])
            self.assertFalse(list(payload.rglob('*settings.json')))
