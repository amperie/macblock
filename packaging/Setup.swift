import Foundation
import Darwin

struct Credentials: Codable {
    let serverURL: String
    let deviceToken: String
    let activityToken: String
    func validate() throws {
        guard let url = URLComponents(string: serverURL), url.scheme == "https",
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, url.path.isEmpty || url.path == "/",
              deviceToken != activityToken,
              [deviceToken, activityToken].allSatisfy({ token in
                  (32...512).contains(token.utf8.count) && token.utf8.allSatisfy { (33...126).contains($0) }
              }) else { throw SetupError.message("Invalid server or tokens. Use distinct device and activity tokens from the VPS.") }
    }
}
// The user-owned monitor must never receive the privileged daemon token.
struct MonitorCredentials: Codable {
    let serverURL: String
    let activityToken: String
    func validate() throws {
        guard let url = URLComponents(string: serverURL), url.scheme == "https",
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, url.path.isEmpty || url.path == "/",
              (32...512).contains(activityToken.utf8.count),
              activityToken.utf8.allSatisfy({ (33...126).contains($0) }) else {
            throw SetupError.message("Invalid monitor server or activity token")
        }
    }
}

func origin(_ value: String) throws -> String {
    guard var url = URLComponents(string: value), url.scheme == "https",
          let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
          url.query == nil, url.fragment == nil, url.path.isEmpty || url.path == "/" else {
        throw SetupError.message("Invalid configured server origin")
    }
    url.host = host.lowercased()
    url.path = ""
    if url.port == 443 { url.port = nil }
    guard let result = url.string else { throw SetupError.message("Invalid configured server origin") }
    return result
}

func checkExistingConfiguration(settings: URL, cache: URL, serverURL: String) throws {
    let fm = FileManager.default
    guard fm.fileExists(atPath: settings.path) else {
        if fm.fileExists(atPath: cache.path) {
            throw SetupError.message("Cached policy has no server settings. Review it before reconfiguration.")
        }
        return
    }
    let data = try Data(contentsOf: settings)
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: String],
          object["deviceToken"] != nil else {
        throw SetupError.message("Existing Orbit settings are invalid; review them before reconfiguration")
    }
    let previous = object["serverURL"] ?? "https://orbit.side-forge.com"
    guard try origin(previous) == origin(serverURL) else {
        throw SetupError.message("This Mac is configured for another server. Review its cached policy before switching servers.")
    }
}

enum SetupError: Error { case message(String) }

