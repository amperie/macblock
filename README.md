# Orbit

**Orbit** uses the reverse-DNS namespace `com.side-forge.orbit` (based on `side-forge.com`). The application, daemon, monitor, browser extension, development tools, and environment variables have been renamed. The GitHub repository is `amperie/orbit`.

Remote parental controls for macOS: a Python parent dashboard and a privileged Swift agent that terminates blocked signed applications. Foreground monitoring supports usage history, schedules, quotas and temporary allowances. Chrome and Safari WebExtension integration is **experimental**.

## Default testing — VPS

Both `python3 tools/dev.py all` and `bash dev/start.sh` connect to `https://orbit.side-forge.com` by default. Edit the private, Git-ignored `.dev/vps.json` to configure `serverURL`, `adminToken`, `deviceToken`, and `activityToken`. The admin token is only for the dashboard; the other two must match the corresponding VPS credentials. Run `python3 tools/dev.py configure` to enter device/activity tokens without echoing them. VPS testing uses separate `.dev/vps/` state and starts no local server. Ctrl-C stops the blocker and tracker. The Python command defaults to dry-run; the shell command enforces blocks for the current user. This mode does not install a privileged daemon or browser extensions.

## Quick start — isolated local Mac testing

**Default mode enforces real blocks.** If Roblox is blocked in the dashboard, the root daemon can terminate it. Use a dedicated test Mac or account. Administrator authentication is required.

Prerequisites: macOS, Python 3.9+, Node.js, Xcode Command Line Tools, and `mkcert`:

```bash
brew install mkcert
mkcert -install
git clone https://github.com/amperie/orbit.git
cd orbit
bash dev/start.sh --local
```

The launcher starts an HTTPS server at **https://localhost:18443/**, creates a private SQLite database and random development credentials, starts the foreground monitor, and installs the privileged daemon for actual app blocking. The terminal prints a clickable login link that signs you in automatically. It does not replace an existing Orbit daemon.

```bash
bash dev/start.sh --local --no-enforce  # No root daemon; test dashboard/monitor only
bash dev/start.sh --help        # Show startup usage
bash dev/test.sh                # Run Python, JavaScript and macOS Swift checks
bash dev/browsers.sh            # Prepare local Chrome extension and Safari Xcode project
bash dev/stop.sh                # Stop local processes, uninstall and verify dev daemon
```

**Ctrl-C or normal script exit calls `dev/stop.sh` automatically.** Only a daemon tagged as belonging to the development session can be uninstalled. The stop script refuses to remove a pre-existing or unowned daemon and reports if cleanup is incomplete. A forced shutdown, crash, power loss, or lost sudo authorization can prevent automatic cleanup; run `bash dev/stop.sh` to recover. It requires administrator authorization to remove the root daemon. Development credentials and builds live in the Git-ignored `.orbit-dev/` directory.

### Browser setup for local testing

Chrome: run `bash dev/browsers.sh`, open `chrome://extensions`, enable Developer Mode, click **Load unpacked**, and select `.orbit-dev/chrome-extension`.

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
| Chrome extension filtering | Experimental | Installer prepares system force-install profile; approval and published Web Store ID required |
| Safari WebExtension | Experimental | Xcode signing, enabling, real Safari verification required |
| Browser protection health | Reports unverified | No authenticated extension attestation |
| VPS deployment and auto-updates | Not automated | Requires separate deployment |

### Security limitations

Usage history is retained for 90 local calendar days by default; set `ORBIT_RETENTION_DAYS` (1–3650) to change it. Pruning runs on server startup and incoming telemetry. The dashboard shows app and website totals by day and Monday-start week. Website tracking stores domain names, not URLs, and is approximate. Browser extension permissions include tabs and idle; actual Safari compatibility remains unverified.

The foreground monitor is owned by the logged-in user; its activity reports are not tamper-resistant. The daemon uses code-signing identifiers to find apps and sends SIGKILL; unsaved application data may be lost. A standard child account and private administrator password are strongly recommended. Browser extensions can be disabled or bypassed through unapproved browsers unless additional management is deployed. Do not rely on this software as fully bypass-resistant parental control until testing on the target Mac is complete.

## Deploying the server to a VPS

See [deploy/README.md](deploy/README.md) for first-install commands and GitHub Actions automation, including database backup and failed-release rollback.

Run `server/server.py` behind an HTTPS reverse proxy bound to `127.0.0.1`, with a persistent SQLite database. Set four distinct random bearer tokens of at least 32 characters: `ORBIT_ADMIN_TOKEN`, `ORBIT_DEVICE_TOKEN`, `ORBIT_ACTIVITY_TOKEN`, and `ORBIT_BROWSER_TOKEN`. Do not expose the Python server directly to the Internet. See `deploy/orbit.service` for the systemd service and `browser/README.md` for extension provisioning.

## Installing on the target Mac

