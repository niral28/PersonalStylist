import AVFoundation
import Foundation
import Photos
import UIKit
import Vision

/// A photo library asset chosen for upload, with the `source` the backend expects.
struct ScanTarget: @unchecked Sendable {
    let asset: PHAsset
    let source: String // "photo" | "screenshot" | "video"
}

/// Finds outfit photos + screenshots in the library and uploads them to POST /ingest.
@Observable
@MainActor
final class PhotoScanner {
    enum Phase: Equatable {
        case idle
        case finding
        case uploading
        case videos
        case finished
        case failed(String)
    }

    var phase: Phase = .idle
    var examined = 0
    var selected = 0
    var uploaded = 0
    var itemsFound = 0
    var skipped = 0
    var errors = 0

    var videosSelected = 0
    var videosDone = 0
    /// Human-readable step for the video currently in flight, e.g. "Exporting video 1 of 3".
    var videoStatus: String?

    /// Max number of photos uploaded per scan.
    var limit = 40
    /// Max number of recent short videos uploaded per scan.
    var videoLimit = UserDefaults.standard.object(forKey: "scanner.videoLimit") as? Int ?? 3 {
        didSet { UserDefaults.standard.set(videoLimit, forKey: "scanner.videoLimit") }
    }
    static let maxVideoDuration: TimeInterval = 60
    /// How many recent non-screenshot photos to run person detection on.
    var lookback = 250
    var concurrency = 6

    var isRunning: Bool { phase == .finding || phase == .uploading || phase == .videos }

    var videoProgress: Double {
        guard videosSelected > 0 else { return 0 }
        return Double(videosDone) / Double(videosSelected)
    }

    var progress: Double {
        guard selected > 0 else { return 0 }
        return Double(uploaded + skipped + errors) / Double(selected)
    }

    private static let processedKey = "scanner.processedAssetIds"

