import SwiftUI

enum AppPrivacyCoverPolicy {
    static func shouldCover(isAuthenticated: Bool, scenePhase: ScenePhase) -> Bool {
        guard isAuthenticated else { return false }
        switch scenePhase {
        case .active:
            return false
        case .inactive, .background:
            return true
        @unknown default:
            return true
        }
    }
}

/// A static, non-sensitive surface rendered before iOS captures an app-switcher
/// snapshot. It intentionally contains no timers, account data, or animation.
struct AppPrivacyCover: View {
    var body: some View {
        ZStack {
            Color(.systemBackground)
            VStack(spacing: 12) {
                Image(systemName: "house.fill")
                    .font(.system(size: 42, weight: .semibold))
                    .foregroundStyle(.tint)
                Text("HausKlar")
                    .font(.title2.bold())
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
        .allowsHitTesting(true)
    }
}
