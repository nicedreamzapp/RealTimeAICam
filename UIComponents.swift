import AVFoundation
import SwiftUI

// MARK: - Basic UI Components

struct ShadedEmoji: View {
    let emoji: String
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.white.opacity(0.92))
                .frame(width: size * 1.35, height: size * 1.35)
                .shadow(color: Color.black.opacity(0.09), radius: 3, x: 0, y: 2)
            Text(emoji)
                .font(.system(size: size))
        }
    }
}

struct OutlinedText: View {
    let text: String
    let fontSize: CGFloat
    let strokeWidth: CGFloat
    let strokeColor: Color
    let fillColor: Color

    init(
        text: String,
        fontSize: CGFloat,
        strokeWidth: CGFloat = 1.1,
        strokeColor: Color = .black,
        fillColor: Color = .white
    ) {
        self.text = text
        self.fontSize = fontSize
        self.strokeWidth = strokeWidth
        self.strokeColor = strokeColor
        self.fillColor = fillColor
    }

    var body: some View {
        ZStack {
            Text(text)
                .font(.system(size: fontSize, weight: .bold, design: .default))
                .foregroundColor(strokeColor)
                .offset(x: -strokeWidth, y: -strokeWidth)
            Text(text)
                .font(.system(size: fontSize, weight: .bold, design: .default))
                .foregroundColor(strokeColor)
                .offset(x: strokeWidth, y: -strokeWidth)
            Text(text)
                .font(.system(size: fontSize, weight: .bold, design: .default))
                .foregroundColor(strokeColor)
                .offset(x: -strokeWidth, y: strokeWidth)
            Text(text)
                .font(.system(size: fontSize, weight: .bold, design: .default))
                .foregroundColor(strokeColor)
                .offset(x: strokeWidth, y: strokeWidth)

            Text(text)
                .font(.system(size: fontSize, weight: .bold, design: .default))
                .foregroundColor(fillColor)
        }
    }
}

// MARK: - Button Styles

enum ButtonStyles {
    @ViewBuilder
    static func glassBackground() -> some View {
        ZStack {
            Capsule()
                .fill(.ultraThinMaterial.opacity(0.25))
                .background(Color.clear)

            Capsule()
                .fill(
                    LinearGradient(
                        colors: [Color.white.opacity(0.35), Color.clear],
                        startPoint: .topLeading,
                        endPoint: .center
                    )
                )
                .blendMode(.screen)
                .opacity(0.7)

            Capsule()
                .stroke(Color.white.opacity(0.15), lineWidth: 1)
                .shadow(color: Color.white.opacity(0.2), radius: 8, x: -2, y: -2)
                .shadow(color: Color.black.opacity(0.2), radius: 8, x: 2, y: 2)
                .blur(radius: 2)

            Capsule()
                .stroke(Color.black.opacity(0.30), lineWidth: 2)
                .blur(radius: 2)
                .offset(x: 1, y: 1)
                .mask(Capsule().fill(LinearGradient(colors: [Color.black, Color.clear], startPoint: .topLeading, endPoint: .bottomTrailing)))
        }
    }
}

// MARK: - Heading View

struct HeadingView: View {
    let animateIn: Bool

