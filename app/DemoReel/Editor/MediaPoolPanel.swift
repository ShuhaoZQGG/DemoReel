import SwiftUI
import AVFoundation

/// Sidebar panel showing the media pool — imported video files available for timeline placement.
struct MediaPoolPanel: View {
    var clipManager: ClipManager
    @State private var isImporting = false
    @State private var thumbnails: [UUID: NSImage] = [:]
    @State private var selectedIds: Set<UUID> = []

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar: import + delete
            HStack(spacing: 8) {
                Button {
                    importVideo()
                } label: {
                    Label("Import...", systemImage: "plus.circle")
                }
                .buttonStyle(.borderedProminent)
                .disabled(isImporting)

                Spacer()

                Button {
                    deleteSelected()
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .disabled(selectedIds.isEmpty)
                .keyboardShortcut(.delete, modifiers: [])
            }
            .padding(12)

            if clipManager.mediaItems.isEmpty {
                Spacer()
                Text("No media imported")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                Spacer()
            } else {
                List(selection: $selectedIds) {
                    ForEach(clipManager.mediaItems) { item in
                        MediaItemRow(
                            item: item,
                            thumbnail: thumbnails[item.id],
                            isSelected: selectedIds.contains(item.id),
                            onAddToTimeline: {
                                clipManager.addClipFromMedia(item)
                            }
                        )
                        .tag(item.id)
                        .contextMenu {
                            Button("Add to Timeline") {
                                clipManager.addClipFromMedia(item)
                            }
                            Divider()
                            Button("Remove from Pool", role: .destructive) {
                                removeMediaItems(ids: [item.id])
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
            }
        }
    }

    private func deleteSelected() {
        removeMediaItems(ids: selectedIds)
    }

    private func importVideo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = true
        panel.message = "Select video files to import"

        guard panel.runModal() == .OK else { return }

        isImporting = true
        Task {
            for url in panel.urls {
                do {
                    let item = try await clipManager.addMediaItem(url: url)
                    await generateThumbnail(for: item)
                } catch {
                    // Skip files that fail to load
                }
            }
            await MainActor.run { isImporting = false }
        }
    }

    private func generateThumbnail(for item: MediaItem) async {
        let asset = AVURLAsset(url: item.fileURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.maximumSize = CGSize(width: 120, height: 80)
        generator.appliesPreferredTrackTransform = true

        if let cgImage = try? generator.copyCGImage(at: .zero, actualTime: nil) {
            let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            await MainActor.run {
                thumbnails[item.id] = nsImage
            }
        }
    }

    private func removeMediaItems(ids: Set<UUID>) {
        let inUseIds = ids.filter { id in
            clipManager.clips.contains { $0.mediaItemId == id }
        }

        if !inUseIds.isEmpty {
            let inUseNames = inUseIds.compactMap { id in
                clipManager.mediaItems.first { $0.id == id }?.name
            }
            let alert = NSAlert()
            alert.messageText = "Cannot remove \(inUseNames.joined(separator: ", "))"
            alert.informativeText = "These videos are used by clips on the timeline. Remove those clips first."
            alert.runModal()
        }

        let removableIds = ids.subtracting(inUseIds)
        clipManager.mediaItems.removeAll { removableIds.contains($0.id) }
        for id in removableIds {
            thumbnails.removeValue(forKey: id)
        }
        selectedIds.subtract(removableIds)
    }
}

/// A single row in the media pool list.
private struct MediaItemRow: View {
    let item: MediaItem
    let thumbnail: NSImage?
    let isSelected: Bool
    let onAddToTimeline: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            // Thumbnail
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 48, height: 32)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            } else {
                RoundedRectangle(cornerRadius: 3)
                    .fill(.quaternary)
                    .frame(width: 48, height: 32)
                    .overlay {
                        Image(systemName: "film")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(formatDuration(item.durationMs))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                onAddToTimeline()
            } label: {
                Image(systemName: "plus.circle")
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .help("Add to timeline")
        }
        .padding(.vertical, 4)
    }

    private func formatDuration(_ ms: UInt64) -> String {
        let totalSeconds = Int(ms / 1000)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
