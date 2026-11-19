import Foundation
import CryptoKit
import Darwin

enum UpdateError: Error { case invalid(String) }
let updateRoot = URL(fileURLWithPath: "/Library/Application Support/OrbitUpdates", isDirectory: true)
let binaries = ["agent": "/Library/PrivilegedHelperTools/orbit-agent", "monitor": "/usr/local/libexec/orbit-foreground"]
let updaterLabel = "com.side-forge.orbit.updater"
struct Artifact: Codable { let url: String; let sha256: String; let size: Int }
struct Manifest: Codable {
    let schemaVersion: Int; let sequence: Int; let version: String; let artifacts: [String: Artifact]
    func validate() throws {
        guard schemaVersion == 1, sequence > 0, sequence < 9_007_199_254_740_992,
              version.range(of: #"\A[0-9]+\.[0-9]+\.[0-9]+\z"#, options: .regularExpression) != nil,
              version.count <= 40, Set(artifacts.keys) == Set(binaries.keys) else { throw UpdateError.invalid("Invalid manifest") }
        for artifact in artifacts.values {
            _ = try httpsURL(artifact.url)
            guard (1...20_000_000).contains(artifact.size),
                  artifact.sha256.range(of: #"\A[0-9a-f]{64}\z"#, options: .regularExpression) != nil else { throw UpdateError.invalid("Invalid artifact") }
        }
    }
}
struct UpdateConfig: Codable { let enabled: Bool; let publicKey: String; let manifestURL: String }
struct Installed: Codable { let version: String; let sequence: Int }
struct UpdateState: Codable { var sequence = 0; var failedSequence = 0; var version = "unknown" }
struct MonitorService: Codable { let uid: UInt32; let home: String }
struct Journal: Codable { let sequence: Int; let version: String; let monitors: [MonitorService] }

func httpsURL(_ string: String) throws -> URL {
    guard let parts = URLComponents(string: string), parts.scheme == "https", let host = parts.host,
          !host.isEmpty, parts.user == nil, parts.password == nil, parts.fragment == nil,
          !string.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) }),
          let url = parts.url else { throw UpdateError.invalid("HTTPS URL required") }
    return url
}
func verifiedManifest(_ data: Data, signature: Data, publicKey: String) throws -> Manifest {
    guard data.count <= 16384, let keyData = Data(base64Encoded: publicKey), keyData.count == 32,
          signature.count == 64 else { throw UpdateError.invalid("Invalid signing material") }
    let key = try Curve25519.Signing.PublicKey(rawRepresentation: keyData)
    guard key.isValidSignature(signature, for: data) else { throw UpdateError.invalid("Manifest signature rejected") }
    let manifest = try JSONDecoder().decode(Manifest.self, from: data)
    try manifest.validate()
    return manifest
}
func verifyArtifact(_ data: Data, _ artifact: Artifact) throws {
    guard data.count == artifact.size,
          SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == artifact.sha256 else {
        throw UpdateError.invalid("Artifact digest/size rejected")
    }
}
func newer(_ manifest: Manifest, state: UpdateState, baseline: Int) -> Bool {
    manifest.sequence > max(state.sequence, baseline) && manifest.sequence != state.failedSequence
}

// No shell, no credentials, bounded HTTPS-only downloads (including redirects).
final class Download: NSObject, URLSessionDataDelegate {
    let limit: Int; let done = DispatchSemaphore(value: 0)
    var data = Data(); var error: Error?; var redirects = 0
    init(limit: Int) { self.limit = limit }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              response.expectedContentLength <= Int64(limit) else {
            error = UpdateError.invalid("Download response rejected"); completionHandler(.cancel); return
        }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive bytes: Data) {
        guard data.count <= limit - bytes.count else { error = UpdateError.invalid("Download too large"); dataTask.cancel(); return }
        data.append(bytes)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        redirects += 1
        guard redirects <= 5, let url = request.url, (try? httpsURL(url.absoluteString)) != nil else {
            error = UpdateError.invalid("Redirect rejected"); completionHandler(nil); return
        }
        completionHandler(request)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError failure: Error?) {
        if error == nil { error = failure }; done.signal()
    }
    static func get(_ url: URL, limit: Int) throws -> Data {
        _ = try httpsURL(url.absoluteString)
        let receiver = Download(limit: limit)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20; config.timeoutIntervalForResource = 60
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config, delegate: receiver, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        session.dataTask(with: url).resume()
        guard receiver.done.wait(timeout: .now() + 65) == .success else { throw UpdateError.invalid("Download timeout") }
        if let error = receiver.error { throw error }
        return receiver.data
    }
}

