import SwiftUI

struct BirthdaysView: View {
    @StateObject private var viewModel = BirthdaysViewModel()
    let initialBirthdayId: String?
    @State private var openedBirthday: BirthdayFullDTO?

    init(initialBirthdayId: String? = nil) {
        self.initialBirthdayId = initialBirthdayId
    }

    private var dueSoon: [BirthdayFullDTO] {
        viewModel.birthdays.filter(\.preparationDue)
    }

    private var later: [BirthdayFullDTO] {
        viewModel.birthdays.filter { !$0.preparationDue }
    }

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.isLoading && viewModel.birthdays.isEmpty {
                    ProgressView("Opening birthdays…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = viewModel.errorMessage, viewModel.birthdays.isEmpty {
                    ContentUnavailableView {
                        Label("Birthdays could not be opened", systemImage: "birthday.cake")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Try again") { Task { await viewModel.loadBirthdays() } }
                            .buttonStyle(.borderedProminent)
                    }
                } else if viewModel.birthdays.isEmpty {
                    ContentUnavailableView {
                        Label("Keep birthdays quietly in hand", systemImage: "birthday.cake")
                    } description: {
                        Text("Add a birthday and HausKlar will bring it forward when there is something to prepare.")
                    } actions: {
                        Button("Add birthday") { viewModel.prepareNew() }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    List {
                        if !dueSoon.isEmpty {
                            Section("Prepare now") {
                                ForEach(dueSoon) { birthdayRow($0) }
                            }
                        }
                        if !later.isEmpty {
                            Section("Later") {
                                ForEach(later) { birthdayRow($0) }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Birthdays")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button { viewModel.prepareNew() } label: {
                            Label("Add birthday", systemImage: "plus")
                        }
                        Button { viewModel.showingImport = true } label: {
                            Label("Paste a list", systemImage: "doc.on.clipboard")
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add birthdays")
                }
            }
            .sheet(isPresented: $viewModel.showingEditor) {
                BirthdayEditorSheet(viewModel: viewModel)
            }
            .sheet(isPresented: $viewModel.showingImport) {
                BirthdayImportSheet(viewModel: viewModel)
            }
            .safeAreaInset(edge: .bottom) {
                if let removed = viewModel.recentlyDeleted {
                    HStack(spacing: 12) {
                        Text("Removed \(removed.personName)'s birthday")
                            .font(.subheadline)
                            .lineLimit(1)
                        Spacer()
                        Button("Undo") { Task { await viewModel.undoDelete() } }
                            .fontWeight(.semibold)
                    }
                    .padding(.horizontal, 16)
                    .frame(minHeight: 52)
                    .background(.regularMaterial)
                }
            }
            .refreshable { await viewModel.loadBirthdays() }
            .task {
                await viewModel.loadBirthdays()
                if let initialBirthdayId {
                    openedBirthday = viewModel.birthdays.first { $0.id == initialBirthdayId }
                }
            }
            .navigationDestination(isPresented: Binding(
                get: { openedBirthday != nil },
                set: { if !$0 { openedBirthday = nil } }
            )) {
                if let birthday = openedBirthday {
                    BirthdayPreparationView(viewModel: viewModel, birthday: birthday)
                }
            }
        }
    }

    private func birthdayRow(_ birthday: BirthdayFullDTO) -> some View {
        NavigationLink {
            BirthdayPreparationView(viewModel: viewModel, birthday: birthday)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: birthday.daysUntil == 0 ? "birthday.cake.fill" : "birthday.cake")
                    .font(.title3)
                    .foregroundStyle(birthday.preparationDue ? .pink : .secondary)
                    .frame(width: 32, height: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(birthday.personName)
                        .font(.headline)
                    Text(birthdaySubtitle(birthday))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(countdown(birthday.daysUntil))
                    .font(.subheadline.weight(birthday.preparationDue ? .semibold : .regular))
                    .foregroundStyle(birthday.daysUntil == 0 ? .pink : .secondary)
            }
            .padding(.vertical, 2)
        }
        .accessibilityLabel("\(birthday.personName), \(countdown(birthday.daysUntil)), \(birthdaySubtitle(birthday))")
    }

    private func birthdaySubtitle(_ birthday: BirthdayFullDTO) -> String {
        let date = BirthdayDateText.monthDay(month: birthday.birthMonth, day: birthday.birthDay)
        if let age = birthday.turningAge { return "\(date) · turning \(age)" }
        return date
    }

    private func countdown(_ days: Int) -> String {
        switch days {
        case 0: "Today"
        case 1: "Tomorrow"
        default: "in \(days) days"
        }
    }
}

private struct BirthdayPreparationView: View {
    @ObservedObject var viewModel: BirthdaysViewModel
    let birthday: BirthdayFullDTO
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var cardMessage = ""
    @State private var showingTask = false
    @State private var taskTitle = ""
    @State private var taskDueDays = 7

