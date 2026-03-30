import AVFoundation
import OSLog

private let log = Logger(subsystem: "com.demoreel.app", category: "MicrophoneCapture")

/// Captures microphone audio via AVCaptureSession and writes to an AVAssetWriterInput.
@Observable
final class MicrophoneCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private(set) var isCapturing = false
    private var captureSession: AVCaptureSession?
    private var writerInput: AVAssetWriterInput?
    private let captureQueue = DispatchQueue(label: "com.demoreel.mic", qos: .userInteractive)

    /// Create an audio writer input for the mic track (mono AAC).
    func makeAudioInput() -> AVAssetWriterInput {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 1,
        ]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        writerInput = input
        return input
    }

    /// Request microphone permission. Returns true if granted.
    static func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    /// Start capturing from the default microphone.
    func start() {
        guard !isCapturing else { return }

        let session = AVCaptureSession()
        session.beginConfiguration()

        guard let mic = AVCaptureDevice.default(for: .audio),
              let deviceInput = try? AVCaptureDeviceInput(device: mic),
              session.canAddInput(deviceInput) else {
            log.error("Failed to set up microphone input")
            session.commitConfiguration()
            return
        }
        session.addInput(deviceInput)

        let audioOutput = AVCaptureAudioDataOutput()
        audioOutput.setSampleBufferDelegate(self, queue: captureQueue)
        guard session.canAddOutput(audioOutput) else {
            log.error("Failed to add audio output to capture session")
            session.commitConfiguration()
            return
        }
        session.addOutput(audioOutput)

        session.commitConfiguration()
        session.startRunning()
        captureSession = session
        isCapturing = true
    }

    /// Stop capturing and mark the writer input as finished.
    func stop() {
        captureSession?.stopRunning()
        captureSession = nil
        writerInput?.markAsFinished()
        writerInput = nil
        isCapturing = false
    }

    // MARK: - AVCaptureAudioDataOutputSampleBufferDelegate

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let input = writerInput, input.isReadyForMoreMediaData else { return }
        input.append(sampleBuffer)
    }
}
