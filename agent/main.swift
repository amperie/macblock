import Foundation
import Security
import Darwin

struct AppRule: Codable { let name: String; let bundleId: String; let blocked: Bool }
struct Policy: Codable {
    let schemaVersion: Int
    let revision: Int
    let apps: [AppRule]
    func validate() throws {
        guard schemaVersion == 1, revision > 0, apps.count <= 100 else { throw Failure.invalidPolicy }
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
    let blocked = Set(policy.apps.filter { $0.blocked }.map { $0.bundleId })
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
            let data = try request(settings, "/api/device/policy")
            let next = try decoder.decode(Policy.self, from: data); try next.validate()
            policyLock.lock()
            if next.revision >= (active?.revision ?? 0) {
                do { try data.write(to: cache, options: .atomic); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cache.path); active = next; lastError = "" }
                catch { lastError = "Cannot persist policy" }
            } else { lastError = "Rejected older policy" }
            policyLock.unlock()
        } catch { policyLock.lock(); lastError = "Policy sync failed; keeping cached rules"; policyLock.unlock() }
        policyLock.lock()
        let report: [String: Any] = ["revision": active?.revision ?? 0, "agentVersion": "0.1.0", "lastError": String(lastError.prefix(500))]
        policyLock.unlock()
        do { _ = try request(settings, "/api/device/status", body: JSONSerialization.data(withJSONObject: report)) } catch { }
        Thread.sleep(forTimeInterval: 120)
    }
}
while true { policyLock.lock(); enforce(); policyLock.unlock(); Thread.sleep(forTimeInterval: 2) }
