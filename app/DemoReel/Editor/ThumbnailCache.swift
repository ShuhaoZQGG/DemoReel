import AppKit
import AVFoundation

/// Generates and caches video frame thumbnails for timeline clip segments.
///
/// Thumbnails are keyed by (mediaItemId, sourceTimeMs) so they can be shared across
/// clips that reference the same source. An LRU eviction policy caps memory at ~500 entries.
@Observable final class ThumbnailCache {

    // MARK: - Types

    struct ThumbnailKey: Hashable {
        let mediaItemId: UUID
        let sourceTimeMs: UInt64
    }

    // MARK: - State

    /// Bump this counter to signal SwiftUI that cached content changed.
    /// Avoids observing the entire dictionary (which would re-render on every insert).
    private(set) var generation: Int = 0

    // Not observed — internal storage only.
    private var cache: [ThumbnailKey: NSImage] = [:]
    private var accessOrder: [ThumbnailKey] = []
    private var pendingClips: Set<UUID> = []
    private var pendingTasks: [UUID: Task<Void, Never>] = [:]
    private var generatorCache: [UUID: AVAssetImageGenerator] = [:]
    private var zoomGeneratorCache: [UUID: AVAssetImageGenerator] = [:]
    private var zoomPreviewCache: [ThumbnailKey: NSImage] = [:]

    private let maxEntries = 500
    private let thumbnailSize = CGSize(width: 80, height: 45)
    private let zoomPreviewSize = CGSize(width: 960, height: 540)

    // MARK: - Public API

    /// Pure read — returns whatever is cached for this clip right now.
    /// Does NOT trigger generation. Call `ensureThumbnails` separately.
    func thumbnails(for clip: Clip, pixelsPerSecond: Double, mediaItem: MediaItem?) -> [NSImage] {
        // Access `generation` so SwiftUI tracks this dependency.
        _ = generation

        guard let mediaItem = mediaItem else { return [] }
        let sampleTimesMs = sampleTimes(for: clip, pixelsPerSecond: pixelsPerSecond)

        var result: [NSImage] = []
        for timeMs in sampleTimesMs {
            let key = ThumbnailKey(mediaItemId: mediaItem.id, sourceTimeMs: timeMs)
            if let image = cache[key] { result.append(image) }
        }
        return result
    }

    /// Request thumbnails for all clips. Safe to call repeatedly — skips clips
    /// that already have a pending or completed request at this zoom level.
    func ensureThumbnails(clips: [Clip], pixelsPerSecond: Double, mediaItems: (Clip) -> MediaItem?) {
        for clip in clips {
            guard let mediaItem = mediaItems(clip) else { continue }
            let sampleTimesMs = sampleTimes(for: clip, pixelsPerSecond: pixelsPerSecond)
            let mediaItemId = mediaItem.id

            let missingTimes = sampleTimesMs.filter { timeMs in
                cache[ThumbnailKey(mediaItemId: mediaItemId, sourceTimeMs: timeMs)] == nil
            }
            guard !missingTimes.isEmpty else { continue }
            guard !pendingClips.contains(clip.id) else { continue }

            startGeneration(clipId: clip.id, mediaItem: mediaItem, missingTimes: missingTimes)
        }
    }

    /// Cancel all pending work and regenerate (e.g. on zoom level change).
    func invalidateAndRegenerate(clips: [Clip], pixelsPerSecond: Double, mediaItems: (Clip) -> MediaItem?) {
        for task in pendingTasks.values { task.cancel() }
        pendingTasks.removeAll()
        pendingClips.removeAll()
        ensureThumbnails(clips: clips, pixelsPerSecond: pixelsPerSecond, mediaItems: mediaItems)
    }

    /// Cancels all pending requests and clears generator cache.
    func cancelAll() {
        for task in pendingTasks.values { task.cancel() }
        pendingTasks.removeAll()
        pendingClips.removeAll()
        generatorCache.removeAll()
        zoomGeneratorCache.removeAll()
        zoomPreviewCache.removeAll()
    }

    // MARK: - Zoom Preview

