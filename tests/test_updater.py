import base64
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


@unittest.skipUnless(sys.platform == 'darwin' and shutil.which('swiftc'), 'Requires macOS and CryptoKit')
class UpdaterTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.root = Path(cls.tmp.name)
        def compile(source, output):
            subprocess.run(['swiftc', '-module-cache-path', str(cls.root / 'modules'), str(source), '-o', str(output)], check=True, capture_output=True)
        cls.signer = cls.root / 'signer'
        compile('updater/Sign.swift', cls.signer)
        cls.updater = cls.root / 'updater'
        compile('updater/Updater.swift', cls.updater)
        source = Path('updater/Updater.swift').read_text().split('// CLI deliberately')[0]
        harness = cls.root / 'harness.swift'
        harness.write_text(source + r'''
do {
    let mode = CommandLine.arguments[1]
    if mode == "verify" {
        let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
        let sig = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3]))
        let manifest = try verifiedManifest(data, signature: sig, publicKey: CommandLine.arguments[4])
        let state = UpdateState(sequence: Int(CommandLine.arguments[5])!, failedSequence: Int(CommandLine.arguments[6])!, version: "test")
        print(newer(manifest, state: state, baseline: Int(CommandLine.arguments[7])!) ? "new" : "skip")
    } else if mode == "digest" {
        let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
        try verifyArtifact(data, Artifact(url:"https://example.test/a", sha256:CommandLine.arguments[3], size:Int(CommandLine.arguments[4])!))
    } else if mode == "recover" {
        var state = UpdateState(sequence: CommandLine.arguments[2] == "stale" ? 3 : (CommandLine.arguments[2] == "committed" ? 2 : 1), failedSequence: CommandLine.arguments[2] == "rolled-back" ? 2 : 0, version:"old")
        var events: [String] = []
        let failure = CommandLine.arguments[2]
        do {
            try recoverTransaction(Journal(sequence:2, version:"new", monitors:[]), state:&state,
                validateBackups: { if failure == "backup-check" { throw UpdateError.invalid("backup integrity failure") } },
                restore: { name in events.append("restore-" + name); if failure == name { throw UpdateError.invalid("injected") } },
                restartServices: { _ in events.append("restart"); if failure == "restart" { throw UpdateError.invalid("injected") } },
                persist: { _ in events.append("save"); if failure == "save" { throw UpdateError.invalid("injected") } },
                removeJournal: { events.append("cleanup"); if failure == "cleanup" { throw UpdateError.invalid("injected cleanup interruption") } })
        } catch { events.append("failed") }
        if failure == "cleanup" {
            try recoverTransaction(Journal(sequence:2,version:"new",monitors:[]),state:&state,
                restore:{ name in events.append("unnecessary-restore-" + name) },
                restartServices:{ _ in events.append("unnecessary-restart") },
                persist:{ _ in events.append("unnecessary-save") },
                removeJournal:{ events.append("cleanup-retry") })
        }
        let result: [String:Any] = ["events":events, "sequence":state.sequence, "failedSequence":state.failedSequence]
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:result))
    } else if mode == "stale-receipt" {
        let data = try JSONSerialization.data(withJSONObject:["pid":123,"version":"1.0.2","at":105.0])
        print(validReceipt(data,pid:123,version:"1.0.2",since:Date(timeIntervalSince1970:100),now:Date(timeIntervalSince1970:250)))
    } else if mode == "receipt" {
        let data = try FileHandle.standardInput.readToEnd() ?? Data()
        print(validReceipt(data, pid:123, version:"1.0.2", since:Date(timeIntervalSince1970:100), now:Date(timeIntervalSince1970:110)))
    } else if mode == "activate" {
        let failure = CommandLine.arguments[2]
        var events: [String] = []
        func step(_ name: String) throws {
            events.append(name)
            if failure == name { throw UpdateError.invalid("injected") }
        }
        do {
            try activateUpdate(install:{ try step("install") }, restartServices:{ try step("restart") },
                checkHealth:{ try step("health"); return failure != "unhealthy" },
                commit:{ try step("commit") }, rollback:{ try step("rollback") })
        } catch { events.append("failed") }
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:events))
    } else if mode == "ancestors" {
        let failure = CommandLine.arguments[2]
        try validateRootAncestors(URL(fileURLWithPath:"/usr/local/libexec")) { path in
            if path == "/usr/local" {
                if failure == "owned-by-user" { return (mode_t(S_IFDIR | 0o755),501) }
                if failure == "writable" { return (mode_t(S_IFDIR | 0o775),0) }
                if failure == "symlink" { return (mode_t(S_IFLNK | 0o777),0) }
            }
            return (mode_t(S_IFDIR | 0o755),0)
        }
    } else if mode == "backups" {
        let failure = CommandLine.arguments[2]
        let original = Data("old-binary".utf8)
        let hash = SHA256.hash(data:original).map { String(format:"%02x",$0) }.joined()
        var journal = Journal(sequence:2,version:"new",monitors:[],backupHashes:["agent":hash,"monitor":hash])
        if failure == "missing-hashes" { journal.backupHashes = nil }
        if failure == "partial-hashes" { journal.backupHashes = ["agent":hash] }
        try validateBackupHashes(journal) { name in
            failure == name ? Data("corrupt".utf8) : original
        }
    } else if mode == "state-for-run" {
        let root = URL(fileURLWithPath:CommandLine.arguments[2])
        let result = try stateForRun(root:root,recoveryOnly:CommandLine.arguments[3] == "maintenance") {
            throw UpdateError.invalid("corrupt state fixture")
        }
        print(result == nil ? "no-recovery-needed" : "loaded")
    } else if mode == "stable-health" {
        var stable = StableHealth()
        var result: [Bool] = []
        let a: [String:Int32] = ["agent":123,"monitor-501":456]
        let b: [String:Int32] = ["agent":124,"monitor-501":456]
        result.append(stable.observe(a,at:0))
        result.append(stable.observe(a,at:5))
        result.append(stable.observe(a,at:10))
        result.append(stable.observe(a,at:15))
        result.append(stable.observe(b,at:16))
        result.append(stable.observe(b,at:21))
        result.append(stable.observe(nil,at:22))
        result.append(stable.observe(b,at:23))
        result.append(stable.observe(b,at:28))
        result.append(stable.observe(b,at:33))
        result.append(stable.observe(b,at:38))
        result.append(stable.observe(b,at:60))
        result.append(stable.observe(b,at:65))
        result.append(stable.observe(b,at:70))
        result.append(stable.observe(b,at:75))
        result.append(stable.observe(b,at:20))
        result.append(stable.observe(b,at:25))
        result.append(stable.observe(b,at:30))
        result.append(stable.observe(b,at:35))
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:result))
    } else if mode == "lock" {
        let fd = try acquireUpdateLock(URL(fileURLWithPath:CommandLine.arguments[2]),owner:getuid())
        defer { close(fd) }
        guard (fcntl(fd,F_GETFD) & FD_CLOEXEC) != 0 else { throw UpdateError.invalid("Lock would leak into helpers") }
        print("locked"); fflush(stdout)
        if CommandLine.arguments.count > 3 { _ = FileHandle.standardInput.readDataToEndOfFile() }
    } else if mode == "monitors" {
        let services = mergeMonitorServices([MonitorService(uid:501,home:"old-home")],
            [MonitorService(uid:502,home:"new-login"),MonitorService(uid:501,home:"current-home")])
        FileHandle.standardOutput.write(try JSONEncoder().encode(services))
    } else if mode == "launchd" {
        let failure = CommandLine.arguments[2]
        let result = try launchdService("gui/501/test") { path, _ in
            if failure == "timeout" { throw UpdateError.invalid("timeout") }
            if failure == "missing" { throw CommandFailure(path:path,status:113,diagnostic:"Could not find service test") }
            if failure == "denied" { throw CommandFailure(path:path,status:1,diagnostic:"Operation not permitted") }
            return "pid = 123"
        }
        print(result == nil ? "absent" : "present")
    } else if mode == "execute" {
        let request = try JSONSerialization.jsonObject(with:FileHandle.standardInput.readDataToEndOfFile()) as! [String:Any]
        print(try execute(request["path"] as! String, request["arguments"] as! [String], timeout:0.25, outputLimit:4096))
    } else if mode == "config" {
        let config = try JSONDecoder().decode(UpdateConfig.self,from:FileHandle.standardInput.readDataToEndOfFile())
        try config.validate()
    } else if mode == "directory" {
        try secureDirectory(URL(fileURLWithPath:CommandLine.arguments[2]), owner:getuid())
    } else if mode == "read" {
        _ = try readFile(URL(fileURLWithPath:CommandLine.arguments[2]), owner:getuid())
    } else if mode == "write" {
        try durableWrite(Data("fixture".utf8), to:URL(fileURLWithPath:CommandLine.arguments[2]))
    }
} catch { exit(1) }
''')
        cls.harness = cls.root / 'harness'
        compile(harness, cls.harness)
        cls.key = cls.root / 'private-key'
        cls.public = subprocess.check_output([str(cls.signer), '--generate-key', str(cls.key)], text=True).strip()
        cls.manifest = dict(schemaVersion=1, sequence=2, version='1.0.2', artifacts={name:dict(url='https://example.test/' + name, sha256='a' * 64, size=50) for name in ['agent', 'monitor']})

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def signed(self, value=None):
        manifest = self.root / 'manifest.json'
        manifest.write_text(json.dumps(value or self.manifest))
        signature = self.root / 'manifest.sig'
        subprocess.run([str(self.signer), '--sign', str(manifest), str(signature), self.public], input=self.key.read_bytes(), check=True, capture_output=True)
        return manifest, signature

    def verify(self, manifest, signature, public=None, sequence=0, failed=0, baseline=0):
        return subprocess.run([str(self.harness), 'verify', str(manifest), str(signature), public or self.public, str(sequence), str(failed), str(baseline)], capture_output=True, text=True)

    def test_signature_and_anti_rollback(self):
        manifest, sig = self.signed()
        self.assertEqual(self.verify(manifest, sig).stdout.strip(), 'new')
        for args in [dict(sequence=2), dict(sequence=3), dict(baseline=2), dict(failed=2)]:
            self.assertEqual(self.verify(manifest, sig, **args).stdout.strip(), 'skip')
        manifest.write_bytes(manifest.read_bytes() + b' ')
        self.assertNotEqual(self.verify(manifest, sig).returncode, 0)
        manifest, sig = self.signed()
        sig.write_bytes(b'0' * 64)
        self.assertNotEqual(self.verify(manifest, sig).returncode, 0)
        manifest, sig = self.signed()
        self.assertNotEqual(self.verify(manifest, sig, public=base64.b64encode(b'x'*32).decode()).returncode, 0)

    def test_signed_malformed_manifests_are_rejected(self):
        cases = [dict(self.manifest, sequence=0), dict(self.manifest, schemaVersion=2), dict(self.manifest, version='../bad'),
                 dict(self.manifest, artifacts={'agent':self.manifest['artifacts']['agent']})]
        for field, bad in [('url','http://example.test/a'), ('url','https://user:secret@example.test/a'), ('url','https://example.test/a#fragment'),
                           ('sha256','bad'), ('size',20_000_001), ('size',0)]:
            value = json.loads(json.dumps(self.manifest))
            value['artifacts']['agent'][field] = bad
            cases.append(value)
        for value in cases:
            manifest, sig = self.signed(value)
            self.assertNotEqual(self.verify(manifest, sig).returncode, 0)

    def test_artifact_size_and_digest(self):
        path = self.root / 'artifact'
        path.write_bytes(b'fixture')
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        def check(hash_value, length):
            return subprocess.run([str(self.harness), 'digest', str(path), hash_value, str(length)], capture_output=True).returncode
        self.assertEqual(check(digest,7),0)
        self.assertNotEqual(check(digest,6),0)
        self.assertNotEqual(check('0'*64,7),0)

    def test_recovery_order_and_retry_on_partial_failure(self):
        expected = ['restore-agent','restore-monitor','restart','save','cleanup']
        for failure in ['none','agent','monitor','restart','save','committed','stale','rolled-back','cleanup','backup-check']:
            result = json.loads(subprocess.check_output([str(self.harness),'recover',failure],text=True))
            if failure == 'none':
                self.assertEqual(result['events'],expected)
                self.assertEqual(result['sequence'],1)
                self.assertEqual(result['failedSequence'],2)
            elif failure == 'backup-check':
                self.assertEqual(result['events'], ['failed'])
                self.assertEqual(result['failedSequence'], 0)
            elif failure == 'cleanup':
                self.assertEqual(result['events'], ['restore-agent','restore-monitor','restart','save','cleanup','failed','cleanup-retry'])
                self.assertEqual(result['failedSequence'], 2)
            elif failure == 'rolled-back':
                self.assertEqual(result['events'],['cleanup'])
                self.assertEqual(result['sequence'],1)
                self.assertEqual(result['failedSequence'],2)
            elif failure == 'committed':
                self.assertEqual(result['events'],['cleanup'])
                self.assertEqual(result['sequence'],2)
            elif failure == 'stale':
                self.assertEqual(result['events'], ['failed'])
                self.assertEqual(result['sequence'], 3)
            else:
                self.assertNotIn('cleanup',result['events'])
                self.assertEqual(result['events'][-1],'failed')
                self.assertEqual(result['sequence'],1)

    def test_activation_requires_health_and_rolls_back_on_errors(self):
        for failure in ['none','install','restart','health','unhealthy','commit']:
            result = json.loads(subprocess.check_output([str(self.harness),'activate',failure],text=True))
            if failure == 'none':
                self.assertEqual(result,['install','restart','health','commit'])
            else:
                self.assertEqual(result[-2:],['rollback','failed'])
                if failure != 'commit':
                    self.assertNotIn('commit',result)

    def test_health_requires_fresh_receipt_from_new_version_and_pid(self):
        valid = dict(pid=123,version='1.0.2',at=105.0)
        for value, expected in [(valid,True),(dict(valid,pid=124),False),(dict(valid,version='1.0.1'),False),
                                (dict(valid,at=99),False),(dict(valid,at=120),False),({},False)]:
            result = subprocess.check_output([str(self.harness),'receipt'],input=json.dumps(value),text=True)
            self.assertEqual(result.strip(),'true' if expected else 'false')

    def test_file_access_rejects_symlinks_and_world_writable_files(self):
        path = self.root / 'private'
        subprocess.run([str(self.harness),'write',str(path)],check=True)
        self.assertEqual(path.read_bytes(),b'fixture')
        self.assertEqual(path.stat().st_mode & 0o777,0o600)
        subprocess.run([str(self.harness),'read',str(path)],check=True)
        link = self.root / 'link'
        link.symlink_to(path)
        self.assertNotEqual(subprocess.run([str(self.harness),'read',str(link)],capture_output=True).returncode,0)
        path.chmod(0o666)
        self.assertNotEqual(subprocess.run([str(self.harness),'read',str(path)],capture_output=True).returncode,0)

    def test_staging_directory_is_private_durable_and_rejects_links(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp) / 'transaction'
            subprocess.run([str(self.harness),'directory',str(directory)],check=True)
            self.assertEqual(directory.stat().st_mode & 0o777, 0o700)
            subprocess.run([str(self.harness),'directory',str(directory)],check=True)
            link = Path(temp) / 'link'
            link.symlink_to(directory, target_is_directory=True)
            self.assertNotEqual(subprocess.run([str(self.harness),'directory',str(link)],capture_output=True).returncode,0)
            directory.chmod(0o777)
            self.assertNotEqual(subprocess.run([str(self.harness),'directory',str(directory)],capture_output=True).returncode,0)

    def test_publisher_manifest_round_trip(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / 'update-binaries').mkdir()
            for filename in ['orbit-agent', 'orbit-foreground']:
                (root / 'update-binaries' / filename).write_bytes(b'fixture-binary')
            subprocess.run([sys.executable, 'updater/publish.py', temp, '1.0.2', '2', 'https://example.test/releases/test'], check=True, capture_output=True)
            manifest, signature = root / 'update.json', root / 'update.json.sig'
            subprocess.run([str(self.signer), '--sign', str(manifest), str(signature), self.public], input=self.key.read_bytes(), check=True, capture_output=True)
            self.assertEqual(self.verify(manifest, signature).stdout.strip(), 'new')
            value = json.loads(manifest.read_text())
            self.assertEqual(value['artifacts']['agent']['sha256'], hashlib.sha256(b'fixture-binary').hexdigest())
            self.assertEqual(value['artifacts']['monitor']['url'], 'https://example.test/releases/test/orbit-foreground')
            subprocess.run([sys.executable, 'updater/publish.py', temp, '1.0.2', '2', 'https://example.test/releases/test', '-12345-2'], check=True, capture_output=True)
            value = json.loads(manifest.read_text())
            self.assertEqual(value['artifacts']['agent']['url'], 'https://example.test/releases/test/orbit-agent-12345-2')
            self.assertEqual(value['artifacts']['monitor']['url'], 'https://example.test/releases/test/orbit-foreground-12345-2')


    def test_system_commands_are_bounded_and_drain_output(self):
        import time
        def command(code):
            request = json.dumps(dict(path=sys.executable, arguments=['-c', code]))
            return subprocess.run([str(self.harness),'execute'], input=request, text=True, capture_output=True, timeout=4)
        self.assertEqual(command("print('ready')").stdout.strip(),'ready')
        self.assertNotEqual(command("print('x' * 10000)").returncode,0)
        self.assertNotEqual(command('raise SystemExit(2)').returncode,0)
        start = time.monotonic()
        result = command('import signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); time.sleep(30)')
        self.assertNotEqual(result.returncode,0)
        self.assertLess(time.monotonic() - start,3)

    def test_existing_configuration_rejects_query_and_invalid_key(self):
        valid = dict(enabled=True,publicKey=self.public,manifestURL='https://example.test/update.json')
        for value, expected in [(valid,0),(dict(valid,manifestURL='https://example.test/update.json?channel=test'),1),
                                (dict(valid,publicKey='bad'),1),(dict(valid,enabled=False,publicKey=''),0)]:
            result = subprocess.run([str(self.harness),'config'],input=json.dumps(value),text=True,capture_output=True)
            self.assertEqual(result.returncode,expected)

    def test_launchd_probe_errors_are_not_treated_as_logout(self):
        for mode, expected in [('missing','absent'), ('normal','present')]:
            result = subprocess.check_output([str(self.harness),'launchd',mode],text=True)
            self.assertEqual(result.strip(),expected)
        for mode in ['timeout','denied']:
            result = subprocess.run([str(self.harness),'launchd',mode],capture_output=True)
            self.assertNotEqual(result.returncode,0)

    def test_lock_exclusion_and_release_and_no_inheritance(self):
        with tempfile.TemporaryDirectory() as temp:
            path = str(Path(temp) / 'lock')
            holding = subprocess.Popen([str(self.harness),'lock',path,'hold'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
            try:
                self.assertEqual(holding.stdout.readline().strip(),'locked')
                other = subprocess.run([str(self.harness),'lock',path],capture_output=True)
                self.assertNotEqual(other.returncode,0)
            finally:
                holding.communicate(timeout=5)
            subprocess.run([str(self.harness),'lock',path],check=True,capture_output=True)
            link = Path(temp) / 'link'
            link.symlink_to(path)
            self.assertNotEqual(subprocess.run([str(self.harness),'lock',str(link)],capture_output=True).returncode,0)
            hardlink = Path(temp) / 'hardlink'
            os.link(path,hardlink)
            self.assertNotEqual(subprocess.run([str(self.harness),'lock',path],capture_output=True).returncode,0)

    def test_monitor_inventory_includes_new_sessions_and_current_home(self):
        result = json.loads(subprocess.check_output([str(self.harness),'monitors'],text=True))
        self.assertEqual(result,[dict(uid=501,home='current-home'),dict(uid=502,home='new-login')])

    def test_health_stability_resets_on_restart_failed_probe_or_clock_reversal(self):
        result = json.loads(subprocess.check_output([str(self.harness),'stable-health'],text=True))
        self.assertEqual(result,[False,False,False,True,False,False,False,False,False,False,True,False,False,False,True,False,False,False,True])

    def test_maintenance_without_transaction_does_not_require_valid_state(self):
        with tempfile.TemporaryDirectory() as temp:
            def run(mode):
                return subprocess.run([str(self.harness),'state-for-run',temp,mode],text=True,capture_output=True)
            self.assertEqual(run('maintenance').stdout.strip(),'no-recovery-needed')
            self.assertNotEqual(run('normal').returncode,0)
            (Path(temp) / 'transaction').mkdir()
            self.assertNotEqual(run('maintenance').returncode,0)

    def test_signer_reads_fragmented_stdin_and_rejects_oversized_input(self):
        import time
        manifest, signature = self.signed()
        key = self.key.read_bytes()
        process = subprocess.Popen([str(self.signer),'--sign',str(manifest),str(signature),self.public],
                                   stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        try:
            process.stdin.write(key[:12]); process.stdin.flush()
            time.sleep(0.05)
            process.stdin.write(key[12:]); process.stdin.close(); process.stdin = None
            output, error = process.communicate(timeout=5)
            self.assertEqual(process.returncode,0,error)
            self.assertEqual(self.verify(manifest,signature).returncode,0)
        finally:
            if process.poll() is None:
                process.kill(); process.communicate()
        result = subprocess.run([str(self.signer),'--sign',str(manifest),str(signature),self.public],
                                input=key + b' ' * 1100,capture_output=True)
        self.assertNotEqual(result.returncode,0)

    def test_old_receipts_do_not_pass_even_if_after_installation_start(self):
        # The harness uses now=110 and installation start=100 for ordinary cases;
        # add an explicit stale-since case using a harness mode with an old start.
        result = subprocess.check_output([str(self.harness),'stale-receipt'],text=True)
        self.assertEqual(result.strip(),'false')

    def test_privileged_ancestors_reject_writable_symlink_or_nonroot_parent(self):
        for mode in ['normal','owned-by-user','writable','symlink']:
            result = subprocess.run([str(self.harness),'ancestors',mode],capture_output=True)
            self.assertEqual(result.returncode,0 if mode == 'normal' else 1)

    def test_rollback_backups_are_checked_as_a_complete_pair(self):
        for mode in ['normal','agent','monitor','missing-hashes','partial-hashes']:
            result = subprocess.run([str(self.harness),'backups',mode],capture_output=True)
            self.assertEqual(result.returncode,0 if mode == 'normal' else 1)

    def test_root_required_without_any_installation(self):
        if os.geteuid() == 0:
            self.skipTest('Requires unprivileged caller')
        for flag in ['--once','--recover-only','--setup']:
            result = subprocess.run([str(self.updater),flag],capture_output=True,text=True)
            self.assertNotEqual(result.returncode,0)
            self.assertIn('root',result.stderr)
