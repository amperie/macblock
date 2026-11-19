import AppKit
import Foundation
import IOKit

// Runs in the logged-in user's GUI session. Activity token can upload telemetry
// only; it cannot fetch policies or change blocking rules.
private let monitorBuild = "__ORBIT_BUILD_VERSION__"
private let monitorVersion = monitorBuild.hasPrefix("__") ? "0.3.0-dev" : monitorBuild
struct MonitorSettings: Decodable {
    let serverURL: String
    let activityToken: String
    private enum CodingKeys: String, CodingKey { case serverURL, activityToken }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        serverURL = try values.decodeIfPresent(String.self, forKey: .serverURL) ?? "https://orbit.side-forge.com"
        activityToken = try values.decode(String.self, forKey: .activityToken)
    }
    func validate(development: Bool = false) throws {
        guard let url = URL(string: serverURL),
              url.scheme == "https" || (development && url.scheme == "http" && ["127.0.0.1", "localhost", "::1", "[::1]"].contains(url.host ?? "")),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, url.path.isEmpty || url.path == "/",
              (32...512).contains(activityToken.utf8.count),
              activityToken.utf8.allSatisfy({ (33...126).contains($0) })
        else { throw NSError(domain: "Orbit", code: 1) }
    }
}
struct Upload: Encodable {
    let events: [FocusEvent]
    let current: Current?
    private enum CodingKeys: String, CodingKey { case events, current }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(events, forKey: .events)
        // Synthesized encoding omits nil optionals, but the server requires an
        // explicit null to clear the current app on idle, lock, and sleep.
        try values.encode(current, forKey: .current)
    }
}
struct Current: Encodable { let bundleId: String; let appName: String; let since: Date }

func activityUpload(events: [FocusEvent], current: Current?) throws -> (Upload, Data) {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    var count = min(events.count, 100)
    while true {
        let payload = Upload(events: Array(events.prefix(count)), current: current)
        let body = try encoder.encode(payload)
        if body.count <= 65536 { return (payload, body) }
        guard count > 0 else { throw NSError(domain: "Orbit", code: 2) }
        count -= 1
    }
}

final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

final class ForegroundMonitor {
    private var tracker = FocusTracker()
    private let settings: MonitorSettings
    private let queueURL: URL
    private let redirectDelegate = NoRedirects()
    private lazy var session = URLSession(configuration: .ephemeral, delegate: redirectDelegate, delegateQueue: nil)
    private var pending: [FocusEvent] = []
    private var idle = false
    private var uploading = false
    private var suspended = false

