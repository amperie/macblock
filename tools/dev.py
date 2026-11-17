#!/usr/bin/env python3
"""Orbit testing against the VPS by default; --local starts isolated services."""
import argparse
import fcntl
import getpass
import importlib.util
import json
import os
from pathlib import Path
import secrets
import signal
import subprocess
import sys
import tempfile
import time
import urllib.request
from urllib.parse import quote, urlsplit

PROJECT = Path(__file__).resolve().parents[1]
VPS_CONFIG = PROJECT / '.dev' / 'vps.json'
DEFAULT_SERVER = 'https://orbit.side-forge.com'


class NoRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def write_private(path, data):
    fd, temporary = tempfile.mkstemp(dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as stream:
            json.dump(data, stream, indent=2)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def setup(directory, port=None):
    directory = Path(directory).resolve()
    if directory == Path('/Library/Application Support/Orbit'):
        raise ValueError('Use a development directory, separate from production')
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    config_path = directory / 'dev.json'
    # IDE compound launches may start the server and agent simultaneously.
    with (directory / 'setup.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if config_path.exists():
            config = json.loads(config_path.read_text())
            if port is not None and port != config['port']:
                raise ValueError('Port differs from saved dev config; use a different --state-dir')
        else:
            config = dict(port=port or 8765, adminToken=secrets.token_urlsafe(48), deviceToken=secrets.token_urlsafe(48))
            write_private(config_path, config)
        for key in ('activityToken', 'browserToken'):
            if key not in config:
                config[key] = secrets.token_urlsafe(48)
        write_private(config_path, config)
        agent_dir = directory / 'agent'
        agent_dir.mkdir(exist_ok=True, mode=0o700)
        write_private(agent_dir / 'settings.json', dict(serverURL=f"http://127.0.0.1:{config['port']}", deviceToken=config['deviceToken']))
        write_private(directory / 'monitor-settings.json', dict(serverURL=f"http://127.0.0.1:{config['port']}", activityToken=config['activityToken']))
    return directory, config


def build(directory):
    binary = directory / 'orbit-agent'
    subprocess.run(['swiftc', '-g', '-Onone', '-module-cache-path', str(directory / 'modules'),
                    str(PROJECT / 'agent/main.swift'), '-framework', 'Security', '-o', str(binary)], check=True)
    return binary


def setup_remote(directory, config_path=VPS_CONFIG, require_tokens=True):
    directory = Path(directory).resolve()
    if directory == Path('/Library/Application Support/Orbit'):
        raise ValueError('Use a development directory, separate from production')
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    config_path = Path(config_path)
    config_path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    if config_path.exists():
        config = json.loads(config_path.read_text())
    else:
        config = dict(serverURL=DEFAULT_SERVER, adminToken='', deviceToken='', activityToken='')
        write_private(config_path, config)
    config_path.chmod(0o600)
    config.setdefault('serverURL', DEFAULT_SERVER)
    url = urlsplit(config['serverURL'])
    if url.scheme != 'https' or not url.hostname or url.username or url.password or url.query or url.fragment or url.path not in ('', '/'):
        raise ValueError('VPS serverURL must be an HTTPS origin')
    config['serverURL'] = config['serverURL'].rstrip('/')
    if require_tokens:
        for key in ('deviceToken', 'activityToken'):
            token = config.get(key, '')
            if not isinstance(token, str) or not 32 <= len(token) <= 512 or not all(33 <= ord(c) <= 126 for c in token):
                raise ValueError(f'Missing or invalid {key} in {config_path}. Run: python3 tools/dev.py configure')
        if len({config['deviceToken'], config['activityToken'], config.get('adminToken', '')}) != 3:
            raise ValueError('VPS admin, device and activity tokens must be distinct')
        agent_dir = directory / 'agent'
        agent_dir.mkdir(exist_ok=True, mode=0o700)
        # Prevent a previous server's policy cache being applied after a URL change.
        old_settings = agent_dir / 'settings.json'
        if old_settings.exists() and json.loads(old_settings.read_text()).get('serverURL') != config['serverURL']:
            raise ValueError('Server changed; select a fresh --state-dir to avoid mixing policy caches')
        write_private(old_settings, dict(serverURL=config['serverURL'], deviceToken=config['deviceToken']))
        write_private(directory / 'monitor-settings.json', dict(serverURL=config['serverURL'], activityToken=config['activityToken']))
    return directory, config


def print_login_link(config):
    base = config.get('serverURL') or f"http://127.0.0.1:{config['port']}"
    url = base + '/'
    if config.get('adminToken'):
        url += '#token=' + quote(config['adminToken'], safe='')
    print(f"\nOpen Orbit (signed-in development link):\n{url}\n", flush=True)


def build_monitor(directory):
    binary = directory / 'orbit-foreground'
    subprocess.run(['swiftc', '-g', '-Onone', '-module-cache-path', str(directory / 'modules'),
                    str(PROJECT / 'agent/FocusTracker.swift'), str(PROJECT / 'agent/ForegroundMonitor.swift'),
                    '-framework', 'AppKit', '-framework', 'IOKit', '-o', str(binary)], check=True)
    return binary


def serve(directory, config):
    spec = importlib.util.spec_from_file_location('orbit_server', PROJECT / 'server/server.py')
    server = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(server)
    server.DB = str(directory / 'server.sqlite3')
    server.ADMIN, server.DEVICE = config['adminToken'], config['deviceToken']
    server.ACTIVITY, server.BROWSER = config['activityToken'], config['browserToken']
    server.init_db()
    http = server.ThreadingHTTPServer(('127.0.0.1', config['port']), server.Handler)
    print(f"\nOrbit DEVELOPMENT website: http://127.0.0.1:{config['port']}", flush=True)
    print_login_link(config)
    print(f"State: {directory}\n", flush=True)
    try:
        http.serve_forever()
    finally:
        http.server_close()


def agent_command(directory, enforce=False, poll_seconds=3):
    command = [str(directory / 'orbit-agent'), '--dev', '--state-dir', str(directory / 'agent'), '--poll-seconds', str(poll_seconds)]
    return command + (['--enforce'] if enforce else [])


def stop(child):
    if child.poll() is None:
        try:
            os.killpg(child.pid, signal.SIGTERM)
        except ProcessLookupError:
            child.wait()
            return
        try:
            child.wait(timeout=5)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(child.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            child.wait()


def run_all(directory, config, enforce, poll_seconds):
    build(directory)
    monitor = build_monitor(directory)
    children = []
    try:
        remote = 'serverURL' in config
        server = None
        if not remote:
            server = subprocess.Popen([sys.executable, str(__file__), 'server', '--local', '--state-dir', str(directory)], start_new_session=True)
            children.append(server)
        base = config.get('serverURL') or f"http://127.0.0.1:{config['port']}"
        request = urllib.request.Request(base + '/api/device/policy', headers={'Authorization': 'Bearer ' + config['deviceToken']})
        if remote:
            # Fail before starting enforcement when production credentials are wrong.
            with urllib.request.build_opener(NoRedirects).open(request, timeout=10) as response:
                json.load(response)
            print_login_link(config)
        for _ in range(100):
            if remote:
                break
            if server.poll() is not None:
                raise RuntimeError('Website failed to start; agent was not started')
            try:
                with urllib.request.urlopen(request, timeout=0.2) as response:
                    json.load(response)
                break
            except OSError:
                time.sleep(0.1)
        else:
            raise RuntimeError('Website did not become ready')
        children.append(subprocess.Popen(agent_command(directory, enforce, poll_seconds), start_new_session=True))
        children.append(subprocess.Popen([str(monitor)], env=dict(os.environ,
            ORBIT_MONITOR_SETTINGS=str(directory / 'monitor-settings.json'),
            ORBIT_MONITOR_QUEUE=str(directory / 'activity-queue.json'),
            ORBIT_MONITOR_DEVELOPMENT='0' if remote else '1'), start_new_session=True))
        while all(child.poll() is None for child in children):
            time.sleep(0.25)
        raise RuntimeError('A development process exited; stopping the other process')
    finally:
        for child in reversed(children):
            stop(child)


def fixture(directory):
    # A unique non-system identity, intentionally safe to terminate.
    source = directory / 'fixture.c'
    source.write_text('#include <unistd.h>\nint main(void) { for (;;) sleep(1); }\n')
    binary = directory / 'Orbit-Test-App'
    subprocess.run(['clang', '-g', str(source), '-o', str(binary)], check=True)
    subprocess.run(['codesign', '--force', '--sign', '-', '--identifier', 'org.orbit.debug.fixture', str(binary)], check=True)
    print('Add an app on the website: name = Orbit Test App, identifier = org.orbit.debug.fixture', flush=True)
    print('Block it, save, and watch it exit. With dry run it keeps running and the agent logs what it would stop.', flush=True)
    # exec makes IDE stop/Ctrl+C act directly on the fixture.
    os.execv(str(binary), [str(binary)])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['setup', 'configure', 'build', 'server', 'agent', 'all', 'fixture'])
    parser.add_argument('--local', action='store_true', help='Use isolated localhost services instead of the VPS')
    parser.add_argument('--config', type=Path, default=VPS_CONFIG, help='Private VPS JSON config (default: .dev/vps.json)')
    parser.add_argument('--state-dir', type=Path)
    parser.add_argument('--port', type=int)
    parser.add_argument('--poll-seconds', type=float, default=3)
    parser.add_argument('--enforce', action='store_true', help='Actually terminate matching apps owned by the current user (default: dry run)')
    parser.add_argument('--no-build', action='store_true', help='Use an already-built agent')
    args = parser.parse_args()
    if args.command == 'server' and not args.local:
        parser.error('The VPS hosts the server. Use server --local to start a local server.')
    if args.port is not None and not args.local:
        parser.error('--port requires --local')
    if args.port is not None and not 1 <= args.port <= 65535:
        parser.error('--port must be between 1 and 65535')
    if not 1 <= args.poll_seconds <= 3600:
        parser.error('--poll-seconds must be between 1 and 3600')
    def interrupted(*_):
        raise KeyboardInterrupt()
    signal.signal(signal.SIGTERM, interrupted)
    try:
        state_dir = args.state_dir or (PROJECT / '.dev' if args.local else PROJECT / '.dev' / 'vps')
        if args.command == 'configure':
            if args.local:
                raise ValueError('configure is for VPS credentials; local credentials are generated automatically')
            directory, config = setup_remote(state_dir, args.config, require_tokens=False)
            for key, label in [('deviceToken', 'ORBIT_DEVICE_TOKEN'), ('activityToken', 'ORBIT_ACTIVITY_TOKEN')]:
                value = getpass.getpass(label + ' (input hidden; Enter keeps saved value): ')
                if value:
                    config[key] = value
            write_private(args.config, config)
            setup_remote(state_dir, args.config)
            print(f'VPS configuration saved in {args.config}')
            return 0
        directory, config = (setup(state_dir, args.port) if args.local else
                             setup_remote(state_dir, args.config, require_tokens=args.command in ('all', 'agent', 'build')))
        if args.command == 'setup':
            print(f"Settings ready in {directory}; VPS config: {args.config}" if not args.local else f"Local settings ready in {directory}")
        elif args.command == 'build':
            print(build(directory))
        elif args.command == 'server':
            serve(directory, config)
        elif args.command == 'agent':
            if not args.no_build:
                build(directory)
            print_login_link(config)
            os.execv(str(directory / 'orbit-agent'), agent_command(directory, args.enforce, args.poll_seconds))
        elif args.command == 'all':
            run_all(directory, config, args.enforce, args.poll_seconds)
        else:
            fixture(directory)
    except KeyboardInterrupt:
        print('\nDevelopment processes stopped.')
    except (ValueError, OSError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f'Orbit dev: {error}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
