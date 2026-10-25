import SwiftUI

struct OnboardingDetailsStep: View {
    var onNext: () -> Void

    @Environment(AppState.self) private var app
    @State private var name = ""
    @State private var topSize = ""
    @State private var pantSize = ""
    @State private var shoeSize = ""
    @State private var fit = "any"
    @State private var budget = ""
    @State private var isSaving = false

    static let topSizes = ["", "XS", "S", "M", "L", "XL", "XXL"]
    static let fits = [("menswear", "Menswear"), ("womenswear", "Womenswear"), ("any", "Any")]

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 20) {
                    OnboardingHeader(
                        icon: "ruler",
                        title: "A few details",
                        subtitle: "All optional — helps me pick sizes and price points that work for you."
                    )
                    .padding(.top, 24)

                    VStack(spacing: 0) {
                        field("Name") {
                            TextField("Your first name", text: $name)
                                .textContentType(.givenName)
                        }
                        divider
                        field("Top size") {
                            Picker("Top size", selection: $topSize) {
                                ForEach(Self.topSizes, id: \.self) { Text($0.isEmpty ? "—" : $0).tag($0) }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                        }
                        divider
                        field("Pant size") {
                            TextField("e.g. 32x30", text: $pantSize)
                        }
                        divider
                        field("Shoe size") {
                            TextField("e.g. US 10", text: $shoeSize)
                        }
                        divider
                        field("Budget") {
                            TextField("e.g. under $200", text: $budget)
                        }
                    }
                    .card(padding: 0)

                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader(title: "I usually shop", icon: "tshirt")
                        Picker("Fit preference", selection: $fit) {
                            ForEach(Self.fits, id: \.0) { Text($0.1).tag($0.0) }
                        }
                        .pickerStyle(.segmented)
                    }
                }
                .padding(24)
            }
            .scrollDismissesKeyboard(.interactively)

            VStack(spacing: 12) {
                Button {
                    Task { await save() }
                } label: {
                    if isSaving { ProgressView().tint(.white) } else { Text("Continue") }
                }
                .buttonStyle(PrimaryButtonStyle())
                Button("Skip", action: onNext)
                    .font(.subheadline)
                    .foregroundStyle(Theme.muted)
            }
            .padding(24)
        }
    }

    private var divider: some View {
        Divider().padding(.leading, 16)
    }

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(label)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.ink)
                .frame(width: 96, alignment: .leading)
            content()
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 52)
    }

    private func save() async {
        func clean(_ s: String) -> String? {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        var profile = app.userProfile
        profile.name = clean(name)
        profile.topSize = clean(topSize)
        profile.pantSize = clean(pantSize)
        profile.shoeSize = clean(shoeSize)
        profile.fitPreference = fit
        profile.budget = clean(budget)
        app.userProfile = profile

        isSaving = true
        defer { isSaving = false }
        if let saved = try? await app.api.saveOnboarding(profile) {
            app.userProfile = saved
        }
        onNext()
    }
}
