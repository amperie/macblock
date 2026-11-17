import Foundation
import Security
import Darwin

struct AppRule: Codable, Equatable { let name: String; let bundleId: String; let blocked: Bool }
struct Policy: Codable, Equatable {
    let schemaVersion: Int
    let revision: Int
    let apps: [AppRule]
    let blockedDomains: [String]
    private enum CodingKeys: String, CodingKey { case schemaVersion, revision, apps, blockedDomains }
    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try fields.decode(Int.self, forKey: .schemaVersion)
        revision = try fields.decode(Int.self, forKey: .revision)
        apps = try fields.decode([AppRule].self, forKey: .apps)
        blockedDomains = fields.contains(.blockedDomains) ? try fields.decode([String].self, forKey: .blockedDomains) : []
    }
    func validate() throws {
        guard schemaVersion == 1, revision > 0, revision < 9_007_199_254_740_992, apps.count <= 100 else { throw Failure.invalidPolicy }
        var seen = Set<String>()
        for app in apps {
            guard !app.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, app.name.unicodeScalars.count <= 80,
                  app.bundleId.count <= 255,
                  app.bundleId.range(of: "^[A-Za-z0-9_-]+(?:\\.[A-Za-z0-9_-]+)+$", options: .regularExpression) != nil,
                  !app.bundleId.lowercased().hasPrefix("com.apple."),
                  !app.bundleId.lowercased().hasPrefix("com.macblock."),
                  seen.insert(app.bundleId).inserted else { throw Failure.invalidPolicy }
        }
        let domains = blockedDomains
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
    func validate(development: Bool = false) throws {
        guard let url = URLComponents(string: serverURL),
              url.scheme == "https" || (development && url.scheme == "http" && ["127.0.0.1", "localhost", "::1", "[::1]"].contains(url.host ?? "")),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, url.path.isEmpty || url.path == "/",
              (32...512).contains(deviceToken.utf8.count),
              deviceToken.utf8.allSatisfy({ $0 >= 33 && $0 <= 126 }) else { throw Failure.invalidSettings }
    }
    var baseURL: String { serverURL.hasSuffix("/") ? String(serverURL.dropLast()) : serverURL }
}
enum Failure: Error { case invalidPolicy, invalidSettings, serverRejected, timeout, rollback }
let decoder = JSONDecoder()
struct RuntimeOptions {
    var development = false
    var dryRun = false
    var stateDirectory = "/Library/Application Support/MacBlock"
    var pollSeconds: Double = 120
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
func log(_ message: String) { print("[MacBlock] \(message)"); fflush(stdout) }
var syncError = ""
var enforcementError = ""
var active: Policy?

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

func enforce(_ policy: Policy?, development: Bool = false, dryRun: Bool = false) -> String {
    guard let policy = policy else { return "" }
    let blocked = Set(policy.apps.filter { $0.blocked }.map { $0.bundleId })
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
        log("Stopping \(identifier) (PID \(pid))")
        if kill(pid, SIGKILL) != 0 && errno != ESRCH { errorMessage = "Unable to stop \(identifier): errno \(errno)" }
    }
    return errorMessage
}

if ["--check-policy", "--check-settings"].contains(CommandLine.arguments.dropFirst().first ?? "") {
    do {
        guard CommandLine.arguments.count == 3 else { throw Failure.invalidSettings }
        let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
        switch CommandLine.arguments[1] {
        case "--check-policy":
            let policy = try decoder.decode(Policy.self, from: data)
            try policy.validate(); print("Valid policy, revision \(policy.revision)")
        case "--check-settings":
            try decoder.decode(Settings.self, from: data).validate(); print("Valid settings")
        default: throw Failure.invalidSettings
        }
        exit(0)
    } catch { fputs("Validation failed: \(error)\n", stderr); exit(1) }
}
let options: RuntimeOptions
do { options = try RuntimeOptions.parse(Array(CommandLine.arguments.dropFirst())) }
catch { fputs("Usage: macblock-agent [--dev [--enforce] [--state-dir PATH] [--poll-seconds N]]\n", stderr); exit(1) }
guard options.development || geteuid() == 0 else { fputs("Run as root using the LaunchDaemon, or use --dev.\n", stderr); exit(1) }
let root = URL(fileURLWithPath: options.stateDirectory, isDirectory: true).standardizedFileURL
let cache = root.appendingPathComponent("policy.json")
if options.development {
    guard root.path != "/Library/Application Support/MacBlock" else { fputs("Development state must be separate from production.\n", stderr); exit(1) }
    log("DEVELOPMENT · \(options.dryRun ? "dry run (no apps killed)" : "enforcing for current user") · state: \(root.path)")
}
let settings: Settings
do {
    settings = try decoder.decode(Settings.self, from: Data(contentsOf: root.appendingPathComponent("settings.json")))
    try settings.validate(development: options.development)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
} catch { fputs("Invalid or missing MacBlock settings.\n", stderr); exit(1) }
do { let saved = try decoder.decode(Policy.self, from: Data(contentsOf: cache)); try saved.validate(); active = saved }
catch { syncError = "No valid cached policy; initial enrollment required" }
// Networking runs separately so a slow/offline server never pauses enforcement.
let policyLock = NSLock()
DispatchQueue.global(qos: .utility).async {
    while true {
        // Fetch separately; publish under the lock, keeping enforcement responsive.
        do {
            let data = try request(settings, "/api/device/policy")
            let next = try decoder.decode(Policy.self, from: data); try next.validate()
            policyLock.lock()
            let current = active
            policyLock.unlock()
            guard next.revision >= (current?.revision ?? 0) else { throw Failure.rollback }
            if let current = current, next.revision == current.revision, next != current { throw Failure.invalidPolicy }
            // Persistence and scanning never hold the state lock during slow I/O.
            try data.write(to: cache, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cache.path)
            policyLock.lock(); active = next; syncError = ""; policyLock.unlock()
            if options.development { log("Received policy revision \(next.revision)") }
        } catch {
            policyLock.lock(); syncError = "Policy sync failed; keeping cached rules: \(error)"; policyLock.unlock()
            if options.development { log("Sync failed (\(error)); cached policy remains active") }
        }
        policyLock.lock()
        let report: [String: Any] = ["revision": active?.revision ?? 0, "agentVersion": options.development ? (options.dryRun ? "0.1.0-dev-dry-run" : "0.1.0-dev-enforce") : "0.1.0", "lastError": String([syncError, enforcementError].filter { !$0.isEmpty }.joined(separator: "; ").prefix(500))]
        policyLock.unlock()
        do { _ = try request(settings, "/api/device/status", body: JSONSerialization.data(withJSONObject: report)) } catch { }
        Thread.sleep(forTimeInterval: options.pollSeconds)
    }
}
while true {
    policyLock.lock(); let snapshot = active; policyLock.unlock()
    let error = enforce(snapshot, development: options.development, dryRun: options.dryRun)
    policyLock.lock(); enforcementError = error; policyLock.unlock()
    Thread.sleep(forTimeInterval: 2)
}
