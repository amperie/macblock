import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.request
import socket

spec = importlib.util.spec_from_file_location('dev', 'tools/dev.py')
dev = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dev)


class DevSetupTests(unittest.TestCase):
    def test_setup_reuses_credentials_and_keeps_state_private(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory, first = dev.setup(Path(temporary) / 'local', 8765)
            _, second = dev.setup(directory)
            self.assertEqual(first, second)
            self.assertEqual(len({first[key] for key in ('adminToken', 'deviceToken', 'activityToken', 'browserToken')}), 4)
            self.assertEqual((directory / 'dev.json').stat().st_mode & 0o777, 0o600)
            settings = json.loads((directory / 'agent/settings.json').read_text())
            self.assertEqual(settings['serverURL'], 'http://127.0.0.1:8765')
            with self.assertRaises(ValueError):
                dev.setup(directory, 9999)

    def test_existing_local_credentials_gain_monitor_and_browser_tokens(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            old = dict(port=8765, adminToken='a' * 40, deviceToken='b' * 40)
            (directory / 'dev.json').write_text(json.dumps(old))
            _, config = dev.setup(directory)
            self.assertEqual(config['adminToken'], old['adminToken'])
            self.assertEqual(config['deviceToken'], old['deviceToken'])
            self.assertEqual(len({config[key] for key in ('adminToken', 'deviceToken', 'activityToken', 'browserToken')}), 4)
            self.assertEqual(dev.setup(directory)[1], config)


@unittest.skipUnless(sys.platform == 'darwin', 'Requires macOS process signing')
class LocalSystemTests(unittest.TestCase):
    def test_dry_run_then_enforcement_and_offline_restart(self):
        with tempfile.TemporaryDirectory() as temporary:
            with socket.socket() as listener:
                listener.bind(('127.0.0.1', 0))
                port = listener.getsockname()[1]
            directory, config = dev.setup(Path(temporary), port)
            dev.build(directory)
            children = []
            def start(command):
                child = subprocess.Popen(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
                children.append(child)
                return child
            def command(mode, *args):
                return [sys.executable, str(dev.PROJECT / 'tools/dev.py'), mode, '--state-dir', str(directory), *args]
            def eventually(predicate, timeout=15):
                deadline = time.monotonic() + timeout
                while time.monotonic() < deadline:
                    try:
                        if predicate():
                            return
                    except (OSError, ValueError):
                        pass
                    time.sleep(0.1)
                self.fail('Local system condition did not become true')
            def api(path, payload=None):
                request = urllib.request.Request(f'http://127.0.0.1:{port}' + path,
                    data=json.dumps(payload).encode() if payload is not None else None,
                    headers={'Authorization': 'Bearer ' + config['adminToken'], 'Content-Type': 'application/json'})
                with urllib.request.urlopen(request, timeout=1) as response:
                    return json.load(response)
            try:
                server = start(command('server'))
                eventually(lambda: api('/api/admin/state'))
                agent = start(command('agent', '--no-build', '--poll-seconds', '1'))
                eventually(lambda: api('/api/admin/state')['device'])
                self.assertIn('dry-run', api('/api/admin/state')['device']['report']['agentVersion'])
                fixture = start(command('fixture'))
                eventually(lambda: (directory / 'Orbit-Test-App').exists())
                policy = api('/api/admin/state')['policy']
                policy['apps'].append(dict(name='Test App', bundleId='org.orbit.debug.fixture', blocked=True))
                updated = api('/api/admin/policy', policy)
                eventually(lambda: api('/api/admin/state')['device']['report']['revision'] == updated['revision'])
                time.sleep(2.5)
                self.assertEqual(api('/api/admin/state')['device']['report']['lastError'], '')
                self.assertIsNone(fixture.poll(), 'Dry run must not kill the fixture')
                dev.stop(agent)
                agent = start(command('agent', '--no-build', '--enforce', '--poll-seconds', '1'))
                eventually(lambda: fixture.poll() is not None)
                self.assertEqual(fixture.returncode, -signal.SIGKILL)
                # Restart both agent and fixture with the server unavailable.
                dev.stop(agent)
                dev.stop(server)
                fixture = start(command('fixture'))
                agent = start(command('agent', '--no-build', '--enforce', '--poll-seconds', '1'))
                eventually(lambda: fixture.poll() is not None)
                self.assertEqual(fixture.returncode, -signal.SIGKILL, 'Cached rules must work after an offline restart')
            finally:
                for child in reversed(children):
                    dev.stop(child)

    def test_combined_launcher_stops_its_children(self):
        with tempfile.TemporaryDirectory() as temporary:
            with socket.socket() as listener:
                listener.bind(('127.0.0.1', 0))
                port = listener.getsockname()[1]
            directory, config = dev.setup(Path(temporary), port)
            runner = subprocess.Popen([sys.executable, str(dev.PROJECT / 'tools/dev.py'), 'all', '--state-dir', str(directory)],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
            request = urllib.request.Request(f'http://127.0.0.1:{port}/api/admin/state', headers={'Authorization': 'Bearer ' + config['adminToken']})
            try:
                deadline = time.monotonic() + 20
                while time.monotonic() < deadline:
                    self.assertIsNone(runner.poll(), 'Combined launcher exited early')
                    try:
                        with urllib.request.urlopen(request, timeout=0.5) as response:
                            if json.load(response)['device']:
                                break
                    except OSError:
                        pass
                    time.sleep(0.1)
                else:
                    self.fail('Combined launcher did not start the system')
            finally:
                dev.stop(runner)
            with self.assertRaises(OSError):
                urllib.request.urlopen(request, timeout=0.5)
            # Every child command includes this isolated state path.
            processes = subprocess.run(['/bin/ps', '-axo', 'command='], capture_output=True, text=True, check=True).stdout
            self.assertNotIn(str(directory), processes, 'Launcher must not leave its agent running')
