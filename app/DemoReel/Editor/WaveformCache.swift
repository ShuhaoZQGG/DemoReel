import AVFoundation
import OSLog

private let log = Logger(subsystem: "com.demoreel.app", category: "WaveformCache")

/// Extracts and caches audio waveform data for timeline clip visualization.
///
/// Waveforms are keyed by mediaItemId so they can be shared across clips that
/// reference the same source. Extraction runs asynchronously on import.
@Observable final class WaveformCache {

    // MARK: - Types

    struct WaveformData {
        let samples: [Float]      // Normalized 0...1 amplitude
        let samplesPerSecond: Int  // Downsample rate (200)
    }

    /// Cache key: mediaItemId + audio track index (0 = first/only track, 1 = second track, etc.)
    private struct CacheKey: Hashable {
        let mediaItemId: UUID
        let trackIndex: Int
    }

    // MARK: - State

    /// Bump to signal SwiftUI that cached content changed.
    private(set) var generation: Int = 0

    private var cache: [CacheKey: WaveformData] = [:]
    private var noAudio: Set<CacheKey> = []
    private var pendingKeys: Set<CacheKey> = []
    private var pendingTasks: [CacheKey: Task<Void, Never>] = [:]

    private let targetSamplesPerSecond = 200

    // MARK: - Public API

    /// Pure read — returns downsampled amplitude values for a clip's visible range.
    /// One value per pixel of clip width. Does NOT trigger extraction.
    func waveformSamples(for clip: Clip, pixelsPerSecond: Double, mediaItem: MediaItem?) -> [Float] {
        _ = generation

        guard let mediaItem = mediaItem else {
            log.debug("waveformSamples: mediaItem is nil")
            return []
        }
        let key = CacheKey(mediaItemId: mediaItem.id, trackIndex: 0)
        guard let data = cache[key] else {
            log.debug("waveformSamples: no cache for mediaItem \(mediaItem.id) track 0, cache has \(self.cache.count) entries, noAudio=\(self.noAudio.contains(key)), pending=\(self.pendingKeys.contains(key))")
            return []
        }

        let startIdx = Int(clip.sourceStartMs) * data.samplesPerSecond / 1000
        let endIdx = Int(clip.sourceEndMs) * data.samplesPerSecond / 1000
        guard startIdx < endIdx, startIdx < data.samples.count else {
            log.debug("waveformSamples: invalid range startIdx=\(startIdx) endIdx=\(endIdx) samples=\(data.samples.count)")
            return []
        }

        let clampedEnd = min(endIdx, data.samples.count)
        let sourceSamples = Array(data.samples[startIdx..<clampedEnd])
        guard !sourceSamples.isEmpty else { return [] }

        let clipWidthPx = clip.sourceDuration * pixelsPerSecond
        let pixelCount = max(1, Int(clipWidthPx))
        guard pixelCount > 0 else { return [] }

        // Aggregate: one max-amplitude value per pixel
        let samplesPerPixel = Double(sourceSamples.count) / Double(pixelCount)
        var result: [Float] = []
        result.reserveCapacity(pixelCount)

        for i in 0..<pixelCount {
            let lo = Int(Double(i) * samplesPerPixel)
            let hi = min(Int(Double(i + 1) * samplesPerPixel), sourceSamples.count)
            guard lo < hi else {
                result.append(0)
                continue
            }
            var maxAmp: Float = 0
            for j in lo..<hi {
                maxAmp = max(maxAmp, sourceSamples[j])
            }
            result.append(maxAmp)
        }

        log.debug("waveformSamples: returning \(result.count) samples for clip sourceMs=\(clip.sourceStartMs)-\(clip.sourceEndMs)")
        return result
    }

    /// Overload for AudioClip — same logic, different source type.
    func waveformSamples(for clip: AudioClip, pixelsPerSecond: Double, mediaItem: MediaItem?) -> [Float] {
        _ = generation

        guard let mediaItem = mediaItem else { return [] }
        let key = CacheKey(mediaItemId: mediaItem.id, trackIndex: clip.trackIndex)
        guard let data = cache[key] else { return [] }

        let startIdx = Int(clip.sourceStartMs) * data.samplesPerSecond / 1000
        let endIdx = Int(clip.sourceEndMs) * data.samplesPerSecond / 1000
        guard startIdx < endIdx, startIdx < data.samples.count else { return [] }

        let clampedEnd = min(endIdx, data.samples.count)
        let sourceSamples = Array(data.samples[startIdx..<clampedEnd])
        guard !sourceSamples.isEmpty else { return [] }

        let clipWidthPx = clip.sourceDuration * pixelsPerSecond
        let pixelCount = max(1, Int(clipWidthPx))

        let samplesPerPixel = Double(sourceSamples.count) / Double(pixelCount)
        var result: [Float] = []
        result.reserveCapacity(pixelCount)

        for i in 0..<pixelCount {
            let lo = Int(Double(i) * samplesPerPixel)
            let hi = min(Int(Double(i + 1) * samplesPerPixel), sourceSamples.count)
            guard lo < hi else { result.append(0); continue }
            var maxAmp: Float = 0
            for j in lo..<hi { maxAmp = max(maxAmp, sourceSamples[j]) }
            result.append(maxAmp)
        }
        return result
    }

