import SwiftUI

/// A small banner displayed at the top of the screen when the device is offline.
/// Informs the user that changes will be queued and synced when connectivity returns.
struct OfflineIndicator: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.slash")
                .font(.caption)
                .accessibilityHidden(true)
            Text("Offline — changes will sync when connected")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(Color.orange.opacity(0.16))
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isStaticText)
        .accessibilityIdentifier(HausKlarAccessibilityID.Main.offlineIndicator)
    }
}

#Preview {
    VStack {
        OfflineIndicator()
        Spacer()
    }
}
