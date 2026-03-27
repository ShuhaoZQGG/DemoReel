import AVFoundation
import CoreGraphics
import AppKit
import SwiftUI

/// Native macOS video exporter that uses SwiftUI's ImageRenderer to render
/// each frame with the EXACT same view pipeline as the preview — guaranteeing
/// pixel-perfect output matching what the user sees in the editor.
final class NativeExporter {
    private let config: ExportConfig
    private let onProgress: (ExportProgress) -> Void
    private let onComplete: (String) -> Void
    private let onError: (String) -> Void

    init(config: ExportConfig,
         onProgress: @escaping (ExportProgress) -> Void,
         onComplete: @escaping (String) -> Void,
         onError: @escaping (String) -> Void) {
        self.config = config
        self.onProgress = onProgress
        self.onComplete = onComplete
        self.onError = onError
    }

    func export() {
        do {
            try runExport()
        } catch {
            onError(error.localizedDescription)
        }
    }

    private func fail(_ msg: String) -> NSError {
        NSError(domain: "NativeExporter", code: 1, userInfo: [NSLocalizedDescriptionKey: msg])
    }

    /// Render a SwiftUI view to CGImage on the main thread (ImageRenderer requirement).
    private func renderOnMain(_ view: ExportFrameView, size: CGSize) -> CGImage? {
        var result: CGImage?
        DispatchQueue.main.sync {
            let renderer = ImageRenderer(content: view)
            renderer.proposedSize = ProposedViewSize(size)
            renderer.scale = 1.0
            result = renderer.cgImage
        }
        return result
    }

