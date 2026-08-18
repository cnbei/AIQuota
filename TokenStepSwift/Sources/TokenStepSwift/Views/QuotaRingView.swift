import AppKit
import SwiftUI

struct QuotaRingView: View {
    var remainingPercent: Double
    var hasError: Bool
    var compact: Bool

    private var clamped: Double {
        max(0, min(100, remainingPercent))
    }

    private var color: Color {
        if hasError { return Color.gray.opacity(0.7) }
        let rgb = QuotaRemainingColor.rgb(clamped)
        return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }

    var body: some View {
        let size: CGFloat = compact ? 18 : 72
        let line: CGFloat = compact ? 2.4 : 8
        ZStack {
            Circle()
                .stroke(Color.tokenInk.opacity(0.12), lineWidth: line)
            Circle()
                .trim(from: 0, to: CGFloat(clamped / 100))
                .stroke(color, style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if compact {
                Text(hasError ? "!" : "\(Int(clamped.rounded()))")
                    .font(.system(size: 7.5, weight: .bold, design: .rounded))
                    .foregroundStyle(color)
            } else {
                VStack(spacing: 2) {
                    Text(hasError ? "—" : "\(Int(clamped.rounded()))%")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(color)
                    Text(L("剩余"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.tokenMuted)
                }
            }
        }
        .frame(width: size, height: size)
    }
}