@discardableResult
func run(_ executable: String, _ arguments: [String], input: Data? = nil, capture: Bool = false) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let output = Pipe()
    if capture { process.standardOutput = output }
    // Bound input before callers use this helper; credential payloads are tiny.
    let pipe = Pipe()
    if input != nil { process.standardInput = pipe }
    try process.run()
    if let input = input {
        pipe.fileHandleForWriting.write(input)
        try pipe.fileHandleForWriting.close()
    }
    let result = capture ? output.fileHandleForReading.readDataToEndOfFile() : Data()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw SetupError.message("Command failed: \(URL(fileURLWithPath: executable).lastPathComponent) (\(process.terminationStatus))")
    }
    return String(data: result, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

func privateJSON(_ object: [String: String], at path: String) throws {
    let data = try JSONSerialization.data(withJSONObject: object)
    try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
}

func readInputData() throws -> Data {
    var data = Data()
    while true {
        let chunk = FileHandle.standardInput.readData(ofLength: min(4096, 8193 - data.count))
        if chunk.isEmpty { return data }
        data.append(chunk)
        guard data.count <= 8192 else { throw SetupError.message("Credential input too large") }
    }
}

func readInput() throws -> Credentials {
    let credentials = try JSONDecoder().decode(Credentials.self, from: readInputData())
    try credentials.validate()
    return credentials
}

func readMonitorInput() throws -> MonitorCredentials {
    let credentials = try JSONDecoder().decode(MonitorCredentials.self, from: readInputData())
    try credentials.validate()
    return credentials
}

func monitorSetup() throws {
    guard getuid() >= 501, let user = getpwuid(getuid()) else {
        throw SetupError.message("Tracker setup must run as the target user")
    }
    let credentials = try readMonitorInput()
    let home = String(cString: user.pointee.pw_dir)
    let fm = FileManager.default
    let directory = home + "/Library/Application Support/Orbit"
    let agents = home + "/Library/LaunchAgents"
    try fm.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try fm.createDirectory(atPath: agents, withIntermediateDirectories: true)
    try privateJSON(["serverURL": credentials.serverURL, "activityToken": credentials.activityToken],
                    at: directory + "/monitor-settings.json")
    let label = "com.side-forge.orbit.foreground"
    let plist = agents + "/" + label + ".plist"
    let properties: [String: Any] = ["Label": label,
        "ProgramArguments": ["/usr/local/libexec/orbit-foreground"],
        "RunAtLoad": true, "KeepAlive": true, "ThrottleInterval": 15]
    let data = try PropertyListSerialization.data(fromPropertyList: properties, format: .xml, options: 0)
    try data.write(to: URL(fileURLWithPath: plist), options: .atomic)
    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: plist)
    let domain = "gui/\(getuid())"
    if (try? run("/bin/launchctl", ["print", domain + "/" + label], capture: true)) != nil {
        try run("/bin/launchctl", ["bootout", domain + "/" + label])
    }
    try run("/bin/launchctl", ["enable", domain + "/" + label])
    try run("/bin/launchctl", ["bootstrap", domain, plist])
    try run("/bin/launchctl", ["kickstart", domain + "/" + label])
}

func validToken(_ value: String?) -> Bool {
    guard let value = value else { return false }
    return (32...512).contains(value.utf8.count) && value.utf8.allSatisfy { (33...126).contains($0) }
}

func savedDevice() throws -> [String: String] {
    guard getuid() == 0 else { throw SetupError.message("Saved device settings require administrator authorization") }
    let directory = "/Library/Application Support/Orbit"
    for path in [directory, directory + "/settings.json"] {
        var info = stat()
        if lstat(path, &info) != 0 {
            if errno == ENOENT { return [:] }
            throw SetupError.message("Cannot inspect saved device settings")
        }
        let expected = path == directory ? S_IFDIR : S_IFREG
        guard info.st_uid == 0, (info.st_mode & S_IFMT) == expected,
              (info.st_mode & 0o022) == 0, path == directory || info.st_size <= 8192 else {
            throw SetupError.message("Unsafe saved device settings; inspect ownership and permissions")
        }
    }
    let data = try Data(contentsOf: URL(fileURLWithPath: directory + "/settings.json"))
    return (try? JSONSerialization.jsonObject(with: data) as? [String: String]) ?? [:]
}

func deviceMetadata(_ saved: [String: String]) throws -> [String: String] {
    let server = try origin(saved["serverURL"] ?? "https://orbit.side-forge.com")
    // Never expose the privileged DEVICE token to the desktop user.
    return ["serverURL": server, "reuseDevice": validToken(saved["deviceToken"]) ? "true" : "false"]
}

