"""MacBlock control plane. Put behind an HTTPS reverse proxy; bind loopback."""
import hmac
import json
import os
import re
import sqlite3
import threading
import datetime
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

LOCK = threading.Lock()
DB = os.environ.get('MACBLOCK_DB', 'macblock.sqlite3')
ADMIN = os.environ.get('MACBLOCK_ADMIN_TOKEN', '')
DEVICE = os.environ.get('MACBLOCK_DEVICE_TOKEN', '')
ACTIVITY = os.environ.get('MACBLOCK_ACTIVITY_TOKEN', '')
PRESETS = [dict(name='Roblox', bundleId='com.roblox.RobloxPlayer', blocked=False),
           dict(name='Opera', bundleId='com.operasoftware.Opera', blocked=False)]


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
        conn.execute('INSERT OR IGNORE INTO state VALUES (1, ?)', (json.dumps(dict(schemaVersion=1, revision=1, apps=PRESETS)),))
        conn.execute('CREATE TABLE IF NOT EXISTS status (id INTEGER PRIMARY KEY, payload TEXT, seen TEXT)')
        conn.execute('CREATE TABLE IF NOT EXISTS activity (event_id TEXT PRIMARY KEY, bundle_id TEXT NOT NULL, app_name TEXT NOT NULL, start TEXT NOT NULL, end TEXT NOT NULL)')
        conn.execute('CREATE TABLE IF NOT EXISTS activity_current (id INTEGER PRIMARY KEY, payload TEXT, seen TEXT)')


def policy():
    with sqlite3.connect(DB) as conn:
        return json.loads(conn.execute('SELECT payload FROM state WHERE id=1').fetchone()[0])


def parse_time(value):
    if not isinstance(value, str) or len(value) > 40:
        raise ValueError('Invalid timestamp')
    dt = datetime.datetime.fromisoformat(value.replace('Z', '+00:00'))
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
        parse_time(current['since'])
        if not isinstance(current['bundleId'], str) or not 1 <= len(current['bundleId']) <= 255 or not isinstance(current['appName'], str) or not 1 <= len(current['appName']) <= 100:
            raise ValueError('Invalid current app')
    clean = []
    now = datetime.datetime.now(datetime.timezone.utc)
    for e in events:
        if not isinstance(e, dict) or set(e) != {'eventId', 'bundleId', 'appName', 'startedAt', 'endedAt'}:
            raise ValueError('Invalid event')
        uid = str(uuid.UUID(e['eventId']))
        start, end = parse_time(e['startedAt']), parse_time(e['endedAt'])
        if not start < end or (end - start).total_seconds() > 86400 or end > now + datetime.timedelta(minutes=5):
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
        size = int(self.headers.get('Content-Length', '0'))
        if not 0 < size <= 65536:
            raise ValueError('Invalid body size')
        return json.loads(self.rfile.read(size))

    def do_GET(self):
        assets = {'/': ('index.html', 'text/html; charset=utf-8'), '/app.js': ('app.js', 'text/javascript'), '/style.css': ('style.css', 'text/css')}
        if self.path in assets:
            name, mime = assets[self.path]
            return self.reply(200, Path(__file__).with_name(name).read_text(), mime)
        if self.path == '/api/device/policy':
            if self.authorized(DEVICE):
                self.reply(200, policy())
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
                self.reply(200, dict(policy=policy(), device=dict(report=json.loads(row[0]), lastSeen=row[1]) if row else None))
        else:
            self.reply(404, {'error': 'Not found'})

    def do_POST(self):
        if self.path not in ('/api/admin/policy', '/api/device/status', '/api/device/activity'):
            return self.reply(404, {'error': 'Not found'})
        if not self.authorized(ADMIN if self.path == '/api/admin/policy' else ACTIVITY if self.path == '/api/device/activity' else DEVICE):
            return
        try:
            data = self.body()
            if not isinstance(data, dict):
                raise ValueError('Expected an object')
            if self.path == '/api/device/activity':
                events, current = validate_activity(data)
                with LOCK, sqlite3.connect(DB) as conn:
                    conn.executemany('INSERT OR IGNORE INTO activity VALUES (?,?,?,?,?)', events)
                    conn.execute("INSERT OR REPLACE INTO activity_current VALUES (1, ?, strftime('%Y-%m-%dT%H:%M:%SZ','now'))", (json.dumps(current),))
                return self.reply(200, {'ok': True})
            if self.path == '/api/admin/policy':
                apps = validate_apps(data.get('apps'))
                with LOCK, sqlite3.connect(DB) as conn:
                    current = json.loads(conn.execute('SELECT payload FROM state WHERE id=1').fetchone()[0])
                    if data.get('revision') != current['revision']:
                        return self.reply(409, {'error': 'Settings changed. Reload before saving.'})
                    current.update(apps=apps, revision=current['revision'] + 1)
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
    if min(len(ADMIN), len(DEVICE), len(ACTIVITY)) < 32 or len({ADMIN, DEVICE, ACTIVITY}) != 3:
        raise SystemExit('Set distinct MACBLOCK_ADMIN_TOKEN, MACBLOCK_DEVICE_TOKEN and MACBLOCK_ACTIVITY_TOKEN (at least 32 characters each)')
    init_db()
    ThreadingHTTPServer((os.environ.get('MACBLOCK_BIND', '127.0.0.1'), int(os.environ.get('PORT', '8080'))), Handler).serve_forever()
