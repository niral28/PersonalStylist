import SwiftUI

struct ChatView: View {
    @Environment(AppState.self) private var app
    @State private var draft = ""
    @FocusState private var inputFocused: Bool

    static let suggestions = [
        "Find me a jacket I'd like",
        "What's missing from my closet?",
        "Shoes to go with my favorite jeans",
    ]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if app.chat.isEmpty {
                        intro
                    }
                    ForEach(app.chat) { entry in
                        ChatRow(entry: entry)
                            .id(entry.id)
                    }
                    if app.isStreaming {
                        ActivityTicker(text: app.activity ?? "Working…")
                            .id("activity")
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: app.chat.count) {
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: app.activity) {
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
        .background(Theme.background)
        .safeAreaInset(edge: .bottom) { inputBar }
        .navigationTitle("Stylist")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    withAnimation { app.newChat() }
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .accessibilityLabel("New chat")
                .disabled(app.chat.isEmpty && !app.isStreaming)
            }
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(Theme.accent)
                Text("What are we shopping for?")
                    .font(.system(.title2, design: .serif, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Text("I know your closet and your taste. Ask for something specific, or let me find what's missing.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.muted)
            }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Self.suggestions, id: \.self) { s in
                    Button {
                        app.send(s)
                    } label: {
                        HStack {
                            Text(s).font(.subheadline.weight(.medium))
                            Spacer()
                            Image(systemName: "arrow.up.right").font(.caption.weight(.semibold))
                        }
                        .foregroundStyle(Theme.ink)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 13)
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.sand, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.top, 24)
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Ask your stylist…", text: $draft, axis: .vertical)
                .lineLimit(1...4)
                .focused($inputFocused)
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Theme.sand, lineWidth: 1))
                .submitLabel(.send)
                .onSubmit(submit)

            Button {
                if app.isStreaming { app.cancelChat() } else { submit() }
            } label: {
                Image(systemName: app.isStreaming ? "stop.fill" : "arrow.up")
                    .font(.body.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(canSend || app.isStreaming ? Theme.ink : Theme.muted.opacity(0.4), in: Circle())
            }
            .disabled(!canSend && !app.isStreaming)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !app.isStreaming
    }

    private func submit() {
        guard canSend else { return }
        app.send(draft)
        draft = ""
    }
}

struct ChatRow: View {
    var entry: ChatEntry

    var body: some View {
        switch entry.kind {
        case .user(let text):
            HStack {
                Spacer(minLength: 48)
                Text(text)
                    .font(.body)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
                    .background(Theme.ink, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
        case .assistant(let text):
            Text(LocalizedStringKey(text))
                .font(.body)
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .textSelection(.enabled)
        case .thought(let text):
            ThoughtRow(text: text)
        case .tool(let name, let summary):
            HStack(spacing: 8) {
                Image(systemName: Self.icon(for: name))
                    .font(.caption)
                    .foregroundStyle(Theme.accent)
                Text(summary.isEmpty ? name : summary)
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
                    .lineLimit(2)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Theme.sand.opacity(0.6), in: Capsule())
        case .candidates(let list):
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(list) { ProductCardView(candidate: $0) }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
            }
            .padding(.horizontal, -16)
        case .error(let text):
            Label(text, systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.red)
                .padding(12)
                .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    static func icon(for tool: String) -> String {
        let t = tool.lowercased()
        if t.contains("search") { return "magnifyingglass" }
        if t.contains("open") || t.contains("tab") || t.contains("browse") { return "safari" }
        if t.contains("extract") || t.contains("product") { return "tag" }
        if t.contains("closet") { return "hanger" }
        if t.contains("profile") || t.contains("taste") { return "sparkles" }
        if t.contains("click") || t.contains("scroll") { return "cursorarrow.click" }
        return "wrench.and.screwdriver"
    }
}

struct ThoughtRow: View {
    var text: String
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "brain")
                    Text("Thinking")
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.muted)
            }
            .buttonStyle(.plain)

            Text(text)
                .font(.caption)
                .foregroundStyle(Theme.muted)
                .lineLimit(expanded ? nil : 2)
                .padding(.leading, 10)
                .overlay(alignment: .leading) {
                    Rectangle().fill(Theme.sand).frame(width: 2)
                }
        }
    }
}

struct ActivityTicker: View {
    var text: String

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .tint(Theme.accent)
            Text(text)
                .font(.footnote)
                .foregroundStyle(Theme.muted)
                .lineLimit(1)
                .contentTransition(.opacity)
                .animation(.easeInOut, value: text)
                .id(text)
                .transition(.push(from: .bottom))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Theme.card.opacity(0.7), in: Capsule())
        .animation(.easeInOut(duration: 0.3), value: text)
    }
}
