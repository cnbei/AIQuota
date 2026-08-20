import SwiftUI

struct CodexBarUsageBar: View {
    var fillPercent: Double
    var tint: Color
    var expectedFillPercent: Double?
    var paceOnTop: Bool = true

    private var clamped: Double {
        min(max(fillPercent, 0), 100)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.tokenTrack)
                Capsule()
                    .fill(tint)
                    .frame(width: max(4, proxy.size.width * clamped / 100))
                if let expectedFillPercent {
                    let x = proxy.size.width * min(max(expectedFillPercent, 0), 100) / 100
                    Capsule()
                        .fill(paceOnTop ? Color.tokenInk.opacity(0.45) : Color.red.opacity(0.85))
                        .frame(width: 2, height: proxy.size.height + 2)
                        .offset(x: x - 1, y: -1)
                }
            }
        }
        .frame(height: 6)
    }
}

struct CodexBarMetricRow: View {
    var title: String
    var remainingPercent: Double
    var resetText: String?
    var metaText: String?
    var tint: Color
    var expectedUsedPercent: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(Color.tokenInk)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let resetText {
                    Text(resetText)
                        .font(.footnote)
                        .foregroundStyle(Color.tokenMuted)
                        .multilineTextAlignment(.trailing)
                        .lineLimit(2)
                }
            }
            CodexBarUsageBar(
                fillPercent: remainingPercent,
                tint: tint,
                expectedFillPercent: expectedUsedPercent.map { 100 - $0 },
                paceOnTop: (expectedUsedPercent ?? 0) >= (100 - remainingPercent)
            )
            if let metaText, !metaText.isEmpty {
                Text(metaText)
                    .font(.footnote)
                    .foregroundStyle(Color.tokenMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
