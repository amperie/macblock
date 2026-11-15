"""MacBlock control plane. Put behind an HTTPS reverse proxy; bind loopback."""
import hmac
import json
import os
import re
import sqlite3
import threading
import datetime
import uuid
import calendar
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

LOCK = threading.Lock()
DB = os.environ.get('MACBLOCK_DB', 'macblock.sqlite3')
ADMIN = os.environ.get('MACBLOCK_ADMIN_TOKEN', '')
DEVICE = os.environ.get('MACBLOCK_DEVICE_TOKEN', '')
ACTIVITY = os.environ.get('MACBLOCK_ACTIVITY_TOKEN', '')
BROWSER = os.environ.get('MACBLOCK_BROWSER_TOKEN', '')
TIME_ZONES = ['America/Los_Angeles', 'America/Denver', 'America/Chicago', 'America/New_York', 'America/Phoenix', 'Pacific/Honolulu', 'Europe/London', 'Europe/Paris', 'Asia/Tokyo', 'Australia/Sydney', 'UTC']
RETENTION_DAYS = int(os.environ.get('MACBLOCK_RETENTION_DAYS', '90'))
if not 1 <= RETENTION_DAYS <= 3650:
    raise ValueError('MACBLOCK_RETENTION_DAYS must be between 1 and 3650')

PRESETS = [dict(name='Roblox', bundleId='com.roblox.RobloxPlayer', blocked=False),
           dict(name='Opera', bundleId='com.operasoftware.Opera', blocked=False)]


def validate_quota(quota):
    if not isinstance(quota, dict) or set(quota) != {'enabled', 'bundleId', 'minutes'}:
        raise ValueError('Invalid quota')
    if type(quota['enabled']) is not bool or type(quota['minutes']) is not int or not 1 <= quota['minutes'] <= 1440:
        raise ValueError('Invalid quota')
    if not isinstance(quota['bundleId'], str) or not re.fullmatch(r'[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)+', quota['bundleId']):
        raise ValueError('Invalid quota app')
    return quota


def quota_state(config, now=None):
    now = now or datetime.datetime.now(datetime.timezone.utc)
    quota = config.get('quota', dict(enabled=False, bundleId='com.roblox.RobloxPlayer', minutes=60))
    zone = ZoneInfo(config.get('enforcementTimeZone', 'America/Los_Angeles'))
    day = now.astimezone(zone).date().isoformat()
    with sqlite3.connect(DB) as conn:
        row = conn.execute('SELECT seconds FROM quota_usage WHERE day=? AND bundle_id=?',
                           (day, quota['bundleId'])).fetchone()
        current = conn.execute('SELECT seen FROM activity_current WHERE id=1').fetchone()
    seconds = row[0] if row else 0.0
    fresh = bool(current and (now - parse_time(current[0])).total_seconds() <= 90)
    return dict(enabled=quota['enabled'], bundleId=quota['bundleId'],
                usedSeconds=seconds, limitSeconds=quota['minutes'] * 60,
                exceeded=seconds >= quota['minutes'] * 60,
                monitoringFresh=fresh, day=day)


def record_heartbeat(conn, current, config, now):
    zone = ZoneInfo(config.get('enforcementTimeZone', 'America/Los_Angeles'))
    day = now.astimezone(zone).date().isoformat()
    previous = conn.execute('SELECT payload, seen FROM activity_current WHERE id=1').fetchone()
    if previous and previous[0] != 'null':
        old = json.loads(previous[0])
        previous_at = parse_time(previous[1])
        elapsed = (now - previous_at).total_seconds()
        if old and 0 < elapsed <= 90:
            # Allocate across midnight in the parent-selected zone. A repeated
            # local hour during DST does not reset or double-count usage.
            add_daily_seconds(conn, 'quota_usage', 'bundle_id',
                              old['bundleId'], previous_at, now, zone)


def validate_domains(domains):
    if not isinstance(domains, list) or len(domains) > 100:
        raise ValueError('Invalid domains')
    clean = []
    for domain in domains:
        if not isinstance(domain, str) or len(domain) > 253 or not re.fullmatch(
                r'[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+', domain):
            raise ValueError('Invalid domain')
        clean.append(domain.lower())
    if len(set(clean)) != len(clean):
        raise ValueError('Duplicate domain')
    return clean


