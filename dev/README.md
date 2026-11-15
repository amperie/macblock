# Local MacBlock testing

Requirements: macOS, Python 3.9+, Node.js, Xcode Command Line Tools, and mkcert (`brew install mkcert && mkcert -install`). Full Xcode is required for Safari conversion and signing.

Run `bash dev/start.sh` to launch the localhost HTTPS server, isolated SQLite database, and (if no existing monitor settings are present) a foreground monitor. Dashboard: `https://localhost:18443/`. The parent token prints in the terminal. Stop with Ctrl-C.

Run `bash dev/test.sh` for tests. Run `bash dev/browsers.sh` to create `.macblock-dev/chrome-extension`; open `chrome://extensions`, enable Developer mode, click **Load unpacked**, and choose that folder. The script also generates a Safari Xcode project if the converter is available. Open it in Xcode, choose a signing team, build/run the containing app, and manually enable the extension in Safari Settings. Scripts cannot silently grant browser extension permissions.

For real Roblox termination, use `bash dev/start.sh --enforce`. This explicitly confirms, invokes sudo, and installs the root daemon against local HTTPS. **The daemon remains installed after the dev server stops.** To stop it: `sudo launchctl bootout system/com.macblock.agent`. Never run this on a production Mac. The launcher refuses to overwrite existing `agent/settings.json` and does not overwrite an existing user's monitor settings.

The `.macblock-dev/` directory contains private test credentials and must never be committed. Safari and Chrome still require interactive verification. Browser dev builds embed a read-only token and must not be distributed.
