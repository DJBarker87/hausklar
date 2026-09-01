import SwiftUI

struct CommitmentReviewView: View {
    @ObservedObject var viewModel: CommitmentsViewModel

    @EnvironmentObject private var networkMonitor: NetworkMonitor
    @State private var showingDecline = false
    @State private var declineReason = ""

    var body: some View {
        if let value = viewModel.draft {
            Form {
                Section {
                    Button {
                        viewModel.closeReview()
                    } label: {
                        Label("All plans", systemImage: "chevron.left")
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.busyAction != nil)
                }

                planHeader(value)
                changeSummarySection
                reviewIssuesSection
                feedbackSection
                basicsSection
                eventsSection
                tasksSection
                preparationsSection
                externalActionSection
                actionsSection
            }
            .accessibilityIdentifier("commitmentReview")
        }
    }

    @ViewBuilder
    private var changeSummarySection: some View {
        if let value = viewModel.draft, !value.updateReviewItems.isEmpty {
            Section {
                ForEach(value.updateReviewItems, id: \.self) { change in
                    Label(change, systemImage: "arrow.triangle.2.circlepath")
                        .foregroundStyle(.primary)
                }
            } header: {
                Text("What changed")
            } footer: {
                Text("This plan updates an earlier open plan. Check these differences before confirming.")
            }
            .accessibilityIdentifier("commitmentChangeSummary")
        }
    }

    private var draft: Binding<Commitment> {
        Binding(
            get: { viewModel.draft! },
            set: { viewModel.draft = $0 }
        )
    }

    private func planHeader(_ value: Commitment) -> some View {
        Section {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: value.kind.symbol)
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: 44, height: 44)
                    .background(Color.accentColor.opacity(0.1), in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(value.kind.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(value.title)
                        .font(.title3.weight(.semibold))
                    Text(statusText(value))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        } footer: {
            Text("Review everything here. HausKlar creates Calendar and Task items only after confirmation.")
        }
    }