func savedUserSettings(home: String, serverURL: String) -> [String: String] {
    let directory = URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/Orbit")
    var result: [String: String] = [:]
    if let data = try? Data(contentsOf: directory.appendingPathComponent("monitor-settings.json")),
       let monitor = try? JSONDecoder().decode(MonitorCredentials.self, from: data),
       (try? monitor.validate()) != nil,
       (try? origin(monitor.serverURL)) == (try? origin(serverURL)) {
        result["activityToken"] = monitor.activityToken
    }
    if let data = try? Data(contentsOf: directory.appendingPathComponent("Orbit-Chrome.mobileconfig")),
       let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
       let profile = object as? [String: Any],
       profile["PayloadIdentifier"] as? String == "com.side-forge.orbit.chrome.configuration",
       let payloads = profile["PayloadContent"] as? [[String: Any]] {
        for payload in payloads {
            guard let domains = payload["PayloadContent"] as? [String: Any] else { continue }
            for (domain, value) in domains where domain.hasPrefix("com.google.Chrome.extensions.") {
                guard let configuration = value as? [String: Any],
                      let forced = configuration["Forced"] as? [[String: Any]],
                      let settings = forced.first?["mcx_preference_settings"] as? [String: String],
                      let server = settings["serverURL"], let token = settings["browserToken"],
                      (try? origin(server)) == (try? origin(serverURL)), validToken(token) else { continue }
                let id = String(domain.dropFirst("com.google.Chrome.extensions.".count))
                if (try? chromeProfile(extensionID: id, serverURL: server, browserToken: token)) != nil {
                    result["extensionID"] = id
                    result["browserToken"] = token
                }
            }
        }
    }
    return result
}

func prepareInstall() throws {
    guard getuid() == 0 else { throw SetupError.message("Installer preparation requires administrator authorization") }
    let service = "system/com.side-forge.orbit.updater"
    if (try? run("/bin/launchctl", ["print", service], capture: true)) != nil {
        try run("/bin/launchctl", ["bootout", service])
    }
    if FileManager.default.fileExists(atPath: "/Library/PrivilegedHelperTools/orbit-updater") {
        try run("/Library/PrivilegedHelperTools/orbit-updater", ["--recover-only"])
    } else if FileManager.default.fileExists(atPath: "/Library/Application Support/OrbitUpdates/transaction") {
        throw SetupError.message("Pending update from an older updater. Recover it with that version before upgrading or uninstalling.")
    }
}

func startUpdater(command: (String, [String], Bool) throws -> String = { try run($0, $1, capture: $2) }) throws {
    let enabled = try command("/Library/PrivilegedHelperTools/orbit-updater", ["--setup"], true) == "enabled"
    if enabled {
        _ = try command("/bin/launchctl", ["enable", "system/com.side-forge.orbit.updater"], false)
        _ = try command("/bin/launchctl", ["bootstrap", "system", "/Library/LaunchDaemons/com.side-forge.orbit.updater.plist"], false)
        print("Automatic signed updates enabled (hourly checks).")
    } else {
        // Merely omitting bootstrap does not prevent a LaunchDaemon plist from
        // loading at the next reboot. Persist an explicit disabled override.
        _ = try command("/bin/launchctl", ["disable", "system/com.side-forge.orbit.updater"], false)
        print("Automatic updates disabled: no release-signing public key configured.")
    }
}

