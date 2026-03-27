#!/usr/bin/env swift
// re_export.swift — Standalone re-exporter for DemoReel recordings.
// Reimplements the NativeExporter pipeline using Core Graphics + AVFoundation.
//
// Usage: swift re_export.swift <input.mov> <events.json> <output.mp4>

import AVFoundation
import CoreGraphics
import AppKit
import Foundation

// MARK: - Data types

struct MouseEvent {
    let x: Double
    let y: Double
    let timestampMs: UInt64
    let click: Bool
}

struct SmoothedPoint {
    let x: Double
    let y: Double
    let timestampMs: UInt64
    let velocity: Double
}

struct ZoomKeyframe {
    var startMs: UInt64
    var endMs: UInt64
    var centerX: Double
    var centerY: Double
    var scale: Double
}

struct ZoomConfig {
    let scale: Double
    let easeInMs: UInt64
    let holdMs: UInt64
    let easeOutMs: UInt64
    let mergeThresholdMs: UInt64
    let enabled: Bool

    static let `default` = ZoomConfig(
        scale: 2.0, easeInMs: 300, holdMs: 600, easeOutMs: 400,
        mergeThresholdMs: 300, enabled: true
    )
}

// MARK: - JSON parsing

func parseEventsJson(path: String) -> (events: [MouseEvent], screenWidth: Double, screenHeight: Double, durationMs: UInt64) {
    guard let data = FileManager.default.contents(atPath: path),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        fatalError("Cannot read events JSON at \(path)")
    }

    let screenW = (json["screen_width"] as? NSNumber)?.doubleValue ?? 3440
    let screenH = (json["screen_height"] as? NSNumber)?.doubleValue ?? 1440
    let durationMs = (json["duration_ms"] as? NSNumber)?.uint64Value ?? 0

    var events: [MouseEvent] = []
    if let rawEvents = json["events"] as? [[String: Any]] {
        for e in rawEvents {
            let type = e["type"] as? String ?? ""
            let x = (e["x"] as? NSNumber)?.doubleValue ?? 0
            let y = (e["y"] as? NSNumber)?.doubleValue ?? 0
            let ts = (e["ts"] as? NSNumber)?.uint64Value ?? 0
            let isClick = type == "click"
            events.append(MouseEvent(x: x, y: y, timestampMs: ts, click: isClick))
        }
    }
    return (events, screenW, screenH, durationMs)
}

// MARK: - Cursor smoothing (exponential moving average)

func smoothCursorPath(positions: [MouseEvent], alpha: Double) -> [SmoothedPoint] {
    let alpha = min(max(alpha, 0.01), 1.0)
    guard !positions.isEmpty else { return [] }

    var result: [SmoothedPoint] = []
    let first = positions[0]
    result.append(SmoothedPoint(x: first.x, y: first.y, timestampMs: first.timestampMs, velocity: 0))

    for i in 1..<positions.count {
        let prev = result[i - 1]
        let raw = positions[i]
        let sx = alpha * raw.x + (1 - alpha) * prev.x
        let sy = alpha * raw.y + (1 - alpha) * prev.y
        let dt = raw.timestampMs > prev.timestampMs ? raw.timestampMs - prev.timestampMs : 0
        let vel: Double
        if dt > 0 {
            let dx = sx - prev.x, dy = sy - prev.y
            vel = sqrt(dx * dx + dy * dy) / (Double(dt) / 1000.0)
        } else { vel = 0 }
        result.append(SmoothedPoint(x: sx, y: sy, timestampMs: raw.timestampMs, velocity: vel))
    }
    return result
}

// MARK: - Zoom keyframe generation

