# 4. Screen Recording — AVAssetWriter + ScreenCaptureKit

**Problem:** All `.mov` files were 0 bytes or corrupt (missing moov atom).

**Root cause:** ScreenCaptureKit delivers raw `BGRA` pixel buffers via `CMSampleBuffer`, but `AVAssetWriterInput` configured for H.264 can't directly accept raw pixel data via `input.append(sampleBuffer)`.

**Fix:** Use `AVAssetWriterInputPixelBufferAdaptor`:
```swift
let adaptor = AVAssetWriterInputPixelBufferAdaptor(
    assetWriterInput: input,
    sourcePixelBufferAttributes: [...]
)
// In the stream output callback:
guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
adaptor.append(pixelBuffer, withPresentationTime: timestamp)
```

**Lesson:** `CMSampleBuffer` from ScreenCaptureKit contains raw pixel data, not encoded video. Must extract `CVPixelBuffer` and feed through an adaptor.