    init(settings: MonitorSettings, queueURL: URL) throws {
        self.settings = settings
        self.queueURL = queueURL
        if let data = try? Data(contentsOf: queueURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            // Recover queues written by older monitors, including events whose
            // timestamps collapsed to the same second during serialization.
            pending = ((try? decoder.decode([FocusEvent].self, from: data)) ?? [])
                .filter { $0.hasReportableDuration }
        }
        let development = ProcessInfo.processInfo.environment["ORBIT_MONITOR_DEVELOPMENT"] == "1"
        try settings.validate(development: development)
    }

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(activated(_:)),
                           name: NSWorkspace.didActivateApplicationNotification, object: nil)
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            center.addObserver(self, selector: #selector(suspended(_:)), name: name, object: nil)
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            center.addObserver(self, selector: #selector(resumed(_:)), name: name, object: nil)
        }
        idle = idleSeconds() >= 300
        recordFrontmost()
        flush()
        print("[Orbit] App time tracker started (foreground apps; pauses after 5 minutes idle)")
        fflush(stdout)
        Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.tick() }
    }

    @objc private func activated(_ notification: Notification) { recordFrontmost() }
    @objc private func suspended(_ notification: Notification) {
        suspended = true
        tracker.suspend(at: Date())
        flush()
    }
    @objc private func resumed(_ notification: Notification) {
        suspended = false
        idle = false
        recordFrontmost()
        flush()
    }

    private func recordFrontmost() {
        guard !idle, !suspended, let app = NSWorkspace.shared.frontmostApplication,
              let id = app.bundleIdentifier, !id.isEmpty else { return }
        tracker.activate(bundleId: id, appName: app.localizedName ?? id, at: Date())
    }

    private func idleSeconds() -> Double {
        // HID idle time is in nanoseconds.
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        guard service != 0 else { return 0 }
        defer { IOObjectRelease(service) }
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = properties?.takeRetainedValue() as? [String: Any],
              let nanos = dict["HIDIdleTime"] as? NSNumber else { return 0 }
        return nanos.doubleValue / 1_000_000_000
    }

    private func tick() {
        if suspended { flush(); return }
        let now = Date()
        let isIdle = idleSeconds() >= 300
        if isIdle && !idle {
            // Approximate idle onset rather than charging all idle time.
            let onset = now.addingTimeInterval(-300)
            let boundary = max(onset, tracker.lastTransition ?? onset)
            tracker.suspend(at: boundary)
        } else if !isIdle && idle {
            idle = false
            recordFrontmost()
        }
        idle = isIdle
        if !idle { recordFrontmost() }
        flush()
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(pending) {
            try? data.write(to: queueURL, options: .atomic)
        }
    }

    private func flush() {
        pending.append(contentsOf: tracker.drain())
        // Cap local telemetry to bound storage during long outages.
        if pending.count > 10000 { pending.removeFirst(pending.count - 10000) }
        persist()
        let base = settings.serverURL.hasSuffix("/") ? String(settings.serverURL.dropLast()) : settings.serverURL
        guard let url = URL(string: base + "/api/device/activity") else { return }
        let current = (!suspended && !idle ? tracker.current : nil).map { Current(bundleId: $0.bundleId, appName: $0.appName, since: $0.startedAt) }
        guard !uploading else { return }
        // Long Unicode names can exceed the server's 64 KiB limit even with
        // fewer than 100 events. Acknowledge only the events actually sent.
        guard let (payload, body) = try? activityUpload(events: pending, current: current) else { return }
        uploading = true
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("Bearer " + settings.activityToken, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // A synchronous upload is avoided on the GUI run loop.
        session.dataTask(with: request) { [weak self] _, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.uploading = false
                guard error == nil, (response as? HTTPURLResponse)?.statusCode == 200 else { return }
                let receipt: [String: Any] = ["pid": getpid(), "version": monitorVersion, "at": Date().timeIntervalSince1970]
                if let data = try? JSONSerialization.data(withJSONObject: receipt) {
                    try? data.write(to: self.queueURL.deletingLastPathComponent().appendingPathComponent("monitor-health.json"), options: .atomic)
                }
                let ids = Set(payload.events.map(\.eventId))
                self.pending.removeAll { ids.contains($0.eventId) }
                self.persist()
            }
        }.resume()
    }
}

@main
struct MonitorMain {
    static func main() {
        umask(0o077)
        if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--check-settings" {
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
                try JSONDecoder().decode(MonitorSettings.self, from: data).validate()
                print("Valid monitor settings")
                return
            } catch {
                fputs("Invalid monitor settings.\n", stderr)
                exit(1)
            }
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let directory = home.appendingPathComponent("Library/Application Support/Orbit", isDirectory: true)
        do {
            let settingsURL = ProcessInfo.processInfo.environment["ORBIT_MONITOR_SETTINGS"].map { URL(fileURLWithPath: $0) } ?? directory.appendingPathComponent("monitor-settings.json")
            let settings = try JSONDecoder().decode(MonitorSettings.self, from: Data(contentsOf: settingsURL))
            let queueURL = ProcessInfo.processInfo.environment["ORBIT_MONITOR_QUEUE"].map { URL(fileURLWithPath: $0) } ?? directory.appendingPathComponent("activity-queue.json")
            try FileManager.default.createDirectory(at: queueURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let monitor = try ForegroundMonitor(settings: settings, queueURL: queueURL)
            monitor.start()
            withExtendedLifetime(monitor) { RunLoop.main.run() }
        } catch {
            fputs("Orbit monitor setup failed: \(error)\n", stderr)
            exit(1)
        }
    }
}
