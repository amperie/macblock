# Orbit for iPhone — first device-test version

Open **`Orbit.xcodeproj`**, select the **Orbit** scheme, and deploy to a physical iPhone running **iOS 17.4 or later** after configuring signing below. The app and its embedded Device Activity Monitor extension build against the installed iOS SDK. Screen Time authorization, blocking, quota callbacks, reboot recovery, and time-zone behavior still require real-device tests.

## What is implemented

- SwiftUI setup/status screen, code-only enrollment and parent unlock, Apple Screen Time authorization, and Apple's app picker.
- Manual shielding and a single **combined daily allowance** for up to 50 explicitly selected apps. Select only Roblox to give Roblox an individual allowance.
- Device Activity Monitor extension to shield selected apps at Apple's threshold callback and reset the quota latch on the next monitored day. Counting stays with iOS; no polling process is used to kill apps.
- Atomic, coordinated App Group storage for policy, private selection tokens, and the quota latch. Tokens and app names are not uploaded.
- Separate iPhone policy/status API with optimistic revision checks. Changing iPhone rules does not change Mac rules.
- HTTPS-only communication, no redirects, bounded request timeouts, and a dedicated device credential stored in Keychain. A short-lived, iPhone-only parent session exists only in memory. The administrator token is never downloaded.
- Sync when the app enters the foreground and a manual Sync button. Cached rules are reconciled before each server fetch, so an interrupted local update can be retried even while offline. Previously installed local rules continue while offline.

## What is not included yet

Background push delivery, guaranteed immediate remote changes, website restrictions, per-app independent budgets, custom shield screens, and usage charts are not included. The web dashboard includes enrollment, revocation, and shared iPhone blocking/allowance controls. Remote rules can be changed in website Settings or through the API below; an unlocked parent session in the phone app can also save policy. This version does not export Screen Time reports or claim to reproduce the Mac telemetry on iOS.

Do not deploy this as the only parental control until the physical-device checklist below passes. Apple authorizations and callbacks cannot be validated by an unsigned build or pure policy tests.

## Xcode signing and capabilities

1. Use an Apple Developer account and select its development team in **both** targets: Orbit and OrbitMonitor.
2. At the project level, set `ORBIT_BUNDLE_PREFIX` to a prefix you own. Bundle IDs become `<prefix>.phone` and `<prefix>.phone.monitor`.
3. Register an App Group you own and set the project's `ORBIT_APP_GROUP` to its exact identifier. Both targets must have that same App Group and the **Family Controls** capability. The Info.plist `OrbitAppGroup` entry and entitlements use this build setting.
4. Connect your iPhone, enable Developer Mode if Xcode asks, choose that device, and run Orbit.
5. For child mode, the child's Apple Account must be in your Family Sharing group and the guardian must approve Apple's authorization sheet. The optional **self-control test** uses individual authorization and can be revoked by the phone owner; it is not child parental control.
6. Apple must approve the Family Controls distribution entitlement for the app and monitor extension before distribution through TestFlight/App Store. A successful unsigned build does not include that approval.

