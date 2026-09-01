import SwiftUI

struct FitnessExploreView: View {
    var body: some View {
        FitnessAnalysisWorkspaceView(title: "Explore", surface: "explore")
    }
}

struct FitnessCoachView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        FitnessCoachWorkspaceView()
            .id(FitnessCoachWorkspacePolicy.key(for: appState.currentUser?.id))
    }
}

enum FitnessCoachWorkspacePolicy {
    static func key(for userId: String?) -> String {
        userId ?? "signed-out"
    }
}
