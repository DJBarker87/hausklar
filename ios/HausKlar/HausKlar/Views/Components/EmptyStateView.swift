import SwiftUI

/// A reusable empty-state placeholder with an icon, title, subtitle, and optional action button.
struct EmptyStateView: View {
    let icon: String
    let title: String
    let subtitle: String
    var actionLabel: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.largeTitle)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title)
                .font(.headline)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let actionLabel = actionLabel, let action = action {
                Button(action: action) {
                    Text(actionLabel)
                        .font(.subheadline.bold())
                        .frame(minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(40)
    }
}

#Preview {
    ZStack {
        Color.black.ignoresSafeArea()
        EmptyStateView(
            icon: "tray",
            title: "No Items",
            subtitle: "There's nothing here yet. Add your first item to get started.",
            actionLabel: "Add Item",
            action: {}
        )
    }
}
