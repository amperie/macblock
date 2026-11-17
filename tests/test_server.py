import importlib.util
import json
import os
import tempfile
import threading
import unittest
import urllib.request
import urllib.error
from http.server import ThreadingHTTPServer

spec = importlib.util.spec_from_file_location('server', 'server/server.py')
s = importlib.util.module_from_spec(spec)
spec.loader.exec_module(s)

class ControlTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        s.DB = os.path.join(self.tmp.name, 'state.sqlite3')
        s.ADMIN, s.DEVICE = 'a' * 40, 'b' * 40
        s.init_db()
        self.http = ThreadingHTTPServer(('127.0.0.1', 0), s.Handler)
        self.thread = threading.Thread(target=self.http.serve_forever, daemon=True)
        self.thread.start()
        self.url = 'http://127.0.0.1:' + str(self.http.server_port)

    def tearDown(self):
        self.http.shutdown(); self.http.server_close(); self.thread.join(); self.tmp.cleanup()

    def call(self, path, token, data=None):
        req = urllib.request.Request(self.url + path, data=json.dumps(data, ensure_ascii=False).encode() if data is not None else None, headers={'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json'})
        try:
            with urllib.request.urlopen(req) as response: return response.status, json.load(response)
        except urllib.error.HTTPError as error: return error.code, json.load(error)

    def test_auth_separation(self):
        self.assertEqual(self.call('/api/admin/state', s.DEVICE)[0], 401)
        self.assertEqual(self.call('/api/device/policy', s.ADMIN)[0], 401)
        self.assertEqual(self.call('/api/device/status', '', {})[0], 401)

    def test_policy_persistence_conflict_and_status(self):
        _, policy = self.call('/api/device/policy', s.DEVICE)
        self.assertFalse(any(a['blocked'] for a in policy['apps']))
        policy['apps'][0]['blocked'] = True
        code, updated = self.call('/api/admin/policy', s.ADMIN, policy)
        self.assertEqual(code, 200); self.assertEqual(updated['revision'], 2)
        self.assertEqual(self.call('/api/admin/policy', s.ADMIN, policy)[0], 409)
        s.init_db() # Reinitialization must preserve saved settings.
        self.assertTrue(s.policy()['apps'][0]['blocked'])
        self.assertEqual(self.call('/api/device/status', s.DEVICE, dict(revision=2, agentVersion='test', lastError=''))[0], 200)
        self.assertEqual(self.call('/api/admin/state', s.ADMIN)[1]['device']['report']['revision'], 2)

    def test_invalid_rules_preserve_previous_policy(self):
        for bid in ['com.apple.finder', 'com.macblock.agent', 'invalid', 'com.example.app']:
            rule = dict(name='App', bundleId=bid, blocked=True)
            apps = [rule, rule] if bid == 'com.example.app' else [rule]
            self.assertEqual(self.call('/api/admin/policy', s.ADMIN, dict(revision=1, apps=apps))[0], 400)
        self.assertEqual(s.policy()['revision'], 1)

    def test_invalid_revision_types(self):
        for revision in [True, 1.0, '1', None, 2**53]:
            code, _ = self.call('/api/admin/policy', s.ADMIN, dict(revision=revision, apps=[]))
            self.assertEqual(code, 400)
        self.assertEqual(s.policy()['revision'], 1)

    def test_domains_are_normalized_preserved_by_legacy_edit_and_explicitly_cleared(self):
        payload = dict(revision=1, apps=[], blockedDomains=[' TikTok.COM. ', 'instagram.com', 'tiktok.com'])
        code, updated = self.call('/api/admin/policy', s.ADMIN, payload)
        self.assertEqual(code, 200)
        self.assertEqual(updated['blockedDomains'], ['instagram.com', 'tiktok.com'])
        code, updated = self.call('/api/admin/policy', s.ADMIN, dict(revision=2, apps=[]))
        self.assertEqual(code, 200)
        self.assertEqual(updated['blockedDomains'], ['instagram.com', 'tiktok.com'])
        code, updated = self.call('/api/admin/policy', s.ADMIN, dict(revision=3, apps=[], blockedDomains=[]))
        self.assertEqual(code, 200)
        self.assertEqual(updated['blockedDomains'], [])

    def test_invalid_domains_preserve_the_revision(self):
        for domains in [None, 'example.com', ['https://example.com'], ['*.example.com'], ['127.0.0.1'],
                        ['0x7f.0x1'], ['example..com'], ['x.Kom'], ['example.com:80'], ['example.com'] * 101]:
            with self.subTest(domains=domains):
                self.assertEqual(self.call('/api/admin/policy', s.ADMIN, dict(revision=1, apps=[], blockedDomains=domains))[0], 400)
        self.assertEqual(s.policy()['revision'], 1)

    def test_expanded_policy_cannot_exceed_agent_limit(self):
        # Small UTF-8 request expands past 64KB when the server JSON-escapes it.
        apps = [dict(name='😀' * 80, bundleId=f'com.example.app{i}', blocked=True) for i in range(100)]
        code, _ = self.call('/api/admin/policy', s.ADMIN, dict(revision=1, apps=apps))
        self.assertEqual(code, 400)
        self.assertEqual(s.policy()['revision'], 1)

    def test_unicode_and_name_validation(self):
        for name in ['   ', 'x' * 81, 'x' * 80 + ' ', '\ud800']:
            rule = dict(name=name, bundleId='com.example.app', blocked=True)
            # Escape invalid Unicode instead of attempting to encode a surrogate.
            request = urllib.request.Request(self.url + '/api/admin/policy',
                data=json.dumps(dict(revision=1, apps=[rule])).encode(),
                headers={'Authorization': 'Bearer ' + s.ADMIN})
            with self.assertRaises(urllib.error.HTTPError) as error:
                urllib.request.urlopen(request)
            self.assertEqual(error.exception.code, 400)
        self.assertEqual(s.policy()['revision'], 1)

if __name__ == '__main__': unittest.main()
