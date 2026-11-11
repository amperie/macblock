# MacBlock

A parent control website and macOS background agent for periodically terminating selected signed applications. Roblox and Opera are presets; additional apps can be added by signing identifier. No DNS changes, VPN interception, website filtering, or Endpoint Security entitlement is involved in this version.

## Behavior

- The agent scans processes every two seconds, checks their running code identity with Apple's Security framework, and sends SIGKILL to matching apps while their switch is enabled.
- Policy is fetched over HTTPS every 120 seconds, independently of process enforcement. A slow request may add up to 25 seconds to the refresh cycle.
- Valid policies are written atomically to root-owned local storage and survive server outages and reboots. Bad responses and decreasing revisions do not replace the cache.
- First installation has no cached rules: it must connect successfully before blocking begins. The website reports last contact and the received revision, not proof that every process was terminated.
- Unblocking permits future launches; it does not reopen applications that were stopped. Unsaved app data can be lost when an app is killed.
- This is a one-Mac, one-parent control service. A standard child account is recommended. An administrator can remove the daemon.

## Server on your VPS

Requires Python 3.9 or later, no third-party Python packages. Use a dedicated subdomain and an HTTPS reverse proxy; the service binds only to loopback by default. Run it separately from CareTV.

1. Copy `server/` to `/opt/macblock/server`.
2. Create an unprivileged `macblock` system user/group.
3. Generate two different random tokens, for example by running `python3 -c 'import secrets; print(secrets.token_urlsafe(48))'` twice. Keep them private.
4. Create `/etc/macblock.env`, owned by root with mode 600:

```text
MACBLOCK_ADMIN_TOKEN=<parent token>
MACBLOCK_DEVICE_TOKEN=<device token>
PORT=8080
```

5. Install `deploy/macblock.service` into `/etc/systemd/system/`, then enable/start it with systemctl. The service stores its SQLite database in `/var/lib/macblock`.
6. Configure your existing reverse proxy to forward a dedicated HTTPS hostname to `127.0.0.1:8080`. For example, in Caddy:

```caddy
blocks.example.com {
    request_body {
        max_size 64KB
    }
    reverse_proxy 127.0.0.1:8080
}
```

Use your own hostname. Keep port 8080 off the public Internet. Configure request timeouts and rate limits at your reverse proxy if available. The server uses high-entropy bearer tokens, not a guessable password. The parent token is kept in browser memory only. Mutations require an Authorization header; cross-origin access is not enabled.

Back up the SQLite database. Rotate either credential by changing the environment and restarting the service; also update the agent when rotating its credential. Do not log Authorization headers at the reverse proxy. TLS is the transport authenticity mechanism in this version; policies do not yet have separate cryptographic signatures.

## Install on the daughter's Mac

Build on the target Mac with Xcode Command Line Tools installed. Do not run the installer on your development Mac unless you intend to install blocking there.

Create `agent/settings.json` (ignored by Git):

```json
{
  "serverURL": "https://blocks.example.com",
  "deviceToken": "<device token>"
}
```

Do not put a trailing slash on the server URL. Then run:

```sh
sudo bash agent/install.sh
```

The installer compiles the agent, installs it in `/Library/PrivilegedHelperTools`, protects settings under `/Library/Application Support/MacBlock`, and registers a system LaunchDaemon. Confirm that the Mac appears on the website before enabling restrictions.

To inspect service state:

```sh
sudo launchctl print system/com.macblock.agent
```

To stop protection for recovery:

```sh
sudo launchctl bootout system/com.macblock.agent
```

To start it again:

```sh
sudo launchctl bootstrap system /Library/LaunchDaemons/com.macblock.agent.plist
```

To uninstall, boot it out and remove its plist, executable, and `/Library/Application Support/MacBlock` directory as administrator.

## Adding another app

The website accepts a name and exact signing identifier. For normal signed Mac apps it is usually the bundle identifier, but confirm it using:

```sh
codesign -dv --verbose=4 '/Applications/Opera.app'
```

Use the `Identifier=` value. Presets are `com.roblox.RobloxPlayer` and `com.operasoftware.Opera`; verify the actual installed versions. Opera GX, Roblox Studio, and other variants may require separate entries. Added apps start allowed until you switch them on and save.

The agent validates code signatures but does not pin an expected developer Team ID. This handles normal signed apps moved or renamed on disk; it is not intended to defeat modified/re-signed apps, unsigned apps, or an adversarial administrator. Shell scripts and apps with different helper signing identifiers need separate consideration. Apple and MacBlock identifiers are rejected to reduce accidental system damage.

## Verification

```sh
python3 -m unittest discover -s tests -v
node --check server/app.js
swiftc -module-cache-path /tmp/macblock-swift-cache agent/main.swift -framework Security -o /tmp/macblock-agent
```

Integration tests cover parent/device credential separation, policy revision conflicts, durable storage, status reporting, and rejection of invalid/system app rules. The agent also offers `/tmp/macblock-agent --check-policy /path/to/policy.json` for validating a policy without installing it.

Before relying on it, test on the target Mac: enable each preset while the app runs; try reopening it; disable and reopen; reboot while offline; change Wi-Fi/VPN; and verify that a server outage preserves restrictions. Actual root-daemon process termination and browser UI interactions have not been verified by these automated tests. This first version does not provide a signed/notarized installer or signed auto-updates.
