# Browser enforcement deployment notes

## Chrome
The shared WebExtension is in `browser/chrome`. It requests a read-only
browser token, not the parent or daemon token. Configure the server with a
**fourth** independent environment variable `MACBLOCK_BROWSER_TOKEN`
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