References: [Family Controls configuration](https://developer.apple.com/documentation/xcode/configuring-family-controls), [distribution entitlement](https://developer.apple.com/documentation/familycontrols/requesting-the-family-controls-entitlement), [Device Activity](https://developer.apple.com/documentation/deviceactivity).

## Enable iPhone access on the server

Deploy the updated `server/server.py` using the existing deployment process. Existing databases migrate automatically at server startup. Mac credentials and policy stay unchanged.

### Code-only setup

1. Sign in to the parent website and open **Settings → iPhone setup**.
2. Optionally configure **iPhone blocking and allowance** and click **Save iPhone rules**. These settings are separate from Mac settings.
3. Click **Generate setup code**. Enter the displayed `XXXX-XXXX-XXXX` code in Orbit on the iPhone and tap **Connect iPhone**.
4. Orbit connects to the built-in `https://orbit.side-forge.com` origin, downloads its own device credential and the latest iPhone policy, and saves the connection in Keychain. No URL, device token, or administrator token needs to be entered on the phone. Self-hosted builds can change `PhoneConnection.defaultOrigin` before building.
5. Approve Apple's Screen Time authorization, choose individual apps, and save the selection on the phone. Apple selection tokens cannot be configured from the server.

Codes expire after 10 minutes, work once, and are replaced when another code is generated. Incorrect guesses are limited to 30 per minute across the service. Codes and credentials are stored as SHA-256 hashes on the server. A code also unlocks parent setup on an enrolled phone, using that phone's existing credential. Parent setup expires after up to 14 minutes locally (15 minutes on the server), and locks when Orbit enters the background. Generate another website code to unlock again.

The website lists enrolled phones with their installation ID prefix and reported state. **Revoke access** removes a phone's credential, parent sessions, and server status. Previously downloaded local restrictions remain; revocation is not an uninstall or an unblock command. A fresh website code permits enrollment again.

`ORBIT_IOS_TOKEN` is no longer required for new enrollments. An existing valid value remains supported for older builds during migration; older shared-token installations cannot be revoked individually. Remove that environment value after migrating all phones. No shared or administrator token is returned by enrollment.

A lost enrollment response can consume a code without saving the credential on the phone. Generate another code and retry; revoke any unused enrollment listed on the website. Do not automatically retry a consumed code. The updated backend and dashboard must be deployed before this flow works against the live server.

## Remote policy API

The first version shares one iPhone policy across enrolled phones. Device status is separated by a generated installation UUID. Separate policies per phone remain follow-up work; the web console edits the shared iPhone policy.

| Endpoint | Credential | Purpose |
| --- | --- | --- |
| `GET /api/ios/policy` | Enrolled device credential (or legacy `ORBIT_IOS_TOKEN`) | Retrieve iPhone-only rules |
| `POST /api/ios/status` | Enrolled device credential (or legacy `ORBIT_IOS_TOKEN`) | Report applied local revision, authorization, app count, and configured shield state |
| `POST /api/admin/ios/pair` | Existing admin token | Issue a single-use setup code (body `{}`) |
| `POST /api/ios/enroll` | Setup code in body | Enroll installation UUID; return private device credential, scoped parent session, and policy |
| `POST /api/ios/unlock` | Device credential + setup code | Unlock parent setup with a fresh short-lived session |
| `GET/POST /api/ios/parent/policy` | Scoped parent session | Read/change iPhone policy without administrator access |
| `POST /api/admin/ios/revoke` | Existing admin token | Revoke the supplied `installationID` |
| `GET /api/admin/ios/policy` | Existing admin token | Read current iPhone policy |
| `POST /api/admin/ios/policy` | Existing admin token | Change rules using the current revision |
| `GET /api/admin/ios/state` | Existing admin token | Read iPhone policy and installation reports |

Example policy:

```json
{
  "schemaVersion": 1,
  "revision": 1,
  "blocked": false,
  "dailyMinutes": 60,
  "timeZone": "America/Los_Angeles"
}
```

Fetch the current policy first; send that revision when saving. A successful write increments it; a stale write returns 409. If a save times out or loses its connection, the app makes one read-back request using the parent credential. It treats the save as confirmed only if the server returns a newer revision with exactly the requested rules. It never repeats the write automatically. Conflicting or unconfirmed outcomes preserve the local draft and ask the parent to discard edits and sync before retrying. `dailyMinutes: null` disables the daily allowance. `blocked: true` overrides it. `timeZone` uses the server's supported time zones. Increasing a limit releases a previous lower-threshold latch and re-registers Apple's event with `includesPastActivity: true`; decreasing it preserves an already-exceeded latch. Changing the selected app group causes iOS to evaluate the new selection's past activity.

To test from your own terminal, set `ORBIT_ORIGIN` and `ORBIT_PARENT_TOKEN` privately, then:

```bash
curl --fail --silent --show-error \
  -H "Authorization: Bearer $ORBIT_PARENT_TOKEN" \
  "$ORBIT_ORIGIN/api/admin/ios/policy" > /tmp/orbit-iphone-policy.json
```

Edit that JSON, retain its revision, then:

```bash
curl --fail --silent --show-error \
  -H "Authorization: Bearer $ORBIT_PARENT_TOKEN" \
  -H 'Content-Type: application/json' \
  --data-binary @/tmp/orbit-iphone-policy.json \
  "$ORBIT_ORIGIN/api/admin/ios/policy"
```

Open Orbit on the phone or tap Sync to fetch the change. An installation report's `shieldConfigured` value describes requested local settings, not independent proof that iOS enforced them. `revision` reports the snapshot installed locally, which may differ from the latest server revision after an apply failure. Parent changes remain on the server if device application fails; resolve the displayed device error and sync again.

## Checks

On a Mac with Xcode and an iOS SDK:

```bash
bash ios/check.sh
```

This runs the Foundation policy/connection tests, intercepted HTTP-client tests without network access, in-process server HTTP-dispatch tests with real SQLite, and an unsigned iOS app/extension build. The client tests cover credential routing, private status fields, explicit unlimited budgets, response-size limits, redirects, rejected acknowledgments, and lost-response save recovery without duplicate writes. HTTP replies are capped at 64 KiB as bytes arrive, rather than after buffering an unbounded response. It does not bind a local test server. It does not install or authorize the app on your phone.

## Physical-device acceptance checklist

1. Verify code setup rejects an incorrect, expired, or reused code, and parent unlock resets on backgrounding. Child controls must remain read-only while locked.
2. Authorize child mode using the family's accounts. Choose only Roblox and save.
3. Enable manual blocking and confirm iOS shows its shield when opening Roblox. Disable it and verify access returns.
4. Set a short daily allowance and use Roblox until the threshold fires, including time spent before configuring the limit. Keep Orbit closed during this test.
5. Change limits upward and downward; confirm past usage is retained/re-evaluated rather than reset. Test a manual block while a quota exists.
6. Change policy through the remote API, then foreground Orbit and verify its applied revision in `/api/admin/ios/state`.
7. Turn off networking, reboot, lock/unlock the device, and test the selected apps again. Check the next-day reset and test both phone and policy time-zone changes. Do not assume that compilation establishes these behaviors.
8. Revoke authorization as the guardian and verify the app reports the changed authorization. No behavior in this first version should be represented as tamper-proof.

9. Edit a limit, open/close Control Center without backgrounding the app, and verify the draft remains intact. Rotate the iPhone token on the server and verify parent-authorized credential recovery. During a failed status upload, confirm local rule application is still shown accurately.

Apple controls timing and callback delivery. In particular, threshold/re-registration and daily resets need testing on the actual iOS version being used.
