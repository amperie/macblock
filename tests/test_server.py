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
        req = urllib.request.Request(self.url + path, data=json.dumps(data, ensure_ascii=False).encode() if data is not None else None, headers={'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json'})
        try:
            with urllib.request.urlopen(req) as response: return response.status, json.load(response)
        except urllib.error.HTTPError as error: return error.code, json.load(error)

    def test_menu_bar_preset_and_existing_policy_migration(self):
        helper_id = 'com.roblox.RobloxPlayer.MenuBar'
        config = s.policy()
        self.assertIn(helper_id, {app['bundleId'] for app in config['apps']})
        config['apps'] = [app for app in config['apps'] if app['bundleId'] != helper_id]
        config['apps'][0]['blocked'] = True
        config['revision'] = 7
        with sqlite3.connect(s.DB) as conn:
            conn.execute('DELETE FROM schema_migrations')
            conn.execute('UPDATE state SET payload=? WHERE id=1', (json.dumps(config),))
        s.init_db()
        migrated = s.policy()
        self.assertEqual(migrated['revision'], 8)
        self.assertTrue(next(app for app in migrated['apps'] if app['bundleId'] == helper_id)['blocked'])
        s.init_db()
        self.assertEqual(s.policy(), migrated)
        # A deliberate removal after migration must survive later restarts.
        migrated['apps'] = config['apps']
        with sqlite3.connect(s.DB) as conn:
            conn.execute('UPDATE state SET payload=? WHERE id=1', (json.dumps(migrated),))
        s.init_db()
        self.assertNotIn(helper_id, {app['bundleId'] for app in s.policy()['apps']})

    def test_expired_queued_events_do_not_block_current_monitoring(self):
        now = datetime.datetime.now(datetime.timezone.utc)
        def event(start):
            return dict(eventId=str(uuid.uuid4()), bundleId='com.apple.Safari', appName='Safari',
                        startedAt=start.isoformat(), endedAt=(start + datetime.timedelta(seconds=10)).isoformat())
        old = event(now - datetime.timedelta(days=s.RETENTION_DAYS + 2))
        recent = event(now - datetime.timedelta(minutes=1))
        current = dict(bundleId='com.apple.Safari', appName='Safari', since=recent['startedAt'])
        status, _ = self.call('/api/device/activity', s.ACTIVITY, dict(events=[old, recent], current=current))
        self.assertEqual(status, 200)
        status, report = self.call('/api/admin/activity', s.ADMIN)
        self.assertEqual(status, 200)
        self.assertEqual(len(report['events']), 1)
        self.assertEqual(report['events'][0]['startedAt'], recent['startedAt'])
        self.assertEqual(report['current'], current)

    def test_connections_are_separate_by_hostname_and_keep_last_seen(self):
        report = dict(revision=1, agentVersion='test', lastError='')
        self.assertEqual(self.call('/api/device/status', s.DEVICE, dict(report, hostname='Daughter-Mac.local'))[0], 200)
        old = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(minutes=10)).isoformat()
        with sqlite3.connect(s.DB) as conn:
            conn.execute('UPDATE device_status SET seen=? WHERE hostname=?', (old, 'daughter-mac.local'))
        self.assertEqual(self.call('/api/device/status', s.DEVICE, dict(report, hostname='Parent-Mac.local'))[0], 200)
        self.assertEqual(self.call('/api/device/status', s.DEVICE, dict(report, hostname='PARENT-MAC.local.'))[0], 200)
        code, body = self.call('/api/admin/connections', s.ADMIN)
        self.assertEqual(code, 200)
        hosts = {device['hostname']: device for device in body['devices']}
        self.assertEqual(set(hosts), {'daughter-mac.local', 'parent-mac.local'})
        self.assertEqual(hosts['daughter-mac.local']['lastSeen'], old)
        self.assertFalse(hosts['daughter-mac.local']['connected'])
        self.assertTrue(hosts['parent-mac.local']['connected'])
        state = self.call('/api/admin/state', s.ADMIN)[1]
        self.assertEqual(state['devices'], body['devices'])
        self.assertEqual(state['device']['report']['hostname'], 'PARENT-MAC.local.')
        for credential in [s.DEVICE, s.BROWSER, s.ACTIVITY, 'wrong']:
            self.assertEqual(self.call('/api/admin/connections', credential)[0], 401)

    def test_legacy_connections_and_database_upgrade(self):
        report = dict(revision=1, agentVersion='old', lastError='')
        self.assertEqual(self.call('/api/device/status', s.DEVICE, report)[0], 200)
        with sqlite3.connect(s.DB) as conn:
            conn.execute('DROP TABLE device_status')
        s.init_db()
        devices = self.call('/api/admin/connections', s.ADMIN)[1]['devices']
        self.assertEqual(len(devices), 1)
        self.assertIsNone(devices[0]['hostname'])
        self.assertEqual(devices[0]['report'], report)
        s.init_db()
        self.assertEqual(len(self.call('/api/admin/connections', s.ADMIN)[1]['devices']), 1)

    def test_status_rejects_invalid_hostnames_without_losing_connections(self):
        report = dict(revision=1, agentVersion='test', lastError='')
        for hostname in ['', None, 3, [], 'x' * 254, 'mac\n', ' mac ', '.']:
            with self.subTest(hostname=repr(hostname)):
                self.assertEqual(self.call('/api/device/status', s.DEVICE, dict(report, hostname=hostname))[0], 400)
        self.assertEqual(self.call('/api/admin/connections', s.ADMIN)[1]['devices'], [])

    def test_usage_history_and_retention(self):
        now = datetime.datetime.now(datetime.timezone.utc)
        today = now.astimezone(s.ZoneInfo('America/Los_Angeles')).date()
        with sqlite3.connect(s.DB) as conn:
            conn.execute('INSERT INTO quota_usage VALUES (?,?,?)',
                         (today.isoformat(), 'com.roblox.RobloxPlayer', 120))
            conn.execute('INSERT INTO quota_usage VALUES (?,?,?)',
                         ((today - datetime.timedelta(days=7)).isoformat(), 'com.roblox.RobloxPlayer', 180))
            conn.execute('INSERT INTO website_usage VALUES (?,?,?)',
                         (today.isoformat(), 'example.com', 60))
            conn.execute('INSERT INTO website_usage VALUES (?,?,?)',
                         ((today - datetime.timedelta(days=110)).isoformat(), 'old.example', 900))
            s.prune_history(conn, now)
        self.assertEqual(self.call('/api/admin/usage', s.DEVICE)[0], 401)
        code, report = self.call('/api/admin/usage', s.ADMIN)
        self.assertEqual(code, 200)
        self.assertEqual(report['retentionDays'], 90)
        self.assertEqual(len(report['apps']), 1)
        self.assertEqual(len(report['apps'][0]['weeks']), 2)
        self.assertEqual(sum(report['apps'][0]['days'].values()), 300)
        self.assertEqual([w['id'] for w in report['websites']], ['example.com'])

    def test_browser_usage_heartbeat_and_validation(self):
        client = str(uuid.uuid4())
        self.assertEqual(self.call('/api/browser/activity', s.DEVICE, {'domain':'example.com','clientId':client})[0], 401)
        self.assertEqual(self.call('/api/browser/activity', s.BROWSER, {'domain':'https://example.com','clientId':client})[0], 400)
        self.assertEqual(self.call('/api/browser/activity', s.BROWSER, {'domain':'example.com','clientId':client})[0], 200)
        with sqlite3.connect(s.DB) as conn:
            old = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(seconds=60)).isoformat()
            conn.execute('UPDATE browser_sessions SET seen=?', (old,))
        self.assertEqual(self.call('/api/browser/activity', s.BROWSER, {'domain':None,'clientId':client})[0], 200)
        report = self.call('/api/admin/usage', s.ADMIN)[1]
        self.assertGreaterEqual(report['websites'][0]['days'][report['endDate']], 59)
        self.assertEqual(self.call('/api/browser/activity', s.BROWSER, {'domain':None,'clientId':client,'extra':1})[0], 400)

    def test_browser_midnight_split(self):
        client = str(uuid.uuid4())
        old = datetime.datetime(2026, 11, 15, 7, 59, 30, tzinfo=datetime.timezone.utc)
        with sqlite3.connect(s.DB) as conn:
            conn.execute('INSERT INTO browser_sessions VALUES (?,?,?)',
                         (client, 'example.com', old.isoformat()))
            s.record_browser_heartbeat(conn, (client, None), s.policy(),
                                       old + datetime.timedelta(seconds=60))
            rows = conn.execute('SELECT day,seconds FROM website_usage ORDER BY day').fetchall()
        self.assertEqual(rows, [('2026-11-14', 30.0), ('2026-11-15', 30.0)])

    def test_browser_sessions_are_isolated(self):
        first, second = str(uuid.uuid4()), str(uuid.uuid4())
        for client, domain in [(first, 'one.example'), (second, 'two.example')]:
            self.assertEqual(self.call('/api/browser/activity', s.BROWSER,
                                       {'domain':domain,'clientId':client})[0], 200)
        with sqlite3.connect(s.DB) as conn:
            old = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(seconds=30)).isoformat()
            conn.execute('UPDATE browser_sessions SET seen=?', (old,))
        self.assertEqual(self.call('/api/browser/activity', s.BROWSER,
                                   {'domain':None,'clientId':first})[0], 200)
        report = self.call('/api/admin/usage', s.ADMIN)[1]
        self.assertEqual([row['id'] for row in report['websites']], ['one.example'])
        self.assertEqual(self.call('/api/browser/activity', s.BROWSER,
                                   {'domain':None,'clientId':second})[0], 200)
        report = self.call('/api/admin/usage', s.ADMIN)[1]
        self.assertEqual([row['id'] for row in report['websites']], ['one.example', 'two.example'])

    def test_reset_counters_requires_admin_and_current_revision(self):
        payload = dict(revision=s.policy()['revision'])
        for token in [s.DEVICE, s.ACTIVITY, s.BROWSER, '']:
            self.assertEqual(self.call('/api/admin/usage/reset',token,payload)[0],401)
        self.assertEqual(self.call('/api/admin/usage/reset',s.ADMIN,dict(revision=True))[0],400)
        self.assertEqual(self.call('/api/admin/usage/reset',s.ADMIN,dict(revision=999))[0],409)
        code,result = self.call('/api/admin/usage/reset',s.ADMIN,payload)
        self.assertEqual(code,200)
        self.assertEqual(result['revision'],payload['revision']+1)
        self.assertEqual(s.policy()['revision'],result['revision'])
        self.assertEqual(self.call('/api/admin/usage/reset',s.ADMIN,payload)[0],409)

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

    def test_safari_block_policy_is_saved_and_delivered(self):
        app = dict(name='Safari', bundleId='com.apple.Safari', blocked=True)
        code, updated = self.call('/api/admin/policy', s.ADMIN, dict(revision=1, apps=[app]))
        self.assertEqual(code, 200)
        self.assertEqual(updated['apps'], [app])
        self.assertEqual(self.call('/api/device/policy', s.DEVICE)[1]['apps'], [app])

    def test_invalid_rules_preserve_previous_policy(self):
        for bid in ['com.apple.Safari.helper', 'COM.APPLE.Finder', 'com.apple.finder', 'com.side-forge.orbit.agent', 'invalid', 'com.example.app']:
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

    def test_derived_quota_policy_cannot_exceed_agent_limit(self):
        apps = [dict(name='App', bundleId='com.example.' + 'x' * 180 + str(i), blocked=False) for i in range(60)]
        rules = {app['bundleId']: dict(schedule=dict(enabled=False, start='21:00', end='07:00'), minutes=60) for app in apps}
        payload = dict(revision=1, apps=apps, appRules=rules)
        self.assertLess(len(json.dumps(payload).encode()), s.MAX_BODY)
        self.assertEqual(self.call('/api/admin/policy', s.ADMIN, payload)[0], 400)
        self.assertEqual(s.policy()['revision'], 1)

    def test_unicode_and_name_validation(self):
        for name in ['   ', 'x' * 81, 'x' * 80 + ' ']:
            rule = dict(name=name, bundleId='com.example.app', blocked=True)
            # Escape invalid Unicode instead of attempting to encode a surrogate.
            request = urllib.request.Request(self.url + '/api/admin/policy',
                data=json.dumps(dict(revision=1, apps=[rule])).encode(),
                headers={'Authorization': 'Bearer ' + s.ADMIN})
            with self.assertRaises(urllib.error.HTTPError) as error:
                urllib.request.urlopen(request)
            self.assertEqual(error.exception.code, 400)
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

    def test_switching_apps_accounts_previous_foreground(self):
        with sqlite3.connect(s.DB) as conn:
            now = datetime.datetime.now(datetime.timezone.utc)
            old = now - datetime.timedelta(seconds=30)
            conn.execute('INSERT OR REPLACE INTO activity_current VALUES (1, ?, ?)',
                         (json.dumps(dict(bundleId='com.roblox.RobloxPlayer',
                                          appName='Roblox', since=old.isoformat())), old.isoformat()))
            s.record_heartbeat(conn, dict(bundleId='com.apple.Safari'), s.policy(), now)
            day = now.astimezone(s.ZoneInfo('America/Los_Angeles')).date().isoformat()
            used = conn.execute('SELECT seconds FROM quota_usage WHERE day=? AND bundle_id=?',
                                (day, 'com.roblox.RobloxPlayer')).fetchone()
        self.assertIsNotNone(used)
        self.assertAlmostEqual(used[0], 30, delta=1)

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

    def test_security_health_reports_unverified_browser(self):
        self.assertEqual(self.call('/api/admin/health', s.DEVICE)[0], 401)
        code, health = self.call('/api/admin/health', s.ADMIN)
        self.assertEqual(code, 200)
        self.assertFalse(health['browserProtectionVerified'])
        self.assertFalse(health['monitorConnected'])
        self.assertFalse(health['deviceConnected'])

    def test_blocked_domain_policy(self):
        _, p = self.call('/api/device/policy', s.DEVICE)
        p['blockedDomains'] = ['instagram.com', 'tiktok.com']
        code, saved = self.call('/api/admin/policy', s.ADMIN, p)
        self.assertEqual(code, 200)
        self.assertEqual(saved['blockedDomains'], ['instagram.com', 'tiktok.com'])
        for domains in [['example'], ['https://example.com'], ['*.example.com']]:
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


class UsageCounterTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.previous_db = s.DB
        s.DB = os.path.join(self.tmp.name, 'counters.sqlite3')
        s.init_db()
        self.now = datetime.datetime.now(datetime.timezone.utc)
        self.day = self.now.date().isoformat()
        self.bid = 'com.example.limited'
        self.config = dict(s.policy(), enforcementTimeZone='UTC',
            apps=[dict(name='Limited', bundleId=self.bid, blocked=False)],
            quota=dict(enabled=True, bundleId=self.bid, minutes=20),
            appRules={self.bid:dict(schedule=dict(enabled=False,start='21:00',end='07:00'),minutes=20)})
        with sqlite3.connect(s.DB) as conn:
            conn.execute('INSERT INTO quota_usage VALUES (?,?,?)', (self.day,self.bid,1800))
            conn.execute('INSERT INTO website_usage VALUES (?,?,?)', (self.day,'example.com',600))
            current = dict(bundleId=self.bid, appName='Limited', since=(self.now-datetime.timedelta(hours=1)).isoformat())
            seen = (self.now-datetime.timedelta(seconds=30)).isoformat()
            conn.execute('INSERT INTO activity_current VALUES (1,?,?)', (json.dumps(current),seen))
            conn.execute('INSERT INTO browser_sessions VALUES (?,?,?)', ('live','example.com',seen))
            conn.execute('INSERT INTO browser_sessions VALUES (?,?,?)', ('stale','example.com',(self.now-datetime.timedelta(hours=1)).isoformat()))

    def tearDown(self):
        s.DB = self.previous_db
        self.tmp.cleanup()

    def test_changed_limits_recalculate_without_resetting_usage(self):
        for minutes, exceeded in [(20,True),(45,False),(15,True),(30,True)]:
            with self.subTest(minutes=minutes):
                self.config['quota']['minutes'] = minutes
                self.config['appRules'][self.bid]['minutes'] = minutes
                for state in [s.quota_state(self.config,self.now),s.app_quota_states(self.config,self.now)[self.bid]]:
                    self.assertEqual(state['usedSeconds'],1800)
                    self.assertEqual(state['limitSeconds'],minutes*60)
                    self.assertEqual(state['exceeded'],exceeded)
                    self.assertTrue(state['monitoringFresh'])

    def test_reset_zeros_totals_and_counts_only_time_after_reset(self):
        with sqlite3.connect(s.DB) as conn:
            conn.execute('INSERT INTO quota_usage VALUES (?,?,?)', ('2020-01-01',self.bid,100))
            s.reset_usage_counters(conn,self.now)
        self.assertEqual(s.usage_report(self.config,self.now)['apps'],[])
        self.assertEqual(s.usage_report(self.config,self.now)['websites'],[])
        self.assertEqual(s.app_quota_states(self.config,self.now)[self.bid]['usedSeconds'],0)
        self.assertFalse(s.quota_state(self.config,self.now)['exceeded'])
        after = self.now+datetime.timedelta(seconds=10)
        with sqlite3.connect(s.DB) as conn:
            s.record_heartbeat(conn,None,self.config,after)
            s.record_browser_heartbeat(conn,('live','example.com'),self.config,after)
            s.record_browser_heartbeat(conn,('stale','example.com'),self.config,after)
            self.assertAlmostEqual(conn.execute('SELECT seconds FROM quota_usage').fetchone()[0],10)
            self.assertAlmostEqual(conn.execute('SELECT seconds FROM website_usage').fetchone()[0],10)

    def test_reset_endpoint_authorization_and_revision_without_network(self):
        from io import BytesIO
        from email.message import Message
        original = (s.ADMIN,s.DEVICE,s.ACTIVITY,s.BROWSER)
        s.ADMIN,s.DEVICE,s.ACTIVITY,s.BROWSER = 'a'*40,'d'*40,'m'*40,'b'*40
        def request(token, payload):
            handler = s.Handler.__new__(s.Handler)
            handler.path = '/api/admin/usage/reset'
            handler.headers = Message()
            handler.headers['Authorization'] = 'Bearer '+token
            body = json.dumps(payload).encode()
            handler.headers['Content-Length'] = str(len(body))
            handler.rfile = BytesIO(body)
            replies = []
            handler.reply = lambda code,data: replies.append((code,data))
            handler.do_POST()
            return replies[0]
        try:
            revision = s.policy()['revision']
            for token in [s.DEVICE,s.ACTIVITY,s.BROWSER,'']:
                self.assertEqual(request(token,dict(revision=revision))[0],401)
            self.assertEqual(request(s.ADMIN,dict(revision=True))[0],400)
            self.assertEqual(request(s.ADMIN,dict(revision=revision+1))[0],409)
            self.assertGreater(s.quota_state(self.config,self.now)['usedSeconds'],0)
            code,result = request(s.ADMIN,dict(revision=revision))
            self.assertEqual(code,200)
            self.assertEqual(result['revision'],revision+1)
            self.assertEqual(s.policy()['revision'],revision+1)
            self.assertEqual(s.usage_report(self.config,self.now)['apps'],[])
            self.assertEqual(request(s.ADMIN,dict(revision=revision))[0],409)
        finally:
            s.ADMIN,s.DEVICE,s.ACTIVITY,s.BROWSER = original

    def test_reset_does_not_make_offline_monitor_fresh(self):
        with sqlite3.connect(s.DB) as conn:
            conn.execute('UPDATE activity_current SET seen=?', ((self.now-datetime.timedelta(minutes=5)).isoformat(),))
            s.reset_usage_counters(conn,self.now)
        self.assertFalse(s.quota_state(self.config,self.now)['monitoringFresh'])


if __name__ == '__main__': unittest.main()
