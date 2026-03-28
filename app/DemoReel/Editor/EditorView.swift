import SwiftUI

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

    enum SidebarTab: String, CaseIterable {
        case zoom = "Zoom"
        case style = "Style"
        case cursor = "Cursor"
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                PreviewView(
                    videoURL: appState.videoPath,
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
                    videoHeight: videoHeight
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
                    onPlaceZoom: { ms in placeZoomClip(atTimelineMs: ms) }
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
                case .zoom:
                    ZoomConfigPanel(
                        config: $zoomConfig,
                        onRegenerate: regenerateKeyframes
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
                zoomClips: clipManager.zoomClips
            )
        }
        .task {
            loadEventsAndGenerate()
            loadProjectSettingsIfNeeded()
        }
        .onChange(of: keyMonitor.lastAction) { _, event in
            guard let event else { return }
            handleKeyAction(event.action)
        }
        .onChange(of: isPlaying) { _, playing in
            if playing {
                startPlaybackTimer()
            } else {
                stopPlaybackTimer()
            }
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
    }

    private func loadEventsAndGenerate() {
        guard let eventsPath = appState.eventsPath else { return }
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

        if trimEnd <= 0 {
            trimEnd = appState.recordingDuration
        }

        if clipManager.clips.isEmpty {
            clipManager.initializeFromTrim(
                startMs: UInt64(trimStart * 1000),
                endMs: UInt64(trimEnd * 1000)
            )
        }

        // Initialize zoom clips from auto-generated keyframes
        clipManager.initializeZoomClips(from: generatedKeyframes)
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
        clipManager.addZoomClip(
            atTimelineMs: ms,
            durationMs: 1000,
            centerX: 0.5,
            centerY: 0.5,
            scale: zoomConfig.scale
        )
    }

    private func addZoomAtPlayhead() {
        let timelineMs = UInt64(timelinePosition * 1000)
        clipManager.addZoomClip(
            atTimelineMs: timelineMs,
            durationMs: 1000,
            centerX: 0.5,
            centerY: 0.5,
            scale: zoomConfig.scale
        )
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

            if let (sourceMs, _) = clipManager.sourceTimeForTimelinePosition(timelinePosition) {
                currentTime = Double(sourceMs) / 1000.0
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
        }
    }

    private func deleteSelected() {
        switch selection {
        case .videoClips(let ids):
            clipManager.deleteClips(ids: ids)
        case .zoomClips(let ids):
            clipManager.deleteZoomClips(ids: ids)
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
            enabled: project.zoomEnabled
        )
        styleConfig = StyleConfig(
            background: BackgroundConfig(
                bgType: project.bgType,
                hex: project.bgHex,
                gradientFromHex: project.bgGradientFromHex,
                gradientToHex: project.bgGradientToHex,
                gradientAngleDegrees: project.bgGradientAngle
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
            bgType: styleConfig.background.bgType,
            bgHex: styleConfig.background.hex,
            bgGradientFromHex: styleConfig.background.gradientFromHex,
            bgGradientToHex: styleConfig.background.gradientToHex,
            bgGradientAngle: styleConfig.background.gradientAngleDegrees,
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
    }

    private func loadClips(projectURL: URL) {
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
    var onRegenerate: () -> Void

    var body: some View {
        Form {
            Section("Zoom") {
                LabeledContent("Scale") {
                    Slider(value: Binding(
                        get: { config.scale },
                        set: { config = ZoomConfig(
                            scale: $0,
                            easeInMs: config.easeInMs,
                            holdMs: config.holdMs,
                            easeOutMs: config.easeOutMs,
                            mergeThresholdMs: config.mergeThresholdMs,
                            enabled: config.enabled
                        )}
                    ), in: 1.0...4.0, step: 0.1)
                    Text(String(format: "%.1fx", config.scale))
                        .monospacedDigit()
                        .frame(width: 40)
                }

                LabeledContent("Ease In") {
                    Slider(value: Binding(
                        get: { Double(config.easeInMs) },
                        set: { config = ZoomConfig(
                            scale: config.scale,
                            easeInMs: UInt64($0),
                            holdMs: config.holdMs,
                            easeOutMs: config.easeOutMs,
                            mergeThresholdMs: config.mergeThresholdMs,
                            enabled: config.enabled
                        )}
                    ), in: 100...800, step: 50)
                    Text("\(config.easeInMs)ms")
                        .monospacedDigit()
                        .frame(width: 55)
                }

                LabeledContent("Hold") {
                    Slider(value: Binding(
                        get: { Double(config.holdMs) },
                        set: { config = ZoomConfig(
                            scale: config.scale,
                            easeInMs: config.easeInMs,
                            holdMs: UInt64($0),
                            easeOutMs: config.easeOutMs,
                            mergeThresholdMs: config.mergeThresholdMs,
                            enabled: config.enabled
                        )}
                    ), in: 200...2000, step: 100)
                    Text("\(config.holdMs)ms")
                        .monospacedDigit()
                        .frame(width: 55)
                }

                LabeledContent("Ease Out") {
                    Slider(value: Binding(
                        get: { Double(config.easeOutMs) },
                        set: { config = ZoomConfig(
                            scale: config.scale,
                            easeInMs: config.easeInMs,
                            holdMs: config.holdMs,
                            easeOutMs: UInt64($0),
                            mergeThresholdMs: config.mergeThresholdMs,
                            enabled: config.enabled
                        )}
                    ), in: 100...800, step: 50)
                    Text("\(config.easeOutMs)ms")
                        .monospacedDigit()
                        .frame(width: 55)
                }

                Toggle("Enabled", isOn: Binding(
                    get: { config.enabled },
                    set: { config = ZoomConfig(
                        scale: config.scale,
                        easeInMs: config.easeInMs,
                        holdMs: config.holdMs,
                        easeOutMs: config.easeOutMs,
                        mergeThresholdMs: config.mergeThresholdMs,
                        enabled: $0
                    )}
                ))
            }

            Button("Regenerate Keyframes") {
                onRegenerate()
            }
            .buttonStyle(.borderedProminent)
        }
        .formStyle(.grouped)
    }
}
