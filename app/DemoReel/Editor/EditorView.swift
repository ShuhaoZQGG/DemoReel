import SwiftUI
import DemoReelCore

/// Main editor layout: preview on top, timeline below, tabbed controls in sidebar.
struct EditorView: View {
    @Bindable var appState: AppState
    @State private var keyframes: [ZoomKeyframe] = []
    @State private var smoothedPoints: [SmoothedPoint] = []
    @State private var currentTime: Double = 0
    @State private var isPlaying = false
    @State private var zoomConfig = defaultZoomConfig()
    @State private var styleConfig = defaultStyleConfig()
    @State private var cursorConfig = defaultCursorConfig()
    @State private var selectedTab = SidebarTab.zoom
    @State private var showExportSheet = false

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
                    keyframes: keyframes,
                    smoothedPoints: smoothedPoints,
                    currentTime: $currentTime,
                    isPlaying: $isPlaying,
                    zoomConfig: zoomConfig,
                    styleConfig: styleConfig,
                    cursorConfig: cursorConfig
                )
                .frame(minHeight: 300)

                Divider()

                TimelineView(
                    keyframes: keyframes,
                    duration: appState.recordingDuration,
                    currentTime: $currentTime,
                    isPlaying: $isPlaying
                )
                .frame(height: 120)
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
                zoomConfig: zoomConfig,
                styleConfig: styleConfig,
                cursorConfig: cursorConfig
            )
        }
        .task {
            loadEventsAndGenerate()
        }
    }

    private func loadEventsAndGenerate() {
        guard let eventsPath = appState.eventsPath else { return }
        guard let json = try? String(contentsOf: eventsPath, encoding: .utf8) else { return }
        guard let mouseEvents = try? mouseEventsFromLog(json: json) else { return }

        keyframes = generateZoomKeyframesWithConfig(
            events: mouseEvents,
            config: zoomConfig
        )
        smoothedPoints = smoothCursorPath(positions: mouseEvents, alpha: 0.3)
    }

    private func regenerateKeyframes() {
        guard let eventsPath = appState.eventsPath else { return }
        guard let json = try? String(contentsOf: eventsPath, encoding: .utf8) else { return }
        guard let mouseEvents = try? mouseEventsFromLog(json: json) else { return }

        keyframes = generateZoomKeyframesWithConfig(
            events: mouseEvents,
            config: zoomConfig
        )
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
