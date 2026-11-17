import Foundation

// Pure event accounting; no GUI session required to test this state machine.
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
    private(set) var lastTransition: Date?

    mutating func activate(bundleId: String, appName: String, at time: Date) {
        guard !bundleId.isEmpty, !appName.isEmpty,
              time.timeIntervalSince1970.isFinite,
              lastTransition.map({ time >= $0 }) ?? true else { return }
        if current?.bundleId == bundleId { return }
        close(at: time)
        current = (bundleId, appName, time)
        lastTransition = time
    }

    mutating func suspend(at time: Date) {
        guard time.timeIntervalSince1970.isFinite,
              lastTransition.map({ time >= $0 }) ?? true else { return }
        close(at: time)
        lastTransition = time
    }

    mutating func drain() -> [FocusEvent] {
        let events = completed
        completed.removeAll(keepingCapacity: true)
        return events
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

