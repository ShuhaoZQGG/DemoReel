import SwiftUI
import AVFoundation

/// Main editor layout: preview on top, timeline below, tabbed controls in sidebar.
struct EditorView: View {
    @Bindable var appState: AppState
    @State private var smoothedPoints: [SmoothedPoint] = []
    @State private var currentTime: Double = 0
    @State private var timelinePosition: Double = 0
    @State private var isPlaying = false
    @State private var playbackTimer: Timer?
    @State private var zoomConfig = defaultZoomConfig()
    @State private var styleConfig = defaultStyleConfig()
    @State private var cursorConfig = defaultCursorConfig()
    @State private var selectedTab = SidebarTab.zoom
    @State private var showExportSheet = false
    @State private var trimStart: Double = 0
    @State private var trimEnd: Double = 0
    @State private var videoWidth: Double = 0
    @State private var videoHeight: Double = 0
    @State private var clipManager = ClipManager()
    @State private var scissorModeActive = false
    @State private var zoomPlacementActive = false
    @State private var selection: TrackSelection = .none
    @State private var keyMonitor = KeyboardShortcutMonitor()
    @State private var restorableZoomCount: Int = 0
    /// The video URL currently being previewed (changes as playhead moves across multi-source clips).
    @State private var activeVideoURL: URL?
    @State private var thumbnailCache = ThumbnailCache()
    @State private var waveformCache = WaveformCache()
    @State private var flashingClipIds: Set<UUID> = []

    enum SidebarTab: String, CaseIterable {
        case media = "Media"
        case zoom = "Zoom"
        case style = "Style"
        case cursor = "Cursor"
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                PreviewView(
                    videoURL: activeVideoURL ?? appState.videoPath,
                    keyframes: clipManager.zoomKeyframesForPreview(),
                    zoomClips: clipManager.zoomClips,
                    smoothedPoints: smoothedPoints,
                    currentTime: $currentTime,
                    timelinePosition: timelinePosition,
                    isPlaying: $isPlaying,
                    zoomConfig: zoomConfig,
                    styleConfig: styleConfig,
                    cursorConfig: cursorConfig,
                    videoWidth: videoWidth,
                    videoHeight: videoHeight,
                    selection: selection,
                    systemAudioClips: clipManager.systemAudioClips,
                    micAudioClips: clipManager.micAudioClips,
                    onFocusPointDragged: { clipID, newCenterX, newCenterY in
                        guard let idx = clipManager.zoomClips.firstIndex(where: { $0.id == clipID }) else { return }
                        clipManager.zoomClips[idx].centerX = newCenterX
                        clipManager.zoomClips[idx].centerY = newCenterY
                    },
                    onDragBegan: {
                        isPlaying = false
                        clipManager.saveUndoState()
                    }
                )
                .frame(minHeight: 300)

                Divider()

                TimelineView(
                    duration: appState.recordingDuration,
                    currentTime: $currentTime,
                    timelinePosition: $timelinePosition,
                    isPlaying: $isPlaying,
                    trimStart: $trimStart,
                    trimEnd: $trimEnd,
                    clipManager: clipManager,
                    onSplit: splitAtPlayhead,
                    onSplitZoom: splitZoomAtPlayhead,
                    onSpeedChange: changeClipSpeed,
                    onZoomScaleChange: changeZoomScale,
                    onAddZoom: addZoomAtPlayhead,
                    selection: $selection,
                    scissorModeActive: $scissorModeActive,
                    zoomPlacementActive: $zoomPlacementActive,
                    zoomPlacementScale: zoomConfig.scale,
                    onPlaceZoom: { ms in placeZoomClip(atTimelineMs: ms) },
                    thumbnailCache: thumbnailCache,
                    waveformCache: waveformCache,
                    flashingClipIds: flashingClipIds
                )
                .frame(height: 200)
            }

