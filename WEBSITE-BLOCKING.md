> Original design proposal. The current experimental WebExtension implementation and setup are documented in [browser/README.md](browser/README.md). Chrome managed URLBlocklist delivery described here remains a proposal.

# Website blocking design

Orbit will block new HTTP and HTTPS navigations to selected domains in Safari and Google Chrome. The dashboard on the existing Linux VPS remains the place to edit the list. The Mac enforces the last known policy locally, including when the VPS is unreachable. The initial scope is the daughter's standard macOS account on one Mac. A Chrome machine policy may also apply to other accounts on that Mac.

## Browser enforcement

| Browser | Proposed enforcement | What the prototype must prove |
| --- | --- | --- |
| Chrome | Mandatory `URLBlocklist` through macOS Managed Preferences. The agent compiles each domain to one bare host entry, which Chromium documents as matching the host and its subdomains. | Verify that a root-owned local managed preference is recognized as mandatory, that a running Chrome picks up additions and removals automatically, and that the same list applies in regular, Incognito, and Guest sessions. |
| Safari | A packaged Safari Web Extension using `declarativeNetRequest` dynamic `block` rules for `main_frame`. The extension applies the Mac's latest local list and reads back the dynamic rules. Safari documents that these rules persist between browser sessions. | Verify direct navigation, private browsing, Safari profiles, rule updates with Safari already open, and whether any Safari UI bypasses the rules. A standard user can potentially disable an unmanaged extension, so this mode is labeled user-disableable. |

### Chrome policy delivery

Use a harmless test domain in a disposable standard account. First establish a baseline with a Google-style configuration profile and verify the effective `URLBlocklist` at `chrome://policy`. Then test agent writes to `/Library/Managed Preferences/com.google.Chrome.plist` as a separate delivery mechanism. Observe policy level and scope, automatic refresh latency, and real navigation for additions and removals. A manual click on **Reload policies** is useful for diagnosis. The automation test passes only when the running browser picks up both changes on its own.

If local writes fail, use MDM to deliver the Chrome configuration profile. Modern macOS requires user interaction to complete a manual profile installation, so generating a new `.mobileconfig` per update would leave a manual step. If a pre-existing management source controls `URLBlocklist` or provides conflicting allowlist rules, surface the conflict and use that management source. Preserve unrelated Chrome policies. Uninstall should remove only policy owned by Orbit and should verify that Chrome picks up the removal.

Chromium documents dynamic refresh for `URLBlocklist` and limitations around in-page JavaScript, dynamic requests, and History API changes. The initial product guarantee is new top-level navigation. Existing pages may keep displaying or running until the next navigation or reload.

