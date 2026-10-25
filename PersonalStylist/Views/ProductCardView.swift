import SwiftUI

struct ProductCardView: View {
    var candidate: Candidate

    @Environment(AppState.self) private var app
    @State private var safariURL: URL?
    @State private var showDislike = false
    @State private var showTryOn = false

    private var verdict: String? { app.feedback[candidate.id] }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .topTrailing) {
                RemoteImage(url: app.url(candidate.imageUrl))
                    .frame(width: 248, height: 260)
                    .clipped()
                if let price = candidate.price, !price.isEmpty {
                    Text(price)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Theme.ink)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(10)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                if let brand = candidate.brand, !brand.isEmpty {
                    Text(brand)
                        .font(.caption.weight(.semibold))
                        .textCase(.uppercase)
                        .tracking(0.6)
                        .foregroundStyle(Theme.accent)
                }
                Text(candidate.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2, reservesSpace: true)
            }

            Text(candidate.why)
                .font(.caption)
                .foregroundStyle(Theme.muted)
                .lineLimit(4, reservesSpace: true)

            let matched = candidate.matchedItemIds.compactMap { app.item(id: $0) }
            if !matched.isEmpty {
                HStack(spacing: 6) {
                    Text("Goes with")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Theme.muted)
                    ForEach(matched.prefix(4)) { item in
                        RemoteImage(url: app.url(item.cropUrl))
                            .frame(width: 30, height: 30)
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                }
            }

            Spacer(minLength: 0)

            Button {
                showTryOn = true
            } label: {
                Label("See it on me", systemImage: "person.crop.rectangle.badge.plus")
                    .font(.caption.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .foregroundStyle(.white)
                    .background(
                        LinearGradient(colors: [Theme.accent, Theme.accent.opacity(0.8)], startPoint: .leading, endPoint: .trailing),
                        in: Capsule()
                    )
            }
            .buttonStyle(.plain)

            HStack(spacing: 8) {
                Button {
                    safariURL = URL(string: candidate.url)
                } label: {
                    Label("Open", systemImage: "safari")
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .foregroundStyle(.white)
                        .background(Theme.ink, in: Capsule())
                }
                .disabled(URL(string: candidate.url) == nil)

                Button {
                    app.sendFeedback(candidate, verdict: "like")
                } label: {
                    Image(systemName: verdict == "like" ? "heart.fill" : "heart")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(verdict == "like" ? Theme.accent : Theme.ink)
                        .frame(width: 40, height: 36)
                        .background(Theme.sand, in: Capsule())
                        .symbolEffect(.bounce, value: verdict == "like")
                }
                .accessibilityLabel("Love")

                Button {
                    showDislike = true
                } label: {
                    Image(systemName: verdict == "dislike" ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.ink)
                        .frame(width: 40, height: 36)
                        .background(Theme.sand, in: Capsule())
                }
                .accessibilityLabel("Not for me")
            }
            .buttonStyle(.plain)
        }
        .frame(width: 248)
        .frame(minHeight: 546, alignment: .top)
        .card(padding: 12)
        .opacity(verdict == "dislike" ? 0.55 : 1)
        .fullScreenCover(isPresented: $showTryOn) {
            TryOnView(candidate: candidate)
        }
        .sheet(item: $safariURL) { url in
            SafariView(url: url).ignoresSafeArea()
        }
        .sheet(isPresented: $showDislike) {
            DislikeSheet(candidate: candidate) { reason in
                app.sendFeedback(candidate, verdict: "dislike", reason: reason)
            }
            .presentationDetents([.medium])
        }
    }
}

struct DislikeSheet: View {
    var candidate: Candidate
    var onSubmit: (String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var reason = ""

    private let quickReasons = ["Too expensive", "Not my color", "Wrong silhouette", "Too trendy", "Already have one"]

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("What's off about \(candidate.title)?")
                    .font(.subheadline)
                    .foregroundStyle(Theme.muted)
                FlowLayout {
                    ForEach(quickReasons, id: \.self) { r in
                        Button {
                            reason = r
                        } label: {
                            Chip(text: r, tint: reason == r ? Theme.accent.opacity(0.25) : Theme.sand)
                        }
                        .buttonStyle(.plain)
                    }
                }
                TextField("Or tell me in your words (optional)", text: $reason, axis: .vertical)
                    .lineLimit(2...4)
                    .padding(12)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                Spacer()
                Button("Not for me") {
                    let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
                    onSubmit(trimmed.isEmpty ? nil : trimmed)
                    dismiss()
                }
                .buttonStyle(PrimaryButtonStyle())
            }
            .padding(20)
            .background(Theme.background)
            .navigationTitle("Not for me")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