            VStack(spacing: 0) {
                Picker("", selection: $selectedTab) {
                    ForEach(SidebarTab.allCases, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(8)

                switch selectedTab {
                case .media:
                    MediaPoolPanel(clipManager: clipManager)
                case .zoom:
                    ZoomConfigPanel(
                        config: $zoomConfig,
                        restorableCount: restorableZoomCount,
                        onRegenerate: regenerateKeyframes,
                        selection: selection,
                        clipManager: clipManager,
                        videoWidth: videoWidth,
                        videoHeight: videoHeight
                    )
                case .style:
                    StylePanel(config: $styleConfig)
                case .cursor:
                    CursorPanel(config: $cursorConfig)
                }
            }
            .frame(width: 280)
        }
        .frame(minWidth: 960, minHeight: 640)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Export") {
                    showExportSheet = true
                }
                .keyboardShortcut("e")
            }
            ToolbarItem(placement: .automatic) {
                Button("Save") {
                    saveProject()
                }
                .keyboardShortcut("s")
            }
            ToolbarItem(placement: .navigation) {
                Button("New Recording") {
                    appState.currentScreen = .recording
                }
            }
        }
        .sheet(isPresented: $showExportSheet) {
            ExportSheet(
                isPresented: $showExportSheet,
                videoPath: appState.videoPath,
                eventsPath: appState.eventsPath,
                zoomConfig: $zoomConfig,
                styleConfig: $styleConfig,
                cursorConfig: $cursorConfig,
                clips: clipManager.clipsByTimelineOrder,
                zoomKeyframes: clipManager.zoomKeyframesForPreview(),
                zoomClips: clipManager.zoomClips,
                mediaItems: clipManager.mediaItems
            )
        }
        .task {
            activeVideoURL = appState.videoPath
            loadEventsAndGenerate()
            loadProjectSettingsIfNeeded()
        }
        .onChange(of: keyMonitor.lastAction) { _, event in
            guard let event else { return }
            handleKeyAction(event.action)
        }
        .onChange(of: timelinePosition) { _, newPos in
            // Update active video source when scrubbing (playback timer handles this during play)
            if !isPlaying {
                if let (_, _, mediaItemId) = clipManager.sourceTimeForTimelinePosition(newPos) {
                    updateActiveVideoURL(mediaItemId: mediaItemId)
                }
            }
        }
        .onChange(of: isPlaying) { _, playing in
            if playing {
                startPlaybackTimer()
            } else {
                stopPlaybackTimer()
            }
        }
        .onChange(of: clipManager.zoomClips.count) {
            updateRestorableZoomCount()
        }
        .onDisappear {
            stopPlaybackTimer()
        }
        .onReceive(NotificationCenter.default.publisher(for: .saveProject)) { _ in
            saveProject()
        }
        .onReceive(NotificationCenter.default.publisher(for: .exportVideo)) { _ in
            showExportSheet = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .importVideo)) { notification in
            if let url = notification.object as? URL {
                importVideoToPool(url: url)
            }
        }
    }

    private func loadEventsAndGenerate() {
        // Auto-register the recording video as a media item if not already present
        registerRecordingAsMediaItem()

        guard let eventsPath = appState.eventsPath else {
            // No event log (e.g. empty project) — just initialize clips from trim
            initializeClipsIfNeeded()
            return
        }
        guard let json = try? String(contentsOf: eventsPath, encoding: .utf8) else { return }
        guard let mouseEvents = try? mouseEventsFromLog(json: json) else { return }

        // Extract video dimensions from event log
        if let record = try? parseEventLog(json: json) {
            videoWidth = Double(record.screenWidth)
            videoHeight = Double(record.screenHeight)
        }

        let generatedKeyframes = generateZoomKeyframesWithConfig(
            events: mouseEvents,
            config: zoomConfig
        )
        smoothedPoints = smoothCursorPath(positions: mouseEvents, alpha: 0.3)

        initializeClipsIfNeeded()

        // Initialize zoom clips from auto-generated keyframes
        clipManager.initializeZoomClips(from: generatedKeyframes)
        updateRestorableZoomCount()
    }

    private func initializeClipsIfNeeded() {
        if trimEnd <= 0 {
            trimEnd = appState.recordingDuration
        }

        if clipManager.clips.isEmpty {
            // Find the media item for the recording, if registered
            let mediaId = clipManager.mediaItems.first(where: {
                appState.videoPath != nil && $0.filePath == appState.videoPath!.path
            })?.id

            let clip = Clip(
                sourceStartMs: UInt64(trimStart * 1000),
                sourceEndMs: UInt64(trimEnd * 1000),
                timelineStartMs: 0,
                mediaItemId: mediaId
            )
            clipManager.clips = [clip]
        }
    }

    /// Register the screen recording video as a media pool item.
    private func registerRecordingAsMediaItem() {
        guard let videoURL = appState.videoPath else { return }
        // Skip if already registered
        if clipManager.mediaItems.contains(where: { $0.filePath == videoURL.path }) { return }

        Task {
            do {
                let item = try await clipManager.addMediaItem(url: videoURL)
                // Update video dimensions from the asset
                await MainActor.run {
                    if videoWidth == 0 { videoWidth = item.width }
                    if videoHeight == 0 { videoHeight = item.height }
                    activeVideoURL = videoURL
                    // Assign mediaItemId to any legacy clips that don't have one
                    for i in clipManager.clips.indices where clipManager.clips[i].mediaItemId == nil {
                        clipManager.clips[i].mediaItemId = item.id
                    }

                    // Initialize audio clips from recorded audio segments
                    initializeAudioClips(mediaItem: item)
                }
            } catch {
                // Fallback: still works with legacy single-source path
            }
        }
    }

    /// Create audio clips from the recorded audio segments (enabled time ranges).
    private func initializeAudioClips(mediaItem: MediaItem) {
        guard clipManager.systemAudioClips.isEmpty else { return }
        guard clipManager.micAudioClips.isEmpty else { return }

        for segment in appState.systemAudioSegments {
            clipManager.systemAudioClips.append(AudioClip(
                sourceStartMs: segment.startMs,
                sourceEndMs: segment.endMs,
                timelineStartMs: segment.startMs,
                mediaItemId: mediaItem.id,
                trackIndex: 0
            ))
        }
        for segment in appState.micAudioSegments {
            clipManager.micAudioClips.append(AudioClip(
                sourceStartMs: segment.startMs,
                sourceEndMs: segment.endMs,
                timelineStartMs: segment.startMs,
                mediaItemId: mediaItem.id,
                trackIndex: 1
            ))
        }
    }

    /// Import a video file into the media pool from the File menu.
    private func importVideoToPool(url: URL) {
        Task {
            do {
                try await clipManager.addMediaItem(url: url)
                await MainActor.run { selectedTab = .media }
            } catch {
                // Silently skip files that fail to load
            }
        }
    }

    private func splitAtPlayhead() {
        guard currentTime >= 0 else { return } // can't split in a gap
        let sourceMs = UInt64(currentTime * 1000)
        clipManager.split(atSourceTimeMs: sourceMs)
    }

    private func splitZoomAtPlayhead() {
        let timelineMs = UInt64(timelinePosition * 1000)
        clipManager.splitZoomClip(atTimelineMs: timelineMs)
    }

    private func changeClipSpeed(_ speed: Double) {
        let sourceMs = UInt64(max(0, currentTime) * 1000)
        guard let index = clipManager.clips.firstIndex(where: { $0.sourceStartMs <= sourceMs && $0.sourceEndMs > sourceMs }) else { return }
        clipManager.clips[index].speed = speed
    }

    private func placeZoomClip(atTimelineMs ms: UInt64) {
        let durationMs = zoomConfig.easeInMs + zoomConfig.holdMs + zoomConfig.easeOutMs
        clipManager.addZoomClip(
            atTimelineMs: ms,
            durationMs: durationMs,
            centerX: 0.5,
            centerY: 0.5,
            scale: zoomConfig.scale
        )
    }

    private func addZoomAtPlayhead() {
        let timelineMs = UInt64(timelinePosition * 1000)
        let durationMs = zoomConfig.easeInMs + zoomConfig.holdMs + zoomConfig.easeOutMs
        clipManager.addZoomClip(
            atTimelineMs: timelineMs,
            durationMs: durationMs,
            centerX: 0.5,
            centerY: 0.5,
            scale: zoomConfig.scale
        )
        if let newClip = clipManager.zoomClips.last {
            selection = .zoomClips([newClip.id])
        }
    }

    private func changeZoomScale(_ scale: Double) {
        let timelineMs = UInt64(timelinePosition * 1000)
        if let index = clipManager.zoomClips.firstIndex(where: { timelineMs >= $0.timelineStartMs && timelineMs < $0.timelineEndMs }) {
            clipManager.zoomClips[index].scale = scale
        }
    }

    // MARK: - Timer-Driven Playback

    private func startPlaybackTimer() {
        stopPlaybackTimer()
        playbackTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [self] _ in
            let dt = 1.0 / 30.0
            timelinePosition += dt

            if let (sourceMs, _, mediaItemId) = clipManager.sourceTimeForTimelinePosition(timelinePosition) {
                currentTime = Double(sourceMs) / 1000.0
                updateActiveVideoURL(mediaItemId: mediaItemId)
            } else {
                // In a gap — show black/nothing
                currentTime = -1

                // Check if we're past all clips
                if UInt64(timelinePosition * 1000) >= clipManager.timelineEndMs {
                    isPlaying = false
                }
            }
        }
    }

    private func stopPlaybackTimer() {
        playbackTimer?.invalidate()
        playbackTimer = nil
    }

    /// Resolve which video file to show in preview based on the active clip's media item.
    private func updateActiveVideoURL(mediaItemId: UUID?) {
        if let id = mediaItemId, let item = clipManager.mediaItems.first(where: { $0.id == id }) {
            let url = item.fileURL
            if activeVideoURL != url {
                activeVideoURL = url
            }
        } else {
            // Legacy clip — fall back to appState.videoPath
            if activeVideoURL != appState.videoPath {
                activeVideoURL = appState.videoPath
            }
        }
    }

    private func handleKeyAction(_ action: KeyboardShortcutMonitor.EditorAction) {
        switch action {
        case .toggleScissor:
            scissorModeActive.toggle()
            if scissorModeActive { zoomPlacementActive = false }
        case .addZoom:
            addZoomAtPlayhead()
        case .deleteSelection:
            deleteSelected()
        case .deactivateScissor:
            scissorModeActive = false
            zoomPlacementActive = false
        case .undo:
            clipManager.undo()
        case .redo:
            clipManager.redo()
        case .nudgeFocusPoint(let dx, let dy):
            nudgeFocusPoint(dx: dx, dy: dy)
        case .adjustZoomDuration(let deltaMs):
            adjustSelectedZoomDuration(deltaMs: deltaMs)
        case .adjustZoomScale(let delta):
            adjustSelectedZoomScale(delta: delta)
        case .nudgeZoomPosition(let deltaMs):
            nudgeSelectedZoomPosition(deltaMs: deltaMs)
        case .duplicateSelection:
            duplicateSelected()
        case .copySelection:
            copySelected()
        case .pasteSelection:
            pasteAtPlayhead()
        case .selectNextZoom:
            selectAdjacentZoom(forward: true)
        case .selectPreviousZoom:
            selectAdjacentZoom(forward: false)
        }
    }

    private func nudgeFocusPoint(dx: Double, dy: Double) {
        guard !zoomConfig.followCursor,
              case .zoomClips(let ids) = selection, ids.count == 1,
              let id = ids.first,
              let idx = clipManager.zoomClips.firstIndex(where: { $0.id == id }) else { return }
        clipManager.saveUndoStateDebounced()
        let clip = clipManager.zoomClips[idx]
        clipManager.zoomClips[idx].centerX = min(max(clip.centerX + dx, 0), videoWidth)
        clipManager.zoomClips[idx].centerY = min(max(clip.centerY + dy, 0), videoHeight)
    }

    private func adjustSelectedZoomDuration(deltaMs: Int64) {
        guard case .zoomClips(let ids) = selection else { return }
        clipManager.saveUndoStateDebounced()
        for id in ids {
            if let idx = clipManager.zoomClips.firstIndex(where: { $0.id == id }) {
                let newDuration = max(200, Int64(clipManager.zoomClips[idx].durationMs) + deltaMs)
                clipManager.zoomClips[idx].durationMs = UInt64(newDuration)
            }
        }
    }

    private func adjustSelectedZoomScale(delta: Double) {
        guard case .zoomClips(let ids) = selection else { return }
        clipManager.saveUndoStateDebounced()
        for id in ids {
            if let idx = clipManager.zoomClips.firstIndex(where: { $0.id == id }) {
                let newScale = min(5.0, max(1.25, clipManager.zoomClips[idx].scale + delta))
                clipManager.zoomClips[idx].scale = newScale
            }
        }
    }

    private func nudgeSelectedZoomPosition(deltaMs: Int64) {
        guard case .zoomClips(let ids) = selection else { return }
        clipManager.saveUndoStateDebounced()
        for id in ids {
            if let idx = clipManager.zoomClips.firstIndex(where: { $0.id == id }) {
                let newStart = max(0, Int64(clipManager.zoomClips[idx].timelineStartMs) + deltaMs)
                clipManager.zoomClips[idx].timelineStartMs = UInt64(newStart)
            }
        }
    }

    private func duplicateSelected() {
        switch selection {
        case .zoomClips(let ids):
            let newIds = clipManager.duplicateZoomClips(ids: ids)
            if !newIds.isEmpty {
                selection = .zoomClips(Set(newIds))
            }
        default:
            break
        }
    }

    private func copySelected() {
        switch selection {
        case .zoomClips(let ids):
            clipManager.copyZoomClips(ids: ids)
        default:
            break
        }
    }

    private func pasteAtPlayhead() {
        let playheadMs = UInt64(timelinePosition * 1000)
        let newIds = clipManager.pasteZoomClips(atTimelineMs: playheadMs)
        guard !newIds.isEmpty else { return }

        selection = .zoomClips(Set(newIds))

        flashingClipIds = Set(newIds)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            flashingClipIds = []
        }
    }

    private func selectAdjacentZoom(forward: Bool) {
        let sorted = clipManager.zoomClips.sorted { $0.timelineStartMs < $1.timelineStartMs }
        guard !sorted.isEmpty else { return }

        var currentIndex: Int? = nil
        if case .zoomClips(let ids) = selection, let id = ids.first {
            currentIndex = sorted.firstIndex(where: { $0.id == id })
        }

        let nextIndex: Int
        if let current = currentIndex {
            nextIndex = forward
                ? (current + 1) % sorted.count
                : (current - 1 + sorted.count) % sorted.count
        } else {
            nextIndex = forward ? 0 : sorted.count - 1
        }

        selection = .zoomClips([sorted[nextIndex].id])
    }

    private func deleteSelected() {
        switch selection {
        case .videoClips(let ids):
            clipManager.deleteClips(ids: ids)
        case .zoomClips(let ids):
            clipManager.deleteZoomClips(ids: ids)
        case .systemAudioClips(let ids):
            clipManager.deleteSystemAudioClips(ids: ids)
        case .micAudioClips(let ids):
            clipManager.deleteMicAudioClips(ids: ids)
        case .none:
            break
        }
        selection = .none
    }

    private func regenerateKeyframes() {
        guard let eventsPath = appState.eventsPath else { return }
        guard let json = try? String(contentsOf: eventsPath, encoding: .utf8) else { return }
        guard let mouseEvents = try? mouseEventsFromLog(json: json) else { return }

        let generatedKeyframes = generateZoomKeyframesWithConfig(
            events: mouseEvents,
            config: zoomConfig
        )
        // Additive: only add non-overlapping new zoom clips, preserving manual edits
        clipManager.regenerateZoomClips(from: generatedKeyframes)
        updateRestorableZoomCount()
    }

    private func updateRestorableZoomCount() {
        guard let eventsPath = appState.eventsPath else { restorableZoomCount = 0; return }
        guard let json = try? String(contentsOf: eventsPath, encoding: .utf8) else { restorableZoomCount = 0; return }
        guard let mouseEvents = try? mouseEventsFromLog(json: json) else { restorableZoomCount = 0; return }

        let keyframes = generateZoomKeyframesWithConfig(events: mouseEvents, config: zoomConfig)
        restorableZoomCount = keyframes.filter { kf in
            !clipManager.zoomClips.contains { zc in
                kf.startMs < zc.timelineEndMs && kf.endMs > zc.timelineStartMs
            }
        }.count
    }

    private func loadProjectSettingsIfNeeded() {
        guard let projectPath = appState.projectPath else { return }
        guard let project = try? loadProject(path: projectPath.path) else { return }

        zoomConfig = ZoomConfig(
            scale: project.zoomScale,
            easeInMs: project.zoomEaseInMs,
            holdMs: project.zoomHoldMs,
            easeOutMs: project.zoomEaseOutMs,
            mergeThresholdMs: project.zoomMergeThresholdMs,
            enabled: project.zoomEnabled,
            idleTimeoutMs: project.zoomIdleTimeoutMs,
            velocityThreshold: project.zoomVelocityThreshold,
            followCursor: project.zoomFollowCursor,
            easingCurve: .easeInOut
        )
        styleConfig = StyleConfig(
            background: BackgroundConfig(
                bgType: project.bgType,
                hex: project.bgHex,
                gradientFromHex: project.bgGradientFromHex,
                gradientToHex: project.bgGradientToHex,
                gradientAngleDegrees: project.bgGradientAngle,
                imageName: project.bgImageName
            ),
            padding: project.padding,
            cornerRadius: project.cornerRadius,
            shadowEnabled: project.shadowEnabled,
            shadowIntensity: project.shadowIntensity,
            aspectRatio: AspectRatioConfig(ratio: project.aspectRatio)
        )
        cursorConfig = CursorConfig(
            cursorStyle: project.cursorStyle,
            sizeMultiplier: project.cursorSizeMultiplier,
            clickHighlight: project.cursorClickHighlight,
            highlightColorHex: project.cursorHighlightColorHex
        )
        trimStart = Double(project.trimStartMs) / 1000.0
        trimEnd = Double(project.trimEndMs) / 1000.0

        regenerateKeyframes()
        loadClips(projectURL: projectPath)
    }

    private func saveProject() {
        let url: URL
        if let existing = appState.projectPath {
            url = existing
        } else {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.init(filenameExtension: "demoreel")!]
            panel.nameFieldStringValue = "Untitled.demoreel"
            guard panel.runModal() == .OK, let chosen = panel.url else { return }
            url = chosen
        }

        let project = ProjectFile(
            version: 1,
            name: url.deletingPathExtension().lastPathComponent,
            createdAt: ISO8601DateFormatter().string(from: Date()),
            videoPath: appState.videoPath?.path ?? "",
            eventsPath: appState.eventsPath?.path ?? "",
            zoomScale: zoomConfig.scale,
            zoomEaseInMs: zoomConfig.easeInMs,
            zoomHoldMs: zoomConfig.holdMs,
            zoomEaseOutMs: zoomConfig.easeOutMs,
            zoomMergeThresholdMs: zoomConfig.mergeThresholdMs,
            zoomEnabled: zoomConfig.enabled,
            zoomIdleTimeoutMs: zoomConfig.idleTimeoutMs,
            zoomVelocityThreshold: zoomConfig.velocityThreshold,
            zoomFollowCursor: zoomConfig.followCursor,
            bgType: styleConfig.background.bgType,
            bgHex: styleConfig.background.hex,
            bgGradientFromHex: styleConfig.background.gradientFromHex,
            bgGradientToHex: styleConfig.background.gradientToHex,
            bgGradientAngle: styleConfig.background.gradientAngleDegrees,
            bgImageName: styleConfig.background.imageName,
            padding: styleConfig.padding,
            cornerRadius: styleConfig.cornerRadius,
            shadowEnabled: styleConfig.shadowEnabled,
            shadowIntensity: styleConfig.shadowIntensity,
            aspectRatio: styleConfig.aspectRatio.ratio,
            cursorStyle: cursorConfig.cursorStyle,
            cursorSizeMultiplier: cursorConfig.sizeMultiplier,
            cursorClickHighlight: cursorConfig.clickHighlight,
            cursorHighlightColorHex: cursorConfig.highlightColorHex,
            trimStartMs: UInt64(trimStart * 1000),
            trimEndMs: UInt64(trimEnd * 1000)
        )

        do {
            try DemoReel.saveProject(project: project, path: url.path)
            appState.projectPath = url
            // Save clips sidecar
            saveClips(projectURL: url)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Failed to save project"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    private func saveClips(projectURL: URL) {
        let clipsURL = projectURL.appendingPathExtension("clips.json")
        if let data = try? JSONEncoder().encode(clipManager.clips) {
            try? data.write(to: clipsURL)
        }
        // Save zoom clips
        let zoomURL = projectURL.appendingPathExtension("zoomclips.json")
        if let data = try? JSONEncoder().encode(clipManager.zoomClips) {
            try? data.write(to: zoomURL)
        }
        // Save media items
        let mediaURL = projectURL.appendingPathExtension("media.json")
        if let data = try? JSONEncoder().encode(clipManager.mediaItems) {
            try? data.write(to: mediaURL)
        }
    }

    private func loadClips(projectURL: URL) {
        // Load media items first (clips reference them)
        let mediaURL = projectURL.appendingPathExtension("media.json")
        if let data = try? Data(contentsOf: mediaURL),
           let items = try? JSONDecoder().decode([MediaItem].self, from: data) {
            clipManager.mediaItems = items
        }

        let clipsURL = projectURL.appendingPathExtension("clips.json")
        if let data = try? Data(contentsOf: clipsURL),
           let clips = try? JSONDecoder().decode([Clip].self, from: data) {
            clipManager.clips = clips
        }
        // Load zoom clips
        let zoomURL = projectURL.appendingPathExtension("zoomclips.json")
        if let data = try? Data(contentsOf: zoomURL),
           let zoomClips = try? JSONDecoder().decode([ZoomClip].self, from: data) {
            clipManager.zoomClips = zoomClips
        }
    }
}

