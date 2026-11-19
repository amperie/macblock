# Orbit

Orbit is a remote parental-control system for macOS. A Linux VPS hosts the parent dashboard and policy API; a privileged Mac agent blocks selected applications, and a separate user-session monitor reports foreground application activity. A browser extension adds website blocking and approximate website usage reports.

**Core features are implemented, but implementation is not proof that a target Mac is correctly configured.** Verify app blocking, monitoring, and browser filtering separately after installation. Safari deployment and automatic-update recovery still need real-Mac integration testing. Orbit is not a fully tamper-resistant parental-control product.

Repository: [amperie/orbit](https://github.com/amperie/orbit). Service namespace: `com.side-forge.orbit`. Default server: `https://orbit.side-forge.com`.

## Features and current status

| Feature | Status | Behavior and remaining limits |
| --- | --- | --- |
| Parent dashboard and authenticated API | Implemented | Configure application blocks, domains, schedules, daily limits, and temporary allowances over HTTPS. |
| Application blocking | Implemented; verify on each Mac | Root LaunchDaemon scans about every two seconds and terminates matching signed applications. Roblox player and menu-bar helper are presets. |
| Safari application blocking | Implemented | `com.apple.Safari` is explicitly allowed in the app block list; other protected Apple/system apps remain excluded. This closes Safari itself, rather than filtering individual websites. |
| Mac connection box | Implemented | Visible above the dashboard tabs; grouped by reported hostname, with last connection time, recent/offline status, version, and reported errors. Refreshes every 15 seconds without discarding edits. |
| Multiple Mac connections | Partial support | Separate connection records by hostname. **Policies, quotas, and usage accounting remain shared; foreground reports overwrite one shared current-activity record.** Independent per-device management and reliable simultaneous multi-Mac usage totals are not supported. Identical hostnames share a row; older agents share an Unknown Mac record. |
| Foreground application monitoring | Implemented; verify on each Mac | User LaunchAgent reports the foreground app, pauses for idle/sleep/inactive sessions, and queues completed sessions locally during outages. User-owned telemetry is not tamper-resistant. |
| Daily/weekly application history | Implemented | Server estimates foreground time from heartbeats; completed sessions are also shown. Totals are approximate. |
| Global and per-app schedules | Implemented | Uses the parent-selected time zone and server-anchored time. Scheduled apps fail closed when trusted time is unavailable. |
| Daily quotas and temporary allowances | Experimental | Approximate foreground usage; quota-controlled apps fail closed when monitoring/time is unavailable. Temporary allowances do not override an explicit parent block. Shared accounting is unsuitable for independent limits across multiple Macs. |
| Website domain configuration | Implemented | Dashboard stores blocked domains and includes subdomains. Configuration alone does not activate browser enforcement. |
| Chrome website filtering | Experimental deployment | Installer generates a system-wide force-install profile and managed extension settings. Requires a published extension, profile approval, and testing on the target Mac. |
| Chrome profile coverage | Implemented in generated policy; verify on device | System policy targets existing/new Chrome profiles and disables Guest and Incognito. An unpacked developer installation covers only the selected profile and can be disabled. |
| Website usage history | Experimental | Samples the active hostname approximately once per minute while the browser is focused and the user is active. Sends domains, not full URLs or page content. Requires the extension. |
| Safari website filtering | Experimental; compatibility unverified | Shared WebExtension code and Xcode project generation exist. Requires a signed containing app, extension enablement, and real Safari/API compatibility tests. The standard installer does not deploy Safari. |
| Browser protection health | Not verified automatically | A connected agent or installed extension does not prove that browser filtering is active. No authenticated browser-enforcement attestation is implemented. |
| Universal Mac installer and uninstaller | Implemented | macOS 13+, Intel and Apple Silicon. Reuses valid saved settings; requests administrator authorization. Chrome profile approval/removal may require manual action. |
| VPS deployment | Implemented; requires setup | GitHub Actions deploys tested `main` changes when production SSH secrets are configured; failed releases restore the previous server/database snapshot. |
| Installer release publication | Implemented; requires successful CI | Actions builds installers and uploads them to Releases. Latest promotion is restricted to a completed installer for the current `main` commit. Pushing source alone does not guarantee a successful release. |
| Signed Mac automatic updates | Implemented; disabled until enrolled; real-Mac recovery tests pending | Hourly checks, pinned Ed25519 signatures, binary hashes, anti-rollback sequencing, staged installation, health checks, and recovery journal. Updates agent/monitor binaries only, not the updater itself or browser extensions. |
| Apple Developer signing/notarization | Not configured by the default build | Binaries are ad-hoc signed for integrity checks; the installer is not Developer ID signed/notarized. macOS may require explicit approval. |

Automated tests cover validation, server routes/accounting, dashboard behavior, browser rules, foreground tracking, packaging, and updater cryptography/recovery decisions. **End-to-end installation, launchd behavior, browser enforcement, reboot, and power-loss recovery must still be tested on real Macs.** Do not infer live deployment or successful device configuration from this table.

## Configure the VPS

First installation requires Linux with systemd, Python 3.9+, git, sudo, tar, and timezone data. Run from a checkout of the intended commit:

```bash
git clone https://github.com/amperie/orbit.git orbit-vps
cd orbit-vps
sudo bash deploy/install.sh
```

The installer uses localhost port `18765` by default, stores SQLite data under `/var/lib/orbit`, and generates credentials in root-readable `/etc/orbit.env`. Put it behind your existing HTTPS reverse proxy; the installer does not configure DNS, TLS, proxy, or firewall rules. Do not expose the Python port directly to the Internet.

### Credentials and server settings

Use four distinct tokens, each at least 32 characters. Mac clients accept 32–512 printable ASCII characters without spaces. The generated VPS values meet those requirements.

| Setting | Used by | Purpose |
| --- | --- | --- |
| `ORBIT_ADMIN_TOKEN` | Parent dashboard | Read reports and change policy. Never give this token to the child-facing components. |
| `ORBIT_DEVICE_TOKEN` | Root Mac agent | Retrieve policy and submit agent status. |
| `ORBIT_ACTIVITY_TOKEN` | Foreground monitor | Submit application activity; cannot edit policy. |
| `ORBIT_BROWSER_TOKEN` | Browser extension | Read blocked domains and submit website activity; cannot edit policy. Visible to the browser user. |
| `ORBIT_BIND` / `PORT` | Server | Deployment defaults to `127.0.0.1:18765`. |
| `ORBIT_DB` | Server | Deployment uses `/var/lib/orbit/state.sqlite3`. |
| `ORBIT_RETENTION_DAYS` | Server | Usage-history retention; default `90`, supported range `1–3650`. |

Inspect `/etc/orbit.env` only in your private VPS terminal. Do not paste tokens into issues, chat, screenshots, or git. Restart the service after changing server environment settings. Rotating a token also requires updating the corresponding Mac/browser configuration; clients do not discover replacement tokens automatically.

For automatic server deployment, configure the repository's `production` environment with `VPS_HOST`, optional `VPS_PORT`, `VPS_SSH_KEY`, and verified `VPS_KNOWN_HOSTS`. A successful **macOS CI** run for a push to `main` triggers **Deploy VPS**, which also runs Linux checks before activation. The workflow can be dispatched manually on `main`.

See [deploy/README.md](deploy/README.md) for SSH provisioning, proxy examples, backups, rollback, and deployment permissions.

## Install or upgrade a Mac

1. Make the monitored account a standard user and keep administrator credentials private. Log into **that account's desktop** before running setup.
2. Download **Orbit-Installer.zip** from [Releases](https://github.com/amperie/orbit/releases/latest) and extract the entire folder.
3. Open **Install Orbit.command**. On first setup have the DEVICE, ACTIVITY, and BROWSER tokens and the actual published Chrome Web Store extension ID ready. macOS requests administrator authorization; a separate administrator account can authorize a standard user's installation.
4. Approve **Orbit Chrome Browser Policy** in **System Settings → General → Device Management** using administrator credentials. Restart Chrome and inspect `chrome://policy` and `chrome://extensions`.
5. Open the parent dashboard with the ADMIN token. Verify the hostname/last connection time, switch between apps and check Monitoring, test blocking/unblocking, and repeat after reboot/login. Test browser filtering in existing and new Chrome profiles separately.

**Use the launcher, not Orbit.pkg alone.** Opening the package directly only installs files; it does not provision credentials or start all services. No Git, Python, Xcode, or compiler is needed on the target Mac. The default package is not Apple Developer signed/notarized; use macOS's explicit approval process for a trusted download rather than disabling Gatekeeper.

The blocker runs system-wide. Monitoring starts automatically for the selected logged-in user and restarts at login; it is not installed for every local user automatically. Installing Orbit does not by itself activate Safari website filtering.

### Upgrades and saved configuration

Run the new **Install Orbit.command** again to update manually. It reuses format-valid settings for the same server and prompts for missing or invalid values. The privileged DEVICE token stays inside the administrator-authorized helper. Corrupt protected settings or a server mismatch may require review before setup can continue. Format validation does not establish that a saved token still authenticates against the VPS.

| File | Contents / access |
| --- | --- |
| `/Library/Application Support/Orbit/settings.json` | Root-owned `serverURL` and `deviceToken`. |
| `~/Library/Application Support/Orbit/monitor-settings.json` | Selected user's `serverURL` and `activityToken`. |
| `~/Library/Application Support/Orbit/Orbit-Chrome.mobileconfig` | Saved Chrome policy with extension ID, server URL, and browser token; requires approval to activate. |
| `/Library/Application Support/Orbit/policy.json` | Cached agent policy for offline enforcement. |
| `~/Library/Application Support/Orbit/activity-queue.json` | Pending application sessions awaiting upload. |

The launcher defaults to `https://orbit.side-forge.com` on first installation and reuses an existing server URL on upgrades. It does not prompt for a custom URL. For your own server, provision the root settings file above with the desired HTTPS origin and DEVICE token before setup, or use the source installation below. Keep its directory root-owned/private (`0700`) and the settings file root-owned (`0600`). Do not switch servers while reusing an unreviewed policy cache.

### Connection and polling intervals

| Component | Default interval |
| --- | --- |
| Root agent policy fetch and status report | 60 seconds; 30 seconds when daily limits are enabled |
| Application enforcement scan | About 2 seconds |
| Foreground monitor heartbeat | About 15 seconds; pauses foreground accounting after 5 minutes idle |
| Browser policy/website usage sampling | About 1 minute |
| Dashboard connection refresh | 15 seconds; recent connection threshold is 5 minutes |
| Enrolled signed updater | 1 hour, plus launch at startup |

Network requests and scheduling add to these intervals. A root-agent check-in confirms agent communication, not successful foreground monitoring or active browser filtering. Older agents cannot supply hostnames retroactively; update them to get named connection records.

## Configure website filtering

Chrome deployment requires a published extension with its real Web Store ID. The installer supplies the Web Store update URL, server origin, and BROWSER token through a system configuration profile. Approval is mandatory without MDM. Once applied, that policy force-installs the extension, disables Guest/Incognito, and covers Chrome profiles at system scope.

For local development, run `bash dev/browsers.sh`, open `chrome://extensions`, enable Developer Mode, and load `.orbit-dev/chrome-extension`. This installation is removable and profile-specific. It is not the managed production deployment.

Safari requires Xcode project generation, Apple signing, installation of the containing app, and enabling the extension in the required Safari profiles. Shared code exists; Safari configuration/API compatibility is still unverified. Other browsers and applications remain possible bypasses.

See [browser/README.md](browser/README.md) for publishing, managed profiles, diagnostics, Safari setup, and limitations. The public privacy-policy route is `/privacy`; verify it is deployed and accessible without login before entering its URL in the Chrome Web Store.

## Configure signed automatic Mac updates

**Implemented does not mean enabled.** One manual installation of an enrolled installer is required. Builds without a signing public key disable the updater, including across reboot. Validate the updater on an administrator-controlled Mac before enrolling other Macs.

1. On a trusted Mac, compile `updater/Sign.swift` and generate an Ed25519 key **outside the repository**. Keep the private key and an offline backup private; never commit it.
2. Add the base64 public key as the GitHub Actions **variable** `ORBIT_UPDATE_PUBLIC_KEY`, and the base64 private key as the **secret** `ORBIT_UPDATE_PRIVATE_KEY`.
3. Publish a successful `main` installer build. Actions supplies the release sequence, builds the binaries, signs the manifest, and publishes the update feed. Both manifest/signature and binaries must be publicly downloadable over HTTPS; private repository release assets need another public update host.
4. Manually run that enrolled installer on the Mac. Existing enabled installations preserve their pinned key/feed. A previously saved disabled configuration needs the explicit bootstrap-copy/enable steps in [updater/README.md](updater/README.md).
5. Test a higher-sequence release, network failure, failed startup, interrupted installation, reboot, rollback, and uninstall before relying on automatic installation.

The updater verifies pinned Ed25519 signatures, signed sizes/hashes, and increasing release sequences; checks staged bytes again before activation; validates rollback backups; and requires successful uploads plus stable process IDs before committing an update. It preserves Orbit settings and credentials. If recovery fails, it retains the journal for review/retry. Failed release sequences are not retried automatically; publish a corrected higher sequence.

| Updater item | Location / setting |
| --- | --- |
| Root executable | `/Library/PrivilegedHelperTools/orbit-updater` |
| Configuration, anti-rollback state, and recovery journal | `/Library/Application Support/OrbitUpdates/` |
| Bootstrap public-key/feed configuration | `/Library/Application Support/OrbitUpdates/bootstrap/update-bootstrap.json` |
| Service label | `com.side-forge.orbit.updater` |
| Log | `/var/log/orbit-updater.log` |
| Build-time settings | `ORBIT_UPDATE_PUBLIC_KEY`, positive `ORBIT_UPDATE_SEQUENCE`, optional `ORBIT_UPDATE_MANIFEST_URL` |

Only the agent and bundled monitor binaries update automatically. The updater itself, service layout, trust keys, installer, and browser extensions require their own update/deployment process. Chrome Web Store updates are handled by Chrome. **Real-Mac power-loss/launchd recovery remains unverified by unit tests.** Full key generation, enrollment, disabling, legacy recovery, and acceptance procedures are in [updater/README.md](updater/README.md).

## Uninstall

Open **Uninstall Orbit.command** from the installer bundle and authorize with administrator credentials, or run:

```bash
/usr/local/libexec/orbit-uninstall --prompt
```

It stops the updater, recovers a pending update when possible, and removes Orbit's blocker/trackers for local users. Choose whether to retain or delete local credentials, queues, policy cache, and logs. VPS history is not deleted. Updater trust and anti-rollback state are intentionally preserved.

Orbit's Chrome profile removal is attempted and verified. If macOS refuses removal, follow the Device Management prompt; an MDM-controlled profile requires MDM removal. Removing Orbit's policy releases its Guest/Incognito restrictions unless another policy imposes them. Restart Chrome and remove the extension if it remains. Safari removal is separate. An unfinished legacy update may need recovery with the previous updater before uninstall can proceed.

## Diagnose a target Mac

Run the monitor commands from the monitored user's desktop. None of these commands displays stored tokens:

```bash
sudo launchctl print system/com.side-forge.orbit.agent
launchctl print "gui/$(id -u)/com.side-forge.orbit.foreground"
sudo tail -n 50 /var/log/orbit.log
sudo launchctl print system/com.side-forge.orbit.updater
sudo tail -n 50 /var/log/orbit-updater.log
```

| Symptom | Check |
| --- | --- |
| No Mac connection | Correct DEVICE token/server, loaded root service, HTTPS reachability, and agent log. |
| Mac connected but no application activity | ACTIVITY token/server, monitor LaunchAgent in the correct GUI account, active app switching, and `/api/admin/health` monitor status. Agent connectivity alone is insufficient. |
| Unknown Mac | Old agent without hostname reporting; named records require an updated agent. |
| Website remains accessible | Approved system profile, published/installed extension, managed values in `chrome://policy`, and the actual browser/profile being used. |
| No new GitHub installer | Check **macOS CI**, then **Build Mac installer**. The release pipeline must complete; the local ZIP is not pushed with source. |
| No automatic Mac update | Confirm key enrollment, enabled service/configuration, accessible signed feed, release sequence, and updater log. Unsafe writable/symlinked ancestors or corrupt backups/state stop automatic installation. |

## Development and source installation

### Rootless development / IDE

Requires macOS, Python 3.9+, and Xcode Command Line Tools. Node.js is needed for JavaScript tests. Development state is separate from production and ignored by git.

```bash
python3 tools/dev.py configure          # Privately enter VPS credentials
python3 tools/dev.py all                # Default VPS; dry-run blocker + monitor
python3 tools/dev.py all --enforce      # Actually terminate matching apps owned by this user
python3 tools/dev.py all --local        # Isolated HTTP dashboard at 127.0.0.1:8765
python3 tools/dev.py fixture            # Signed test app: org.orbit.debug.fixture
```

Default remote credentials/configuration are in `.dev/vps.json`; remote test state is under `.dev/vps/`. `--local` uses `.dev/` and generated local credentials. The agent polls every three seconds in development. Ctrl-C stops the launched development processes, not a pre-existing production installation. Development allows HTTP only on loopback; production requires HTTPS.

For independent local processes use `python3 tools/dev.py server --local` and `python3 tools/dev.py agent --local --enforce`. With the dashboard open, add **Orbit Test App**, identifier **org.orbit.debug.fixture**, save a block, and launch the fixture again to test repeated enforcement. Dry run logs `Would stop …` without terminating the app.

VS Code tasks/debug configurations and `Package.swift` support IDE use. For Xcode or another native debugger, run `python3 tools/dev.py setup`, then use `--dev --state-dir /absolute/path/to/Orbit/.dev/vps` for the default VPS configuration. Use `.dev` with `--local`. See [dev/README.md](dev/README.md) for the full workflows.

### Isolated HTTPS development with a root daemon

Use a dedicated test Mac/account. This launcher enforces real blocks by default and requests administrator authorization. It will not replace an existing Orbit daemon.

```bash
brew install mkcert
mkcert -install
bash dev/start.sh --local
# Dashboard: https://localhost:18443/
```

Use `bash dev/start.sh --local --no-enforce` for dashboard/monitor-only testing. Ctrl-C or normal exit invokes cleanup. After a crash or forced shutdown, run `bash dev/stop.sh` and verify that the development daemon was removed. Only daemons tagged as belonging to that development session are removed.

### Source installation on a Mac

Requires Xcode Command Line Tools on the target. Create ignored `agent/settings.json`:

```json
{"serverURL":"https://orbit.side-forge.com","deviceToken":"YOUR_DEVICE_TOKEN"}
```

Create ignored `agent/monitor-settings.json` with the same server:

```json
{"serverURL":"https://orbit.side-forge.com","activityToken":"YOUR_ACTIVITY_TOKEN"}
```

```bash
sudo bash agent/install.sh
bash agent/install-monitor.sh
```

Run the monitor installer as the monitored user, without sudo. These production services persist across logout/reboot. Source installation is separate from updater enrollment; user-owned source-installed monitors are not replaced by the signed updater.

### Build and verify

```bash
bash dev/test.sh
bash packaging/build.sh 1.2.4
ORBIT_TEST_PACKAGE="$PWD/dist/Orbit-Installer.zip" python3 -m unittest discover -s tests -p 'test_packaging.py'
```

`dev/test.sh` needs Node.js and the macOS Swift toolchain. Some integration checks require process enumeration/termination and a real GUI session; restricted sandboxes cannot fully validate them. Packaging emits `dist/Orbit-Installer.zip`, its SHA-256 file, a Chrome Web Store upload archive, and updater binary artifacts. Building does not publish anything.

Implementation directories: `agent/`, `server/`, `browser/`, `packaging/`, `updater/`, `deploy/`, `dev/`, and `tests/`. See [deploy/README.md](deploy/README.md), [browser/README.md](browser/README.md), [updater/README.md](updater/README.md), [dev/README.md](dev/README.md), and [packaging/README.txt](packaging/README.txt) for component-specific instructions.
