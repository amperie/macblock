import Foundation
import CryptoKit
import Darwin

enum UpdateError: Error { case invalid(String) }
struct CommandFailure: Error, CustomStringConvertible {
    let path: String; let status: Int32; let diagnostic: String
    // Diagnostics are inspected locally but never copied wholesale into logs.
    var description: String { "Command failed: \(path) (\(status))" }
}
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
struct UpdateConfig: Codable {
    let enabled: Bool; let publicKey: String; let manifestURL: String
    func validate() throws {
        guard enabled else { return }
        guard let key = Data(base64Encoded: publicKey), key.count == 32 else { throw UpdateError.invalid("Invalid pinned public key") }
        let url = try httpsURL(manifestURL)
        guard URLComponents(url: url, resolvingAgainstBaseURL: false)?.query == nil else { throw UpdateError.invalid("Manifest URL cannot have a query") }
    }
}
struct Installed: Codable { let version: String; let sequence: Int }
struct UpdateState: Codable { var sequence = 0; var failedSequence = 0; var version = "unknown" }
struct MonitorService: Codable { let uid: UInt32; let home: String }
struct Journal: Codable {
    let sequence: Int; let version: String; let monitors: [MonitorService]
    var backupHashes: [String: String]? = nil
}

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
func execute(_ path: String, _ arguments: [String], timeout: TimeInterval = 15, outputLimit: Int = 1_048_576) throws -> String {
    guard timeout > 0, timeout.isFinite, outputLimit > 0 else { throw UpdateError.invalid("Invalid command bounds") }
    let process = Process(); process.executableURL = URL(fileURLWithPath: path); process.arguments = arguments
    process.standardInput = FileHandle.nullDevice
    let output = Pipe(); process.standardOutput = output; process.standardError = output
    let fd = output.fileHandleForReading.fileDescriptor
    guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { throw UpdateError.invalid("Cannot configure command output") }
    try process.run()
    output.fileHandleForWriting.closeFile()
    defer { output.fileHandleForReading.closeFile() }
    func stop() {
        guard process.isRunning else { return }
        process.terminate()
        let grace = ProcessInfo.processInfo.systemUptime + 0.25
        while process.isRunning && ProcessInfo.processInfo.systemUptime < grace { usleep(10_000) }
        if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
    }
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    var data = Data(); var buffer = [UInt8](repeating: 0, count: 8192); var eof = false
    do {
        while true {
            if ProcessInfo.processInfo.systemUptime >= deadline { throw UpdateError.invalid("Command timed out: \(path)") }
            let count = read(fd, &buffer, buffer.count)
            if count > 0 {
                guard data.count <= outputLimit - count else { throw UpdateError.invalid("Command output limit exceeded") }
                data.append(contentsOf: buffer.prefix(count))
            } else if count == 0 { eof = true }
            else if errno != EAGAIN && errno != EINTR { throw UpdateError.invalid("Cannot read command output") }
            if eof && !process.isRunning { break }
            if count <= 0 { usleep(10_000) }
        }
    } catch { stop(); throw error }
    guard process.terminationStatus == 0 else { throw CommandFailure(path:path, status:process.terminationStatus, diagnostic:String(decoding:data, as:UTF8.self)) }
    return String(decoding: data, as: UTF8.self)
}