func generateZoomKeyframes(events: [MouseEvent], config: ZoomConfig) -> [ZoomKeyframe] {
    guard config.enabled else { return [] }
    let clicks = events.filter { $0.click }
    guard !clicks.isEmpty else { return [] }

    // Cluster nearby clicks
    struct Cluster { var cx: Double; var cy: Double; var ts: UInt64; var count: Int }
    var clusters: [Cluster] = []
    for click in clicks {
        if var last = clusters.last,
           click.timestampMs >= last.ts,
           click.timestampMs - last.ts <= config.mergeThresholdMs {
            let total = Double(last.count + 1)
            last.cx = (last.cx * Double(last.count) + click.x) / total
            last.cy = (last.cy * Double(last.count) + click.y) / total
            last.ts = max(last.ts, click.timestampMs)
            last.count += 1
            clusters[clusters.count - 1] = last
        } else {
            clusters.append(Cluster(cx: click.x, cy: click.y, ts: click.timestampMs, count: 1))
        }
    }

    // Generate keyframes
    let totalDur = config.easeInMs + config.holdMs + config.easeOutMs
    var keyframes: [ZoomKeyframe] = clusters.map { c in
        let start = c.ts >= config.easeInMs ? c.ts - config.easeInMs : 0
        return ZoomKeyframe(startMs: start, endMs: start + totalDur,
                            centerX: c.cx, centerY: c.cy, scale: config.scale)
    }

    // Merge overlapping
    var i = 0
    while i + 1 < keyframes.count {
        if keyframes[i].endMs >= keyframes[i + 1].startMs {
            let next = keyframes.remove(at: i + 1)
            keyframes[i].endMs = max(keyframes[i].endMs, next.endMs)
            keyframes[i].centerX = (keyframes[i].centerX + next.centerX) / 2
            keyframes[i].centerY = (keyframes[i].centerY + next.centerY) / 2
            keyframes[i].scale = max(keyframes[i].scale, next.scale)
        } else { i += 1 }
    }
    return keyframes
}

func cubicEaseInOut(_ t: Double) -> Double {
    let t = min(max(t, 0), 1)
    return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
}

func zoomScaleAt(keyframes: [ZoomKeyframe], timestampMs: UInt64, config: ZoomConfig) -> Double {
    for kf in keyframes {
        guard timestampMs >= kf.startMs && timestampMs <= kf.endMs else { continue }
        let elapsed = timestampMs - kf.startMs
        if elapsed <= config.easeInMs {
            let t = Double(elapsed) / Double(config.easeInMs)
            return 1.0 + (kf.scale - 1.0) * cubicEaseInOut(t)
        } else if elapsed <= config.easeInMs + config.holdMs {
            return kf.scale
        } else {
            let easeOutElapsed = elapsed - config.easeInMs - config.holdMs
            let remaining = (kf.endMs - kf.startMs) - config.easeInMs - config.holdMs
            if remaining == 0 { return 1.0 }
            let t = Double(easeOutElapsed) / Double(remaining)
            return kf.scale - (kf.scale - 1.0) * cubicEaseInOut(t)
        }
    }
    return 1.0
}

func zoomCenterAt(keyframes: [ZoomKeyframe], timestampMs: UInt64) -> (Double, Double)? {
    for kf in keyframes {
        if timestampMs >= kf.startMs && timestampMs <= kf.endMs {
            return (kf.centerX, kf.centerY)
        }
    }
    return nil
}

// MARK: - Output dimensions (16:9 with 32px padding)

func computeOutputDimensions(sourceW: Int, sourceH: Int, padding: Double) -> (Int, Int) {
    let pad = Int(padding) * 2
    let videoW = sourceW + pad
    let videoH = sourceH + pad
    let targetRatio = 16.0 / 9.0
    let currentRatio = Double(videoW) / Double(videoH)
    let (w, h): (Int, Int)
    if currentRatio > targetRatio {
        let newH = Int(ceil(Double(videoW) / targetRatio))
        w = videoW; h = newH
    } else {
        let newW = Int(ceil(Double(videoH) * targetRatio))
        w = newW; h = videoH
    }
    // Round to even
    return ((w + 1) & ~1, (h + 1) & ~1)
}

// MARK: - Core Graphics frame renderer

func parseHex(_ hex: String) -> (CGFloat, CGFloat, CGFloat, CGFloat) {
    let h = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
    guard h.count == 6 || h.count == 8 else { return (0, 0, 0, 1) }
    let scanner = Scanner(string: h)
    var val: UInt64 = 0
    scanner.scanHexInt64(&val)
    if h.count == 6 {
        return (CGFloat((val >> 16) & 0xFF) / 255,
                CGFloat((val >> 8) & 0xFF) / 255,
                CGFloat(val & 0xFF) / 255, 1.0)
    } else {
        return (CGFloat((val >> 24) & 0xFF) / 255,
                CGFloat((val >> 16) & 0xFF) / 255,
                CGFloat((val >> 8) & 0xFF) / 255,
                CGFloat(val & 0xFF) / 255)
    }
}

