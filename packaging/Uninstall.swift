import Foundation
import Darwin

enum RemovalError: Error { case message(String) }

@discardableResult
func command(_ path: String, _ arguments: [String], capture: Bool = false) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    let pipe = Pipe()
    if capture { process.standardOutput = pipe; process.standardError = FileHandle.nullDevice }
    try process.run()
    let data = capture ? pipe.fileHandleForReading.readDataToEndOfFile() : Data()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw RemovalError.message("\(path) failed (\(process.terminationStatus)); removal did not complete")
    }
    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

func stopService(_ service: String) throws {
    if (try? command("/bin/launchctl", ["print", service], capture: true)) != nil {
        try command("/bin/launchctl", ["bootout", service])
        if (try? command("/bin/launchctl", ["print", service], capture: true)) != nil {
            throw RemovalError.message("Service is still loaded: \(service)")
        }
    }
}

let installedFiles = [
    "/Library/LaunchDaemons/com.side-forge.orbit.agent.plist",
    "/Library/PrivilegedHelperTools/orbit-agent",
    "/usr/local/libexec/orbit-foreground",
    "/usr/local/libexec/orbit-setup",
    "/usr/local/libexec/orbit-uninstall"
]

func userFiles(home: String, purge: Bool) -> [String] {
    var paths = [home + "/Library/LaunchAgents/com.side-forge.orbit.foreground.plist",
                 home + "/Library/Application Support/Orbit/orbit-foreground",
                 home + "/Library/Application Support/Orbit/Orbit-Chrome.mobileconfig"]
    if purge {
        paths += [home + "/Library/Application Support/Orbit/monitor-settings.json",
                  home + "/Library/Application Support/Orbit/activity-queue.json"]
    }
    return paths
}

func removeFile(_ path: String) throws {
    // lstat also finds broken symlinks; removeItem removes the link itself.
    var info = stat()
    if lstat(path, &info) == 0 {
        guard (info.st_mode & S_IFMT) != S_IFDIR else {
            throw RemovalError.message("Expected a file, refusing to remove directory: \(path)")
        }
        try FileManager.default.removeItem(atPath: path)
    } else if errno != ENOENT {
        throw RemovalError.message("Cannot inspect \(path)")
    }
}

let chromeProfileIdentifier = "com.side-forge.orbit.chrome.configuration"

func containsOrbitProfile(_ dictionary: [String: Any]) throws -> Bool {
    var found = false
    // profiles list exports a dictionary of scope/user -> profile arrays.
    // An unexpected successful response is not evidence of profile absence.
    for value in dictionary.values {
        guard let profiles = value as? [[String: Any]] else {
            throw RemovalError.message("Unrecognized installed-profile listing")
        }
        for profile in profiles {
            guard let identifier = profile["ProfileIdentifier"] as? String else {
                throw RemovalError.message("Installed-profile identifier is missing")
            }
            if identifier == chromeProfileIdentifier { found = true }
        }
    }
    return found
}

func removeChromeProfiles(users: [String], execute: (String, [String]) throws -> String) -> Bool {
    func present() throws -> Bool {
        let xml = try execute("/usr/bin/profiles", ["list", "-all", "-output", "stdout-xml"])
        let plist = try PropertyListSerialization.propertyList(from: Data(xml.utf8), options: [], format: nil)
        guard let dictionary = plist as? [String: Any] else {
            throw RemovalError.message("Cannot verify installed Chrome profiles")
        }
        return try containsOrbitProfile(dictionary)
    }
    if (try? present()) == false { return true }
    // Include legacy user-scoped installations. -forced suppresses interactive
    // confirmation, but does not override MDM or a removal password.
    let base = ["remove", "-identifier", chromeProfileIdentifier, "-forced"]
    _ = try? execute("/usr/bin/profiles", base)
    for user in users { _ = try? execute("/usr/bin/profiles", base + ["-user", user]) }
    return (try? present()) == false
}

