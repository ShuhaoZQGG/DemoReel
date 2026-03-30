import AVFoundation
import CoreGraphics
import AppKit
import SwiftUI

/// Native macOS video exporter that uses SwiftUI's ImageRenderer to render
/// each frame with the EXACT same view pipeline as the preview — guaranteeing
/// pixel-perfect output matching what the user sees in the editor.
///
/// The exporter processes clips in timeline order, respecting clip boundaries,
/// ordering, gaps, and zoom keyframes from the editor's ClipManager.
final class NativeExporter {
    private let config: ExportConfig
    private let clips: [Clip]
    private let zoomKeyframes: [ZoomKeyframe]
    private let zoomClips: [ZoomClip]
    private let mediaItems: [MediaItem]
    private let onProgress: (ExportProgress) -> Void
    private let onComplete: (String) -> Void
    private let onError: (String) -> Void

    init(config: ExportConfig,
         clips: [Clip],
         zoomKeyframes: [ZoomKeyframe],
         zoomClips: [ZoomClip] = [],
         mediaItems: [MediaItem] = [],
         onProgress: @escaping (ExportProgress) -> Void,
         onComplete: @escaping (String) -> Void,
         onError: @escaping (String) -> Void) {
        self.config = config
        self.clips = clips
        self.zoomKeyframes = zoomKeyframes
        self.zoomClips = zoomClips
        self.mediaItems = mediaItems
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

    /// Resolve the AVURLAsset and video track for a clip.
    private func resolveAsset(for clip: Clip, fallbackAsset: AVURLAsset, fallbackTrack: AVAssetTrack, assetCache: [UUID: (AVURLAsset, AVAssetTrack)]) -> (AVURLAsset, AVAssetTrack) {
        if let mediaId = clip.mediaItemId, let cached = assetCache[mediaId] {
            return cached
        }
        return (fallbackAsset, fallbackTrack)
    }

    private func runExport() throws {
        onProgress(ExportProgress(percent: 1, stage: "Preparing..."))

        // --- Load primary source video (fallback for legacy clips) ---
        let sourceURL = URL(fileURLWithPath: config.inputVideoPath)
        let asset = AVURLAsset(url: sourceURL)
        guard let videoTrack = asset.tracks(withMediaType: .video).first else {
            throw fail("No video track in source")
        }

        // --- Pre-load all media item assets ---
        var assetCache: [UUID: (AVURLAsset, AVAssetTrack)] = [:]
        for item in mediaItems {
            let itemAsset = AVURLAsset(url: item.fileURL)
            if let track = itemAsset.tracks(withMediaType: .video).first {
                assetCache[item.id] = (itemAsset, track)
            }
        }

        let naturalSize = videoTrack.naturalSize
        let sourceW = Double(naturalSize.width)
        let sourceH = Double(naturalSize.height)
        let sourceFps = Double(videoTrack.nominalFrameRate)
        let fps = config.fps > 0 ? Double(config.fps) : sourceFps
        let frameDurationMs = 1000.0 / fps

        // --- Compute output dimensions ---
        let dims = computeOutputDimensions(
            sourceWidth: UInt32(sourceW),
            sourceHeight: UInt32(sourceH),
            style: config.styleConfig
        )
        let outputW = config.outputWidth > 0 ? Int(config.outputWidth) : Int(dims[0])
        let outputH = config.outputHeight > 0 ? Int(config.outputHeight) : Int(dims[1])

        // --- Load cursor data from events ---
        let eventsJson = (try? String(contentsOfFile: config.eventsJsonPath, encoding: .utf8)) ?? "{}"
        let mouseEvents = (try? mouseEventsFromLog(json: eventsJson)) ?? []
        let smoothedPts = smoothCursorPath(positions: mouseEvents, alpha: 0.3)

        // Use screen dimensions from event log for cursor/zoom coordinate mapping
        let eventLog = try? parseEventLog(json: eventsJson)
        let screenW = Double(eventLog?.screenWidth ?? UInt32(sourceW))
        let screenH = Double(eventLog?.screenHeight ?? UInt32(sourceH))

        // --- Determine clips to export ---
        // Sort clips by timeline position; use editor zoom keyframes (not auto-generated)
        let sortedClips = clips.sorted(by: { $0.timelineStartMs < $1.timelineStartMs })
        let keyframes = zoomKeyframes

        // Calculate total timeline duration for progress reporting
        let timelineEndMs = sortedClips.map(\.timelineEndMs).max() ?? 0
        let totalFrames = Int(Double(timelineEndMs) / frameDurationMs)

        onProgress(ExportProgress(percent: 5, stage: "Setting up encoder..."))

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

        // Audio: skip for now — clip-aware audio mixing is complex and the
        // sequential passthrough would be wrong for reordered clips.
        // TODO: Add clip-aware audio export

        guard writer.startWriting() else {
            throw fail("AVAssetWriter failed: \(writer.error?.localizedDescription ?? "unknown")")
        }
        writer.startSession(atSourceTime: CMTime.zero)

        onProgress(ExportProgress(percent: 10, stage: "Encoding..."))

        let outputSize = CGSize(width: outputW, height: outputH)
        let ciCtx = CIContext()
        var outputFrameIndex = 0

        // If no clips exist, fall back to a single clip spanning the full source video.
        let effectiveClips: [Clip]
        if sortedClips.isEmpty {
            let durationMs = UInt64(CMTimeGetSeconds(asset.duration) * 1000)
            effectiveClips = [Clip(sourceStartMs: 0, sourceEndMs: durationMs, timelineStartMs: 0)]
        } else {
            effectiveClips = sortedClips
        }

        // --- Process each clip in timeline order ---
        for clip in effectiveClips {
            // Fill gap before this clip with black frames
            let expectedTimelineMs = UInt64(Double(outputFrameIndex) * frameDurationMs)
            if clip.timelineStartMs > expectedTimelineMs {
                let gapFrames = Int(Double(clip.timelineStartMs - expectedTimelineMs) / frameDurationMs)
                for _ in 0..<gapFrames {
                    autoreleasepool {
                        while !writerVideoInput.isReadyForMoreMediaData {
                            Thread.sleep(forTimeInterval: 0.005)
                        }
                        let presentTime = CMTime(value: Int64(outputFrameIndex), timescale: CMTimeScale(fps))

                        let frameView = ExportFrameView(
                            frameImage: nil,
                            scale: 1.0,
                            zoomAnchor: .center,
                            cursorPoint: nil,
                            styleConfig: config.styleConfig,
                            cursorConfig: config.cursorConfig,
                            videoWidth: screenW,
                            videoHeight: screenH,
                            outputSize: outputSize
                        )
                        if let cgImage = renderOnMain(frameView, size: outputSize),
                           let pool = adaptor.pixelBufferPool {
                            var buf: CVPixelBuffer?
                            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buf)
                            if let buf {
                                CVPixelBufferLockBaseAddress(buf, [])
                                ciCtx.render(CIImage(cgImage: cgImage), to: buf)
                                CVPixelBufferUnlockBaseAddress(buf, [])
                                adaptor.append(buf, withPresentationTime: presentTime)
                            }
                        }
                        outputFrameIndex += 1
                    }
                }
            }

            // Resolve which video source to read from for this clip
            let (clipAsset, clipTrack) = resolveAsset(for: clip, fallbackAsset: asset, fallbackTrack: videoTrack, assetCache: assetCache)
            let clipVideoW = Double(clipTrack.naturalSize.width)
            let clipVideoH = Double(clipTrack.naturalSize.height)

            // Read frames for this clip using a time-ranged AVAssetReader
            let clipStartTime = CMTime(value: Int64(clip.sourceStartMs), timescale: 1000)
            let clipEndTime = CMTime(value: Int64(clip.sourceEndMs), timescale: 1000)
            let timeRange = CMTimeRange(start: clipStartTime, end: clipEndTime)

            let clipReader = try AVAssetReader(asset: clipAsset)
            clipReader.timeRange = timeRange
            let clipVideoOutput = AVAssetReaderTrackOutput(track: clipTrack, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ])
            clipVideoOutput.alwaysCopiesSampleData = false
            clipReader.add(clipVideoOutput)

            guard clipReader.startReading() else {
                throw fail("AVAssetReader failed for clip: \(clipReader.error?.localizedDescription ?? "unknown")")
            }

            while let sampleBuffer = clipVideoOutput.copyNextSampleBuffer() {
                autoreleasepool {
                    while !writerVideoInput.isReadyForMoreMediaData {
                        Thread.sleep(forTimeInterval: 0.005)
                    }

                    let sourcePTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                    let sourceTimeMs = UInt64(max(0, CMTimeGetSeconds(sourcePTS)) * 1000)

                    // Map source time to timeline time for zoom lookup
                    let offsetInClipMs = sourceTimeMs >= clip.sourceStartMs
                        ? sourceTimeMs - clip.sourceStartMs
                        : 0
                    let timelineMs = clip.timelineStartMs + offsetInClipMs

                    // Use strictly monotonic frame-counter PTS for output
                    let outputPTS = CMTime(value: Int64(outputFrameIndex), timescale: CMTimeScale(fps))

                    guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

                    // Convert pixel buffer to NSImage for SwiftUI
                    let ciImage = CIImage(cvPixelBuffer: imageBuffer)
                    let rep = NSCIImageRep(ciImage: ciImage)
                    let nsImage = NSImage(size: rep.size)
                    nsImage.addRepresentation(rep)

                    // Compute zoom state using TIMELINE time (matches preview)
                    let scale = zoomClips.isEmpty
                        ? zoomScaleAt(keyframes: keyframes, timestampMs: timelineMs, config: config.zoomConfig)
                        : ClipManager.zoomScaleWithPerClipEase(zoomClips: zoomClips, timestampMs: timelineMs, globalConfig: config.zoomConfig)
                    // Derive hold from clip duration — global holdMs is only for auto-generation
                    let effectiveZoomConfig: ZoomConfig
                    if let zc = zoomClips.first(where: { timelineMs >= $0.timelineStartMs && timelineMs <= $0.timelineEndMs }) {
                        let easeIn = zc.easeEnabled ? zc.easeInMs : config.zoomConfig.easeInMs
                        let easeOut = zc.easeEnabled ? zc.easeOutMs : config.zoomConfig.easeOutMs
                        let holdMs = zc.durationMs > (easeIn + easeOut)
                            ? zc.durationMs - easeIn - easeOut : 0
                        effectiveZoomConfig = config.zoomConfig.with(
                            easeInMs: easeIn, holdMs: holdMs, easeOutMs: easeOut,
                            easingCurve: zc.easingCurveValue
                        )
                    } else {
                        effectiveZoomConfig = config.zoomConfig
                    }
                    let centerVec = zoomCenterAtFollowing(
                        keyframes: keyframes,
                        smoothedPath: smoothedPts,
                        timestampMs: timelineMs,
                        config: effectiveZoomConfig
                    )
                    let anchor: UnitPoint
                    if centerVec.count == 2, screenW > 0, screenH > 0 {
                        let ax = min(max(centerVec[0] / screenW, 0), 1)
                        let ay = min(max(centerVec[1] / screenH, 0), 1)
                        anchor = UnitPoint(x: ax, y: ay)
                    } else {
                        anchor = .center
                    }

                    // Find cursor position using SOURCE time (cursor data is in source coordinates)
                    let cursorPoint = smoothedPts.last(where: { $0.timestampMs <= sourceTimeMs })

                    let frameView = ExportFrameView(
                        frameImage: nsImage,
                        scale: scale,
                        zoomAnchor: anchor,
                        cursorPoint: cursorPoint,
                        styleConfig: config.styleConfig,
                        cursorConfig: config.cursorConfig,
                        videoWidth: clipVideoW,
                        videoHeight: clipVideoH,
                        outputSize: outputSize
                    )

                    guard let cgImage = renderOnMain(frameView, size: outputSize) else { return }

                    guard let pool = adaptor.pixelBufferPool else { return }
                    var outputBuffer: CVPixelBuffer?
                    CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outputBuffer)
                    guard let outputBuffer else { return }

                    CVPixelBufferLockBaseAddress(outputBuffer, [])
                    let ciImg = CIImage(cgImage: cgImage)
                    ciCtx.render(ciImg, to: outputBuffer)
                    CVPixelBufferUnlockBaseAddress(outputBuffer, [])

                    adaptor.append(outputBuffer, withPresentationTime: outputPTS)

                    outputFrameIndex += 1
                    if outputFrameIndex % 10 == 0 {
                        let pct = 10.0 + Double(outputFrameIndex) / Double(max(totalFrames, 1)) * 80.0
                        onProgress(ExportProgress(percent: min(pct, 90), stage: "Encoding..."))
                    }
                }
            }