def validate_app_rules(rules, apps):
    if not isinstance(rules, dict) or len(rules) > 100:
        raise ValueError('Invalid per-app rules')
    allowed = {a['bundleId'] for a in apps}
    for bid, rule in rules.items():
        if bid not in allowed or not isinstance(rule, dict) or set(rule) != {'schedule', 'minutes'}:
            raise ValueError('Invalid per-app rule')
        validate_schedule(rule['schedule'])
        if rule['minutes'] is not None and (type(rule['minutes']) is not int or not 1 <= rule['minutes'] <= 1440):
            raise ValueError('Invalid per-app minutes')
    return rules


def validate_overrides(overrides, apps):
    if not isinstance(overrides, dict) or len(overrides) > 100:
        raise ValueError('Invalid overrides')
    allowed = {a['bundleId'] for a in apps}
    now = datetime.datetime.now(datetime.timezone.utc)
    active = {}
    for bid, until in overrides.items():
        expiry = parse_time(until)
        if bid not in allowed or expiry > now + datetime.timedelta(hours=24):
            raise ValueError('Invalid override')
        # Expired temporary allowances must not prevent future parent edits.
        if expiry > now:
            active[bid] = until
    return active


def app_quota_states(config, now=None):
    now = now or datetime.datetime.now(datetime.timezone.utc)
    rules = config.get('appRules', {})
    result = {}
    for bid, rule in rules.items():
        if rule.get('minutes') is None:
            continue
        copy = dict(config, quota=dict(enabled=True, bundleId=bid, minutes=rule['minutes']))
        result[bid] = quota_state(copy, now)
    return result


def validate_schedule(schedule):
    if not isinstance(schedule, dict) or set(schedule) != {'enabled', 'start', 'end'}:
        raise ValueError('Invalid schedule')
    if type(schedule['enabled']) is not bool:
        raise ValueError('Invalid schedule enabled')
    for key in ('start', 'end'):
        if not isinstance(schedule[key], str) or not re.fullmatch(r'(?:[01][0-9]|2[0-3]):[0-5][0-9]', schedule[key]):
            raise ValueError('Invalid schedule time')
    if schedule['start'] == schedule['end']:
        raise ValueError('Schedule start and end must differ')
    return schedule


def validate_timezone(value):
    if value not in TIME_ZONES:
        raise ValueError('Unsupported timezone')
    return value


def validate_apps(apps):
    if not isinstance(apps, list) or len(apps) > 100:
        raise ValueError('Supply at most 100 apps')
    seen = set()
    for app in apps:
        if not isinstance(app, dict) or set(app) != {'name', 'bundleId', 'blocked'}:
            raise ValueError('Each app requires name, bundleId, blocked')
        if not isinstance(app['name'], str) or not 1 <= len(app['name'].strip()) <= 80:
            raise ValueError('Invalid app name')
        bid = app['bundleId']
        if not isinstance(bid, str) or not re.fullmatch(r'[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)+', bid) or len(bid) > 255:
            raise ValueError('Invalid bundle identifier')
        if bid.lower().startswith(('com.apple.', 'com.macblock.')):
            raise ValueError('System and MacBlock apps cannot be blocked')
        if bid in seen or type(app['blocked']) is not bool:
            raise ValueError('Duplicate app or invalid block switch')
        seen.add(bid)
    return apps


