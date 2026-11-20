import Foundation

enum OrbitFailure: LocalizedError {
    case invalidPolicy, invalidCredential, setupUnconfirmed, saveUnconfirmed, stalePolicy, unavailableStorage, authorizationRequired, emptySelection, unsupportedSelection, insecureServer, credentialStorage, invalidResponse
    var errorDescription: String? {
        switch self {
        case .setupUnconfirmed: return "Setup could not be confirmed. The code may already have been used. Generate a new code on the website and try again; revoke any unused iPhone enrollment listed there."
        case .saveUnconfirmed: return "Save could not be confirmed. Discard edits and sync before retrying; the server may already have saved the change."
        case .invalidCredential: return "Use a 32–512 character credential containing printable ASCII characters without spaces."
        case .invalidPolicy: return "The iPhone policy is invalid."
        case .stalePolicy: return "The server returned an older or conflicting policy. Existing restrictions were kept."
        case .unavailableStorage: return "Shared storage is unavailable. Check the App Group on both targets."
        case .authorizationRequired: return "Authorize Screen Time before applying restrictions."
        case .emptySelection: return "Choose at least one app."
        case .unsupportedSelection: return "Choose up to 50 individual apps. Categories and websites are not supported yet."
        case .insecureServer: return "Use an HTTPS server origin without a path, query, or embedded credentials."
        case .credentialStorage: return "Credentials could not be saved in Keychain."
        case .invalidResponse: return "The server response is invalid."
        }
    }
}

struct PhonePolicy: Codable, Equatable {
    var schemaVersion = 1
    var revision = 1
    var blocked = false
    var dailyMinutes: Int?
    var timeZone = "America/Los_Angeles"

    private enum CodingKeys: String, CodingKey { case schemaVersion, revision, blocked, dailyMinutes, timeZone }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(schemaVersion, forKey: .schemaVersion)
        try values.encode(revision, forKey: .revision)
        try values.encode(blocked, forKey: .blocked)
        try values.encode(dailyMinutes, forKey: .dailyMinutes) // Encode explicit null for the strict server schema.
        try values.encode(timeZone, forKey: .timeZone)
    }

    func validate(previous: PhonePolicy? = nil) throws {
        guard schemaVersion == 1, revision > 0, revision < 9_007_199_254_740_992,
              TimeZone(identifier: timeZone) != nil,
              dailyMinutes.map({ (1...1440).contains($0) }) ?? true else { throw OrbitFailure.invalidPolicy }
        if let previous {
            guard revision >= previous.revision, revision != previous.revision || self == previous else {
                throw OrbitFailure.stalePolicy
            }
        }
    }

    func hasSameRules(as other: PhonePolicy) -> Bool {
        schemaVersion == other.schemaVersion && blocked == other.blocked &&
            dailyMinutes == other.dailyMinutes && timeZone == other.timeZone
    }

    func day(at date: Date = Date()) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZone) ?? TimeZone(secondsFromGMT: 0)!
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    func shouldShield(exceededDay: String?, at date: Date = Date()) -> Bool {
        blocked || (dailyMinutes != nil && exceededDay == day(at: date))
    }

    func inheritedExceededDay(from previous: PhonePolicy, exceededDay: String?, sameSelection: Bool) -> String? {
        guard sameSelection, preservesExceeded(from: previous) else { return nil }
        return exceededDay
    }

    func preservesExceeded(from previous: PhonePolicy) -> Bool {
        guard let old = previous.dailyMinutes, let new = dailyMinutes else { return false }
        return timeZone == previous.timeZone && new <= old
    }
}

struct PhoneConnection: Codable {
    static let defaultOrigin = URL(string: "https://orbit.side-forge.com")!
    var origin: URL
    var deviceToken: String
    var installationID: UUID
    var paired: Bool? = nil

    func replacingDeviceToken(_ value: String) throws -> PhoneConnection {
        var updated = self
        if !value.isEmpty { updated.deviceToken = value }
        try Self.validateCredential(updated.deviceToken)
        return updated
    }

    static func validateCredential(_ value: String) throws {
        guard (32...512).contains(value.utf8.count), value.utf8.allSatisfy({ (33...126).contains($0) }) else {
            throw OrbitFailure.invalidCredential
        }
    }

    static func serverURL(_ value: String) throws -> URL {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https", url.host != nil, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, url.path.isEmpty || url.path == "/" else { throw OrbitFailure.insecureServer }
        return url
    }
}
