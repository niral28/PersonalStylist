import PhotosUI
import SwiftUI

struct OnboardingSelfieStep: View {
    var onNext: () -> Void

    @Environment(AppState.self) private var app
    @State private var image: UIImage?
    @State private var showCamera = false
    @State private var pickerItem: PhotosPickerItem?
    @State private var isUploading = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 24) {
            OnboardingHeader(
                icon: "person.crop.circle",
                title: "Take a quick selfie",
                subtitle: "So I can tell which person in your photos is you. It stays on your stylist backend."
            )
            .padding(.top, 24)

            Spacer()

            ZStack {
                Circle().fill(Theme.sand)
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .clipShape(Circle())
                } else {
                    Image(systemName: "face.smiling")
                        .font(.system(size: 64, weight: .ultraLight))
                        .foregroundStyle(Theme.muted)
                }
                if isUploading {
                    Circle().fill(.black.opacity(0.35))
                    ProgressView().tint(.white).controlSize(.large)
                }
            }
            .frame(width: 220, height: 220)
            .overlay(Circle().stroke(Theme.card, lineWidth: 6))
            .shadow(color: Theme.ink.opacity(0.1), radius: 16, y: 8)

            if let error {
                Text(error).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
            }

            Spacer()

            VStack(spacing: 12) {
                if image != nil && error == nil && !isUploading {
                    Button("Looks good", action: onNext)
                        .buttonStyle(PrimaryButtonStyle())
                }
                if SelfieCamera.isAvailable {
                    Button {
                        showCamera = true
                    } label: {
                        Label(image == nil ? "Open camera" : "Retake", systemImage: "camera")
                    }
                    .buttonStyle(image == nil ? AnyButtonStyle(PrimaryButtonStyle()) : AnyButtonStyle(SecondaryButtonStyle()))
                } else {
                    PhotosPicker(selection: $pickerItem, matching: .images) {
                        Label(image == nil ? "Choose a photo of you" : "Choose another", systemImage: "photo")
                    }
                    .buttonStyle(image == nil ? AnyButtonStyle(PrimaryButtonStyle()) : AnyButtonStyle(SecondaryButtonStyle()))
                }
                Button("Skip for now", action: onNext)
                    .font(.subheadline)
                    .foregroundStyle(Theme.muted)
                    .padding(.top, 4)
            }
        }
        .padding(24)
        .fullScreenCover(isPresented: $showCamera) {
            SelfieCamera { captured in
                Task { await upload(captured) }
            }
            .ignoresSafeArea()
        }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) {
                    await upload(img)
                }
            }
        }
    }

    private func upload(_ captured: UIImage) async {
        let resized = captured.resized(maxSide: 1024)
        image = resized
        error = nil
        guard let jpeg = resized.jpegData(compressionQuality: 0.8) else { return }
        isUploading = true
        defer { isUploading = false }
        do {
            app.userProfile = try await app.api.uploadSelfie(jpeg)
        } catch {
            self.error = "Couldn't upload selfie — \(error.localizedDescription). You can skip and add it later."
        }
    }
}

/// Type-erased ButtonStyle so we can swap styles conditionally.
struct AnyButtonStyle: ButtonStyle {
    private let make: (Configuration) -> AnyView
    init<S: ButtonStyle>(_ style: S) {
        make = { AnyView(style.makeBody(configuration: $0)) }
    }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}
