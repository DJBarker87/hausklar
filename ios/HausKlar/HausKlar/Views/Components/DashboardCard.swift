import SwiftUI

/// A reusable card component for the dashboard. Displays a title, icon, and custom content.
struct DashboardCard<Content: View>: View {
    let title: LocalizedStringKey
    let icon: String
    var showChevron: Bool = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.headline)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                if showChevron {
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }

            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(16)
        .shadow(color: .black.opacity(0.05), radius: 8, x: 0, y: 2)
        .contentShape(Rectangle())
    }
}

#Preview {
    ZStack {
        Color(.systemGroupedBackground)
            .ignoresSafeArea()

        DashboardCard(title: "Calendar", icon: "calendar") {
            Text("3 events today")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}
