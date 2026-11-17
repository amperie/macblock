# Orbit testing

## Default: VPS

`bash dev/start.sh` starts the blocker and tracker for your current user against
`https://orbit.side-forge.com`. It starts no local server and installs no daemon.
Use `--no-enforce` for dry-run blocking. Configure the private Git-ignored
`.dev/vps.json`; run `python3 tools/dev.py configure` to enter the VPS's device
and activity tokens with hidden input. The dashboard admin token is separate.
Ctrl-C stops both processes. The equivalent Python command is
`python3 tools/dev.py all --enforce` (omit `--enforce` for dry run).

The rest of this document describes the explicit `--local` workflow.

## Start (real blocking by default)

On macOS install Python 3.9+, Node.js, Xcode Command Line Tools, and a local HTTPS certificate authority:

```bash
brew install mkcert
mkcert -install
bash dev/start.sh --local
```

This launches the local HTTPS dashboard at `https://localhost:18443/`, an isolated SQLite database, foreground monitor, and a **privileged app-blocking daemon**. The parent token prints in the terminal. It can terminate Roblox or any other app you block in the dashboard. Administrator authentication is required. Existing installed Orbit daemon/state is never replaced.

## Commands

```bash
bash dev/start.sh --help        # Print usage
bash dev/start.sh --local --no-enforce  # Start without privileged blocking
bash dev/test.sh                # Python, JavaScript and Swift checks
bash dev/browsers.sh            # Generate Chrome unpacked extension and Safari Xcode project
bash dev/stop.sh                # Stop local services and uninstall owned test daemon
```

**Ctrl-C or normal exit invokes the stop script.** It stops only recorded development processes, checks their command lines before signaling them, and removes the privileged daemon only if a root-owned session marker matches. It verifies daemon removal and reports errors. A crash, power loss or unavailable sudo authorization can leave the daemon installed; run `bash dev/stop.sh` to recover. The script refuses to uninstall pre-existing Orbit installations.

Development artifacts and credentials are stored in Git-ignored `.orbit-dev/`. The script does not automatically uninstall browser extensions or reset browser permissions.

## Browser setup

Chrome: run `bash dev/browsers.sh`, visit `chrome://extensions`, enable Developer Mode, choose **Load unpacked**, and select `.orbit-dev/chrome-extension`. The script cannot approve browser permissions.

Safari: with full Xcode installed, the same command attempts to generate a Safari Web Extension project. Open the generated project, select a signing team, run the containing app and enable the extension in Safari Settings. Signing and activation require interaction and have not been verified on the target Mac.

**The local workflow is for a dedicated test Mac, not a production machine.** Browser filtering is experimental and requires manual verification.
