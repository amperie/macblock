import Foundation
import Security
import Darwin

struct Schedule: Codable {
    let enabled: Bool
    let start: String
    let end: String
    func validate() throws {
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
    let appQuotaStates: [String: QuotaState]?
    let overrides: [String: String]?
    func validate() throws {
        guard schemaVersion == 1, revision > 0, apps.count <= 100 else { throw Failure.invalidPolicy }
        if let schedule = schedule { try schedule.validate() }
        for (_, rule) in appSchedules ?? [:] { try rule.validate() }
        if let quota = quota, quota.enabled {
            guard quota.minutes >= 1, quota.minutes <= 1440,
                  apps.contains(where: { $0.bundleId == quota.bundleId }) else { throw Failure.invalidPolicy }
        }
        if let zone = enforcementTimeZone, TimeZone(identifier: zone) == nil { throw Failure.invalidPolicy }
        var seen = Set<String>()
        for app in apps {
            guard !app.name.isEmpty, app.name.count <= 80,
                  app.bundleId.count <= 255,
                  app.bundleId.range(of: "^[A-Za-z0-9_-]+(?:\\.[A-Za-z0-9_-]+)+$", options: .regularExpression) != nil,
                  !app.bundleId.lowercased().hasPrefix("com.apple."),
                  !app.bundleId.lowercased().hasPrefix("com.macblock."),
                  seen.insert(app.bundleId).inserted else { throw Failure.invalidPolicy }
        }
    }
}
struct Settings: Decodable { let serverURL: String; let deviceToken: String }
enum Failure: Error { case invalidPolicy, invalidSettings, serverRejected, timeout, rollback }
let encoder = JSONEncoder()
let decoder = JSONDecoder()
let root = URL(fileURLWithPath: "/Library/Application Support/MacBlock", isDirectory: true)
let cache = root.appendingPathComponent("policy.json")
var lastError = ""
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
    guard let url = URL(string: settings.serverURL + path) else { throw Failure.invalidSettings }
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

func enforce() {
    guard let policy = active else { return }
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
            !state!.monitoringFresh || state!.exceeded
    } else { quotaBlocked = false }
    let now = trustedNow()
    let zone = policy.enforcementTimeZone.flatMap(TimeZone.init(identifier:))
    let blocked = Set(policy.apps.filter { app in
        if let until = policy.overrides?[app.bundleId],
           let expiration = trustedFormatter.date(from: until),
           let now = now, now < expiration { return false }
        let perAppSchedule = policy.appSchedules?[app.bundleId]
        let appScheduled: Bool
        if let rule = perAppSchedule, rule.enabled {
            appScheduled = (now != nil && zone != nil) ? rule.isBlocked(at: now!, zone: zone!) : true
        } else { appScheduled = scheduleBlocked }
        let appQuota = policy.appQuotaStates?[app.bundleId]
        let appQuotaBlocked = appQuota.map { $0.exceeded || !$0.monitoringFresh || now == nil } ?? false
        return app.blocked || appScheduled || appQuotaBlocked ||
            (quotaBlocked && app.bundleId == policy.quota?.bundleId)
    }.map { $0.bundleId })
    guard !blocked.isEmpty else { return }
    let task = Process(); task.executableURL = URL(fileURLWithPath: "/bin/ps")
    task.arguments = ["-axo", "pid="]
    let pipe = Pipe(); task.standardOutput = pipe
    do { try task.run() } catch { lastError = "Cannot enumerate processes"; return }
    let data = pipe.fileHandleForReading.readDataToEndOfFile(); task.waitUntilExit()
    guard task.terminationStatus == 0 else { lastError = "Process enumeration failed"; return }
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
        if kill(pid, SIGKILL) != 0 && errno != ESRCH { lastError = "Unable to stop \(identifier): errno \(errno)" }
    }
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
if CommandLine.arguments.contains("--check-policy") {
    do {
        let file = CommandLine.arguments.last!
        let policy = try decoder.decode(Policy.self, from: Data(contentsOf: URL(fileURLWithPath: file)))
        try policy.validate(); print("Valid policy, revision \(policy.revision)"); exit(0)
    } catch { fputs("Invalid policy: \(error)\n", stderr); exit(1) }
}
guard geteuid() == 0 else { fputs("Run as root using the supplied LaunchDaemon.\n", stderr); exit(1) }
let settings: Settings
do {
    settings = try decoder.decode(Settings.self, from: Data(contentsOf: root.appendingPathComponent("settings.json")))
    guard let url = URL(string: settings.serverURL), url.scheme == "https", url.host != nil, url.user == nil, url.query == nil, url.fragment == nil, settings.deviceToken.count >= 32 else { throw Failure.invalidSettings }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
} catch { fputs("Invalid or missing MacBlock settings.\n", stderr); exit(1) }
do { let saved = try decoder.decode(Policy.self, from: Data(contentsOf: cache)); try saved.validate(); active = saved }
catch { lastError = "No valid cached policy; initial enrollment required" }
// Networking runs separately so a slow/offline server never pauses enforcement.
let policyLock = NSLock()
DispatchQueue.global(qos: .utility).async {
    while true {
        // Fetch separately; publish under the lock, keeping enforcement responsive.
        do {
            let requestStartedUptime = ProcessInfo.processInfo.systemUptime
            let data = try request(settings, "/api/device/policy")
            let receivedUptime = ProcessInfo.processInfo.systemUptime
            let next = try decoder.decode(Policy.self, from: data); try next.validate()
            policyLock.lock()
            if next.revision >= (active?.revision ?? 0) {
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
                if next.quota?.enabled == true {
                    lastQuotaSyncUptime = receivedUptime
                } else {
                    lastQuotaSyncUptime = nil
                }
                do { try data.write(to: cache, options: .atomic); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cache.path); active = next; lastError = "" }
                catch { lastError = "Cannot persist policy" }
            } else { lastError = "Rejected older policy" }
            policyLock.unlock()
        } catch { policyLock.lock(); lastError = "Policy sync failed; keeping cached rules"; policyLock.unlock() }
        policyLock.lock()
        let report: [String: Any] = ["revision": active?.revision ?? 0, "agentVersion": "0.2.0", "lastError": String(lastError.prefix(500))]
        policyLock.unlock()
        do { _ = try request(settings, "/api/device/status", body: JSONSerialization.data(withJSONObject: report)) } catch { }
        policyLock.lock()
        let refreshInterval: TimeInterval = active?.quota?.enabled == true ? 30 : 120
        policyLock.unlock()
        Thread.sleep(forTimeInterval: refreshInterval)
    }
}
while true { policyLock.lock(); enforce(); policyLock.unlock(); Thread.sleep(forTimeInterval: 2) }