    var body: some View {
        GeometryReader { geometry in
            let scaleFactor = min(geometry.size.width / 390, 1.0)
            let titleSize: CGFloat = 52 * scaleFactor
            let subtitleSize: CGFloat = 44 * scaleFactor

            ZStack {
                // Soft blue glow behind main capsule
                Capsule()
                    .fill(Color.blue.opacity(0.35))
                    .blur(radius: 18)
                    .scaleEffect(1.12)
                    .zIndex(0)

                // Static LinearGradient fill for main pill (no shimmer)
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [Color.white.opacity(0.82), Color.blue.opacity(0.55), Color.white.opacity(0.82)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .zIndex(1)

                // Top gloss
                Capsule()
                    .fill(
                        LinearGradient(
                            gradient: Gradient(colors: [Color.white.opacity(0.62), Color.clear]),
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .blur(radius: 1.9 * scaleFactor)
                    .padding(.top, 3 * scaleFactor)
                    .zIndex(2)
                // Outer blue stroke
                Capsule()
                    .stroke(Color(red: 0.20, green: 0.43, blue: 0.82).opacity(0.42), lineWidth: 4.2 * scaleFactor)
                    .zIndex(3)
                // Inner dark border for shadow/definition
                Capsule()
                    .stroke(Color.black.opacity(0.16), lineWidth: 1.9 * scaleFactor)
                    .padding(1.9 * scaleFactor)
                    .zIndex(4)

                // Inner glow
                Capsule()
                    .fill(Color.white.opacity(0.18))
                    .blur(radius: 5.5 * scaleFactor)
                    .padding(8 * scaleFactor)
                    .zIndex(6)

                // Text with offset and opacity animation removed
                VStack(spacing: -8 * scaleFactor) {
                    OutlinedText(
                        text: "RealTime",
                        fontSize: titleSize,
                        strokeWidth: 2.1,
                        strokeColor: .black,
                        fillColor: Color(red: 0.64, green: 0.85, blue: 1.0)
                    )
                    OutlinedText(
                        text: "Ai Camera",
                        fontSize: subtitleSize,
                        strokeWidth: 2.1,
                        strokeColor: .black,
                        fillColor: Color(red: 0.81, green: 0.93, blue: 1.0)
                    )
                }
                .offset(y: 0)
                .opacity(1)
                .padding(.horizontal, 25 * scaleFactor)
                .padding(.vertical, 14 * scaleFactor)
                .zIndex(10)
            }
            .frame(width: geometry.size.width * 0.92, height: 120)
            .position(x: geometry.size.width / 2, y: 60)
            .opacity(1)
            .scaleEffect(x: 1, y: 1, anchor: .center)
        }
        .frame(height: 120)
    }
}

// MARK: - Voice Picker

struct AnimatedVoicePicker: View {
    @ObservedObject var viewModel: CameraViewModel
    let animateIn: Bool
    let onVoiceChange: () -> Void
    let speechSynthesizer: AVSpeechSynthesizer
    @State private var showVoiceGrid = false

    private func isPremiumPlus(_ voice: AVSpeechSynthesisVoice) -> Bool {
        let name = voice.name.lowercased()
        return name.contains("premium") || name.contains("plus") || name.contains("ava")
    }

    private var premiumEnglishVoices: [AVSpeechSynthesisVoice] {
        let allVoices = AVSpeechSynthesisVoice.speechVoices().filter { v in
            v.language.hasPrefix("en") && !v.name.lowercased().contains("robot") && !v.name.lowercased().contains("whisper") && !v.name.lowercased().contains("grandma")
        }
        let favoriteNames = ["Ava", "Samantha", "Daniel", "Karen", "Moira", "Serena", "Martha", "Aaron", "Fred", "Tessa", "Fiona", "Allison", "Nicky", "Joelle", "Oliver"]
        let premiumPlus = allVoices.filter { isPremiumPlus($0) }
        let enhanced = allVoices.filter { $0.quality == .enhanced && !isPremiumPlus($0) }
        let regular = allVoices.filter { $0.quality != .enhanced && !isPremiumPlus($0) }
        let sortedPremiumPlus = premiumPlus.sorted { lhs, rhs in
            let f1 = favoriteNames.firstIndex(of: lhs.name) ?? Int.max
            let f2 = favoriteNames.firstIndex(of: rhs.name) ?? Int.max
            return f1 < f2
        }
        let sortedEnhanced = enhanced.sorted { lhs, rhs in
            let f1 = favoriteNames.firstIndex(of: lhs.name) ?? Int.max
            let f2 = favoriteNames.firstIndex(of: rhs.name) ?? Int.max
            return f1 < f2
        }
        let sortedRegular = regular.sorted { lhs, rhs in
            let f1 = favoriteNames.firstIndex(of: lhs.name) ?? Int.max
            let f2 = favoriteNames.firstIndex(of: rhs.name) ?? Int.max
            return f1 < f2
        }
        var result = [AVSpeechSynthesisVoice]()
        result.append(contentsOf: sortedPremiumPlus)
        if result.count < 10 { result.append(contentsOf: sortedEnhanced.prefix(10 - result.count)) }
        if result.count < 10 { result.append(contentsOf: sortedRegular.prefix(10 - result.count)) }
        if let ava = allVoices.first(where: { $0.name == "Ava" && $0.language.hasPrefix("en") }), !result.contains(where: { $0.identifier == ava.identifier }) {
            result.insert(ava, at: 0)
        }
        return Array(result.prefix(10))
    }

    private func genderEmoji(for voice: AVSpeechSynthesisVoice) -> String {
        switch voice.gender {
        case .female: "👩"
        case .male: "👨"
        default: "🧑"
        }
    }

    private func qualityTag(for voice: AVSpeechSynthesisVoice) -> String {
        if isPremiumPlus(voice) {
            return "(Premium)"
        }
        if voice.quality == .enhanced {
            return "(Enhanced)"
        }
        return ""
    }

    private var selectedVoice: AVSpeechSynthesisVoice? {
        premiumEnglishVoices.first(where: { $0.identifier == viewModel.selectedVoiceIdentifier })
    }

    var body: some View {
        Button(action: {
            withAnimation(.spring(response: 0.3)) {
                showVoiceGrid.toggle()
            }
        }) {
            let voice = selectedVoice
            let defaultVoice = premiumEnglishVoices.first ?? AVSpeechSynthesisVoice(language: "en-US")!
            let voiceToUse = voice ?? defaultVoice
            let tag = qualityTag(for: voiceToUse)
            let cleanedName = (voice?.name ?? "Select Voice")
                .replacingOccurrences(of: " (Enhanced)", with: "")
                .replacingOccurrences(of: " (Premium)", with: "")
            HStack(spacing: 6) {
                Text(genderEmoji(for: voiceToUse))
                    .font(.system(size: 28))
                Text(cleanedName + (voice != nil && !tag.isEmpty ? " \(tag)" : ""))
                    .font(.system(size: 20, weight: .bold, design: .default))
                    .foregroundColor(.white)
                Image(systemName: showVoiceGrid ? "chevron.down" : "chevron.up")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.purple.opacity(0.24)))
            .overlay(Capsule().stroke(Color.black, lineWidth: 1.1))
        }
        .opacity(animateIn ? 1 : 0)
        .scaleEffect(animateIn ? 1 : 0.7)
        .animation(.easeOut(duration: 0.3), value: animateIn)
        .overlay(
            Group {
                if showVoiceGrid {
                    Color.clear
                        .frame(width: UIScreen.main.bounds.width, height: UIScreen.main.bounds.height)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(.spring(response: 0.25)) {
                                showVoiceGrid = false
                            }
                        }
                        .offset(y: -400)

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                        ForEach(premiumEnglishVoices, id: \.identifier) { voice in
                            Button(action: {
                                viewModel.selectedVoiceIdentifier = voice.identifier
                                onVoiceChange()
                                withAnimation(.spring(response: 0.25)) {
                                    showVoiceGrid = false
                                }
                            }) {
                                let tag = qualityTag(for: voice)
                                let cleanedName = voice.name
                                    .replacingOccurrences(of: " (Enhanced)", with: "")
                                    .replacingOccurrences(of: " (Premium)", with: "")
                                VStack(spacing: 4) {
                                    Text(genderEmoji(for: voice))
                                        .font(.system(size: 20))
                                    Text(cleanedName + (tag.isEmpty ? "" : " \(tag)"))
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundColor(.white)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(voice.identifier == viewModel.selectedVoiceIdentifier ?
                                            Color.purple.opacity(0.5) :
                                            Color.black.opacity(0.6))
                                )
                            }
                        }
                    }
                    .padding(8)
                    .frame(width: 280)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.black.opacity(0.85))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color.purple.opacity(0.4), lineWidth: 1)
                            )
                    )
                    .shadow(color: .black.opacity(0.5), radius: 10)
                    .offset(y: -200)
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
                }
            }
        )
        .accessibilityLabel("Voice Selection")
        .accessibilityHint("Choose your preferred voice for speech feedback")
    }
}

