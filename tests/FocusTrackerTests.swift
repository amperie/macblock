import Foundation
@main struct FocusTrackerTests {
 static func main() {

func check(_ value: @autoclosure () -> Bool, _ message: String) {
    guard value() else { fatalError(message) }
}
let start = Date(timeIntervalSince1970: 1_700_000_000)
var tracker = FocusTracker()
tracker.activate(bundleId: "com.roblox.RobloxPlayer", appName: "Roblox", at: start)
tracker.activate(bundleId: "com.roblox.RobloxPlayer", appName: "Roblox", at: start.addingTimeInterval(5))
check(tracker.completed.isEmpty, "duplicate activation must not split session")
tracker.activate(bundleId: "com.apple.Safari", appName: "Safari", at: start.addingTimeInterval(60))
check(tracker.completed.count == 1, "switch must close prior session")
check(tracker.completed[0].endedAt.timeIntervalSince(tracker.completed[0].startedAt) == 60, "duration mismatch")
tracker.activate(bundleId: "com.roblox.RobloxPlayer", appName: "Roblox", at: start.addingTimeInterval(30))
check(tracker.current?.bundleId == "com.apple.Safari", "out-of-order activation must be rejected")
tracker.suspend(at: start.addingTimeInterval(20))
check(tracker.current?.bundleId == "com.apple.Safari", "out-of-order suspension must be rejected")
tracker.suspend(at: start.addingTimeInterval(90))
tracker.suspend(at: start.addingTimeInterval(100))
check(tracker.completed.count == 2, "suspend must be idempotent")
check(tracker.current == nil, "suspend must clear focus")
let events = tracker.drain()
check(events.count == 2 && tracker.completed.isEmpty, "drain must clear buffer")
check(Set(events.map(\.eventId)).count == 2, "events need distinct IDs")
tracker.activate(bundleId: "", appName: "invalid", at: start.addingTimeInterval(110))
check(tracker.current == nil, "invalid bundle ID must be ignored")
print("Foreground tracker state-machine tests passed")

 }
}
