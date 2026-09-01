import SwiftUI

struct FitnessStrengthView: View {
    private let initialPlanId:String?
    @StateObject private var viewModel=FitnessStrengthViewModel()
    @State private var showingStart=false
    @State private var showingPicker=false
    @State private var showingFinish=false
    @State private var selectedSetContext: FitnessStrengthSetContext?
    @State private var selectedComponentGroup: FitnessSetGroup?
    @State private var selectedSetupExercise: FitnessSessionExercise?
    @State private var substitutionTarget: FitnessSessionExercise?
    @State private var showingLibraryMerge=false
    @State private var startSourceId="blank"
    @State private var consumedInitialPlan=false
    @State private var copiedWorkoutId: String?

    init(initialPlanId:String?=nil) {
        self.initialPlanId=initialPlanId
    }

    var body: some View {
        List {
            if let error=viewModel.errorMessage {
                Section {
                    Label(error,systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    Button("Try again",systemImage: "arrow.clockwise") {
                        Task { await viewModel.load() }
                    }
                    .disabled(viewModel.isLoading)
                }
            }
            if viewModel.isLoading && viewModel.activeWorkout == nil
                && viewModel.exercises.isEmpty && viewModel.plans.isEmpty
                && viewModel.savedWorkouts.isEmpty && viewModel.recentSessions.isEmpty {
                Section {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Loading strength…").foregroundStyle(.secondary)
                    }
                }
            } else if let session=viewModel.activeWorkout {
                activeHeader(session)
                if !viewModel.activeIssues.isEmpty { issueContext }
                if viewModel.workoutExercises.isEmpty {
                    ContentUnavailableView(
                        "No exercises yet",systemImage: "dumbbell",
                        description: Text("Add a planned, favourite, recent, or searched exercise. The workout remains available offline.")
                    )
                }
                Section("Exercises") {
                    ForEach(Array(viewModel.workoutExercises.enumerated()),id: \.element.id) { index,item in
                        FitnessActiveExerciseCard(
                            index: index,item: item,target: { viewModel.target(for: $0) },
                            comparable: viewModel.comparable[item.id] ?? [],
                            suggestion: viewModel.suggestion(for: item.exercise),
                            onAddSet: { group in
                                selectedSetContext=FitnessStrengthSetContext(
                                    exercise: item.exercise,group: group,
                                    target: group.flatMap(viewModel.target(for:)), component: nil
                                )
                            },
                            onEditSet: { group, component in
                                selectedSetContext=FitnessStrengthSetContext(
                                    exercise: item.exercise, group: group,
                                    target: nil, component: component
                                )
                            },
                            onAddComponent: { selectedComponentGroup=$0 },
                            onSkip: { group in Task { await viewModel.skip(group) } },
                            onSetup: { selectedSetupExercise=item.exercise },
                            onSubstitute: { substitutionTarget=item.exercise; showingPicker=true }
                        )
                    }
                    .onMove { source,destination in
                        Task { await viewModel.moveExercises(from: source,to: destination) }
                    }
                }
                Section {
                    Button("Add exercise",systemImage: "plus.circle.fill") { showingPicker=true }
                        .font(.headline).frame(maxWidth: .infinity,minHeight: 44)
                    Button("Finish workout",systemImage: "checkmark.circle.fill") { showingFinish=true }
                        .font(.headline).frame(maxWidth: .infinity,minHeight: 44).foregroundStyle(.indigo)
                }
            } else {
                Section {
                    ContentUnavailableView(
                        "Ready when you are",systemImage: "figure.strengthtraining.traditional",
                        description: Text("Start an accepted plan or a blank workout. Every set is committed locally before it appears saved.")
                    )
                    Button("Start workout",systemImage: "play.fill") {
                        startSourceId="blank"
                        showingStart=true
                    }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .frame(maxWidth: .infinity)
                }
                Section("Upcoming startable plans") {
                    let startable=viewModel.plans.filter(\.isStartable)
                    if startable.isEmpty {
                        Text("No accepted or scheduled strength plan. Proposed plans require review before Start.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(startable.prefix(5)) { plan in
                        Button {
                            startSourceId="plan:\(plan.id)"
                            showingStart=true
                        } label: {
                            VStack(alignment: .leading,spacing: 3) {
                                Text(plan.title).foregroundStyle(.primary)
                                Text(plan.plannedFor?.formatted(date: .abbreviated,time: .shortened) ?? plan.status.capitalized)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section("Saved and previous workouts") {
                    NavigationLink { FitnessTrainingView() } label: {
                        Label("Author a strength workout",systemImage: "square.and.pencil")
                    }
                    ForEach(viewModel.savedWorkouts.prefix(6)) { workout in
                        Button {
                            startSourceId="saved:\(workout.versionId)"
                            showingStart=true
                        } label: {
                            HStack {
                                VStack(alignment: .leading,spacing: 2) {
                                    Text(workout.name).foregroundStyle(.primary)
                                    Text("Accepted version · \(workout.exercises.count) exercises")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(); Image(systemName: "play.circle")
                            }
                        }
                    }
                    ForEach(viewModel.recentSessions.prefix(6)) { session in
                        HStack {
                            Button {
                                startSourceId="previous:\(session.id)"
                                showingStart=true
                            } label: {
                                VStack(alignment: .leading,spacing: 2) {
                                    Text(session.title).foregroundStyle(.primary)
                                    Text("Copy previous · \(session.startedAt.formatted(date: .abbreviated,time: .omitted))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity,alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            Button(copiedWorkoutId == session.id ? "Copied" : "Copy",systemImage: copiedWorkoutId == session.id ? "checkmark" : "doc.on.doc") {
                                copyWorkout(session)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    if viewModel.savedWorkouts.isEmpty && viewModel.recentSessions.isEmpty {
                        Text("Saved workouts and copied history will appear here.")
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Exercise library") {
                    Button("Browse or create exercise",systemImage: "books.vertical") { showingPicker=true }
                    Button("Merge duplicate exercises or setups",systemImage: "arrow.triangle.merge") {
                        showingLibraryMerge=true
                    }
                    ForEach(viewModel.exercises.prefix(10)) { item in
                        LabeledContent(item.name,value: item.movementPatternKey.replacingOccurrences(of: "_",with: " "))
                    }
                }
            }
        }
        .navigationTitle("Strength")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Manage exercise merges",systemImage: "arrow.triangle.merge") {
                    showingLibraryMerge=true
                }
                if viewModel.activeWorkout != nil { EditButton() }
            }
        }
        .sheet(isPresented: $showingStart,onDismiss: { startSourceId="blank" }) {
            FitnessStrengthStartSheet(viewModel: viewModel,initialSourceId: startSourceId)
        }
        .sheet(isPresented: $showingPicker,onDismiss: { substitutionTarget=nil }) {
            FitnessStrengthExercisePicker(
                viewModel: viewModel,substitutionTarget: substitutionTarget
            )
        }
        .sheet(isPresented: $showingFinish) { FitnessStrengthFinishSheet(viewModel: viewModel) }
        .sheet(item: $selectedSetContext) { context in
            FitnessStrengthSetSheet(context: context,viewModel: viewModel)
        }
        .sheet(item: $selectedComponentGroup) { group in
            FitnessStrengthComponentSheet(group: group,viewModel: viewModel)
        }
        .sheet(item: $selectedSetupExercise) { exercise in
            FitnessStrengthSetupSheet(exercise: exercise,viewModel: viewModel)
        }
        .sheet(isPresented: $showingLibraryMerge) {
            FitnessStrengthMergeSheet(viewModel: viewModel)
        }
        .task {
            await viewModel.load()
            guard !consumedInitialPlan,let initialPlanId,
                  viewModel.plans.contains(where:{ $0.id == initialPlanId && $0.isStartable })
            else { return }
            consumedInitialPlan=true
            startSourceId="plan:\(initialPlanId)"
            showingStart=true
        }
        .refreshable { await viewModel.load() }
    }

    @ViewBuilder
    private func activeHeader(_ session: FitnessStrengthSession) -> some View {
        Section("Active workout") {
            VStack(alignment: .leading,spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(session.title).font(.title3.bold())
                    Spacer()
                    TimelineView(.periodic(from: .now,by: 1)) { context in
                        Text(elapsed(context.date,from: session.startedAt))
                            .font(.headline.monospacedDigit())
                    }
                }
                HStack(spacing: 12) {
                    if let readiness=session.readiness { Label("\(readiness)/5",systemImage: "bolt.heart") }
                    if viewModel.pendingMutationCount > 0 {
                        Label("Saved offline",systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
                if session.readiness == nil {
                    Menu("Add retrospective readiness") {
                        ForEach(1...5,id: \.self) { value in
                            Button("\(value)/5") { Task { await viewModel.addLateReadiness(value) } }
                        }
                    }
                }
                FitnessRestTimerRow(session: session,viewModel: viewModel)
                Button(copiedWorkoutId == session.id ? "Workout copied" : "Copy whole workout",systemImage: copiedWorkoutId == session.id ? "checkmark" : "doc.on.doc") {
                    copyWorkout(session)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var issueContext: some View {
        Section {
            ForEach(viewModel.activeIssues.prefix(3)) { issue in
                HStack(alignment: .top) {
                    Image(systemName: "bandage").foregroundStyle(.orange)
                    VStack(alignment: .leading,spacing: 3) {
                        Text("\(issue.bodyLocationKey.replacingOccurrences(of: "_",with: " ")) · \(issue.side.replacingOccurrences(of: "_",with: " "))")
                            .font(.subheadline.weight(.medium))
                        Text("Recorded \(issue.issueTypeKey), severity \(issue.severity)/10. Choose a substitution if useful; HausKlar does not diagnose it.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        } header: { Text("Active body issue") }
    }

    private func elapsed(_ now: Date,from start: Date) -> String {
        let seconds=max(0,Int(now.timeIntervalSince(start)))
        return String(format: "%d:%02d:%02d",seconds/3600,(seconds%3600)/60,seconds%60)
    }

    private func copyWorkout(_ session: FitnessStrengthSession) {
        Task {
            guard let text=await viewModel.workoutExportText(for: session) else { return }
            FitnessStrengthTextExport.copy(text)
            copiedWorkoutId=session.id
            HapticManager.success()
        }
    }
}

private struct FitnessRestTimerRow: View {
    let session: FitnessStrengthSession
    @ObservedObject var viewModel: FitnessStrengthViewModel
    @State private var restStartedAt=Date()

    var body: some View {
        Group {
            if let deadline=session.restTimerDeadline {
                TimelineView(.periodic(from: .now,by: 1)) { context in
                    HStack {
                        VStack(alignment: .leading,spacing: 2) {
                            Text("Rest elapsed").font(.caption).foregroundStyle(.secondary)
                            Label(elapsedRest(now: context.date),systemImage: "timer")
                                .font(.title3.monospacedDigit().bold())
                            Text("Target remaining \(remaining(deadline,now: context.date))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Dismiss") { Task { await viewModel.clearRest() } }
                    }
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack {
                        Text("Rest timer").foregroundStyle(.secondary)
                        Spacer()
                        ForEach([60,90,120],id: \.self) { seconds in
                            Button("\(seconds)s") { Task { await viewModel.startRest(seconds: seconds) } }
                                .buttonStyle(.bordered)
                        }
                    }
                    Menu {
                        ForEach([60,90,120],id: \.self) { seconds in
                            Button("\(seconds) seconds") {
                                Task { await viewModel.startRest(seconds: seconds) }
                            }
                        }
                    } label: {
                        Label("Start rest timer",systemImage: "timer")
                            .frame(maxWidth: .infinity,minHeight: 44,alignment: .leading)
                    }
                }
            }
        }
        .onChange(of: session.restTimerDeadline) { _, deadline in
            if deadline != nil { restStartedAt=Date() }
        }
    }

    private func remaining(_ deadline: Date,now: Date) -> String {
        let seconds=max(0,Int(deadline.timeIntervalSince(now)))
        return String(format: "%d:%02d",seconds/60,seconds%60)
    }

    private func elapsedRest(now: Date) -> String {
        let seconds=max(0,Int(now.timeIntervalSince(restStartedAt)))
        return String(format: "%d:%02d",seconds/60,seconds%60)
    }
}

private struct FitnessActiveExerciseCard: View {
    let index: Int
    let item: FitnessWorkoutExercise
    let target: (FitnessSetGroup) -> FitnessPlannedStrengthSet?
    let comparable: [FitnessComparableSet]
    let suggestion: FitnessStrengthSuggestion?
    let onAddSet: (FitnessSetGroup?) -> Void
    let onEditSet: (FitnessSetGroup, FitnessSetComponent) -> Void
    let onAddComponent: (FitnessSetGroup) -> Void
    let onSkip: (FitnessSetGroup) -> Void
    let onSetup: () -> Void
    let onSubstitute: () -> Void
    @State private var isExpanded: Bool

    init(
        index: Int,item: FitnessWorkoutExercise,
        target: @escaping (FitnessSetGroup) -> FitnessPlannedStrengthSet?,
        comparable: [FitnessComparableSet],suggestion: FitnessStrengthSuggestion?,
        onAddSet: @escaping (FitnessSetGroup?) -> Void,
        onEditSet: @escaping (FitnessSetGroup, FitnessSetComponent) -> Void,
        onAddComponent: @escaping (FitnessSetGroup) -> Void,
        onSkip: @escaping (FitnessSetGroup) -> Void,
        onSetup: @escaping () -> Void,onSubstitute: @escaping () -> Void
    ) {
        self.index=index; self.item=item; self.target=target; self.comparable=comparable
        self.suggestion=suggestion; self.onAddSet=onAddSet; self.onEditSet=onEditSet
        self.onAddComponent=onAddComponent
        self.onSkip=onSkip; self.onSetup=onSetup; self.onSubstitute=onSubstitute
        _isExpanded=State(initialValue: index == 0)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading,spacing: 10) {
                ForEach(item.groups) { workoutGroup in
                    groupRow(workoutGroup)
                }
                Button("Log next set",systemImage: "plus.circle.fill") { onAddSet(nil) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .frame(maxWidth: .infinity,minHeight: 48)
                DisclosureGroup("History and exercise options") {
                    if let previous=comparable.first {
                        LabeledContent("Previous",value: comparableDescription(previous))
                            .font(.caption)
                    } else {
                        Text("No comparable history for this setup yet.").font(.caption).foregroundStyle(.secondary)
                    }
                    if let suggestion {
                        VStack(alignment: .leading,spacing: 2) {
                            Text(suggestion.title).font(.caption.bold())
                            Text(suggestion.recommendation ?? suggestion.reason).font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(8).background(.indigo.opacity(0.08),in: RoundedRectangle(cornerRadius: 8))
                    }
                    HStack {
                        Button("Change setup",action: onSetup)
                        Spacer()
                        Button("Substitute",action: onSubstitute)
                    }
                    .font(.subheadline)
                }
            }
            .padding(.top,8)
        } label: {
            VStack(alignment: .leading,spacing: 3) {
                HStack {
                    Text(index == 0 ? "Current" : index == 1 ? "Next" : "#\(index+1)")
                        .font(.caption.bold()).foregroundStyle(index == 0 ? .indigo : .secondary)
                    Text(item.exercise.exerciseName).font(.headline)
                }
                Text("\(item.exercise.setupName) · \(loadLabel(item.exercise.setupLoadModeSnapshot))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onChange(of: index) { _,newIndex in
            if newIndex == 0 { isExpanded=true }
        }
    }

    @ViewBuilder
    private func groupRow(_ workout: FitnessWorkoutGroup) -> some View {
        let planned=target(workout.group)
        VStack(alignment: .leading,spacing: 7) {
            HStack {
                Text("Set \(workout.group.position+1) · \(workout.group.role.title)").font(.subheadline.bold())
                if workout.group.isAMRAP { Text("AMRAP").fitnessPill(.orange) }
                Spacer()
                Text(workout.group.status.title).font(.caption).foregroundStyle(.secondary)
            }
            if let planned {
                Text(targetDescription(planned)).font(.caption).foregroundStyle(.indigo)
            }
            ForEach(workout.components) { component in
                HStack {
                    Text("\(component.position+1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Text(componentDescription(component)).font(.body.monospacedDigit())
                    Spacer()
                    if component.status == .partial { Text("Partial").fitnessPill(.orange) }
                    Button("Edit") { onEditSet(workout.group, component) }
                        .buttonStyle(.borderless)
                }
            }
            if workout.group.status == .planned {
                Button("Log planned set") { onAddSet(workout.group) }.buttonStyle(.borderedProminent)
            }
            DisclosureGroup("More set options") {
                if workout.group.status != .planned {
                    Button("Add drop / rest-pause / cluster") { onAddComponent(workout.group) }
                }
                if workout.group.status != .skipped {
                    Button("Skip set",role: .destructive) { onSkip(workout.group) }
                }
            }
            .font(.caption)
        }
        .padding(10).background(.secondary.opacity(0.08),in: RoundedRectangle(cornerRadius: 10))
    }

    private func targetDescription(_ value: FitnessPlannedStrengthSet) -> String {
        var parts:[String]=[]
        if let min=value.repsMin { parts.append(value.repsMax == min ? "\(min) reps" : "\(min)–\(value.repsMax ?? min) reps") }
        if let min=value.loadMin { parts.append(value.loadMax == min ? "\(min.formatted()) \(value.loadUnit ?? "kg")" : "\(min.formatted())–\((value.loadMax ?? min).formatted()) \(value.loadUnit ?? "kg")") }
        if let rir=value.rirMax { parts.append("RIR ≤\(rir.formatted())") }
        if let rest=value.restSeconds { parts.append("rest \(rest)s") }
        return parts.isEmpty ? "Planned \(value.role.title.lowercased()) set" : parts.joined(separator: " · ")
    }

    private func comparableDescription(_ value: FitnessComparableSet) -> String {
        guard let component=value.components.first(where: FitnessCalculations.isPerformed) else { return "No performed component" }
        return "\(componentDescription(component)) · \(value.performedAt.formatted(date: .abbreviated,time: .omitted))"
    }

    private func componentDescription(_ value: FitnessSetComponent) -> String {
        if value.status == .skipped { return "Skipped" }
        var parts:[String]=[]
        if let load=value.loadValue { parts.append("\(load.formatted(.number.precision(.fractionLength(0...1)))) \(value.loadUnit ?? "kg")") }
        if let reps=value.reps { parts.append("× \(reps)") }
        else if value.repsLeft != nil || value.repsRight != nil { parts.append("L \(value.repsLeft.map(String.init) ?? "—") / R \(value.repsRight.map(String.init) ?? "—")") }
        if let duration=value.durationSeconds { parts.append("\(duration)s") }
        if let rir=value.rir { parts.append("RIR \(rir.formatted())") }
        else if let rpe=value.rpe { parts.append("RPE \(rpe.formatted())") }
        if let bodyweight=value.bodyweightKgSnapshot { parts.append("BW \(bodyweight.formatted()) kg") }
        return parts.isEmpty ? "Recorded work" : parts.joined(separator: " · ")
    }

    private func loadLabel(_ raw: String) -> String {
        FitnessStrengthSemantics.loadLabel(FitnessRepositoryLoadMode.local(raw))
    }
}

private enum FitnessRepositoryLoadMode {
    static func local(_ raw: String) -> FitnessLoadMode {
        switch raw {
        case "per_hand": .each
        case "per_side": .perSide
        case "machine_stack": .machine
        case "machine_level": .level
        case "bodyweight_only": .bodyweight
        case "added_bodyweight": .added
        case "assistance": .assistance
        default: .total
        }
    }
}

private struct FitnessStrengthStartSheet: View {
    @ObservedObject var viewModel: FitnessStrengthViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var title="Strength workout"
    @State private var sourceId="blank"
    @State private var readiness=3
    @State private var includeReadiness=true
    @State private var showingDetails=false
    @State private var energy=3
    @State private var soreness=3
    @State private var motivation=3

    init(viewModel: FitnessStrengthViewModel,initialSourceId: String = "blank") {
        self.viewModel=viewModel
        _sourceId=State(initialValue: initialSourceId)
        let initialTitle: String
        if initialSourceId.hasPrefix("plan:"),
           let plan=viewModel.plans.first(where: { $0.id == String(initialSourceId.dropFirst(5)) }) {
            initialTitle=plan.title
        } else if initialSourceId.hasPrefix("saved:"),
                  let workout=viewModel.savedWorkouts.first(where: { $0.versionId == String(initialSourceId.dropFirst(6)) }) {
            initialTitle=workout.title
        } else if initialSourceId.hasPrefix("previous:"),
                  let session=viewModel.recentSessions.first(where: { $0.id == String(initialSourceId.dropFirst(9)) }) {
            initialTitle=session.title
        } else {
            initialTitle="Strength workout"
        }
        _title=State(initialValue: initialTitle)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Workout") {
                    Picker("Start from",selection: $sourceId) {
                        Text("Blank workout").tag("blank")
                        Section("Accepted plans") {
                            ForEach(viewModel.plans.filter(\.isStartable)) { plan in
                                Text(plan.title).tag("plan:\(plan.id)")
                            }
                        }
                        Section("Saved workouts") {
                            ForEach(viewModel.savedWorkouts) { workout in
                                Text(workout.name).tag("saved:\(workout.versionId)")
                            }
                        }
                        Section("Copy previous") {
                            ForEach(viewModel.recentSessions) { session in
                                Text("\(session.title) · \(session.startedAt.formatted(date: .abbreviated,time: .omitted))")
                                    .tag("previous:\(session.id)")
                            }
                        }
                    }
                    TextField("Title",text: $title)
                    if !viewModel.plans.filter({ !$0.isCompleted && !$0.isStartable }).isEmpty {
                        Text("Proposed plans are review-only until accepted or scheduled.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Readiness") {
                    Toggle("Record readiness",isOn: $includeReadiness)
                    if includeReadiness {
                        Picker("Ready",selection: $readiness) {
                            ForEach(1...5,id: \.self) { Text("\($0)").tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                    DisclosureGroup("Optional detail",isExpanded: $showingDetails) {
                        Stepper("Energy \(energy)/5",value: $energy,in: 1...5)
                        Stepper("Soreness \(soreness)/5",value: $soreness,in: 1...5)
                        Stepper("Motivation \(motivation)/5",value: $motivation,in: 1...5)
                    }
                }
            }
            .navigationTitle("Start workout")
            .onChange(of: sourceId) { _,newValue in
                if let plan=selectedPlan { title=plan.title }
                else if let workout=selectedSaved { title=workout.title }
                else if let previous=selectedPrevious { title=previous.title }
                else if newValue == "blank" { title="Strength workout" }
            }
            .onAppear { updateTitle(for: sourceId) }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") {
                        Task {
                            let ready=includeReadiness ? readiness : nil
                            let energyValue=showingDetails ? energy : nil
                            let sorenessValue=showingDetails ? soreness : nil
                            let motivationValue=showingDetails ? motivation : nil
                            let succeeded: Bool
                            if let saved=selectedSaved {
                                succeeded=await viewModel.start(
                                    savedWorkout: saved,readiness: ready,energy: energyValue,
                                    soreness: sorenessValue,motivation: motivationValue,bodyweight: bodyweight
                                )
                            } else if let previous=selectedPrevious {
                                succeeded=await viewModel.start(
                                    previousSession: previous,readiness: ready,energy: energyValue,
                                    soreness: sorenessValue,motivation: motivationValue,bodyweight: bodyweight
                                )
                            } else {
                                succeeded=await viewModel.start(
                                    title: selectedPlan?.title ?? title,plan: selectedPlan,
                                    readiness: ready,energy: energyValue,soreness: sorenessValue,
                                    motivation: motivationValue,bodyweight: bodyweight
                                )
                            }
                            if succeeded { dismiss() }
                        }
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private var selectedPlan: FitnessPlannedSession? {
        guard sourceId.hasPrefix("plan:") else { return nil }
        return viewModel.plans.first { $0.id == String(sourceId.dropFirst(5)) }
    }
    private var selectedSaved: FitnessSavedStrengthWorkout? {
        guard sourceId.hasPrefix("saved:") else { return nil }
        return viewModel.savedWorkouts.first { $0.versionId == String(sourceId.dropFirst(6)) }
    }
    private var selectedPrevious: FitnessStrengthSession? {
        guard sourceId.hasPrefix("previous:") else { return nil }
        return viewModel.recentSessions.first { $0.id == String(sourceId.dropFirst(9)) }
    }

    private func updateTitle(for sourceId: String) {
        if let plan=selectedPlan { title=plan.title }
        else if let workout=selectedSaved { title=workout.title }
        else if let previous=selectedPrevious { title=previous.title }
        else if sourceId == "blank" { title="Strength workout" }
    }

    private var bodyweight: FitnessBodyweightChoice {
        guard let latest=viewModel.latestBodyweight else { return .unknown }
        return .init(kilograms: latest.weightKg,source: .recentCanonical)
    }
}

private struct FitnessStrengthExercisePicker: View {
    @ObservedObject var viewModel: FitnessStrengthViewModel
    let substitutionTarget: FitnessSessionExercise?
    @Environment(\.dismiss) private var dismiss
    @State private var query=""
    @State private var showingCreate=false

    var body: some View {
        NavigationStack {
            List {
                let added=Set(viewModel.workoutExercises.map { $0.exercise.exerciseId })
                let plannedIds=viewModel.plannedExercises.map(\.exerciseId).filter { !added.contains($0) }
                let substitutions=plannedSubstitutionIds
                if substitutionTarget != nil {
                    if substitutions.isEmpty {
                        Section {
                            Text("This plan did not name alternatives. Choose from your library if you deliberately need a change.")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Section("Planned substitutions") { exerciseButtons(ids: substitutions) }
                        Section {
                            Text("This plan limits substitutions to the reviewed alternatives above.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if substitutions.isEmpty {
                        Section("Library options") {
                            if filtered.isEmpty { Text("No matching exercise.").foregroundStyle(.secondary) }
                            ForEach(filtered) { exercise in button(exercise) }
                        }
                    }
                } else {
                    if !plannedIds.isEmpty {
                        Section("Planned") { exerciseButtons(ids: plannedIds) }
                    }
                    Section("Favourites") {
                        ForEach(filtered.filter(\.isFavourite)) { exercise in button(exercise) }
                    }
                    Section("Recent and catalogue") {
                        if filtered.isEmpty { Text("No matching exercise.").foregroundStyle(.secondary) }
                        ForEach(filtered.filter { !$0.isFavourite }) { exercise in button(exercise) }
                    }
                }
                Section { Button("Create exercise",systemImage: "plus") { showingCreate=true } }
            }
            .searchable(text: $query,prompt: "Exercise or alias")
            .navigationTitle(substitutionTarget == nil ? "Add exercise" : "Choose substitute")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $showingCreate) { FitnessCreateExerciseSheet(viewModel: viewModel) }
        }
    }

    @ViewBuilder private func exerciseButtons(ids: [String]) -> some View {
        ForEach(viewModel.exercises.filter { ids.contains($0.id) }) { exercise in button(exercise) }
    }

    private var filtered: [FitnessExercise] {
        let available=viewModel.exercises.filter { $0.id != substitutionTarget?.exerciseId }
        guard !query.isEmpty else { return available }
        return available.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.aliases.contains(where: { $0.localizedCaseInsensitiveContains(query) })
        }
    }

    private var plannedSubstitutionIds: [String] {
        guard let substitutionTarget else { return [] }
        return viewModel.plannedSubstitutionIds(for: substitutionTarget)
    }

    private func button(_ exercise: FitnessExercise) -> some View {
        Button {
            Task {
                let ok = if let substitutionTarget {
                    await viewModel.substitute(substitutionTarget,with: exercise)
                } else {
                    await viewModel.addExercise(exercise)
                }
                if ok { dismiss() }
            }
        } label: {
            VStack(alignment: .leading,spacing: 2) {
                Text(exercise.name).foregroundStyle(.primary)
                Text("\(exercise.movementPatternKey.replacingOccurrences(of: "_",with: " ")) · \(exercise.loadEntryMode.replacingOccurrences(of: "_",with: " "))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct FitnessCreateExerciseSheet: View {
    @ObservedObject var viewModel: FitnessStrengthViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var name=""
    @State private var category="Strength"
    @State private var mode=FitnessLoadMode.total
    var body: some View {
        NavigationStack {
            Form {
                TextField("Name",text: $name)
                TextField("Category",text: $category)
                Picker("Load entry",selection: $mode) {
                    ForEach(FitnessLoadMode.allCases) { Text(FitnessStrengthSemantics.loadLabel($0)).tag($0) }
                }
            }
            .navigationTitle("New exercise")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { Task { if await viewModel.createAndOptionallyAdd(name: name,category: category,mode: mode) { dismiss() } } }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

private enum FitnessStrengthMergeKind: String,CaseIterable,Identifiable {
    case exercise="Exercises"
    case setup="Setups"
    var id: String { rawValue }
}

private struct FitnessStrengthMergeSheet: View {
    @ObservedObject var viewModel: FitnessStrengthViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var kind=FitnessStrengthMergeKind.exercise
    @State private var sourceExerciseId=""
    @State private var targetExerciseId=""
    @State private var exercisePreview: FitnessExerciseMergePreview?
    @State private var setupExerciseId=""
    @State private var sourceSetupId=""
    @State private var targetSetupId=""
    @State private var setupPreview: FitnessExerciseSetupMergePreview?
    @State private var busy=false

    private var activeExercises: [FitnessExercise] {
        viewModel.exercises.filter { $0.active && $0.mergedIntoExerciseId == nil }
    }

    private var selectedSetups: [FitnessExerciseSetup] {
        viewModel.setups[setupExerciseId,default: []].filter { $0.active && $0.mergedIntoSetupId == nil }
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("Merge type",selection: $kind) {
                    ForEach(FitnessStrengthMergeKind.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                if kind == .exercise { exerciseMergeForm }
                else { setupMergeForm }

                Section {
                    Label(
                        "Merges need a connection because existing plans and history must all point to the record you keep.",
                        systemImage: "network"
                    )
                    .font(.caption).foregroundStyle(.secondary)
                    if let error=viewModel.errorMessage {
                        Label(error,systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Merge duplicates")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
            .task {
                if setupExerciseId.isEmpty,let first=activeExercises.first {
                    setupExerciseId=first.id
                    await viewModel.loadSetups(for: first.id)
                }
            }
            .onChange(of: setupExerciseId) { _,exerciseId in
                sourceSetupId=""; targetSetupId=""; setupPreview=nil
                guard !exerciseId.isEmpty else { return }
                Task { await viewModel.loadSetups(for: exerciseId) }
            }
            .onChange(of: sourceExerciseId) { _,_ in exercisePreview=nil }
            .onChange(of: targetExerciseId) { _,_ in exercisePreview=nil }
            .onChange(of: sourceSetupId) { _,_ in setupPreview=nil }
            .onChange(of: targetSetupId) { _,_ in setupPreview=nil }
        }
    }

    private var exerciseMergeForm: some View {
        Group {
            Section("Duplicate to replace") {
                Picker("Source exercise",selection: $sourceExerciseId) {
                    Text("Choose exercise").tag("")
                    ForEach(activeExercises) { Text($0.name).tag($0.id) }
                }
                Picker("Exercise to keep",selection: $targetExerciseId) {
                    Text("Choose exercise to keep").tag("")
                    ForEach(activeExercises.filter { $0.id != sourceExerciseId }) {
                        Text($0.name).tag($0.id)
                    }
                }
                if let preview=exercisePreview {
                    mergeStatus(alreadyMerged: preview.alreadyMerged)
                    LabeledContent("Planned exercises",value: "\(preview.plannedExercises)")
                    LabeledContent("Logged exercises",value: "\(preview.sessionExercises)")
                    LabeledContent("Setups moved",value: "\(preview.movedSetups)")
                    Button("Confirm exercise merge",role: .destructive) {
                        Task {
                            busy=true
                            if await viewModel.mergeExercises(preview) { dismiss() }
                            busy=false
                        }
                    }
                    .disabled(preview.alreadyMerged || busy)
                    Button("Cancel preview") { exercisePreview=nil }
                } else {
                    Button("Preview what changes") {
                        Task {
                            busy=true
                            exercisePreview=await viewModel.previewExerciseMerge(
                                sourceId: sourceExerciseId,targetId: targetExerciseId
                            )
                            busy=false
                        }
                    }
                    .disabled(sourceExerciseId.isEmpty || targetExerciseId.isEmpty || busy)
                }
            }
        }
    }

    private var setupMergeForm: some View {
        Group {
            Section("Exercise") {
                Picker("Exercise",selection: $setupExerciseId) {
                    Text("Choose exercise").tag("")
                    ForEach(activeExercises) { Text($0.name).tag($0.id) }
                }
            }
            Section("Duplicate setup to replace") {
                if selectedSetups.count < 2 {
                    Text("This exercise needs at least two active setups before they can be merged.")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Source setup",selection: $sourceSetupId) {
                        Text("Choose setup").tag("")
                        ForEach(selectedSetups) { Text($0.name).tag($0.id) }
                    }
                    Picker("Setup to keep",selection: $targetSetupId) {
                        Text("Choose setup to keep").tag("")
                        ForEach(selectedSetups.filter { $0.id != sourceSetupId }) {
                            Text($0.name).tag($0.id)
                        }
                    }
                    if let preview=setupPreview {
                        mergeStatus(alreadyMerged: preview.alreadyMerged)
                        LabeledContent("Planned exercises",value: "\(preview.plannedExercises)")
                        LabeledContent("Logged exercises",value: "\(preview.sessionExercises)")
                        Button("Confirm setup merge",role: .destructive) {
                            Task {
                                busy=true
                                if await viewModel.mergeSetups(preview,exerciseId: setupExerciseId) {
                                    sourceSetupId=""; targetSetupId=""; setupPreview=nil
                                }
                                busy=false
                            }
                        }
                        .disabled(preview.alreadyMerged || busy)
                        Button("Cancel preview") { setupPreview=nil }
                    } else {
                        Button("Preview what changes") {
                            Task {
                                busy=true
                                setupPreview=await viewModel.previewSetupMerge(
                                    sourceId: sourceSetupId,targetId: targetSetupId
                                )
                                busy=false
                            }
                        }
                        .disabled(sourceSetupId.isEmpty || targetSetupId.isEmpty || busy)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func mergeStatus(alreadyMerged: Bool) -> some View {
        Label(
            alreadyMerged ? "These already point to the same saved record." : "Review what will change, then confirm once.",
            systemImage: alreadyMerged ? "checkmark.circle" : "arrow.triangle.merge"
        )
        .font(.subheadline).foregroundStyle(alreadyMerged ? Color.secondary : Color.orange)
    }
}

private struct FitnessStrengthSetContext: Identifiable {
    let exercise: FitnessSessionExercise
    let group: FitnessSetGroup?
    let target: FitnessPlannedStrengthSet?
    let component: FitnessSetComponent?
    var id: String { component?.id ?? group?.id ?? "new-\(exercise.id)" }
}

private struct FitnessStrengthSetSheet: View {
    let context: FitnessStrengthSetContext
    @ObservedObject var viewModel: FitnessStrengthViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: FitnessStrengthSetDraft
    @State private var setStartedAt: Date?
    @State private var saving=false

    init(context: FitnessStrengthSetContext,viewModel: FitnessStrengthViewModel) {
        self.context=context; self.viewModel=viewModel
        var value=FitnessStrengthSetDraft()
        if let group=context.group {
            value.plannedSetId=group.plannedSetId; value.role=group.role
            value.structure=group.structure; value.isAMRAP=group.isAMRAP
        }
        if let target=context.target {
            value.reps=target.repsMin == target.repsMax ? target.repsMin : target.repsMin
            value.loadValue=target.loadMin == target.loadMax ? target.loadMin : target.loadMin
            value.loadUnit=target.loadUnit ?? "kg"
            value.rir=target.rirMax; value.rpe=target.rpeMax
            value.restBeforeSeconds=target.restSeconds
        }
        if let component=context.component {
            value.reps=component.reps; value.repsLeft=component.repsLeft
            value.repsRight=component.repsRight; value.loadValue=component.loadValue
            value.loadUnit=component.loadUnit ?? "kg"; value.durationSeconds=component.durationSeconds
            value.distanceMetres=component.distanceMetres; value.rir=component.rir; value.rpe=component.rpe
            value.restBeforeSeconds=component.restBeforeSeconds; value.tempoText=component.tempoText
            value.notes=component.notes; value.componentStatus=component.status
        }
        _draft=State(initialValue: value)
        _setStartedAt=State(initialValue: nil)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Exercise", value: context.exercise.exerciseName)
                    if mode != .bodyweight {
                        TextField("Weight (\(FitnessStrengthSemantics.loadLabel(mode)))", value: $draft.loadValue, format: .number)
                            .keyboardType(.decimalPad)
                            .font(.title2.weight(.semibold))
                            .disabled(setStartedAt != nil)
                    }
                    if context.exercise.repCountModeSnapshot == "left_right_separate" {
                        HStack {
                            TextField("Left reps", value: $draft.repsLeft, format: .number).keyboardType(.numberPad)
                            TextField("Right reps", value: $draft.repsRight, format: .number).keyboardType(.numberPad)
                        }
                        .disabled(setStartedAt != nil)
                    } else {
                        TextField(
                            context.exercise.repCountModeSnapshot == "per_side" ? "Reps per side" : "Repetitions",
                            value: $draft.reps, format: .number
                        )
                        .keyboardType(.numberPad)
                        .font(.title2.weight(.semibold))
                        .disabled(setStartedAt != nil)
                    }
                }
                if context.component == nil {
                    Section {
                        TimelineView(.periodic(from: .now, by: 1)) { timeline in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(setStartedAt == nil ? "Ready" : "Set running")
                                        .font(.caption).foregroundStyle(.secondary)
                                    Text(setClock(at: timeline.date))
                                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                                        .monospacedDigit()
                                }
                                Spacer()
                                Button(setStartedAt == nil ? "Start" : "Stop", systemImage: setStartedAt == nil ? "play.fill" : "stop.fill") {
                                    if setStartedAt == nil {
                                        setStartedAt=Date(); HapticManager.selection()
                                    } else {
                                        Task { await stopAndSave() }
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(setStartedAt == nil ? .indigo : .red)
                                .controlSize(.large)
                                .disabled(saving)
                            }
                        }
                    }
                }
                Section {
                    Button {
                        draft.failureState = draft.failureState == .muscular ? .none : .muscular
                        HapticManager.selection()
                    } label: {
                        Label(
                            draft.failureState == .muscular ? "Failure recorded" : "Record failure",
                            systemImage: draft.failureState == .muscular ? "flag.checkered.circle.fill" : "flag.checkered"
                        )
                        .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .tint(draft.failureState == .muscular ? .orange : .secondary)
                    .disabled(setStartedAt != nil)
                }
                Section {
                    DisclosureGroup("More set details") {
                        Picker("Role",selection: $draft.role) { ForEach(FitnessSetRole.allCases) { Text($0.title).tag($0) } }
                        Picker("Structure",selection: $draft.structure) { ForEach(FitnessSetStructure.allCases) { Text($0.title).tag($0) } }
                        HStack {
                            TextField("RIR",value: $draft.rir,format: .number).keyboardType(.decimalPad)
                            TextField("RPE",value: $draft.rpe,format: .number).keyboardType(.decimalPad)
                        }
                        TextField("Rest target (seconds)",value: $draft.restBeforeSeconds,format: .number).keyboardType(.numberPad)
                        TextField("Notes",text: optional($draft.notes),axis: .vertical)
                    }
                }
            }
                .navigationTitle(context.component == nil ? "Log set" : "Edit set")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    if context.component != nil {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Save") { Task { await saveEdit() } }.disabled(saving)
                        }
                    }
                }
        }
    }

    private var mode: FitnessLoadMode {
        FitnessRepositoryLoadMode.local(context.exercise.setupLoadModeSnapshot)
    }

    private func setClock(at now: Date) -> String {
        guard let setStartedAt else { return "0:00" }
        let seconds=max(0,Int(now.timeIntervalSince(setStartedAt)))
        return String(format: "%d:%02d",seconds/60,seconds%60)
    }

    @MainActor
    private func stopAndSave() async {
        guard let started=setStartedAt else { return }
        saving=true
        let stopped=Date()
        draft.startedAt=started; draft.completedAt=stopped
        if draft.durationSeconds == nil {
            draft.durationSeconds=max(0,Int(stopped.timeIntervalSince(started)))
        }
        if await viewModel.saveSet(to: context.exercise,draft: draft) {
            await viewModel.startRest(seconds: draft.restBeforeSeconds ?? 120)
            dismiss()
        }
        saving=false
    }

    @MainActor
    private func saveEdit() async {
        guard let group=context.group,let component=context.component else { return }
        saving=true
        if await viewModel.updateSet(group: group,component: component,draft: draft) { dismiss() }
        saving=false
    }
}

private struct FitnessStrengthComponentSheet: View {
    let group: FitnessSetGroup
    @ObservedObject var viewModel: FitnessStrengthViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var structure: FitnessSetStructure
    @State private var draft=FitnessStrengthSetDraft()

    init(group: FitnessSetGroup,viewModel: FitnessStrengthViewModel) {
        self.group=group; self.viewModel=viewModel
        _structure=State(initialValue: group.structure == .straight ? .drop : group.structure)
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("Component type",selection: $structure) {
                    ForEach([FitnessSetStructure.drop,.restPause,.cluster]) { Text($0.title).tag($0) }
                }
                componentFields
            }
            .navigationTitle("Add component")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            draft.structure=structure
                            if await viewModel.addComponent(to: group,structure: structure,draft: draft) { dismiss() }
                        }
                    }
                }
            }
        }
    }

    private var componentFields: some View {
        Group {
            TextField("Load",value: $draft.loadValue,format: .number).keyboardType(.decimalPad)
            TextField("Repetitions",value: $draft.reps,format: .number).keyboardType(.numberPad)
            TextField("RIR",value: $draft.rir,format: .number).keyboardType(.decimalPad)
            TextField("RPE",value: $draft.rpe,format: .number).keyboardType(.decimalPad)
            TextField("Rest before (seconds)",value: $draft.restBeforeSeconds,format: .number).keyboardType(.numberPad)
            TextField("Tempo",text: optional($draft.tempoText))
            TextField("Notes",text: optional($draft.notes),axis: .vertical)
        }
    }
}

private struct FitnessStrengthSetFields: View {
    let exercise: FitnessSessionExercise
    @Binding var draft: FitnessStrengthSetDraft
    let allowsStructure: Bool

    private var mode: FitnessLoadMode { FitnessRepositoryLoadMode.local(exercise.setupLoadModeSnapshot) }

    var body: some View {
        Form {
            Section {
                LabeledContent("Exercise",value: exercise.exerciseName)
                LabeledContent("Setup",value: exercise.setupName)
                LabeledContent("Load entry",value: FitnessStrengthSemantics.loadLabel(mode))
            }
            Section("Set") {
                Picker("Role",selection: $draft.role) { ForEach(FitnessSetRole.allCases) { Text($0.title).tag($0) } }
                if allowsStructure {
                    Picker("Structure",selection: $draft.structure) { ForEach(FitnessSetStructure.allCases) { Text($0.title).tag($0) } }
                }
                Picker("Status",selection: $draft.groupStatus) {
                    ForEach([FitnessSetStatus.completed,.partial,.skipped]) { Text($0.title).tag($0) }
                }
                Toggle("AMRAP instruction",isOn: $draft.isAMRAP)
                Picker("What ended the effort",selection: $draft.failureState) {
                    ForEach(FitnessFailureType.allCases) { Text($0.title).tag($0) }
                }
            }
            Section("Performed work") {
                if mode != .bodyweight {
                    TextField(FitnessStrengthSemantics.loadLabel(mode),value: $draft.loadValue,format: .number)
                        .keyboardType(.decimalPad).font(.title3)
                }
                if exercise.repCountModeSnapshot == "left_right_separate" {
                    HStack {
                        TextField("Left reps",value: $draft.repsLeft,format: .number).keyboardType(.numberPad)
                        TextField("Right reps",value: $draft.repsRight,format: .number).keyboardType(.numberPad)
                    }
                } else {
                    TextField(exercise.repCountModeSnapshot == "per_side" ? "Reps per side" : "Repetitions",value: $draft.reps,format: .number)
                        .keyboardType(.numberPad).font(.title3)
                }
                TextField("Duration (seconds)",value: $draft.durationSeconds,format: .number).keyboardType(.numberPad)
                TextField("Distance (metres)",value: $draft.distanceMetres,format: .number).keyboardType(.decimalPad)
            }
            Section("Effort and detail") {
                HStack {
                    TextField("RIR",value: $draft.rir,format: .number).keyboardType(.decimalPad)
                    TextField("RPE",value: $draft.rpe,format: .number).keyboardType(.decimalPad)
                }
                TextField("Rest before (seconds)",value: $draft.restBeforeSeconds,format: .number).keyboardType(.numberPad)
                TextField("Tempo",text: optional($draft.tempoText))
                TextField("Notes",text: optional($draft.notes),axis: .vertical)
            }
        }
    }
}

private struct FitnessStrengthSetupSheet: View {
    let exercise: FitnessSessionExercise
    @ObservedObject var viewModel: FitnessStrengthViewModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                ForEach(viewModel.setups[exercise.exerciseId] ?? []) { setup in
                    Button {
                        Task { if await viewModel.changeSetup(for: exercise,to: setup) { dismiss() } }
                    } label: {
                        VStack(alignment: .leading,spacing: 2) {
                            Text(setup.name).foregroundStyle(.primary)
                            Text(FitnessStrengthSemantics.loadLabel(setup.loadMode)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Exercise setup")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .task { await viewModel.loadSetups(for: exercise.exerciseId) }
        }
    }
}

private struct FitnessStrengthFinishSheet: View {
    @ObservedObject var viewModel: FitnessStrengthViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var rpe: Double?
    @State private var performance=3
    @State private var matchedPlan="changed"
    @State private var note=""
    @State private var addIssue=false
    @State private var issue=NewBodyIssue(
        issueTypeKey: "discomfort",bodyLocationKey: "",side: "not_applicable",severity: 3,
        timing: "during",changedSession: false,sessionChangeKey: "none",note: nil
    )

    var body: some View {
        NavigationStack {
            Form {
                Section("Session") {
                    TextField("Session RPE",value: $rpe,format: .number).keyboardType(.decimalPad)
                    Stepper("Performance \(performance)/5",value: $performance,in: 1...5)
                    Picker("Plan",selection: $matchedPlan) {
                        Text("Matched plan").tag("matched")
                        Text("Changed plan").tag("changed")
                        Text("No plan").tag("not_planned")
                    }
                    TextField("Note",text: $note,axis: .vertical)
                }
                Section {
                    Toggle("Pain, tightness, or another issue occurred",isOn: $addIssue)
                    if addIssue { StrengthBodyIssueEditor(issue: $issue,locations: viewModel.bodyLocations) }
                }
                Section {
                    Text("HausKlar records training and reminders only; it does not provide medical advice.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Finish workout")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Finish") {
                        Task {
                            if await viewModel.finish(
                                rpe: rpe,performance: performance,matchedPlanKey: matchedPlan,
                                note: note,issue: addIssue ? issue : nil
                            ) { dismiss() }
                        }
                    }
                    .disabled(addIssue && issue.bodyLocationKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

private struct StrengthBodyIssueEditor: View {
    @Binding var issue: NewBodyIssue
    let locations: [FitnessBodyLocation]
    var body: some View {
        Picker("Type",selection: $issue.issueTypeKey) {
            ForEach(FitnessBodyIssueType.allCases) { Text($0.rawValue.capitalized).tag($0.rawValue) }
        }
        Picker("Body location",selection: $issue.bodyLocationKey) {
            Text("Choose…").tag("")
            ForEach(locations.filter(\.active)) { location in
                Text(location.displayName).tag(location.locationKey)
            }
            if !issue.bodyLocationKey.isEmpty && !locations.contains(where: { $0.locationKey == issue.bodyLocationKey }) {
                Text(FitnessBodyLocation.label(for: issue.bodyLocationKey,locations: locations)).tag(issue.bodyLocationKey)
            }
        }
        Picker("Side",selection: $issue.side) {
            ForEach(FitnessBodyIssueSide.allCases) { Text($0.rawValue.replacingOccurrences(of: "_",with: " ").capitalized).tag($0.rawValue) }
        }
        Stepper("Severity \(issue.severity)/10",value: $issue.severity,in: 0...10)
        Toggle("Changed the session",isOn: $issue.changedSession)
        if issue.changedSession {
            Picker("Change",selection: $issue.sessionChangeKey) {
                ForEach(FitnessBodyIssueSessionChange.allCases.filter { $0 != .none }) {
                    Text($0.rawValue.replacingOccurrences(of: "_",with: " ").capitalized).tag($0.rawValue)
                }
            }
        }
        TextField("Issue note",text: optional($issue.note),axis: .vertical)
    }
}

private func optional(_ binding: Binding<String?>) -> Binding<String> {
    Binding(get: { binding.wrappedValue ?? "" },set: { binding.wrappedValue=$0.isEmpty ? nil : $0 })
}

private extension View {
    func fitnessPill(_ color: Color) -> some View {
        self.font(.caption2.bold()).foregroundStyle(color)
            .padding(.horizontal,6).padding(.vertical,2)
            .background(color.opacity(0.12),in: Capsule())
    }
}
