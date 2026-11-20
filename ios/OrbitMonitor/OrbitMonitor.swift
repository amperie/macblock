import DeviceActivity
import Foundation

final class OrbitMonitor: DeviceActivityMonitor {
    private let enforcement = PhoneEnforcement()

    override func intervalDidStart(for activity: DeviceActivityName) {
        super.intervalDidStart(for: activity)
        do {
            try enforcement.storage.update { state in
                guard state?.activityName == activity.rawValue else { return }
                if state?.exceededDay != state?.policy.day() { state?.exceededDay = nil }
            }
            try enforcement.refreshShields()
        } catch {
            // Preserve existing shields on storage errors; do not log private selections.
        }
    }

    override func eventDidReachThreshold(_ event: DeviceActivityEvent.Name, activity: DeviceActivityName) {
        super.eventDidReachThreshold(event, activity: activity)
        do {
            try enforcement.storage.update { state in
                guard state?.activityName == activity.rawValue, state?.generation == event.rawValue else { return }
                let day = state?.policy.day()
                state?.exceededDay = day
            }
            try enforcement.refreshShields()
        } catch {
            // Existing shields remain in place if the shared snapshot cannot be read.
        }
    }
}