Download **Orbit-Installer.zip** from [repository Releases](https://github.com/amperie/orbit/releases), extract the whole bundle, and open **Install Orbit.command** while logged into the target user's desktop. It prompts for device/activity tokens and administrator authorization, installs both components, and starts them. No developer tools are needed on the target Mac. Supports macOS 13+, Intel and Apple Silicon. The basic package is unsigned/not notarized, so macOS may require explicit approval. Browser extensions are separate. GitHub's **Build Mac installer** workflow publishes a download after successful main-branch macOS CI, or can be run manually. To build locally: `bash packaging/build.sh`. Installer details are in `packaging/README.txt`.

### Source installation (alternative)

To uninstall the package or source installation, open **Uninstall Orbit.command** in the installer download. It requests administrator authorization, removes services for all local users, and offers to keep or delete local settings and cached data. VPS history remains. Chrome profile removal is attempted automatically; if macOS refuses, follow the Device Management cleanup prompt. Restart Chrome and remove the extension if it remains. Safari is unchanged. New installations also include `/usr/local/libexec/orbit-uninstall --prompt`.

The agent and foreground monitor default to `https://orbit.side-forge.com` when `serverURL` is omitted. Create `agent/settings.json` containing `deviceToken`, then run `sudo bash agent/install.sh`. For foreground telemetry, create `agent/monitor-settings.json` with `activityToken`, then run `bash agent/install-monitor.sh` as the logged-in user. Both files may specify `serverURL` to override the default. Use the corresponding production tokens from the VPS; local development tokens will not authenticate. These **production install scripts persist**; unlike the local development launcher, they are not automatically uninstalled.

See `browser/README.md` for managed Chrome installation and Safari signing requirements. Neither extension has been verified on the target Mac.

## Development

Source: `agent/` (Swift daemon and monitor), `server/` (Python control plane and dashboard), `browser/` (WebExtensions), `dev/` (local launch/cleanup/testing), `tests/` (regression suite), `.github/workflows/` (macOS CI).

The project is currently intended for a single Mac and parent. Offline policy caching, server-anchored time, and stale-quota fail-closed behavior are implemented, but real-device integration and security testing remain necessary.

## Run locally from an IDE

This rootless workflow starts the app blocker and foreground app time tracker against the VPS by default. Add `--local` to start an isolated dashboard as well. Browser extensions require separate setup.


Requires macOS, Python 3, and Xcode Command Line Tools. No sudo, installation, VPS, or additional Python packages are needed.

Run this from the project root, or create an IDE Python run configuration for `tools/dev.py` with argument `all`:

```sh
python3 tools/dev.py all
```

Open the clickable VPS login link printed in the IDE terminal. The agent polls every three seconds and starts in **dry-run mode**: it logs `Would stop …` instead of killing apps. Ctrl+C stops the blocker and tracker. If either exits unexpectedly, the launcher stops the other too. App usage appears in Monitoring after about 30 seconds. For a fully local test use `python3 tools/dev.py all --local`, with a dashboard at **http://127.0.0.1:8765**.

For actual app termination on your development Mac:

```sh
python3 tools/dev.py all --enforce
```

Development enforcement is limited to processes owned by your current user. Do not run development commands with sudo. The dashboard shows `dev-dry-run` or `dev-enforce` in the agent version.

### VS Code

Open this folder and use **Terminal → Run Task → Orbit: run whole system (dry run)**. There are also tasks for enforcement and the test app. These tasks need no debugger extensions.

For breakpoints, install the recommended Python Debugger and CodeLLDB extensions, then select **Orbit: website + agent (dry run)** in Run and Debug and press F5. The compound configuration starts both debuggers; stop ends both. Select the enforce compound to actually kill blocked apps. Set Python breakpoints in `server/server.py` and Swift breakpoints in `agent/main.swift`.

### Xcode or another IDE

Open `Package.swift` in Xcode to debug the native agent. Run `python3 tools/dev.py setup` once, then edit the executable scheme's Run arguments:

```text
--dev --state-dir /absolute/path/to/Orbit/.dev/agent
```

Add `--enforce` only when you want real termination. Launch the website separately with `python3 tools/dev.py server --local` (from the IDE terminal or a Python run configuration). For other IDEs, use that same server entry point; build the native debug executable with `python3 tools/dev.py build` and debug `.dev/vps/orbit-agent` with the arguments above. The Swift package and direct build compile the same source.

### Test without blocking your browser

With the system running, start a second terminal or use the IDE task:

```sh
python3 tools/dev.py fixture
```

On the website add **Orbit Test App** with identifier **org.orbit.debug.fixture**, switch it to blocked, and save. Dry run logs a match and leaves it running; enforcement stops it within the polling/scan interval. Run the fixture again to test repeated launches.

Stop only the website while leaving the agent running to test an outage. Restart the agent while the website remains stopped to verify cached rules. These can be run independently:

```sh
python3 tools/dev.py server --local
python3 tools/dev.py agent --local --enforce
```

All local credentials, database, settings, build output, and cached policy live in ignored `.dev/`, separate from production. State persists between runs; delete `.dev/` while everything is stopped to reset it. Use `--state-dir /another/local/directory` consistently on all commands for a second isolated environment. Choose a port with `--port 8766` on first setup; subsequent launches reuse it. Development permits HTTP only on loopback; production still requires HTTPS and root.

The dashboard shows a Mac connections box above all tabs, grouped by reported
hostname, with each Mac's last server-received check-in time. It refreshes every
15 seconds without changing unsaved policy edits. Agents must be updated to send
hostnames; older agents share an Unknown Mac row. Connection records are separate
by host; policies, quotas and activity accounting remain shared. Deploy the server
update before installing the updated agents.

Mac agents normally check for policy updates and report their connection every
60 seconds. When daily limits are enabled, they check every 30 seconds. Network
request time adds to these intervals; app enforcement continues every two seconds.

Signed automatic agent/monitor updates are implemented on the updater branch.
They require a manually enrolled signing public key and an accessible signed
release feed; builds without a key keep automatic installation disabled. See
[updater/README.md](updater/README.md) for setup, recovery, and real-Mac tests.
