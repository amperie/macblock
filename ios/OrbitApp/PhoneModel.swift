import SwiftUI
import FamilyControls

@MainActor
final class PhoneModel: ObservableObject {
    @Published var connection: PhoneConnection?
    @Published var policy = PhonePolicy()
    @Published var selection = FamilyActivitySelection()
    @Published var selectionDraft = FamilyActivitySelection()
    @Published var isBusy = false
    @Published var parentUnlocked = false
    @Published var message = "Enter a setup code from the Orbit website, then authorize Screen Time and choose apps."
    @Published var lastSync: Date?
    @Published var authorization = AuthorizationCenter.shared.authorizationStatus
    @Published var setupUnavailable = false
    private var parentSession = "" // Scoped, short-lived parent session; never persisted.
    private var parentExpires = Date.distantPast
    private var unlockGeneration = 0
    private let keychain = ConnectionKeychain()
    private let enforcement = PhoneEnforcement()

    init() {
        do {
            connection = try keychain.load()
            if let state = try enforcement.storage.read() { policy = state.policy; selection = state.selection }
            selectionDraft = selection
        } catch {
            setupUnavailable = true; message = error.localizedDescription
        }
    }

    func lockParent() { unlockGeneration += 1; parentSession = ""; parentUnlocked = false }

    @discardableResult
    private func perform(_ work: () async throws -> Void) async -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        defer { isBusy = false }
        do { try await work(); return true }
        catch {
            if (error as NSError).domain == "Orbit", (error as NSError).code == 401 { lockParent() }
            message = error.localizedDescription; return false
        }
    }

    func unlock(code: String) async {
        let generation = unlockGeneration
        await perform {
            guard !setupUnavailable else { throw OrbitFailure.unavailableStorage }
            var existing = connection?.paired == true
            if existing, let connection {
                do { _ = try await PhoneAPI(connection: connection).policy() }
                catch {
                    // A revoked installation can enroll again with fresh parent approval.
                    guard (error as NSError).domain == "Orbit", (error as NSError).code == 401 else { throw error }
                    existing = false
                }
            }
            let candidate = existing ? connection! : PhoneConnection(origin: PhoneConnection.defaultOrigin,
                deviceToken: "", installationID: UUID(), paired: true)
            let result = try await PhoneAPI(connection: candidate).pair(code: code, existing: existing)
            try result.policy.validate(previous: try enforcement.storage.read()?.policy)
            var saved = candidate
            if let credential = result.deviceToken { saved.deviceToken = credential }
            // Keep a successfully enrolled device even if backgrounding cancelled parent unlock.
            try keychain.save(saved)
            connection = saved; policy = result.policy
            guard generation == unlockGeneration else { return }
            parentSession = result.parentSession; parentExpires = Date().addingTimeInterval(840)
            parentUnlocked = true
            message = "Connected. Parent setup is unlocked for up to 14 minutes, or until the app enters the background."
        }
    }

    private func requireParent() -> Bool {
        guard parentUnlocked, Date() < parentExpires else {
            lockParent(); message = "Generate a new setup code on the website to unlock parent setup."
            return false
        }
        return true
    }

    func authorize(individualTest: Bool) async {
        guard requireParent() else { return }
        await perform {
            try await AuthorizationCenter.shared.requestAuthorization(for: individualTest ? .individual : .child)
            authorization = AuthorizationCenter.shared.authorizationStatus
            message = individualTest ? "Self-control test authorized. Device owners can revoke this mode." : "Family authorization approved."
            if !selection.applicationTokens.isEmpty { try enforcement.apply(policy, selection: selection) }
        }
    }

    func saveSelection() async -> Bool {
        guard requireParent() else { return false }
        return await perform {
            try enforcement.apply(policy, selection: selectionDraft)
            selection = selectionDraft
            message = "Selected apps saved on this phone. All selected apps share one daily allowance."
            await report()
        }
    }

    func savePolicy(blocked: Bool, dailyMinutes: Int?) async {
        guard requireParent(), let connection else { return }
        await perform {
            guard authorization == .approved, !selection.applicationTokens.isEmpty else { throw OrbitFailure.authorizationRequired }
            var draft = policy; draft.blocked = blocked; draft.dailyMinutes = dailyMinutes
            // The server increments the revision. Validate field ranges independently of the cached revision.
            try draft.validate()
            let saved = try await PhoneAPI(connection: connection).save(draft, parentSession: parentSession)
            try saved.validate(previous: policy)
            guard saved.revision > draft.revision else { throw OrbitFailure.invalidResponse }
            policy = saved
            do { try enforcement.apply(saved, selection: selection) }
            catch {
                message = "Server saved revision \(saved.revision), but this phone could not apply it: \(error.localizedDescription)"
                return
            }
            lastSync = Date(); message = "Settings applied on this phone."
            await report()
        }
    }

    func sync() async {
        guard let connection else { return }
        await perform {
            authorization = AuthorizationCenter.shared.authorizationStatus
            // Reconcile cached restrictions before depending on the network. In particular,
            // recover an interrupted snapshot/shield update while the phone is offline.
            var cacheRestored = false
            var restoreError: Error?
            do {
                if authorization == .approved, let cached = try enforcement.storage.read(),
                   !cached.selection.applicationTokens.isEmpty {
                    try enforcement.apply(cached.policy, selection: cached.selection)
                    selection = cached.selection; cacheRestored = true
                }
            } catch { restoreError = error }
            let fetched: PhonePolicy
            do { fetched = try await PhoneAPI(connection: connection).policy() }
            catch {
                if (error as NSError).domain == "Orbit", (error as NSError).code == 401 { lockParent() }
                message = cacheRestored ? "Cached rules reapplied locally. Server sync failed: " + error.localizedDescription : error.localizedDescription
                if let restoreError { message += " Cached-rule recovery also failed: " + restoreError.localizedDescription }
                return
            }
            try fetched.validate(previous: try enforcement.storage.read()?.policy)
            if authorization == .approved && !selection.applicationTokens.isEmpty {
                try enforcement.apply(fetched, selection: selection)
                message = "Latest settings applied. Previously downloaded rules work offline."
            } else {
                message = "Settings downloaded. Parent authorization and app selection are needed before enforcement."
            }
            policy = fetched; lastSync = Date()
            await report()
        }
    }

    private func report() async {
        // A telemetry failure must not misrepresent a successful local policy application.
        do { try await uploadStatus() }
        catch { message += " Status upload failed: " + error.localizedDescription }
    }

    private func uploadStatus() async throws {
        guard let connection else { return }
        let local = try enforcement.storage.read()
        try await PhoneAPI(connection: connection).report(.init(installationID: connection.installationID,
            revision: local?.policy.revision ?? 0, authorized: authorization == .approved,
            applicationCount: selection.applicationTokens.count, shieldConfigured: local?.shouldShield ?? false))
    }
}
