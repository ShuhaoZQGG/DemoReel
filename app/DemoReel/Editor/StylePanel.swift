import SwiftUI

/// Sidebar panel for configuring visual style: background, padding, corners, shadow.
struct StylePanel: View {
    @Binding var config: StyleConfig

    private let gradientPresets: [(String, String, String, Double)] = [
        ("Indigo → Purple", "#667eea", "#764ba2", 135),
        ("Cyan → Blue", "#0891b2", "#1d4ed8", 135),
        ("Rose → Orange", "#f43f5e", "#f97316", 135),
        ("Green → Teal", "#22c55e", "#14b8a6", 135),
        ("Slate", "#334155", "#1e293b", 180),
    ]

    private let solidPresets: [String] = [
        "#1a1a2e", "#0f172a", "#1e1b4b", "#1c1917",
        "#ffffff", "#f8fafc", "#fef3c7", "#ecfdf5",
    ]

    var body: some View {
        Form {
            Section("Background") {
                Picker("Type", selection: bgTypeBinding) {
                    Text("Solid").tag("solid")
                    Text("Gradient").tag("gradient")
                    Text("Transparent").tag("transparent")
                }
                .pickerStyle(.segmented)

                if config.background.bgType == "solid" {
                    ColorPicker("Color", selection: solidColorBinding)

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 28))], spacing: 6) {
                        ForEach(solidPresets, id: \.self) { hex in
                            Circle()
                                .fill(Color(hex: hex))
                                .frame(width: 28, height: 28)
                                .overlay(
                                    Circle().strokeBorder(.primary.opacity(0.2), lineWidth: 1)
                                )
                                .onTapGesture {
                                    var bg = config.background
                                    bg = BackgroundConfig(
                                        bgType: "solid",
                                        hex: hex,
                                        gradientFromHex: bg.gradientFromHex,
                                        gradientToHex: bg.gradientToHex,
                                        gradientAngleDegrees: bg.gradientAngleDegrees
                                    )
                                    config = StyleConfig(
                                        background: bg,
                                        padding: config.padding,
                                        cornerRadius: config.cornerRadius,
                                        shadowEnabled: config.shadowEnabled,
                                        shadowIntensity: config.shadowIntensity,
                                        aspectRatio: config.aspectRatio
                                    )
                                }
                        }
                    }
                }

                if config.background.bgType == "gradient" {
                    ColorPicker("From", selection: gradientFromBinding)
                    ColorPicker("To", selection: gradientToBinding)

                    LabeledContent("Angle") {
                        Slider(
                            value: gradientAngleBinding,
                            in: 0...360,
                            step: 15
                        )
                        Text("\(Int(config.background.gradientAngleDegrees))")
                            .monospacedDigit()
                            .frame(width: 30)
                    }

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(Array(gradientPresets.enumerated()), id: \.offset) { _, preset in
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(LinearGradient(
                                        colors: [Color(hex: preset.1), Color(hex: preset.2)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ))
                                    .frame(width: 44, height: 28)
                                    .onTapGesture {
                                        config = StyleConfig(
                                            background: BackgroundConfig(
                                                bgType: "gradient",
                                                hex: config.background.hex,
                                                gradientFromHex: preset.1,
                                                gradientToHex: preset.2,
                                                gradientAngleDegrees: preset.3
                                            ),
                                            padding: config.padding,
                                            cornerRadius: config.cornerRadius,
                                            shadowEnabled: config.shadowEnabled,
                                            shadowIntensity: config.shadowIntensity,
                                            aspectRatio: config.aspectRatio
                                        )
                                    }
                            }
                        }
                    }
                }
            }

            Section("Frame") {
                LabeledContent("Padding") {
                    Slider(value: paddingBinding, in: 0...80, step: 4)
                    Text("\(Int(config.padding))px")
                        .monospacedDigit()
                        .frame(width: 40)
                }

                LabeledContent("Corners") {
                    Slider(value: cornerRadiusBinding, in: 0...24, step: 2)
                    Text("\(Int(config.cornerRadius))px")
                        .monospacedDigit()
                        .frame(width: 40)
                }
            }

            Section("Shadow") {
                Toggle("Enabled", isOn: shadowEnabledBinding)

                if config.shadowEnabled {
                    LabeledContent("Intensity") {
                        Slider(value: shadowIntensityBinding, in: 0...1, step: 0.1)
                        Text(String(format: "%.1f", config.shadowIntensity))
                            .monospacedDigit()
                            .frame(width: 30)
                    }
                }
            }

            Section("Aspect Ratio") {
                Picker("Ratio", selection: aspectRatioBinding) {
                    Text("16:9").tag("landscape_16x9")
                    Text("1:1").tag("square_1x1")
                    Text("9:16").tag("portrait_9x16")
                    Text("4:3").tag("landscape_4x3")
                    Text("Auto").tag("auto")
                }
                .pickerStyle(.segmented)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Bindings

    private var bgTypeBinding: Binding<String> {
        Binding(
            get: { config.background.bgType },
            set: { newType in
                config = StyleConfig(
                    background: BackgroundConfig(
                        bgType: newType,
                        hex: config.background.hex,
                        gradientFromHex: config.background.gradientFromHex,
                        gradientToHex: config.background.gradientToHex,
                        gradientAngleDegrees: config.background.gradientAngleDegrees
                    ),
                    padding: config.padding,
                    cornerRadius: config.cornerRadius,
                    shadowEnabled: config.shadowEnabled,
                    shadowIntensity: config.shadowIntensity,
                    aspectRatio: config.aspectRatio
                )
            }
        )
    }

    private var solidColorBinding: Binding<Color> {
        Binding(
            get: { Color(hex: config.background.hex) },
            set: { _ in }
        )
    }

    private var gradientFromBinding: Binding<Color> {
        Binding(
            get: { Color(hex: config.background.gradientFromHex) },
            set: { _ in }
        )
    }

    private var gradientToBinding: Binding<Color> {
        Binding(
            get: { Color(hex: config.background.gradientToHex) },
            set: { _ in }
        )
    }

    private var gradientAngleBinding: Binding<Double> {
        Binding(
            get: { config.background.gradientAngleDegrees },
            set: { newAngle in
                config = StyleConfig(
                    background: BackgroundConfig(
                        bgType: config.background.bgType,
                        hex: config.background.hex,
                        gradientFromHex: config.background.gradientFromHex,
                        gradientToHex: config.background.gradientToHex,
                        gradientAngleDegrees: newAngle
                    ),
                    padding: config.padding,
                    cornerRadius: config.cornerRadius,
                    shadowEnabled: config.shadowEnabled,
                    shadowIntensity: config.shadowIntensity,
                    aspectRatio: config.aspectRatio
                )
            }
        )
    }

    private var paddingBinding: Binding<Double> {
        Binding(
            get: { config.padding },
            set: { config = StyleConfig(
                background: config.background,
                padding: $0,
                cornerRadius: config.cornerRadius,
                shadowEnabled: config.shadowEnabled,
                shadowIntensity: config.shadowIntensity,
                aspectRatio: config.aspectRatio
            )}
        )
    }

    private var cornerRadiusBinding: Binding<Double> {
        Binding(
            get: { config.cornerRadius },
            set: { config = StyleConfig(
                background: config.background,
                padding: config.padding,
                cornerRadius: $0,
                shadowEnabled: config.shadowEnabled,
                shadowIntensity: config.shadowIntensity,
                aspectRatio: config.aspectRatio
            )}
        )
    }

    private var shadowEnabledBinding: Binding<Bool> {
        Binding(
            get: { config.shadowEnabled },
            set: { config = StyleConfig(
                background: config.background,
                padding: config.padding,
                cornerRadius: config.cornerRadius,
                shadowEnabled: $0,
                shadowIntensity: config.shadowIntensity,
                aspectRatio: config.aspectRatio
            )}
        )
    }

    private var shadowIntensityBinding: Binding<Double> {
        Binding(
            get: { config.shadowIntensity },
            set: { config = StyleConfig(
                background: config.background,
                padding: config.padding,
                cornerRadius: config.cornerRadius,
                shadowEnabled: config.shadowEnabled,
                shadowIntensity: $0,
                aspectRatio: config.aspectRatio
            )}
        )
    }

    private var aspectRatioBinding: Binding<String> {
        Binding(
            get: { config.aspectRatio.ratio },
            set: { config = StyleConfig(
                background: config.background,
                padding: config.padding,
                cornerRadius: config.cornerRadius,
                shadowEnabled: config.shadowEnabled,
                shadowIntensity: config.shadowIntensity,
                aspectRatio: AspectRatioConfig(ratio: $0)
            )}
        )
    }
}

// MARK: - Color hex extension

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: .init(charactersIn: "#"))
        var rgb: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&rgb)

        let r, g, b: Double
        if hex.count == 3 {
            r = Double((rgb >> 8) & 0xF) / 15.0
            g = Double((rgb >> 4) & 0xF) / 15.0
            b = Double(rgb & 0xF) / 15.0
        } else {
            r = Double((rgb >> 16) & 0xFF) / 255.0
            g = Double((rgb >> 8) & 0xFF) / 255.0
            b = Double(rgb & 0xFF) / 255.0
        }
        self.init(red: r, green: g, blue: b)
    }
}
