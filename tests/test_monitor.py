import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


@unittest.skipUnless(sys.platform == 'darwin' and shutil.which('swiftc'), 'Requires macOS and Swift')
class MonitorSettingsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        directory = Path(cls.tmp.name)
        source = Path('agent/ForegroundMonitor.swift').read_text().split('@main\nstruct MonitorMain')[0]
        harness = directory / 'MonitorHarness.swift'
        harness.write_text(source + '''
@main struct Harness {
    static func main() {
        do {
            let settings = try JSONDecoder().decode(MonitorSettings.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
            _ = try ForegroundMonitor(settings: settings, queueURL: URL(fileURLWithPath: CommandLine.arguments[2]))
        } catch { exit(1) }
    }
}
''')
        cls.binary = directory / 'monitor-settings-test'
        subprocess.run(['swiftc', '-module-cache-path', str(directory / 'modules'),
                        'agent/FocusTracker.swift', str(harness), '-framework', 'AppKit',
                        '-framework', 'IOKit', '-o', str(cls.binary)], check=True, capture_output=True)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def test_http_requires_explicit_development_and_loopback(self):
        directory = Path(self.tmp.name)
        settings = directory / 'settings.json'
        for development, url, expected in [
            (False, 'https://example.com', 0),
            (False, 'http://127.0.0.1:8765', 1),
            (True, 'http://127.0.0.1:8765', 0),
            (True, 'http://example.com', 1),
            (True, 'http://127.0.0.1:8765/path', 1),
            (True, 'http://user@127.0.0.1:8765', 1),
        ]:
            with self.subTest(development=development, url=url):
                settings.write_text(json.dumps(dict(serverURL=url, activityToken='a' * 40)))
                env = dict(os.environ, ORBIT_MONITOR_DEVELOPMENT='1' if development else '0')
                result = subprocess.run([str(self.binary), str(settings), str(directory / 'queue.json')], env=env, capture_output=True)
                self.assertEqual(result.returncode, expected, result.stderr)

    def test_invalid_activity_credentials_are_rejected(self):
        directory = Path(self.tmp.name)
        settings = directory / 'settings.json'
        for value in ['short', 'a' * 513, 'a' * 40 + '\n', 'a' * 40 + ' ', 'é' * 40]:
            with self.subTest(length=len(value)):
                settings.write_text(json.dumps(dict(serverURL='https://example.com', activityToken=value)))
                result = subprocess.run([str(self.binary), str(settings), str(directory / 'queue.json')], capture_output=True)
                self.assertEqual(result.returncode, 1)