func removeInstallation(purge: Bool) throws {
    guard getuid() == 0 else { throw RemovalError.message("Uninstall requires administrator authorization") }
    // Discover every local user's tracker, including users who are logged out.
    // No root process writes or removes anything inside a user's home.
    let users = try command("/usr/bin/dscl", [".", "-list", "/Users", "UniqueID"], capture: true)
    var accounts: [(String, uid_t, String)] = []
    for line in users.split(separator: "\n") {
        let fields = line.split(whereSeparator: { $0.isWhitespace })
        guard fields.count == 2, let id = UInt32(fields[1]), id >= 501,
              let record = getpwnam(String(fields[0])) else { continue }
        let home = String(cString: record.pointee.pw_dir)
        guard home.hasPrefix("/"), !["/", "/var/empty", "/Users/Shared"].contains(home) else { continue }
        accounts.append((String(fields[0]), id, home))
    }
    // Remove only Orbit's profile; never rewrite shared Chrome preference files
    // or edit Chrome's profile databases. MDM may refuse local removal.
    let profileRemoved = removeChromeProfiles(users: accounts.map { $0.0 }) { path, arguments in
        try command(path, arguments, capture: true)
    }
    // Clean up the standalone browser installer's generated profile too.
    for directory in ["/Library/Application Support/Orbit", "/Library/Application Support/Orbit/Browser"] {
        var info = stat()
        if lstat(directory, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == 0,
                  (info.st_mode & 0o022) == 0 else {
                throw RemovalError.message("Unsafe browser settings directory; refusing cleanup")
            }
        } else if errno == ENOENT { break }
        else { throw RemovalError.message("Cannot inspect browser settings directory") }
        if directory.hasSuffix("/Browser") { try removeFile(directory + "/Orbit-Chrome.mobileconfig") }
    }
    try stopService("system/com.side-forge.orbit.agent")
    for (name, uid, home) in accounts {
        try stopService("gui/\(uid)/com.side-forge.orbit.foreground")
        try command("/usr/bin/sudo", ["-H", "-u", name, "/bin/rm", "-f", "--"] + userFiles(home: home, purge: purge))
    }
    if purge {
        let directory = "/Library/Application Support/Orbit"
        var info = stat()
        if lstat(directory, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == 0,
                  (info.st_mode & 0o022) == 0 else {
                throw RemovalError.message("Unsafe system settings directory; refusing to follow links or delete its contents")
            }
            for name in ["settings.json", "policy.json"] { try removeFile(directory + "/" + name) }
        } else if errno != ENOENT { throw RemovalError.message("Cannot inspect system settings directory") }
        try removeFile("/var/log/orbit.log")
    }
    for file in installedFiles { try removeFile(file) }
    let receipt = "com.side-forge.orbit.installer"
    let receipts = try command("/usr/sbin/pkgutil", ["--pkgs"], capture: true)
    if receipts.split(separator: "\n").contains(Substring(receipt)) {
        try command("/usr/sbin/pkgutil", ["--forget", receipt])
    }
    print("Orbit removed. " + (purge ? "Local credentials, policy cache and telemetry queue deleted." : "Local settings and cached data preserved."))
    if profileRemoved {
        print("Orbit Chrome profile removed. Restart Chrome to refresh policy; check chrome://extensions and remove Orbit if it remains. Other management policies may still apply.")
    } else {
        print("CHROME CLEANUP REQUIRED: Orbit profile removal could not be confirmed (it may be absent or MDM-managed). Check System Settings > General > Device Management and remove Orbit Chrome Browser Policy, or ask the MDM administrator. Restart Chrome and remove Orbit at chrome://extensions if it remains.")
    }
    print("VPS history and Safari were not changed. Chrome browsing data was preserved.")
}

func prompt() throws {
    guard getuid() >= 501 else { throw RemovalError.message("Open Uninstall Orbit.command without sudo") }
    let script = "button returned of (display dialog \"Remove Orbit blocking and app tracking for all local users? Chrome policy removal will be attempted. VPS history is unchanged.\" buttons {\"Cancel\", \"Delete local data\", \"Keep local data\"} default button \"Keep local data\" cancel button \"Cancel\" with title \"Uninstall Orbit\")"
    let choice = try command("/usr/bin/osascript", ["-e", script], capture: true)
    guard ["Keep local data", "Delete local data"].contains(choice) else { throw RemovalError.message("Uninstall cancelled") }
    let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
    let action = quote(executable) + " --remove" + (choice == "Delete local data" ? " --purge" : "")
    let authorize = "on run argv\ndo shell script (item 1 of argv) with administrator privileges\nend run"
    let result = try command("/usr/bin/osascript", ["-e", authorize, action], capture: true)
    print(result)
    if result.contains("CHROME CLEANUP REQUIRED") {
        try command("/usr/bin/open", ["x-apple.systempreferences:com.apple.Profiles-Settings.extension"])
    }
    let message = "Orbit services removed. Restart Chrome and check chrome://extensions. If Orbit Chrome Browser Policy remains in Device Management, remove it there or through MDM."
    try command("/usr/bin/osascript", ["-e", "on run argv\ndisplay dialog (item 1 of argv) buttons {\"OK\"} default button \"OK\" with title \"Uninstall Orbit\"\nend run", message])
}

do {
    let args = Array(CommandLine.arguments.dropFirst())
    if args == ["--prompt"] { try prompt() }
    else if args == ["--remove"] { try removeInstallation(purge: false) }
    else if args == ["--remove", "--purge"] { try removeInstallation(purge: true) }
    else if args == ["--plan"] || args == ["--plan", "--purge"] {
        let purge = args.contains("--purge")
        let plan: [String: Any] = ["installedFiles": installedFiles,
            "userFiles": userFiles(home: "/Users/TARGET", purge: purge),
            "purgeLocalData": purge, "touchesVPS": false,
            "chromeProfileIdentifier": "com.side-forge.orbit.chrome.configuration",
            "attemptsChromeProfileRemoval": true, "deletesChromeBrowsingData": false]
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: plan, options: .sortedKeys))
    } else { throw RemovalError.message("Open Uninstall Orbit.command to remove Orbit") }
} catch RemovalError.message(let message) {
    fputs("Orbit uninstall: \(message)\n", stderr)
    exit(1)
} catch {
    fputs("Orbit uninstall failed: \(error)\n", stderr)
    exit(1)
}
