import importlib.util
import datetime
import uuid
import sqlite3
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
        s.ADMIN, s.DEVICE, s.ACTIVITY, s.BROWSER = 'a' * 40, 'b' * 40, 'c' * 40, 'd' * 40
        s.init_db()
        self.http = ThreadingHTTPServer(('127.0.0.1', 0), s.Handler)
        self.thread = threading.Thread(target=self.http.serve_forever, daemon=True)
        self.thread.start()
        self.url = 'http://127.0.0.1:' + str(self.http.server_port)

    def tearDown(self):
        self.http.shutdown(); self.http.server_close(); self.thread.join(); self.tmp.cleanup()

    def call(self, path, token, data=None):
        req = urllib.request.Request(self.url + path, data=json.dumps(data).encode() if data is not None else None, headers={'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json'})
        try:
            with urllib.request.urlopen(req) as response: return response.status, json.load(response)
        except urllib.error.HTTPError as error: return error.code, json.load(error)

    def test_auth_separation(self):
        self.assertEqual(self.call('/api/admin/state', s.DEVICE)[0], 401)
        self.assertEqual(self.call('/api/device/policy', s.ADMIN)[0], 401)
        self.assertEqual(self.call('/api/browser/domains', s.DEVICE)[0], 401)
        self.assertEqual(self.call('/api/browser/domains', s.BROWSER)[1]['blockedDomains'], [])
        self.assertEqual(self.call('/api/admin/state', s.BROWSER)[0], 401)
        self.assertEqual(self.call('/api/admin/policy', s.BROWSER, dict(apps=[], revision=1))[0], 401)
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



    def test_server_time_is_utc_and_independent_of_local_timezone(self):
        before = datetime.datetime.now(datetime.timezone.utc)
        code, response = self.call('/api/device/policy', s.DEVICE)
        after = datetime.datetime.now(datetime.timezone.utc)
        self.assertEqual(code, 200)
        self.assertEqual(response['enforcementTimeZone'], 'America/Los_Angeles')
        server_time = datetime.datetime.fromisoformat(response['serverTimeUTC'])
        self.assertEqual(server_time.utcoffset(), datetime.timedelta(0))
        self.assertLessEqual(before, server_time)
        self.assertLessEqual(server_time, after)
        self.assertNotIn('serverTimeUTC', s.policy())
        self.assertEqual(s.policy()['enforcementTimeZone'], 'America/Los_Angeles')

    def test_timezone_schedule_update_and_persistence(self):
        _, policy = self.call('/api/device/policy', s.DEVICE)
        policy['enforcementTimeZone'] = 'America/New_York'
        policy['schedule'] = dict(enabled=True, start='21:00', end='07:00')
        code, saved = self.call('/api/admin/policy', s.ADMIN, policy)
        self.assertEqual(code, 200)
        self.assertEqual(saved['enforcementTimeZone'], 'America/New_York')
        self.assertTrue(saved['schedule']['enabled'])
        self.assertEqual(self.call('/api/device/policy', s.DEVICE)[1]['enforcementTimeZone'], 'America/New_York')
        s.init_db()
        self.assertEqual(s.policy()['enforcementTimeZone'], 'America/New_York')
        for zone in ['Invalid/Zone', '', None]:
            invalid = dict(saved, enforcementTimeZone=zone)
            self.assertEqual(self.call('/api/admin/policy', s.ADMIN, invalid)[0], 400)
        invalid = dict(saved, schedule=dict(enabled=True, start='25:00', end='07:00'))
        self.assertEqual(self.call('/api/admin/policy', s.ADMIN, invalid)[0], 400)
        self.assertEqual(s.policy()['revision'], 2)

    def test_quota_midnight_split(self):
        with sqlite3.connect(s.DB) as conn:
            old = datetime.datetime(2026, 11, 15, 7, 59, 30, tzinfo=datetime.timezone.utc)
            now = old + datetime.timedelta(seconds=60)
            conn.execute('INSERT OR REPLACE INTO activity_current VALUES (1, ?, ?)',
                         (json.dumps(dict(bundleId='com.roblox.RobloxPlayer', appName='Roblox', since=old.isoformat())),
                          old.isoformat()))
            s.record_heartbeat(conn, dict(bundleId='com.roblox.RobloxPlayer'), s.policy(), now)
            rows = conn.execute('SELECT day, seconds FROM quota_usage ORDER BY day').fetchall()
        self.assertEqual(rows, [('2026-11-14', 30.0), ('2026-11-15', 30.0)])

    def test_quota_heartbeat_and_daily_limit(self):
        _, policy = self.call('/api/device/policy', s.DEVICE)
        policy['quota'] = dict(enabled=True, bundleId='com.roblox.RobloxPlayer', minutes=1)
        self.assertEqual(self.call('/api/admin/policy', s.ADMIN, policy)[0], 200)
        current = dict(bundleId='com.roblox.RobloxPlayer', appName='Roblox',
                       since=datetime.datetime.now(datetime.timezone.utc).isoformat())
        payload = dict(events=[], current=current)
        self.assertEqual(self.call('/api/device/activity', s.ACTIVITY, payload)[0], 200)
        with sqlite3.connect(s.DB) as conn:
            old_seen = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(seconds=70)).isoformat()
            conn.execute("UPDATE activity_current SET seen=? WHERE id=1", (old_seen,))
        self.assertEqual(self.call('/api/device/activity', s.ACTIVITY, payload)[0], 200)
        state = self.call('/api/device/policy', s.DEVICE)[1]['quotaState']
        self.assertTrue(state['exceeded'])
        self.assertGreaterEqual(state['usedSeconds'], 60)
        self.assertTrue(state['monitoringFresh'])
        self.assertEqual(self.call('/api/admin/state', s.ADMIN)[1]['quotaState']['day'], state['day'])
        tomorrow = datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(days=2)
        reset = s.quota_state(s.policy(), now=tomorrow)
        self.assertFalse(reset['exceeded'])
        self.assertEqual(reset['usedSeconds'], 0)
        bad_policy = dict(policy, revision=2,
                          quota=dict(enabled=True, bundleId='com.example.missing', minutes=60))
        self.assertEqual(self.call('/api/admin/policy', s.ADMIN, bad_policy)[0], 400)

    def test_blocked_domain_policy(self):
        _, p = self.call('/api/device/policy', s.DEVICE)
        p['blockedDomains'] = ['instagram.com', 'tiktok.com']
        code, saved = self.call('/api/admin/policy', s.ADMIN, p)
        self.assertEqual(code, 200)
        self.assertEqual(saved['blockedDomains'], ['instagram.com', 'tiktok.com'])
        for domains in [['example'], ['a.com', 'a.com'], ['https://example.com'], ['*.example.com']]:
            invalid = dict(saved, blockedDomains=domains)
            self.assertEqual(self.call('/api/admin/policy', s.ADMIN, invalid)[0], 400)

    def test_per_app_rules_and_temporary_override(self):
        _, p = self.call('/api/device/policy', s.DEVICE)
        p['appRules'] = {'com.roblox.RobloxPlayer': {
            'schedule': dict(enabled=True, start='20:00', end='08:00'), 'minutes': 45}}
        until = (datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(minutes=30)).isoformat()
        p['overrides'] = {'com.roblox.RobloxPlayer': until}
        code, result = self.call('/api/admin/policy', s.ADMIN, p)
        self.assertEqual(code, 200)
        device = self.call('/api/device/policy', s.DEVICE)[1]
        self.assertEqual(device['appQuotaStates']['com.roblox.RobloxPlayer']['limitSeconds'], 2700)
        self.assertTrue(device['appSchedules']['com.roblox.RobloxPlayer']['enabled'])
        self.assertEqual(device['overrides']['com.roblox.RobloxPlayer'], until)
        expired = dict(result, overrides={'com.roblox.RobloxPlayer': (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=3)).isoformat()})
        self.assertEqual(self.call('/api/admin/policy', s.ADMIN, expired)[1]['overrides'], {})
        self.assertEqual(self.call('/api/admin/alerts', s.DEVICE)[0], 401)
        self.assertTrue(self.call('/api/admin/alerts', s.ADMIN)[1]['alerts'])
        bad = dict(result, revision=3, appRules={'com.example.unknown': {
            'schedule': dict(enabled=True, start='20:00', end='08:00'), 'minutes': 60}})
        self.assertEqual(self.call('/api/admin/policy', s.ADMIN, bad)[0], 400)

    def test_activity_auth_validation_and_deduplication(self):
        now = datetime.datetime.now(datetime.timezone.utc)
        start = (now - datetime.timedelta(minutes=5)).isoformat()
        end = (now - datetime.timedelta(minutes=4)).isoformat()
        event = dict(eventId=str(uuid.uuid4()), bundleId='com.roblox.RobloxPlayer',
                     appName='Roblox', startedAt=start, endedAt=end)
        payload = dict(events=[event], current=None)
        self.assertEqual(self.call('/api/device/activity', s.DEVICE, payload)[0], 401)
        self.assertEqual(self.call('/api/admin/activity', s.DEVICE)[0], 401)
        self.assertEqual(self.call('/api/device/activity', s.ACTIVITY, payload)[0], 200)
        self.assertEqual(self.call('/api/device/activity', s.ACTIVITY, payload)[0], 200)
        code, result = self.call('/api/admin/activity', s.ADMIN)
        self.assertEqual(code, 200)
        self.assertEqual(len(result['events']), 1)
        invalid = dict(payload, events=[dict(event, endedAt=start)])
        self.assertEqual(self.call('/api/device/activity', s.ACTIVITY, invalid)[0], 400)
        self.assertEqual(len(self.call('/api/admin/activity', s.ADMIN)[1]['events']), 1)
        current = dict(bundleId='com.apple.Safari', appName='Safari', since=start)
        self.assertEqual(self.call('/api/device/activity', s.ACTIVITY, dict(events=[], current=current))[0], 200)
        self.assertEqual(self.call('/api/admin/activity', s.ADMIN)[1]['current']['appName'], 'Safari')
        self.assertEqual(self.call('/api/device/activity', s.ACTIVITY, dict(events=[], current=None))[0], 200)
        self.assertIsNone(self.call('/api/admin/activity', s.ADMIN)[1]['current'])
        for bad_id in [None, 123, 'not-a-uuid']:
            bad = dict(event, eventId=bad_id)
            self.assertEqual(self.call('/api/device/activity', s.ACTIVITY,
                                       dict(events=[bad], current=None))[0], 400)
        future = (now + datetime.timedelta(days=1)).isoformat()
        self.assertEqual(self.call('/api/device/activity', s.ACTIVITY,
                                   dict(events=[], current=dict(current, since=future)))[0], 400)
        self.assertEqual(len(self.call('/api/admin/activity', s.ADMIN)[1]['events']), 1)

if __name__ == '__main__': unittest.main()
