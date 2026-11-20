import Foundation

private final class StubProtocol: URLProtocol {
    static var responder: ((URLRequest) throws -> (HTTPURLResponse, Data))!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (response, data) = try Self.responder(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@main
struct APITests {
    static func rejects(_ operation: () async throws -> Void) async {
        do { try await operation(); fatalError("Expected request rejection") } catch { }
    }
    static func requestBody(_ request: URLRequest) -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { fatalError("Expected an encoded request body") }
        stream.open(); defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            precondition(count >= 0)
            if count == 0 { return data }
            data.append(contentsOf: buffer.prefix(count))
        }
    }
    static func main() async throws {
        let connection = PhoneConnection(origin: try PhoneConnection.serverURL("https://orbit.example.test"),
            deviceToken: String(repeating: "d", count: 40), installationID: UUID())
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let api = PhoneAPI(connection: connection, configuration: config)
        let policy = PhonePolicy()
        let payload = try JSONEncoder().encode(policy)
        StubProtocol.responder = { request in
            precondition(request.url!.path == "/api/ios/policy")
            precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer " + connection.deviceToken)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, payload)
        }
        let fetched = try await api.policy()
        precondition(fetched == policy)
        let enrollmentPayload = try JSONSerialization.data(withJSONObject: [
            "installationID":connection.installationID.uuidString, "deviceToken":String(repeating:"n", count:43),
            "parentSession":String(repeating:"p", count:43), "policy":JSONSerialization.jsonObject(with:payload)])
        StubProtocol.responder = { request in
            precondition(request.url!.path == "/api/ios/enroll" && request.httpMethod == "POST")
            precondition(request.value(forHTTPHeaderField:"Authorization") == "Bearer ", "Enrollment sends no dashboard credential")
            let body = try JSONSerialization.jsonObject(with:requestBody(request)) as! [String:Any]
            precondition(Set(body.keys) == ["code", "installationID"])
            precondition(body["code"] as? String == "ABCD-EFGH-JKLM")
            return (HTTPURLResponse(url:request.url!, statusCode:200, httpVersion:nil, headerFields:nil)!, enrollmentPayload)
        }
        let enrolled = try await api.pair(code:"ABCD-EFGH-JKLM", existing:false)
        precondition(enrolled.policy == policy && enrolled.deviceToken != nil)
        let unlockPayload = try JSONSerialization.data(withJSONObject: [
            "installationID":connection.installationID.uuidString, "parentSession":String(repeating:"p", count:43),
            "policy":JSONSerialization.jsonObject(with:payload)])
        StubProtocol.responder = { request in
            precondition(request.url!.path == "/api/ios/unlock")
            precondition(request.value(forHTTPHeaderField:"Authorization") == "Bearer " + connection.deviceToken)
            return (HTTPURLResponse(url:request.url!, statusCode:200, httpVersion:nil, headerFields:nil)!, unlockPayload)
        }
        _ = try await api.pair(code:"ABCD-EFGH-JKLM", existing:true)
        StubProtocol.responder = { request in
            (HTTPURLResponse(url:request.url!, statusCode:200, httpVersion:nil, headerFields:nil)!, enrollmentPayload)
        }
        await rejects { _ = try await api.pair(code:"ABCD-EFGH-JKLM", existing:true) }
        for existing in [false, true] {
            var attempts = 0
            StubProtocol.responder = { request in
                attempts += 1
                throw URLError(.networkConnectionLost)
            }
            do { _ = try await api.pair(code:"ABCD-EFGH-JKLM", existing:existing); fatalError("Expected unconfirmed setup") }
            catch { precondition(error as? OrbitFailure == .setupUnconfirmed) }
            precondition(attempts == 1, "A lost response must not automatically reuse a one-time code")
        }
        let wrongIdentity = try JSONSerialization.data(withJSONObject: [
            "installationID":UUID().uuidString, "deviceToken":String(repeating:"n", count:43),
            "parentSession":String(repeating:"p", count:43), "policy":JSONSerialization.jsonObject(with:payload)])
        StubProtocol.responder = { request in
            (HTTPURLResponse(url:request.url!, statusCode:200, httpVersion:nil, headerFields:nil)!, wrongIdentity)
        }
        await rejects { _ = try await api.pair(code:"ABCD-EFGH-JKLM", existing:false) }
        let status = PhoneStatus(installationID: connection.installationID, revision: 1, authorized: true,
                                 applicationCount: 1, shieldConfigured: false)
        StubProtocol.responder = { request in
            precondition(request.httpMethod == "POST" && request.url!.path == "/api/ios/status")
            let body = try JSONSerialization.jsonObject(with: requestBody(request)) as! [String: Any]
            precondition(Set(body.keys) == ["installationID", "revision", "authorized", "applicationCount", "shieldConfigured"],
                         "Status must not upload app selections or private app names")
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(#"{"ok":true}"#.utf8))
        }
        try await api.report(status)
        let parentToken = String(repeating: "a", count: 40)
        var savedPolicy = policy; savedPolicy.revision += 1
        let savedPayload = try JSONEncoder().encode(savedPolicy)
        StubProtocol.responder = { request in
            precondition(request.url!.path == "/api/ios/parent/policy" && request.httpMethod == "POST")
            precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer " + parentToken)
            let body = try JSONSerialization.jsonObject(with: requestBody(request)) as! [String: Any]
            precondition(body["dailyMinutes"] is NSNull, "An unlimited budget must survive actual HTTP encoding")
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, savedPayload)
        }
        let saved = try await api.save(policy, parentSession: parentToken)
        precondition(saved == savedPolicy)
        StubProtocol.responder = { request in
            precondition(request.url!.path == "/api/ios/status")
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(#"{"ok":false}"#.utf8))
        }
        await rejects { try await api.report(status) }
        StubProtocol.responder = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(repeating: 32, count: 65_537))
        }
        await rejects { _ = try await api.policy() }
        StubProtocol.responder = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Length":"2000000"])!, payload)
        }
        await rejects { _ = try await api.policy() }
        var padded = payload
        padded.append(Data(repeating: 32, count: 65_536 - payload.count))
        let exactLimit = padded
        StubProtocol.responder = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, exactLimit)
        }
        let boundary = try await api.policy()
        precondition(boundary == policy, "The response-size boundary is inclusive")
        StubProtocol.responder = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!, Data())
        }
        do { _ = try await api.policy(); fatalError("Expected unauthorized response") }
        catch { precondition((error as NSError).domain == "Orbit" && (error as NSError).code == 401) }
        var redirectRequests = 0
        StubProtocol.responder = { request in
            redirectRequests += 1
            precondition(request.url!.host == connection.origin.host)
            return (HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: nil,
                headerFields: ["Location":"https://other.example.test/"])!, Data())
        }
        await rejects { _ = try await api.policy() }
        precondition(redirectRequests == 1, "A redirected credential request must not reach another origin")
        // A POST can commit successfully even when its response connection is lost.
        // Confirm with a read; never blindly repeat a policy-changing request.
        var uncertainPosts = 0, confirmationReads = 0
        StubProtocol.responder = { request in
            if request.httpMethod == "POST" {
                uncertainPosts += 1
                throw URLError(.networkConnectionLost)
            }
            confirmationReads += 1
            precondition(request.url!.path == "/api/ios/parent/policy")
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, savedPayload)
        }
        let confirmed = try await api.save(policy, parentSession: parentToken)
        precondition(confirmed == savedPolicy)
        precondition(uncertainPosts == 1 && confirmationReads == 1, "An uncertain save is resolved by a read, not another POST")
        // If another parent's settings won, do not apply or overwrite them as our save.
        var otherPolicy = savedPolicy; otherPolicy.blocked = !policy.blocked
        let otherPayload = try JSONEncoder().encode(otherPolicy)
        var recoveryPosts = 0, recoveryReads = 0
        StubProtocol.responder = { request in
            precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer " + parentToken)
            if request.httpMethod == "POST" { recoveryPosts += 1; throw URLError(.timedOut) }
            recoveryReads += 1
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, otherPayload)
        }
        do { _ = try await api.save(policy, parentSession: parentToken); fatalError("Expected a conflicting save outcome") }
        catch { precondition((error as NSError).domain == "Orbit" && (error as NSError).code == 409) }
        precondition(recoveryPosts == 1 && recoveryReads == 1)

        // An unchanged revision or an unreachable confirmation endpoint does not prove success.
        for outcome in ["notCommitted", "unreachable"] {
            var writes = 0, reads = 0
            StubProtocol.responder = { request in
                if request.httpMethod == "POST" { writes += 1; throw URLError(.networkConnectionLost) }
                reads += 1
                if outcome == "unreachable" { throw URLError(.notConnectedToInternet) }
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, payload)
            }
            do { _ = try await api.save(policy, parentSession: parentToken); fatalError("Expected an unconfirmed save") }
            catch { precondition(error as? OrbitFailure == .saveUnconfirmed) }
            precondition(writes == 1 && reads == 1)
        }
        for statusCode in [401, 409] {
            var attempts = 0
            StubProtocol.responder = { request in
                attempts += 1
                precondition(request.httpMethod == "POST", "Known rejected writes need no recovery read")
                return (HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!, Data())
            }
            do { _ = try await api.save(policy, parentSession: parentToken); fatalError("Expected HTTP rejection") }
            catch { precondition((error as NSError).domain == "Orbit" && (error as NSError).code == statusCode) }
            precondition(attempts == 1)
        }
        print("iPhone HTTP client checks passed (intercepted; no network)")
    }
}