    private var processed: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Self.processedKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: Self.processedKey) }
    }

    func resetHistory() {
        UserDefaults.standard.removeObject(forKey: Self.processedKey)
        phase = .idle
    }

    func scan(api: APIClient, onItems: @escaping @MainActor ([ClosetItem]) -> Void) async {
        guard !isRunning else { return }
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else {
            phase = .failed("Photo access not granted")
            return
        }

        examined = 0; selected = 0; uploaded = 0; itemsFound = 0; skipped = 0; errors = 0
        videosSelected = 0; videosDone = 0; videoStatus = nil
        phase = .finding

        let targets = await findTargets(excluding: processed)
        selected = targets.count
        let videos = videoLimit > 0 ? Self.recentShortVideos(max: videoLimit, excluding: processed) : []
        videosSelected = videos.count

        if !targets.isEmpty {
            phase = .uploading
            await uploadPhotos(targets, api: api, onItems: onItems)
        }
        if !videos.isEmpty {
            phase = .videos
            await uploadVideos(videos, api: api, onItems: onItems)
        }

        let succeeded = uploaded + skipped
        if errors > 0 && succeeded == 0 {
            phase = .failed("Couldn't reach the backend")
        } else {
            phase = .finished
        }
    }

    /// Uploads exactly the assets the user picked, bypassing the automatic selection heuristics.
    func scanPicked(assetIds: [String], api: APIClient, asAspirational: Bool = false, onItems: @escaping @MainActor ([ClosetItem]) -> Void) async {
        guard !isRunning, !assetIds.isEmpty else { return }
        examined = 0; selected = 0; uploaded = 0; itemsFound = 0; skipped = 0; errors = 0
        videosSelected = 0; videosDone = 0; videoStatus = nil
        phase = .finding

        var photos: [ScanTarget] = []
        var videos: [ScanTarget] = []
        PHAsset.fetchAssets(withLocalIdentifiers: assetIds, options: nil).enumerateObjects { asset, _, _ in
            switch asset.mediaType {
            case .video:
                videos.append(ScanTarget(asset: asset, source: "video"))
            case .image:
                let source = asAspirational
                    ? "aspirational"
                    : (asset.mediaSubtypes.contains(.photoScreenshot) ? "screenshot" : "photo")
                photos.append(ScanTarget(asset: asset, source: source))
            default:
                break
            }
        }
        selected = photos.count
        videosSelected = videos.count

        if !photos.isEmpty {
            phase = .uploading
            await uploadPhotos(photos, api: api, onItems: onItems)
        }
        if !videos.isEmpty {
            phase = .videos
            await uploadVideos(videos, api: api, onItems: onItems)
        }
        let succeeded = uploaded + skipped
        phase = (errors > 0 && succeeded == 0) ? .failed("Couldn't reach the backend") : .finished
    }

    private func record(_ assetId: String, _ resp: IngestResponse, onItems: @MainActor ([ClosetItem]) -> Void) {
        processed.insert(assetId)
        if resp.skipped == true {
            skipped += 1
        } else {
            uploaded += 1
        }
        if !resp.items.isEmpty {
            itemsFound += resp.items.count
            onItems(resp.items)
        }
    }

    private func uploadPhotos(_ targets: [ScanTarget], api: APIClient, onItems: @escaping @MainActor ([ClosetItem]) -> Void) async {
        let maxInFlight = concurrency
        await withTaskGroup(of: (String, Result<IngestResponse, Error>).self) { group in
            var iterator = targets.makeIterator()
            func addNext() -> Bool {
                guard let target = iterator.next() else { return false }
                group.addTask {
                    do {
                        guard let jpeg = await Self.loadJPEG(target.asset) else {
                            throw APIError.http(0, "Could not load image")
                        }
                        let resp = try await api.ingest(jpeg: jpeg, assetId: target.asset.localIdentifier, source: target.source)
                        return (target.asset.localIdentifier, .success(resp))
                    } catch {
                        return (target.asset.localIdentifier, .failure(error))
                    }
                }
                return true
            }
            for _ in 0..<maxInFlight { if !addNext() { break } }

            for await (assetId, result) in group {
                switch result {
                case .success(let resp):
                    record(assetId, resp, onItems: onItems)
                case .failure:
                    errors += 1
                }
                _ = addNext()
            }
        }
    }

    /// Videos go one at a time: each is a multi-MB upload that the backend watches end to end.
    private func uploadVideos(_ videos: [ScanTarget], api: APIClient, onItems: @escaping @MainActor ([ClosetItem]) -> Void) async {
        for (i, target) in videos.enumerated() {
            let label = "video \(i + 1) of \(videos.count)"
            let assetId = target.asset.localIdentifier
            do {
                videoStatus = "Preparing \(label)…"
                let fileURL = try await Self.exportMP4(target.asset)
                defer { try? FileManager.default.removeItem(at: fileURL) }
                let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
                videoStatus = "Watching \(label) (\(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)))…"
                let resp = try await api.ingestVideo(mp4: data, assetId: assetId)
                record(assetId, resp, onItems: onItems)
            } catch {
                errors += 1
            }
            videosDone += 1
        }
        videoStatus = nil
    }

    // MARK: - Video

    private static func recentShortVideos(max: Int, excluding done: Set<String>) -> [ScanTarget] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = NSPredicate(format: "mediaType == %d AND duration <= %f",
                                        PHAssetMediaType.video.rawValue, maxVideoDuration)
        options.fetchLimit = max * 4
        var out: [ScanTarget] = []
        PHAsset.fetchAssets(with: options).enumerateObjects { asset, _, stop in
            guard !done.contains(asset.localIdentifier), asset.duration > 0.5 else { return }
            out.append(ScanTarget(asset: asset, source: "video"))
            if out.count >= max { stop.pointee = true }
        }
        return out
    }

    /// Exports to a temporary 720p MP4 with location and other personal metadata stripped.
    nonisolated static func exportMP4(_ asset: PHAsset) async throws -> URL {
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .mediumQualityFormat
        options.version = .current

        let session: AVAssetExportSession = try await withCheckedThrowingContinuation { continuation in
            PHImageManager.default().requestExportSession(forVideo: asset, options: options, exportPreset: AVAssetExportPreset1280x720) { session, info in
                if let session {
                    continuation.resume(returning: session)
                } else {
                    let error = info?[PHImageErrorKey] as? Error ?? APIError.http(0, "Video export unavailable")
                    continuation.resume(throwing: error)
                }
            }
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ingest-\(UUID().uuidString)")
            .appendingPathExtension("mp4")
        session.metadataItemFilter = .forSharing()
        session.shouldOptimizeForNetworkUse = true
        try await session.export(to: url, as: .mp4)
        return url
    }

    // MARK: - Selection

    private func findTargets(excluding done: Set<String>) async -> [ScanTarget] {
        var targets: [ScanTarget] = []
        var seen = done

        func add(_ asset: PHAsset, _ source: String) {
            guard targets.count < limit, !seen.contains(asset.localIdentifier) else { return }
            seen.insert(asset.localIdentifier)
            targets.append(ScanTarget(asset: asset, source: source))
        }

        // Screenshots are capped at ~40% so outfit photos get room too.
        let screenshotCap = max(limit * 2 / 5, 1)
        for asset in Self.assets(inSmartAlbum: .smartAlbumScreenshots, max: screenshotCap * 3)
            where targets.count < screenshotCap {
            add(asset, "screenshot")
        }

        for asset in Self.assets(inSmartAlbum: .smartAlbumSelfPortraits, max: limit) where targets.count < limit {
            add(asset, "photo")
        }

        guard targets.count < limit else { return targets }

        // Recent photos (non-screenshots) that contain a person.
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        options.fetchLimit = lookback
        let result = PHAsset.fetchAssets(with: options)
        var candidates: [PHAsset] = []
        result.enumerateObjects { asset, _, _ in
            if !asset.mediaSubtypes.contains(.photoScreenshot), !seen.contains(asset.localIdentifier) {
                candidates.append(asset)
            }
        }

        var index = 0
        let batch = concurrency
        while index < candidates.count && targets.count < limit {
            let slice = candidates[index..<min(index + batch, candidates.count)].map { ScanTarget(asset: $0, source: "photo") }
            index += batch
            let hits: [(Int, Bool)] = await withTaskGroup(of: (Int, Bool).self) { group in
                for (i, t) in slice.enumerated() {
                    group.addTask { (i, await Self.containsPerson(t.asset)) }
                }
                var out: [(Int, Bool)] = []
                for await r in group { out.append(r) }
                return out.sorted { $0.0 < $1.0 }
            }
            examined += slice.count
            for (i, hasPerson) in hits where hasPerson {
                add(slice[i].asset, "photo")
            }
        }
        return targets
    }

    private static func assets(inSmartAlbum subtype: PHAssetCollectionSubtype, max: Int) -> [PHAsset] {
        let collections = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: subtype, options: nil)
        guard let collection = collections.firstObject else { return [] }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = max
        let result = PHAsset.fetchAssets(in: collection, options: options)
        var out: [PHAsset] = []
        result.enumerateObjects { asset, _, _ in
            if asset.mediaType == .image { out.append(asset) }
        }
        return out
    }

    // MARK: - Image loading

    nonisolated static func requestImage(_ asset: PHAsset, maxSide: CGFloat, fast: Bool) async -> UIImage? {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = fast ? .fast : .exact
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false
        let size = CGSize(width: maxSide, height: maxSide)
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestImage(for: asset, targetSize: size, contentMode: .aspectFit, options: options) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }

    /// Re-encoding through UIImage drops EXIF/GPS metadata.
    nonisolated static func loadJPEG(_ asset: PHAsset) async -> Data? {
        guard let image = await requestImage(asset, maxSide: 1024, fast: false) else { return nil }
        return image.jpegData(compressionQuality: 0.7)
    }

    nonisolated static func containsPerson(_ asset: PHAsset) async -> Bool {
        guard let image = await requestImage(asset, maxSide: 320, fast: true),
              let cgImage = image.cgImage else { return false }
        let request = VNDetectHumanRectanglesRequest()
        request.upperBodyOnly = false
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: image.cgOrientation)
        do {
            try handler.perform([request])
            return !(request.results ?? []).filter { $0.confidence > 0.5 }.isEmpty
        } catch {
            return false
        }
    }
}

extension UIImage {
    var cgOrientation: CGImagePropertyOrientation {
        switch imageOrientation {
        case .up: return .up
        case .down: return .down
        case .left: return .left
        case .right: return .right
        case .upMirrored: return .upMirrored
        case .downMirrored: return .downMirrored
        case .leftMirrored: return .leftMirrored
        case .rightMirrored: return .rightMirrored
        @unknown default: return .up
        }
    }

    /// Downscales so the longest side is at most `maxSide`.
    func resized(maxSide: CGFloat) -> UIImage {
        let longest = max(size.width, size.height)
        guard longest > maxSide else { return self }
        let scale = maxSide / longest
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: newSize, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}