    @ViewBuilder
    private var reviewIssuesSection: some View {
        if !viewModel.reviewIssues.isEmpty {
            Section {
                ForEach(viewModel.reviewIssues, id: \.self) { issue in
                    Label(issue, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                if viewModel.isDirty {
                    Text("Save your edits to refresh these checks.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Check before confirming")
            }
        }
    }

    @ViewBuilder
    private var feedbackSection: some View {
        if let notice = viewModel.notice {
            Section {
                Label(notice, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
        if let error = viewModel.errorMessage {
            Section {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                if viewModel.conflictNeedsReload {
                    Button("Reload current plan") {
                        Task {
                            await viewModel.reloadSelectedDiscardingEdits(
                                online: networkMonitor.isConnected
                            )
                        }
                    }
                    .disabled(viewModel.busyAction != nil || !networkMonitor.isConnected)
                }
            }
        }
    }

    private var basicsSection: some View {
        Section {
            TextField("Title", text: draft.title, axis: .vertical)
                .accessibilityIdentifier("commitmentTitle")

            Picker("Who can see it?", selection: draft.visibility) {
                ForEach(CommitmentVisibility.allCases) { visibility in
                    Text(visibility.title).tag(visibility)
                }
            }
            .disabled(!viewModel.mayChangeVisibility)
            .accessibilityIdentifier("commitmentVisibility")

            if !viewModel.mayChangeVisibility {
                Text("Only the plan owner can change its visibility.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if draft.wrappedValue.kind == .travel {
                TextField(
                    "Trip group or reference",
                    text: optionalText(draft.groupKey)
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("commitmentTravelGroup")
            }

            TextField(
                "Summary (optional)",
                text: optionalText(draft.summary),
                axis: .vertical
            )
            .lineLimit(3...8)
            .accessibilityIdentifier("commitmentSummary")

            DisclosureGroup("Sources and references (\(draft.wrappedValue.sources.count))") {
                ForEach(draft.wrappedValue.sources) { source in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(source.label ?? (source.kind == .document ? "Document" : "Source"))
                            .font(.subheadline.weight(.semibold))
                        if let reference = source.providerReference {
                            Text(reference)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 3)
                }
            }
        } header: {
            Text("Plan basics")
        } footer: {
            Text(draft.wrappedValue.kind == .travel
                ? "Keep every journey, connection and stay under one trip reference."
                : "Keep the summary short enough to scan later.")
        }
    }

    private var eventsSection: some View {
        Section {
            if draft.wrappedValue.plan.events.isEmpty {
                Text("No event yet. Add only a date HausKlar genuinely needs.")
                    .foregroundStyle(.secondary)
            }
            ForEach(draft.plan.events) { event in
                CommitmentEventEditor(
                    event: event,
                    members: viewModel.members,
                    onRemove: { viewModel.removeEvent(id: event.wrappedValue.id) }
                )
            }
            Button {
                viewModel.addEvent()
                HapticManager.selection()
            } label: {
                Label("Add event", systemImage: "plus")
                    .frame(minHeight: 44)
            }
            .accessibilityIdentifier("commitmentAddEvent")
        } header: {
            Text("Events")
        } footer: {
            Text(draft.wrappedValue.kind == .travel
                ? "Add each journey, connection or stay."
                : "These dates reach the family calendar only after confirmation.")
        }
    }

    private var tasksSection: some View {
        Section {
            if draft.wrappedValue.plan.tasks.isEmpty {
                Text("No separate tasks.")
                    .foregroundStyle(.secondary)
            }
            ForEach(draft.plan.tasks) { task in
                CommitmentTaskEditor(
                    task: task,
                    members: viewModel.members,
                    onRemove: { viewModel.removeTask(id: task.wrappedValue.id) }
                )
            }
            Button {
                viewModel.addTask()
                HapticManager.selection()
            } label: {
                Label("Add task", systemImage: "plus")
                    .frame(minHeight: 44)
            }
            .accessibilityIdentifier("commitmentAddTask")
        } header: {
            Text("Tasks")
        } footer: {
            Text("Actions that need doing, separate from what needs packing.")
        }
    }

    private var preparationsSection: some View {
        Section {
            if draft.wrappedValue.plan.preparations.isEmpty {
                Text("No preparation items.")
                    .foregroundStyle(.secondary)
            }
            ForEach(draft.plan.preparations) { preparation in
                CommitmentPreparationEditor(
                    preparation: preparation,
                    events: draft.wrappedValue.plan.events,
                    members: viewModel.members,
                    onRemove: {
                        viewModel.removePreparation(id: preparation.wrappedValue.id)
                    }
                )
            }
            Button {
                viewModel.addPreparation()
                HapticManager.selection()
            } label: {
                Label("Add preparation", systemImage: "plus")
                    .frame(minHeight: 44)
            }
            .disabled(draft.wrappedValue.plan.events.isEmpty)
            .accessibilityIdentifier("commitmentAddPreparation")
        } header: {
            Text("Preparation")
        } footer: {
            Text("Things to pack or prepare become linked tasks at the right time.")
        }
    }

    private var externalActionSection: some View {
        Section {
            Toggle(
                "This plan has an outside step",
                isOn: Binding(
                    get: { draft.wrappedValue.plan.externalAction != nil },
                    set: { viewModel.setHasExternalAction($0) }
                )
            )
            .accessibilityIdentifier("commitmentHasExternalAction")

            if draft.wrappedValue.plan.externalAction != nil {
                CommitmentExternalActionEditor(action: externalAction)

                if let action = draft.wrappedValue.plan.externalAction {
                    if let destination = action.handoffURL {
                        Link(destination: destination) {
                            Label(action.label, systemImage: "arrow.up.right.square")
                                .frame(minHeight: 44)
                        }
                        .accessibilityIdentifier("commitmentExternalHandoff")
                    } else if action.targetType == .manual {
                        Text(action.target)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        Label(
                            "Check the destination before opening it.",
                            systemImage: "exclamationmark.shield.fill"
                        )
                        .foregroundStyle(.orange)
                    }

                    Button {
                        Task { _ = await viewModel.markExternalActionDone() }
                    } label: {
                        if viewModel.busyAction == "action" {
                            ProgressView().frame(maxWidth: .infinity, minHeight: 44)
                        } else {
                            Label(
                                draft.wrappedValue.externalActionStatus == .completed
                                    ? "Done" : "Mark Done",
                                systemImage: "checkmark"
                            )
                            .frame(maxWidth: .infinity, minHeight: 44)
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(
                        viewModel.isDirty
                            || viewModel.busyAction != nil
                            || draft.wrappedValue.externalActionStatus == .completed
                    )
                    .accessibilityIdentifier("commitmentMarkActionDone")

                    if viewModel.isDirty {
                        Text("Save the edited outside step before marking it done.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("Outside HausKlar")
        } footer: {
            Text("Booking, replying and paying still happen with the provider. HausKlar records only that you did it.")
        }
    }

    private var actionsSection: some View {
        Section {
            HStack {
                Label(
                    viewModel.isDirty ? "Unsaved changes" : "Review saved",
                    systemImage: viewModel.isDirty ? "pencil.circle" : "checkmark.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Spacer()
            }

            Button {
                Task { _ = await viewModel.saveDraft() }
            } label: {
                if viewModel.busyAction == "save" {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 44)
                } else {
                    Label("Save changes", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
            }
            .buttonStyle(.bordered)
            .disabled(!viewModel.isDirty || viewModel.busyAction != nil)
            .accessibilityIdentifier("commitmentSave")

            Button {
                Task { _ = await viewModel.confirm() }
            } label: {
                if viewModel.busyAction == "confirm" {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 44)
                } else {
                    Label("Confirm plan", systemImage: "checkmark.seal.fill")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!viewModel.canConfirm)
            .accessibilityIdentifier("commitmentConfirm")

            Button("Decline", role: .destructive) {
                showingDecline = true
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .disabled(viewModel.isDirty || viewModel.busyAction != nil)
            .accessibilityIdentifier("commitmentDecline")

            if showingDecline {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Decline this plan?")
                        .font(.headline)
                    Text("Nothing from it will be added to Calendar or Tasks.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("Reason (optional)", text: $declineReason, axis: .vertical)
                    HStack(spacing: 10) {
                        Button("Keep reviewing") { showingDecline = false }
                            .buttonStyle(.bordered)
                        Button("Decline plan", role: .destructive) {
                            Task {
                                if await viewModel.decline(reason: declineReason) {
                                    showingDecline = false
                                }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding(.vertical, 6)
                .accessibilityIdentifier("commitmentDeclineConfirmation")
            }

            confirmHelp
        }
    }

    @ViewBuilder
    private var confirmHelp: some View {
        if draft.wrappedValue.visibility == .owner {
            Label(
                viewModel.mayChangeVisibility
                    ? "Share this plan with the family and save before confirming."
                    : "Only the owner can share this plan before it is confirmed.",
                systemImage: "person.example_f47e224f.slash"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        } else if viewModel.isDirty {
            Text("Save your edits before confirming.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if draft.wrappedValue.actionBlocksConfirmation {
            Text("Complete the outside step, then mark it Done.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if !draft.wrappedValue.reviewIssues.isEmpty {
            Text("Resolve the checks above and save the plan.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func statusText(_ value: Commitment) -> String {
        switch value.status {
        case .draft: "Draft".localized
        case .actionRequired: "Outside step needed".localized
        case .ready: "Ready to confirm".localized
        case .confirmed: "Confirmed".localized
        case .declined: "Declined".localized
        }
    }

    private func optionalText(_ value: Binding<String?>) -> Binding<String> {
        Binding(
            get: { value.wrappedValue ?? "" },
            set: { value.wrappedValue = $0.isEmpty ? nil : $0 }
        )
    }

    private var externalAction: Binding<CommitmentExternalAction> {
        Binding(
            get: {
                draft.wrappedValue.plan.externalAction
                    ?? CommitmentExternalAction(
                        kind: .other,
                        label: "Complete the outside step".localized,
                        targetType: .manual,
                        target: "Follow the instructions in the source".localized,
                        dueAt: nil,
                        requiresCompletionBeforeConfirm: false
                    )
            },
            set: { draft.wrappedValue.plan.externalAction = $0 }
        )
    }
}

private struct CommitmentEventEditor: View {
    @Binding var event: CommitmentEventDraft
    let members: [FamilyMemberDTO]
    let onRemove: () -> Void

    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 12) {
                TextField("Event title", text: $event.title, axis: .vertical)
                TextField(
                    "Description (optional)",
                    text: optionalText($event.description),
                    axis: .vertical
                )
                Toggle("All day", isOn: allDay)
                DatePicker(
                    event.allDay ? "Date" : "Starts",
                    selection: startDate,
                    displayedComponents: event.allDay ? .date : [.date, .hourAndMinute]
                )
                Toggle("Add an end", isOn: hasEnd)
                if event.endTime != nil {
                    DatePicker(
                        "Ends",
                        selection: endDate,
                        in: startDate.wrappedValue...,
                        displayedComponents: event.allDay ? .date : [.date, .hourAndMinute]
                    )
                }
                TextField("Location (optional)", text: optionalText($event.location))

                DisclosureGroup("People") {
                    ForEach(members) { member in
                        Toggle(member.name, isOn: attending(member.id))
                            .frame(minHeight: 44)
                    }
                }

                let adults = members.filter { $0.memberType == "user" }
                if !adults.isEmpty {
                    DisclosureGroup("Adults affected but not attending") {
                        ForEach(adults) { member in
                            Toggle(member.name, isOn: affected(member.id))
                                .frame(minHeight: 44)
                        }
                    }
                }

                Picker("Responsible person", selection: optionalText($event.assignedTo)) {
                    Text("Anyone").tag("")
                    ForEach(members) { member in
                        Text(member.name).tag(member.id)
                    }
                }

                Button("Remove event", role: .destructive, action: onRemove)
                    .frame(minHeight: 44)
            }
            .padding(.top, 10)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(event.title.isEmpty ? "Untitled event" : event.title)
                    .font(.headline)
                Text(eventDateText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("commitmentEvent-\(event.id)")
    }

    private var allDay: Binding<Bool> {
        Binding(
            get: { event.allDay },
            set: { value in
                guard value != event.allDay else { return }
                let start = startDate.wrappedValue
                let end = event.endTime.flatMap(ISODateParser.parse)
                event.allDay = value
                event.startTime = value
                    ? ISODateParser.stringDateOnly(from: start)
                    : ISODateParser.string(from: start)
                if let end {
                    event.endTime = value
                        ? ISODateParser.stringDateOnly(from: end)
                        : ISODateParser.string(from: end)
                }
            }
        )
    }

    private var startDate: Binding<Date> {
        Binding(
            get: { ISODateParser.parse(event.startTime) ?? Date() },
            set: { value in
                event.startTime = event.allDay
                    ? ISODateParser.stringDateOnly(from: value)
                    : ISODateParser.string(from: value)
                if let end = event.endTime.flatMap(ISODateParser.parse), end <= value {
                    let adjusted = Calendar.current.date(
                        byAdding: event.allDay ? .day : .hour,
                        value: 1,
                        to: value
                    ) ?? value.addingTimeInterval(3_600)
                    event.endTime = event.allDay
                        ? ISODateParser.stringDateOnly(from: adjusted)
                        : ISODateParser.string(from: adjusted)
                }
            }
        )
    }

    private var hasEnd: Binding<Bool> {
        Binding(
            get: { event.endTime != nil },
            set: { enabled in
                if enabled, event.endTime == nil {
                    let value = Calendar.current.date(
                        byAdding: event.allDay ? .day : .hour,
                        value: 1,
                        to: startDate.wrappedValue
                    ) ?? startDate.wrappedValue.addingTimeInterval(3_600)
                    event.endTime = event.allDay
                        ? ISODateParser.stringDateOnly(from: value)
                        : ISODateParser.string(from: value)
                } else if !enabled {
                    event.endTime = nil
                }
            }
        )
    }

    private var endDate: Binding<Date> {
        Binding(
            get: {
                event.endTime.flatMap(ISODateParser.parse)
                    ?? startDate.wrappedValue.addingTimeInterval(3_600)
            },
            set: { value in
                event.endTime = event.allDay
                    ? ISODateParser.stringDateOnly(from: value)
                    : ISODateParser.string(from: value)
            }
        )
    }

    private func attending(_ id: String) -> Binding<Bool> {
        Binding(
            get: { event.personIds.contains(id) },
            set: { selected in
                if selected {
                    if !event.personIds.contains(id) { event.personIds.append(id) }
                    event.affectedAdultIds.removeAll { $0 == id }
                } else {
                    event.personIds.removeAll { $0 == id }
                }
            }
        )
    }

    private func affected(_ id: String) -> Binding<Bool> {
        Binding(
            get: { event.affectedAdultIds.contains(id) },
            set: { selected in
                if selected {
                    if !event.affectedAdultIds.contains(id) { event.affectedAdultIds.append(id) }
                    event.personIds.removeAll { $0 == id }
                } else {
                    event.affectedAdultIds.removeAll { $0 == id }
                }
            }
        )
    }

    private var eventDateText: String {
        guard let value = ISODateParser.parse(event.startTime) else { return "Date needs checking".localized }
        return event.allDay ? ISODateParser.dateOnly(from: value) : ISODateParser.dateTime(from: value)
    }

    private func optionalText(_ value: Binding<String?>) -> Binding<String> {
        Binding(
            get: { value.wrappedValue ?? "" },
            set: { value.wrappedValue = $0.isEmpty ? nil : $0 }
        )
    }
}

private struct CommitmentTaskEditor: View {
    @Binding var task: CommitmentTaskDraft
    let members: [FamilyMemberDTO]
    let onRemove: () -> Void

    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 12) {
                TextField("Task title", text: $task.title, axis: .vertical)
                TextField(
                    "Description (optional)",
                    text: optionalText($task.description),
                    axis: .vertical
                )
                Toggle("Add a due date", isOn: hasDueDate)
                if task.dueDate != nil {
                    DatePicker("Due", selection: dueDate, displayedComponents: .date)
                    Toggle("Add a start date", isOn: hasActionableDate)
                    if task.actionableFrom != nil {
                        DatePicker(
                            "Can start",
                            selection: actionableDate,
                            in: ...dueDate.wrappedValue,
                            displayedComponents: .date
                        )
                    }
                }
                Picker("For", selection: optionalText($task.assignedTo)) {
                    Text("Anyone").tag("")
                    ForEach(members) { member in
                        Text(member.name).tag(member.id)
                    }
                }
                Picker("Priority", selection: $task.priority) {
                    Text("Low").tag(1)
                    Text("Normal").tag(2)
                    Text("High").tag(3)
                }
                Button("Remove task", role: .destructive, action: onRemove)
                    .frame(minHeight: 44)
            }
            .padding(.top, 10)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(task.title.isEmpty ? "Untitled task" : task.title)
                    .font(.headline)
                Text(task.dueDate.flatMap(ISODateParser.parseDateOnly).map(ISODateParser.dateOnly)
                    ?? "No due date".localized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("commitmentTask-\(task.id)")
    }

    private var hasDueDate: Binding<Bool> {
        Binding(
            get: { task.dueDate != nil },
            set: { enabled in
                task.dueDate = enabled ? ISODateParser.stringDateOnly(from: Date()) : nil
                if !enabled { task.actionableFrom = nil }
            }
        )
    }

    private var dueDate: Binding<Date> {
        Binding(
            get: { task.dueDate.flatMap(ISODateParser.parseDateOnly) ?? Date() },
            set: { value in
                task.dueDate = ISODateParser.stringDateOnly(from: value)
                if let actionable = task.actionableFrom.flatMap(ISODateParser.parseDateOnly),
                   actionable > value {
                    task.actionableFrom = ISODateParser.stringDateOnly(from: value)
                }
            }
        )
    }

    private var hasActionableDate: Binding<Bool> {
        Binding(
            get: { task.actionableFrom != nil },
            set: { enabled in
                task.actionableFrom = enabled
                    ? (task.dueDate ?? ISODateParser.stringDateOnly(from: Date())) : nil
            }
        )
    }

    private var actionableDate: Binding<Date> {
        Binding(
            get: { task.actionableFrom.flatMap(ISODateParser.parseDateOnly) ?? dueDate.wrappedValue },
            set: { task.actionableFrom = ISODateParser.stringDateOnly(from: $0) }
        )
    }

    private func optionalText(_ value: Binding<String?>) -> Binding<String> {
        Binding(
            get: { value.wrappedValue ?? "" },
            set: { value.wrappedValue = $0.isEmpty ? nil : $0 }
        )
    }
}

private struct CommitmentPreparationEditor: View {
    @Binding var preparation: CommitmentPreparationDraft
    let events: [CommitmentEventDraft]
    let members: [FamilyMemberDTO]
    let onRemove: () -> Void

    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 12) {
                TextField("Group name", text: $preparation.name)
                Picker("For event", selection: $preparation.eventId) {
                    ForEach(events) { event in
                        Text(event.title).tag(event.id)
                    }
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text("Items (one per line)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextEditor(text: items)
                        .frame(minHeight: 100)
                }
                Picker("Start preparing", selection: $preparation.leadHours) {
                    Text("At the event").tag(0)
                    Text("12 hours before").tag(12)
                    Text("1 day before").tag(24)
                    Text("2 days before").tag(48)
                    Text("1 week before").tag(168)
                }
                Picker("For", selection: optionalText($preparation.assignedTo)) {
                    Text("Anyone").tag("")
                    ForEach(members) { member in
                        Text(member.name).tag(member.id)
                    }
                }
                Button("Remove preparation", role: .destructive, action: onRemove)
                    .frame(minHeight: 44)
            }
            .padding(.top, 10)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(preparation.name.isEmpty ? "Untitled preparation" : preparation.name)
                    .font(.headline)
                Text(preparation.items.isEmpty
                    ? "No items".localized
                    : String(format: "%lld items".localized, Int64(preparation.items.count)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("commitmentPreparation-\(preparation.id)")
    }

    private var items: Binding<String> {
        Binding(
            get: { preparation.items.joined(separator: "\n") },
            set: { value in
                preparation.items = value
                    .split(whereSeparator: \.isNewline)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            }
        )
    }

    private func optionalText(_ value: Binding<String?>) -> Binding<String> {
        Binding(
            get: { value.wrappedValue ?? "" },
            set: { value.wrappedValue = $0.isEmpty ? nil : $0 }
        )
    }
}

private struct CommitmentExternalActionEditor: View {
    @Binding var action: CommitmentExternalAction

    var body: some View {
        Picker("Action", selection: $action.kind) {
            ForEach(CommitmentExternalActionKind.allCases) { kind in
                Text(kind.title).tag(kind)
            }
        }
        TextField("Button label", text: $action.label)
        Picker("How it opens", selection: $action.targetType) {
            ForEach(CommitmentExternalTargetType.allCases) { type in
                Text(type.title).tag(type)
            }
        }
        TextField("Destination or instructions", text: $action.target, axis: .vertical)
            .textInputAutocapitalization(action.targetType == .https ? .never : .sentences)
            .autocorrectionDisabled(action.targetType == .https)
            .keyboardType(action.targetType == .https ? .URL : .default)
        Toggle("Add a deadline", isOn: hasDeadline)
        if action.dueAt != nil {
            DatePicker("Deadline", selection: deadline)
        }
        Toggle("Must be done before confirming", isOn: $action.requiresCompletionBeforeConfirm)
    }

    private var hasDeadline: Binding<Bool> {
        Binding(
            get: { action.dueAt != nil },
            set: { enabled in
                action.dueAt = enabled ? ISODateParser.string(from: Date()) : nil
            }
        )
    }

    private var deadline: Binding<Date> {
        Binding(
            get: { action.dueAt.flatMap(ISODateParser.parse) ?? Date() },
            set: { action.dueAt = ISODateParser.string(from: $0) }
        )
    }
}
