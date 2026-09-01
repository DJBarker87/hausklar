import SwiftUI

struct FitnessFirstRunView: View {
    @ObservedObject var viewModel: FitnessOnboardingViewModel
    @State private var confirmSkip = false
    @AccessibilityFocusState private var focusedSetupTarget: FitnessOnboardingAccessibilityTarget?

    var body: some View {
        NavigationStack {
            setupContent
                .background(Color(.systemGroupedBackground))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Finish later") { confirmSkip = true }
                            .disabled(viewModel.isWorking)
                    }
                }
                .safeAreaInset(edge: .bottom) { controls }
        }
        .interactiveDismissDisabled()
        .confirmationDialog("Finish setting up later?", isPresented: $confirmSkip) {
            Button("Finish later") { Task { _ = await viewModel.skip() } }
            Button("Keep setting up", role: .cancel) {}
        } message: {
            Text("Your choices are saved. Fitness will stay available and you can finish this whenever it suits you.")
        }
        .onAppear { focusedSetupTarget = setupFocusTarget }
        .onChange(of: setupFocusTarget) { _, target in focusedSetupTarget = target }
    }

    private var setupContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                setupHeader
                stepContent
                if let error = viewModel.actionError {
                    Label(error, systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                }
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding(20)
            .frame(maxWidth: .infinity)
        }
    }

    private var setupHeader: some View {
        let displayedStep =
            viewModel.preview == nil
            ? min(viewModel.step, FitnessOnboardingCommitPolicy.choiceStepCount - 1) + 1
            : FitnessOnboardingCommitPolicy.totalSetupStepCount
        return VStack(alignment: .leading, spacing: 8) {
            Text(viewModel.preview == nil ? "Set up Fitness" : "Your first week")
                .font(.largeTitle.bold())
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($focusedSetupTarget, equals: setupFocusTarget)
            Text(subtitle).font(.body).foregroundStyle(.secondary)
            ProgressView(
                value: Double(displayedStep),
                total: Double(FitnessOnboardingCommitPolicy.totalSetupStepCount)
            )
            .accessibilityLabel("Setup progress")
            .accessibilityValue(
                "Step \(displayedStep) of \(FitnessOnboardingCommitPolicy.totalSetupStepCount)"
            )
        }
    }

    @ViewBuilder private var stepContent: some View {
        if let preview = viewModel.preview {
            previewStep(preview)
        } else {
            switch viewModel.step {
            case 0: outcomeStep
            case 1: availabilityStep
            default: activityStep
            }
        }
    }

    private var subtitle: String {
        if viewModel.preview != nil { return "Check the week below. Nothing is added until you confirm." }
        return [
            "What would make this useful?",
            "When could movement fit?",
            "What fits your life?",
        ][min(max(viewModel.step, 0), 2)]
    }

    private var setupFocusTarget: FitnessOnboardingAccessibilityTarget {
        .afterTransition(choiceStep: viewModel.step, hasPreview: viewModel.preview != nil)
    }

    private var outcomeStep: some View {
        choiceGroup {
            ForEach(FitnessOnboardingOutcome.allCases) { outcome in
                choiceButton(
                    title: outcome.title,
                    selected: viewModel.draft?.mainOutcome == outcome
                ) { updateDraft { $0.mainOutcome = outcome } }
            }
        }
    }

    private var availabilityStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 8)], spacing: 8) {
                ForEach(FitnessOnboardingDay.allCases) { day in
                    let selected = availability(for: day) != nil
                    Button {
                        updateDraft { draft in
                            if selected {
                                draft.availability.removeAll { $0.day == day }
                            } else {
                                draft.availability.append(
                                    .init(
                                        day: day, timeOfDay: .flexible, durationMinutes: 30
                                    ))
                                draft.availability.sort { $0.day.sortOrder < $1.day.sortOrder }
                            }
                        }
                    } label: {
                        Text(day.shortTitle).frame(maxWidth: .infinity, minHeight: 44)
                            .background(
                                selected ? Color.accentColor.opacity(0.14) : Color(.secondarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: 12)
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(selected ? Color.accentColor : Color.secondary.opacity(0.25))
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            ForEach(viewModel.draft?.availability ?? []) { slot in
                VStack(alignment: .leading, spacing: 8) {
                    Text(slot.day.title).font(.headline)
                    Picker("Time", selection: availabilityBinding(slot.day, \.timeOfDay, default: .flexible)) {
                        ForEach(FitnessOnboardingTimeOfDay.allCases) { Text($0.title).tag($0) }
                    }
                    Stepper(
                        "\(availability(for:slot.day)?.durationMinutes ?? 30) minutes",
                        value: availabilityBinding(slot.day, \.durationMinutes, default: 30),
                        in: 10...180, step: 5
                    )
                }
                .padding(14)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }

    private var activityStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            choiceGroup {
                ForEach(FitnessOnboardingActivity.allCases) { activity in
                    choiceButton(
                        title: activity.title,
                        selected: viewModel.draft?.activities.contains(activity) == true
                    ) {
                        updateDraft { draft in
                            if draft.activities.contains(activity) {
                                draft.activities.removeAll { $0 == activity }
                            } else {
                                draft.activities.append(activity)
                            }
                        }
                    }
                }
            }
        }
    }

    private func previewStep(_ preview: FitnessOnboardingWeekPreview) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(preview.summary).font(.title3.bold())
            ForEach(preview.sessions) { session in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: icon(for: session.activity))
                        .font(.title3).foregroundStyle(.tint)
                        .frame(width: 30)
                        .frame(minHeight: 44, alignment: .top)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(session.title).font(.headline)
                        Text("\(session.day.shortTitle) \(session.startTime) · \(session.durationMinutes) min")
                            .foregroundStyle(.secondary)
                        Text(session.reason).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
            }
            Button("Edit choices", systemImage: "pencil") { viewModel.back() }
                .frame(minHeight: 44)
        }
    }

    private var controls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                if viewModel.step > 0 || viewModel.preview != nil {
                    Button("Back") { viewModel.back() }
                        .buttonStyle(.bordered).frame(minHeight: 44)
                }
                Button {
                    Task {
                        if viewModel.preview != nil { _ = await viewModel.confirm() } else { await viewModel.next() }
                    }
                } label: {
                    if viewModel.isWorking {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        Text(viewModel.preview != nil ? "Confirm week" : (viewModel.step == 2 ? "Preview my week" : "Continue"))
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent).frame(minHeight: 44)
                .disabled(viewModel.isWorking)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
        .background(.bar)
    }

    private func choiceGroup<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 10, content: content)
    }

    private func choiceButton(title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).foregroundStyle(.primary)
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
            }
            .padding(.horizontal, 14).frame(maxWidth: .infinity, minHeight: 52)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func updateDraft(
        haptic: Bool = true, _ mutation: (inout FitnessOnboardingDraft) -> Void
    ) {
        guard var draft = viewModel.draft else { return }
        mutation(&draft)
        viewModel.draft = draft
        if haptic { HapticManager.selection() }
    }

    private func availability(for day: FitnessOnboardingDay) -> FitnessOnboardingAvailability? {
        viewModel.draft?.availability.first { $0.day == day }
    }

    private func availabilityBinding<Value>(
        _ day: FitnessOnboardingDay,
        _ keyPath: WritableKeyPath<FitnessOnboardingAvailability, Value>,
        default fallback: Value
    ) -> Binding<Value> {
        Binding(
            get: { availability(for: day)?[keyPath: keyPath] ?? fallback },
            set: { value in
                updateDraft { draft in
                    guard let index = draft.availability.firstIndex(where: { $0.day == day }) else { return }
                    draft.availability[index][keyPath: keyPath] = value
                }
            }
        )
    }

    private func icon(for activity: FitnessOnboardingActivity) -> String {
        switch activity {
        case .walking: "figure.walk"
        case .running: "figure.run"
        case .strength: "dumbbell.fill"
        case .cycling: "bicycle"
        case .swimming: "figure.pool.swim"
        case .mobility: "figure.cooldown"
        }
    }
}
