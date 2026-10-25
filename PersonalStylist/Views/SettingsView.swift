import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @AppStorage("onboardingComplete") private var onboardingComplete = false
    @State private var urlDraft = ""
    @State private var confirmReset = false
    @State private var isResetting = false
    @State private var preparedItems = 0
    @State private var isSavingDemo = false
    @State private var isOpeningDemo = false
    @State private var demoMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("http://localhost:8000", text: $urlDraft)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit(applyURL)
                    HStack {
                        healthIndicator
                        Spacer()
                        Button("Check") {
                            applyURL()
                        }
                        .font(.subheadline.weight(.medium))
                    }
                } header: {
                    Text("Backend")
                } footer: {
                    Text("Simulator: http://localhost:8000. On a phone, use your https tunnel URL.")
                }

                Section("Scanning") {
                    Stepper("Photos per scan: \(app.scanner.limit)", value: Bindable(app.scanner).limit, in: 10...200, step: 10)
                    Stepper("Videos per scan: \(app.scanner.videoLimit)", value: Bindable(app.scanner).videoLimit, in: 0...10)
                }

                Section {
                    Button {
                        Task { await openPreparedCloset() }
                    } label: {
                        HStack {
                            Text(preparedItems > 0 ? "Use prepared closet · \(preparedItems) pieces" : "Use prepared closet")
                            Spacer()
                            if isOpeningDemo { ProgressView() }
                        }
                    }
                    .disabled(isOpeningDemo)
                    Button {
                        Task { await savePreparedCloset() }
                    } label: {
                        HStack {
                            Text(preparedItems > 0 ? "Update prepared closet" : "Save this closet for the demo")
                            Spacer()
                            if isSavingDemo { ProgressView() }
                        }
                    }
                    .disabled(isSavingDemo)
                } footer: {
                    Text(demoFooter)
                }

                Section {
                    Button(role: .destructive) {
                        confirmReset = true
                    } label: {
                        HStack {
                            Text("Reset demo")
                            Spacer()
                            if isResetting { ProgressView() }
                        }
                    }
                } footer: {
                    Text("Clears the live closet and restarts onboarding. A prepared closet stays saved, so the photo step can skip the scan.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        applyURL()
                        dismiss()
                    }
                }
            }
            .confirmationDialog("Reset everything?", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Reset demo", role: .destructive) {
                    Task {
                        isResetting = true
                        await app.resetDemo()
                        isResetting = false
                        dismiss()
                        onboardingComplete = false
                    }
                }
            }
            .onAppear { urlDraft = app.baseURLString }
            .task {
                await app.checkHealth()
                if let demo = try? await app.api.demoStatus() {
                    preparedItems = demo.ready ? demo.items : 0
                }
            }
        }
    }

    @ViewBuilder
    private var healthIndicator: some View {
        switch app.health {
        case .unknown, .checking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking…").foregroundStyle(Theme.muted)
            }
            .font(.subheadline)
        case .ok(let browser, let ext):
            VStack(alignment: .leading, spacing: 2) {
                Label("Connected", systemImage: "circle.fill")
                    .foregroundStyle(.green)
                    .font(.subheadline.weight(.medium))
                Text("Browser: \(browser)\(ext ? " · extension online" : "")")
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
            }
        case .unreachable(let message):
            VStack(alignment: .leading, spacing: 2) {
                Label("Unreachable", systemImage: "circle.fill")
                    .foregroundStyle(.red)
                    .font(.subheadline.weight(.medium))
                Text(message).font(.caption).foregroundStyle(Theme.muted).lineLimit(2)
            }
        }
    }

    private var demoFooter: String {
        if let demoMessage { return demoMessage }
        if preparedItems > 0 {
            return "Onboarding can skip the scan and open these \(preparedItems) pieces."
        }
        return "Saves the current closet so a later demo can skip indexing."
    }

    private func openPreparedCloset() async {
        isOpeningDemo = true
        demoMessage = nil
        defer { isOpeningDemo = false }
        do {
            try await app.openPreparedCloset()
            onboardingComplete = true
            dismiss()
        } catch {
            demoMessage = error.localizedDescription
        }
    }

    private func savePreparedCloset() async {
        isSavingDemo = true
        demoMessage = nil
        defer { isSavingDemo = false }
        do {
            let demo = try await app.api.snapshotDemo()
            preparedItems = demo.items
            demoMessage = "Saved \(demo.items) pieces. Reset, walk through onboarding, then skip the scan."
        } catch {
            demoMessage = error.localizedDescription
        }
    }

    private func applyURL() {
        let trimmed = urlDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed != app.baseURLString {
            app.baseURLString = trimmed
        }
        Task { await app.checkHealth() }
    }
}
