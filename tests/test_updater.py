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
        var state = UpdateState(sequence: CommandLine.arguments[2] == "committed" ? 2 : 1, failedSequence: 0, version:"old")
        var events: [String] = []
        let failure = CommandLine.arguments[2]
        do {
            try recoverTransaction(Journal(sequence:2, version:"new", monitors:[]), state:&state,
                restore: { name in events.append("restore-" + name); if failure == name { throw UpdateError.invalid("injected") } },
                restartServices: { _ in events.append("restart"); if failure == "restart" { throw UpdateError.invalid("injected") } },
                persist: { _ in events.append("save"); if failure == "save" { throw UpdateError.invalid("injected") } },
                removeJournal: { events.append("cleanup") })
        } catch { events.append("failed") }
        let result: [String:Any] = ["events":events, "sequence":state.sequence, "failedSequence":state.failedSequence]
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:result))
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
        for failure in ['none','agent','monitor','restart','save','committed']:
            result = json.loads(subprocess.check_output([str(self.harness),'recover',failure],text=True))
            if failure == 'none':
                self.assertEqual(result['events'],expected)
                self.assertEqual(result['sequence'],1)
                self.assertEqual(result['failedSequence'],2)
            elif failure == 'committed':
                self.assertEqual(result['events'],['cleanup'])
                self.assertEqual(result['sequence'],2)
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

    def test_root_required_without_any_installation(self):
        if os.geteuid() == 0:
            self.skipTest('Requires unprivileged caller')
        for flag in ['--once','--recover-only','--setup']:
            result = subprocess.run([str(self.updater),flag],capture_output=True,text=True)
            self.assertNotEqual(result.returncode,0)
            self.assertIn('root',result.stderr)
