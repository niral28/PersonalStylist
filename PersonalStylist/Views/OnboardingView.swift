import SwiftUI

struct OnboardingView: View {
    enum Step: Int, CaseIterable {
        case welcome, selfie, details, photos
    }

    @State private var step: Step = .welcome
    @State private var showSettings = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                if step != .welcome {
                    progressBar
                        .padding(.horizontal, 24)
                        .padding(.top, 8)
                }
                Group {
                    switch step {
                    case .welcome:
                        OnboardingWelcomeStep { advance() }
                    case .selfie:
                        OnboardingSelfieStep { advance() }
                    case .details:
                        OnboardingDetailsStep { advance() }
                    case .photos:
                        OnboardingPhotosStep()
                    }
                }
                .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                        removal: .move(edge: .leading).combined(with: .opacity)))
            }
            Button { showSettings = true } label: {
                Image(systemName: "gearshape")
                    .font(.body.weight(.medium))
                    .foregroundStyle(Theme.muted)
                    .padding(12)
            }
            .accessibilityLabel("Settings")
            .padding(.trailing, 8)
            .padding(.top, step == .welcome ? 0 : 12)
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
    }

    private var progressBar: some View {
        HStack(spacing: 6) {
            ForEach(Step.allCases.dropFirst(), id: \.self) { s in
                Capsule()
                    .fill(s.rawValue <= step.rawValue ? Theme.ink : Theme.sand)
                    .frame(height: 4)
            }
        }
        .animation(.easeInOut, value: step)
    }

    private func advance() {
        guard let next = Step(rawValue: step.rawValue + 1) else { return }
        withAnimation(.spring(duration: 0.45)) { step = next }
    }
}

struct OnboardingWelcomeStep: View {
    var onNext: () -> Void

    @Environment(AppState.self) private var app
    @AppStorage("onboardingComplete") private var onboardingComplete = false
    @State private var isOpening = false
    @State private var openError: String?

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            ZStack {
                Circle().fill(Theme.sand).frame(width: 180, height: 180)
                Circle().fill(Theme.card).frame(width: 132, height: 132)
                    .shadow(color: Theme.ink.opacity(0.08), radius: 12, y: 6)
                Image(systemName: "hanger")
                    .font(.system(size: 56, weight: .light))
                    .foregroundStyle(Theme.accent)
            }
            VStack(spacing: 12) {
                Text("Your personal stylist")
                    .font(.system(.largeTitle, design: .serif, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .multilineTextAlignment(.center)
                Text("I'll look through your outfit photos and saved screenshots, build your virtual closet, and shop the web for pieces you'll actually love.")
                    .font(.body)
                    .foregroundStyle(Theme.muted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
            }
            VStack(alignment: .leading, spacing: 14) {
                feature("photo.on.rectangle.angled", "Scans your camera roll for outfits")
                feature("sparkles", "Learns your palette, fits & brands")
                feature("bag", "Finds new pieces that match your closet")
            }
            .card()
            Spacer()
            VStack(spacing: 12) {
                Button("Get started", action: onNext)
                    .buttonStyle(PrimaryButtonStyle())
                Button {
                    Task { await openPrepared() }
                } label: {
                    if isOpening {
                        ProgressView()
                    } else {
                        Text("Use prepared closet")
                    }
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(isOpening)
                if let openError {
                    Text(openError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .padding(24)
    }

    private func openPrepared() async {
        isOpening = true
        openError = nil
        defer { isOpening = false }
        do {
            try await app.openPreparedCloset()
            onboardingComplete = true
        } catch {
            openError = error.localizedDescription
        }
    }

    private func feature(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.body.weight(.medium))
                .foregroundStyle(Theme.accent)
                .frame(width: 28)
            Text(text).font(.subheadline).foregroundStyle(Theme.ink)
            Spacer(minLength: 0)
        }
    }
}

struct OnboardingHeader: View {
    var icon: String
    var title: String
    var subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Theme.accent)
            Text(title)
                .font(.system(.title, design: .serif, weight: .semibold))
                .foregroundStyle(Theme.ink)
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview {
    OnboardingView().environment(AppState())
}
