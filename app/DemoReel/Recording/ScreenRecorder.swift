import ScreenCaptureKit
import AVFoundation

/// Wraps ScreenCaptureKit to record a window or display to a .mov file.
@Observable
final class ScreenRecorder: NSObject {
    private(set) var isRecording = false
    private(set) var availableWindows: [SCWindow] = []
    private(set) var availableDisplays: [SCDisplay] = []

    private var stream: SCStream?
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var startTime: CMTime?

    /// Refresh the list of capturable windows and displays.
    func refreshAvailableSources() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        availableWindows = content.windows.filter { $0.isOnScreen && $0.frame.width > 100 }
        availableDisplays = content.displays
    }

    /// Start recording the specified window to a file.
    func startRecording(window: SCWindow, outputURL: URL) async throws {
        guard !isRecording else { return }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        config.width = Int(window.frame.width) * 2
        config.height = Int(window.frame.height) * 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.showsCursor = false
        config.pixelFormat = kCVPixelFormatType_32BGRA

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: config.width,
            AVVideoHeightKey: config.height,
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = true
        writer.add(input)

        assetWriter = writer
        videoInput = input
        startTime = nil

        writer.startWriting()

        let captureStream = SCStream(filter: filter, configuration: config, delegate: self)
        try captureStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: .main)
        try await captureStream.startCapture()
        stream = captureStream
        isRecording = true
    }

    /// Start recording a display to a file.
    func startRecording(display: SCDisplay, outputURL: URL) async throws {
        guard !isRecording else { return }

        let filter = SCContentFilter(
            display: display,
            excludingApplications: [],
            exceptingWindows: []
        )
        let config = SCStreamConfiguration()
        config.width = Int(display.width) * 2
        config.height = Int(display.height) * 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.showsCursor = false
        config.pixelFormat = kCVPixelFormatType_32BGRA

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: config.width,
            AVVideoHeightKey: config.height,
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = true
        writer.add(input)

        assetWriter = writer
        videoInput = input
        startTime = nil

        writer.startWriting()

        let captureStream = SCStream(filter: filter, configuration: config, delegate: self)
        try captureStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: .main)
        try await captureStream.startCapture()
        stream = captureStream
        isRecording = true
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

        let url = writer.outputURL
        assetWriter = nil
        videoInput = nil
        startTime = nil
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
        guard type == .screen,
              let input = videoInput,
              input.isReadyForMoreMediaData else { return }

        if startTime == nil {
            startTime = sampleBuffer.presentationTimeStamp
            assetWriter?.startSession(atSourceTime: startTime!)
        }

        input.append(sampleBuffer)
    }
}

private let log = Logger(subsystem: "com.demoreel.app", category: "ScreenRecorder")
import OSLog
