import Photos
import SwiftUI

struct OnboardingPhotosStep: View {
    @Environment(AppState.self) private var app
    @AppStorage("onboardingComplete") private var onboardingComplete = false
    @State private var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @State private var preparedItems = 0
    @State private var isRestoring = false
    @State private var restoreError: String?

    var body: some View {
        VStack(spacing: 24) {
            OnboardingHeader(
                icon: "photo.stack",
                title: "Let me see your style",
                subtitle: "I'll look at recent photos with people in them, selfies, and screenshots of things you've saved. Location data is stripped before upload."
            )
            .padding(.top, 24)

            Spacer()

            ZStack {
                ForEach(0..<3) { i in
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(i == 2 ? Theme.card : Theme.sand.opacity(i == 0 ? 0.6 : 0.9))
                        .frame(width: 170, height: 220)
                        .rotationEffect(.degrees(Double(i - 1) * 8))
                        .offset(x: CGFloat(i - 1) * 26)
                        .shadow(color: Theme.ink.opacity(0.08), radius: 10, y: 5)
                }
                Image(systemName: statusIcon)
                    .font(.system(size: 54, weight: .light))
                    .foregroundStyle(Theme.accent)
                    .contentTransition(.symbolEffect(.replace))
            }
            .frame(height: 260)

            Text(statusText)
                .font(.subheadline)
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)

            Spacer()

            VStack(spacing: 12) {
                Button {
                    Task { await usePreparedCloset() }
                } label: {
                    if isRestoring {
                        ProgressView()
                    } else {
                        Text(preparedItems > 0 ? "Use prepared closet · \(preparedItems) pieces" : "Use prepared closet")
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(isRestoring)
                switch status {
                case .authorized:
                    buildClosetButton
                case .limited:
                    buildClosetButton
                    Button("Choose more photos") { presentLimitedPicker() }
                        .buttonStyle(SecondaryButtonStyle())
                case .denied, .restricted:
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    Button("Continue without photos") { finish(scan: false) }
                        .font(.subheadline)
                        .foregroundStyle(Theme.muted)
                default:
                    Button("Allow photo access") {
                        Task { await requestAccess() }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    Button("Not now") { finish(scan: false) }
                        .font(.subheadline)
                        .foregroundStyle(Theme.muted)
                }
                if let restoreError {
                    Text(restoreError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .padding(24)
        .task { await loadPreparedCloset() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        }
    }

    private var statusIcon: String {
        switch status {
        case .authorized, .limited: return "checkmark.circle"
        case .denied, .restricted: return "lock"
        default: return "photo.on.rectangle.angled"
        }
    }

    private var statusText: String {
        switch status {
        case .authorized: return "Full access granted. Ready to scan."
        case .limited: return "You've shared a selection of photos. Add more any time for better results."
        case .denied, .restricted: return "Photo access is off. Enable it in Settings so I can learn your style."
        default: return "Your photos are only sent to your own stylist backend."
        }
    }

    private func requestAccess() async {
        let result = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        withAnimation { status = result }
    }

    private func presentLimitedPicker() {
        guard let root = UIApplication.shared.topViewController else { return }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: root)
    }

    private func loadPreparedCloset() async {
        if let demo = try? await app.api.demoStatus(), demo.ready {
            preparedItems = demo.items
        }
    }

    private func usePreparedCloset() async {
        isRestoring = true
        restoreError = nil
        defer { isRestoring = false }
        do {
            try await app.openPreparedCloset()
            onboardingComplete = true
        } catch {
            restoreError = error.localizedDescription
        }
    }

    @ViewBuilder
    private var buildClosetButton: some View {
        if preparedItems > 0 {
            Button("Build my closet") { finish(scan: true) }
                .buttonStyle(SecondaryButtonStyle())
        } else {
            Button("Build my closet") { finish(scan: true) }
                .buttonStyle(PrimaryButtonStyle())
        }
    }

    private func finish(scan: Bool) {
        if scan { app.startScan() }
        onboardingComplete = true
    }
}

extension UIApplication {
    var topViewController: UIViewController? {
        let scene = connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }
            ?? connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var top = scene?.keyWindow?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}
