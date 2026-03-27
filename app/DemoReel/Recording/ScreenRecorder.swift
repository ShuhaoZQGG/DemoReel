import ScreenCaptureKit
import AVFoundation
import OSLog

private let log = Logger(subsystem: "com.demoreel.app", category: "ScreenRecorder")

/// Wraps ScreenCaptureKit to record a window or display to a .mov file.
@Observable
final class ScreenRecorder: NSObject {
    private(set) var isRecording = false
    private(set) var isPaused = false
    private(set) var availableWindows: [SCWindow] = []
    private(set) var availableDisplays: [SCDisplay] = []
    private(set) var captureRect: CGRect = .zero

    private var stream: SCStream?
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var firstSampleTime: CMTime?
    private var sessionStarted = false
    private let captureQueue = DispatchQueue(label: "com.demoreel.capture", qos: .userInteractive)
    private var pauseStartTime: CMTime?
    private var totalPausedDuration: CMTime = .zero

    /// Refresh the list of capturable windows and displays.
    func refreshAvailableSources() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        availableWindows = content.windows.filter { $0.isOnScreen && $0.frame.width > 100 }
        availableDisplays = content.displays
    }

    /// Start recording with an arbitrary content filter (window, display, or region).
    func startRecording(filter: SCContentFilter, outputURL: URL) async throws {
        guard !isRecording else { return }

        let rect = try await filter.contentRect
        captureRect = rect
        let width = max(Int(rect.size.width) * 2, 640)
        let height = max(Int(rect.size.height) * 2, 480)

        try await startCapture(filter: filter, width: width, height: height, outputURL: outputURL)
    }

    /// Start recording the specified window to a file.
    func startRecording(window: SCWindow, outputURL: URL) async throws {
        guard !isRecording else { return }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let width = Int(window.frame.width) * 2
        let height = Int(window.frame.height) * 2

        try await startCapture(filter: filter, width: width, height: height, outputURL: outputURL)
    }

    /// Start recording a display to a file.
    func startRecording(display: SCDisplay, outputURL: URL) async throws {
        guard !isRecording else { return }

        let filter = SCContentFilter(
            display: display,
            excludingApplications: [],
            exceptingWindows: []
        )
        let width = Int(display.width) * 2
        let height = Int(display.height) * 2

        try await startCapture(filter: filter, width: width, height: height, outputURL: outputURL)
    }

    private func startCapture(filter: SCContentFilter, width: Int, height: Int, outputURL: URL) async throws {
        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.showsCursor = false
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.scalesToFit = true

        // Set up AVAssetWriter with pixel buffer adaptor for raw frame input
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = true

        let sourcePixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: sourcePixelBufferAttributes
        )

        writer.add(input)

        assetWriter = writer
        videoInput = input
        pixelBufferAdaptor = adaptor
        firstSampleTime = nil
        sessionStarted = false

        writer.startWriting()

        let captureStream = SCStream(filter: filter, configuration: config, delegate: self)
        try captureStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
        try await captureStream.startCapture()
        stream = captureStream
        isRecording = true
    }

    /// Pause recording — frames are skipped but the stream stays alive.
    func pause() {
        guard isRecording, !isPaused else { return }
        captureQueue.sync {
            pauseStartTime = CMClockGetTime(CMClockGetHostTimeClock())
        }
        isPaused = true
    }

    /// Resume recording after a pause.
    func resume() {
        guard isRecording, isPaused else { return }
        captureQueue.sync {
            if let start = pauseStartTime {
                let now = CMClockGetTime(CMClockGetHostTimeClock())
                totalPausedDuration = CMTimeAdd(totalPausedDuration, CMTimeSubtract(now, start))
                pauseStartTime = nil
            }
        }
        isPaused = false
    }

    /// Stop recording and finalize the .mov file.
    func stopRecording() async throws -> URL? {
        guard isRecording else { return nil }

        try await stream?.stopCapture()
        stream = nil
        isRecording = false

        guard let writer = assetWriter else { return nil }
        videoInput?.markAsFinished()
        await writer.finishWriting()

        if writer.status == .failed {
            log.error("AssetWriter failed: \(writer.error?.localizedDescription ?? "unknown")")
        }

        let url = writer.outputURL
        assetWriter = nil
        videoInput = nil
        pixelBufferAdaptor = nil
        firstSampleTime = nil
        sessionStarted = false
        isPaused = false
        pauseStartTime = nil
        totalPausedDuration = .zero
        return url
    }
}

extension ScreenRecorder: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        log.error("Stream stopped with error: \(error.localizedDescription)")
        isRecording = false
    }
}

extension ScreenRecorder: SCStreamOutput {
    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen else { return }

        // Skip frames while paused
        guard !isPaused else { return }

        // Extract the pixel buffer from the sample
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        guard let writer = assetWriter, writer.status == .writing,
              let input = videoInput, input.isReadyForMoreMediaData,
              let adaptor = pixelBufferAdaptor else { return }

        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        // Adjust timestamp to remove paused duration for continuous output
        let adjustedTime = CMTimeSubtract(timestamp, totalPausedDuration)

        if !sessionStarted {
            firstSampleTime = adjustedTime
            writer.startSession(atSourceTime: adjustedTime)
            sessionStarted = true
        }

        adaptor.append(pixelBuffer, withPresentationTime: adjustedTime)
    }
}
