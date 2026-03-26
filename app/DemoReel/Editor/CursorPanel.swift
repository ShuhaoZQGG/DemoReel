import SwiftUI
import DemoReelCore

/// Sidebar panel for configuring cursor rendering style.
struct CursorPanel: View {
    @Binding var config: CursorConfig

    var body: some View {
        Form {
            Section("Cursor Style") {
                Picker("Style", selection: cursorStyleBinding) {
                    Text("Circle Highlight").tag("circle")
                    Text("System Cursor").tag("system")
                    Text("Hidden").tag("hidden")
                }

                if config.cursorStyle != "hidden" {
                    LabeledContent("Size") {
                        Slider(value: sizeBinding, in: 0.5...3.0, step: 0.25)
                        Text(String(format: "%.1fx", config.sizeMultiplier))
                            .monospacedDigit()
                            .frame(width: 40)
                    }
                }
            }

            Section("Click Highlight") {
                Toggle("Show on Click", isOn: clickHighlightBinding)

                if config.clickHighlight {
                    ColorPicker("Color", selection: highlightColorBinding)
                }
            }

            Section("Preview") {
                HStack {
                    Spacer()
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(.quaternary)
                            .frame(width: 120, height: 80)

                        if config.cursorStyle == "circle" {
                            Circle()
                                .fill(Color(hex: config.highlightColorHex).opacity(0.3))
                                .frame(
                                    width: 24 * config.sizeMultiplier,
                                    height: 24 * config.sizeMultiplier
                                )
                            Circle()
                                .fill(.white)
                                .frame(
                                    width: 8 * config.sizeMultiplier,
                                    height: 8 * config.sizeMultiplier
                                )
                        } else if config.cursorStyle == "system" {
                            Image(systemName: "cursorarrow")
                                .font(.system(size: 20 * config.sizeMultiplier))
                                .foregroundStyle(.white)
                        }
                    }
                    Spacer()
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Bindings

    private var cursorStyleBinding: Binding<String> {
        Binding(
            get: { config.cursorStyle },
            set: { config = CursorConfig(
                cursorStyle: $0,
                sizeMultiplier: config.sizeMultiplier,
                clickHighlight: config.clickHighlight,
                highlightColorHex: config.highlightColorHex
            )}
        )
    }

    private var sizeBinding: Binding<Double> {
        Binding(
            get: { config.sizeMultiplier },
            set: { config = CursorConfig(
                cursorStyle: config.cursorStyle,
                sizeMultiplier: $0,
                clickHighlight: config.clickHighlight,
                highlightColorHex: config.highlightColorHex
            )}
        )
    }

    private var clickHighlightBinding: Binding<Bool> {
        Binding(
            get: { config.clickHighlight },
            set: { config = CursorConfig(
                cursorStyle: config.cursorStyle,
                sizeMultiplier: config.sizeMultiplier,
                clickHighlight: $0,
                highlightColorHex: config.highlightColorHex
            )}
        )
    }

    private var highlightColorBinding: Binding<Color> {
        Binding(
            get: { Color(hex: config.highlightColorHex) },
            set: { _ in }
        )
    }
}