/// Sidebar panel for adjusting zoom configuration.
struct ZoomConfigPanel: View {
    @Binding var config: ZoomConfig
    var restorableCount: Int
    var onRegenerate: () -> Void
    var selection: TrackSelection
    var clipManager: ClipManager
    var videoWidth: Double
    var videoHeight: Double

    private var selectedClipID: UUID? {
        guard case .zoomClips(let ids) = selection, ids.count == 1 else { return nil }
        return ids.first
    }

    private var selectedClip: ZoomClip? {
        guard let id = selectedClipID else { return nil }
        return clipManager.zoomClips.first { $0.id == id }
    }

    /// Create a Binding that looks up the zoom clip by ID each time, preventing stale-index crashes.
    private func clipBinding<T>(default defaultValue: T, get: @escaping (Int) -> T, set: @escaping (Int, T) -> Void) -> Binding<T> {
        Binding(
            get: {
                guard let id = selectedClipID,
                      let idx = clipManager.zoomClips.firstIndex(where: { $0.id == id })
                else { return defaultValue }
                return get(idx)
            },
            set: { newValue in
                guard let id = selectedClipID,
                      let idx = clipManager.zoomClips.firstIndex(where: { $0.id == id })
                else { return }
                clipManager.saveUndoStateDebounced()
                set(idx, newValue)
            }
        )
    }

