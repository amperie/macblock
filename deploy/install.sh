#!/bin/bash
# One-time setup for a Linux VPS with systemd, Python >= 3.9 and sudo.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ $EUID == 0 ]] || { echo 'Run with sudo bash deploy/install.sh [port]' >&2; exit 1; }
port=${1:-18765}
[[ $port =~ ^[0-9]{4,5}$ ]] && ((port >= 1024 && port <= 65535)) || { echo 'Invalid port' >&2; exit 1; }
command -v systemctl >/dev/null
command -v sudo >/dev/null
python3 -c 'import sys, zoneinfo; assert sys.version_info >= (3, 9)'
if [[ ! -f /etc/orbit.env ]]; then
  python3 - "$port" <<'PY'
import secrets, sys, socket, os
with socket.socket() as check:
    check.bind(('127.0.0.1', int(sys.argv[1])))
fd = os.open('/etc/orbit.env', os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(fd, 'w') as stream:
    stream.write('ORBIT_BIND=127.0.0.1\nPORT=' + sys.argv[1] + '\n')
    for role in ('ADMIN', 'DEVICE', 'ACTIVITY', 'BROWSER'):
        stream.write('ORBIT_' + role + '_TOKEN=' + secrets.token_urlsafe(48) + '\n')
PY
fi
id orbit >/dev/null 2>&1 || useradd --system --home-dir /var/lib/orbit --shell /usr/sbin/nologin orbit
id orbit-deploy >/dev/null 2>&1 || useradd --create-home --shell /bin/bash orbit-deploy
install -d -m 755 /opt/orbit /opt/orbit/releases
install -d -m 700 -o orbit -g orbit /var/lib/orbit
install -d -m 700 -o orbit-deploy -g orbit-deploy /home/orbit-deploy/.ssh
install -m 755 deploy/release.py /usr/local/sbin/orbit-deploy
install -m 644 deploy/orbit.service /etc/systemd/system/orbit.service
sudoers=$(mktemp)
trap 'rm -f "$sudoers"' EXIT
echo 'orbit-deploy ALL=(root) NOPASSWD: /usr/local/sbin/orbit-deploy *' > "$sudoers"
visudo -cf "$sudoers"
install -m 440 "$sudoers" /etc/sudoers.d/orbit-deploy
systemctl daemon-reload
systemctl enable orbit
revision=$(git rev-parse HEAD)
tar -cf - server/server.py server/app.js server/index.html server/style.css | /usr/local/sbin/orbit-deploy "$revision"
echo 'Orbit installed. Configure your existing HTTPS proxy; see deploy/README.md.'
echo 'Credentials remain in /etc/orbit.env; they were not printed or regenerated.'