    private var plan: BirthdayPreparationDTO? { viewModel.preparations[birthday.id] }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(BirthdayDateText.monthDay(month: birthday.birthMonth, day: birthday.birthDay))
                        .font(.title2.weight(.semibold))
                    if let turningAge = birthday.turningAge {
                        Text("Turning \(turningAge) · \(countdown)")
                            .foregroundStyle(.secondary)
                    } else {
                        Text(countdown)
                            .foregroundStyle(.secondary)
                    }
                    Text("HausKlar starts showing this \(birthday.reminderDaysBefore) days beforehand.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            }

            if viewModel.preparingBirthdayId == birthday.id && plan == nil {
                Section { ProgressView("Opening the plan…") }
            } else {
                Section("Present") {
                    Button {
                        appState.openFamily(.presents)
                    } label: {
                        planRow(
                            icon: "gift",
                            title: giftTitle,
                            detail: giftDetail,
                            complete: (plan?.giftsTotal ?? 0) > 0 && plan?.giftsRemaining == 0
                        )
                    }
                    .buttonStyle(.plain)
                }

                Section("Card") {
                    Menu {
                        ForEach(cardStatuses, id: \.0) { value, label in
                            Button(label) {
                                Task { await viewModel.updatePreparation(for: birthday, cardStatus: value) }
                            }
                        }
                    } label: {
                        planRow(
                            icon: "envelope",
                            title: "Card",
                            detail: cardStatusLabel(plan?.cardStatus ?? "not_started"),
                            complete: plan?.cardStatus == "sent"
                        )
                    }
                    .buttonStyle(.plain)

                    TextField("Message idea (optional)", text: $cardMessage, axis: .vertical)
                        .lineLimit(2...5)
                    if cardMessage != (plan?.cardMessage ?? "") {
                        Button("Save message") {
                            Task { await viewModel.updatePreparation(for: birthday, cardMessage: cardMessage) }
                        }
                    }
                }

                Section("Celebration") {
                    if let event = plan?.calendarEvent {
                        Button {
                            appState.highlightedCalendarResultId = event.id
                            appState.preferredCalendarDate = BirthdayDateText.date(birthday.nextBirthday)
                            appState.selectedTab = .calendar
                        } label: {
                            planRow(icon: "calendar", title: event.title, detail: "In Planner", complete: true)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Button {
                            Task { await viewModel.addPreparationEvent(for: birthday) }
                        } label: {
                            Label("Add birthday to Planner", systemImage: "calendar.badge.plus")
                        }
                        .disabled(viewModel.isSaving)
                    }

                    Menu {
                        Button("Not started") {
                            Task { await viewModel.updatePreparation(for: birthday, celebrationStatus: "not_started") }
                        }
                        Button("Planning") {
                            Task { await viewModel.updatePreparation(for: birthday, celebrationStatus: "planning") }
                        }
                        Button("Planned") {
                            Task { await viewModel.updatePreparation(for: birthday, celebrationStatus: "planned") }
                        }
                    } label: {
                        planRow(
                            icon: "party.popper",
                            title: "Celebration",
                            detail: celebrationLabel(plan?.celebrationStatus ?? "not_started"),
                            complete: plan?.celebrationStatus == "planned"
                        )
                    }
                    .buttonStyle(.plain)
                }

                Section("Things to do") {
                    ForEach(plan?.tasks ?? []) { task in
                        Button {
                            appState.highlightedTaskResultId = task.id
                            appState.openLists(.tasks)
                        } label: {
                            planRow(
                                icon: task.completed ? "checkmark.circle.fill" : "circle",
                                title: task.title,
                                detail: task.completed ? "Done" : "Open task",
                                complete: task.completed
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    Button { showingTask = true } label: {
                        Label("Add a task", systemImage: "plus")
                    }
                }
            }

            if let error = viewModel.errorMessage {
                Section { Text(error).foregroundStyle(.red) }
            }
        }
        .navigationTitle(birthday.personName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Edit") { viewModel.prepareEdit(birthday) }
            }
        }
        .sheet(isPresented: $showingTask) {
            NavigationStack {
                Form {
                    Section("Task") {
                        TextField("What needs doing?", text: $taskTitle)
                        Stepper("Due \(taskDueDays) days before", value: $taskDueDays, in: 0...60)
                    }
                }
                .navigationTitle("Add birthday task")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showingTask = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Add") {
                            Task {
                                if await viewModel.addPreparationTask(
                                    for: birthday,
                                    title: taskTitle,
                                    dueDaysBefore: taskDueDays
                                ) {
                                    taskTitle = ""
                                    showingTask = false
                                }
                            }
                        }
                        .disabled(taskTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.isSaving)
                    }
                }
            }
        }
        .task { await viewModel.loadPreparation(for: birthday) }
        .onChange(of: plan?.cardMessage) { _, value in cardMessage = value ?? "" }
        .onChange(of: viewModel.birthdays) { _, values in
            if !values.contains(where: { $0.id == birthday.id }) { dismiss() }
        }
    }

