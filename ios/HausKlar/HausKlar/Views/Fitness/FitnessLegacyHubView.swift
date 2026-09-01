import SwiftUI

/// Retained while the specialist Fitness screens are migrated behind
/// `FitnessShellView`. It is no longer presented by the app.
private struct LegacyFitnessHubView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @StateObject private var viewModel = FitnessHubViewModel()
    @StateObject private var syncStatus = FitnessSyncStatus.shared
    @State private var showingMore = false
    private let primarySections: [FitnessSection] = [.today, .nutrition, .training, .activities, .coach]
    private let moreSections: [FitnessSection] = [.strength, .progress, .recovery, .explore, .runPlans, .analysis]

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                if viewModel.isLoading && viewModel.activeWorkout == nil
                    && viewModel.plans.isEmpty && viewModel.notices.isEmpty
                    && viewModel.diary.entries.isEmpty && viewModel.weightTrend == nil
                {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Loading your Fitness overview…").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
                }
                if let active = viewModel.activeWorkout {
                    NavigationLink(value: FitnessSection.strength) {
                        HStack(spacing: 14) {
                            Image(systemName: "figure.strengthtraining.traditional")
                                .font(.title2).foregroundStyle(.white)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Resume workout").font(.headline).foregroundStyle(.white)
                                Text(active.title).font(.subheadline).foregroundStyle(.white.opacity(0.85))
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.white.opacity(0.8))
                        }
                        .padding(16)
                        .background(Color.indigo.gradient)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("fitnessResumeWorkout")
                }

                if let message = syncStatus.message {
                    Label(message, systemImage: "icloud.slash")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }

                if let error = viewModel.errorMessage {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote).foregroundStyle(.orange)
                        Button("Try again", systemImage: "arrow.clockwise") {
                            Task { await viewModel.load() }
                        }
                        .disabled(viewModel.isLoading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                }

                if !viewModel.notices.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Sync review", systemImage: "arrow.triangle.2.circlepath.circle.fill")
                            .font(.headline)
                        Text("These changes need your review. HausKlar kept the values that were attempted.")
                            .font(.footnote).foregroundStyle(.secondary)
                        ForEach(viewModel.notices) { notice in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(notice.message).font(.subheadline.weight(.semibold))
                                if let type = notice.entityType {
                                    Text(type.replacingOccurrences(of: "_", with: " ").capitalized)
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                if let values = notice.previousValues, !values.isEmpty {
                                    DisclosureGroup("Attempted fields") {
                                        VStack(alignment: .leading, spacing: 6) {
                                            ForEach(values.keys.sorted(), id: \.self) { key in
                                                LabeledContent(
                                                    key.replacingOccurrences(of: "_", with: " ").capitalized,
                                                    value: noticeDisplay(values[key] ?? .null)
                                                )
                                            }
                                        }
                                        .font(.caption)
                                        .padding(.top, 6)
                                    }
                                }
                                if let target = notice.targetEntityId {
                                    Text("Main record: \(target)")
                                        .font(.caption2.monospaced()).foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                                HStack {
                                    if notice.rejectionDisposition == .retryable,
                                        notice.rejectedMutationId != nil
                                    {
                                        Button("Review and retry", systemImage: "arrow.clockwise") {
                                            Task { await viewModel.retry(notice) }
                                        }
                                        .buttonStyle(.borderedProminent)
                                    }
                                    Button("Reviewed") { Task { await viewModel.dismiss(notice) } }
                                        .buttonStyle(.bordered)
                                }
                            }
                            .padding(12)
                            .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { metricCards }
                    VStack(spacing: 12) { metricCards }
                }

                ForEach(primarySections) { section in
                    NavigationLink(value: section) {
                        HStack(spacing: 14) {
                            Image(systemName: section.icon)
                                .font(.title3)
                                .foregroundStyle(section.tint)
                                .frame(width: 38, height: 38)
                                .background(section.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(section.title).font(.headline)
                                Text(subtitle(section)).font(.subheadline).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }
                        .padding(14)
                        .background(Color(.secondarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
                    .accessibilityHint("Opens \(section.title)")
                }

                DisclosureGroup(isExpanded: $showingMore) {
                    LazyVGrid(columns: moreColumns, spacing: 10) {
                        ForEach(moreSections) { section in
                            NavigationLink {
                                fitnessDestination(for: section)
                            } label: {
                                HStack(spacing: 9) {
                                    Image(systemName: section.icon).foregroundStyle(section.tint)
                                        .frame(width: 28, height: 28)
                                        .background(section.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                                    Text(section.title).font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.primary).lineLimit(2)
                                    Spacer(minLength: 0)
                                }
                                .padding(10)
                                .frame(maxWidth: .infinity, minHeight: 48)
                                .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("Opens \(section.title)")
                        }
                    }
                    .padding(.top, 10)
                } label: {
                    Label("More Fitness tools", systemImage: "ellipsis.circle")
                        .font(.headline)
                }
                .padding(14)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Fitness")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await viewModel.sync() }
                } label: {
                    if syncStatus.isSyncing { ProgressView() } else { Image(systemName: "arrow.triangle.2.circlepath") }
                }
                .frame(minWidth: 44, minHeight: 44)
                .disabled(syncStatus.isSyncing)
                .accessibilityLabel(syncStatus.isSyncing ? "Syncing Fitness" : "Sync Fitness")
            }
        }
        .navigationDestination(for: FitnessSection.self) { section in
            fitnessDestination(for: section)
        }
        .navigationDestination(for: FitnessRecoveryFocusRoute.self) { route in
            FitnessRecoveryView(focus: route)
        }
        .task { await viewModel.load() }
        .refreshable { await viewModel.sync() }
    }

    @ViewBuilder private var metricCards: some View {
        FitnessMetricCard(
            title: "Today",
            value: viewModel.diary.totalKcal > 0 ? "\(Int(viewModel.diary.totalKcal)) kcal" : "No food yet",
            icon: "fork.knife",
            tint: .green
        )
        FitnessMetricCard(
            title: "7-day weight",
            value: viewModel.weightTrend.map { String(format: "%.1f kg", $0) } ?? "No trend yet",
            icon: "scalemass.fill",
            tint: .purple
        )
    }

    private var moreColumns: [GridItem] {
        Array(repeating: GridItem(.flexible()), count: dynamicTypeSize.isAccessibilitySize ? 1 : 2)
    }

    @ViewBuilder
    private func fitnessDestination(for section: FitnessSection) -> some View {
        switch section {
        case .today: FitnessTodayView()
        case .activities: FitnessActivityHistoryView()
        case .runPlans: FitnessRunPlansView()
        case .nutrition: FitnessNutritionView()
        case .training: FitnessTrainingView()
        case .strength: FitnessStrengthView()
        case .progress: FitnessProgressView()
        case .analysis: FitnessAnalysisView()
        case .recovery: FitnessRecoveryView()
        case .explore: FitnessExploreView()
        case .coach: FitnessCoachView()
        }
    }

    private func subtitle(_ section: FitnessSection) -> String {
        switch section {
        case .today: "Your useful snapshot and quick actions".localized
        case .activities: "Completed sessions, imports and run detail".localized
        case .runPlans: "Structured workouts, cues and Garmin export".localized
        case .nutrition: "Search, log and repeat food quickly".localized
        case .training: "Your next session and this week".localized
        case .strength: "Exercise library and live workouts".localized
        case .progress: "Weight, strength trends and private photos".localized
        case .analysis: "Build transparent views from recorded data".localized
        case .recovery: "Sleep, personal baselines, readiness and issues".localized
        case .explore: "Compare your recorded measures across Fitness".localized
        case .coach: "Advice, chat and reviewable proposals".localized
        }
    }

    private func noticeDisplay(_ value: JSONValue) -> String {
        switch value {
        case .string(let value): value
        case .int(let value): String(value)
        case .double(let value): value.formatted()
        case .bool(let value): value ? "Yes".localized : "No".localized
        case .null: "None".localized
        case .array(let values): values.map(noticeDisplay).joined(separator: ", ")
        case .object(let values):
            values.keys.sorted().map {
                "\($0): \(noticeDisplay(values[$0] ?? .null))"
            }.joined(separator: ", ")
        }
    }
}

private struct FitnessMetricCard: View {
    let title: String
    let value: String
    let icon: String
    let tint: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title.localized, systemImage: icon).font(.caption).foregroundStyle(tint)
            Text(value).font(.headline).lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

struct FitnessNextActionCard: View {
    let action: FitnessNextAction
    let currentSection: FitnessSection
    let dismiss: () -> Void
    var openPlannedSession: ((String) -> Void)? = nil
    var recordReadiness: ((String) -> Void)? = nil
    var handleCurrentSection: ((FitnessNextActionCommand) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Label("Next action", systemImage: urgencyIcon)
                    .font(.caption.bold()).foregroundStyle(urgencyTint)
                Spacer()
                Text(action.urgency.rawValue.capitalized)
                    .font(.caption2.bold()).foregroundStyle(urgencyTint)
            }
            Text(action.title).font(.headline)
            Text(action.body).font(.subheadline).foregroundStyle(.secondary)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    command(action.action)
                    if let secondary = action.secondaryAction { command(secondary) }
                }
                VStack(alignment: .leading, spacing: 8) {
                    command(action.action)
                    if let secondary = action.secondaryAction { command(secondary) }
                }
            }
            if !action.evidence.isEmpty {
                DisclosureGroup("Why this?") {
                    VStack(alignment: .leading, spacing: 9) {
                        ForEach(action.evidence) { item in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.label).font(.caption.bold())
                                Text(item.summary).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.top, 5)
                }
                .font(.caption)
            }
            Button("Dismiss", systemImage: "xmark", action: dismiss)
                .buttonStyle(.borderless).font(.caption)
        }
        .padding(14)
        .background(urgencyTint.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private func command(_ command: FitnessNextActionCommand) -> some View {
        switch command.kind {
        case "open_body_issue", "open_recovery":
            NavigationLink(value: recoveryRoute(command)) { Label(command.label, systemImage: "waveform.path.ecg") }
                .buttonStyle(.borderedProminent)
        case "open_coach":
            if currentSection == .coach, let handleCurrentSection {
                Button {
                    handleCurrentSection(command)
                } label: {
                    Label(command.label, systemImage: "bubble.left.and.text.bubble.right")
                }
                .buttonStyle(.borderedProminent)
            } else {
                NavigationLink(value: FitnessSection.coach) { Label(command.label, systemImage: "bubble.left.and.text.bubble.right") }
                    .buttonStyle(.borderedProminent)
            }
        case "open_planned_session":
            if let openPlannedSession {
                Button {
                    openPlannedSession(command.target)
                } label: {
                    Label(command.label, systemImage: "calendar")
                }
                .buttonStyle(.borderedProminent)
            } else {
                NavigationLink(value: FitnessSection.training) { Label(command.label, systemImage: "calendar") }
                    .buttonStyle(.borderedProminent)
            }
        case "record_readiness":
            if let recordReadiness {
                Button {
                    recordReadiness(command.target)
                } label: {
                    Label(command.label, systemImage: "bolt.heart")
                }
                .buttonStyle(.borderedProminent)
            } else {
                NavigationLink(value: FitnessSection.today) { Label(command.label, systemImage: "bolt.heart") }
                    .buttonStyle(.borderedProminent)
            }
        case "open_today":
            if currentSection == .today, let handleCurrentSection {
                Button {
                    handleCurrentSection(command)
                } label: {
                    Label(command.label, systemImage: "sun.max")
                }
                .buttonStyle(.borderedProminent)
            } else {
                NavigationLink(value: FitnessSection.today) { Label(command.label, systemImage: "sun.max") }
                    .buttonStyle(.borderedProminent)
            }
        default:
            NavigationLink(value: FitnessSection.training) { Label(command.label, systemImage: "arrow.right.circle") }
                .buttonStyle(.borderedProminent)
        }
    }

    private func recoveryRoute(_ command: FitnessNextActionCommand) -> FitnessRecoveryFocusRoute {
        let evidence = action.evidence.first {
            $0.id == command.target || $0.id.hasSuffix(":\(command.target)")
        }
        return FitnessRecoveryFocusRoute(
            kind: command.kind == "open_body_issue" ? .bodyIssue : .baseline,
            target: command.target, label: evidence?.label ?? action.title,
            summary: evidence?.summary ?? action.body
        )
    }

    private var urgencyTint: Color {
        switch action.urgency {
        case .routine: .teal
        case .attention: .orange
        case .urgent: .red
        }
    }
    private var urgencyIcon: String {
        switch action.urgency {
        case .routine: "checkmark.circle"
        case .attention: "exclamationmark.circle"
        case .urgent: "exclamationmark.triangle.fill"
        }
    }
}
