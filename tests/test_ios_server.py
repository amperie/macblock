"""Exercise iOS HTTP dispatch and real SQLite state without binding a listening socket."""
import importlib.util
import io
import json
import os
from email.message import Message
import tempfile
import threading
import unittest
import uuid

spec = importlib.util.spec_from_file_location('ios_server', 'server/server.py')
s = importlib.util.module_from_spec(spec)
spec.loader.exec_module(s)


class IOSAPITests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        s.DB = os.path.join(self.tmp.name, 'orbit.sqlite3')
        s.ADMIN, s.DEVICE, s.ACTIVITY, s.BROWSER, s.IOS = [letter * 40 for letter in 'abcde']
        s.init_db()

    def tearDown(self):
        self.tmp.cleanup()

    def call(self, path, token, body=None, before_body=None, reply_error=None):
        handler = object.__new__(s.Handler)
        handler.path = path
        handler.headers = Message()
        handler.headers['Authorization'] = 'Bearer ' + token
        replies = []
        def reply(code, data, *args):
            replies.append((code, data))
            if reply_error:
                raise reply_error
        handler.reply = reply
        if body is not None:
            encoded = json.dumps(body).encode()
            handler.headers['Content-Length'] = str(len(encoded))
            handler.rfile = io.BytesIO(encoded)
            if before_body:
                read_body = handler.body
                def delayed_body():
                    before_body()
                    return read_body()
                handler.body = delayed_body
            handler.do_POST()
        else:
            handler.do_GET()
        self.assertEqual(len(replies), 1)
        return replies[0]

    def test_device_and_admin_credentials_are_separate(self):
        for credential in (s.ADMIN, s.DEVICE, s.ACTIVITY, s.BROWSER, 'wrong', ''):
            self.assertEqual(self.call('/api/ios/policy', credential)[0], 401)
        self.assertEqual(self.call('/api/ios/policy', s.IOS)[0], 200)
        for credential in (s.IOS, s.DEVICE, s.ACTIVITY, s.BROWSER, ''):
            self.assertEqual(self.call('/api/admin/ios/policy', credential)[0], 401)
        self.assertEqual(self.call('/api/admin/ios/policy', s.ADMIN)[0], 200)
        for unset in ('', 'short', s.ADMIN):
            s.IOS = unset
            self.assertEqual(self.call('/api/ios/policy', unset)[0], 503)

    def test_policy_revisions_and_mac_isolation(self):
        original_mac = s.policy()
        config = self.call('/api/admin/ios/policy', s.ADMIN)[1]
        changed = dict(config, blocked=True, dailyMinutes=30)
        self.assertEqual(self.call('/api/admin/ios/policy', s.IOS, changed)[0], 401)
        code, saved = self.call('/api/admin/ios/policy', s.ADMIN, changed)
        self.assertEqual(code, 200)
        self.assertEqual(saved['revision'], config['revision'] + 1)
        self.assertEqual(self.call('/api/ios/policy', s.IOS)[1], saved)
        self.assertEqual(self.call('/api/admin/ios/policy', s.ADMIN, changed)[0], 409)
        self.assertEqual(s.policy(), original_mac)
        self.assertEqual(self.call('/api/admin/ios/policy', s.ADMIN, dict(saved, dailyMinutes=None))[0], 200)
        s.init_db()
        self.assertIsNone(self.call('/api/ios/policy', s.IOS)[1]['dailyMinutes'])

    def test_malformed_policy_cannot_replace_valid_settings(self):
        config = self.call('/api/ios/policy', s.IOS)[1]
        for field, values in {'revision':[True, 0, -1, 2**53], 'schemaVersion':[True, 2],
                              'blocked':[1, None], 'dailyMinutes':[True, 0, -1, 1441, 1.5, '60'],
                              'timeZone':['Invalid/Zone', None]}.items():
            for value in values:
                self.assertEqual(self.call('/api/admin/ios/policy', s.ADMIN, dict(config, **{field:value}))[0], 400, (field, value))
        self.assertEqual(self.call('/api/admin/ios/policy', s.ADMIN, dict(config, applicationTokens=[]))[0], 400)
        self.assertEqual(self.call('/api/ios/policy', s.IOS)[1], config)

    def test_simultaneous_parent_writes_conflict_instead_of_losing_edits(self):
        policy = self.call('/api/ios/policy', s.IOS)[1]
        barrier = threading.Barrier(2)
        results = []
        failures = []
        def save(minutes):
            try:
                barrier.wait(timeout=5)
                results.append(self.call('/api/admin/ios/policy', s.ADMIN, dict(policy, dailyMinutes=minutes)))
            except Exception as error:
                failures.append(error)
        workers = [threading.Thread(target=save, args=(minutes,)) for minutes in (30, 60)]
        for worker in workers:
            worker.start()
        for worker in workers:
            worker.join(timeout=10)
        self.assertFalse(failures)
        self.assertFalse(any(worker.is_alive() for worker in workers))
        self.assertEqual(sorted(code for code, _ in results), [200, 409])
        winner = next(body for code, body in results if code == 200)
        self.assertEqual(self.call('/api/ios/policy', s.IOS)[1], winner)


    def test_status_is_minimal_and_not_a_mac_connection(self):
        report = dict(installationID=str(uuid.uuid4()), revision=0, authorized=False,
                      applicationCount=0, shieldConfigured=False)
        self.assertEqual(self.call('/api/ios/status', s.ADMIN, report)[0], 401)
        self.assertEqual(self.call('/api/ios/status', s.IOS, report)[0], 200)
        updated = dict(report, revision=2, authorized=True, applicationCount=1, shieldConfigured=True)
        self.assertEqual(self.call('/api/ios/status', s.IOS, updated)[0], 200)
        code, state = self.call('/api/admin/ios/state', s.ADMIN)
        self.assertEqual(code, 200)
        self.assertEqual(len(state['devices']), 1)
        self.assertEqual(state['devices'][0]['report'], updated)
        self.assertEqual(self.call('/api/admin/ios/state', s.IOS)[0], 401)
        self.assertEqual(s.connections_report()['devices'], [])
        for invalid in (dict(report, applicationCount=51), dict(report, applicationCount=True),
                        dict(report, revision=True), dict(report, authorized=1),
                        dict(report, installationID='bad'), dict(report, appNames=['Roblox'])):
            self.assertEqual(self.call('/api/ios/status', s.IOS, invalid)[0], 400)


    def enroll(self, identity=None):
        code, issued = self.call('/api/admin/ios/pair', s.ADMIN, {})
        self.assertEqual(code, 200)
        identity = identity or str(uuid.uuid4())
        code, result = self.call('/api/ios/enroll', '', dict(code=issued['code'], installationID=identity))
        self.assertEqual(code, 200)
        return result

    def test_code_enrollment_scope_hashes_and_revocation(self):
        s.IOS = ''  # Website setup needs no manually configured iPhone token.
        enrolled = self.enroll()
        token = enrolled['deviceToken']
        session = enrolled['parentSession']
        identity = enrolled['installationID']
        self.assertNotIn(s.ADMIN, json.dumps(enrolled))
        self.assertEqual(self.call('/api/ios/policy', token)[1], enrolled['policy'])
        self.assertEqual(self.call('/api/admin/state', token)[0], 401)
        self.assertEqual(self.call('/api/admin/ios/policy', session)[0], 401)
        self.assertEqual(self.call('/api/ios/parent/policy', token)[0], 401)
        self.assertEqual(self.call('/api/ios/parent/policy', session)[0], 200)
        self.assertEqual(self.call('/api/ios/parent/policy', session, dict(enrolled['policy'], blocked=True))[0], 200)
        report = dict(installationID=identity, revision=1, authorized=True, applicationCount=1, shieldConfigured=True)
        self.assertEqual(self.call('/api/ios/status', token, report)[0], 200)
        self.assertEqual(self.call('/api/ios/status', token, dict(report, installationID=str(uuid.uuid4())))[0], 403)
        import sqlite3
        with sqlite3.connect(s.DB) as conn:
            stored = str(conn.execute('SELECT * FROM ios_devices').fetchall()) + str(conn.execute('SELECT * FROM ios_parent_sessions').fetchall())
        self.assertNotIn(token, stored)
        self.assertNotIn(session, stored)
        self.assertEqual(len(self.call('/api/admin/ios/state', s.ADMIN)[1]['enrolled']), 1)
        self.assertEqual(self.call('/api/admin/ios/revoke', token, dict(installationID=identity))[0], 401)
        self.assertEqual(self.call('/api/admin/ios/revoke', s.ADMIN, dict(installationID=identity))[0], 200)
        self.assertEqual(self.call('/api/ios/policy', token)[0], 401)
        self.assertEqual(self.call('/api/ios/parent/policy', session)[0], 401)
        self.assertEqual(self.call('/api/admin/ios/state', s.ADMIN)[1]['enrolled'], [])

    def test_codes_are_single_use_expire_and_replace_previous_codes(self):
        from unittest.mock import patch
        with patch.object(s.time, 'time', return_value=1000):
            first = self.call('/api/admin/ios/pair', s.ADMIN, {})[1]['code']
            second = self.call('/api/admin/ios/pair', s.ADMIN, {})[1]['code']
            body = dict(code=first, installationID=str(uuid.uuid4()))
            self.assertEqual(self.call('/api/ios/enroll', '', body)[0], 401)
            body['code'] = second.lower().replace('-', ' ')
            self.assertEqual(self.call('/api/ios/enroll', '', body)[0], 200)
            self.assertEqual(self.call('/api/ios/enroll', '', body)[0], 401)
            expired = self.call('/api/admin/ios/pair', s.ADMIN, {})[1]['code']
        with patch.object(s.time, 'time', return_value=1600):
            self.assertEqual(self.call('/api/ios/enroll', '', dict(code=expired, installationID=str(uuid.uuid4())))[0], 401)

    def test_unlock_needs_device_and_fresh_code_and_sessions_expire(self):
        from unittest.mock import patch
        with patch.object(s.time, 'time', return_value=1000):
            enrolled = self.enroll()
            code = self.call('/api/admin/ios/pair', s.ADMIN, {})[1]['code']
            body = dict(code=code, installationID=enrolled['installationID'])
            self.assertEqual(self.call('/api/ios/unlock', 'wrong', body)[0], 401)
            self.assertEqual(self.call('/api/ios/unlock', enrolled['deviceToken'], dict(body, installationID=str(uuid.uuid4())))[0], 401)
            status, unlocked = self.call('/api/ios/unlock', enrolled['deviceToken'], body)
            self.assertEqual(status, 200)
            self.assertNotIn('deviceToken', unlocked)
            self.assertEqual(self.call('/api/ios/parent/policy', enrolled['parentSession'])[0], 401)
            self.assertEqual(self.call('/api/ios/parent/policy', unlocked['parentSession'])[0], 200)
        with patch.object(s.time, 'time', return_value=1900):
            self.assertEqual(self.call('/api/ios/parent/policy', unlocked['parentSession'])[0], 401)
            self.assertEqual(self.call('/api/ios/policy', enrolled['deviceToken'])[0], 200)

    def test_rate_limit_and_atomic_redemption(self):
        from unittest.mock import patch
        with patch.object(s.time, 'time', return_value=1000):
            for _ in range(30):
                self.assertEqual(self.call('/api/ios/enroll', '', dict(code='ZZZZ-ZZZZ-ZZZZ', installationID=str(uuid.uuid4())))[0], 401)
            self.assertEqual(self.call('/api/ios/enroll', '', dict(code='ZZZZ-ZZZZ-ZZZZ', installationID=str(uuid.uuid4())))[0], 429)
        with patch.object(s.time, 'time', return_value=1061):
            code = self.call('/api/admin/ios/pair', s.ADMIN, {})[1]['code']
            results = []
            barrier = threading.Barrier(2)
            def redeem():
                barrier.wait(timeout=5)
                results.append(self.call('/api/ios/enroll', '', dict(code=code, installationID=str(uuid.uuid4())))[0])
            workers = [threading.Thread(target=redeem) for _ in range(2)]
            for worker in workers: worker.start()
            for worker in workers: worker.join(timeout=10)
            self.assertEqual(sorted(results), [200, 401])

    def test_revocation_during_request_body_blocks_status_and_parent_writes(self):
        for endpoint in ('/api/ios/status', '/api/ios/parent/policy', '/api/ios/unlock'):
            enrolled = self.enroll()
            identity = enrolled['installationID']
            original = self.call('/api/admin/ios/policy', s.ADMIN)[1]
            token = enrolled['deviceToken']
            if endpoint.endswith('/status'):
                body = dict(installationID=identity, revision=1, authorized=True, applicationCount=1, shieldConfigured=True)
            elif endpoint.endswith('/unlock'):
                code = self.call('/api/admin/ios/pair', s.ADMIN, {})[1]['code']
                body = dict(code=code, installationID=identity)
            else:
                token = enrolled['parentSession']
                body = dict(original, blocked=not original['blocked'])
            def revoke():
                self.assertEqual(self.call('/api/admin/ios/revoke', s.ADMIN, dict(installationID=identity))[0], 200)
            self.assertEqual(self.call(endpoint, token, body, before_body=revoke)[0], 401)
            state = self.call('/api/admin/ios/state', s.ADMIN)[1]
            self.assertEqual(state['devices'], [])
            self.assertEqual(state['policy'], original)
            if endpoint.endswith('/unlock'):
                # Revocation during unlock must not consume the parent's still-valid code.
                self.assertEqual(self.call('/api/ios/enroll', '', dict(code=code, installationID=str(uuid.uuid4())))[0], 200)

    def test_parent_session_expiring_during_body_cannot_save(self):
        import sqlite3
        enrolled = self.enroll()
        def expire():
            with sqlite3.connect(s.DB) as conn:
                conn.execute('UPDATE ios_parent_sessions SET expires=0')
        body = dict(enrolled['policy'], blocked=True)
        self.assertEqual(self.call('/api/ios/parent/policy', enrolled['parentSession'], body, before_body=expire)[0], 401)
        self.assertEqual(self.call('/api/admin/ios/policy', s.ADMIN)[1], enrolled['policy'])

    def test_disconnecting_does_not_erase_failed_code_attempts(self):
        import sqlite3
        body = dict(code='ZZZZ-ZZZZ-ZZZZ', installationID=str(uuid.uuid4()))
        with self.assertRaises(BrokenPipeError):
            self.call('/api/ios/enroll', '', body, reply_error=BrokenPipeError())
        with sqlite3.connect(s.DB) as conn:
            self.assertEqual(conn.execute('SELECT failures FROM ios_pairing_attempts WHERE id=1').fetchone()[0], 1)


if __name__ == '__main__':
    unittest.main()
