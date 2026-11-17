#!/usr/bin/env python3
"""IDE entry point for isolated local Orbit development (Python standard library)."""
import argparse
import fcntl
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
from urllib.parse import quote

PROJECT = Path(__file__).resolve().parents[1]


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


def print_login_link(config):
    url = f"http://127.0.0.1:{config['port']}/#token={quote(config['adminToken'], safe='')}"
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
        server = subprocess.Popen([sys.executable, str(__file__), 'server', '--state-dir', str(directory)], start_new_session=True)
        children.append(server)
        request = urllib.request.Request(f"http://127.0.0.1:{config['port']}/api/device/policy", headers={'Authorization': 'Bearer ' + config['deviceToken']})
        for _ in range(100):
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
            ORBIT_MONITOR_DEVELOPMENT='1'), start_new_session=True))
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
    parser.add_argument('command', choices=['setup', 'build', 'server', 'agent', 'all', 'fixture'])
    parser.add_argument('--state-dir', type=Path, default=PROJECT / '.dev')
    parser.add_argument('--port', type=int)
    parser.add_argument('--poll-seconds', type=float, default=3)
    parser.add_argument('--enforce', action='store_true', help='Actually terminate matching apps owned by the current user (default: dry run)')
    parser.add_argument('--no-build', action='store_true', help='Use an already-built agent')
    args = parser.parse_args()
    if args.port is not None and not 1 <= args.port <= 65535:
        parser.error('--port must be between 1 and 65535')
    if not 1 <= args.poll_seconds <= 3600:
        parser.error('--poll-seconds must be between 1 and 3600')
    def interrupted(*_):
        raise KeyboardInterrupt()
    signal.signal(signal.SIGTERM, interrupted)
    try:
        directory, config = setup(args.state_dir, args.port)
        if args.command == 'setup':
            print(f"Local settings ready in {directory}")
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
