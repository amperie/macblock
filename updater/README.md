# Signed Mac updates

Automatic updates replace **only the agent and bundled foreground monitor**.
The updater, installers, launchd definitions, settings, credentials, and browser
extensions are not downloaded or rewritten by an automatic update.

The installer includes an hourly root LaunchDaemon. It is loaded only when an
administrator has provisioned a pinned Ed25519 public key. Builds without a key
leave automatic installation disabled. One manual installation is necessary.
This feature needs the real-Mac acceptance checks below before broad rollout.

## Release signing and first enrollment

On a trusted Mac, compile the signing helper and generate a private key **outside
this repository**, in a protected directory. The command prints the public key:

```bash
swiftc updater/Sign.swift -o /tmp/orbit-sign
/tmp/orbit-sign --generate-key /YOUR/PRIVATE/DIRECTORY/orbit-update-key
```

Keep an offline backup of the private key. Never commit it. In GitHub repository
settings add:

* Actions **variable** `ORBIT_UPDATE_PUBLIC_KEY`: the printed base64 public key.
* Actions **secret** `ORBIT_UPDATE_PRIVATE_KEY`: the base64 file contents.

The existing installer workflow passes its monotonically increasing run number
as `ORBIT_UPDATE_SEQUENCE`, signs the manifest, and publishes binaries under the
commit-specific release. The `agent-updates` release holds the rolling manifest
and detached signature. A transient mismatch while the two feed assets are being
published is rejected and retried on the next check. Failed sequences are not
retried automatically after rollback; publish a higher sequence with the fix.
Never reset sequence numbering without a reviewed migration of the persisted
anti-rollback state (for example, after recreating the workflow).

**The update feed and binaries must be publicly downloadable over HTTPS.** A
private GitHub repository's release assets will not work without another public
update host. The updater deliberately has no GitHub token. For another host set
`ORBIT_UPDATE_MANIFEST_URL` while building and publish the manifest/signature at
that URL and `<URL>.sig`; its artifact URLs must point to accessible binaries.
The supplied Actions publication step targets GitHub Releases.

After the key is configured, use the Actions-built installer for the first Mac.
A local enrolled build requires both the public key and a positive sequence:

```bash
ORBIT_UPDATE_PUBLIC_KEY=YOUR_BASE64_PUBLIC_KEY ORBIT_UPDATE_SEQUENCE=100 \
  bash packaging/build.sh 1.2.100
```

Use the real release sequence, not an arbitrarily high number: that is the
minimum release accepted by that installer. Run **Install Orbit.command**.
Existing enabled configurations preserve their feed and pinned key through
manual reinstalls. Changing a feed/key requires deliberate administrator action.
If a previous build created a disabled configuration, enable the new bootstrap
configuration explicitly after installing a correctly keyed package:

```bash
sudo cp /usr/local/share/orbit/update-bootstrap.json \
  '/Library/Application Support/OrbitUpdates/config.json'
sudo chmod 600 '/Library/Application Support/OrbitUpdates/config.json'
sudo /usr/local/libexec/orbit-updater --setup
sudo launchctl bootstrap system /Library/LaunchDaemons/com.side-forge.orbit.updater.plist
```

## Installation and recovery

* Downloads use bounded HTTPS-only requests, including redirects. The manifest
  is at most 16 KiB and each binary at most 20 MB.
* The pinned key verifies the exact manifest bytes before any manifest field is
  trusted. Each download must match its signed size and SHA-256 digest; both
  universal binaries must pass code-signature and architecture checks.
* No archive is extracted and no release-provided command or path is executed.
  Only the two fixed binary destinations are replaceable.
* Root-owned private staging, a lock, same-filesystem atomic replacements,
  synced backups, and a durable journal protect installation. On the next run
  after an interrupted update, recovery happens **before** any network access.
* A new agent must successfully upload status and each previously running,
  bundled monitor must successfully upload activity within three minutes.
  Receipts must match the new build version, live process ID, and installation
  start time. User-session monitor receipts are operational checks, not
  tamper-proof attestations. Source-installed user-owned monitors are excluded.
* A failed update restores both binaries, restarts their services, and records
  the rejected sequence. If recovery itself fails, the journal remains for retry.
  Logged-out monitors use the installed binary on their next login.
* The updater does not update itself. Updating its trust model or service layout
  requires a manual installer. Manual installation and uninstall first stop the
  updater and recover an unfinished transaction.

Logs: `/var/log/orbit-updater.log`. State and recovery data:
`/Library/Application Support/OrbitUpdates`. Uninstall removes the updater
service and executable but preserves this trust/anti-rollback state. It must not
be erased casually during reinstall or rollback.

To disable checks, stop the service and change `enabled` to `false` in the
root-owned `config.json`. To check now, run
`sudo /usr/local/libexec/orbit-updater --once`. A restart of the Mac is not
normally required. Automatic updates do not prompt for existing Orbit tokens.

## Required real-Mac acceptance tests

Before enabling your daughter's Mac, test on an administrator-controlled Mac:

1. Install a keyed release; publish a higher sequence; confirm status/activity
   uploads, process versions, and preserved credentials after automatic update.
2. Publish tampered manifest/signature/binary, wrong size, and lower sequence;
   verify that running binaries are unchanged.
3. Cut networking during download and during health checks. Confirm that a
   partial download cannot install and a failed health check restores the old pair.
4. Interrupt after the first replacement, reboot, and verify recovery runs from
   the journal before fetching any feed. Also interrupt after the commit marker.
5. Exercise monitor logout/login, multiple GUI users, unavailable VPS, failed
   service startup, full disk, manual reinstall, and uninstall during an update.
6. Confirm initial rollback and a higher-sequence corrected release both work.

Offline tests cover real signature verification, digests, rollback ordering,
partial recovery failures, anti-rollback decisions, filesystem checks, and root
requirements. They cannot establish launchd/reboot/power-loss correctness; the
above acceptance tests remain necessary.