    var body: some View {
        Form {
            Section("Zoom") {
                LabeledContent("Scale") {
                    Slider(value: Binding(
                        get: { config.scale },
                        set: { config = config.with(scale: $0) }
                    ), in: 1.0...4.0, step: 0.1)
                    Text(String(format: "%.1fx", config.scale))
                        .monospacedDigit()
                        .frame(width: 40)
                }

                LabeledContent("Ease In") {
                    Slider(value: Binding(
                        get: { Double(config.easeInMs) },
                        set: { config = config.with(easeInMs: UInt64($0)) }
                    ), in: 100...800, step: 50)
                    Text("\(config.easeInMs)ms")
                        .monospacedDigit()
                        .frame(width: 55)
                }

                LabeledContent("Hold") {
                    Slider(value: Binding(
                        get: { Double(config.holdMs) },
                        set: { config = config.with(holdMs: UInt64($0)) }
                    ), in: 200...2000, step: 100)
                    Text("\(config.holdMs)ms")
                        .monospacedDigit()
                        .frame(width: 55)
                }

                LabeledContent("Ease Out") {
                    Slider(value: Binding(
                        get: { Double(config.easeOutMs) },
                        set: { config = config.with(easeOutMs: UInt64($0)) }
                    ), in: 100...800, step: 50)
                    Text("\(config.easeOutMs)ms")
                        .monospacedDigit()
                        .frame(width: 55)
                }

                Toggle("Enabled", isOn: Binding(
                    get: { config.enabled },
                    set: { config = config.with(enabled: $0) }
                ))

                Toggle("Follow Cursor", isOn: Binding(
                    get: { config.followCursor },
                    set: { config = config.with(followCursor: $0) }
                ))
            }

            Button("Restore Zoom Clips") {
                onRegenerate()
            }
            .buttonStyle(.borderedProminent)
            .disabled(restorableCount == 0)

            if let clip = selectedClip {
                Section("Selected Clip") {
                    LabeledContent("Scale") {
                        Slider(value: clipBinding(default: 1.0,
                            get: { clipManager.zoomClips[$0].scale },
                            set: { clipManager.zoomClips[$0].scale = $1 }
                        ), in: 1.0...4.0, step: 0.1)
                        Text(String(format: "%.1fx", clip.scale))
                            .monospacedDigit()
                            .frame(width: 40)
                    }

                    LabeledContent("Duration") {
                        Slider(value: clipBinding(default: 1000.0,
                            get: { Double(clipManager.zoomClips[$0].durationMs) },
                            set: { clipManager.zoomClips[$0].durationMs = UInt64($1) }
                        ), in: 200...5000, step: 100)
                        Text("\(clip.durationMs)ms")
                            .monospacedDigit()
                            .frame(width: 55)
                    }

                    LabeledContent("Ease In") {
                        Slider(value: clipBinding(default: 0.0,
                            get: { Double(clipManager.zoomClips[$0].easeInMs) },
                            set: { idx, val in
                                clipManager.zoomClips[idx].easeInMs = UInt64(val)
                                if !clipManager.zoomClips[idx].easeEnabled {
                                    clipManager.zoomClips[idx].easeEnabled = true
                                }
                            }
                        ), in: 0...800, step: 50)
                        Text("\(clip.easeInMs)ms")
                            .monospacedDigit()
                            .frame(width: 55)
                    }

                    LabeledContent("Ease Out") {
                        Slider(value: clipBinding(default: 0.0,
                            get: { Double(clipManager.zoomClips[$0].easeOutMs) },
                            set: { idx, val in
                                clipManager.zoomClips[idx].easeOutMs = UInt64(val)
                                if !clipManager.zoomClips[idx].easeEnabled {
                                    clipManager.zoomClips[idx].easeEnabled = true
                                }
                            }
                        ), in: 0...800, step: 50)
                        Text("\(clip.easeOutMs)ms")
                            .monospacedDigit()
                            .frame(width: 55)
                    }

                    LabeledContent {
                        Slider(value: clipBinding(default: 0.5,
                            get: { videoWidth > 0 ? clipManager.zoomClips[$0].centerX / videoWidth : 0.5 },
                            set: { clipManager.zoomClips[$0].centerX = $1 * videoWidth }
                        ), in: 0...1, step: 0.01)
                        .disabled(config.followCursor)
                        Text(String(format: "%.0f%%", videoWidth > 0 ? clip.centerX / videoWidth * 100 : 50))
                            .monospacedDigit()
                            .frame(width: 40)
                    } label: {
                        HStack(spacing: 4) {
                            Text("Center X")
                            if config.followCursor {
                                Image(systemName: "info.circle")
                                    .foregroundStyle(.secondary)
                                    .tooltip("Disabled while Follow Cursor is on — the zoom center tracks the cursor automatically")
                            }
                        }
                    }

                    LabeledContent {
                        Slider(value: clipBinding(default: 0.5,
                            get: { videoHeight > 0 ? clipManager.zoomClips[$0].centerY / videoHeight : 0.5 },
                            set: { clipManager.zoomClips[$0].centerY = $1 * videoHeight }
                        ), in: 0...1, step: 0.01)
                        .disabled(config.followCursor)
                        Text(String(format: "%.0f%%", videoHeight > 0 ? clip.centerY / videoHeight * 100 : 50))
                            .monospacedDigit()
                            .frame(width: 40)
                    } label: {
                        HStack(spacing: 4) {
                            Text("Center Y")
                            if config.followCursor {
                                Image(systemName: "info.circle")
                                    .foregroundStyle(.secondary)
                                    .tooltip("Disabled while Follow Cursor is on — the zoom center tracks the cursor automatically")
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

extension ZoomConfig {
    func with(
        scale: Double? = nil,
        easeInMs: UInt64? = nil,
        holdMs: UInt64? = nil,
        easeOutMs: UInt64? = nil,
        mergeThresholdMs: UInt64? = nil,
        enabled: Bool? = nil,
        idleTimeoutMs: UInt64? = nil,
        velocityThreshold: Double? = nil,
        followCursor: Bool? = nil,
        easingCurve: EasingCurve? = nil
    ) -> ZoomConfig {
        ZoomConfig(
            scale: scale ?? self.scale,
            easeInMs: easeInMs ?? self.easeInMs,
            holdMs: holdMs ?? self.holdMs,
            easeOutMs: easeOutMs ?? self.easeOutMs,
            mergeThresholdMs: mergeThresholdMs ?? self.mergeThresholdMs,
            enabled: enabled ?? self.enabled,
            idleTimeoutMs: idleTimeoutMs ?? self.idleTimeoutMs,
            velocityThreshold: velocityThreshold ?? self.velocityThreshold,
            followCursor: followCursor ?? self.followCursor,
            easingCurve: easingCurve ?? self.easingCurve
        )
    }
}
