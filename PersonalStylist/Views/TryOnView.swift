import SwiftUI

/// Drives one POST /tryon stream.
@Observable
@MainActor
final class TryOnSession {
    var status: String?
    var renders: [TryOnRender] = []
    var result: TryOnResult?
    var error: String?
    var isRunning = false
    var options: [TryOnBase] = []
    var selectedBaseId: String?
    var occasion: String?

    static let maxIterations = 3

    private var task: Task<Void, Never>?

    var latest: TryOnRender? { renders.max { $0.iteration < $1.iteration } }

    var bestIteration: Int? {
        result?.bestIteration ?? renders.max { ($0.scores?.overall ?? 0) < ($1.scores?.overall ?? 0) }?.iteration
    }

    func start(api: APIClient, candidateId: String, baseId: String?, context: String) {
        task?.cancel()
        status = baseId == nil ? "Choosing a photo that fits the occasion…" : "Trying this photo…"
        renders = []
        result = nil
        error = nil
        isRunning = true
        if let baseId { selectedBaseId = baseId }
        let trimmed = context.trimmingCharacters(in: .whitespacesAndNewlines)
        let stream = api.tryOn(candidateId: candidateId, baseId: baseId, context: trimmed.isEmpty ? nil : trimmed)
        task = Task { [weak self] in
            do {
                for try await event in stream {
                    self?.handle(event)
                }
            } catch is CancellationError {
            } catch {
                if self?.result == nil { self?.error = error.localizedDescription }
            }
            self?.isRunning = false
            self?.status = nil
        }
    }

    func cancel() {
        task?.cancel()
        isRunning = false
    }

    private func handle(_ event: TryOnEvent) {
        switch event {
        case .status(let text):
            status = text
        case .scene(let scene):
            options = scene.options
            selectedBaseId = scene.selectedId ?? selectedBaseId
            let note = scene.occasion?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            occasion = note.isEmpty ? nil : note
        case .render(let render):
            withAnimation(.spring(duration: 0.5)) {
                renders.removeAll { $0.iteration == render.iteration }
                renders.append(render)
            }
        case .done(let result):
            withAnimation(.spring(duration: 0.6)) { self.result = result }
            isRunning = false
            status = nil
        case .error(let text):
            error = text
            isRunning = false
            status = nil
        }
    }
}

struct TryOnView: View {
    var candidate: Candidate

    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var session = TryOnSession()
    @State private var pinnedIteration: Int?
    @State private var safariURL: URL?
    @State private var savedImageURL: String?
    @State private var isSaving = false
    @State private var saveError: String?

    /// Render shown in the hero: a pinned pass, else the newest.
    private var heroRender: TryOnRender? {
        if let pinned = pinnedIteration, let r = session.renders.first(where: { $0.iteration == pinned }) { return r }
        return session.latest
    }

