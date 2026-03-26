import ScreenCaptureKit
import AVFoundation

/// Captures system audio alongside screen recording.
@Observable
final class AudioCapture {
    private(set) var isCapturing = false
    private var audioInput: AVAssetWriterInput?

    /// Create an audio input for the asset writer.
    func makeAudioInput() -> AVAssetWriterInput {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 2,
        ]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        audioInput = input
        return input
    }

    /// Append an audio sample buffer from ScreenCaptureKit.
    func appendSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard let input = audioInput, input.isReadyForMoreMediaData else { return }
        input.append(sampleBuffer)
    }

    func start() {
        isCapturing = true
    }

    func stop() {
        audioInput?.markAsFinished()
        audioInput = nil
        isCapturing = false
    }
}
