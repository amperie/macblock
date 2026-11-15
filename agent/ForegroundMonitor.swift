import AppKit
import Foundation
import IOKit

// Runs in the logged-in user's GUI session. Activity token can upload telemetry
// only; it cannot fetch policies or change blocking rules.
struct MonitorSettings: Decodable {
    let serverURL: String
    let activityToken: String
}
struct Upload: Encodable { let events: [FocusEvent]; let current: Current? }
struct Current: Encodable { let bundleId: String; let appName: String; let since: Date }

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

    init(settings: MonitorSettings, queueURL: URL) throws {
        self.settings = settings
        self.queueURL = queueURL
        if let data = try? Data(contentsOf: queueURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            pending = (try? decoder.decode([FocusEvent].self, from: data)) ?? []
        }
        guard let url = URL(string: settings.serverURL), url.scheme == "https",
              url.host != nil, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, settings.activityToken.count >= 32
        else { throw NSError(domain: "MacBlock", code: 1) }
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
        recordFrontmost()
        Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.tick() }
    }

    @objc private func activated(_ notification: Notification) { recordFrontmost() }
    @objc private func suspended(_ notification: Notification) { tracker.suspend(at: Date()); flush() }
    @objc private func resumed(_ notification: Notification) { idle = false; recordFrontmost() }

    private func recordFrontmost() {
        guard !idle, let app = NSWorkspace.shared.frontmostApplication,
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
        guard let url = URL(string: settings.serverURL + "/api/device/activity") else { return }
        let current = tracker.current.map { Current(bundleId: $0.bundleId, appName: $0.appName, since: $0.startedAt) }
        guard !uploading else { return }
        let payload = Upload(events: Array(pending.prefix(100)), current: current)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let body = try? encoder.encode(payload) else { return }
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
        let home = FileManager.default.homeDirectoryForCurrentUser
        let directory = home.appendingPathComponent("Library/Application Support/MacBlock", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let settingsURL = directory.appendingPathComponent("monitor-settings.json")
            let settings = try JSONDecoder().decode(MonitorSettings.self, from: Data(contentsOf: settingsURL))
            let monitor = try ForegroundMonitor(settings: settings, queueURL: directory.appendingPathComponent("activity-queue.json"))
            monitor.start()
            RunLoop.main.run()
        } catch {
            fputs("MacBlock monitor setup failed: \\(error)\\n", stderr)
            exit(1)
        }
    }
}