func configure(_ username: String, reuseDevice: Bool = false) throws {
    guard getuid() == 0, let user = getpwnam(username), user.pointee.pw_uid >= 501 else {
        throw SetupError.message("Configuration requires administrator authorization and a regular target user")
    }
    let uid = user.pointee.pw_uid
    let console = try run("/usr/bin/stat", ["-f", "%Su", "/dev/console"], capture: true)
    guard console == username else { throw SetupError.message("Log into the target user's desktop before installing") }
    let input = try readInputData()
    let supplied = try JSONDecoder().decode(Credentials.self, from: input)
    let credentials: Credentials
    if reuseDevice {
        let saved = try savedDevice()
        guard validToken(saved["deviceToken"]),
              try origin(saved["serverURL"] ?? "https://orbit.side-forge.com") == origin(supplied.serverURL) else {
            throw SetupError.message("Saved device settings changed; restart the installer")
        }
        credentials = Credentials(serverURL: supplied.serverURL, deviceToken: saved["deviceToken"]!, activityToken: supplied.activityToken)
    } else { credentials = supplied }
    try credentials.validate()
    if let fields = try JSONSerialization.jsonObject(with: input) as? [String: String],
       let browser = fields["browserToken"], browser == credentials.deviceToken || browser == credentials.activityToken {
        throw SetupError.message("The BROWSER token must differ from DEVICE and ACTIVITY tokens")
    }
    let directory = "/Library/Application Support/Orbit"
    let fm = FileManager.default
    var status = stat()
    if lstat(directory, &status) == 0 {
        guard status.st_uid == 0, (status.st_mode & S_IFMT) == S_IFDIR,
              (status.st_mode & 0o022) == 0 else {
            throw SetupError.message("Unsafe Orbit settings directory; inspect its ownership and permissions")
        }
    } else {
        try fm.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    let settings = directory + "/settings.json"
    // Refuse stale-policy reuse even if the old settings are missing or corrupt.
    try checkExistingConfiguration(settings: URL(fileURLWithPath: settings),
        cache: URL(fileURLWithPath: directory + "/policy.json"), serverURL: credentials.serverURL)
    try privateJSON(["serverURL": credentials.serverURL, "deviceToken": credentials.deviceToken], at: settings)
    if (try? run("/bin/launchctl", ["print", "system/com.side-forge.orbit.agent"], capture: true)) != nil {
        try run("/bin/launchctl", ["bootout", "system/com.side-forge.orbit.agent"])
    }
    try run("/bin/launchctl", ["enable", "system/com.side-forge.orbit.agent"])
    try run("/bin/launchctl", ["bootstrap", "system", "/Library/LaunchDaemons/com.side-forge.orbit.agent.plist"])
    try run("/bin/launchctl", ["kickstart", "system/com.side-forge.orbit.agent"])
    // Drop privileges before writing anything in the target user's home.
    let data = try JSONEncoder().encode(MonitorCredentials(serverURL: credentials.serverURL, activityToken: credentials.activityToken))
    try run("/bin/launchctl", ["asuser", String(uid), "/usr/bin/sudo", "-H", "-u", username,
        "/usr/local/libexec/orbit-setup", "--monitor-user"], input: data)
    try startUpdater()
}

func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

func stagePackage(_ source: URL, in directory: URL) throws -> URL {
    let fm = FileManager.default
    let source = source.standardizedFileURL.resolvingSymlinksInPath()
    let values = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard values.isRegularFile == true, (values.fileSize ?? 0) > 0 else {
        throw SetupError.message("Orbit.pkg is missing or empty. Extract the entire installer ZIP first.")
    }
    let staged = directory.appendingPathComponent("Orbit.pkg")
    try fm.copyItem(at: source, to: staged)
    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staged.path)
    let expanded = directory.appendingPathComponent("package-check")
    do {
        // Read-only validation, before asking for tokens or administrator access.
        try run("/usr/sbin/pkgutil", ["--expand", staged.path, expanded.path], capture: true)
        try fm.removeItem(at: expanded)
    } catch {
        throw SetupError.message("Orbit.pkg is not a readable installer package. Download the installer ZIP again and extract the entire folder.")
    }
    return staged
}

