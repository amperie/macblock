import Foundation

struct PhoneStatus: Encodable {
    let installationID: UUID
    let revision: Int
    let authorized: Bool
    let applicationCount: Int
    let shieldConfigured: Bool
}

struct PhoneEnrollment: Decodable {
    let installationID: UUID
    let deviceToken: String?
    let parentSession: String
    let policy: PhonePolicy
}

struct PhoneAPI {
    let connection: PhoneConnection
    private let sessionConfiguration: URLSessionConfiguration?

    init(connection: PhoneConnection, configuration: URLSessionConfiguration? = nil) {
        self.connection = connection
        self.sessionConfiguration = configuration
    }

    private func request<T: Decodable>(_ path: String, token: String, body: Data? = nil) async throws -> T {
        var request = URLRequest(url: connection.origin.appendingPathComponent(path))
        request.httpMethod = body == nil ? "GET" : "POST"
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 15
        let configuration = (sessionConfiguration?.copy() as? URLSessionConfiguration) ?? .ephemeral
        configuration.timeoutIntervalForResource = 20
        let session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, response.expectedContentLength <= 65_536 else { throw OrbitFailure.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            throw NSError(domain: "Orbit", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey:
                http.statusCode == 401 ? (path == "api/ios/enroll" || path == "api/ios/unlock" ? "Invalid, expired, or already used setup code. Generate a new code on the website." : "The server rejected this credential. Generate a new website setup code to reconnect or unlock.") : http.statusCode == 429 ? "Too many incorrect setup codes. Wait a minute before trying again." : http.statusCode == 409 ? "Settings changed on the server. Discard edits and sync before saving again." : "Server request failed (\(http.statusCode))."])
        }
        // Bound bytes as they arrive, including replies with no Content-Length header.
        // Checking after data(for:) would already have allocated the entire response.
        var data = Data()
        for try await byte in bytes {
            guard data.count < 65_536 else { throw OrbitFailure.invalidResponse }
            data.append(byte)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
    func policy() async throws -> PhonePolicy { try await request("api/ios/policy", token: connection.deviceToken) }
    func pair(code: String, existing: Bool) async throws -> PhoneEnrollment {
        struct Setup: Encodable { let code: String; let installationID: UUID }
        let result: PhoneEnrollment
        do {
            result = try await request(existing ? "api/ios/unlock" : "api/ios/enroll",
                token: existing ? connection.deviceToken : "",
                body: JSONEncoder().encode(Setup(code: code, installationID: connection.installationID)))
        } catch let error as URLError where error.code == .networkConnectionLost || error.code == .timedOut {
            // The one-time code may have been consumed. Never silently repeat enrollment.
            throw OrbitFailure.setupUnconfirmed
        }
        guard result.installationID == connection.installationID else { throw OrbitFailure.invalidResponse }
        try result.policy.validate()
        try PhoneConnection.validateCredential(result.parentSession)
        if existing {
            guard result.deviceToken == nil else { throw OrbitFailure.invalidResponse }
        } else {
            guard let credential = result.deviceToken else { throw OrbitFailure.invalidResponse }
            try PhoneConnection.validateCredential(credential)
        }
        return result
    }
    func unlock(parentSession: String) async throws -> PhonePolicy { try await request("api/ios/parent/policy", token: parentSession) }
    func save(_ policy: PhonePolicy, parentSession: String) async throws -> PhonePolicy {
        do {
            return try await request("api/ios/parent/policy", token: parentSession, body: JSONEncoder().encode(policy))
        } catch let error as URLError where error.code == .networkConnectionLost || error.code == .timedOut {
            // The server may have committed the POST before its reply was lost. Never retry
            // a policy write automatically; first confirm the desired rules with a GET.
            let current: PhonePolicy
            do { current = try await unlock(parentSession: parentSession) }
            catch {
                if (error as NSError).domain == "Orbit", (error as NSError).code == 401 { throw error }
                throw OrbitFailure.saveUnconfirmed
            }
            try current.validate()
            guard current.revision >= policy.revision else { throw OrbitFailure.stalePolicy }
            guard current.revision > policy.revision else { throw OrbitFailure.saveUnconfirmed }
            guard current.hasSameRules(as: policy) else {
                throw NSError(domain: "Orbit", code: 409, userInfo: [NSLocalizedDescriptionKey:
                    "Server settings changed during the save. Discard edits and sync before retrying."])
            }
            return current
        }
    }
    func report(_ status: PhoneStatus) async throws {
        struct Ack: Decodable { let ok: Bool }
        let ack: Ack = try await request("api/ios/status", token: connection.deviceToken, body: JSONEncoder().encode(status))
        guard ack.ok else { throw OrbitFailure.invalidResponse }
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil) // Never forward credentials to a redirected origin.
    }
}
