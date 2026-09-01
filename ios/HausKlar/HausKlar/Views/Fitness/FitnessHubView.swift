import SwiftUI

enum FitnessSection: String, CaseIterable, Identifiable, Hashable {
    case today, activities, runPlans, nutrition, training, strength, progress, analysis, recovery, explore, coach
    var id: String { rawValue }
    var title: String {
        switch self {
        case .today: "Today".localized
        case .nutrition: "Food".localized
        case .training: "Plan".localized
        case .activities: "History".localized
        case .coach: "Coach".localized
        case .runPlans: "Run plans".localized
        case .strength: "Strength".localized
        case .progress: "Progress".localized
        case .analysis: "Analysis".localized
        case .recovery: "Recovery".localized
        case .explore: "Explore".localized
        }
    }
    var icon: String {
        switch self {
        case .today: "sun.max.fill"
        case .activities: "figure.run.circle.fill"
        case .runPlans: "list.bullet.clipboard.fill"
        case .nutrition: "fork.knife"
        case .training: "calendar.badge.clock"
        case .strength: "dumbbell.fill"
        case .progress: "chart.xyaxis.line"
        case .analysis: "chart.bar.xaxis"
        case .recovery: "waveform.path.ecg"
        case .explore: "square.grid.2x2.fill"
        case .coach: "bubble.left.and.text.bubble.right.fill"
        }
    }
    var tint: Color {
        switch self {
        case .today: .orange
        case .activities: .cyan
        case .runPlans: .blue
        case .nutrition: .green
        case .training: .blue
        case .strength: .indigo
        case .progress: .purple
        case .analysis: .purple
        case .recovery: .mint
        case .explore: .teal
        case .coach: .pink
        }
    }
}

struct FitnessRecoveryFocusRoute:Hashable {
    enum Kind:Hashable { case bodyIssue,baseline }
    let kind:Kind
    let target:String
    let label:String
    let summary:String
}

struct FitnessNutritionView: View {
    var body: some View {
        FitnessLogHomeView()
    }
}