// Generate in the logged-in user's private directory; the containing profile
// requests System scope, so macOS requires administrator approval to activate it.
func chromeProfile(extensionID: String, serverURL: String, browserToken: String) throws -> Data {
    guard extensionID.utf8.count == 32,
          extensionID.utf8.allSatisfy({ (97...112).contains($0) }),
          (32...512).contains(browserToken.utf8.count),
          browserToken.utf8.allSatisfy({ (33...126).contains($0) }) else {
        throw SetupError.message("Use a real 32-letter Chrome Web Store extension ID and a valid BROWSER token")
    }
    _ = try origin(serverURL)
    func payload(_ type: String, _ identifier: String, _ values: [String: Any]) -> [String: Any] {
        var result = values
        result.merge(["PayloadType": type, "PayloadVersion": 1,
                      "PayloadIdentifier": identifier, "PayloadUUID": UUID().uuidString]) { _, new in new }
        return result
    }
    let chromeSettings: [String: Any] = [
        "ExtensionSettings": [extensionID: ["installation_mode": "force_installed",
            "update_url": "https://clients2.google.com/service/update2/crx"]],
        "IncognitoModeAvailability": 1, "BrowserGuestModeEnabled": false]
    // Use Apple's documented managed-preferences payload format. Arbitrary
    // bundle IDs are preference domains, not registered Apple payload types.
    func managed(_ domain: String, _ identifier: String, _ values: [String: Any]) -> [String: Any] {
        payload("com.apple.ManagedClient.preferences", identifier, [
            "PayloadContent": [domain: ["Forced": [["mcx_preference_settings": values]]]]])
    }
    let chrome = managed("com.google.Chrome", "com.side-forge.orbit.chrome.policy", chromeSettings)
    let storage = managed("com.google.Chrome.extensions." + extensionID,
        "com.side-forge.orbit.chrome.storage", ["serverURL": serverURL, "browserToken": browserToken])
    let profile = payload("Configuration", "com.side-forge.orbit.chrome.configuration", [
        "PayloadDisplayName": "Orbit Chrome Browser Policy", "PayloadOrganization": "Orbit",
        "PayloadScope": "System", "PayloadRemovalDisallowed": false,
        "PayloadContent": [chrome, storage]])
    return try PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0)
}