@discardableResult
func execute(_ path: String, _ arguments: [String]) throws -> String {
    let process = Process(); process.executableURL = URL(fileURLWithPath: path); process.arguments = arguments
    let output = Pipe(); process.standardOutput = output; process.standardError = output
    try process.run(); let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw UpdateError.invalid("Command failed: \(path)") }
    return String(decoding: data, as: UTF8.self)
}
func secureDirectory(_ url: URL) throws {
    var info = stat()
    if lstat(url.path, &info) != 0 {
        guard errno == ENOENT else { throw UpdateError.invalid("Cannot inspect directory") }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        guard lstat(url.path, &info) == 0 else { throw UpdateError.invalid("Cannot inspect new directory") }
    }
    guard (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == 0, (info.st_mode & 0o077) == 0 else { throw UpdateError.invalid("Unsafe update directory") }
}
func readFile(_ url: URL, limit: Int = 16384, owner: uid_t = 0) throws -> Data {
    let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
    guard fd >= 0 else { throw UpdateError.invalid("Cannot open \(url.lastPathComponent)") }
    defer { close(fd) }; var info = stat()
    guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == owner,
          (info.st_mode & 0o022) == 0, info.st_size >= 0, info.st_size <= limit else { throw UpdateError.invalid("Unsafe file") }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
    let data = handle.readData(ofLength: limit + 1)
    guard data.count <= limit else { throw UpdateError.invalid("File too large") }
    return data
}
func syncPath(_ path: String) throws {
    let fd = open(path, O_RDONLY | O_NOFOLLOW)
    guard fd >= 0 else { throw UpdateError.invalid("Cannot open for sync") }
    defer { close(fd) }
    guard fsync(fd) == 0 else { throw UpdateError.invalid("Cannot sync update") }
}
func durableWrite(_ data: Data, to url: URL, permissions: Int = 0o600) throws {
    try data.write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
    try syncPath(url.path); try syncPath(url.deletingLastPathComponent().path)
}
func save<T: Encodable>(_ object: T, to url: URL) throws { try durableWrite(JSONEncoder().encode(object), to: url) }
func load<T: Decodable>(_ type: T.Type, _ url: URL) throws -> T { try JSONDecoder().decode(type, from: readFile(url)) }
func optionalState(_ root: URL) throws -> UpdateState {
    let url = root.appendingPathComponent("state.json")
    var info = stat()
    if lstat(url.path, &info) != 0 && errno == ENOENT { return UpdateState() }
    let state = try load(UpdateState.self, url)
    guard state.sequence >= 0, state.failedSequence >= 0 else { throw UpdateError.invalid("Invalid update state") }
    return state
}
func replaceBinary(_ source: URL, destination: String) throws {
    // Only fixed system destinations are allowed; never install archive paths.
    guard binaries.values.contains(destination) else { throw UpdateError.invalid("Unexpected destination") }
    let parent = URL(fileURLWithPath: destination).deletingLastPathComponent()
    var info = stat()
    guard lstat(parent.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == 0,
          (info.st_mode & 0o022) == 0 else { throw UpdateError.invalid("Unsafe binary directory") }
    let bytes = try readFile(source, limit: 20_000_000)
    try durableWrite(bytes, to: URL(fileURLWithPath: destination), permissions: 0o755)
}
func servicePID(_ service: String) -> Int32? {
    guard let text = try? execute("/bin/launchctl", ["print", service]) else { return nil }
    for line in text.split(separator: "\n") {
        let fields = line.split(whereSeparator: { $0.isWhitespace })
        if fields.count == 3, fields[0] == "pid", fields[1] == "=", let pid = Int32(fields[2]), pid > 1 { return pid }
    }
    return nil
}
func monitors() throws -> [MonitorService] {
    let users = try execute("/usr/bin/dscl", [".", "-list", "/Users", "UniqueID"])
    var result: [MonitorService] = []
    for line in users.split(separator: "\n") {
        let fields = line.split(whereSeparator: { $0.isWhitespace })
        guard fields.count == 2, let uid = UInt32(fields[1]), uid >= 501,
              let user = getpwnam(String(fields[0])), user.pointee.pw_uid == uid else { continue }
        let home = String(cString: user.pointee.pw_dir)
        let service = "gui/\(uid)/com.side-forge.orbit.foreground"
        guard servicePID(service) != nil,
              let data = try? readFile(URL(fileURLWithPath: home + "/Library/LaunchAgents/com.side-forge.orbit.foreground.plist"), owner: uid),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              (plist["ProgramArguments"] as? [String])?.first == binaries["monitor"] else { continue }
        result.append(MonitorService(uid: uid, home: home))
    }
    return result
}
func restart(_ services: [MonitorService]) throws {
    try execute("/bin/launchctl", ["kickstart", "-k", "system/com.side-forge.orbit.agent"])
    for monitor in services {
        let service = "gui/\(monitor.uid)/com.side-forge.orbit.foreground"
        // A user may log out while downloading. Their next login uses the new binary.
        if (try? execute("/bin/launchctl", ["print", service])) != nil {
            try execute("/bin/launchctl", ["kickstart", "-k", service])
        }
    }
}
func cleanup(_ transaction: URL) throws {
    try FileManager.default.removeItem(at: transaction)
    try syncPath(transaction.deletingLastPathComponent().path)
}
// Recovery ordering is independently testable without root or live services.
func recoverTransaction(_ journal: Journal, state: inout UpdateState,
                        restore: (String) throws -> Void,
                        restartServices: ([MonitorService]) throws -> Void,
                        persist: (UpdateState) throws -> Void,
                        removeJournal: () throws -> Void) throws {
    if state.sequence == journal.sequence { try removeJournal(); return }
    for name in binaries.keys.sorted() { try restore(name) }
    try restartServices(journal.monitors)
    var recovered = state; recovered.failedSequence = journal.sequence
    try persist(recovered); state = recovered
    try removeJournal()
}
func recover(root: URL, state: inout UpdateState, restartServices: ([MonitorService]) throws -> Void = restart) throws {
    let transaction = root.appendingPathComponent("transaction")
    var info = stat()
    guard lstat(transaction.path, &info) == 0 else {
        if errno == ENOENT { return }; throw UpdateError.invalid("Cannot inspect transaction")
    }
    try secureDirectory(transaction)
    let journalURL = transaction.appendingPathComponent("journal.json")
    if !FileManager.default.fileExists(atPath: journalURL.path) {
        // No binary may be touched until a complete journal is durable.
        try cleanup(transaction); return
    }
    let journal = try load(Journal.self, journalURL)
    try recoverTransaction(journal, state: &state,
        restore: { name in try replaceBinary(transaction.appendingPathComponent(name + ".old"), destination: binaries[name]!) },
        restartServices: restartServices,
        persist: { try save($0, to: root.appendingPathComponent("state.json")) },
        removeJournal: { try cleanup(transaction) })
}
func validReceipt(_ data: Data, pid: Int32, version: String, since: Date, now: Date = Date()) -> Bool {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          object["pid"] as? Int32 == pid, object["version"] as? String == version,
          let timestamp = object["at"] as? Double, timestamp >= since.timeIntervalSince1970,
          timestamp <= now.timeIntervalSince1970 + 5 else { return false }
    return true
}
func healthy(version: String, since: Date, services: [MonitorService]) -> Bool {
    func receipt(_ path: String, owner: uid_t, pid: Int32?) -> Bool {
        guard let pid = pid, let data = try? readFile(URL(fileURLWithPath: path), owner: owner) else { return false }
        return validReceipt(data, pid: pid, version: version, since: since)
    }
    guard receipt("/Library/Application Support/Orbit/health.json", owner: 0,
                  pid: servicePID("system/com.side-forge.orbit.agent")) else { return false }
    for monitor in services {
        let service = "gui/\(monitor.uid)/com.side-forge.orbit.foreground"
        if (try? execute("/bin/launchctl", ["print", service])) == nil { continue }
        guard receipt(monitor.home + "/Library/Application Support/Orbit/monitor-health.json", owner: monitor.uid, pid: servicePID(service)) else { return false }
    }
    return true
}
func activateUpdate(install: () throws -> Void, restartServices: () throws -> Void,
                    checkHealth: () throws -> Bool, commit: () throws -> Void,
                    rollback: () throws -> Void) throws {
    do {
        try install(); try restartServices()
        guard try checkHealth() else { throw UpdateError.invalid("New services did not report successful uploads") }
        try commit()
    } catch {
        try rollback()
        throw error
    }
}

func configureUpdater() throws {
    guard geteuid() == 0 else { throw UpdateError.invalid("Updater setup requires root") }
    umask(0o077); try secureDirectory(updateRoot)
    let destination = updateRoot.appendingPathComponent("config.json")
    var info = stat()
    if lstat(destination.path, &info) != 0 {
        guard errno == ENOENT else { throw UpdateError.invalid("Cannot inspect updater configuration") }
        let bootstrap = try readFile(URL(fileURLWithPath: "/usr/local/share/orbit/update-bootstrap.json"))
        let candidate = try JSONDecoder().decode(UpdateConfig.self, from: bootstrap)
        if candidate.enabled {
            guard let key = Data(base64Encoded: candidate.publicKey), key.count == 32 else { throw UpdateError.invalid("Invalid public key") }
            let url = try httpsURL(candidate.manifestURL)
            guard URLComponents(url: url, resolvingAgainstBaseURL: false)?.query == nil else { throw UpdateError.invalid("Manifest URL cannot have a query") }
        }
        try durableWrite(bootstrap, to: destination)
    }
    let config = try load(UpdateConfig.self, destination)
    if config.enabled {
        guard let key = Data(base64Encoded: config.publicKey), key.count == 32 else { throw UpdateError.invalid("Invalid pinned key") }
        _ = try httpsURL(config.manifestURL)
        print("enabled")
    } else { print("disabled") }
}

func runUpdate(recoveryOnly: Bool) throws {
    guard geteuid() == 0 else { throw UpdateError.invalid("Updater requires root") }
    umask(0o077); try secureDirectory(updateRoot)
    let lock = open(updateRoot.appendingPathComponent("lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
    guard lock >= 0 else { throw UpdateError.invalid("Cannot open updater lock") }
    defer { close(lock) }
    guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw UpdateError.invalid("Another updater is running") }
    var state = try optionalState(updateRoot)
    try recover(root: updateRoot, state: &state)
    if recoveryOnly { return }
    let config = try load(UpdateConfig.self, updateRoot.appendingPathComponent("config.json"))
    guard config.enabled else { print("Automatic updates disabled"); return }
    let baseline = try load(Installed.self, URL(fileURLWithPath: "/usr/local/share/orbit/installed-version.json"))
    let feed = try httpsURL(config.manifestURL)
    let manifest = try verifiedManifest(Download.get(feed, limit: 16384),
        signature: Download.get(try httpsURL(config.manifestURL + ".sig"), limit: 64), publicKey: config.publicKey)
    guard newer(manifest, state: state, baseline: baseline.sequence) else { print("No newer eligible update"); return }
    let transaction = updateRoot.appendingPathComponent("transaction")
    try secureDirectory(transaction)
    for name in binaries.keys.sorted() {
        let artifact = manifest.artifacts[name]!
        let bytes = try Download.get(try httpsURL(artifact.url), limit: artifact.size)
        try verifyArtifact(bytes, artifact)
        let target = transaction.appendingPathComponent(name + ".new")
        try durableWrite(bytes, to: target, permissions: 0o755)
        try execute("/usr/bin/codesign", ["--verify", "--strict", target.path])
        try execute("/usr/bin/lipo", [target.path, "-verify_arch", "arm64", "x86_64"])
        let old = try readFile(URL(fileURLWithPath: binaries[name]!), limit: 20_000_000)
        try durableWrite(old, to: transaction.appendingPathComponent(name + ".old"), permissions: 0o755)
    }
    let services = try monitors()
    try save(Journal(sequence: manifest.sequence, version: manifest.version, monitors: services), to: transaction.appendingPathComponent("journal.json"))
    let started = Date()
    try activateUpdate(install: {
        for name in binaries.keys.sorted() { try replaceBinary(transaction.appendingPathComponent(name + ".new"), destination: binaries[name]!) }
    }, restartServices: { try restart(services) }, checkHealth: {
        for _ in 0..<90 {
            if healthy(version: manifest.version, since: started, services: services) { return true }
            Thread.sleep(forTimeInterval: 2)
        }
        return false
    }, commit: {
        let accepted = UpdateState(sequence: manifest.sequence, failedSequence: 0, version: manifest.version)
        try save(accepted, to: updateRoot.appendingPathComponent("state.json"))
        state = accepted
        try cleanup(transaction)
    }, rollback: {
        // Atomic state replacement can succeed before a subsequent sync/cleanup
        // error. Read the durable commit marker before deciding to roll back.
        state = try optionalState(updateRoot)
        try recover(root: updateRoot, state: &state)
    })
    print("Updated agent and monitor to \(manifest.version)")
}

// CLI deliberately exposes no arbitrary installation path or untrusted root override.
if CommandLine.arguments.count == 2 && CommandLine.arguments[1] == "--setup" {
    do { try configureUpdater() } catch { fputs("Orbit updater setup: \(error)\n", stderr); exit(1) }
} else if CommandLine.arguments.count == 2 && ["--once", "--recover-only"].contains(CommandLine.arguments[1]) {
    do { try runUpdate(recoveryOnly: CommandLine.arguments[1] == "--recover-only") }
    catch { fputs("Orbit updater: \(error)\n", stderr); exit(1) }
} else { fputs("Usage: orbit-updater --once | --recover-only\n", stderr); exit(1) }
