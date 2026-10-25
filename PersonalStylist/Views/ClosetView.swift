import PhotosUI
import SwiftUI

struct ClosetView: View {
    enum Filter: String, CaseIterable {
        case worn = "Worn"
        case aspirational = "Aspirational"
        case looks = "Looks"
    }

    @Environment(AppState.self) private var app
    @State private var filter: Filter = .worn
    @State private var selected: ClosetItem?
    @State private var selectedLook: SavedLook?
    @State private var pickedItems: [PhotosPickerItem] = []

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 12)]

    private var items: [ClosetItem] {
        app.closet.filter { filter == .worn ? $0.isWorn : !$0.isWorn }
    }

    var body: some View {
        VStack(spacing: 12) {
            filterBar
                .padding(.horizontal, 16)
                .padding(.top, 8)
            ScrollView {
                VStack(spacing: 16) {
                    ScanBanner()
                    closetBody
                }
                .padding(16)
            }
            .refreshable {
                await app.loadCloset()
                await app.loadLooks()
            }
        }
        .background(Theme.background)
        .navigationTitle("Closet")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    app.startScan()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "plus.viewfinder")
                        Text("Scan more")
                    }
                    .font(.subheadline.weight(.medium))
                }
                .disabled(app.scanner.isRunning)
            }
            ToolbarItem(placement: .topBarTrailing) {
                PhotosPicker(selection: $pickedItems,
                             maxSelectionCount: 30,
                             matching: .any(of: [.images, .videos]),
                             photoLibrary: .shared()) {
                    Image(systemName: "photo.badge.plus")
                }
                .accessibilityLabel("Add specific photos")
                .disabled(app.scanner.isRunning)
            }
        }
        .onChange(of: pickedItems) { _, items in
            let ids = items.compactMap(\.itemIdentifier)
            pickedItems = []
            if !ids.isEmpty { app.scanPicked(assetIds: ids, asAspirational: filter == .aspirational) }
        }
        .sheet(item: $selected) { item in
            ClosetItemDetailView(item: item)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $selectedLook) { look in
            SavedLookDetailView(look: look)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    private var filterBar: some View {
        HStack(spacing: 4) {
            ForEach(Filter.allCases, id: \.self) { option in
                Button {
                    withAnimation(.snappy) { filter = option }
                } label: {
                    VStack(spacing: 1) {
                        Text(option.rawValue)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Text("\(count(option))")
                            .font(.caption2.weight(.medium).monospacedDigit())
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .foregroundStyle(filter == option ? Theme.ink : Theme.muted)
                    .background(filter == option ? Theme.card : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Theme.sand, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private var closetBody: some View {
        if filter == .looks {
            looksGrid
        } else if items.isEmpty {
            emptyState
        } else {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(items) { item in
                    ClosetTile(item: item)
                        .onTapGesture { selected = item }
                        .contextMenu {
                            Button(role: .destructive) {
                                Task { await app.delete(item) }
                            } label: {
                                Label("Remove from closet", systemImage: "trash")
                            }
                        }
                        .transition(.scale.combined(with: .opacity))
                }
            }
        }
    }

    private var looksGrid: some View {
        Group {
            if app.looks.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "person.crop.rectangle")
                        .font(.system(size: 40, weight: .light))
                        .foregroundStyle(Theme.muted)
                    Text("No saved looks yet")
                        .font(.headline)
                        .foregroundStyle(Theme.ink)
                    Text("Tap See it on me, then Save this look. The product link is kept with it.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.muted)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 48)
            } else {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(app.looks) { look in
                        VStack(alignment: .leading, spacing: 6) {
                            RemoteImage(url: app.url(look.imageUrl))
                                .frame(height: 150)
                                .frame(maxWidth: .infinity)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            Text(look.title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Theme.ink)
                                .lineLimit(2)
                            if let price = look.price, !price.isEmpty {
                                Text(price).font(.caption2).foregroundStyle(Theme.muted)
                            }
                        }
                        .onTapGesture { selectedLook = look }
                        .contextMenu {
                            Button(role: .destructive) {
                                Task { await app.deleteLook(look) }
                            } label: {
                                Label("Remove look", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
    }

    private func count(_ f: Filter) -> Int {
        switch f {
        case .worn: return app.closet.filter(\.isWorn).count
        case .aspirational: return app.closet.filter { !$0.isWorn }.count
        case .looks: return app.looks.count
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: filter == .worn ? "hanger" : "star")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Theme.muted)
            Text(filter == .worn ? "No worn pieces yet" : "No aspirational pieces yet")
                .font(.headline)
                .foregroundStyle(Theme.ink)
            Text(filter == .worn
                 ? "Items you're wearing in your photos show up here."
                 : "Photos you add on this tab, and screenshots, show up here.")
                .font(.subheadline)
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
            if !app.scanner.isRunning {
                Button("Scan my photos") { app.startScan() }
                    .buttonStyle(SecondaryButtonStyle())
                    .frame(maxWidth: 220)
                    .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }
}

struct ClosetTile: View {
    var item: ClosetItem
    @Environment(AppState.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Color.clear
                .aspectRatio(0.8, contentMode: .fit)
                .overlay { RemoteImage(url: app.url(item.cropUrl)) }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(alignment: .bottomLeading) {
                    if let ts = item.sourceTimestamp, !ts.isEmpty {
                        VideoBadge(timestamp: ts, compact: true).padding(6)
                    }
                }
            Text(item.name)
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.ink)
                .lineLimit(2, reservesSpace: true)
        }
    }
}

struct ScanBanner: View {
    @Environment(AppState.self) private var app

    var body: some View {
        let s = app.scanner
        Group {
            switch s.phase {
            case .finding:
                banner(icon: "viewfinder", title: "Finding outfit photos…",
                       detail: "Looked at \(s.examined) photos · \(s.selected) picked", progress: nil)
            case .uploading:
                banner(icon: "sparkles", title: "Building your closet…",
                       detail: "\(s.uploaded + s.skipped) of \(s.selected) photos · \(s.itemsFound) items found",
                       progress: s.progress)
            case .videos:
                banner(icon: "video", title: s.videoStatus ?? "Watching your videos…",
                       detail: "\(s.videosDone) of \(s.videosSelected) videos · \(s.itemsFound) items found",
                       progress: s.videoProgress)
            case .failed(let message):
                banner(icon: "exclamationmark.triangle", title: "Scan stopped", detail: message, progress: nil)
            case .finished where s.selected == 0 && s.videosSelected == 0:
                banner(icon: "checkmark.circle", title: "All caught up", detail: "No new outfit photos found.", progress: nil)
            default:
                EmptyView()
            }
        }
        .animation(.easeInOut, value: s.phase)
    }

    private func banner(icon: String, title: String, detail: String, progress: Double?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(Theme.accent)
                    .symbolEffect(.pulse, isActive: app.scanner.isRunning)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                    Text(detail).font(.caption).foregroundStyle(Theme.muted).contentTransition(.numericText())
                }
                Spacer()
                if app.scanner.isRunning && progress == nil {
                    ProgressView().tint(Theme.muted)
                }
            }
            if let progress {
                ProgressView(value: progress).tint(Theme.accent)
            }
        }
        .card(padding: 14)
    }
}

struct VideoBadge: View {
    var timestamp: String
    var compact: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "play.fill")
            Text(compact ? timestamp : "from video \(timestamp)")
                .monospacedDigit()
        }
        .font(compact ? .caption2.weight(.semibold) : .caption.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, compact ? 6 : 9)
        .padding(.vertical, compact ? 3 : 5)
        .background(Theme.ink.opacity(0.75), in: Capsule())
    }
}

struct ClosetItemDetailView: View {
    var item: ClosetItem
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    RemoteImage(url: app.url(item.cropUrl), contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: 320)
                        .background(Theme.sand)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))

                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.category.capitalized)
                            .font(.caption.weight(.semibold))
                            .textCase(.uppercase)
                            .foregroundStyle(Theme.accent)
                        Text(item.name.capitalized)
                            .font(.system(.title2, design: .serif, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                        Label(item.isWorn ? "You wear this" : "Saved as inspiration",
                              systemImage: item.isWorn ? "person.fill.checkmark" : "star")
                            .font(.footnote)
                            .foregroundStyle(Theme.muted)
                        if let ts = item.sourceTimestamp, !ts.isEmpty {
                            VideoBadge(timestamp: ts, compact: false).padding(.top, 2)
                        }
                    }

                    VStack(spacing: 0) {
                        attribute("Brand", item.brand)
                        attribute("Material", item.material)
                        attribute("Pattern", item.pattern)
                        attribute("Fit", item.fit)
                    }
                    .card(padding: 0)

                    if !item.colors.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            SectionHeader(title: "Colors", icon: "paintpalette")
                            ChipGroup(items: item.colors, swatches: true)
                        }
                    }
                    if !item.styleTags.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            SectionHeader(title: "Style", icon: "tag")
                            ChipGroup(items: item.styleTags)
                        }
                    }

                    Button(role: .destructive) {
                        Task {
                            await app.delete(item)
                            dismiss()
                        }
                    } label: {
                        Label("Remove from closet", systemImage: "trash")
                            .font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity)
                    }
                    .padding(.top, 8)
                }
                .padding(20)
            }
            .background(Theme.background)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func attribute(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            HStack {
                Text(label).font(.subheadline).foregroundStyle(Theme.muted)
                Spacer()
                Text(value.capitalized).font(.subheadline.weight(.medium)).foregroundStyle(Theme.ink)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
        }
    }
}

struct SavedLookDetailView: View {
    var look: SavedLook
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var safariURL: URL?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    RemoteImage(url: app.url(look.imageUrl), contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: 420)
                        .background(Theme.sand)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))

                    VStack(alignment: .leading, spacing: 6) {
                        if let brand = look.brand, !brand.isEmpty {
                            Text(brand)
                                .font(.caption.weight(.semibold))
                                .textCase(.uppercase)
                                .foregroundStyle(Theme.accent)
                        }
                        Text(look.title)
                            .font(.system(.title2, design: .serif, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                        if let price = look.price, !price.isEmpty {
                            Text(price).font(.subheadline).foregroundStyle(Theme.muted)
                        }
                    }

                    if let url = URL(string: look.url), !look.url.isEmpty {
                        Button {
                            safariURL = url
                        } label: {
                            Label("Open product", systemImage: "safari")
                        }
                        .buttonStyle(PrimaryButtonStyle())
                    }

                    Button(role: .destructive) {
                        Task {
                            await app.deleteLook(look)
                            dismiss()
                        }
                    } label: {
                        Label("Remove look", systemImage: "trash")
                            .font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(20)
            }
            .background(Theme.background)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $safariURL) { SafariView(url: $0).ignoresSafeArea() }
        }
    }
}