    private func runExport() throws {
        onProgress(ExportProgress(percent: 1, stage: "Preparing..."))

        // --- Load source video ---
        let sourceURL = URL(fileURLWithPath: config.inputVideoPath)
        let asset = AVURLAsset(url: sourceURL)
        guard let videoTrack = asset.tracks(withMediaType: .video).first else {
            throw fail("No video track in source")
        }

        let naturalSize = videoTrack.naturalSize
        let sourceW = Double(naturalSize.width)
        let sourceH = Double(naturalSize.height)
        let duration = asset.duration
        let sourceFps = Double(videoTrack.nominalFrameRate)
        let fps = config.fps > 0 ? Double(config.fps) : sourceFps
        let totalFrames = Int(CMTimeGetSeconds(duration) * fps)

        // --- Compute output dimensions ---
        let dims = computeOutputDimensions(
            sourceWidth: UInt32(sourceW),
            sourceHeight: UInt32(sourceH),
            style: config.styleConfig
        )
        let outputW = config.outputWidth > 0 ? Int(config.outputWidth) : Int(dims[0])
        let outputH = config.outputHeight > 0 ? Int(config.outputHeight) : Int(dims[1])

        // --- Load zoom keyframes and cursor data ---
        let eventsJson = (try? String(contentsOfFile: config.eventsJsonPath, encoding: .utf8)) ?? "{}"
        let mouseEvents = (try? mouseEventsFromLog(json: eventsJson)) ?? []
        let keyframes: [ZoomKeyframe] = config.zoomConfig.enabled
            ? generateZoomKeyframesWithConfig(events: mouseEvents, config: config.zoomConfig)
            : []
        let smoothedPts = smoothCursorPath(positions: mouseEvents, alpha: 0.3)

        // Use screen dimensions from event log for cursor/zoom coordinate mapping
        // (cursor coords are in screen points, not video pixels — differs on Retina)
        let eventLog = try? parseEventLog(json: eventsJson)
        let screenW = Double(eventLog?.screenWidth ?? UInt32(sourceW))
        let screenH = Double(eventLog?.screenHeight ?? UInt32(sourceH))

        onProgress(ExportProgress(percent: 5, stage: "Setting up encoder..."))

        // --- Setup AVAssetReader ---
        let reader = try AVAssetReader(asset: asset)
        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        videoOutput.alwaysCopiesSampleData = false
        reader.add(videoOutput)

        // Audio track (passthrough)
        let audioTrack = asset.tracks(withMediaType: .audio).first
        var audioOutput: AVAssetReaderTrackOutput?
        if let at = audioTrack {
            let ao = AVAssetReaderTrackOutput(track: at, outputSettings: nil)
            ao.alwaysCopiesSampleData = false
            reader.add(ao)
            audioOutput = ao
        }

        // --- Setup AVAssetWriter ---
        let outputURL = URL(fileURLWithPath: config.outputPath)
        try? FileManager.default.removeItem(at: outputURL)

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: outputW,
            AVVideoHeightKey: outputH,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: outputW * outputH * 4,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ] as [String: Any]
        ]
        let writerVideoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        writerVideoInput.expectsMediaDataInRealTime = false

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerVideoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: outputW,
                kCVPixelBufferHeightKey as String: outputH,
            ]
        )
        writer.add(writerVideoInput)

        var writerAudioInput: AVAssetWriterInput?
        if audioTrack != nil {
            let ai = AVAssetWriterInput(mediaType: .audio, outputSettings: nil)
            ai.expectsMediaDataInRealTime = false
            writer.add(ai)
            writerAudioInput = ai
        }

        // --- Start reading/writing ---
        guard reader.startReading() else {
            throw fail("AVAssetReader failed: \(reader.error?.localizedDescription ?? "unknown")")
        }
        guard writer.startWriting() else {
            throw fail("AVAssetWriter failed: \(writer.error?.localizedDescription ?? "unknown")")
        }
        writer.startSession(atSourceTime: CMTime.zero)

        onProgress(ExportProgress(percent: 10, stage: "Encoding..."))

        // --- Frame-by-frame processing using SwiftUI ImageRenderer ---
        let outputSize = CGSize(width: outputW, height: outputH)
        let ciCtx = CIContext()  // Reuse one CIContext for all frames
        var frameIndex = 0

        while let sampleBuffer = videoOutput.copyNextSampleBuffer() {
            autoreleasepool {
                while !writerVideoInput.isReadyForMoreMediaData {
                    Thread.sleep(forTimeInterval: 0.005)
                }

                let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                let timeSeconds = CMTimeGetSeconds(presentationTime)
                let timestampMs = UInt64(max(0, timeSeconds) * 1000)

                guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

                // Convert pixel buffer to NSImage for SwiftUI
                let ciImage = CIImage(cvPixelBuffer: imageBuffer)
                let rep = NSCIImageRep(ciImage: ciImage)
                let nsImage = NSImage(size: rep.size)
                nsImage.addRepresentation(rep)

                // Compute zoom state at this frame's timestamp (same functions as preview)
                let scale = zoomScaleAt(keyframes: keyframes, timestampMs: timestampMs, config: config.zoomConfig)
                let centerVec = zoomCenterAt(keyframes: keyframes, timestampMs: timestampMs)
                let anchor: UnitPoint
                if centerVec.count == 2, screenW > 0, screenH > 0 {
                    let ax = min(max(centerVec[0] / screenW, 0), 1)
                    let ay = min(max(centerVec[1] / screenH, 0), 1)
                    anchor = UnitPoint(x: ax, y: ay)
                } else {
                    anchor = .center
                }

                // Find cursor position
                let cursorPoint = smoothedPts.last(where: { $0.timestampMs <= timestampMs })

                // Build the SAME SwiftUI view as PreviewView uses
                let frameView = ExportFrameView(
                    frameImage: nsImage,
                    scale: scale,
                    zoomAnchor: anchor,
                    cursorPoint: cursorPoint,
                    styleConfig: config.styleConfig,
                    cursorConfig: config.cursorConfig,
                    videoWidth: screenW,
                    videoHeight: screenH,
                    outputSize: outputSize
                )

                // Render SwiftUI view to CGImage (on main thread)
                guard let cgImage = renderOnMain(frameView, size: outputSize) else { return }

                // Write CGImage to pixel buffer
                guard let pool = adaptor.pixelBufferPool else { return }
                var outputBuffer: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outputBuffer)
                guard let outputBuffer else { return }

                CVPixelBufferLockBaseAddress(outputBuffer, [])
                let ciImg = CIImage(cgImage: cgImage)
                ciCtx.render(ciImg, to: outputBuffer)
                CVPixelBufferUnlockBaseAddress(outputBuffer, [])

                adaptor.append(outputBuffer, withPresentationTime: presentationTime)

                frameIndex += 1
                if frameIndex % 10 == 0 {
                    let pct = 10.0 + Double(frameIndex) / Double(max(totalFrames, 1)) * 80.0
                    onProgress(ExportProgress(percent: min(pct, 90), stage: "Encoding..."))
                }
            }
        }

        // Write audio
        if let audioOutput, let writerAudioInput {
            while let audioSample = audioOutput.copyNextSampleBuffer() {
                autoreleasepool {
                    while !writerAudioInput.isReadyForMoreMediaData {
                        Thread.sleep(forTimeInterval: 0.005)
                    }
                    writerAudioInput.append(audioSample)
                }
            }
        }

        // --- Finish ---
        writerVideoInput.markAsFinished()
        writerAudioInput?.markAsFinished()

        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting { sem.signal() }
        sem.wait()

        if writer.status == .failed {
            throw fail("AVAssetWriter failed: \(writer.error?.localizedDescription ?? "unknown")")
        }

        reader.cancelReading()

        onProgress(ExportProgress(percent: 100, stage: "Complete"))
        onComplete(config.outputPath)
    }
}

// MARK: - SwiftUI view that renders a single export frame
// Uses the EXACT same modifiers as PreviewView to guarantee pixel-perfect output.