import SwiftUI

struct AnimatedLoader: View {
    let size: CGFloat
    let lineWidth: CGFloat
    let colors: [Color]
    /// Should animate fade and scale in? Defaults to true.
    let fadeIn: Bool

    @State private var rotate = false
    @State private var trimEnd: CGFloat = 0.7
    @State private var trimStart: CGFloat = 0.0
    @State private var animate = false

    init(
        size: CGFloat = 36,
        lineWidth: CGFloat = 6,
        colors: [Color] = [Color.purple, Color.blue, Color.cyan, Color.purple],
        fadeIn: Bool = true
    ) {
        self.size = size
        self.lineWidth = lineWidth
        self.colors = colors
        self.fadeIn = fadeIn
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.18), lineWidth: lineWidth)
                .frame(width: size, height: size)
            ArcLoaderShape(trimStart: trimStart, trimEnd: trimEnd)
                .stroke(
                    AngularGradient(
                        gradient: Gradient(colors: colors),
                        center: .center,
                        startAngle: .degrees(0),
                        endAngle: .degrees(360)
                    ),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .frame(width: size, height: size)
                .rotationEffect(.degrees(rotate ? 360 : 0))
                .animation(.linear(duration: 1.1).repeatForever(autoreverses: false), value: rotate)
                .animation(.easeInOut(duration: 0.95).repeatForever(autoreverses: true), value: trimEnd)
        }
        .opacity(1)
        .scaleEffect(1)
        .onAppear {
            rotate = true
            withAnimation(.easeInOut(duration: 0.95).repeatForever(autoreverses: true)) {
                trimEnd = 0.96
                trimStart = 0.08
            }
        }
    }
}

struct ArcLoaderShape: Shape {
    var trimStart: CGFloat
    var trimEnd: CGFloat
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(trimStart, trimEnd) }
        set {
            trimStart = newValue.first
            trimEnd = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addArc(
            center: CGPoint(x: rect.midX, y: rect.midY),
            radius: rect.width / 2,
            startAngle: .degrees(Double(360) * trimStart - 90),
            endAngle: .degrees(Double(360) * trimEnd - 90),
            clockwise: false
        )
        return path
    }
}
