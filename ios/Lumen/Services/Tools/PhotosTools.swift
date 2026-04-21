import Foundation
import Photos
import AVFoundation

@MainActor
enum PhotosTools {
    static func searchPhotos(query: String) async -> String {
        let status = await withCheckedContinuation { (cont: CheckedContinuation<PHAuthorizationStatus, Never>) in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { cont.resume(returning: $0) }
        }
        guard status == .authorized || status == .limited else {
            return "Photo library access was denied."
        }

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = 500
        let assets = PHAsset.fetchAssets(with: .image, options: options)

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let now = Date()
        let cal = Calendar.current

        var dateRange: (Date, Date)? = nil
        if trimmed.contains("today") {
            let start = cal.startOfDay(for: now)
            dateRange = (start, now)
        } else if trimmed.contains("yesterday") {
            let start = cal.startOfDay(for: cal.date(byAdding: .day, value: -1, to: now)!)
            let end = cal.startOfDay(for: now)
            dateRange = (start, end)
        } else if trimmed.contains("week") {
            dateRange = (cal.date(byAdding: .day, value: -7, to: now)!, now)
        } else if trimmed.contains("month") {
            dateRange = (cal.date(byAdding: .month, value: -1, to: now)!, now)
        } else if trimmed.contains("year") {
            dateRange = (cal.date(byAdding: .year, value: -1, to: now)!, now)
        }

        let wantFavorites = trimmed.contains("favorite") || trimmed.contains("favourite")
        let wantSelfies = trimmed.contains("selfie")
        let wantVideos = trimmed.contains("video")
        let wantScreenshots = trimmed.contains("screenshot")
        let wantLivePhotos = trimmed.contains("live photo") || trimmed.contains("live")
        let wantPortraits = trimmed.contains("portrait")

        var selfieIDs: Set<String> = []
        if wantSelfies {
            let collections = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .smartAlbumSelfPortraits, options: nil)
            collections.enumerateObjects { coll, _, _ in
                let assetsInAlbum = PHAsset.fetchAssets(in: coll, options: nil)
                assetsInAlbum.enumerateObjects { a, _, _ in selfieIDs.insert(a.localIdentifier) }
            }
        }

        var matches: [PHAsset] = []
        assets.enumerateObjects { asset, _, _ in
            if let range = dateRange, let created = asset.creationDate {
                if created < range.0 || created > range.1 { return }
            }
            if wantFavorites && !asset.isFavorite { return }
            if wantScreenshots && !asset.mediaSubtypes.contains(.photoScreenshot) { return }
            if wantLivePhotos && !asset.mediaSubtypes.contains(.photoLive) { return }
            if wantPortraits && !asset.mediaSubtypes.contains(.photoDepthEffect) { return }
            if wantVideos && asset.mediaType != .video { return }
            if wantSelfies && !selfieIDs.contains(asset.localIdentifier) { return }
            matches.append(asset)
        }

        let total = matches.count
        let totalInLibrary = assets.count
        if trimmed.isEmpty {
            return "Photo library has \(totalInLibrary) images. Most recent: \(formatAssetDate(assets.firstObject?.creationDate))."
        }
        if total == 0 {
            return "No photos match \"\(query)\"."
        }
        let sample = matches.prefix(5).map { formatAssetDate($0.creationDate) }.joined(separator: ", ")
        return "Found \(total) photos matching \"\(query)\". Recent dates: \(sample)."
    }

    static func captureImage() async -> String {
        #if targetEnvironment(simulator)
        return "Camera is unavailable in the simulator. Install on a real device to capture images."
        #else
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        let granted: Bool
        switch status {
        case .authorized:
            granted = true
        case .notDetermined:
            granted = await AVCaptureDevice.requestAccess(for: .video)
        default:
            granted = false
        }
        guard granted else { return "Camera access was denied." }
        guard AVCaptureDevice.default(for: .video) != nil else {
            return "No camera device available."
        }
        return await CameraCaptureController.shared.capture()
        #endif
    }

    private static func formatAssetDate(_ date: Date?) -> String {
        guard let date else { return "unknown date" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

