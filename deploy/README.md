# VPS deployment

Supports Linux with systemd, Python 3.9+, sudo, git, tar and installed timezone data
(`tzdata`). Uses an isolated service and localhost port 18765 by default. It does
not install or alter a reverse proxy, firewall, DNS, or your Care TV service.

## First installation (on the VPS)

Clone the repository using your normal GitHub authentication if it is private:

```bash
git clone https://github.com/amperie/macblock.git orbit-vps
cd orbit-vps
sudo bash deploy/install.sh
```

An alternative port can be supplied as `sudo bash deploy/install.sh 18766`.
Reruns preserve `/etc/orbit.env`; changing the saved port requires editing that
file. The installer deploys the server files in this checkout. Run it from a
clean checkout of the intended commit. Python 3.9+ is required; use a supported
Linux distribution. On Debian/Ubuntu, missing dependencies can be installed with
`sudo apt-get install python3 git sudo tzdata`.

The service uses `/var/lib/orbit/state.sqlite3`. Four distinct credentials are
generated once in root-readable `/etc/orbit.env`. Inspect them only in your
private terminal with `sudo cat /etc/orbit.env`; never put them in GitHub or git.
The admin token signs into the dashboard; device, activity and browser tokens
belong to their corresponding Mac components. These are new production settings;
your Mac's local development database is not automatically imported.

## HTTPS routing

Point your chosen subdomain at the VPS. Add a virtual host to your **existing**
proxy, using the actual saved port. For an existing Caddy installation, a site
block is:

```caddyfile
orbit.example.com {
    reverse_proxy 127.0.0.1:18765
}
```

For an existing Nginx HTTPS virtual host, its location block is:

```nginx
location / {
    proxy_pass http://127.0.0.1:18765;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-Proto $scheme;
    client_max_body_size 64k;
}
```

Nginx still needs the certificate and `listen 443 ssl` configuration appropriate
to your current setup. Validate your proxy configuration before reloading it.
Do not open port 18765 publicly. Check `sudo systemctl status orbit` and
`sudo journalctl -u orbit -n 50`. Visit your HTTPS address and sign in with the
admin token before installing the Mac agent against that address.

## GitHub deployment access

For guided setup from your Mac, run `bash tools/githubsecrets.sh` after
`gh auth login`. It creates a dedicated SSH key, asks you to verify the VPS host
fingerprint, installs the public key through your existing VPS login, and sets
all four secrets in the repository's `production` environment. Run the VPS
installer first so the `orbit-deploy` account and release helper exist.
The manual alternative follows.

Create a dedicated SSH key for Actions on a trusted computer (not your personal
SSH key):

```bash
ssh-keygen -t ed25519 -f orbit-actions -N '' -C orbit-github-actions
```

On the VPS, add the contents of **orbit-actions.pub** to:

```bash
sudo -u orbit-deploy tee -a /home/orbit-deploy/.ssh/authorized_keys >/dev/null <<'KEY'
restrict ssh-ed25519 REPLACE_WITH_PUBLIC_KEY orbit-github-actions
KEY
sudo chmod 600 /home/orbit-deploy/.ssh/authorized_keys
```

Replace the entire example key with the generated public key, retaining the
`restrict` prefix. The deployment account can invoke only the installed release
helper through passwordless sudo. A deployment key can replace application code,
so protect it as production access. The helper accepts a bounded tar containing
only the four server files; incoming code runs as `orbit`, not root.

Create a GitHub environment named **production** under repository Settings →
Environments. Restrict deployments to `main`. Add its environment secrets:

| Secret | Value |
| --- | --- |
| `VPS_HOST` | VPS hostname or IPv4 address, without a scheme |
| `VPS_PORT` | SSH port, optional; default 22 |
| `VPS_SSH_KEY` | Complete private `orbit-actions` key, including header/footer |
| `VPS_KNOWN_HOSTS` | Verified SSH known_hosts entry for this host and SSH port |

Use the VPS console to verify its host key fingerprint with
`sudo ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub`. Obtain the known_hosts
entry on your trusted computer using `ssh-keyscan -t ed25519 -p 22 YOUR_HOST`,
and compare the fingerprint before saving it. For nonstandard ports the entry
uses `[hostname]:port`. The workflow never disables host verification.

## Automatic releases and recovery

After a push to `main` passes **macOS CI**, **Deploy VPS** tests the server on
Linux and deploys the exact tested commit over SSH. It can also be run manually
on `main` from Actions; manual runs perform Linux tests but do not wait for macOS
CI. Deployment jobs are serialized. No recurring task or VPS GitHub token is
needed. The initial workflow files must be committed and pushed first.

Each deployment stops Orbit briefly, backs up SQLite consistently, switches an
atomic `current` symlink, restarts the service, and calls its authenticated local
health endpoint. On failure it restores the previous code and database snapshot.
The check verifies server/database readiness, not public TLS or Mac connectivity.
The deployment never overwrites credentials or redeploys Mac components.

Releases remain under `/opt/orbit/releases`; predeployment snapshots remain under
`/var/lib/orbit/backups`. They are retained until you remove them: monitor disk
usage and arrange an off-VPS backup. Automatic rollback restores the stopped
database snapshot, so telemetry received during a failed rollout may be lost.
First-install failures leave Orbit stopped and report an error.

For an explicit rollback, redeploy a known-good commit from a trusted checkout:

```bash
git archive --format=tar GOOD_COMMIT server/ | ssh orbit-deploy@YOUR_HOST \
  'sudo -n /usr/local/sbin/orbit-deploy FULL_40_CHARACTER_COMMIT_SHA'
```

An explicit rollback preserves the current database; only automatic failure
rollback restores the matching predeployment database. If a future release adds
incompatible migrations, review database compatibility before rolling back.
Changes to systemd, the installer, or release helper need a reviewed rerun of
the installer on the VPS; application deployments cannot replace root helpers.

## Public privacy policy

The server serves `/privacy` and `/privacy/` without login; the dashboard links
to it. The policy is embedded in `server/server.py` so existing four-file release
helpers deploy it without a privileged helper upgrade. After deploying, verify
`curl --fail https://orbit.side-forge.com/privacy` returns the privacy policy
without an administrator token before submitting that URL to the Chrome Web Store.
