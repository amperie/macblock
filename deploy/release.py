#!/usr/bin/python3
"""Root-owned release helper. Accept only a bounded server archive on stdin."""
import fcntl
import io
import json
import os
from pathlib import Path
import re
import shutil
import sqlite3
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.request

ROOT = Path('/opt/orbit')
STATE = Path('/var/lib/orbit')
FILES = {'server/server.py', 'server/app.js', 'server/index.html', 'server/style.css'}
LIMIT = 10 * 1024 * 1024


def unpack(data, destination):
    if len(data) > LIMIT:
        raise ValueError('Release archive exceeds 10 MiB')
    with tarfile.open(fileobj=io.BytesIO(data), mode='r:') as archive:
        seen = set()
        for member in archive:
            if member.isdir() and member.name.rstrip('/') == 'server':
                continue
            if member.name not in FILES or not member.isfile() or member.name in seen:
                raise ValueError('Unexpected or duplicate archive entry')
            if member.size > LIMIT:
                raise ValueError('Release file too large')
            seen.add(member.name)
            target = destination / member.name
            target.parent.mkdir(exist_ok=True)
            target.parent.chmod(0o755)
            with archive.extractfile(member) as source, target.open('wb') as output:
                shutil.copyfileobj(source, output)
            target.chmod(0o644)
        if seen != FILES:
            raise ValueError('Release is missing server files')
    compile((destination / 'server/server.py').read_text(), 'server.py', 'exec')


def settings():
    return dict(line.split('=', 1) for line in Path('/etc/orbit.env').read_text().splitlines()
                if line and not line.startswith('#'))


def healthy(config):
    request = urllib.request.Request(
        'http://127.0.0.1:' + config['PORT'] + '/api/admin/health',
        headers={'Authorization': 'Bearer ' + config['ORBIT_ADMIN_TOKEN']})
    for _ in range(30):
        try:
            with urllib.request.urlopen(request, timeout=2) as response:
                body = json.load(response)
                if response.status == 200 and 'deviceConnected' in body:
                    return True
        except (OSError, ValueError):
            pass
        time.sleep(1)
    return False


def activate(release):
    temporary = ROOT / 'current.next'
    temporary.unlink(missing_ok=True)
    temporary.symlink_to(release)
    temporary.replace(ROOT / 'current')


def deploy(revision):
    releases = ROOT / 'releases'
    releases.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.incoming-', dir=releases) as temporary:
        staging = Path(temporary)
        unpack(sys.stdin.buffer.read(LIMIT + 1), staging)
        staging.chmod(0o755)
        release = releases / (revision + '-' + str(time.time_ns()))
        # Move validated content; TemporaryDirectory can still clean its own path.
        release.mkdir(mode=0o755)
        shutil.move(str(staging / 'server'), release / 'server')
    current = ROOT / 'current'
    previous = current.resolve() if current.is_symlink() else None
    config = settings()
    subprocess.run(['systemctl', 'stop', 'orbit'], check=True)
    database = STATE / 'state.sqlite3'
    backup = None
    try:
        if database.exists():
            backups = STATE / 'backups'
            backups.mkdir(mode=0o700, exist_ok=True)
            candidate = backups / (release.name + '.sqlite3')
            with sqlite3.connect(database) as source, sqlite3.connect(candidate) as target:
                source.backup(target)
            backup = candidate
            backup.chmod(0o600)
        activate(release)
        subprocess.run(['systemctl', 'start', 'orbit'], check=True)
        if not healthy(config):
            raise RuntimeError('New release failed authenticated health check')
    except BaseException:
        subprocess.run(['systemctl', 'stop', 'orbit'], check=False)
        if backup:
            for suffix in ('-wal', '-shm', '-journal'):
                Path(str(database) + suffix).unlink(missing_ok=True)
            shutil.copyfile(backup, database)
            shutil.chown(database, user='orbit', group='orbit')
            database.chmod(0o600)
        if previous:
            activate(previous)
            subprocess.run(['systemctl', 'start', 'orbit'], check=True)
            if not healthy(config):
                raise RuntimeError('Rollback also failed; inspect journalctl -u orbit')
        else:
            current.unlink(missing_ok=True)
        raise
    print('Deployed Orbit release ' + revision)


if __name__ == '__main__':
    if os.geteuid() != 0 or len(sys.argv) != 2 or not re.fullmatch(r'[0-9a-f]{40}', sys.argv[1]):
        sys.exit('Usage: sudo orbit-deploy <40-character commit SHA> < release.tar')
    with open('/run/lock/orbit-deploy.lock', 'w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        deploy(sys.argv[1])
