import Foundation
import FamilyControls
import DeviceActivity
import ManagedSettings

struct PhoneEnforcement {
    let storage = SharedStore()
    let center = DeviceActivityCenter()
    let shields = ManagedSettingsStore(named: .init("orbit.phone"))

    func refreshShields() throws {
        // Keep the snapshot read and the shield write in the same coordinated transaction.
        // Otherwise the app can clear a shield immediately after a quota callback set it.
        try storage.update { state in
            shields.shield.applications = state?.shouldShield == true ? state?.selection.applicationTokens : nil
        }
    }

    func apply(_ policy: PhonePolicy, selection: FamilyActivitySelection) throws {
        guard AuthorizationCenter.shared.authorizationStatus == .approved else { throw OrbitFailure.authorizationRequired }
        guard !selection.applicationTokens.isEmpty else { throw OrbitFailure.emptySelection }
        guard selection.applicationTokens.count <= 50, selection.categoryTokens.isEmpty,
              selection.webDomainTokens.isEmpty else { throw OrbitFailure.unsupportedSelection }
        let generation = UUID().uuidString
        let activity = DeviceActivityName("orbit.daily." + generation)
        var previous: PhoneState?
        var unchanged = false
        var registrationAttempted = false
        do {
            try storage.update { current in
                // Read the previous quota latch under the write lock, not before obtaining it.
                previous = current
                try policy.validate(previous: current?.policy)
                if let current, current.policy == policy, current.selection == selection,
                   policy.dailyMinutes == nil || center.activities.contains(.init(current.activityName)) {
                    unchanged = true
                    return
                }
                if let minutes = policy.dailyMinutes {
                    let zone = TimeZone(identifier: policy.timeZone)!
                    let schedule = DeviceActivitySchedule(
                        intervalStart: DateComponents(timeZone: zone, hour: 0, minute: 0),
                        intervalEnd: DateComponents(timeZone: zone, hour: 23, minute: 59, second: 59), repeats: true)
                    let event = DeviceActivityEvent(applications: selection.applicationTokens,
                        threshold: DateComponents(minute: minutes), includesPastActivity: true)
                    registrationAttempted = true
                    // The extension also obtains this lock. An immediate callback waits until
                    // the registered policy is persisted, rather than seeing an old generation.
                    try center.startMonitoring(activity, during: schedule, events: [.init(generation): event])
                }
                let retainedDay = current.flatMap {
                    policy.inheritedExceededDay(from: $0.policy, exceededDay: $0.exceededDay,
                                                sameSelection: $0.selection == selection)
                }
                current = PhoneState(policy: policy, selection: selection, generation: generation,
                                     exceededDay: retainedDay, updatedAt: Date())
            }
            try refreshShields()
        } catch {
            if registrationAttempted { center.stopMonitoring([activity]) }
            try storage.update { current in
                // A registration/write failure may leave the old snapshot untouched. Do not
                // replace its newer callback state with the copy captured before the failure.
                guard let installed = current, installed.generation == generation else { return }
                var restored = previous
                if let old = restored {
                    let reached = old.policy.inheritedExceededDay(from: installed.policy,
                        exceededDay: installed.exceededDay, sameSelection: old.selection == installed.selection)
                    if let reached { restored?.exceededDay = reached }
                }
                current = restored
            }
            try refreshShields()
            throw error
        }
        guard !unchanged else { return }
        if let previous { center.stopMonitoring([.init(previous.activityName)]) }
        let obsolete = center.activities.filter { $0.rawValue.hasPrefix("orbit.daily.") && $0 != activity }
        if !obsolete.isEmpty { center.stopMonitoring(obsolete) }
    }
}
