import SwiftUI
import SafariServices

enum Theme {
    static let background = Color(red: 0.969, green: 0.953, blue: 0.933)   // #F7F3EE
    static let card = Color(red: 1.0, green: 0.992, blue: 0.980)           // #FFFDFA
    static let sand = Color(red: 0.918, green: 0.890, blue: 0.851)         // #EAE3D9
    static let ink = Color(red: 0.169, green: 0.141, blue: 0.125)          // #2B2420
    static let muted = Color(red: 0.541, green: 0.498, blue: 0.463)        // #8A7F76
    static let accent = Color(red: 0.702, green: 0.427, blue: 0.290)       // #B36D4A terracotta
    static let olive = Color(red: 0.420, green: 0.463, blue: 0.333)        // #6B7655

    static let cornerRadius: CGFloat = 18
}

struct CardBackground: ViewModifier {
    var padding: CGFloat = 16
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
            .shadow(color: Theme.ink.opacity(0.06), radius: 10, y: 4)
    }
}

extension View {
    func card(padding: CGFloat = 16) -> some View { modifier(CardBackground(padding: padding)) }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(Theme.ink.opacity(configuration.isPressed ? 0.8 : 1), in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Theme.ink)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Theme.sand.opacity(configuration.isPressed ? 0.7 : 1), in: Capsule())
    }
}

/// Remote image (crop or product) with a soft placeholder.
struct RemoteImage: View {
    var url: URL?
    var contentMode: ContentMode = .fill

    var body: some View {
        AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.25))) { phase in
            switch phase {
            case .success(let image):
                image.resizable().aspectRatio(contentMode: contentMode)
            case .failure:
                placeholder(icon: "photo")
            default:
                placeholder(icon: nil)
            }
        }
    }

    private func placeholder(icon: String?) -> some View {
        ZStack {
            Theme.sand
            if let icon {
                Image(systemName: icon).foregroundStyle(Theme.muted)
            } else {
                ProgressView().tint(Theme.muted)
            }
        }
    }
}

/// Wrapping horizontal layout for chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(width: bounds.width, subviews: subviews)
        for row in rows {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row { var indices: [Int] = []; var y: CGFloat = 0; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        var y: CGFloat = 0
        for (i, sub) in subviews.enumerated() {
            let size = sub.sizeThatFits(.unspecified)
            var row = rows[rows.count - 1]
            let needed = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if needed > width && !row.indices.isEmpty {
                y += row.height + spacing
                rows.append(Row(indices: [i], y: y, width: size.width, height: size.height))
                continue
            }
            row.indices.append(i)
            row.width = needed
            row.height = max(row.height, size.height)
            rows[rows.count - 1] = row
        }
        return rows.filter { !$0.indices.isEmpty }
    }
}

struct Chip: View {
    var text: String
    var swatch: Color?
    var tint: Color = Theme.sand

    var body: some View {
        HStack(spacing: 6) {
            if let swatch {
                Circle().fill(swatch)
                    .frame(width: 12, height: 12)
                    .overlay(Circle().stroke(Theme.ink.opacity(0.15), lineWidth: 0.5))
            }
            Text(text)
        }
        .font(.subheadline)
        .foregroundStyle(Theme.ink)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(tint, in: Capsule())
    }
}

struct ChipGroup: View {
    var items: [String]
    var swatches = false
    var tint: Color = Theme.sand

    var body: some View {
        FlowLayout {
            ForEach(items, id: \.self) { item in
                Chip(text: item, swatch: swatches ? ColorNames.color(for: item) : nil, tint: tint)
            }
        }
    }
}

enum ColorNames {
    private static let table: [(String, Color)] = [
        ("charcoal", Color(white: 0.25)), ("black", .black), ("white", .white), ("ivory", Color(red: 1, green: 0.99, blue: 0.94)),
        ("cream", Color(red: 0.98, green: 0.95, blue: 0.87)), ("ecru", Color(red: 0.93, green: 0.90, blue: 0.80)),
        ("off-white", Color(red: 0.97, green: 0.96, blue: 0.92)), ("grey", .gray), ("gray", .gray), ("heather", Color(white: 0.7)),
        ("navy", Color(red: 0.12, green: 0.16, blue: 0.32)), ("indigo", Color(red: 0.2, green: 0.22, blue: 0.45)),
        ("denim", Color(red: 0.32, green: 0.43, blue: 0.6)), ("blue", .blue), ("sky", Color(red: 0.6, green: 0.78, blue: 0.92)),
        ("olive", Color(red: 0.42, green: 0.46, blue: 0.28)), ("sage", Color(red: 0.68, green: 0.73, blue: 0.6)),
        ("khaki", Color(red: 0.76, green: 0.69, blue: 0.5)), ("forest", Color(red: 0.13, green: 0.33, blue: 0.2)),
        ("green", Color(red: 0.25, green: 0.5, blue: 0.3)), ("camel", Color(red: 0.76, green: 0.6, blue: 0.42)),
        ("tan", Color(red: 0.82, green: 0.7, blue: 0.55)), ("beige", Color(red: 0.91, green: 0.85, blue: 0.75)),
        ("sand", Color(red: 0.88, green: 0.8, blue: 0.67)), ("taupe", Color(red: 0.56, green: 0.5, blue: 0.45)),
        ("brown", Color(red: 0.45, green: 0.3, blue: 0.2)), ("chocolate", Color(red: 0.35, green: 0.22, blue: 0.14)),
        ("rust", Color(red: 0.72, green: 0.33, blue: 0.16)), ("terracotta", Color(red: 0.8, green: 0.45, blue: 0.3)),
        ("burgundy", Color(red: 0.5, green: 0.1, blue: 0.18)), ("maroon", Color(red: 0.45, green: 0.1, blue: 0.12)),
        ("red", .red), ("pink", .pink), ("blush", Color(red: 0.95, green: 0.78, blue: 0.76)),
        ("orange", .orange), ("mustard", Color(red: 0.84, green: 0.66, blue: 0.2)), ("yellow", .yellow),
        ("purple", .purple), ("lavender", Color(red: 0.75, green: 0.7, blue: 0.88)), ("teal", .teal),
        ("silver", Color(white: 0.78)), ("gold", Color(red: 0.83, green: 0.69, blue: 0.22)),
    ]

    static func color(for name: String) -> Color {
        let lower = name.lowercased()
        return table.first { lower.contains($0.0) }?.1 ?? Theme.muted.opacity(0.5)
    }
}

struct SectionHeader: View {
    var title: String
    var icon: String

    var body: some View {
        Label(title, systemImage: icon)
            .font(.footnote.weight(.semibold))
            .textCase(.uppercase)
            .tracking(0.8)
            .foregroundStyle(Theme.muted)
    }
}

struct SafariView: UIViewControllerRepresentable {
    var url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }
    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}
