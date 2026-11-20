import SwiftUI
import FamilyControls

@main
struct OrbitPhoneApp: App {
    @StateObject private var model = PhoneModel()
    var body: some Scene { WindowGroup { PhoneView(model: model) } }
}

struct PhoneView: View {
    @ObservedObject var model: PhoneModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var setupCode = ""
    @State private var showPicker = false
    @State private var individualTest = false
    @State private var blocked = false
    @State private var limited = false
    @State private var minutes = 60

    private var hasDraftChanges: Bool {
        blocked != model.policy.blocked || (limited ? minutes : nil) != model.policy.dailyMinutes
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("This iPhone") {
                    LabeledContent("Screen Time", value: model.authorization == .approved ? "Authorized" : "Not authorized")
                    LabeledContent("Selected apps", value: String(model.selection.applicationTokens.count))
                    LabeledContent("Server revision", value: String(model.policy.revision))
                    if let date = model.lastSync { LabeledContent("Last sync") { Text(date, style: .time) } }
                    Button("Sync with server") { Task { await model.sync() } }.disabled(model.connection == nil || hasDraftChanges)
                    Text(model.message).font(.footnote).foregroundStyle(.secondary).accessibilityAddTraits(.updatesFrequently)
                }
                Section {
                    LabeledContent("Server", value: (model.connection?.origin ?? PhoneConnection.defaultOrigin).host ?? "Orbit")
                    if model.parentUnlocked {
                        Button(hasDraftChanges ? "Lock and discard edits" : "Lock parent controls") { model.lockParent(); setupCode = ""; copyPolicy() }
                    } else {
                        Text("Open Settings → iPhone setup on the Orbit website and generate a setup code. Codes work once and expire after 10 minutes.")
                            .font(.footnote).foregroundStyle(.secondary)
                        TextField("Setup code (XXXX-XXXX-XXXX)", text: $setupCode)
                            .textInputAutocapitalization(.characters).autocorrectionDisabled()
                            .privacySensitive()
                        Button(model.connection == nil ? "Connect iPhone" : "Unlock parent setup") {
                            Task {
                                await model.unlock(code: setupCode)
                                setupCode = ""
                                if model.parentUnlocked { await model.sync() }
                            }
                        }.disabled(model.setupUnavailable || setupCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                } header: { Text("Parent setup") } footer: {
                    Text("Connection details and rules download automatically. This phone's credential is saved in Keychain. The dashboard administrator credential is never downloaded. App selection stays on the phone.")
                }
                Section("Screen Time authorization") {
                    Toggle("Self-control test instead of child mode", isOn: $individualTest)
                    Button("Authorize Screen Time") { Task { await model.authorize(individualTest: individualTest) } }
                    Text("Use child mode for Family Sharing parental controls. Self-control mode can be revoked by the phone’s owner.").font(.footnote).foregroundStyle(.secondary)
                }.disabled(!model.parentUnlocked)
                Section("Apps and limits") {
                    Button("Choose apps") { model.selectionDraft = model.selection; showPicker = true }.disabled(hasDraftChanges)
                    Toggle("Block selected apps", isOn: $blocked)
                    Toggle("Daily allowance", isOn: $limited)
                    if limited { Stepper("\(minutes) minutes per day", value: $minutes, in: 1...1440, step: 5) }
                    LabeledContent("Daily reset time zone", value: model.policy.timeZone)
                    if hasDraftChanges {
                        Text("Unsaved changes — save or discard before syncing or changing selected apps.").font(.footnote).foregroundStyle(.orange)
                        Button("Discard edits") { copyPolicy() }
                    }
                    Button("Save and apply") { Task { await model.savePolicy(blocked: blocked, dailyMinutes: limited ? minutes : nil) } }.disabled(!hasDraftChanges)
                    Text("One combined allowance for the selected apps. Start with Roblox only to test its individual limit. Apple’s picker may show categories and websites; this version accepts individual apps only.")
                        .font(.footnote).foregroundStyle(.secondary)
                }.disabled(!model.parentUnlocked || model.authorization != .approved)
                Section("First version") {
                    if let connection = model.connection { Link("Privacy policy", destination: connection.origin.appendingPathComponent("privacy")) }
                    Text("Sync runs when this app opens or you tap Sync. Background push updates, website filtering, and usage charts are not included yet. No live usage or app names are uploaded.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Orbit")
            .disabled(model.isBusy)
            .overlay { if model.isBusy { ProgressView().padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
            .sheet(isPresented: $showPicker) {
                NavigationStack {
                    FamilyActivityPicker(selection: $model.selectionDraft)
                        .disabled(model.isBusy)
                        .safeAreaInset(edge: .bottom) { Text(model.message).font(.footnote).padding().frame(maxWidth: .infinity).background(.regularMaterial) }
                        .navigationTitle("Choose apps")
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showPicker = false }.disabled(model.isBusy) }
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Save") { Task { if await model.saveSelection() { showPicker = false } } }
                                    .disabled(model.isBusy || !model.parentUnlocked)
                            }
                        }
                }
                .interactiveDismissDisabled(model.isBusy)
            }
            .task { copyPolicy(); await model.sync(); copyPolicy() }
            .onChange(of: model.policy) { _, _ in copyPolicy() }
            .onChange(of: model.parentUnlocked) { _, unlocked in if !unlocked { copyPolicy(); showPicker = false; setupCode = "" } }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background {
                    model.lockParent(); setupCode = ""; showPicker = false
                } else if phase == .active && !hasDraftChanges && !showPicker { Task { await model.sync() } }
            }
            .onReceive(AuthorizationCenter.shared.$authorizationStatus) { model.authorization = $0 }
        }
    }
    private func copyPolicy() { blocked = model.policy.blocked; limited = model.policy.dailyMinutes != nil; minutes = model.policy.dailyMinutes ?? 60 }
}
