import Foundation
import FamilyControls

struct PhoneState: Codable {
    var policy: PhonePolicy
    var selection: FamilyActivitySelection
    var generation: String
    var exceededDay: String?
    var updatedAt: Date

    var shouldShield: Bool { policy.shouldShield(exceededDay: exceededDay) }
    var activityName: String { "orbit.daily." + generation }
}

// App and monitor extension coordinate writes; tokens never leave this App Group.
final class SharedStore {
    private var file: URL {
        get throws {
            guard let group = Bundle.main.object(forInfoDictionaryKey: "OrbitAppGroup") as? String,
                  let directory = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
                throw OrbitFailure.unavailableStorage
            }
            return directory.appendingPathComponent("phone-state.json")
        }
    }

    func read() throws -> PhoneState? {
        let url = try file
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        // Atomic replacement means readers see an entire old or new snapshot.
        return try JSONDecoder().decode(PhoneState.self, from: Data(contentsOf: url))
    }

    @discardableResult
    func update(_ transform: (inout PhoneState?) throws -> Void) throws -> PhoneState? {
        let url = try file
        var coordinationError: NSError?
        var result: Result<PhoneState?, Error>?
        NSFileCoordinator().coordinate(writingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in
            result = Result {
                var state = try read()
                try transform(&state)
                if let state {
                    try JSONEncoder().encode(state).write(to: coordinatedURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                } else if FileManager.default.fileExists(atPath: coordinatedURL.path) {
                    try FileManager.default.removeItem(at: coordinatedURL)
                }
                return state
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw OrbitFailure.unavailableStorage }
        return try result.get()
    }
}