func renderFrame(
    frameImage: CGImage,
    outputSize: CGSize,
    screenW: Double, screenH: Double,
    scale: Double, anchorX: Double, anchorY: Double,
    cursorPoint: SmoothedPoint?,
    padding: Double, cornerRadius: Double,
    bgColor: (CGFloat, CGFloat, CGFloat, CGFloat),
    shadowEnabled: Bool, shadowIntensity: Double
) -> CGImage? {
    let w = Int(outputSize.width)
    let h = Int(outputSize.height)
    guard let ctx = CGContext(
        data: nil, width: w, height: h,
        bitsPerComponent: 8, bytesPerRow: w * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    ) else { return nil }

    // Flip to match top-left origin
    ctx.translateBy(x: 0, y: CGFloat(h))
    ctx.scaleBy(x: 1, y: -1)

    // Background
    ctx.setFillColor(red: bgColor.0, green: bgColor.1, blue: bgColor.2, alpha: bgColor.3)
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))

    // Compute video render rect (fit within padding)
    let availW = outputSize.width - padding * 2
    let availH = outputSize.height - padding * 2
    let videoAspect = screenW / max(screenH, 1)
    let viewAspect = availW / max(availH, 1)
    let renderW: Double, renderH: Double
    if videoAspect > viewAspect {
        renderW = availW; renderH = availW / videoAspect
    } else {
        renderH = availH; renderW = availH * videoAspect
    }
    let videoX = (outputSize.width - renderW) / 2
    let videoY = (outputSize.height - renderH) / 2

    // Apply zoom transform around anchor point
    let zoomOriginX = videoX + renderW * anchorX
    let zoomOriginY = videoY + renderH * anchorY

    ctx.saveGState()
    ctx.translateBy(x: CGFloat(zoomOriginX), y: CGFloat(zoomOriginY))
    ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
    ctx.translateBy(x: CGFloat(-zoomOriginX), y: CGFloat(-zoomOriginY))

    // Shadow
    if shadowEnabled {
        ctx.setShadow(
            offset: CGSize(width: 0, height: 10 * shadowIntensity),
            blur: CGFloat(20 * shadowIntensity),
            color: CGColor(red: 0, green: 0, blue: 0, alpha: CGFloat(shadowIntensity * 0.6))
        )
    }

    // Clip to rounded rect and draw video
    let videoRect = CGRect(x: videoX, y: videoY, width: renderW, height: renderH)
    let roundedPath = CGPath(roundedRect: videoRect, cornerWidth: CGFloat(cornerRadius), cornerHeight: CGFloat(cornerRadius), transform: nil)
    ctx.addPath(roundedPath)
    ctx.clip()

    // Clear shadow for the actual draw
    ctx.setShadow(offset: .zero, blur: 0, color: nil)

    ctx.draw(frameImage, in: videoRect)

    // Draw cursor
    if let cp = cursorPoint {
        let fracX = cp.x / max(screenW, 1)
        let fracY = cp.y / max(screenH, 1)
        let cx = videoX + fracX * renderW
        let cy = videoY + fracY * renderH

        // Draw system-style cursor (white arrow with black outline)
        let cursorSize: CGFloat = 20
        let path = CGMutablePath()
        // Arrow cursor shape
        path.move(to: CGPoint(x: cx, y: cy))
        path.addLine(to: CGPoint(x: cx, y: cy + cursorSize))
        path.addLine(to: CGPoint(x: cx + cursorSize * 0.35, y: cy + cursorSize * 0.72))
        path.addLine(to: CGPoint(x: cx + cursorSize * 0.55, y: cy + cursorSize * 1.05))
        path.addLine(to: CGPoint(x: cx + cursorSize * 0.7, y: cy + cursorSize * 0.95))
        path.addLine(to: CGPoint(x: cx + cursorSize * 0.48, y: cy + cursorSize * 0.62))
        path.addLine(to: CGPoint(x: cx + cursorSize * 0.75, y: cy + cursorSize * 0.58))
        path.closeSubpath()

        // Black outline
        ctx.setStrokeColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.8))
        ctx.setLineWidth(1.5)
        ctx.addPath(path)
        ctx.strokePath()

        // White fill
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.95))
        ctx.addPath(path)
        ctx.fillPath()
    }

    ctx.restoreGState()

    return ctx.makeImage()
}