private struct ExportFrameView: View {
    let frameImage: NSImage
    let scale: Double
    let zoomAnchor: UnitPoint
    let cursorPoint: SmoothedPoint?
    let styleConfig: StyleConfig
    let cursorConfig: CursorConfig
    let videoWidth: Double
    let videoHeight: Double
    let outputSize: CGSize

    var body: some View {
        ZStack {
            // Background — same as PreviewView.backgroundView
            backgroundView

            // Video + cursor composite — same transform chain as PreviewView
            videoWithCursor
                .clipShape(RoundedRectangle(cornerRadius: styleConfig.cornerRadius))
                .shadow(
                    color: .black.opacity(styleConfig.shadowEnabled ? styleConfig.shadowIntensity * 0.6 : 0),
                    radius: styleConfig.shadowEnabled ? 20 * styleConfig.shadowIntensity : 0,
                    y: styleConfig.shadowEnabled ? 10 * styleConfig.shadowIntensity : 0
                )
                .scaleEffect(scale, anchor: zoomAnchor)
                .padding(styleConfig.padding)
        }
        .frame(width: outputSize.width, height: outputSize.height)
        .clipped()
    }

    @ViewBuilder
    private var backgroundView: some View {
        switch styleConfig.background.bgType {
        case "gradient":
            LinearGradient(
                colors: [
                    Color(hex: styleConfig.background.gradientFromHex),
                    Color(hex: styleConfig.background.gradientToHex),
                ],
                startPoint: gradientStart,
                endPoint: gradientEnd
            )
        case "transparent":
            Color.white
        default:
            Color(hex: styleConfig.background.hex)
        }
    }

    private var gradientStart: UnitPoint {
        let angle = styleConfig.background.gradientAngleDegrees
        let rad = angle * .pi / 180.0
        return UnitPoint(x: 0.5 - cos(rad) * 0.5, y: 0.5 - sin(rad) * 0.5)
    }

    private var gradientEnd: UnitPoint {
        let angle = styleConfig.background.gradientAngleDegrees
        let rad = angle * .pi / 180.0
        return UnitPoint(x: 0.5 + cos(rad) * 0.5, y: 0.5 + sin(rad) * 0.5)
    }

    @ViewBuilder
    private var videoWithCursor: some View {
        let padding = styleConfig.padding
        let availW = outputSize.width - padding * 2
        let availH = outputSize.height - padding * 2
        let videoAspect = videoWidth / max(videoHeight, 1)
        let viewAspect = availW / max(availH, 1)
        let renderW = videoAspect > viewAspect ? availW : availH * videoAspect
        let renderH = videoAspect > viewAspect ? availW / videoAspect : availH

        ZStack {
            Image(nsImage: frameImage)
                .resizable()
                .aspectRatio(contentMode: .fit)

            cursorOverlay
        }
        .frame(width: renderW, height: renderH)
    }

    @ViewBuilder
    private var cursorOverlay: some View {
        if cursorConfig.cursorStyle != "hidden", let point = cursorPoint {
            let fracX = point.x / max(videoWidth, 1)
            let fracY = point.y / max(videoHeight, 1)
            let baseSize = 12.0 * cursorConfig.sizeMultiplier

            Canvas { context, size in
                let x = fracX * size.width
                let y = fracY * size.height

                if cursorConfig.cursorStyle == "circle" {
                    if cursorConfig.clickHighlight {
                        let highlightSize = baseSize * 2.5
                        let highlightRect = CGRect(
                            x: x - highlightSize / 2, y: y - highlightSize / 2,
                            width: highlightSize, height: highlightSize
                        )
                        context.fill(
                            Path(ellipseIn: highlightRect),
                            with: .color(Color(hex: cursorConfig.highlightColorHex).opacity(0.25))
                        )
                    }
                    let dotRect = CGRect(
                        x: x - baseSize / 2, y: y - baseSize / 2,
                        width: baseSize, height: baseSize
                    )
                    context.fill(
                        Path(ellipseIn: dotRect),
                        with: .color(.white.opacity(0.9))
                    )
                } else if cursorConfig.cursorStyle == "system" {
                    let cursorImage = NSCursor.arrow.image
                    let cursorSize = CGSize(
                        width: cursorImage.size.width * cursorConfig.sizeMultiplier,
                        height: cursorImage.size.height * cursorConfig.sizeMultiplier
                    )
                    let hotSpot = NSCursor.arrow.hotSpot
                    let drawRect = CGRect(
                        x: x - hotSpot.x * cursorConfig.sizeMultiplier,
                        y: y - hotSpot.y * cursorConfig.sizeMultiplier,
                        width: cursorSize.width,
                        height: cursorSize.height
                    )
                    context.draw(
                        Image(nsImage: cursorImage),
                        in: drawRect
                    )
                }
            }
        }
    }
}
