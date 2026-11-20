import Foundation

@main
struct PolicyTests {
    static func rejects(_ work: () throws -> Void) {
        do { try work(); fatalError("Expected validation to reject this value") } catch { }
    }
    static func main() throws {
        let base = PhonePolicy()
        try base.validate()
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(base)) as! [String: Any]
        precondition(object["dailyMinutes"] is NSNull, "No daily limit must encode as explicit null for the server schema")
        let roundTrip = try JSONDecoder().decode(PhonePolicy.self, from: JSONEncoder().encode(base))
        precondition(roundTrip == base)
        for limit in [0, -1, 1441] { var invalid = base; invalid.dailyMinutes = limit; rejects { try invalid.validate() } }
        var newer = base; newer.revision += 1; newer.dailyMinutes = 30
        try newer.validate(previous: base)
        rejects { try base.validate(previous: newer) }
        var conflicting = base; conflicting.blocked = true
        rejects { try conflicting.validate(previous: base) }
        var invalidZone = base; invalidZone.timeZone = "Invalid/Zone"
        rejects { try invalidZone.validate() }
        var increased = newer; increased.revision += 1; increased.dailyMinutes = 60
        precondition(!increased.preservesExceeded(from: newer), "An increased allowance can release the previous lower threshold latch")
        var decreased = newer; decreased.dailyMinutes = 10
        precondition(decreased.preservesExceeded(from: newer), "A decrease cannot release an exceeded budget")
        precondition(!base.preservesExceeded(from: newer), "Removing the limit removes the exceeded-budget latch")
        let instant = ISO8601DateFormatter().date(from: "2026-11-21T01:00:00Z")!
        precondition(base.day(at: instant) == "2026-11-20", "Reset day must follow configured zone, not phone locale")
        let valid = try PhoneConnection.serverURL("https://orbit.example.com:8443/")
        precondition(valid.port == 8443)
        for url in ["http://orbit.example.com", "https://secret@orbit.example.com", "https://orbit.example.com/path",
                    "https://orbit.example.com?token=secret", "https://orbit.example.com/#token"] {
            rejects { _ = try PhoneConnection.serverURL(url) }
        }
        // Rollback from a reached higher threshold must retain the lower budget's block.
        let day = "2026-11-20"
        precondition(newer.inheritedExceededDay(from: increased, exceededDay: day, sameSelection: true) == day)
        precondition(increased.inheritedExceededDay(from: newer, exceededDay: day, sameSelection: true) == nil,
                     "Reaching a lower threshold does not establish that a higher threshold was reached")
        precondition(newer.inheritedExceededDay(from: increased, exceededDay: day, sameSelection: false) == nil)
        precondition(newer.shouldShield(exceededDay: day, at: instant))
        let tomorrow = instant.addingTimeInterval(86400)
        precondition(!newer.shouldShield(exceededDay: day, at: tomorrow), "Yesterday's quota latch cannot block a new day")
        precondition(!base.shouldShield(exceededDay: day, at: instant), "A removed limit ignores old quota state")
        precondition(conflicting.shouldShield(exceededDay: nil, at: instant), "A manual block is independent of quota state")

        try PhoneConnection.validateCredential(String(repeating: "a", count: 32))
        for token in ["short", String(repeating:"a",count:513), String(repeating:"a",count:32)+"\n",
                      String(repeating:"a",count:32)+" ", String(repeating:"é",count:32)] {
            rejects { try PhoneConnection.validateCredential(token) }
        }
        let original = PhoneConnection(origin: valid, deviceToken: String(repeating:"a",count:40), installationID: UUID())
        let replacement = try original.replacingDeviceToken(String(repeating:"b",count:40))
        precondition(replacement.origin == original.origin && replacement.installationID == original.installationID,
                     "Credential recovery must not change the trusted server or installation identity")
        precondition(replacement.deviceToken != original.deviceToken)
        let unchanged = try original.replacingDeviceToken("")
        precondition(unchanged.deviceToken == original.deviceToken)
        rejects { _ = try original.replacingDeviceToken("bad") }
        var sameRules = newer; sameRules.revision += 1
        precondition(sameRules.hasSameRules(as: newer), "A newer acknowledgement may have identical rule content")
        precondition(!increased.hasSameRules(as: newer), "Different allowances cannot confirm the requested save")
        var otherZone = newer; otherZone.timeZone = "UTC"
        precondition(!otherZone.hasSameRules(as: newer))
        print("iPhone policy and connection checks passed")
    }
}