            clipReader.cancelReading()
        }

        // --- Finish ---
        writerVideoInput.markAsFinished()

        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting { sem.signal() }
        sem.wait()

        if writer.status == .failed {
            throw fail("AVAssetWriter failed (\(outputFrameIndex) frames written): \(writer.error?.localizedDescription ?? "unknown")")
        }

        if outputFrameIndex == 0 {
            throw fail("No frames were exported — clips may be empty or out of range")
        }

        onProgress(ExportProgress(percent: 100, stage: "Complete"))
        onComplete(config.outputPath)
    }
}

// MARK: - SwiftUI view that renders a single export frame
// Uses the EXACT same modifiers as PreviewView to guarantee pixel-perfect output.

private struct ExportFrameView: View {
    let frameImage: NSImage?
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

            if let frameImage {
                // Video + cursor composite — same transform chain as PreviewView
                videoWithCursor(image: frameImage)
                    .clipShape(RoundedRectangle(cornerRadius: styleConfig.cornerRadius))
                    .shadow(
                        color: .black.opacity(styleConfig.shadowEnabled ? styleConfig.shadowIntensity * 0.6 : 0),
                        radius: styleConfig.shadowEnabled ? 20 * styleConfig.shadowIntensity : 0,
                        y: styleConfig.shadowEnabled ? 10 * styleConfig.shadowIntensity : 0
                    )
                    .scaleEffect(scale, anchor: zoomAnchor)
                    .padding(styleConfig.padding)
            }
            // If frameImage is nil, we're in a gap — just show background (black)
        }
        .frame(width: outputSize.width, height: outputSize.height)
        .clipped()
    }

    @ViewBuilder
    private var backgroundView: some View {
        if frameImage == nil {
            // Gap frame — show black
            Color.black
        } else {
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
            case "image":
                if let nsImage = NSImage(named: styleConfig.background.imageName) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: outputSize.width, height: outputSize.height)
                        .clipped()
                } else {
                    Color(hex: "#1a1a2e")
                }
            case "transparent":
                Color.white
            default:
                Color(hex: styleConfig.background.hex)
            }
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
    private func videoWithCursor(image: NSImage) -> some View {
        let padding = styleConfig.padding
        let availW = outputSize.width - padding * 2
        let availH = outputSize.height - padding * 2
        let videoAspect = videoWidth / max(videoHeight, 1)
        let viewAspect = availW / max(availH, 1)
        let renderW = videoAspect > viewAspect ? availW : availH * videoAspect
        let renderH = videoAspect > viewAspect ? availW / videoAspect : availH

        ZStack {
            Image(nsImage: image)
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

            // Use GeometryReader + standard SwiftUI views instead of Canvas,
            // because Canvas does not render through ImageRenderer.
            GeometryReader { geo in
                let x = fracX * geo.size.width
                let y = fracY * geo.size.height

                if cursorConfig.cursorStyle == "circle" {
                    ZStack {
                        if cursorConfig.clickHighlight {
                            Circle()
                                .fill(Color(hex: cursorConfig.highlightColorHex).opacity(0.25))
                                .frame(width: baseSize * 2.5, height: baseSize * 2.5)
                        }
                        Circle()
                            .fill(.white.opacity(0.9))
                            .frame(width: baseSize, height: baseSize)
                            .shadow(color: .black.opacity(0.3), radius: 2)
                    }
                    .position(x: x, y: y)
                } else if cursorConfig.cursorStyle == "system" {
                    SystemCursorView(sizeMultiplier: cursorConfig.sizeMultiplier)
                        .position(x: x, y: y)
                }
            }
        }
    }
}