func directoryInfo(_ path: String) throws -> (mode_t, uid_t) {
    var info = stat()
    guard lstat(path, &info) == 0 else { throw UpdateError.invalid("Cannot inspect privileged ancestor") }
    return (info.st_mode, info.st_uid)
}
func validateRootAncestors(_ directory: URL, inspect: (String) throws -> (mode_t, uid_t) = directoryInfo) throws {
    var directory = directory.standardizedFileURL
    var paths: [String] = []
    while true {
        paths.append(directory.path)
        if directory.path == "/" { break }
        directory.deleteLastPathComponent()
    }
    for path in paths.reversed() {
        let (mode, owner) = try inspect(path)
        guard (mode & S_IFMT) == S_IFDIR, owner == 0, (mode & 0o022) == 0 else {
            throw UpdateError.invalid("Unsafe privileged ancestor: \(path)")
        }
    }
}
func secureDirectory(_ url: URL, owner: uid_t = 0) throws {
    if owner == 0 { try validateRootAncestors(url.deletingLastPathComponent()) }
    var info = stat()
    if lstat(url.path, &info) != 0 {
        guard errno == ENOENT else { throw UpdateError.invalid("Cannot inspect directory") }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        guard lstat(url.path, &info) == 0 else { throw UpdateError.invalid("Cannot inspect new directory") }
    }
    guard (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == owner, (info.st_mode & 0o077) == 0 else { throw UpdateError.invalid("Unsafe update directory") }
    // Persist the directory entry in its parent too. Syncing journal.json and
    // transaction/ alone cannot guarantee recovery if transaction/ itself is
    // lost from the parent directory after a power interruption.
    try syncPath(url.path)
    try syncPath(url.deletingLastPathComponent().path)
}
func readFile(_ url: URL, limit: Int = 16384, owner: uid_t = 0) throws -> Data {
    if owner == 0 { try validateRootAncestors(url.deletingLastPathComponent()) }
    let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
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
    let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw UpdateError.invalid("Cannot open for sync") }
    defer { close(fd) }
    guard fsync(fd) == 0 else { throw UpdateError.invalid("Cannot sync update") }
    var info = stat()
    guard fstat(fd, &info) == 0 else { throw UpdateError.invalid("Cannot inspect sync target") }
    if (info.st_mode & S_IFMT) == S_IFREG {
        guard fcntl(fd, F_FULLFSYNC) == 0 else { throw UpdateError.invalid("Cannot flush update to durable storage") }
    }
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
func replaceBinary(_ source: URL, destination: String, expected: Artifact? = nil) throws {
    // Only fixed system destinations are allowed; never install archive paths.
    guard binaries.values.contains(destination) else { throw UpdateError.invalid("Unexpected destination") }
    let parent = URL(fileURLWithPath: destination).deletingLastPathComponent()
    try validateRootAncestors(parent)
    let bytes = try readFile(source, limit: 20_000_000)
    if let expected = expected { try verifyArtifact(bytes, expected) }
    try durableWrite(bytes, to: URL(fileURLWithPath: destination), permissions: 0o755)
}
func launchdService(_ service: String, run: (String, [String]) throws -> String = { try execute($0, $1) }) throws -> String? {
    do { return try run("/bin/launchctl", ["print", service]) }
    catch let error as CommandFailure {
        // A missing GUI domain/service can mean logout. Timeout, permission,
        // and other probe failures must not silently bypass monitor health.
        if error.path == "/bin/launchctl" && (error.diagnostic.contains("Could not find service") || error.diagnostic.contains("Could not find domain")) { return nil }
        throw error
    }
}
func servicePID(_ service: String) -> Int32? {
    guard let text = try? launchdService(service) else { return nil }
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
        guard try launchdService(service) != nil,
              let data = try? readFile(URL(fileURLWithPath: home + "/Library/LaunchAgents/com.side-forge.orbit.foreground.plist"), owner: uid),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              (plist["ProgramArguments"] as? [String])?.first == binaries["monitor"] else { continue }
        result.append(MonitorService(uid: uid, home: home))
    }
    return result
}
func mergeMonitorServices(_ original: [MonitorService], _ current: [MonitorService]) -> [MonitorService] {
    var byUID: [UInt32: MonitorService] = [:]
    for monitor in original + current { byUID[monitor.uid] = monitor }
    return byUID.values.sorted { $0.uid < $1.uid }
}
func restart(_ services: [MonitorService]) throws {
    try execute("/bin/launchctl", ["kickstart", "-k", "system/com.side-forge.orbit.agent"])
    for monitor in mergeMonitorServices(services, try monitors()) {
        let service = "gui/\(monitor.uid)/com.side-forge.orbit.foreground"
        // A user may log out while downloading. Their next login uses the new binary.
        if try launchdService(service) != nil {
            try execute("/bin/launchctl", ["kickstart", "-k", service])
        }
    }
}
func cleanup(_ transaction: URL) throws {
    try FileManager.default.removeItem(at: transaction)
    try syncPath(transaction.deletingLastPathComponent().path)
}
// Recovery ordering is independently testable without root or live services.
func validateBackupHashes(_ journal: Journal, readBackup: (String) throws -> Data) throws {
    guard let hashes = journal.backupHashes, Set(hashes.keys) == Set(binaries.keys) else {
        throw UpdateError.invalid("Recovery journal has no complete backup hashes; recover with the previous updater before upgrading")
    }
    // Validate the complete pair before restoring either destination.
    for name in binaries.keys.sorted() {
        let hash = SHA256.hash(data: try readBackup(name)).map { String(format:"%02x",$0) }.joined()
        guard hashes[name] == hash else { throw UpdateError.invalid("Rollback backup is corrupt") }
    }
}
func recoverTransaction(_ journal: Journal, state: inout UpdateState,
                        validateBackups: () throws -> Void = {},
                        restore: (String) throws -> Void,
                        restartServices: ([MonitorService]) throws -> Void,
                        persist: (UpdateState) throws -> Void,
                        removeJournal: () throws -> Void) throws {
    if state.sequence == journal.sequence || (state.sequence < journal.sequence && state.failedSequence == journal.sequence) {
        // Both successful installation and completed rollback are durable commit
        // markers. Cleanup may have already deleted some backup files.
        try removeJournal(); return
    }
    guard state.sequence < journal.sequence else { throw UpdateError.invalid("Stale journal would roll back an accepted release") }
    try validateBackups()
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
        validateBackups: { try validateBackupHashes(journal) { name in
            try readFile(transaction.appendingPathComponent(name + ".old"), limit:20_000_000)
        } },
        restore: { name in try replaceBinary(transaction.appendingPathComponent(name + ".old"), destination: binaries[name]!) },
        restartServices: restartServices,
        persist: { try save($0, to: root.appendingPathComponent("state.json")) },
        removeJournal: { try cleanup(transaction) })
}
func validReceipt(_ data: Data, pid: Int32, version: String, since: Date, now: Date = Date()) -> Bool {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          object["pid"] as? Int32 == pid, object["version"] as? String == version,
          let timestamp = object["at"] as? Double, timestamp >= since.timeIntervalSince1970,
          timestamp <= now.timeIntervalSince1970 + 5,
          now.timeIntervalSince1970 - timestamp <= 120 else { return false }
    return true
}
struct StableHealth {
    private var fingerprint: [String: Int32]?
    private var since: TimeInterval?
    private var lastSample: TimeInterval?
    mutating func observe(_ sample: [String: Int32]?, at now: TimeInterval) -> Bool {
        guard now.isFinite, let sample = sample, !sample.isEmpty,
              sample.values.allSatisfy({ $0 > 1 }) else {
            fingerprint = nil; since = nil; lastSample = nil; return false
        }
        if fingerprint != sample || lastSample.map({ now < $0 || now - $0 > 10 }) == true {
            fingerprint = sample; since = now
        }
        lastSample = now
        return since.map { now - $0 >= 15 } ?? false
    }
}
func healthSnapshot(version: String, since: Date, services: [MonitorService]) -> [String: Int32]? {
    func receipt(_ path: String, owner: uid_t, pid: Int32) -> Bool {
        guard let data = try? readFile(URL(fileURLWithPath: path), owner: owner) else { return false }
        return validReceipt(data, pid: pid, version: version, since: since)
    }
    guard let daemonPID = servicePID("system/com.side-forge.orbit.agent"),
          receipt("/Library/Application Support/Orbit/health.json", owner: 0, pid: daemonPID) else { return nil }
    var result = ["agent": daemonPID]
    let activeMonitors: [MonitorService]
    do { activeMonitors = try monitors() } catch { return nil }
    for monitor in mergeMonitorServices(services, activeMonitors) {
        let service = "gui/\(monitor.uid)/com.side-forge.orbit.foreground"
        do {
            if try launchdService(service) == nil { continue }
        } catch { return nil }
        guard let pid = servicePID(service),
              receipt(monitor.home + "/Library/Application Support/Orbit/monitor-health.json", owner: monitor.uid, pid: pid) else { return nil }
        result["monitor-\(monitor.uid)"] = pid
    }
    return result
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
        let bootstrap = try readFile(URL(fileURLWithPath: "/Library/Application Support/OrbitUpdates/bootstrap/update-bootstrap.json"))
        let candidate = try JSONDecoder().decode(UpdateConfig.self, from: bootstrap)
        try candidate.validate()
        try durableWrite(bootstrap, to: destination)
    }
    let config = try load(UpdateConfig.self, destination)
    try config.validate()
    print(config.enabled ? "enabled" : "disabled")
}

