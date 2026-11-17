import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
import uuid

@unittest.skipUnless(sys.platform == 'darwin' and shutil.which('swiftc'), 'Requires macOS and Swift')
class AgentValidationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.binary = str(Path(cls.tmp.name) / 'agent')
        subprocess.run(['swiftc', '-module-cache-path', str(Path(cls.tmp.name) / 'modules'),
                        'agent/main.swift', '-framework', 'Security', '-o', cls.binary], check=True, capture_output=True)

        # Exercise the production enforcement function without installing a daemon.
        harness = Path(cls.tmp.name) / 'main.swift'
        source = Path('agent/main.swift').read_text().split('if CommandLine.arguments.contains("--check-schedule")')[0]
        harness.write_text(source + '\nlet p = try decoder.decode(Policy.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))\ntry p.validate()\nprint(enforce(p))\n')
        cls.harness = str(Path(cls.tmp.name) / 'enforce-once')
        subprocess.run(['swiftc', '-module-cache-path', str(Path(cls.tmp.name) / 'modules'),
                        str(harness), '-framework', 'Security', '-o', cls.harness], check=True, capture_output=True)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def check(self, mode, payload, valid):
        path = Path(self.tmp.name) / 'input.json'
        path.write_text(json.dumps(payload))
        result = subprocess.run([self.binary, mode, str(path)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0 if valid else 1, result.stderr)

    def test_settings_validation_before_install(self):
        for url, valid in [('https://example.com', True), ('https://example.com/', True),
                           ('http://example.com', False), ('https://example.com/path', False),
                           ('https://user:password@example.com', False), ('https://example.com?q=x', False)]:
            self.check('--check-settings', dict(serverURL=url, deviceToken='a' * 40), valid)
        self.check('--check-settings', dict(serverURL='https://example.com', deviceToken='a' * 40 + '\n'), False)

    def test_development_options_are_explicit(self):
        for arguments in [['--enforce'], ['--poll-seconds', '1'], ['--dev', '--poll-seconds', '0'], ['--dev', '--poll-seconds', 'nan']]:
            result = subprocess.run([self.binary, *arguments], capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)
            self.assertIn('Usage:', result.stderr)

    def test_development_rejects_http_beyond_loopback(self):
        state = Path(self.tmp.name) / 'invalid-server'
        state.mkdir(exist_ok=True)
        (state / 'settings.json').write_text(json.dumps(dict(serverURL='http://example.com', deviceToken='a' * 40)))
        result = subprocess.run([self.binary, '--dev', '--state-dir', str(state)], capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 1)
        self.assertIn('Invalid or missing Orbit settings', result.stderr)

    def test_policy_validation(self):
        base = dict(schemaVersion=1, revision=1, apps=[])
        self.check('--check-policy', base, True)
        self.check('--check-policy', dict(base, revision=2**53), False)
        for identifier, name, valid in [('com.operasoftware.Opera', 'Opera', True),
                                        ('com.apple.finder', 'Finder', False),
                                        ('com.example.app', '   ', False)]:
            self.check('--check-policy', dict(base, apps=[dict(name=name, bundleId=identifier, blocked=True)]), valid)

    def test_domain_policy_validation(self):
        base = dict(schemaVersion=1, revision=1, apps=[])
        self.check('--check-policy', dict(base, blockedDomains=['instagram.com', 'xn--bcher-kva.example']), True)
        for domains in [None, ['Instagram.com'], ['example.com\n'], ['127.0.0.1'], ['0x7f.0x1'], ['*.example.com'], ['example.com'] * 2]:
            self.check('--check-policy', dict(base, blockedDomains=domains), False)

    def test_signed_renamed_process_is_killed_only_when_blocked(self):
        identifier = 'org.orbittest.fixture.' + uuid.uuid4().hex
        source = Path(self.tmp.name) / 'fixture.c'
        source.write_text('#include <unistd.h>\nint main(void) { for (;;) sleep(1); }\n')
        fixture = Path(self.tmp.name) / 'renamed-application'
        subprocess.run(['clang', str(source), '-o', str(fixture)], check=True, capture_output=True)
        subprocess.run(['codesign', '--force', '--sign', '-', '--identifier', identifier, str(fixture)], check=True, capture_output=True)
        child = subprocess.Popen([str(fixture)])
        try:
            path = Path(self.tmp.name) / 'enforce.json'
            def scan(blocked):
                path.write_text(json.dumps(dict(schemaVersion=1, revision=1, apps=[dict(name='Fixture', bundleId=identifier, blocked=blocked)])))
                result = subprocess.run([self.harness, str(path)], check=True, capture_output=True, text=True)
                if blocked:
                    self.assertIn('Sent SIGKILL to ' + identifier, result.stdout)
                else:
                    self.assertEqual(result.stdout.strip(), '')
            scan(False)
            self.assertIsNone(child.poll(), 'Allowed process should remain running')
            scan(True)
            self.assertEqual(child.wait(timeout=5), -9, 'Signed matching process should receive SIGKILL')
        finally:
            if child.poll() is None:
                child.kill()
            child.wait()