// MARK: - Main export pipeline

func main() {
    let args = CommandLine.arguments
    guard args.count >= 4 else {
        print("Usage: swift re_export.swift <input.mov> <events.json> <output.mp4>")
        exit(1)
    }

    let inputPath = (args[1] as NSString).expandingTildeInPath
    let eventsPath = (args[2] as NSString).expandingTildeInPath
    let outputPath = (args[3] as NSString).expandingTildeInPath

    print("Loading events...")
    let (events, screenW, screenH, _) = parseEventsJson(path: eventsPath)
    print("  \(events.count) events, screen: \(Int(screenW))x\(Int(screenH))")

    let zoomConfig = ZoomConfig.default
    let keyframes = generateZoomKeyframes(events: events, config: zoomConfig)
    print("  \(keyframes.count) zoom keyframes generated")

    let smoothedPts = smoothCursorPath(positions: events.filter { $0.click || !$0.click }, alpha: 0.3)
    print("  \(smoothedPts.count) smoothed cursor points")

    // Style defaults
    let padding = 32.0
    let cornerRadius = 12.0
    let bgColor = parseHex("#1a1a2e")
    let shadowEnabled = true
    let shadowIntensity = 0.5

    print("Loading video...")
    let sourceURL = URL(fileURLWithPath: inputPath)
    let asset = AVURLAsset(url: sourceURL)
    guard let videoTrack = asset.tracks(withMediaType: .video).first else {
        print("ERROR: No video track"); exit(1)
    }

    let naturalSize = videoTrack.naturalSize
    let sourceW = Int(naturalSize.width)
    let sourceH = Int(naturalSize.height)
    let duration = asset.duration
    let sourceFps = Double(videoTrack.nominalFrameRate)
    let fps = 30.0
    let totalFrames = Int(CMTimeGetSeconds(duration) * fps)
    print("  Source: \(sourceW)x\(sourceH), \(String(format: "%.1f", sourceFps))fps, \(String(format: "%.1f", CMTimeGetSeconds(duration)))s")

    let (outputW, outputH) = computeOutputDimensions(sourceW: Int(screenW), sourceH: Int(screenH), padding: padding)
    print("  Output: \(outputW)x\(outputH) @ \(Int(fps))fps (\(totalFrames) frames)")

    // Setup reader
    let reader: AVAssetReader
    do { reader = try AVAssetReader(asset: asset) } catch {
        print("ERROR: \(error)"); exit(1)
    }
    let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ])
    videoOutput.alwaysCopiesSampleData = false
    reader.add(videoOutput)

    // Audio passthrough
    let audioTrack = asset.tracks(withMediaType: .audio).first
    var audioOutput: AVAssetReaderTrackOutput?
    if let at = audioTrack {
        let ao = AVAssetReaderTrackOutput(track: at, outputSettings: nil)
        ao.alwaysCopiesSampleData = false
        reader.add(ao)
        audioOutput = ao
    }

    // Setup writer
    let outputURL = URL(fileURLWithPath: outputPath)
    try? FileManager.default.removeItem(at: outputURL)
    let writer: AVAssetWriter
    do { writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4) } catch {
        print("ERROR: \(error)"); exit(1)
    }

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

    // Start
    guard reader.startReading() else {
        print("ERROR: Reader failed: \(reader.error?.localizedDescription ?? "unknown")"); exit(1)
    }
    guard writer.startWriting() else {
        print("ERROR: Writer failed: \(writer.error?.localizedDescription ?? "unknown")"); exit(1)
    }
    writer.startSession(atSourceTime: .zero)

    let outputSize = CGSize(width: outputW, height: outputH)
    let ciCtx = CIContext()  // Reuse one CIContext for all frames
    var frameIndex = 0
    var peakMemoryMB = 0.0
    let startTime = Date()

    print("Encoding frames...")
    while let sampleBuffer = videoOutput.copyNextSampleBuffer() {
        autoreleasepool {
            while !writerVideoInput.isReadyForMoreMediaData {
                Thread.sleep(forTimeInterval: 0.005)
            }

            let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let timeSeconds = CMTimeGetSeconds(presentationTime)
            let timestampMs = UInt64(max(0, timeSeconds) * 1000)

            guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

            // Convert pixel buffer to CGImage (reusing CIContext)
            let ciImage = CIImage(cvPixelBuffer: imageBuffer)
            guard let frameImage = ciCtx.createCGImage(ciImage, from: ciImage.extent) else { return }

            // Compute zoom
            let scale = zoomScaleAt(keyframes: keyframes, timestampMs: timestampMs, config: zoomConfig)
            let center = zoomCenterAt(keyframes: keyframes, timestampMs: timestampMs)
            let anchorX: Double, anchorY: Double
            if let c = center, screenW > 0, screenH > 0 {
                anchorX = min(max(c.0 / screenW, 0), 1)
                anchorY = min(max(c.1 / screenH, 0), 1)
            } else {
                anchorX = 0.5; anchorY = 0.5
            }

            // Find cursor position
            let cursorPoint = smoothedPts.last(where: { $0.timestampMs <= timestampMs })

            // Render frame
            guard let rendered = renderFrame(
                frameImage: frameImage,
                outputSize: outputSize,
                screenW: screenW, screenH: screenH,
                scale: scale, anchorX: anchorX, anchorY: anchorY,
                cursorPoint: cursorPoint,
                padding: padding, cornerRadius: cornerRadius,
                bgColor: bgColor,
                shadowEnabled: shadowEnabled, shadowIntensity: shadowIntensity
            ) else { return }

            // Write to pixel buffer (reusing CIContext)
            guard let pool = adaptor.pixelBufferPool else { return }
            var outputBuffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outputBuffer)
            guard let outputBuffer else { return }

            CVPixelBufferLockBaseAddress(outputBuffer, [])
            ciCtx.render(CIImage(cgImage: rendered), to: outputBuffer)
            CVPixelBufferUnlockBaseAddress(outputBuffer, [])

            adaptor.append(outputBuffer, withPresentationTime: presentationTime)

            frameIndex += 1
            if frameIndex % 30 == 0 {
                let pct = Double(frameIndex) / Double(max(totalFrames, 1)) * 100
                let elapsed = Date().timeIntervalSince(startTime)
                let fps = Double(frameIndex) / elapsed
                // Report memory usage
                var info = mach_task_basic_info()
                var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
                let kr = withUnsafeMutablePointer(to: &info) {
                    $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                        task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
                    }
                }
                let memMB = kr == KERN_SUCCESS ? Double(info.resident_size) / 1_000_000 : 0
                peakMemoryMB = max(peakMemoryMB, memMB)
                print("  \(frameIndex)/\(totalFrames) frames (\(String(format: "%.0f", pct))%) — \(String(format: "%.1f", fps)) fps — mem: \(String(format: "%.0f", memMB)) MB")
            }
        }
    }

    // Write audio
    if let audioOutput, let writerAudioInput {
        print("Writing audio...")
        while let audioSample = audioOutput.copyNextSampleBuffer() {
            autoreleasepool {
                while !writerAudioInput.isReadyForMoreMediaData {
                    Thread.sleep(forTimeInterval: 0.005)
                }
                writerAudioInput.append(audioSample)
            }
        }
    }

    // Finalize
    writerVideoInput.markAsFinished()
    writerAudioInput?.markAsFinished()

    let sem = DispatchSemaphore(value: 0)
    writer.finishWriting { sem.signal() }
    sem.wait()

    if writer.status == .failed {
        print("ERROR: Writer failed: \(writer.error?.localizedDescription ?? "unknown")")
        exit(1)
    }

    reader.cancelReading()

    let elapsed = Date().timeIntervalSince(startTime)
    let fileSize = (try? FileManager.default.attributesOfItem(atPath: outputPath)[.size] as? Int) ?? 0
    print("Done! \(frameIndex) frames in \(String(format: "%.1f", elapsed))s")
    print("Output: \(outputPath) (\(fileSize / 1_000_000) MB)")
    print("Peak memory: \(String(format: "%.0f", peakMemoryMB)) MB")
}

main()
