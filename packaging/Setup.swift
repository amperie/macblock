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
          let token = object["deviceToken"], (32...512).contains(token.utf8.count),
          token.utf8.allSatisfy({ (33...126).contains($0) }) else {
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

func configure(_ username: String) throws {
    guard getuid() == 0, let user = getpwnam(username), user.pointee.pw_uid >= 501 else {
        throw SetupError.message("Configuration requires administrator authorization and a regular target user")
    }
    let uid = user.pointee.pw_uid
    let console = try run("/usr/bin/stat", ["-f", "%Su", "/dev/console"], capture: true)
    guard console == username else { throw SetupError.message("Log into the target user's desktop before installing") }
    let credentials = try readInput()
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

func install(_ package: String) throws {
    guard getuid() >= 501, let user = getpwuid(getuid()) else {
        throw SetupError.message("Run Install Orbit.command from the target user's desktop, without sudo")
    }
    let username = String(cString: user.pointee.pw_name)
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
    let credentials = Credentials(serverURL: "https://orbit.side-forge.com",
                                  deviceToken: try prompt("Enter the VPS DEVICE token (not the admin token)"),
                                  activityToken: try prompt("Enter the VPS ACTIVITY token"))
    try credentials.validate()
    let file = directory.appendingPathComponent("credentials.json")
    try JSONEncoder().encode(credentials).write(to: file, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    let command = "/usr/sbin/installer -pkg " + shellQuote(stagedPackage.path) + " -target / && /usr/local/libexec/orbit-setup --configure " + shellQuote(username) + " < " + shellQuote(file.path)
    // Pass the command as argv, not interpolated AppleScript. macOS requests
    // administrator credentials even when the console user is a standard user.
    let script = "on run argv\ndo shell script (item 1 of argv) with administrator privileges\nend run"
    try run("/usr/bin/osascript", ["-e", script, command])
    print("Orbit services installed for \(username). Confirm both connect in the dashboard.")
    try run("/usr/bin/open", ["https://orbit.side-forge.com"])
}

umask(0o077)
do {
    let args = CommandLine.arguments
    if args.count == 3 && args[1] == "--install" { try install(args[2]) }
    else if args.count == 3 && args[1] == "--configure" { try configure(args[2]) }
    else if args.count == 2 && args[1] == "--monitor-user" { try monitorSetup() }
    else if args.count == 2 && args[1] == "--check-monitor-input" { _ = try readMonitorInput(); print("Monitor credentials valid") }
    else if args.count == 2 && args[1] == "--check-input" { _ = try readInput(); print("Credentials valid") }
    else { throw SetupError.message("Use Install Orbit.command from the downloaded bundle") }
} catch SetupError.message(let message) {
    fputs("Orbit setup: \(message)\n", stderr)
    exit(1)
} catch {
    fputs("Orbit setup failed: \(error)\n", stderr)
    exit(1)
}