References: [Google macOS policy setup](https://support.google.com/chrome/a/answer/9020077?hl=en), [Chromium policy definition](https://chromium.googlesource.com/chromium/src/components/policy/+/ed128c77b3eab98ea94b20a49c06de41f9d87a7d/resources/templates/policy_definitions/Miscellaneous/URLBlocklist.yaml), [Chromium filter syntax](https://www.chromium.org/administrators/url-blocklist-filter-format/), [Apple profile installation changes](https://developer.apple.com/videos/play/wwdc2020/10639/).

### Safari policy delivery

Use a signed macOS app containing the Safari Web Extension. The extension background context requests the current rules from its native handler on startup and on a retry schedule. A containing app running in the login session can notify the extension of changes through Safari's native messaging API if polling alone is too slow. The root daemon remains the source of policy. The prototype should verify that the sandboxed native handler can read a dedicated root-owned, read-only policy snapshot with its chosen entitlement. The snapshot contains only domains and a revision. The daemon's credential and cached full policy remain in private storage. If direct reads fail under signing and sandboxing, prototype a read-only XPC service before choosing the bridge.

Compile rules with a hostname boundary, so `instagram.com` also matches `www.instagram.com` while `instagram.com.example.org` remains allowed. Validate the resulting filter syntax in Safari. Update the previous and next rule sets in one API call, then read back the installed rules. Each Safari profile that participates must catch up when it starts, including after the Mac has been offline. Keep the previous dynamic rules if the snapshot cannot be read or validated.

For protection against the standard user switching the extension off, use Apple’s Safari Extensions declaration on a supervised, MDM-enrolled Mac running macOS 15 or later. Set `State` and `PrivateBrowsing` to `AlwaysOn` for the signed extension in the child user's management scope. Verify any required website permissions, extension availability in new Safari profiles, and actual private-window blocking. The declaration controls extension state. The Orbit daemon still delivers the changing domain list, so each edit does not require an MDM update. Check on the target Mac that the child account cannot remove the management profile. Profile-based Device Enrollment can supervise a Mac running macOS 11 or later, and an MDM service is a separate dependency for this mode.

References: [Safari dynamic rules](https://developer.apple.com/documentation/safariservices/blocking-content-with-your-safari-web-extension), [Safari native messaging](https://developer.apple.com/documentation/safariservices/messaging-between-the-app-and-javascript-in-a-safari-web-extension), [Apple sandbox file entitlements](https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/AppSandboxTemporaryExceptionEntitlements.html), [Safari extension management declaration](https://developer.apple.com/documentation/devicemanagement/safariextensionsettings), [Mac Device Enrollment](https://support.apple.com/guide/deployment/device-enrollment-and-device-management-depd1c27dfe6/1/web/1.0).

## Policy and status

- Add optional `blockedDomains` to the existing revisioned policy. Treat a missing field in a legacy policy as an empty list on the agent. Preserve stored domains when an older dashboard saves an app-only payload. An explicit empty array clears the list. Keep the existing revision check and JSON size limit. Older agents can continue app blocking, and the dashboard should show that they lack browser support.
- Accept domain names in the dashboard, normalize to lowercase ASCII, remove a single terminal dot, and deduplicate. Validate on the VPS and again on the Mac. Initially cap the list at 100 entries and accept internationalized names in their ASCII Punycode form. Reject IP addresses, URLs, wildcard input, and malformed DNS labels. Presets can add `instagram.com`, `tiktok.com`, and `roblox.com`. Add alternate domains explicitly as needed.
- Keep the 120-second agent polling interval. Validate and atomically cache a new revision before staging it for browsers. Reconcile both browsers independently and retry failed applications, including after restarts and when the relevant browser or profile becomes available. The last successfully installed rules continue to apply during a sync outage. A higher revision can restore a previous domain list.
- Report desired revision, cached revision, and a separate result per browser. A file write is **Staged**. A matching browser rule readback can be **Loaded**. A Safari extension that has checked in without management is **Loaded · user-disableable**. If Chrome has no reliable unattended readback, report **Staged** and provide the manual check at `chrome://policy`. An acknowledgement is scoped to the profile or policy source actually checked. Surface stale status and local errors without collecting browsing history or visited URLs.
- Keep app restrictions for Opera and Roblox independent. Coverage applies to the supported browsers and the selected domains. Alternate browsers, web proxies on other domains, embedded resources, and native app traffic are outside the initial website-blocking scope. Browser rules evaluate the requested URL, so ordinary DoH or VPN routing should leave direct navigation blocking intact.

## Build order and acceptance checks

1. **Chrome spike.** Prove automatic add and remove while the browser is running. Compare elapsed time with the two-minute agent poll and record the additional browser refresh time. Verify machine-policy scope with the standard account and a separate administrator account.
2. **Safari spike.** Load one dynamic rule, prove sandboxed policy read and rule readback, then exercise extension settings and private browsing. If the extension can be turned off, verify the supervised configuration before offering a locked mode.
3. **Wire the dashboard and daemon.** Use one server revision and show progress per browser. Test updating apps from an older dashboard, clearing the domain list, and resuming after a failure between caching and browser application.

| Check on the target Mac | Expected result |
| --- | --- |
| Visit a listed domain over HTTP and HTTPS, a subdomain, and a lookalike | The domain and subdomain are blocked. The lookalike opens. Test explicit ports, redirects, and terminal-dot URLs for hostname handling. |
| Add then remove a rule with both browsers running | A new navigation blocks after the browser loads the addition and works again after removal. Record what happens to an already open tab and when it reloads. |
| Try private browsing, Chrome Guest, and a new Safari profile | The listed domain blocks in every supported mode. Disable or mark any mode with a verified bypass before treating it as protected. |
| Try Secure DNS and a VPN. Reboot with the VPS unreachable, then serve an invalid policy response. | Direct navigation still blocks in the supported modes. Previously loaded rules survive failure and reboot. With all external networking disconnected, verify persistence by browser readback or against a local test site. |
| Attempt to disable Safari protection or change managed Chrome policy from the child account | Chrome policy remains mandatory. For Safari, record whether the extension, its website access, or MDM enrollment can be changed. Test per-site settings and any available reload-without-blockers control. |
| Revert the test configuration | Orbit rules are removed, and unrelated browser settings still work. |