func install(_ package: String) throws {
    guard getuid() >= 501, let user = getpwuid(getuid()) else {
        throw SetupError.message("Run Install Orbit.command from the target user's desktop, without sudo")
    }
    let username = String(cString: user.pointee.pw_name)
    let home = String(cString: user.pointee.pw_dir)
    let console = try run("/usr/bin/stat", ["-f", "%Su", "/dev/console"], capture: true)
    guard console == username else { throw SetupError.message("Log into the account whose app usage should be tracked") }
    guard FileManager.default.fileExists(atPath: package) else { throw SetupError.message("Orbit.pkg is missing; extract the entire download first") }
    // Avoid Downloads/Desktop privacy restrictions when the elevated Installer
    // reads the package. Keep the package and credentials private until cleanup.
    let directory = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("orbit-setup-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: directory) }
    let stagedPackage = try stagePackage(URL(fileURLWithPath: package), in: directory)
    func prompt(_ label: String) throws -> String {
        try run("/usr/bin/osascript", ["-e", "text returned of (display dialog \"\(label)\" default answer \"\" with hidden answer buttons {\"Cancel\", \"Continue\"} default button \"Continue\" with title \"Orbit setup\")"], capture: true)
    }
    // The elevated probe returns only server metadata, never the DEVICE token.
    // Use this bundle's staged helper so upgrades from old versions work too.
    let helper = directory.appendingPathComponent("OrbitSetup")
    try FileManager.default.copyItem(at: URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL, to: helper)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
    let script = "on run argv\ndo shell script (item 1 of argv) with administrator privileges\nend run"
    let metadataJSON = try run("/usr/bin/osascript", ["-e", script, shellQuote(helper.path) + " --saved-device-info"], capture: true)
    guard let metadata = try JSONSerialization.jsonObject(with: Data(metadataJSON.utf8)) as? [String: String],
          let serverURL = metadata["serverURL"] else { throw SetupError.message("Cannot read saved installation metadata") }
    let reuseDevice = metadata["reuseDevice"] == "true"
    let saved = savedUserSettings(home: home, serverURL: serverURL)
    let device = reuseDevice ? "" : try prompt("Enter the VPS DEVICE token (not the admin token)")
    let activity = try saved["activityToken"] ?? prompt("Enter the VPS ACTIVITY token")
    let extensionID = try saved["extensionID"] ?? prompt("Enter the published Orbit Chrome Web Store extension ID (32 letters)")
    let browserToken = try saved["browserToken"] ?? prompt("Enter the distinct read-only VPS BROWSER token")
    guard validToken(activity), reuseDevice || validToken(device), browserToken != activity,
          reuseDevice || browserToken != device else { throw SetupError.message("Invalid or shared credentials") }
    let profile = try chromeProfile(extensionID: extensionID, serverURL: serverURL, browserToken: browserToken)
    let file = directory.appendingPathComponent("credentials.json")
    try privateJSON(["serverURL": serverURL, "deviceToken": device, "activityToken": activity, "browserToken": browserToken], at: file.path)
    let configureFlag = reuseDevice ? " --configure-reusing " : " --configure "
    let command = shellQuote(helper.path) + " --prepare-install && /usr/sbin/installer -pkg " + shellQuote(stagedPackage.path) + " -target / && /usr/local/libexec/orbit-setup" + configureFlag + shellQuote(username) + " < " + shellQuote(file.path)
    // Pass the command as argv, not interpolated AppleScript. macOS requests
    // administrator credentials even when the console user is a standard user.
    try run("/usr/bin/osascript", ["-e", script, command])
    let profileURL = URL(fileURLWithPath: home)
        .appendingPathComponent("Library/Application Support/Orbit/Orbit-Chrome.mobileconfig")
    try profile.write(to: profileURL, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: profileURL.path)
    try run("/usr/bin/open", [profileURL.path])
    let message = "Chrome protection needs approval. In System Settings > General > Device Management, install Orbit Chrome Browser Policy using administrator credentials. Then restart Chrome and test a blocked site. Guest and Incognito will be disabled. Until approved, website blocking is not active."
    try run("/usr/bin/osascript", ["-e", "on run argv\ndisplay dialog (item 1 of argv) buttons {\"Open Settings\"} default button \"Open Settings\" with title \"Finish Chrome setup\"\nend run", message])
    try run("/usr/bin/open", ["x-apple.systempreferences:com.apple.Profiles-Settings.extension"])
    print("CHROME SETUP PENDING: Approve Orbit Chrome Browser Policy in System Settings > General > Device Management using administrator credentials. Restart Chrome, verify chrome://policy, and test a blocked site in a new profile. Guest and Incognito will be disabled after approval. The extension must already be published in the Chrome Web Store.")
    print("Orbit services installed for \(username). Confirm both connect in the dashboard.")
    try run("/usr/bin/open", [serverURL])
}

umask(0o077)
do {
    let args = CommandLine.arguments
    if args.count == 3 && args[1] == "--install" { try install(args[2]) }
    else if args.count == 2 && args[1] == "--prepare-install" { try prepareInstall() }
    else if args.count == 2 && args[1] == "--saved-device-info" {
        let metadata = try deviceMetadata(savedDevice())
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: metadata))
    }
    else if args.count == 3 && args[1] == "--configure-reusing" { try configure(args[2], reuseDevice: true) }
    else if args.count == 3 && args[1] == "--configure" { try configure(args[2]) }
    else if args.count == 2 && args[1] == "--monitor-user" { try monitorSetup() }
    else if args.count == 2 && args[1] == "--check-monitor-input" { _ = try readMonitorInput(); print("Monitor credentials valid") }
    else if args.count == 3 && args[1] == "--check-chrome-profile" {
        let values = try JSONSerialization.jsonObject(with: readInputData()) as? [String: String] ?? [:]
        FileHandle.standardOutput.write(try chromeProfile(extensionID: args[2], serverURL: values["serverURL"] ?? "", browserToken: values["browserToken"] ?? ""))
    }
    else if args.count == 2 && args[1] == "--check-input" { _ = try readInput(); print("Credentials valid") }
    else { throw SetupError.message("Use Install Orbit.command from the downloaded bundle") }
} catch SetupError.message(let message) {
    fputs("Orbit setup: \(message)\n", stderr)
    exit(1)
} catch {
    fputs("Orbit setup failed: \(error)\n", stderr)
    exit(1)
}