    private var showingFinal: Bool { session.result != nil && pinnedIteration == nil }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    hero
                    if !session.options.isEmpty {
                        settingPicker
                    }
                    heroOverlay
                    if session.isRunning {
                        ActivityTicker(text: session.status ?? "Working…")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .transition(.opacity)
                    }
                    if let error = session.error {
                        errorCard(error)
                    }
                    if !session.renders.isEmpty {
                        passStrip
                    }
                    if !session.renders.isEmpty {
                        iterations
                    }
                    if heroRender?.imageUrl != nil {
                        saveButton
                    }
                    productCard
                }
                .padding(16)
                .animation(.spring(duration: 0.45), value: session.renders.count)
                .animation(.easeInOut, value: session.isRunning)
            }
            .background(Theme.background)
            .navigationTitle("See it on me")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        session.cancel()
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.subheadline.weight(.semibold))
                    }
                    .accessibilityLabel("Close")
                }
                if !session.isRunning && (session.result != nil || session.error != nil) {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            begin(baseId: session.selectedBaseId)
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .accessibilityLabel("Try again")
                    }
                }
            }
            .sheet(item: $safariURL) { SafariView(url: $0).ignoresSafeArea() }
        }
        .onAppear {
            if session.renders.isEmpty && !session.isRunning && session.result == nil {
                begin(baseId: nil)
            }
        }
        .onDisappear { session.cancel() }
    }

    /// Recent things the user told the stylist, so try-on can pick a setting for the occasion.
    private var chatContext: String {
        app.chat.compactMap { entry -> String? in
            if case .user(let text) = entry.kind { return text }
            return nil
        }.suffix(4).joined(separator: "\n")
    }

    private func begin(baseId: String?) {
        pinnedIteration = nil
        session.start(api: app.api, candidateId: candidate.id, baseId: baseId, context: chatContext)
    }

    private var settingPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Photo")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.muted)
                Spacer()
                if let occasion = session.occasion {
                    Text(occasion)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                        .lineLimit(1)
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(session.options) { option in
                        Button {
                            guard option.id != session.selectedBaseId else { return }
                            begin(baseId: option.id)
                        } label: {
                            VStack(spacing: 6) {
                                RemoteImage(url: app.url(option.imageUrl))
                                    .frame(width: 72, height: 96)
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .stroke(option.id == session.selectedBaseId ? Theme.accent : .clear, lineWidth: 2.5)
                                    )
                                Text(option.label)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(Theme.ink)
                                    .multilineTextAlignment(.center)
                                    .lineLimit(2)
                                    .frame(width: 84)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - Hero

    private var hero: some View {
        let imagePath: String? = showingFinal
            ? (session.result?.imageUrl ?? heroRender?.imageUrl)
            : heroRender?.imageUrl

        return Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: 460)
            .overlay {
                if let path = imagePath {
                    RemoteImage(url: app.url(path))
                        .id(path)
                        .transition(.opacity.combined(with: .scale(scale: 1.02)))
                } else {
                    ZStack {
                        Theme.ink
                        RemoteImage(url: app.url(candidate.imageUrl))
                            .blur(radius: 18)
                            .opacity(0.55)
                        RenderingPlaceholder(active: session.isRunning)
                    }
                }
            }
            .clipped()
        .overlay(alignment: .topLeading) { heroChip.padding(14) }
        .overlay(alignment: .topTrailing) {
            if imagePath != nil {
                RemoteImage(url: app.url(candidate.imageUrl))
                    .frame(width: 76, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.white, lineWidth: 2))
                    .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
                    .padding(14)
            }
        }
        .overlay {
            if session.isRunning && imagePath != nil {
                RefiningShimmer()
                    .allowsHitTesting(false)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: Theme.ink.opacity(0.15), radius: 18, y: 10)
    }

    @ViewBuilder
    private var heroChip: some View {
        if showingFinal {
            Label("Final look", systemImage: "checkmark.seal.fill")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Theme.olive, in: Capsule())
        } else if let r = heroRender {
            Text("Pass \(r.iteration)")
                .font(.caption.weight(.bold))
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
        }
    }

    @ViewBuilder
    private var heroOverlay: some View {
        if showingFinal, let result = session.result {
            ImprovementBadge(baseline: result.baselineScore ?? session.renders.min { $0.iteration < $1.iteration }?.scores?.overall,
                             final: result.finalScore ?? heroRender?.scores?.overall,
                             passes: session.renders.count)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        } else if let r = heroRender, let overall = r.scores?.overall {
            HStack(alignment: .lastTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.isRunning ? "Critiquing & refining…" : "Pass \(r.iteration) score")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.muted)
                    Text(String(format: "%.1f", overall))
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.ink)
                        .contentTransition(.numericText(value: overall))
                }
                Text("/ 10").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.muted)
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
        } else if heroRender == nil && !showingFinal {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(candidate.brand ?? "Virtual try-on")
                        .font(.caption.weight(.semibold))
                        .textCase(.uppercase)
                        .foregroundStyle(Theme.accent)
                    Text(candidate.title)
                        .font(.system(.title3, design: .serif, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(2)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
        }
    }

    // MARK: - Pass strip

    private var passStrip: some View {
        let sorted = session.renders.sorted { $0.iteration < $1.iteration }
        return HStack(spacing: 10) {
            ForEach(sorted) { r in
                Button {
                    withAnimation(.snappy) {
                        pinnedIteration = (pinnedIteration == r.iteration) ? nil : r.iteration
                    }
                } label: {
                    VStack(spacing: 6) {
                        RemoteImage(url: app.url(r.imageUrl))
                            .frame(width: 62, height: 80)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(heroRender?.iteration == r.iteration && !showingFinal ? Theme.accent : .clear, lineWidth: 2.5)
                            )
                        Text("Pass \(r.iteration)")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Theme.muted)
                    }
                }
                .buttonStyle(.plain)
            }
            if session.isRunning && sorted.count < TryOnSession.maxIterations {
                VStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Theme.sand)
                        .frame(width: 62, height: 80)
                        .overlay(ProgressView().tint(Theme.muted))
                    Text("Pass \(sorted.count + 1)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.muted)
                }
            }
            Spacer(minLength: 0)
            if session.result != nil {
                Button {
                    withAnimation(.snappy) { pinnedIteration = nil }
                } label: {
                    Label("Final", systemImage: "checkmark.seal")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .foregroundStyle(showingFinal ? .white : Theme.ink)
                        .background(showingFinal ? Theme.olive : Theme.sand, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Iterations

    private var iterations: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Render → critique → fix", icon: "arrow.triangle.2.circlepath")
            ForEach(session.renders.sorted { $0.iteration > $1.iteration }) { r in
                IterationCard(render: r, isBest: session.result != nil && session.bestIteration == r.iteration)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    // MARK: - Product + error

    private var saveButton: some View {
        let imageURL = heroRender?.imageUrl
        let alreadySaved = imageURL != nil && (savedImageURL == imageURL || app.looks.contains { $0.imageUrl == imageURL })
        return VStack(spacing: 8) {
            Button {
                guard let imageURL, !alreadySaved else { return }
                isSaving = true
                saveError = nil
                Task {
                    do {
                        _ = try await app.saveLook(candidate: candidate, imageUrl: imageURL, iteration: heroRender?.iteration)
                        savedImageURL = imageURL
                    } catch {
                        saveError = error.localizedDescription
                    }
                    isSaving = false
                }
            } label: {
                HStack(spacing: 8) {
                    if isSaving {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: alreadySaved ? "bookmark.fill" : "bookmark")
                    }
                    Text(alreadySaved ? "Saved to Looks" : "Save this look")
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(alreadySaved || isSaving)
            if let saveError {
                Text(saveError).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center)
            }
        }
    }

    private var productCard: some View {
        HStack(spacing: 14) {
            RemoteImage(url: app.url(candidate.imageUrl))
                .frame(width: 70, height: 88)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                if let brand = candidate.brand, !brand.isEmpty {
                    Text(brand)
                        .font(.caption.weight(.semibold))
                        .textCase(.uppercase)
                        .foregroundStyle(Theme.accent)
                }
                Text(candidate.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
                if let price = candidate.price, !price.isEmpty {
                    Text(price).font(.subheadline).foregroundStyle(Theme.muted)
                }
            }
            Spacer(minLength: 0)
            Button {
                safariURL = URL(string: candidate.url)
            } label: {
                Image(systemName: "safari")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(Theme.ink, in: Circle())
            }
            .disabled(URL(string: candidate.url) == nil)
            .accessibilityLabel("Open product")
        }
        .card(padding: 12)
    }

    private func errorCard(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Try-on hit a snag", systemImage: "exclamationmark.triangle")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.red)
            Text(text).font(.footnote).foregroundStyle(Theme.muted)
            Button("Try again") {
                begin(baseId: session.selectedBaseId)
            }
            .buttonStyle(SecondaryButtonStyle())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

// MARK: - Components

struct ImprovementBadge: View {
    var baseline: Double?
    var final: Double?
    var passes: Int

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(passes > 1 ? "Improved over \(passes) passes" : "Scored on first pass")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.muted)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Baseline \(fmt(baseline))")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.muted)
                    Image(systemName: "arrow.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Theme.muted)
                    Text("Final \(fmt(final))")
                        .font(.system(.title2, design: .rounded, weight: .bold))
                        .foregroundStyle(Theme.ink)
                }
            }
            Spacer(minLength: 0)
            if let b = baseline, let f = final {
                let delta = f - b
                Text(String(format: "%@%.1f", delta >= 0 ? "+" : "−", abs(delta)))
                    .font(.system(.title3, design: .rounded, weight: .heavy))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(delta >= 0 ? Theme.olive : Theme.accent, in: Capsule())
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 0)
    }

    private func fmt(_ v: Double?) -> String {
        v.map { String(format: "%.1f", $0) } ?? "–"
    }
}

struct IterationCard: View {
    var render: TryOnRender
    var isBest: Bool
    @Environment(AppState.self) private var app
    @State private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                RemoteImage(url: app.url(render.imageUrl))
                    .frame(width: 104, height: 138)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Pass \(render.iteration)")
                            .font(.system(.headline, design: .serif))
                            .foregroundStyle(Theme.ink)
                        if isBest {
                            Label("Best", systemImage: "crown.fill")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .background(Theme.accent, in: Capsule())
                        }
                        Spacer()
                        if let overall = render.scores?.overall {
                            Text(String(format: "%.1f", overall))
                                .font(.system(.title3, design: .rounded, weight: .bold))
                                .foregroundStyle(ScoreBar.color(for: overall))
                        }
                    }
                    if let scores = render.scores {
                        VStack(spacing: 5) {
                            ForEach(scores.rows.filter { $0.label != "Overall" }, id: \.label) { row in
                                ScoreBar(label: row.label, value: row.value)
                            }
                        }
                    }
                }
            }

            if !render.critique.isEmpty || !render.edits.isEmpty {
                Button {
                    withAnimation(.snappy) { expanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "text.magnifyingglass")
                        Text("Argon's critique")
                        Spacer()
                        Image(systemName: "chevron.down")
                            .rotationEffect(.degrees(expanded ? 180 : 0))
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.muted)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if expanded {
                    VStack(alignment: .leading, spacing: 12) {
                        if !render.critique.isEmpty {
                            Text(render.critique)
                                .font(.subheadline)
                                .foregroundStyle(Theme.ink)
                                .lineSpacing(2)
                                .padding(.leading, 10)
                                .overlay(alignment: .leading) {
                                    Rectangle().fill(Theme.accent.opacity(0.5)).frame(width: 2)
                                }
                        }
                        if !render.edits.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Edits for next pass")
                                    .font(.caption.weight(.semibold))
                                    .textCase(.uppercase)
                                    .tracking(0.6)
                                    .foregroundStyle(Theme.olive)
                                ForEach(Array(render.edits.enumerated()), id: \.offset) { _, edit in
                                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                                        Image(systemName: "wand.and.rays")
                                            .font(.caption)
                                            .foregroundStyle(Theme.olive)
                                        Text(edit)
                                            .font(.footnote)
                                            .foregroundStyle(Theme.ink)
                                    }
                                }
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.olive.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .card(padding: 14)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                .stroke(isBest ? Theme.accent.opacity(0.6) : .clear, lineWidth: 1.5)
        )
    }
}

