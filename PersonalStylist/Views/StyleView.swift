import SwiftUI

struct StyleView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if app.isRebuildingProfile {
                    RebuildingCard()
                }
                if let error = app.profileError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .card(padding: 12)
                }
                if !app.looks.isEmpty {
                    SavedForLaterSection()
                }
                if let profile = app.tasteProfile {
                    ProfileContent(profile: profile)
                } else if !app.isRebuildingProfile {
                    emptyState
                }
            }
            .padding(16)
            .animation(.easeInOut, value: app.isRebuildingProfile)
        }
        .background(Theme.background)
        .navigationTitle("Your Style")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    Task { await app.rebuildProfile() }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "wand.and.stars")
                        Text("Rebuild")
                    }
                    .font(.subheadline.weight(.medium))
                }
                .disabled(app.isRebuildingProfile || app.closet.isEmpty)
            }
        }
        .refreshable {
            await app.loadProfile()
            await app.loadLooks()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "sparkles")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Theme.accent)
            Text("No taste profile yet")
                .font(.headline)
                .foregroundStyle(Theme.ink)
            Text(app.closet.isEmpty
                 ? "Scan some photos first so there's something to learn from."
                 : "You have \(app.closet.count) pieces in your closet. Ask your stylist to study them.")
                .font(.subheadline)
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
            Button("Build my taste profile") {
                Task { await app.rebuildProfile() }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(app.closet.isEmpty)
            .opacity(app.closet.isEmpty ? 0.4 : 1)
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
        .padding(.horizontal, 12)
    }
}

struct RebuildingCard: View {
    private let messages = [
        "Studying your closet…",
        "Noticing your palette…",
        "Comparing silhouettes…",
        "Spotting what you reach for…",
        "Finding gaps worth filling…",
        "Writing your style brief…",
    ]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 3.5)) { context in
            let index = Int(context.date.timeIntervalSinceReferenceDate / 3.5) % messages.count
            HStack(spacing: 14) {
                Image(systemName: "wand.and.stars")
                    .font(.title2)
                    .foregroundStyle(Theme.accent)
                    .symbolEffect(.variableColor.iterative, options: .repeating)
                VStack(alignment: .leading, spacing: 4) {
                    Text(messages[index])
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.ink)
                        .contentTransition(.opacity)
                        .animation(.easeInOut, value: index)
                    Text("Deep thinking with Gemini — this can take a minute or two.")
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                }
                Spacer(minLength: 0)
            }
        }
        .card()
    }
}

struct SavedForLaterSection: View {
    @Environment(AppState.self) private var app
    @State private var safariURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Saved for later", icon: "bookmark")
            Text("Looks you kept. Saving one is a sign you liked the aesthetic.")
                .font(.caption)
                .foregroundStyle(Theme.muted)
            VStack(spacing: 0) {
                ForEach(Array(app.looks.enumerated()), id: \.element.id) { index, look in
                    HStack(alignment: .top, spacing: 12) {
                        RemoteImage(url: app.url(look.imageUrl))
                            .frame(width: 64, height: 84)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(look.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.ink)
                                .lineLimit(2)
                            if let note = look.aestheticNote, !note.isEmpty {
                                Text(note)
                                    .font(.caption)
                                    .foregroundStyle(Theme.muted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if let url = URL(string: look.url), !look.url.isEmpty {
                                Button("View product") { safariURL = url }
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Theme.accent)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(12)
                    if index < app.looks.count - 1 { Divider().padding(.leading, 88) }
                }
            }
            .card(padding: 0)
        }
        .sheet(item: $safariURL) { SafariView(url: $0).ignoresSafeArea() }
    }
}

struct ProfileContent: View {
    var profile: TasteProfile

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "In a nutshell", icon: "quote.opening")
                Text(profile.summary)
                    .font(.system(.body, design: .serif))
                    .foregroundStyle(Theme.ink)
                    .lineSpacing(3)
                if let price = profile.priceBand, !price.isEmpty {
                    Label(price, systemImage: "tag")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Theme.olive)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()

            chipSection("Palette", icon: "paintpalette", items: profile.palette, swatches: true)
            chipSection("Silhouettes", icon: "figure.stand", items: profile.silhouettes)
            chipSection("Keywords", icon: "text.word.spacing", items: profile.styleKeywords)
            chipSection("Brands", icon: "bag", items: profile.preferredBrands)

            if !profile.gaps.isEmpty {
                listSection("Gaps to fill", icon: "plus.circle", items: profile.gaps, tint: Theme.olive)
            }
            if !profile.avoid.isEmpty {
                listSection("Steers clear of", icon: "nosign", items: profile.avoid, tint: Theme.accent)
            }

            if !profile.evidence.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader(title: "Why I think so", icon: "magnifyingglass")
                    VStack(spacing: 0) {
                        ForEach(Array(profile.evidence.enumerated()), id: \.offset) { i, ev in
                            EvidenceRow(evidence: ev)
                            if i < profile.evidence.count - 1 { Divider().padding(.leading, 16) }
                        }
                    }
                    .card(padding: 0)
                }
            }

            if let updated = profile.updatedAt, let date = ISO8601DateFormatter.flexible(updated) {
                Text("Updated \(date.formatted(.relative(presentation: .named)))")
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    @ViewBuilder
    private func chipSection(_ title: String, icon: String, items: [String], swatches: Bool = false) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: title, icon: icon)
                ChipGroup(items: items, swatches: swatches, tint: Theme.card)
            }
        }
    }

    private func listSection(_ title: String, icon: String, items: [String], tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: title, icon: icon)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(items, id: \.self) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Circle().fill(tint).frame(width: 6, height: 6)
                        Text(item).font(.subheadline).foregroundStyle(Theme.ink)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
        }
    }
}

struct EvidenceRow: View {
    var evidence: Evidence
    @Environment(AppState.self) private var app
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.snappy) { expanded.toggle() }
            } label: {
                HStack(alignment: .top) {
                    Text(evidence.claim)
                        .font(.subheadline)
                        .foregroundStyle(Theme.ink)
                        .multilineTextAlignment(.leading)
                    Spacer()
                    if !evidence.itemIds.isEmpty {
                        HStack(spacing: 4) {
                            Text("\(evidence.itemIds.count)")
                            Image(systemName: "chevron.down")
                                .rotationEffect(.degrees(expanded ? 180 : 0))
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.muted)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(evidence.itemIds, id: \.self) { id in
                            if let item = app.item(id: id) {
                                RemoteImage(url: app.url(item.cropUrl))
                                    .frame(width: 64, height: 80)
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            }
                        }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(16)
    }
}

extension ISO8601DateFormatter {
    static func flexible(_ string: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: string) { return d }
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: string) { return d }
        // Python isoformat without timezone, e.g. 2026-10-25T11:41:00.123456
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(identifier: "UTC")
        for format in ["yyyy-MM-dd'T'HH:mm:ss.SSSSSS", "yyyy-MM-dd'T'HH:mm:ss"] {
            df.dateFormat = format
            if let d = df.date(from: string) { return d }
        }
        return nil
    }
}