def init_db():
    with sqlite3.connect(DB) as conn:
        conn.execute('CREATE TABLE IF NOT EXISTS state (id INTEGER PRIMARY KEY, payload TEXT NOT NULL)')
        conn.execute('INSERT OR IGNORE INTO state VALUES (1, ?)', (json.dumps(dict(schemaVersion=1, revision=1, apps=PRESETS, enforcementTimeZone='America/Los_Angeles', schedule=dict(enabled=False, start='21:00', end='07:00'), quota=dict(enabled=False, bundleId='com.roblox.RobloxPlayer', minutes=60))),))
        row = conn.execute('SELECT payload FROM state WHERE id=1').fetchone()
        existing = json.loads(row[0])
        if 'enforcementTimeZone' not in existing or 'schedule' not in existing:
            existing.setdefault('enforcementTimeZone', 'America/Los_Angeles')
            existing.setdefault('schedule', dict(enabled=False, start='21:00', end='07:00'))
            conn.execute('UPDATE state SET payload=? WHERE id=1', (json.dumps(existing),))
        existing.setdefault('quota', dict(enabled=False, bundleId='com.roblox.RobloxPlayer', minutes=60))
        existing.setdefault('blockedDomains', [])
        existing.setdefault('appRules', {})
        existing.setdefault('overrides', {})
        conn.execute('UPDATE state SET payload=? WHERE id=1', (json.dumps(existing),))
        conn.execute('CREATE TABLE IF NOT EXISTS quota_usage (day TEXT NOT NULL, bundle_id TEXT NOT NULL, seconds REAL NOT NULL, PRIMARY KEY(day,bundle_id))')
        conn.execute('CREATE TABLE IF NOT EXISTS status (id INTEGER PRIMARY KEY, payload TEXT, seen TEXT)')
        conn.execute('CREATE TABLE IF NOT EXISTS alerts (id INTEGER PRIMARY KEY AUTOINCREMENT, kind TEXT, message TEXT, created TEXT)')
        conn.execute('CREATE TABLE IF NOT EXISTS activity (event_id TEXT PRIMARY KEY, bundle_id TEXT NOT NULL, app_name TEXT NOT NULL, start TEXT NOT NULL, end TEXT NOT NULL)')
        conn.execute('CREATE TABLE IF NOT EXISTS activity_current (id INTEGER PRIMARY KEY, payload TEXT, seen TEXT)')
        conn.execute('CREATE TABLE IF NOT EXISTS website_usage (day TEXT NOT NULL, domain TEXT NOT NULL, seconds REAL NOT NULL, PRIMARY KEY(day,domain))')
        conn.execute('CREATE TABLE IF NOT EXISTS browser_current (id INTEGER PRIMARY KEY, domain TEXT, seen TEXT)')
        prune_history(conn)


def prune_history(conn, now=None):
    """Retain 90 rolling calendar days by default; keep current quota data intact."""
    now = now or datetime.datetime.now(datetime.timezone.utc)
    cutoff = (now - datetime.timedelta(days=RETENTION_DAYS)).date().isoformat()
    conn.execute('DELETE FROM quota_usage WHERE day < ?', (cutoff,))
    conn.execute('DELETE FROM website_usage WHERE day < ?', (cutoff,))
    conn.execute('DELETE FROM activity WHERE end < ?', ((now - datetime.timedelta(days=RETENTION_DAYS)).isoformat(),))
    conn.execute('DELETE FROM alerts WHERE created < ?', ((now - datetime.timedelta(days=RETENTION_DAYS)).isoformat(),))


def add_daily_seconds(conn, table, key_column, key, start, end, zone):
    """Split server-observed usage at local midnight, including DST transitions."""
    cursor = start
    while cursor < end:
        day = cursor.astimezone(zone).date()
        next_midnight = datetime.datetime.combine(
            day + datetime.timedelta(days=1), datetime.time.min,
            tzinfo=zone).astimezone(datetime.timezone.utc)
        boundary = min(end, next_midnight)
        if boundary <= cursor:
            break
        conn.execute(
            f'INSERT INTO {table}(day,{key_column},seconds) VALUES(?,?,?) '
            f'ON CONFLICT(day,{key_column}) DO UPDATE SET seconds=seconds+excluded.seconds',
            (day.isoformat(), key, (boundary - cursor).total_seconds()))
        cursor = boundary


def record_browser_heartbeat(conn, domain, config, now):
    previous = conn.execute('SELECT domain, seen FROM browser_current WHERE id=1').fetchone()
    if previous and previous[0]:
        start = parse_time(previous[1])
        elapsed = (now - start).total_seconds()
        if 0 < elapsed <= 90:
            zone = ZoneInfo(config.get('enforcementTimeZone', 'America/Los_Angeles'))
            add_daily_seconds(conn, 'website_usage', 'domain', previous[0], start, now, zone)
    conn.execute('INSERT OR REPLACE INTO browser_current(id,domain,seen) VALUES(1,?,?)',
                 (domain, now.isoformat()))


def validate_browser_heartbeat(payload):
    if not isinstance(payload, dict) or set(payload) != {'domain'}:
        raise ValueError('Invalid browser heartbeat')
    domain = payload['domain']
    if domain is not None:
        if not isinstance(domain, str) or len(domain) > 253 or not re.fullmatch(
                r'[a-z0-9-]+(?:\\.[a-z0-9-]+)+', domain):
            raise ValueError('Invalid website domain')
    return domain


