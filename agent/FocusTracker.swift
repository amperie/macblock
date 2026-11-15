import Foundation

// Pure foreground-session accounting. This file intentionally has no AppKit dependency,
// so the state machine can be exercised on hosted macOS runners without a GUI login.
struct FocusEvent: Codable, Equatable {
    let bundleId: String
    let appName: String
    let startedAt: Date
    let endedAt: Date
    let eventId: UUID
}

struct FocusTracker {
    private(set) var current: (bundleId: String, appName: String, startedAt: Date)?
    private(set) var completed: [FocusEvent] = []

    mutating func activate(bundleId: String, appName: String, at time: Date) {
        guard !bundleId.isEmpty, !appName.isEmpty else { return }
        if current?.bundleId == bundleId { return }
        close(at: time)
        current = (bundleId, appName, time)
    }

    mutating func suspend(at time: Date) {
        close(at: time)
    }

    private mutating func close(at time: Date) {
        guard let previous = current else { return }
        current = nil
        guard time > previous.startedAt else { return }
        completed.append(FocusEvent(bundleId: previous.bundleId,
                                    appName: previous.appName,
                                    startedAt: previous.startedAt,
                                    endedAt: time,
                                    eventId: UUID()))
    }
}

#if FOCUS_TRACKER_SELF_TEST
func check(_ value: @autoclosure () -> Bool, _ message: String) {
    guard value() else { fatalError(message) }
}
let start = Date(timeIntervalSince1970: 1_700_000_000)
var tracker = FocusTracker()
tracker.activate(bundleId: "com.roblox.RobloxPlayer", appName: "Roblox", at: start)
tracker.activate(bundleId: "com.roblox.RobloxPlayer", appName: "Roblox", at: start.addingTimeInterval(5))
check(tracker.completed.isEmpty, "duplicate activation should not split session")
tracker.activate(bundleId: "com.apple.Safari", appName: "Safari", at: start.addingTimeInterval(60))
check(tracker.completed.count == 1, "switch must close previous session")
check(tracker.completed[0].endedAt.timeIntervalSince(tracker.completed[0].startedAt) == 60, "duration mismatch")
tracker.suspend(at: start.addingTimeInterval(90))
tracker.suspend(at: start.addingTimeInterval(100))
check(tracker.completed.count == 2, "suspend must be idempotent")
check(tracker.current == nil, "suspend must clear focus")
print("Foreground tracker state-machine tests passed")
#endif
