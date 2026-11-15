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

## Foreground activity monitoring (experimental)

This feature is separate from the root blocking daemon. It runs inside the logged-in
user's graphical session, watches NSWorkspace foreground app changes, and uploads
completed sessions and the current foreground app to the same VPS. The dashboard
shows recent sessions and a current app only when a recent heartbeat exists.

Set a **third**, distinct, 32+ character random token in the server's environment:

```text
MACBLOCK_ACTIVITY_TOKEN=<separate activity-only token>
```

Restart the VPS service after updating the environment. On the **target Mac**,
while logged in as the account to monitor, create `agent/monitor-settings.json`:

```json
{"serverURL":"https://blocks.example.com","activityToken":"<activity-only token>"}
```

Then run `bash agent/install-monitor.sh` **as that user, not with sudo**.
The monitor is installed in that user's Library and loaded as a per-user
LaunchAgent. Do not commit either settings file. This monitor requires the
user to be logged into a graphical session; it does not track the login screen.

**Limitations:** Foreground time is not proof of active play. Idle detection uses
IOHIDSystem and a 5-minute threshold, with approximate timestamps. Sleep,
fast user switching, and login/logout produce session boundaries. Uploads are
best-effort and queued locally; if the local user can modify the queue or
monitor, the activity log is not tamper-proof. The activity token is scoped
to telemetry ingestion, not policy changes. Do not rely on these logs for
high-stakes decisions. Current activity becomes stale after 2 minutes without
a report. The current summary includes only the latest 500 completed sessions,
not an all-time aggregate.

Test with the target Mac before relying on monitoring. GitHub Actions tests
Swift compilation and deterministic state-machine logic, but cannot prove
NSWorkspace notifications fire in a real interactive login session.

## Server-authoritative time (foundation)

The device policy response includes `serverTimeUTC` (an ISO-8601 UTC instant)
and `enforcementTimeZone` (`America/Los_Angeles`). The root daemon anchors
the received UTC instant to macOS monotonic system uptime. Changing the Mac's
time zone or wall clock does not change that in-memory trusted-time estimate.
On reboot or after a long unsynchronized interval, the anchor is invalidated.
The server's time is transmitted over the existing authenticated HTTPS channel.

**Important:** The current policy schema still only contains static app
`blocked` switches. No bedtime schedules, daily resets, or usage budgets are
enforced by this time anchor yet. Those features must use trusted time and
fail closed when no trusted time is available. Do not use the local Mac clock
as a fallback. The existing static blocked-app policy continues to operate
offline without a time anchor.

## Parent-selected enforcement timezone and nightly schedule

The dashboard provides a dropdown of supported IANA time zones and a nightly
restriction switch with start/end times (24-hour format). The default schedule
is 21:00–07:00 and **disabled** until the parent enables it. When enabled,
**all apps listed in the MacBlock policy** are blocked during that interval;
the individual `blocked` switch remains an unconditional block.

The timezone and schedule are persisted in the server policy, delivered to
the root daemon, and evaluated with server-anchored UTC time using Apple's
timezone database. Overnight intervals and daylight saving time are supported.
The Mac's configured timezone is ignored. When a schedule is enabled but no
valid server time is available, listed apps remain blocked until the daemon
resynchronizes. Static blocks remain effective independently of the clock.

This is scheduled blocking, **not a daily foreground usage quota**. Daily
budgets require additional trusted accounting across reboot and offline periods.

## Daily foreground allowance (experimental)

The parent dashboard has a daily allowance switch, app selector, and minutes
per day (1–1440). The default is 60 minutes for Roblox, **disabled** until
enabled. The server accumulates foreground time from monitor heartbeats using
server receipt timestamps, and stores usage by date in the parent-selected
enforcement timezone. A Mac time-zone change cannot reset that date.

The root daemon fetches the usage decision every 30 seconds when the quota
is enabled. It blocks the selected app when the allowance is exhausted, or
when the monitor, trusted clock, or server policy refresh becomes stale.
The allowance is approximate: 15-second monitor heartbeat plus polling
latency may allow some overrun. No quota is reset on daemon restart.

**Security limitation:** The monitor runs as the child's user and can be
stopped or impersonated by that user; this is not tamper-resistant enforcement.
It must be moved behind privileged authenticated IPC before treating the
activity measurement as trustworthy. A disabled monitor will cause the
limited app to be blocked once the server reports stale monitoring.
The agent and VPS must both be updated before enabling quotas.

## Extended controls (experimental)

Parent dashboard supports per-app schedules, per-app daily allowances,
30-minute temporary overrides (applied when Save is pressed), a website
domain list, and an alert history. The server validates per-app rules,
enforces a maximum 24-hour override, and supplies per-app quota decisions
to the root daemon. A temporary override takes precedence over static,
scheduled, and quota restrictions for that app until expiry.

**Browser limitation:** `browser/chrome/` contains a prototype Chromium
declarativeNetRequest extension. It currently reads rules from Chrome's local
extension storage and is NOT connected to the server's blockedDomains policy.
It is NOT force-installed or protected against removal. Safari requires a
properly signed Safari Web Extension / content blocker or managed network
filter; neither is implemented. The website domain list is configuration
storage only, not active enforcement.

**Security limitation:** The foreground monitor still uses a user-owned
LaunchAgent and bearer token, not protected root-owned authenticated IPC.
A standard user may interfere with or spoof monitoring. Alert history is
visible in the dashboard but there is no push/email notification delivery.
The root daemon and monitor must be tested on an actual Mac before production
use. No automatic deployment is performed.