def usage_report(config, now=None):
    now = now or datetime.datetime.now(datetime.timezone.utc)
    zone = ZoneInfo(config.get('enforcementTimeZone', 'America/Los_Angeles'))
    today = now.astimezone(zone).date()
    cutoff = (today - datetime.timedelta(days=RETENTION_DAYS - 1)).isoformat()
    results = {'apps': [], 'websites': []}
    with sqlite3.connect(DB) as conn:
        for kind, table, column in (('apps', 'quota_usage', 'bundle_id'),
                                    ('websites', 'website_usage', 'domain')):
            rows = conn.execute(
                f'SELECT day,{column},seconds FROM {table} WHERE day>=? AND day<=? ORDER BY day',
                (cutoff, today.isoformat())).fetchall()
            by_key = {}
            for day, key, seconds in rows:
                entry = by_key.setdefault(key, {'id': key, 'days': {}, 'weeks': {}})
                entry['days'][day] = round(seconds, 1)
                week = datetime.date.fromisoformat(day)
                week_start = (week - datetime.timedelta(days=week.weekday())).isoformat()
                entry['weeks'][week_start] = round(entry['weeks'].get(week_start, 0) + seconds, 1)
            results[kind] = sorted(by_key.values(), key=lambda e: e['id'])
    return dict(timeZone=str(zone), retentionDays=RETENTION_DAYS,
                startDate=cutoff, endDate=today.isoformat(), **results)


def policy():
    with sqlite3.connect(DB) as conn:
        return json.loads(conn.execute('SELECT payload FROM state WHERE id=1').fetchone()[0])


def parse_time(value):
    if not isinstance(value, str) or len(value) > 40:
        raise ValueError('Invalid timestamp')
    try:
        dt = datetime.datetime.fromisoformat(value.replace('Z', '+00:00'))
    except (ValueError, OverflowError) as exc:
        raise ValueError('Invalid timestamp') from exc
    if dt.tzinfo is None:
        raise ValueError('Timezone required')
    return dt.astimezone(datetime.timezone.utc)