    /// Generate (or return cached) a high-res frame for the zoom preview popover.
    /// The zoom transform is applied in the view via scaleEffect to match PreviewView behavior.
    @MainActor
    func zoomPreviewFrame(
        mediaItem: MediaItem,
        sourceTimeMs: UInt64
    ) async -> NSImage? {
        let key = ThumbnailKey(mediaItemId: mediaItem.id, sourceTimeMs: sourceTimeMs)
        if let cached = zoomPreviewCache[key] { return cached }

        let generator = zoomImageGenerator(for: mediaItem)
        let cmTime = CMTime(value: Int64(sourceTimeMs), timescale: 1000)

        let cgImage: CGImage
        do {
            cgImage = try generator.copyCGImage(at: cmTime, actualTime: nil)
        } catch {
            return nil
        }

        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        // Keep cache small — only hold a few recent frames
        if zoomPreviewCache.count > 10 {
            zoomPreviewCache.removeAll()
        }
        zoomPreviewCache[key] = nsImage
        return nsImage
    }

    // MARK: - Internals

    /// Computes evenly-spaced sample times within a clip's source range.
    /// One thumbnail per ~60px of clip width.
    func sampleTimes(for clip: Clip, pixelsPerSecond: Double) -> [UInt64] {
        let clipWidthPx = clip.sourceDuration * pixelsPerSecond
        guard clipWidthPx > 4 else { return [] }

        let thumbWidthPx: Double = 60
        let count = max(1, Int((clipWidthPx / thumbWidthPx).rounded()))
        let intervalMs = (clip.sourceEndMs - clip.sourceStartMs) / UInt64(max(count, 1))
        guard intervalMs > 0 else { return [clip.sourceStartMs] }

        var times: [UInt64] = []
        for i in 0..<count {
            times.append(clip.sourceStartMs + UInt64(i) * intervalMs)
        }
        return times
    }

    private func startGeneration(clipId: UUID, mediaItem: MediaItem, missingTimes: [UInt64]) {
        pendingClips.insert(clipId)
        let mediaItemId = mediaItem.id

        let task = Task.detached { [weak self] in
            guard let self = self else { return }
            let generator = await self.imageGenerator(for: mediaItem)

            for timeMs in missingTimes {
                if Task.isCancelled { break }

                let cmTime = CMTime(value: Int64(timeMs), timescale: 1000)
                do {
                    let cgImage = try generator.copyCGImage(at: cmTime, actualTime: nil)
                    let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                    await MainActor.run {
                        let key = ThumbnailKey(mediaItemId: mediaItemId, sourceTimeMs: timeMs)
                        self.insertCached(key: key, image: nsImage)
                    }
                } catch {
                    // Frame extraction failed — skip
                }
            }

            await MainActor.run {
                self.pendingClips.remove(clipId)
                self.pendingTasks.removeValue(forKey: clipId)
                // Bump generation once per completed clip, not per thumbnail.
                self.generation += 1
            }
        }

        pendingTasks[clipId] = task
    }

    @MainActor
    private func imageGenerator(for mediaItem: MediaItem) -> AVAssetImageGenerator {
        if let existing = generatorCache[mediaItem.id] {
            return existing
        }
        let asset = AVURLAsset(url: mediaItem.fileURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.maximumSize = thumbnailSize
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        generatorCache[mediaItem.id] = generator
        return generator
    }

    @MainActor
    private func zoomImageGenerator(for mediaItem: MediaItem) -> AVAssetImageGenerator {
        if let existing = zoomGeneratorCache[mediaItem.id] {
            return existing
        }
        let asset = AVURLAsset(url: mediaItem.fileURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.maximumSize = zoomPreviewSize
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)
        zoomGeneratorCache[mediaItem.id] = generator
        return generator
    }

    private func insertCached(key: ThumbnailKey, image: NSImage) {
        cache[key] = image
        accessOrder.removeAll { $0 == key }
        accessOrder.append(key)
        evictIfNeeded()
    }

    private func evictIfNeeded() {
        while cache.count > maxEntries, let oldest = accessOrder.first {
            cache.removeValue(forKey: oldest)
            accessOrder.removeFirst()
        }
    }
}
