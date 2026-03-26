import SwiftUI
import UniformTypeIdentifiers

/// Export configuration sheet: format picker, resolution, progress bar.
struct ExportSheet: View {
    @Binding var isPresented: Bool
    let videoPath: URL?
    let eventsPath: URL?
    let zoomConfig: ZoomConfig
    let styleConfig: StyleConfig
    let cursorConfig: CursorConfig

    @State private var selectedFormat = "mp4"
    @State private var selectedResolution = "source"
    @State private var isExporting = false
    @State private var progress: Double = 0
    @State private var progressStage = ""
    @State private var exportedPath: URL?
    @State private var errorMessage: String?

    private let formats = ["mp4", "gif", "webm"]
    private let resolutions = [
        ("source", "Match Source"),
        ("1080p", "1080p (1920x1080)"),
        ("4k", "4K (3840x2160)"),
    ]

    var body: some View {
        VStack(spacing: 20) {
            Text("Export Video")
                .font(.title2)
                .fontWeight(.semibold)

            if let exportedPath {
                exportCompleteView(path: exportedPath)
            } else if isExporting {
                exportProgressView
            } else {
                exportConfigView
            }
        }
        .padding(24)
        .frame(width: 420)
    }

    @ViewBuilder
    private var exportConfigView: some View {
        Form {
            Picker("Format", selection: $selectedFormat) {
                ForEach(formats, id: \.self) { format in
                    Text(format.uppercased()).tag(format)
                }
            }
            .pickerStyle(.segmented)

            Picker("Resolution", selection: $selectedResolution) {
                ForEach(resolutions, id: \.0) { res in
                    Text(res.1).tag(res.0)
                }
            }
        }
        .formStyle(.grouped)

        if let error = errorMessage {
            Text(error)
                .foregroundStyle(.red)
                .font(.caption)
        }

        HStack {
            Button("Cancel") {
                isPresented = false
            }
            .keyboardShortcut(.cancelAction)

            Spacer()

            Button("Export") {
                startExport()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
    }

    @ViewBuilder
    private var exportProgressView: some View {
        VStack(spacing: 12) {
            ProgressView(value: progress, total: 100)
                .progressViewStyle(.linear)

            Text(progressStage)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("\(Int(progress))%")
                .font(.system(.title3, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func exportCompleteView(path: URL) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)

            Text("Export Complete!")
                .font(.headline)

            Text(path.lastPathComponent)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([path])
                }

                Button("Done") {
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func startExport() {
        guard let videoPath, let eventsPath else {
            errorMessage = "No recording loaded"
            return
        }

        let (outWidth, outHeight) = resolveResolution()
        let outputDir = videoPath.deletingLastPathComponent()
        let outputName = videoPath.deletingPathExtension().lastPathComponent + "_export"
        let outputURL = outputDir
            .appendingPathComponent(outputName)
            .appendingPathExtension(selectedFormat)

        let config = ExportConfig(
            inputVideoPath: videoPath.path,
            eventsJsonPath: eventsPath.path,
            outputPath: outputURL.path,
            zoomConfig: zoomConfig,
            styleConfig: styleConfig,
            cursorConfig: cursorConfig,
            outputWidth: outWidth,
            outputHeight: outHeight,
            fps: 30,
            format: OutputFormatConfig(format: selectedFormat)
        )

        isExporting = true
        errorMessage = nil

        let manager = ExportManager(
            onProgress: { prog in
                Task { @MainActor in
                    self.progress = prog.percent
                    self.progressStage = prog.stage
                }
            },
            onComplete: { path in
                Task { @MainActor in
                    self.isExporting = false
                    self.exportedPath = URL(fileURLWithPath: path)
                }
            },
            onError: { message in
                Task { @MainActor in
                    self.isExporting = false
                    self.errorMessage = message
                }
            }
        )

        Task.detached {
            exportVideo(config: config, callback: manager)
        }
    }

    private func resolveResolution() -> (UInt32, UInt32) {
        switch selectedResolution {
        case "1080p": return (1920, 1080)
        case "4k": return (3840, 2160)
        default: return (0, 0) // 0 = use source dimensions
        }
    }
}
