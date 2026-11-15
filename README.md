# MacBlock

Remote parental controls for macOS: a Python parent dashboard and a privileged Swift agent that terminates blocked signed applications. Foreground monitoring supports usage history, schedules, quotas and temporary allowances. Chrome and Safari WebExtension integration is **experimental**.

## Quick start — local Mac testing

**Default mode enforces real blocks.** If Roblox is blocked in the dashboard, the root daemon can terminate it. Use a dedicated test Mac or account. Administrator authentication is required.

Prerequisites: macOS, Python 3.9+, Node.js, Xcode Command Line Tools, and `mkcert`:

```bash
brew install mkcert
mkcert -install
git clone https://github.com/amperie/macblock.git
cd macblock
bash dev/start.sh
```

The launcher starts an HTTPS server at **https://localhost:18443/**, creates a private SQLite database and random development credentials, starts the foreground monitor, and installs the privileged daemon for actual app blocking. The parent token is printed in the terminal. It does not replace an existing MacBlock daemon.

```bash
bash dev/start.sh --no-enforce  # No root daemon; test dashboard/monitor only
bash dev/start.sh --help        # Show startup usage
bash dev/test.sh                # Run Python, JavaScript and macOS Swift checks
bash dev/browsers.sh            # Prepare local Chrome extension and Safari Xcode project
bash dev/stop.sh                # Stop local processes, uninstall and verify dev daemon
```

**Ctrl-C or normal script exit calls `dev/stop.sh` automatically.** Only a daemon tagged as belonging to the development session can be uninstalled. The stop script refuses to remove a pre-existing or unowned daemon and reports if cleanup is incomplete. A forced shutdown, crash, power loss, or lost sudo authorization can prevent automatic cleanup; run `bash dev/stop.sh` to recover. It requires administrator authorization to remove the root daemon. Development credentials and builds live in the Git-ignored `.macblock-dev/` directory.

### Browser setup for local testing

Chrome: run `bash dev/browsers.sh`, open `chrome://extensions`, enable Developer Mode, click **Load unpacked**, and select `.macblock-dev/chrome-extension`.

Safari: the same script attempts to generate an Xcode Safari Web Extension project. With full Xcode installed, choose a signing team, build and run the containing app, then enable its extension in Safari Settings. **Neither browser extension is silently registered or enabled by the script.** Browser filtering must be verified interactively.

See [dev/README.md](dev/README.md) for more detail.

## Features and status

| Feature | Implementation | Verification |
| --- | --- | --- |
| Remote application blocking (Roblox preset) | Implemented, root daemon | Automated macOS CI; real-device validation required |
| Parent dashboard and HTTPS policy API | Implemented | Server tests |
| Per-app and global schedules | Implemented | Automated schedule tests |
| Daily quotas and temporary allowances | Experimental | Automated accounting tests; approximate usage |
| Daily/weekly application usage history | Implemented | Server-observed foreground heartbeat accounting; 90-day default retention |
| Daily/weekly website usage history | Experimental | Active-tab/idle sampling; browser extension required; approximate time |
| Foreground activity monitoring | Implemented, user LaunchAgent | Swift tests; not tamper-resistant |
| Website domain configuration | Implemented | Server tests |
| Chrome extension filtering | Experimental | Local unpacked installation/manual verification required |
| Safari WebExtension | Experimental | Xcode signing, enabling, real Safari verification required |
| Browser protection health | Reports unverified | No authenticated extension attestation |
| VPS deployment and auto-updates | Not automated | Requires separate deployment |

### Security limitations

Usage history is retained for 90 local calendar days by default; set `MACBLOCK_RETENTION_DAYS` (1–3650) to change it. Pruning runs on server startup and incoming telemetry. The dashboard shows app and website totals by day and Monday-start week. Website tracking stores domain names, not URLs, and is approximate. Browser extension permissions include tabs and idle; actual Safari compatibility remains unverified.\n\nThe foreground monitor is owned by the logged-in user; its activity reports are not tamper-resistant. The daemon uses code-signing identifiers to find apps and sends SIGKILL; unsaved application data may be lost. A standard child account and private administrator password are strongly recommended. Browser extensions can be disabled or bypassed through unapproved browsers unless additional management is deployed. Do not rely on this software as fully bypass-resistant parental control until testing on the target Mac is complete.

## Deploying the server to a VPS

Run `server/server.py` behind an HTTPS reverse proxy bound to `127.0.0.1`, with a persistent SQLite database. Set four distinct random bearer tokens of at least 32 characters: `MACBLOCK_ADMIN_TOKEN`, `MACBLOCK_DEVICE_TOKEN`, `MACBLOCK_ACTIVITY_TOKEN`, and `MACBLOCK_BROWSER_TOKEN`. Do not expose the Python server directly to the Internet. See `deploy/macblock.service` for the systemd service and `browser/README.md` for extension provisioning.

## Installing on the target Mac

Create `agent/settings.json` containing an HTTPS `serverURL` and `deviceToken`, then run `sudo bash agent/install.sh`. For foreground telemetry, create `agent/monitor-settings.json` with `serverURL` and `activityToken`, then run `bash agent/install-monitor.sh` as the logged-in user. These **production install scripts persist**; unlike the local development launcher, they are not automatically uninstalled.

See `browser/README.md` for managed Chrome installation and Safari signing requirements. Neither extension has been verified on the target Mac.

## Development

Source: `agent/` (Swift daemon and monitor), `server/` (Python control plane and dashboard), `browser/` (WebExtensions), `dev/` (local launch/cleanup/testing), `tests/` (regression suite), `.github/workflows/` (macOS CI).

The project is currently intended for a single Mac and parent. Offline policy caching, server-anchored time, and stale-quota fail-closed behavior are implemented, but real-device integration and security testing remain necessary.
