import SwiftUI
import AppKit

struct QuotaRingView: View {
    var remainingPercent: Double
    var hasError: Bool
    var compact: Bool

    private var clamped: Double {
        max(0, min(100, remainingPercent))
    }

    private var color: Color {
        hasError ? Color.gray.opacity(0.7) : QuotaColor.forRemaining(clamped)
    }

    var body: some View {
        let size: CGFloat = compact ? 18 : 72
        let line: CGFloat = compact ? 2.4 : 8
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.12), lineWidth: line)
            Circle()
                .trim(from: 0, to: CGFloat(clamped / 100))
                .stroke(
                    color,
                    style: StrokeStyle(lineWidth: line, lineCap: .round)
                )
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
                    Text("剩余")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
    }
}

/// Renders the menu-bar icon into an NSImage so MenuBarExtra can host a custom graphic.
enum MenuBarIconRenderer {
    @MainActor
    static func image(remaining: Double, hasError: Bool) -> NSImage {
        let view = QuotaRingView(remainingPercent: remaining, hasError: hasError, compact: true)
            .frame(width: 18, height: 18)
            .padding(1)
        let renderer = ImageRenderer(content: view)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        if let cg = renderer.cgImage {
            let image = NSImage(cgImage: cg, size: NSSize(width: 18, height: 18))
            image.isTemplate = false
            return image
        }
        return NSImage(size: NSSize(width: 18, height: 18))
    }
}
