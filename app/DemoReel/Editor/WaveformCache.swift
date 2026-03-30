import AVFoundation

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

    // MARK: - State

    /// Bump to signal SwiftUI that cached content changed.
    private(set) var generation: Int = 0

    private var cache: [UUID: WaveformData] = [:]       // mediaItemId → data
    private var noAudio: Set<UUID> = []                  // mediaItemIds with no audio track
    private var pendingIds: Set<UUID> = []
    private var pendingTasks: [UUID: Task<Void, Never>] = [:]

    private let targetSamplesPerSecond = 200

    // MARK: - Public API

    /// Pure read — returns downsampled amplitude values for a clip's visible range.
    /// One value per pixel of clip width. Does NOT trigger extraction.
    func waveformSamples(for clip: Clip, pixelsPerSecond: Double, mediaItem: MediaItem?) -> [Float] {
        _ = generation

        guard let mediaItem = mediaItem,
              let data = cache[mediaItem.id] else { return [] }

        let startIdx = Int(clip.sourceStartMs) * data.samplesPerSecond / 1000
        let endIdx = Int(clip.sourceEndMs) * data.samplesPerSecond / 1000
        guard startIdx < endIdx, startIdx < data.samples.count else { return [] }

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

        return result
    }

    /// Request waveform extraction for all clips. Safe to call repeatedly.
    func ensureWaveforms(clips: [Clip], mediaItems: (Clip) -> MediaItem?) {
        var seen: Set<UUID> = []
        for clip in clips {
            guard let mediaItem = mediaItems(clip) else { continue }
            let id = mediaItem.id
            guard !seen.contains(id) else { continue }
            seen.insert(id)
            guard cache[id] == nil, !noAudio.contains(id), !pendingIds.contains(id) else { continue }
            startExtraction(mediaItem: mediaItem)
        }
    }

    /// Cancel all pending extraction tasks.
    func cancelAll() {
        for task in pendingTasks.values { task.cancel() }
        pendingTasks.removeAll()
        pendingIds.removeAll()
    }

    // MARK: - Internals

    private func startExtraction(mediaItem: MediaItem) {
        let mediaItemId = mediaItem.id
        pendingIds.insert(mediaItemId)

        let targetRate = targetSamplesPerSecond
        let task = Task.detached { [weak self] in
            guard let self = self else { return }

            let asset = AVURLAsset(url: mediaItem.fileURL)
            let tracks: [AVAssetTrack]
            do {
                tracks = try await asset.loadTracks(withMediaType: .audio)
            } catch {
                await MainActor.run {
                    self.noAudio.insert(mediaItemId)
                    self.pendingIds.remove(mediaItemId)
                    self.pendingTasks.removeValue(forKey: mediaItemId)
                }
                return
            }

            guard let audioTrack = tracks.first else {
                await MainActor.run {
                    self.noAudio.insert(mediaItemId)
                    self.pendingIds.remove(mediaItemId)
                    self.pendingTasks.removeValue(forKey: mediaItemId)
                }
                return
            }

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

            guard let reader = try? AVAssetReader(asset: asset) else {
                await MainActor.run {
                    self.noAudio.insert(mediaItemId)
                    self.pendingIds.remove(mediaItemId)
                    self.pendingTasks.removeValue(forKey: mediaItemId)
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

            guard !Task.isCancelled else { return }

            let waveformData = WaveformData(samples: samples, samplesPerSecond: targetRate)

            await MainActor.run {
                self.cache[mediaItemId] = waveformData
                self.pendingIds.remove(mediaItemId)
                self.pendingTasks.removeValue(forKey: mediaItemId)
                self.generation += 1
            }
        }

        pendingTasks[mediaItemId] = task
    }
}