    private var countdown: String {
        birthday.daysUntil == 0 ? "today" : birthday.daysUntil == 1 ? "tomorrow" : "in \(birthday.daysUntil) days"
    }

    private var giftTitle: String {
        guard let plan, plan.giftsTotal > 0 else { return "Choose a present" }
        return plan.giftsRemaining == 0 ? "Present ready" : "Present"
    }

    private var giftDetail: String {
        guard let plan, plan.giftsTotal > 0 else { return "Open Presents" }
        return plan.giftsRemaining == 0 ? "All sorted" : "\(plan.giftsRemaining) still to prepare"
    }

    private let cardStatuses = [
        ("not_started", "Not started"), ("to_buy", "Need to buy"),
        ("bought", "Bought"), ("written", "Written"), ("sent", "Sent")
    ]

    private func cardStatusLabel(_ value: String) -> String {
        cardStatuses.first { $0.0 == value }?.1 ?? "Not started"
    }

    private func celebrationLabel(_ value: String) -> String {
        ["not_started": "Not started", "planning": "Planning", "planned": "Planned"][value] ?? "Not started"
    }

    private func planRow(icon: String, title: String, detail: String, complete: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(complete ? .green : .pink)
                .frame(width: 28, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(.primary)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}

private struct BirthdayEditorSheet: View {
    @ObservedObject var viewModel: BirthdaysViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDelete = false

    private var selectedMonth: Binding<Int> {
        Binding(
            get: { Calendar(identifier: .gregorian).component(.month, from: viewModel.formDateOfBirth) },
            set: { setMonthDay(month: $0, day: selectedDay.wrappedValue) }
        )
    }

    private var selectedDay: Binding<Int> {
        Binding(
            get: { Calendar(identifier: .gregorian).component(.day, from: viewModel.formDateOfBirth) },
            set: { setMonthDay(month: selectedMonth.wrappedValue, day: $0) }
        )
    }

    private var daysInMonth: Int {
        var components = DateComponents()
        components.year = 2000
        components.month = selectedMonth.wrappedValue
        let calendar = Calendar(identifier: .gregorian)
        guard let date = calendar.date(from: components),
              let range = calendar.range(of: .day, in: .month, for: date) else { return 31 }
        return range.count
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Birthday") {
                    TextField("Name", text: $viewModel.formName)
                    Toggle("I know the birth year", isOn: $viewModel.formHasBirthYear)
                    if viewModel.formHasBirthYear {
                        DatePicker(
                            "Date of birth",
                            selection: $viewModel.formDateOfBirth,
                            in: ...Date(),
                            displayedComponents: .date
                        )
                    } else {
                        Picker("Month", selection: selectedMonth) {
                            ForEach(1...12, id: \.self) { month in
                                Text(BirthdayDateText.monthName(month)).tag(month)
                            }
                        }
                        Picker("Day", selection: selectedDay) {
                            ForEach(1...daysInMonth, id: \.self) { day in Text(String(day)).tag(day) }
                        }
                    }
                }

                Section("Bring it forward") {
                    Stepper(
                        "Show \(viewModel.formReminderDays) days before",
                        value: $viewModel.formReminderDays,
                        in: 0...90
                    )
                    Text("Until then it stays quietly in the Later list.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("More") {
                    Picker("Relationship", selection: $viewModel.formRelationship) {
                        ForEach(viewModel.relationships, id: \.self) { value in
                            Text(value.capitalized).tag(value)
                        }
                    }
                }

                if let editing = viewModel.editingBirthday {
                    Section {
                        Button("Remove birthday", role: .destructive) { confirmingDelete = true }
                    } footer: {
                        Text("You can undo this after closing the form.")
                    }
                    .confirmationDialog("Remove \(editing.personName)'s birthday?", isPresented: $confirmingDelete) {
                        Button("Remove", role: .destructive) {
                            Task {
                                await viewModel.deleteBirthday(editing)
                                viewModel.showingEditor = false
                            }
                        }
                    }
                }

                if let error = viewModel.errorMessage {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle(viewModel.editingBirthday == nil ? "Add birthday" : "Edit birthday")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { viewModel.showingEditor = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { _ = await viewModel.saveBirthday() } }
                        .disabled(viewModel.isSaving || viewModel.formName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .alert("Keep both birthdays?", isPresented: $viewModel.duplicateNeedsConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Keep both") { Task { _ = await viewModel.saveBirthday(allowDuplicate: true) } }
            } message: {
                Text("A birthday with this name and date is already saved.")
            }
        }
    }

    private func setMonthDay(month: Int, day: Int) {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.year = 2000
        components.month = month
        components.day = min(day, days(for: month))
        if let date = components.date { viewModel.formDateOfBirth = date }
    }

    private func days(for month: Int) -> Int {
        let calendar = Calendar(identifier: .gregorian)
        guard let date = calendar.date(from: DateComponents(year: 2000, month: month)),
              let range = calendar.range(of: .day, in: .month, for: date) else { return 31 }
        return range.count
    }
}

private struct BirthdayImportSheet: View {
    @ObservedObject var viewModel: BirthdaysViewModel

    var body: some View {
        NavigationStack {
            Form {
                if viewModel.importDrafts.isEmpty {
                    Section("Paste birthdays") {
                        TextEditor(text: $viewModel.importText)
                            .frame(minHeight: 180)
                        Text("One person per line, for example “Grandma, 15 June 1955”. Leave off the year if you do not know it.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section("Check before saving") {
                        ForEach(viewModel.importDrafts) { draft in
                            if draft.canImport {
                                Toggle(isOn: Binding(
                                    get: { viewModel.selectedImportLines.contains(draft.lineNumber) },
                                    set: { selected in
                                        if selected { viewModel.selectedImportLines.insert(draft.lineNumber) }
                                        else { viewModel.selectedImportLines.remove(draft.lineNumber) }
                                    }
                                )) {
                                    importRow(draft)
                                }
                            } else {
                                importRow(draft)
                            }
                        }
                    }
                    Section {
                        Button("Edit pasted list") {
                            viewModel.importDrafts = []
                            viewModel.selectedImportLines = []
                        }
                    }
                }

                if let error = viewModel.errorMessage {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Import birthdays")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { viewModel.showingImport = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if viewModel.importDrafts.isEmpty {
                        Button("Review") { Task { await viewModel.previewImport() } }
                            .disabled(viewModel.importText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.isReviewingImport)
                    } else {
                        Button("Save selected") { Task { _ = await viewModel.importSelected() } }
                            .disabled(viewModel.selectedImportLines.isEmpty || viewModel.isSaving)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func importRow(_ draft: BirthdayImportDraftDTO) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(draft.personName ?? draft.sourceLine)
            if let month = draft.birthMonth, let day = draft.birthDay {
                Text(BirthdayDateText.monthDay(month: month, day: day) + (draft.dateOfBirth == nil ? " · year unknown" : ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if draft.duplicateId != nil {
                Text("Already saved")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let issue = draft.issue {
                Text(issue).font(.caption).foregroundStyle(.orange)
            }
        }
    }
}

private enum BirthdayDateText {
    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        return formatter
    }()

    static func monthName(_ month: Int) -> String {
        guard (1...12).contains(month) else { return String(month) }
        return monthFormatter.monthSymbols[month - 1]
    }

    static func monthDay(month: Int, day: Int) -> String {
        "\(day) \(monthName(month))"
    }

    static func date(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.date(from: value)
    }
}

#Preview {
    BirthdaysView()
        .environmentObject(AppState())
}
