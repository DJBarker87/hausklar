import SwiftUI

/// Compact status banner showing temperature, lights, doors, and Sonos at a glance.
/// Sits at the top of the connected Home tab view.
struct StatusBannerView: View {
    let temperature: String?
    let lightsOn: Int
    let totalLights: Int
    let doorSummary: String
    let sonosSummary: String?

    @ScaledMetric(relativeTo: .caption2) private var bannerFontSize: CGFloat = 9

    var body: some View {
        HStack(spacing: 0) {
            if let temp = temperature {
                segment(temp, color: .hackerGreen)
                divider
            }

            segment(
                lightsOn > 0 ? "\(lightsOn) LIGHTS" : "LIGHTS OFF",
                color: lightsOn > 0 ? .hackerGreen : .hackerGrey
            )
            divider

            segment(
                doorSummary,
                color: doorSummary.contains("OPEN") ? .hackerRed : .hackerGreen
            )

            if let sonos = sonosSummary {
                divider
                segment(sonos, color: .hackerGreen)
            }
        }
        .font(.system(size: bannerFontSize, weight: .medium, design: .monospaced))
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.hackerGreen.opacity(0.15), lineWidth: 1)
        )
        // Combine all segments into one accessibility element (#44)
        .accessibilityElement(children: .combine)
    }

    private func segment(_ text: String, color: Color) -> some View {
        Text(text)
            .foregroundStyle(color)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }

    private var divider: some View {
        Text(" | ")
            .foregroundStyle(Color.hackerGrey.opacity(0.5))
    }
}