    /// Request waveform extraction for all video clips (track 0). Safe to call repeatedly.
    func ensureWaveforms(clips: [Clip], mediaItems: (Clip) -> MediaItem?) {
        var seen: Set<CacheKey> = []
        for clip in clips {
            guard let mediaItem = mediaItems(clip) else { continue }
            let key = CacheKey(mediaItemId: mediaItem.id, trackIndex: 0)
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            guard cache[key] == nil, !noAudio.contains(key), !pendingKeys.contains(key) else { continue }
            startExtraction(mediaItem: mediaItem, trackIndex: 0)
        }
    }

    /// Request waveform extraction for audio clips (per track index).
    func ensureWaveforms(audioClips: [AudioClip], mediaItems: (AudioClip) -> MediaItem?) {
        var seen: Set<CacheKey> = []
        for clip in audioClips {
            guard let mediaItem = mediaItems(clip) else { continue }
            let key = CacheKey(mediaItemId: mediaItem.id, trackIndex: clip.trackIndex)
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            guard cache[key] == nil, !noAudio.contains(key), !pendingKeys.contains(key) else { continue }
            startExtraction(mediaItem: mediaItem, trackIndex: clip.trackIndex)
        }
    }

    /// Cancel all pending extraction tasks.
    func cancelAll() {
        for task in pendingTasks.values { task.cancel() }
        pendingTasks.removeAll()
        pendingKeys.removeAll()
    }

    // MARK: - Internals

    private func startExtraction(mediaItem: MediaItem, trackIndex: Int) {
        let key = CacheKey(mediaItemId: mediaItem.id, trackIndex: trackIndex)
        pendingKeys.insert(key)

        let targetRate = targetSamplesPerSecond
        let task = Task.detached { [weak self] in
            guard let self = self else { return }

            log.info("Starting waveform extraction for \(mediaItem.fileURL.lastPathComponent) track \(trackIndex)")
            let asset = AVURLAsset(url: mediaItem.fileURL)
            let tracks: [AVAssetTrack]
            do {
                tracks = try await asset.loadTracks(withMediaType: .audio)
            } catch {
                log.warning("No audio tracks found: \(error.localizedDescription)")
                await MainActor.run {
                    self.noAudio.insert(key)
                    self.pendingKeys.remove(key)
                    self.pendingTasks.removeValue(forKey: key)
                }
                return
            }

            guard trackIndex < tracks.count else {
                log.warning("Track index \(trackIndex) out of range (asset has \(tracks.count) audio tracks)")
                await MainActor.run {
                    self.noAudio.insert(key)
                    self.pendingKeys.remove(key)
                    self.pendingTasks.removeValue(forKey: key)
                }
                return
            }
            let audioTrack = tracks[trackIndex]
            log.info("Found audio track \(trackIndex), format: \(audioTrack.formatDescriptions)")

            // Use 48kHz to match ScreenCaptureKit's native audio rate.
            // AVFoundation resamples automatically if the source differs.
            let sourceRate: Double = 48000
            let outputSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
                AVNumberOfChannelsKey: 1,
                AVSampleRateKey: sourceRate,
            ]

            let reader: AVAssetReader
            do {
                reader = try AVAssetReader(asset: asset)
            } catch {
                log.error("Failed to create AVAssetReader: \(error.localizedDescription)")
                await MainActor.run {
                    self.noAudio.insert(key)
                    self.pendingKeys.remove(key)
                    self.pendingTasks.removeValue(forKey: key)
                }
                return
            }

            let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: outputSettings)
            reader.add(output)
            reader.startReading()

            let chunkSize = Int(sourceRate) / targetRate  // ~220 samples per waveform sample
            var samples: [Float] = []
            var buffer: [Float] = []

            while reader.status == .reading {
                if Task.isCancelled { break }

                guard let sampleBuffer = output.copyNextSampleBuffer(),
                      let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
                    continue
                }

                let length = CMBlockBufferGetDataLength(blockBuffer)
                let floatCount = length / MemoryLayout<Float>.size
                var data = [Float](repeating: 0, count: floatCount)
                CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: &data)

                for sample in data {
                    buffer.append(abs(sample))
                    if buffer.count >= chunkSize {
                        samples.append(buffer.max() ?? 0)
                        buffer.removeAll(keepingCapacity: true)
                    }
                }
            }

            // Flush remaining
            if !buffer.isEmpty {
                samples.append(buffer.max() ?? 0)
            }

            // Normalize to 0...1
            let peak = samples.max() ?? 1
            if peak > 0 {
                for i in samples.indices {
                    samples[i] /= peak
                }
            }

            if reader.status == .failed {
                log.error("AVAssetReader failed: \(reader.error?.localizedDescription ?? "unknown")")
            }

            guard !Task.isCancelled else { return }

            log.info("Extracted \(samples.count) waveform samples (peak: \(peak))")
            let waveformData = WaveformData(samples: samples, samplesPerSecond: targetRate)

            await MainActor.run {
                self.cache[key] = waveformData
                self.pendingKeys.remove(key)
                self.pendingTasks.removeValue(forKey: key)
                self.generation += 1
            }
        }

        pendingTasks[key] = task
    }
}
