import SwiftUI

struct PerformanceOverlayView: View {
    let fps: Double
    let objectCount: Int
    let isPortrait: Bool

    // Dynamic color based on FPS performance
    private var fpsColor: Color {
        switch fps {
        case 0 ..< 15: .red
        case 15 ..< 25: .orange
        case 25 ..< 30: .yellow
        default: .green
        }
    }

    // Dynamic color based on object count
    private var objectCountColor: Color {
        switch objectCount {
        case 0: .gray
        case 1 ... 3: .blue
        case 4 ... 6: .orange
        case 7 ... 10: .red
        default: .purple
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            // Object Count Indicator
            if objectCount > 0 {
                HStack(spacing: 6) {
                    Image(systemName: "eye")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(objectCountColor)
                    Text("\(objectCount)")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.black.opacity(0.8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(objectCountColor, lineWidth: 1.5)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
                                .blur(radius: 0.5)
                        )
                        .shadow(color: objectCountColor.opacity(0.3), radius: 4, x: 0, y: 2)
                        .shadow(color: .black.opacity(0.5), radius: 8, x: 0, y: 4)
                )
            }

            // FPS Indicator
            HStack(spacing: 6) {
                Image(systemName: "speedometer")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(fpsColor)
                Text(String(format: "%.2f", fps))
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                Text("FPS")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.8))
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.black.opacity(0.8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(fpsColor, lineWidth: 1.5)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
                            .blur(radius: 0.5)
                    )
                    .shadow(color: fpsColor.opacity(0.3), radius: 4, x: 0, y: 2)
                    .shadow(color: .black.opacity(0.5), radius: 8, x: 0, y: 4)
            )
        }
    }
}

// MARK: - Preview

#Preview {
    ZStack {
        Color.gray
        VStack(spacing: 20) {
            PerformanceOverlayView(fps: 15.00, objectCount: 2, isPortrait: true)
            PerformanceOverlayView(fps: 30.00, objectCount: 5, isPortrait: true)
            PerformanceOverlayView(fps: 60.00, objectCount: 8, isPortrait: true)
        }
        .padding()
    }
}
