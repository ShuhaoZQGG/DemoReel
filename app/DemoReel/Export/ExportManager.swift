import Foundation

/// Bridges the Rust ExportCallback interface to Swift closures.
final class ExportManager: ExportCallback {
    private let onProgressHandler: (ExportProgress) -> Void
    private let onCompleteHandler: (String) -> Void
    private let onErrorHandler: (String) -> Void

    init(
        onProgress: @escaping (ExportProgress) -> Void,
        onComplete: @escaping (String) -> Void,
        onError: @escaping (String) -> Void
    ) {
        self.onProgressHandler = onProgress
        self.onCompleteHandler = onComplete
        self.onErrorHandler = onError
    }

    func onProgress(progress: ExportProgress) {
        onProgressHandler(progress)
    }

    func onComplete(outputPath: String) {
        onCompleteHandler(outputPath)
    }

    func onError(message: String) {
        onErrorHandler(message)
    }
}