def validate_activity(data):
    if not isinstance(data, dict) or set(data) != {'events', 'current'}:
        raise ValueError('Invalid activity payload')
    events = data['events']
    if not isinstance(events, list) or len(events) > 100:
        raise ValueError('Invalid events')
    current = data['current']
    if current is not None:
        if not isinstance(current, dict) or set(current) != {'bundleId', 'appName', 'since'}:
            raise ValueError('Invalid current app')
        since = parse_time(current['since'])
        if since > datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(minutes=5):
            raise ValueError('Future current app')
        if not isinstance(current['bundleId'], str) or not 1 <= len(current['bundleId']) <= 255 or not isinstance(current['appName'], str) or not 1 <= len(current['appName']) <= 100:
            raise ValueError('Invalid current app')
    clean = []
    now = datetime.datetime.now(datetime.timezone.utc)
    for e in events:
        if not isinstance(e, dict) or set(e) != {'eventId', 'bundleId', 'appName', 'startedAt', 'endedAt'}:
            raise ValueError('Invalid event')
        if not isinstance(e['eventId'], str):
            raise ValueError('Invalid event ID')
        uid = str(uuid.UUID(e['eventId']))
        start, end = parse_time(e['startedAt']), parse_time(e['endedAt'])
        if not start < end or (end - start).total_seconds() > 86400 or end > now + datetime.timedelta(minutes=5) or start < now - datetime.timedelta(days=RETENTION_DAYS):
            raise ValueError('Invalid event duration')
        if not isinstance(e['bundleId'], str) or not 1 <= len(e['bundleId']) <= 255 or not isinstance(e['appName'], str) or not 1 <= len(e['appName']) <= 100:
            raise ValueError('Invalid app')
        clean.append((uid, e['bundleId'], e['appName'], start.isoformat(), end.isoformat()))
    return clean, current


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        # Do not log credentials or request bodies.
        pass

    def reply(self, code, data, content_type='application/json'):
        body = data.encode() if isinstance(data, str) else json.dumps(data).encode()
        self.send_response(code)
        self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-store')
        self.send_header('X-Content-Type-Options', 'nosniff')
        self.send_header('X-Frame-Options', 'DENY')
        self.send_header('Content-Security-Policy', "default-src 'self'; script-src 'self'; style-src 'self'; frame-ancestors 'none'; base-uri 'none'")
        self.end_headers()
        self.wfile.write(body)

    def authorized(self, token):
        supplied = self.headers.get('Authorization', '')
        if not hmac.compare_digest(supplied.encode('utf-8'), ('Bearer ' + token).encode('utf-8')):
            self.reply(401, {'error': 'Unauthorized'})
            return False
        return True

    def body(self):
        try:
            size = int(self.headers.get('Content-Length', '0'))
        except ValueError:
            raise ValueError('Invalid body size')
        if not 0 < size <= 65536:
            raise ValueError('Invalid body size')
        return json.loads(self.rfile.read(size))

    def do_GET(self):
        assets = {'/': ('index.html', 'text/html; charset=utf-8'), '/app.js': ('app.js', 'text/javascript'), '/style.css': ('style.css', 'text/css')}
        if self.path in assets:
            name, mime = assets[self.path]
            return self.reply(200, Path(__file__).with_name(name).read_text(), mime)
        if self.path == '/api/admin/health':
            if self.authorized(ADMIN):
                now = datetime.datetime.now(datetime.timezone.utc)
                with sqlite3.connect(DB) as conn:
                    device = conn.execute('SELECT seen FROM status WHERE id=1').fetchone()
                    monitor = conn.execute('SELECT seen FROM activity_current WHERE id=1').fetchone()
                device_age = (now - parse_time(device[0])).total_seconds() if device else None
                monitor_age = (now - parse_time(monitor[0])).total_seconds() if monitor else None
                self.reply(200, dict(
                    deviceConnected=device_age is not None and 0 <= device_age <= 300,
                    monitorConnected=monitor_age is not None and 0 <= monitor_age <= 90,
                    deviceAgeSeconds=device_age, monitorAgeSeconds=monitor_age,
                    browserProtectionVerified=False,
                    browserProtectionReason='No authenticated browser enforcement attestation is implemented'))
        elif self.path == '/api/device/policy':
            if self.authorized(DEVICE):
                config = policy()
                rules = config.get('appRules', {})
                self.reply(200, dict(config,
                    appSchedules={bid: rule['schedule'] for bid, rule in rules.items()},
                    appQuotaStates=app_quota_states(config),
                    serverTimeUTC=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                    quotaState=quota_state(config)))
        elif self.path == '/api/browser/domains':
            if self.authorized(BROWSER):
                config = policy()
                self.reply(200, dict(revision=config['revision'], blockedDomains=config.get('blockedDomains', [])))
        elif self.path == '/api/admin/alerts':
            if self.authorized(ADMIN):
                with sqlite3.connect(DB) as conn:
                    rows = conn.execute('SELECT id, kind, message, created FROM alerts ORDER BY id DESC LIMIT 100').fetchall()
                self.reply(200, {'alerts': [dict(id=r[0], kind=r[1], message=r[2], created=r[3]) for r in rows]})
        elif self.path == '/api/admin/usage':
            if self.authorized(ADMIN):
                self.reply(200, usage_report(policy()))
        elif self.path == '/api/admin/activity':
            if self.authorized(ADMIN):
                with sqlite3.connect(DB) as conn:
                    rows = conn.execute('SELECT bundle_id, app_name, start, end FROM activity ORDER BY start DESC LIMIT 500').fetchall()
                    current = conn.execute('SELECT payload, seen FROM activity_current WHERE id=1').fetchone()
                self.reply(200, {'events': [dict(bundleId=r[0], appName=r[1], startedAt=r[2], endedAt=r[3]) for r in rows],
                                 'current': json.loads(current[0]) if current else None,
                                 'lastSeen': current[1] if current else None})
        elif self.path == '/api/admin/state':
            if self.authorized(ADMIN):
                with sqlite3.connect(DB) as conn:
                    row = conn.execute('SELECT payload, seen FROM status WHERE id=1').fetchone()
                config = policy()
                self.reply(200, dict(timeZones=TIME_ZONES, policy=config, quotaState=quota_state(config), appQuotaStates=app_quota_states(config), device=dict(report=json.loads(row[0]), lastSeen=row[1]) if row else None))
        else:
            self.reply(404, {'error': 'Not found'})

    def do_POST(self):
        if self.path not in ('/api/admin/policy', '/api/device/status', '/api/device/activity', '/api/browser/activity'):
            return self.reply(404, {'error': 'Not found'})
        if not self.authorized(ADMIN if self.path == '/api/admin/policy' else ACTIVITY if self.path == '/api/device/activity' else BROWSER if self.path == '/api/browser/activity' else DEVICE):
            return
        try:
            data = self.body()
            if not isinstance(data, dict):
                raise ValueError('Expected an object')
            if self.path == '/api/browser/activity':
                domain = validate_browser_heartbeat(data)
                with LOCK, sqlite3.connect(DB) as conn:
                    now = datetime.datetime.now(datetime.timezone.utc)
                    config = json.loads(conn.execute('SELECT payload FROM state WHERE id=1').fetchone()[0])
                    record_browser_heartbeat(conn, domain, config, now)
                    prune_history(conn, now)
                return self.reply(200, {'ok': True})
            if self.path == '/api/device/activity':
                events, current = validate_activity(data)
                with LOCK, sqlite3.connect(DB) as conn:
                    now = datetime.datetime.now(datetime.timezone.utc)
                    config = json.loads(conn.execute('SELECT payload FROM state WHERE id=1').fetchone()[0])
                    record_heartbeat(conn, current, config, now)
                    previous = conn.execute('SELECT seen FROM activity_current WHERE id=1').fetchone()
                    if previous and (now - parse_time(previous[0])).total_seconds() > 300:
                        conn.execute("INSERT INTO alerts(kind,message,created) VALUES('monitor','Activity monitor reconnected after an outage',?)", (now.isoformat(),))
                    conn.executemany('INSERT OR IGNORE INTO activity VALUES (?,?,?,?,?)', events)
                    prune_history(conn, now)
                    conn.execute("INSERT OR REPLACE INTO activity_current VALUES (1, ?, strftime('%Y-%m-%dT%H:%M:%SZ','now'))", (json.dumps(current),))
                return self.reply(200, {'ok': True})
            if self.path == '/api/admin/policy':
                apps = validate_apps(data.get('apps'))
                with LOCK, sqlite3.connect(DB) as conn:
                    current = json.loads(conn.execute('SELECT payload FROM state WHERE id=1').fetchone()[0])
                    if data.get('revision') != current['revision']:
                        return self.reply(409, {'error': 'Settings changed. Reload before saving.'})
                    tz = validate_timezone(data.get('enforcementTimeZone', current.get('enforcementTimeZone', 'America/Los_Angeles')))
                    schedule = validate_schedule(data.get('schedule', current.get('schedule', dict(enabled=False, start='21:00', end='07:00'))))
                    quota = validate_quota(data.get('quota', current.get('quota', dict(enabled=False, bundleId='com.roblox.RobloxPlayer', minutes=60))))
                    if quota['enabled'] and quota['bundleId'] not in {app['bundleId'] for app in apps}:
                        raise ValueError('Quota app must be in the policy')
                    domains = validate_domains(data.get('blockedDomains', current.get('blockedDomains', [])))
                    rules = validate_app_rules(data.get('appRules', current.get('appRules', {})), apps)
                    overrides = validate_overrides(data.get('overrides', current.get('overrides', {})), apps)
                    current.update(apps=apps, enforcementTimeZone=tz, schedule=schedule, quota=quota, appRules=rules, overrides=overrides, blockedDomains=domains, revision=current['revision'] + 1)
                    conn.execute("INSERT INTO alerts(kind,message,created) VALUES('policy','Parent changed MacBlock restrictions',?)", (datetime.datetime.now(datetime.timezone.utc).isoformat(),))
                    conn.execute('UPDATE state SET payload=? WHERE id=1', (json.dumps(current),))
                self.reply(200, current)
            else:
                if set(data) != {'revision', 'agentVersion', 'lastError'} or type(data['revision']) is not int or data['revision'] < 0 or not isinstance(data['agentVersion'], str) or len(data['agentVersion']) > 40 or not isinstance(data['lastError'], str) or len(data['lastError']) > 500:
                    raise ValueError('Invalid status')
                with sqlite3.connect(DB) as conn:
                    conn.execute("INSERT OR REPLACE INTO status VALUES (1, ?, strftime('%Y-%m-%dT%H:%M:%SZ','now'))", (json.dumps(data),))
                self.reply(200, {'ok': True})
        except (ValueError, TypeError, KeyError, OverflowError, json.JSONDecodeError):
            self.reply(400, {'error': 'Invalid request; check app names and bundle identifiers'})


if __name__ == '__main__':
    if min(len(ADMIN), len(DEVICE), len(ACTIVITY), len(BROWSER)) < 32 or len({ADMIN, DEVICE, ACTIVITY, BROWSER}) != 4:
        raise SystemExit('Set distinct MACBLOCK_ADMIN_TOKEN, MACBLOCK_DEVICE_TOKEN, MACBLOCK_ACTIVITY_TOKEN and MACBLOCK_BROWSER_TOKEN (at least 32 characters each)')
    init_db()
    ThreadingHTTPServer((os.environ.get('MACBLOCK_BIND', '127.0.0.1'), int(os.environ.get('PORT', '8080'))), Handler).serve_forever()
