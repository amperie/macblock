Orbit basic installer — macOS 13 or later, Intel or Apple Silicon

1. Log into the Mac account whose foreground app usage should be tracked.
2. Extract the whole ZIP. Keep all four files together.
3. Open Install Orbit.command. It prompts privately for the VPS DEVICE and
   ACTIVITY tokens, then requests an administrator username/password through
   macOS. A standard user can authorize with a separate administrator account.
4. Open https://orbit.side-forge.com and sign in with your ADMIN token.
   Confirm the blocker and monitor connect; test Roblox blocking and a reboot.

No Git, Python, Xcode or compiler is needed on the target Mac. The package
contains no credentials. Credentials are stored privately on the installed Mac.
The blocking daemon runs system-wide; tracking runs only for the chosen user.
Re-run the setup launcher to update binaries and provision credentials again.

This initial release is NOT Apple Developer signed or notarized. macOS may
block the launcher/package. If you trust the download, use the relevant
Privacy & Security approval in System Settings. Do not disable Gatekeeper.
An organization-managed Mac may prohibit unsigned software entirely.

Opening Orbit.pkg directly only installs files. Use Install Orbit.command to
configure credentials and start services. Closing the installer does not stop
the installed services; they persist across reboots and logins.

The package does not install Safari or Chrome extensions, auto-update the Mac,
or make the user-owned tracker tamper-resistant.

Troubleshooting:
  sudo launchctl print system/com.side-forge.orbit.agent
  launchctl print gui/$(id -u)/com.side-forge.orbit.foreground
  sudo tail -n 50 /var/log/orbit.log