func acquireUpdateLock(_ url: URL, owner: uid_t = 0) throws -> Int32 {
    let fd = open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw UpdateError.invalid("Cannot open updater lock") }
    var info = stat()
    guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
          info.st_uid == owner, info.st_nlink == 1, (info.st_mode & 0o077) == 0 else {
        close(fd); throw UpdateError.invalid("Unsafe updater lock")
    }
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
        close(fd); throw UpdateError.invalid("Another updater is running")
    }
    return fd
}

func transactionExists(_ root: URL) throws -> Bool {
    var info = stat()
    if lstat(root.appendingPathComponent("transaction").path, &info) == 0 { return true }
    guard errno == ENOENT else { throw UpdateError.invalid("Cannot inspect transaction") }
    return false
}
func stateForRun(root: URL, recoveryOnly: Bool, readState: () throws -> UpdateState) throws -> UpdateState? {
    // Uninstall/manual repair does not need anti-rollback metadata when there
    // is nothing to recover. Normal update checks must still reject bad state.
    if recoveryOnly, !(try transactionExists(root)) { return nil }
    return try readState()
}

func runUpdate(recoveryOnly: Bool) throws {
    guard geteuid() == 0 else { throw UpdateError.invalid("Updater requires root") }
    umask(0o077); try secureDirectory(updateRoot)
    // A helper must not retain our lock if the updater is interrupted.
    let lock = try acquireUpdateLock(updateRoot.appendingPathComponent("lock"))
    defer { close(lock) }
    guard var state = try stateForRun(root: updateRoot, recoveryOnly: recoveryOnly,
                                     readState: { try optionalState(updateRoot) }) else { return }
    try recover(root: updateRoot, state: &state)
    if recoveryOnly { return }
    let config = try load(UpdateConfig.self, updateRoot.appendingPathComponent("config.json"))
    guard config.enabled else { print("Automatic updates disabled"); return }
    try config.validate()
    let baseline = try load(Installed.self, URL(fileURLWithPath: "/Library/Application Support/OrbitUpdates/bootstrap/installed-version.json"))
    let feed = try httpsURL(config.manifestURL)
    let manifest = try verifiedManifest(Download.get(feed, limit: 16384),
        signature: Download.get(try httpsURL(config.manifestURL + ".sig"), limit: 64), publicKey: config.publicKey)
    guard newer(manifest, state: state, baseline: baseline.sequence) else { print("No newer eligible update"); return }
    let transaction = updateRoot.appendingPathComponent("transaction")
    try secureDirectory(transaction)
    var backupHashes: [String:String] = [:]
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
        backupHashes[name] = SHA256.hash(data: old).map { String(format:"%02x",$0) }.joined()
    }
    let services = try monitors()
    try save(Journal(sequence: manifest.sequence, version: manifest.version, monitors: services, backupHashes: backupHashes), to: transaction.appendingPathComponent("journal.json"))
    let started = Date()
    try activateUpdate(install: {
        for name in binaries.keys.sorted() { try replaceBinary(transaction.appendingPathComponent(name + ".new"), destination: binaries[name]!, expected: manifest.artifacts[name]) }
    }, restartServices: { try restart(services) }, checkHealth: {
        let deadline = ProcessInfo.processInfo.systemUptime + 180
        var stable = StableHealth()
        while ProcessInfo.processInfo.systemUptime < deadline {
            // Require successful uploads beyond the initial startup, so a
            // process that reports once and immediately crashes cannot commit.
            let snapshot = healthSnapshot(version: manifest.version, since: started.addingTimeInterval(15), services: services)
            let now = ProcessInfo.processInfo.systemUptime
            if now < deadline && stable.observe(snapshot, at: now) { return true }
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
