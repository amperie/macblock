import Foundation
import Security
import Darwin

struct Schedule: Codable {
    let enabled: Bool
    let start: String
    let end: String
    func validate() throws {
        let pattern = #"\A(?:[01][0-9]|2[0-3]):[0-5][0-9]\z"#
        guard start.range(of: pattern, options: .regularExpression) != nil,
              end.range(of: pattern, options: .regularExpression) != nil else { throw Failure.invalidPolicy }
        func minutes(_ value: String) -> Int? {
            let parts = value.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0].count == 2, parts[1].count == 2,
                  let hour = Int(parts[0]), let minute = Int(parts[1]),
                  (0..<24).contains(hour), (0..<60).contains(minute) else { return nil }
            return hour * 60 + minute
        }
        guard let a = minutes(start), let b = minutes(end), a != b else { throw Failure.invalidPolicy }
    }
    func isBlocked(at date: Date, zone: TimeZone) -> Bool {
        guard enabled else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        let startParts = start.split(separator: ":").compactMap { Int($0) }
        let endParts = end.split(separator: ":").compactMap { Int($0) }
        let a = startParts[0] * 60 + startParts[1], b = endParts[0] * 60 + endParts[1]
        return a < b ? (minute >= a && minute < b) : (minute >= a || minute < b)
    }
}
struct AppSpecificRule: Codable {
    let schedule: Schedule
    let minutes: Int?
}
struct Quota: Codable {
    let enabled: Bool
    let bundleId: String
    let minutes: Int
}
struct QuotaState: Codable {
    let enabled: Bool
    let bundleId: String
    let usedSeconds: Double
    let limitSeconds: Int
    let exceeded: Bool
    let monitoringFresh: Bool
    let day: String
}
struct AppRule: Codable { let name: String; let bundleId: String; let blocked: Bool }
struct Policy: Codable {
    let schemaVersion: Int
    let revision: Int
    let apps: [AppRule]
    let serverTimeUTC: String?
    let enforcementTimeZone: String?
    let schedule: Schedule?
    let quota: Quota?
    let quotaState: QuotaState?
    let appSchedules: [String: Schedule]?
    let appRules: [String: AppSpecificRule]?
    let appQuotaStates: [String: QuotaState]?
    let overrides: [String: String]?
    let blockedDomains: [String]?
    private enum CodingKeys: String, CodingKey { case schemaVersion, revision, apps, serverTimeUTC, enforcementTimeZone, schedule, quota, quotaState, appSchedules, appRules, appQuotaStates, overrides, blockedDomains }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        revision = try values.decode(Int.self, forKey: .revision)
        apps = try values.decode([AppRule].self, forKey: .apps)
        serverTimeUTC = try values.decodeIfPresent(String.self, forKey: .serverTimeUTC)
        enforcementTimeZone = try values.decodeIfPresent(String.self, forKey: .enforcementTimeZone)
        schedule = try values.decodeIfPresent(Schedule.self, forKey: .schedule)
        quota = try values.decodeIfPresent(Quota.self, forKey: .quota)
        quotaState = try values.decodeIfPresent(QuotaState.self, forKey: .quotaState)
        appSchedules = try values.decodeIfPresent([String: Schedule].self, forKey: .appSchedules)
        appRules = try values.decodeIfPresent([String: AppSpecificRule].self, forKey: .appRules)
        appQuotaStates = try values.decodeIfPresent([String: QuotaState].self, forKey: .appQuotaStates)
        overrides = try values.decodeIfPresent([String: String].self, forKey: .overrides)
        blockedDomains = values.contains(.blockedDomains) ? try values.decode([String].self, forKey: .blockedDomains) : []
    }
    func validate() throws {
        guard schemaVersion == 1, revision > 0, revision < 9_007_199_254_740_992, apps.count <= 100 else { throw Failure.invalidPolicy }
        if let schedule = schedule { try schedule.validate() }
        for (_, rule) in appSchedules ?? [:] { try rule.validate() }
        for (_, rule) in appRules ?? [:] {
            try rule.schedule.validate()
            if let minutes = rule.minutes, !(1...1440).contains(minutes) { throw Failure.invalidPolicy }
        }
        if let quota = quota {
            guard quota.minutes >= 1, quota.minutes <= 1440,
                  (!quota.enabled || apps.contains(where: { $0.bundleId == quota.bundleId }))
            else { throw Failure.invalidPolicy }
        }
        if let state = quotaState {
            guard state.usedSeconds.isFinite, state.usedSeconds >= 0,
                  state.limitSeconds > 0, state.day.count == 10
            else { throw Failure.invalidPolicy }
        }
        for (id, state) in appQuotaStates ?? [:] {
            guard state.bundleId == id, state.usedSeconds.isFinite,
                  state.usedSeconds >= 0, state.limitSeconds > 0,
                  state.day.count == 10 else { throw Failure.invalidPolicy }
        }
        if let zone = enforcementTimeZone, TimeZone(identifier: zone) == nil { throw Failure.invalidPolicy }
        let appIDs = Set(apps.map(\.bundleId))
        guard (appRules ?? [:]).keys.allSatisfy({ appIDs.contains($0) }),
              (appSchedules ?? [:]).keys.allSatisfy({ appIDs.contains($0) }),
              (appQuotaStates ?? [:]).keys.allSatisfy({ appIDs.contains($0) }),
              (overrides ?? [:]).keys.allSatisfy({ appIDs.contains($0) })
        else { throw Failure.invalidPolicy }
        var seen = Set<String>()
        for app in apps {
            guard !app.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, app.name.unicodeScalars.count <= 80,
                  app.bundleId.count <= 255,
                  app.bundleId.range(of: "^[A-Za-z0-9_-]+(?:\\.[A-Za-z0-9_-]+)+$", options: .regularExpression) != nil,
                  (app.bundleId == "com.apple.Safari" || !app.bundleId.lowercased().hasPrefix("com.apple.")),
                  !app.bundleId.lowercased().hasPrefix("com.side-forge.orbit."),
                  seen.insert(app.bundleId).inserted else { throw Failure.invalidPolicy }
        }
        let domains = blockedDomains ?? []
        guard domains.count <= 100, Set(domains).count == domains.count else { throw Failure.invalidPolicy }
        for host in domains {
            let labels = host.split(separator: ".", omittingEmptySubsequences: false)
            guard host.utf8.count <= 253, labels.count >= 2, let tld = labels.last,
                  tld.range(of: "[a-z]", options: .regularExpression) != nil,
                  tld.range(of: "^0x[0-9a-f]+$", options: .regularExpression) == nil,
                  labels.allSatisfy({ $0.range(of: #"\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z"#, options: .regularExpression) != nil })
            else { throw Failure.invalidPolicy }
        }
    }
}
struct Settings: Decodable {
    let serverURL: String
    let deviceToken: String
    private enum CodingKeys: String, CodingKey { case serverURL, deviceToken }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        serverURL = try values.decodeIfPresent(String.self, forKey: .serverURL) ?? "https://orbit.side-forge.com"
        deviceToken = try values.decode(String.self, forKey: .deviceToken)
    }
    func validate(development: Bool = false) throws {
        guard let url = URLComponents(string: serverURL),
              url.scheme == "https" || (development && url.scheme == "http" && ["127.0.0.1", "localhost", "::1", "[::1]"].contains(url.host ?? "")),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, url.path.isEmpty || url.path == "/",
              (32...512).contains(deviceToken.utf8.count),
              deviceToken.utf8.allSatisfy({ $0 >= 33 && $0 <= 126 }) else { throw Failure.invalidSettings }
    }
    var baseURL: String { serverURL.hasSuffix("/") ? String(serverURL.dropLast()) : serverURL }
    var canonicalOrigin: String {
        // Used only after validate() has established a complete HTTPS origin.
        var url = URLComponents(string: serverURL)!
        url.host = url.host?.lowercased()
        url.path = ""
        if url.port == 443 { url.port = nil }
        return url.string!
    }
}
enum Failure: Error { case invalidPolicy, invalidSettings, serverRejected, timeout, rollback }
// Packaging substitutes this placeholder in a staging copy, never in source.
let buildVersion = "__ORBIT_BUILD_VERSION__"
let daemonVersion = buildVersion.hasPrefix("__") ? "0.3.0-dev" : buildVersion
let decoder = JSONDecoder()
struct RuntimeOptions {
    var development = false
    var dryRun = false
    var stateDirectory = "/Library/Application Support/Orbit"
    var pollSeconds: Double = 60
    static func parse(_ arguments: [String]) throws -> RuntimeOptions {
        var result = RuntimeOptions()
        result.development = arguments.contains("--dev")
        result.dryRun = result.development && !arguments.contains("--enforce")
        if result.development { result.stateDirectory = ".dev/agent"; result.pollSeconds = 3 }
        var index = 0
        while index < arguments.count {
            let arg = arguments[index]
            switch arg {
            case "--dev": break
            case "--enforce": guard result.development else { throw Failure.invalidSettings }
            case "--state-dir", "--poll-seconds":
                guard result.development, index + 1 < arguments.count else { throw Failure.invalidSettings }
                index += 1
                if arg == "--state-dir" { result.stateDirectory = arguments[index] }
                else {
                    guard let interval = Double(arguments[index]), interval.isFinite, interval >= 1, interval <= 3600 else { throw Failure.invalidSettings }
                    result.pollSeconds = interval
                }
            default: throw Failure.invalidSettings
            }
            index += 1
        }
        return result
    }
}
func log(_ message: String) { print("[Orbit] \(message)"); fflush(stdout) }
var syncError = ""
var enforcementError = ""
let policyLock = NSLock()
var active: Policy?
// Server UTC anchor is advanced using monotonic uptime, not the user's clock.
// It is intentionally memory-only: reboot/offline time is not trustworthy.
var trustedTime: (utc: Date, uptime: TimeInterval)?
var lastQuotaSyncUptime: TimeInterval?
let trustedFormatter = ISO8601DateFormatter()
trustedFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
func trustedNow() -> Date? {
    guard let anchor = trustedTime else { return nil }
    let elapsed = ProcessInfo.processInfo.systemUptime - anchor.uptime
    guard elapsed >= 0, elapsed < 86400 else { return nil }
    return anchor.utc.addingTimeInterval(elapsed)
}

func request(_ settings: Settings, _ path: String, body: Data? = nil) throws -> Data {
    guard let url = URL(string: settings.baseURL + path) else { throw Failure.invalidSettings }
    var req = URLRequest(url: url, timeoutInterval: 20)
    req.setValue("Bearer " + settings.deviceToken, forHTTPHeaderField: "Authorization")
    if let body = body {
        req.httpMethod = "POST"; req.httpBody = body
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    // No redirects: never forward device credentials to another host.
    final class Delegate: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }
    let session = URLSession(configuration: .ephemeral, delegate: Delegate(), delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    let semaphore = DispatchSemaphore(value: 0)
    final class ResultBox: @unchecked Sendable { var result: Result<Data, Error>? }
    let box = ResultBox()
    session.dataTask(with: req) { data, response, error in
        if let error = error { box.result = .failure(error) }
        else if let response = response as? HTTPURLResponse, response.statusCode == 200, let data = data, data.count <= 65536 { box.result = .success(data) }
        else { box.result = .failure(Failure.serverRejected) }
        semaphore.signal()
    }.resume()
    guard semaphore.wait(timeout: .now() + 25) == .success else { throw Failure.timeout }
    return try box.result!.get()
}

func blockedAppIdentifiers(_ policy: Policy?) -> Set<String> {
    guard let policy = policy else { return [] }
    policyLock.lock()
    let scheduleBlocked: Bool
    if let schedule = policy.schedule, schedule.enabled {
        if let now = trustedNow(), let identifier = policy.enforcementTimeZone,
           let zone = TimeZone(identifier: identifier) {
            scheduleBlocked = schedule.isBlocked(at: now, zone: zone)
        } else {
            // Fail closed for scheduled apps if time cannot be verified.
            scheduleBlocked = true
        }
    } else {
        scheduleBlocked = false
    }
    let quotaBlocked: Bool
    if let quota = policy.quota, quota.enabled {
        let recentlySynced = lastQuotaSyncUptime.map {
            let age = ProcessInfo.processInfo.systemUptime - $0
            return age >= 0 && age <= 180
        } ?? false
        let state = policy.quotaState
        quotaBlocked = !recentlySynced || trustedNow() == nil ||
            state == nil || state!.bundleId != quota.bundleId ||
            !state!.monitoringFresh || state!.exceeded || {
                guard let current = trustedNow(),
                      let name = policy.enforcementTimeZone,
                      let tz = TimeZone(identifier: name) else { return true }
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = tz
                let p = calendar.dateComponents([.year, .month, .day], from: current)
                return state!.day != String(format: "%04d-%02d-%02d", p.year!, p.month!, p.day!)
            }()
    } else { quotaBlocked = false }
    let now = trustedNow()
    let zone = policy.enforcementTimeZone.flatMap(TimeZone.init(identifier:))
    let blocked = Set(policy.apps.filter { app in
        // A temporary allowance must never defeat an explicit parent block.
        if app.blocked { return true }
        if let until = policy.overrides?[app.bundleId],
           let expiration = trustedFormatter.date(from: until),
           let now = now, now < expiration { return false }
        let perAppSchedule = policy.appRules?[app.bundleId]?.schedule ?? policy.appSchedules?[app.bundleId]
        let appScheduled: Bool
        if let rule = perAppSchedule, rule.enabled {
            appScheduled = (now != nil && zone != nil) ? rule.isBlocked(at: now!, zone: zone!) : true
        } else { appScheduled = perAppSchedule == nil ? scheduleBlocked : false }
        let appQuota = policy.appQuotaStates?[app.bundleId]
        let quotaSyncValid = lastQuotaSyncUptime.map { let age = ProcessInfo.processInfo.systemUptime - $0; return age >= 0 && age <= 180 } ?? false
        let localDay = (now != nil && zone != nil) ? {
            () -> String in
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone!
            let parts = calendar.dateComponents([.year, .month, .day], from: now!)
            return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
        }() : nil
        let appQuotaRequired = policy.appRules?[app.bundleId]?.minutes != nil
        let appQuotaBlocked = appQuotaRequired && (appQuota == nil ||
            appQuota!.exceeded || !appQuota!.monitoringFresh || now == nil ||
            !quotaSyncValid || localDay != appQuota!.day)
        return app.blocked || appScheduled || appQuotaBlocked ||
            (quotaBlocked && app.bundleId == policy.quota?.bundleId)
    }.map { $0.bundleId })
    policyLock.unlock()
    return blocked
}

func enforce(_ policy: Policy?, development: Bool = false, dryRun: Bool = false) -> String {
    let blocked = blockedAppIdentifiers(policy)
    guard !blocked.isEmpty else { return "" }
    var errorMessage = ""
    let task = Process(); task.executableURL = URL(fileURLWithPath: "/bin/ps")
    task.arguments = development ? ["-U", String(getuid()), "-o", "pid="] : ["-axo", "pid="]
    let pipe = Pipe(); task.standardOutput = pipe
    do { try task.run() } catch { return "Cannot enumerate processes" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile(); task.waitUntilExit()
    guard task.terminationStatus == 0 else { return "Process enumeration failed" }
    for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
        guard let pid = Int32(line.trimmingCharacters(in: .whitespaces)), pid > 1, pid != getpid() else { continue }
        var code: SecCode?
        let attrs = [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attrs, [], &code) == errSecSuccess, let code = code else { continue }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode = staticCode else { continue }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let values = info as? [String: Any], let identifier = values[kSecCodeInfoIdentifier as String] as? String,
              blocked.contains(identifier) else { continue }
        // Validate the running code rather than trusting a process name or app path.
        guard SecCodeCheckValidity(code, [], nil) == errSecSuccess else { continue }
        if dryRun { log("Would stop \(identifier) (PID \(pid))"); continue }
        if kill(pid, SIGKILL) == 0 {
            log("Sent SIGKILL to \(identifier) (PID \(pid))")
        } else if errno != ESRCH {
            errorMessage = "Unable to stop \(identifier) (PID \(pid)): errno \(errno)"
            log(errorMessage)
        }
    }
    return errorMessage
}

if CommandLine.arguments.contains("--check-schedule") {
    guard CommandLine.arguments.count == 4,
          let date = trustedFormatter.date(from: CommandLine.arguments[2]),
          let data = try? Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3])),
          let policy = try? decoder.decode(Policy.self, from: data),
          (try? policy.validate()) != nil,
          let schedule = policy.schedule, let identifier = policy.enforcementTimeZone,
          let zone = TimeZone(identifier: identifier) else { exit(2) }
    print(schedule.isBlocked(at: date, zone: zone) ? "blocked" : "allowed")
    exit(0)
}
if ["--check-policy", "--check-settings", "--print-server-origin"].contains(CommandLine.arguments.dropFirst().first ?? "") {
    do {
        guard CommandLine.arguments.count == 3 else { throw Failure.invalidSettings }
        let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
        switch CommandLine.arguments[1] {
        case "--check-policy":
            let policy = try decoder.decode(Policy.self, from: data)
            try policy.validate(); print("Valid policy, revision \(policy.revision)")
        case "--check-settings":
            try decoder.decode(Settings.self, from: data).validate(); print("Valid settings")
        case "--print-server-origin":
            let settings = try decoder.decode(Settings.self, from: data)
            try settings.validate(); print(settings.canonicalOrigin)
        default: throw Failure.invalidSettings
        }
        exit(0)
    } catch { fputs("Validation failed: \(error)\n", stderr); exit(1) }
}
let options: RuntimeOptions
do { options = try RuntimeOptions.parse(Array(CommandLine.arguments.dropFirst())) }
catch { fputs("Usage: orbit-agent [--dev [--enforce] [--state-dir PATH] [--poll-seconds N]]\n", stderr); exit(1) }
guard options.development || geteuid() == 0 else { fputs("Run as root using the LaunchDaemon, or use --dev.\n", stderr); exit(1) }
let root = URL(fileURLWithPath: options.stateDirectory, isDirectory: true).standardizedFileURL
let cache = root.appendingPathComponent("policy.json")
if options.development {
    guard root.path != "/Library/Application Support/Orbit" else { fputs("Development state must be separate from production.\n", stderr); exit(1) }
    log("DEVELOPMENT · \(options.dryRun ? "dry run (no apps killed)" : "enforcing for current user") · state: \(root.path)")
}
let settings: Settings
do {
    settings = try decoder.decode(Settings.self, from: Data(contentsOf: root.appendingPathComponent("settings.json")))
    try settings.validate(development: options.development)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
} catch { fputs("Invalid or missing Orbit settings.\n", stderr); exit(1) }
do { let saved = try decoder.decode(Policy.self, from: Data(contentsOf: cache)); try saved.validate(); active = saved }
catch { syncError = "No valid cached policy; initial enrollment required" }
// Networking runs separately so a slow/offline server never pauses enforcement.
DispatchQueue.global(qos: .utility).async {
    while true {
        // Fetch separately; publish under the lock, keeping enforcement responsive.
        do {
            let requestStartedUptime = ProcessInfo.processInfo.systemUptime
            let data = try request(settings, "/api/device/policy")
            let receivedUptime = ProcessInfo.processInfo.systemUptime
            let next = try decoder.decode(Policy.self, from: data); try next.validate()
            policyLock.lock()
            let current = active
            policyLock.unlock()
            guard next.revision >= (current?.revision ?? 0) else { throw Failure.rollback }
            // Persistence and scanning never hold the state lock during slow I/O.
            try data.write(to: cache, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cache.path)
            policyLock.lock()
                // Reject malformed or stale time samples. Use a conservative
                // anchor at receipt, never an earlier time than a previous anchor.
                let roundTrip = receivedUptime - requestStartedUptime
                if roundTrip >= 0, roundTrip <= 25,
                   let timestamp = next.serverTimeUTC,
                   next.enforcementTimeZone != nil && TimeZone(identifier: next.enforcementTimeZone!) != nil,
                   let parsed = trustedFormatter.date(from: timestamp),
                   let old = trustedNow(), parsed >= old.addingTimeInterval(-2) {
                    trustedTime = (max(parsed, old), receivedUptime)
                } else if roundTrip >= 0, roundTrip <= 25,
                          (trustedTime == nil || trustedNow() == nil),
                          let timestamp = next.serverTimeUTC,
                          next.enforcementTimeZone != nil && TimeZone(identifier: next.enforcementTimeZone!) != nil,
                          let parsed = trustedFormatter.date(from: timestamp) {
                    trustedTime = (parsed, receivedUptime)
                }
                if next.quota?.enabled == true || (next.appRules ?? [:]).values.contains(where: { $0.minutes != nil }) {
                    lastQuotaSyncUptime = receivedUptime
                } else {
                    lastQuotaSyncUptime = nil
                }
            active = next; syncError = ""; policyLock.unlock()
            if options.development && next.revision != current?.revision {
                log("Received policy revision \(next.revision)")
            }
        } catch {
            policyLock.lock(); syncError = "Policy sync failed; keeping cached rules: \(error)"; policyLock.unlock()
            if options.development { log("Sync failed (\(error)); cached policy remains active") }
        }
        policyLock.lock()
        let report: [String: Any] = ["hostname": ProcessInfo.processInfo.hostName, "revision": active?.revision ?? 0, "agentVersion": options.development ? (options.dryRun ? "0.2.0-dev-dry-run" : "0.2.0-dev-enforce") : daemonVersion, "lastError": String([syncError, enforcementError].filter { !$0.isEmpty }.joined(separator: "; ").prefix(500))]
        policyLock.unlock()
        do {
            _ = try request(settings, "/api/device/status", body: JSONSerialization.data(withJSONObject: report))
            if !options.development {
                let receipt: [String: Any] = ["pid": getpid(), "version": daemonVersion, "at": Date().timeIntervalSince1970]
                try JSONSerialization.data(withJSONObject: receipt).write(to: root.appendingPathComponent("health.json"), options: .atomic)
            }
        } catch { }
        policyLock.lock()
        let hasQuota = active?.quota?.enabled == true || (active?.appRules ?? [:]).values.contains(where: { $0.minutes != nil })
        policyLock.unlock()
        Thread.sleep(forTimeInterval: options.development ? options.pollSeconds : (hasQuota ? 30 : options.pollSeconds))
    }
}
while true {
    policyLock.lock(); let snapshot = active; policyLock.unlock()
    let error = enforce(snapshot, development: options.development, dryRun: options.dryRun)
    policyLock.lock(); enforcementError = error; policyLock.unlock()
    Thread.sleep(forTimeInterval: 2)
}