struct ScoreBar: View {
    var label: String
    var value: Double?
    @State private var appeared = false

    static func color(for value: Double) -> Color {
        switch value {
        case 8...: return Theme.olive
        case 6..<8: return Color(red: 0.80, green: 0.62, blue: 0.25)
        default: return Theme.accent
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(Theme.muted)
                .frame(width: 54, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.sand)
                    if let value {
                        Capsule()
                            .fill(Self.color(for: value))
                            .frame(width: geo.size.width * (appeared ? min(max(value / 10, 0), 1) : 0))
                    }
                }
            }
            .frame(height: 6)
            Text(value.map { String(format: "%.1f", $0) } ?? "–")
                .font(.caption2.weight(.semibold).monospacedDigit())
                .foregroundStyle(Theme.ink)
                .frame(width: 24, alignment: .trailing)
        }
        .onAppear {
            withAnimation(.spring(duration: 0.8).delay(0.1)) { appeared = true }
        }
    }
}

struct RenderingPlaceholder: View {
    var active: Bool

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "person.and.background.dotted")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(.white)
                .symbolEffect(.pulse, isActive: active)
            Text(active ? "Dressing you in it…" : "No render yet")
                .font(.system(.headline, design: .serif))
                .foregroundStyle(.white)
        }
        .shadow(color: .black.opacity(0.3), radius: 6)
    }
}

/// Diagonal light sweep shown over the hero while the next pass is rendering.
struct RefiningShimmer: View {
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.4) / 2.4
            GeometryReader { geo in
                LinearGradient(colors: [.clear, .white.opacity(0.22), .clear],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: geo.size.width * 0.5)
                    .rotationEffect(.degrees(20))
                    .offset(x: -geo.size.width * 0.5 + geo.size.width * 1.6 * t)
                    .frame(maxHeight: .infinity)
            }
        }
        .blendMode(.plusLighter)
    }
}
