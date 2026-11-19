# Browser enforcement deployment notes

## Chrome
The shared WebExtension is in `browser/chrome`. It requests a read-only
browser token, not the parent or daemon token. Configure the server with a
**fourth** independent environment variable `ORBIT_BROWSER_TOKEN`
(32+ characters). The extension polls `/api/browser/domains` every minute,
and keeps the previous rules if a fetch fails.

To make the extension non-removable, publish it with a stable extension ID
and configure Chrome Enterprise `ExtensionSettings` with
`installation_mode=force_installed` and its real update URL using a
device-management profile. An unpacked developer extension is **not**
protected. Chrome managed extension configuration must supply
`serverURL` and `browserToken`; verify those values in
`chrome://policy` and confirm the extension has installed blocking rules.
Do not invent an extension ID or update URL.

## Integrated installer
`bash packaging/build.sh` produces the universal installer and a separate
`Orbit-Chrome-WebStore.zip` upload archive. Publish that archive in the Chrome
Web Store first and record the assigned extension ID. No publication or developer
account is provisioned by the build. Self-hosted force installation on macOS
requires MDM, domain management, or Chrome Enterprise Core enrollment.

Run `Install Orbit.command` on the target desktop. Alongside DEVICE/ACTIVITY
credentials, it requests the distinct BROWSER token and published extension ID.
It generates a private profile and opens it for administrator approval in
System Settings > General > Device Management. The profile explicitly requests
System scope, force-installs the extension across Chrome profiles, disables
Guest mode and Incognito, and supplies credentials through the separate
`com.google.Chrome.extensions.EXTENSION_ID` managed preference domain.
Profile generation alone does not activate protection. Restart Chrome, verify
machine policy in `chrome://policy`, and test blocking in existing and new
profiles. Test with the target user's standard account and after reboot.

`Uninstall Orbit.command` attempts to remove only Orbit's configuration profile
with administrator authorization, including legacy user-scoped profiles. It verifies
profile absence after removal. If removal fails or cannot be confirmed,
it opens Device Management for manual cleanup. MDM-controlled profiles must be
removed by MDM. Restart Chrome after removal and remove Orbit through
`chrome://extensions` if it remains. The uninstaller never edits Chrome profile
databases, deletes browsing data, or rewrites unrelated Chrome policies.

## Safari
Run `bash browser/safari/build-project.sh` on a Mac with Xcode. Sign the
generated containing app and extension using an Apple developer identity,
install the app, then enable the extension for the required Safari profiles.
The WebExtension engine is shared, but **Safari support for the managed
extension configuration and runtime APIs must be validated on a real Mac**.
Safari extensions can be disabled in Settings. Packaging the extension
does not automatically enable it or make it non-removable.

## Security and fail-closed limitations
A root daemon cannot reliably infer that Safari's extension is active merely
because the app is installed. A user can disable an unmanaged extension.
There is no authenticated health channel from either browser to the daemon
in this implementation. **Do not enable automatic killing of Safari or Chrome
on the basis of a missing extension file or an unauthenticated heartbeat**:
that would be unreliable and trivially spoofed.

The server's blockedDomains list is now exposed through a dedicated,
read-only bearer token. That token is visible to the logged-in browser user,
so it must never authorize policy edits. Changing the Mac's DNS or time zone
does not bypass declarative URL rules when the extension is active, but
alternate browsers, extension removal, browser profiles, and unfiltered
applications remain bypasses.

For robust enforcement, use supervised device management and verify actual
Safari/Chrome policy state on the target Mac. If tamper resistance is mandatory,
a properly entitled, signed system network content filter is the stronger
fallback, not a hosts-file rule.

## Installer usage (on target Mac)

After publishing the Chrome extension and obtaining its real extension ID and
update URL, configure `ORBIT_BROWSER_TOKEN` on the VPS and run:

```bash
sudo bash browser/install-browsers.sh \
  --chrome-id ACTUAL_32_CHARACTER_EXTENSION_ID \
  --chrome-update-url https://your-extension-update-server/update.xml \
  --server-url https://your-orbit-server \
  --browser-token YOUR_DISTINCT_READ_ONLY_BROWSER_TOKEN \
  --safari-pkg /path/to/your-signed-safari-containing-app.pkg
```

The Safari package option is optional. The script checks package signing and
installs the supplied package, but does not build or sign one. The generated
Chrome configuration profile must be approved through System Settings or MDM;
generating a profile does not install it. Run
`bash browser/check-browsers.sh ACTUAL_32_CHARACTER_EXTENSION_ID` for
diagnostics, then verify a blocked website in each browser.

The extension ID, update URL, signed Safari package, and any required Apple
signing credentials are not in this repository. Without these, a complete
automatic installation is impossible. The current Safari implementation also
needs an actual Safari-managed-settings compatibility test before deployment.

## Website usage telemetry (experimental)

The browser extension samples the foreground tab hostname approximately once
per minute while the browser window is focused and the user is not idle.
It sends `{clientId,domain}` to the authenticated `/api/browser/activity`
endpoint; no full URLs, titles, paths, or query strings are transmitted.
Each browser installation has its own random client ID. The server estimates
elapsed seconds between consecutive observations, caps gaps at 90 seconds,
and aggregates by the parent-selected time zone. The parent dashboard exposes
daily and Monday-start weekly totals via `/api/admin/usage`.

This is **not precise per-site screen time**: quick visits may be missed,
idle/focus transitions can overcount up to the next observation, and Safari
API compatibility is not yet validated. The extension requires `tabs` and
`idle` permissions, which must be reviewed when installing/updating it.
Website usage requires the extension to be enabled; the Mac daemon cannot
supply per-site activity on its own. Default retention is 90 calendar days,
configurable with `ORBIT_RETENTION_DAYS`.
