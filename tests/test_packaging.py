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
        harness.write_text(source + '\ndo {\n    if CommandLine.arguments[1] == "monitor-payload" {\n        let credentials = try readInput()\n        let data = try JSONEncoder().encode(MonitorCredentials(serverURL: credentials.serverURL, activityToken: credentials.activityToken))\n        FileHandle.standardOutput.write(data)\n    } else if CommandLine.arguments[1] == "stage-package" {\n        let staged = try stagePackage(URL(fileURLWithPath: CommandLine.arguments[2]), in: URL(fileURLWithPath: CommandLine.arguments[3]))\n        print(staged.path)\n    } else if CommandLine.arguments[1] == "quote" {\n        print(try run("/bin/sh", ["-c", "printf \'%s\' " + shellQuote(CommandLine.arguments[2])], capture: true))\n    } else {\n        try checkExistingConfiguration(settings: URL(fileURLWithPath: CommandLine.arguments[1]), cache: URL(fileURLWithPath: CommandLine.arguments[2]), serverURL: CommandLine.arguments[3])\n    }\n} catch { exit(1) }\n')
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

    def test_chrome_profile_uses_system_scope_and_separate_managed_storage(self):
        import plistlib
        payload = json.dumps(dict(serverURL='https://orbit.side-forge.com', browserToken='b' * 40))
        result = subprocess.run([self.binary, '--check-chrome-profile', 'a' * 32],
                                input=payload.encode(), capture_output=True, check=True)
        profile = plistlib.loads(result.stdout)
        self.assertEqual(profile['PayloadScope'], 'System')
        chromePayload, storagePayload = profile['PayloadContent']
        self.assertEqual(chromePayload['PayloadType'], 'com.apple.ManagedClient.preferences')
        self.assertEqual(storagePayload['PayloadType'], 'com.apple.ManagedClient.preferences')
        chrome = chromePayload['PayloadContent']['com.google.Chrome']['Forced'][0]['mcx_preference_settings']
        storage = storagePayload['PayloadContent']['com.google.Chrome.extensions.' + 'a' * 32]['Forced'][0]['mcx_preference_settings']
        self.assertEqual(chrome['IncognitoModeAvailability'], 1)
        self.assertIs(chrome['BrowserGuestModeEnabled'], False)
        self.assertEqual(chrome['ExtensionSettings']['a' * 32]['installation_mode'], 'force_installed')
        self.assertEqual(storage['browserToken'], 'b' * 40)
        for bad in ['short', 'z' * 32, '../bad', 'a' * 32 + '\n']:
            result = subprocess.run([self.binary, '--check-chrome-profile', bad],
                                    input=payload.encode(), capture_output=True)
            self.assertNotEqual(result.returncode, 0)

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

    def test_stages_and_validates_package_from_path_with_spaces_and_apostrophe(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "Parent's Downloads"
            source.mkdir()
            payload = Path(directory) / 'payload'
            payload.mkdir()
            (payload / 'fixture.txt').write_text('Installer staging regression fixture')
            package = source / 'Orbit.pkg'
            subprocess.run(['/usr/bin/pkgbuild', '--root', str(payload), '--identifier', 'com.side-forge.orbit.test', '--version', '1.0', str(package)], check=True, capture_output=True)
            staging = Path(directory) / 'staging'
            staging.mkdir(mode=0o700)
            result = subprocess.run([self.harness, 'stage-package', str(package), str(staging)], check=True, capture_output=True, text=True)
            staged = Path(result.stdout.strip())
            self.assertEqual(staged, staging / 'Orbit.pkg')
            self.assertEqual(staged.read_bytes(), package.read_bytes())
            self.assertEqual(staged.stat().st_mode & 0o777, 0o600)
            self.assertFalse((staging / 'package-check').exists())

    def test_invalid_package_is_rejected_before_provisioning(self):
        with tempfile.TemporaryDirectory() as directory:
            package = Path(directory) / 'broken.pkg'
            package.write_text('Not a package')
            staging = Path(directory) / 'staging'
            staging.mkdir()
            result = subprocess.run([self.harness, 'stage-package', str(package), str(staging)], capture_output=True)
            self.assertNotEqual(result.returncode, 0)

    def test_elevated_command_path_quoting(self):
        path = "/tmp/Parent's Folder/Orbit.pkg"
        result = subprocess.run([self.harness, 'quote', path], check=True, capture_output=True, text=True)
        self.assertEqual(result.stdout.strip(), path)


@unittest.skipUnless(sys.platform == 'darwin' and shutil.which('swiftc'), 'Requires macOS and Swift')
class UninstallerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory()
        root = Path(cls.temporary.name)
        cls.binary = str(root / 'uninstall')
        subprocess.run(['swiftc', '-module-cache-path', str(root / 'cache'),
                        'packaging/Uninstall.swift', '-o', cls.binary], check=True, capture_output=True)
        source = Path('packaging/Uninstall.swift').read_text().split('do {\n    let args = Array(CommandLine.arguments.dropFirst())')[0]
        harness = root / 'main.swift'
        harness.write_text(source + r'''
do {
    if CommandLine.arguments[1] == "profile-cleanup" {
        let mode = CommandLine.arguments[2]
        var calls: [[String]] = []
        var listed = 0
        let result = removeChromeProfiles(users: ["child", "parent"]) { path, arguments in
            calls.append([path] + arguments)
            if arguments[0] == "list" {
                listed += 1
                if mode == "unknown" { return "malformed" }
                if mode == "unexpected-shape" {
                    return "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>error</key><string>Unavailable</string></dict></plist>"
                }
                let present = mode == "refused" || (mode != "absent" && listed == 1)
                let object: [String: Any] = ["_computerlevel": present ? [["ProfileIdentifier": chromeProfileIdentifier]] : []]
                let data = try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)
                return String(data: data, encoding: .utf8)!
            }
            return "" // Success exit code alone is insufficient evidence.
        }
        let data = try JSONSerialization.data(withJSONObject: ["removed": result, "calls": calls])
        FileHandle.standardOutput.write(data)
    } else { try removeFile(CommandLine.arguments[1]) }
} catch { exit(1) }
''')
        cls.harness = str(root / 'remove-file')
        subprocess.run(['swiftc', '-module-cache-path', str(root / 'cache'), str(harness), '-o', cls.harness],
                       check=True, capture_output=True)

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def test_uninstall_requires_admin_before_any_changes(self):
        if os.getuid() == 0:
            self.skipTest('Requires unprivileged caller')
        for args in [['--remove'], ['--remove', '--purge']]:
            result = subprocess.run([self.binary, *args], capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)
            self.assertIn('administrator authorization', result.stderr)

    def test_default_plan_preserves_credentials_and_queue(self):
        def plan(*args):
            return json.loads(subprocess.check_output([self.binary, '--plan', *args], text=True))
        keep, purge = plan(), plan('--purge')
        self.assertFalse(keep['purgeLocalData'])
        self.assertFalse(keep['touchesVPS'])
        self.assertTrue(keep['attemptsChromeProfileRemoval'])
        self.assertEqual(keep['chromeProfileIdentifier'], 'com.side-forge.orbit.chrome.configuration')
        self.assertFalse(keep['deletesChromeBrowsingData'])
        self.assertTrue(any(path.endswith('Orbit-Chrome.mobileconfig') for path in keep['userFiles']))
        self.assertTrue(purge['purgeLocalData'])
        self.assertTrue(set(keep['userFiles']) < set(purge['userFiles']))
        self.assertFalse(any(path.endswith('monitor-settings.json') for path in keep['userFiles']))
        self.assertTrue(any(path.endswith('monitor-settings.json') for path in purge['userFiles']))
        self.assertTrue(all('/Orbit/' in path or '/LaunchAgents/com.side-forge.orbit.' in path for path in purge['userFiles']))

    def test_profile_removal_verifies_absence_and_handles_legacy_user_scope(self):
        for mode in ['removed', 'absent', 'refused', 'unknown', 'unexpected-shape']:
            with self.subTest(mode=mode):
                result = json.loads(subprocess.check_output([self.harness, 'profile-cleanup', mode], text=True))
                self.assertEqual(result['removed'], mode in ['removed', 'absent'])
                removal = [args for args in result['calls'] if args[1] == 'remove']
                if mode == 'absent':
                    self.assertEqual(removal, [])
                else:
                    self.assertEqual(len(removal), 3)
                    self.assertTrue(all('-forced' in args for args in removal))
                    self.assertTrue(all('com.side-forge.orbit.chrome.configuration' in args for args in removal))
                    self.assertEqual(removal[1][-2:], ['-user', 'child'])
                    self.assertEqual(removal[2][-2:], ['-user', 'parent'])

    def test_file_removal_does_not_follow_symlinks_or_remove_directories(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = root / 'keep.txt'
            target.write_text('preserve')
            link = root / 'link'
            link.symlink_to(target)
            subprocess.run([self.harness, str(link)], check=True)
            self.assertFalse(link.is_symlink())
            self.assertEqual(target.read_text(), 'preserve')
            subprocess.run([self.harness, str(link)], check=True)  # Idempotent.
            result = subprocess.run([self.harness, directory])
            self.assertEqual(result.returncode, 1)
            self.assertTrue(target.exists())


@unittest.skipUnless(sys.platform == 'darwin' and os.environ.get('ORBIT_TEST_PACKAGE'), 'Set ORBIT_TEST_PACKAGE to verify a built installer')
class PackagePayloadTests(unittest.TestCase):
    def test_web_store_archive_contains_only_extension_sources(self):
        import zipfile
        archive = Path(os.environ['ORBIT_TEST_PACKAGE']).resolve().with_name('Orbit-Chrome-WebStore.zip')
        with zipfile.ZipFile(archive) as extension:
            self.assertEqual(set(extension.namelist()), {'manifest.json', 'background.js', 'managed_schema.json'})
            for name in extension.namelist():
                self.assertEqual(extension.read(name), (Path('browser/chrome') / name).read_bytes())
            manifest = json.loads(extension.read('manifest.json'))
            self.assertEqual(manifest['manifest_version'], 3)
            self.assertEqual(manifest['storage']['managed_schema'], 'managed_schema.json')

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
            self.assertEqual({path.name for path in bundle.iterdir()}, {'Orbit.pkg', 'OrbitSetup', 'OrbitUninstall', 'Install Orbit.command', 'Uninstall Orbit.command', 'README.txt'})
            expanded = Path(directory) / 'expanded'
            subprocess.run(['/usr/sbin/pkgutil', '--expand-full', str(bundle / 'Orbit.pkg'), str(expanded)], check=True, capture_output=True)
            payload = expanded / 'Payload'
            for name in ['Library', 'Library/PrivilegedHelperTools', 'Library/LaunchDaemons', 'usr', 'usr/local', 'usr/local/libexec']:
                self.assertEqual((payload / name).stat().st_mode & 0o777, 0o755, name)
            for name in ['Library/PrivilegedHelperTools/orbit-agent', 'usr/local/libexec/orbit-foreground', 'usr/local/libexec/orbit-setup', 'usr/local/libexec/orbit-uninstall']:
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
