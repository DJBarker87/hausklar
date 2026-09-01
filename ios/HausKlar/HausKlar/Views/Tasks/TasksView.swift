import SwiftUI

/// Filter for showing the current user's tasks vs all tasks.
enum TaskOwnerFilter {
    case mine, all
}

enum TaskPriorityFilter: Int, CaseIterable {
    case any = 0
    case high = 3
    case normal = 2
    case low = 1

    var label: String {
        switch self {
        case .any: "Any"
        case .high: "High"
        case .normal: "Normal"
        case .low: "Low"
        }
    }
}

enum TaskListSection: String, CaseIterable, Identifiable {
    case todayAndOverdue = "Today & overdue"
    case soon = "Soon"
    case waiting = "Waiting"
    case completed = "Completed"

    var id: Self { self }
}

enum TaskDatePresentation {
    static func isDateOnly(_ value: String) -> Bool {
        value.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
    }

    static func isOverdue(
        _ value: String,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Bool {
        if isDateOnly(value) {
            let parts = value.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3,
                  let due = calendar.date(
                    from: DateComponents(
                        year: parts[0],
                        month: parts[1],
                        day: parts[2]
                    )
                  ) else {
                return false
            }
            return calendar.startOfDay(for: due) < calendar.startOfDay(for: now)
        }
        guard let due = ISODateParser.parse(value) else { return false }
        return due < now
    }

    static func isWaiting(
        _ value: String?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Bool {
        guard let value, let date = ISODateParser.parse(value) else { return false }
        if isDateOnly(value) {
            return calendar.startOfDay(for: date) > calendar.startOfDay(for: now)
        }
        return date > now
    }

    static func isDueTodayOrEarlier(
        _ value: String?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Bool {
        guard let value, let due = ISODateParser.parse(value),
              let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) else {
            return false
        }
        return due < tomorrow
    }
}

enum TaskGrouping {
    static func section(
        for task: TaskDTO,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> TaskListSection {
        if task.completedAt != nil { return .completed }
        if TaskDatePresentation.isWaiting(task.actionableFrom, now: now, calendar: calendar) {
            return .waiting
        }
        if TaskDatePresentation.isDueTodayOrEarlier(task.dueDate, now: now, calendar: calendar) {
            return .todayAndOverdue
        }
        return .soon
    }

    static func sorted(_ tasks: [TaskDTO], in section: TaskListSection) -> [TaskDTO] {
        tasks.sorted { left, right in
            if section == .completed {
                return (left.completedAt ?? "") > (right.completedAt ?? "")
            }
            if section == .waiting, left.actionableFrom != right.actionableFrom {
                return (left.actionableFrom ?? "9999") < (right.actionableFrom ?? "9999")
            }
            if left.dueDate != right.dueDate {
                return (left.dueDate ?? "9999") < (right.dueDate ?? "9999")
            }
            if left.priority != right.priority { return left.priority > right.priority }
            return left.title.localizedCaseInsensitiveCompare(right.title) == .orderedAscending
        }
    }
}

/// Full task management view with filtering, creation, completion, and deletion.
struct TasksView: View {
    @StateObject private var viewModel: TasksViewModel
    @EnvironmentObject private var appState: AppState
    @Environment(\.modelContext) private var modelContext

    @State private var showDeleteConfirmation = false
    @State private var taskToDelete: TaskDTO?
    @State private var taskOwnerFilter: TaskOwnerFilter = .mine
    @State private var taskPriorityFilter: TaskPriorityFilter = .any
    @State private var selectedTask: TaskDTO?
    @State private var showingQuickTask = false
    @State private var showingFilters = false

    // Cached formatters
    private static let shortDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .none
        return f
    }()

    private static let shortDateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    init(assigneeFilterId: String? = nil, assigneeFilterName: String? = nil) {
        _viewModel = StateObject(
            wrappedValue: TasksViewModel(
                assigneeFilterId: assigneeFilterId,
                assigneeFilterName: assigneeFilterName
            )
        )
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                filterSummaryBar
                taskListContent
            }
            .navigationTitle(viewModel.assigneeFilterName.map { "\($0)'s Tasks" } ?? "Tasks")
            .toolbar {
                if viewModel.assigneeFilterId == nil {
                    ToolbarItem(placement: .topBarLeading) {
                        NavigationLink {
                            TaskOverviewView()
                        } label: {
                            Image(systemName: "person.example_81b06587.fill")
                        }
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Filters", systemImage: hasCustomFilters
                           ? "line.3.horizontal.decrease.circle.fill"
                           : "line.3.horizontal.decrease.circle") {
                        showingFilters = true
                        HapticManager.selection()
                    }
                    .accessibilityIdentifier("tasksFilterButton")

                    Button("Add", systemImage: "plus") {
                        showingQuickTask = true
                        HapticManager.medium()
                    }
                    .accessibilityHint("Add a task")
                    .accessibilityIdentifier("tasksAddButton")
                }
            }
            .confirmationDialog("Delete this task?", isPresented: $showDeleteConfirmation, presenting: taskToDelete) { task in
                Button("Delete", role: .destructive) {
                    Task { await viewModel.deleteTask(task.id) }
                }
                Button("Cancel", role: .cancel) { }
            } message: { task in
                Text("Are you sure you want to delete \"\(task.title)\"?")
            }
            .sheet(item: $selectedTask) { task in
                TaskDetailSheet(initialTask: task, viewModel: viewModel)
            }
            .sheet(isPresented: $showingQuickTask) {
                QuickTaskSheet(initialDate: Date(), startsWithDueDate: false) {
                    Task { await viewModel.loadTasks() }
                }
            }
            .sheet(isPresented: $showingFilters) {
                TaskFilterSheet(
                    ownerFilter: $taskOwnerFilter,
                    category: $viewModel.selectedCategory,
                    priority: $taskPriorityFilter,
                    categories: viewModel.categories,
                    showsOwner: viewModel.assigneeFilterId == nil
                )
            }
            .task {
                applyResultFocusIfNeeded()
                viewModel.bindModelContext(modelContext)
                await viewModel.loadTasks()
            }
            .onChange(of: viewModel.querySignature) {
                Task { await viewModel.loadTasks() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .taskDataChanged)) { _ in
                Task { await viewModel.loadTasks() }
            }
            .onChange(of: appState.highlightedTaskResultId) { _, resultId in
                guard resultId != nil else { return }
                applyResultFocusIfNeeded()
                Task { await viewModel.loadTasks() }
            }
        }
    }

    private var filteredTasks: [TaskDTO] {
        var result = viewModel.tasks
        if viewModel.assigneeFilterId == nil,
           taskOwnerFilter == .mine,
           let currentUserId = appState.currentUser?.id {
            result = result.filter { task in
                viewModel.taskIsVisibleInMine(task, currentUserId: currentUserId)
            }
        }
        if let category = viewModel.selectedCategory {
            result = result.filter { $0.category == category }
        }
        if taskPriorityFilter != .any {
            result = result.filter { $0.priority == taskPriorityFilter.rawValue }
        }
        return result
    }

    private var hasCustomFilters: Bool {
        (viewModel.assigneeFilterId == nil && taskOwnerFilter == .all)
            || viewModel.selectedCategory != nil
            || taskPriorityFilter != .any
    }

    private var filterSummary: String {
        var parts: [String] = []
        if viewModel.assigneeFilterId != nil {
            parts.append(viewModel.assigneeFilterName ?? "This person")
        } else {
            parts.append(taskOwnerFilter == .mine ? "Mine" : "Everyone")
        }
        if let category = viewModel.selectedCategory {
            parts.append(category.capitalized)
        }
        if taskPriorityFilter != .any {
            parts.append("\(taskPriorityFilter.label) priority")
        }
        return parts.isEmpty ? "Everyone" : parts.joined(separator: " · ")
    }

    private var filterSummaryBar: some View {
        Button {
            showingFilters = true
            HapticManager.selection()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "line.3.horizontal.decrease")
                Text("Showing")
                    .font(.subheadline.weight(.semibold))
                Text(filterSummary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .frame(minHeight: 44)
            .padding(.horizontal)
        }
        .buttonStyle(.plain)
        .background(Color(.systemGroupedBackground))
        .accessibilityLabel("Filters, \(filterSummary)")
    }

    // MARK: - Task List Content

    private var taskListContent: some View {
        Group {
            if viewModel.isLoading && viewModel.tasks.isEmpty {
                loadingState
            } else if filteredTasks.isEmpty {
                emptyState
            } else {
                taskList
            }
        }
    }

    private var loadingState: some View {
        VStack {
            Spacer()
            ProgressView("Loading tasks...")
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(hasCustomFilters ? "No tasks match these filters" : "No tasks — enjoy the free time!")
                .font(.headline)
                .foregroundStyle(.secondary)
            if hasCustomFilters {
                Button("Clear filters") {
                    taskOwnerFilter = .mine
                    viewModel.selectCategory(nil)
                    taskPriorityFilter = .any
                }
                .buttonStyle(.bordered)
            } else {
                Button("Add a task", systemImage: "plus") {
                    showingQuickTask = true
                }
                .buttonStyle(.borderedProminent)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var taskList: some View {
        return List {
            // Error banner
            if let errorMessage = viewModel.errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .font(.subheadline)
                }
            }

            ForEach(TaskListSection.allCases) { section in
                let sectionTasks = TaskGrouping.sorted(
                    filteredTasks.filter { TaskGrouping.section(for: $0) == section },
                    in: section
                )
                if !sectionTasks.isEmpty {
                    Section(section.rawValue) {
                        ForEach(sectionTasks) { task in
                        taskRow(task)
                            .deleteDisabled(!viewModel.canDeleteTask(task))
                        }
                        .onDelete { indexSet in
                            confirmDeleteFromSection(sectionTasks, at: indexSet)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable {
            await viewModel.loadTasks()
        }
    }

    // MARK: - Task Row

    private func taskRow(_ task: TaskDTO) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                // Completion checkbox
                Button {
                    Task {
                        if task.completedAt == nil {
                            await viewModel.completeTask(task.id)
                        } else {
                            await viewModel.reopenTask(task.id)
                        }
                    }
                } label: {
                    Image(systemName: task.completedAt != nil ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(task.completedAt != nil ? .green : .secondary)
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(task.completedAt != nil ? "Reopen task" : "Complete task")

                Button {
                    selectedTask = task
                } label: {
                    HStack(spacing: 10) {
                        // Task details
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text(task.title)
                                    .font(.body)
                                    .strikethrough(task.completedAt != nil)
                                    .foregroundStyle(task.completedAt != nil ? .secondary : .primary)

                                // Coloured bin dots (from description e.g. "black,blue")
                                if task.category == "bins", let desc = task.description, !desc.isEmpty {
                                    binDots(desc, isCompleted: task.completedAt != nil)
                                }
                            }

                            HStack(spacing: 6) {
                                // Category badge
                                if task.isManaged || task.category != nil {
                                    let category = task.managedCategoryLabel
                                        ?? (task.category?.capitalized ?? "")
                                    Text(category)
                                        .font(.caption2)
                                        .fontWeight(.medium)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(categoryColor(category).opacity(0.15))
                                        .foregroundStyle(categoryColor(category))
                                        .clipShape(Capsule())
                                }

                                // Due date
                                if let dueDateString = task.dueDate {
                                    dueDateLabel(dueDateString)
                                }

                                // Actionable from indicator
                                if let actionableFrom = task.actionableFrom {
                                    actionableFromLabel(actionableFrom)
                                }

                                // Assignee initial circles
                                if !task.assignees.isEmpty {
                                    assigneeCircles(task.assignees)
                                }
                            }
                        }

                        Spacer(minLength: 4)

                        if task.sourceDocument != nil {
                            Image(systemName: "paperclip")
                                .font(.caption)
                                .foregroundStyle(Color.accentColor)
                                .accessibilityHidden(true)
                        }

                        // Priority indicator
                        priorityIndicator(task.priority)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(task.title)
                .accessibilityValue(task.sourceDocument == nil ? "" : "Document attached")
                .accessibilityHint("Open task details")
            }

            // Per-person completion for multi-assignee tasks
            if task.assignees.count > 1 && !task.isManaged {
                DisclosureGroup("Assignees") {
                    ForEach(task.assignees) { assignee in
                        HStack {
                            Button {
                                if assignee.completedAt == nil {
                                    Task {
                                        await viewModel.completeTaskForPerson(
                                            taskId: task.id,
                                            assigneeId: assignee.assigneeId
                                        )
                                    }
                                }
                            } label: {
                                Image(systemName: assignee.completedAt != nil ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(assignee.completedAt != nil ? .green : .secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(assignee.completedAt != nil ? "Completed" : "Not completed")

                            Text(assignee.assigneeName ?? "Unknown")
                                .font(.subheadline)
                                .strikethrough(assignee.completedAt != nil)
                                .foregroundStyle(assignee.completedAt != nil ? .secondary : .primary)

                            Spacer()
                        }
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .listRowBackground(
            appState.highlightedTaskResultId == task.id
                ? Color.accentColor.opacity(0.14)
                : Color(.secondarySystemGroupedBackground)
        )
    }

    private func applyResultFocusIfNeeded() {
        guard appState.highlightedTaskResultId != nil else { return }
        taskOwnerFilter = .all
        viewModel.selectedCategory = nil
        taskPriorityFilter = .any
    }

    // MARK: - Assignee Circles

    private func assigneeCircles(_ assignees: [TaskAssigneeDTO]) -> some View {
        HStack(spacing: -4) {
            ForEach(assignees.prefix(4)) { assignee in
                ZStack {
                    Circle()
                        .fill(assignee.completedAt != nil ? Color.green.opacity(0.3) : Color.blue.opacity(0.3))
                        .frame(width: 20, height: 20)
                    Text(String((assignee.assigneeName ?? "?").prefix(1)).uppercased())
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(assignee.completedAt != nil ? .green : .blue)
                }
            }
            if assignees.count > 4 {
                Text("+\(assignees.count - 4)")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func binDots(_ description: String, isCompleted: Bool) -> some View {
        let keys = description.split(separator: ",").map {
            String($0).trimmingCharacters(in: .whitespaces)
        }
        let labels = keys.map(binLabel)
        return HStack(spacing: 4) {
            ForEach(keys, id: \.self) { key in
                Circle()
                    .fill(binColor(key))
                    .frame(width: 14, height: 14)
                    .opacity(isCompleted ? 0.4 : 1.0)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Bins: \(labels.joined(separator: ", "))")
    }

    private func binColor(_ key: String) -> Color {
        switch key.trimmingCharacters(in: .whitespaces) {
        case "black": return .primary
        case "blue": return .blue
        case "green": return .green
        default: return .gray
        }
    }

    private func binLabel(_ key: String) -> String {
        switch key.trimmingCharacters(in: .whitespaces) {
        case "black": return "refuse"
        case "blue": return "recycling"
        case "green": return "garden"
        default: return "other"
        }
    }

    // MARK: - Helper Views

    private func dueDateLabel(_ dateString: String) -> some View {
        let date = ISODateParser.parse(dateString)
        let isOverdue = TaskDatePresentation.isOverdue(dateString)
        let displayText: String = {
            guard let date else { return dateString }
            return Self.shortDateFormatter.string(from: date)
        }()

        return HStack(spacing: 3) {
            Image(systemName: "calendar")
                .font(.caption2)
            Text(displayText)
                .font(.caption)
        }
        .foregroundStyle(isOverdue ? .red : .secondary)
        .accessibilityLabel("Due \(displayText)\(isOverdue ? ", overdue" : "")")
    }

    private func actionableFromLabel(_ dateString: String) -> some View {
        let date = ISODateParser.parse(dateString)
        let displayText: String = {
            guard let date else { return dateString }
            return Self.shortDateTimeFormatter.string(from: date)
        }()

        return HStack(spacing: 3) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.caption2)
            Text("Hide until \(displayText)")
                .font(.caption)
        }
        .foregroundStyle(.purple)
    }

    private func priorityIndicator(_ priority: Int) -> some View {
        Circle()
            .fill(priorityColor(priority))
            .frame(width: 10, height: 10)
            .accessibilityLabel("\(priorityLabel(priority)) priority")
    }

    private func priorityColor(_ priority: Int) -> Color {
        switch priority {
        case 3: return .red
        case 2: return .orange
        default: return .gray
        }
    }

    private func categoryColor(_ category: String) -> Color {
        switch category {
        case "bins": return .brown
        case "household": return .blue
        case "shopping": return .purple
        case "admin": return .indigo
        case "other": return .gray
        default: return .gray
        }
    }

    private func confirmDeleteFromSection(_ sectionTasks: [TaskDTO], at indexSet: IndexSet) {
        guard let index = indexSet.first else { return }
        let task = sectionTasks[index]
        guard viewModel.canDeleteTask(task) else { return }
        taskToDelete = task
        showDeleteConfirmation = true
    }

    // MARK: - Helpers

    private func priorityLabel(_ priority: Int) -> String {
        switch priority {
        case 3: return "High"
        case 2: return "Medium"
        default: return "Low"
        }
    }
}

private struct TaskFilterSheet: View {
    @Binding var ownerFilter: TaskOwnerFilter
    @Binding var category: String?
    @Binding var priority: TaskPriorityFilter
    let categories: [String]
    let showsOwner: Bool

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                if showsOwner {
                    Section("Owner") {
                        Picker("Owner", selection: $ownerFilter) {
                            Text("Mine").tag(TaskOwnerFilter.mine)
                            Text("Everyone").tag(TaskOwnerFilter.all)
                        }
                        .pickerStyle(.segmented)
                    }
                }

                Section("Category") {
                    Picker("Category", selection: $category) {
                        Text("Any category").tag(String?.none)
                        ForEach(categories, id: \.self) { item in
                            Text(item.capitalized).tag(Optional(item))
                        }
                    }
                }

                Section("Priority") {
                    Picker("Priority", selection: $priority) {
                        ForEach(TaskPriorityFilter.allCases, id: \.self) { item in
                            Text(item.label).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    Button("Reset filters") {
                        ownerFilter = .mine
                        category = nil
                        priority = .any
                    }
                }
            }
            .navigationTitle("Filter Tasks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

/// Compact attachment control shared by task creation and editing. The picker
/// works with documents already stored in the family library; capture remains
/// in the Files workflow so task forms stay quick.
struct TaskDocumentAttachmentSection: View {
    @Binding var document: SourceDocumentDTO?
    let sectioned: Bool
    @State private var showingPicker = false

    init(document: Binding<SourceDocumentDTO?>, sectioned: Bool = true) {
        _document = document
        self.sectioned = sectioned
    }

    var body: some View {
        Group {
            if sectioned {
                Section("Attachment") {
                    attachmentContent
                }
            } else {
                attachmentContent
            }
        }
        .sheet(isPresented: $showingPicker) {
            DocumentAttachmentPicker(selectedDocument: document) { selected in
                document = selected
                HapticManager.selection()
            }
        }
    }

    @ViewBuilder
    private var attachmentContent: some View {
        if let attachedDocument = document {
            HStack(spacing: 12) {
                Image(systemName: attachedDocument.mediaType.hasPrefix("image/") ? "photo.fill" : "doc.fill")
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 28, height: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(attachedDocument.title)
                        .lineLimit(2)
                    Text(attachedDocument.originalFilename)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Attached document, \(attachedDocument.title)")

            Button {
                showingPicker = true
            } label: {
                Label("Change Document", systemImage: "arrow.triangle.2.circlepath")
                    .frame(minHeight: 44)
            }
            .accessibilityHint("Choose a different document from the family library")
            .accessibilityIdentifier("taskChangeDocumentButton")

            Button(role: .destructive) {
                document = nil
                HapticManager.selection()
            } label: {
                Label("Remove Attachment", systemImage: "paperclip.badge.ellipsis")
                    .frame(minHeight: 44)
            }
            .accessibilityHint("The document remains in the family library")
            .accessibilityIdentifier("taskRemoveDocumentButton")
        } else {
            Button {
                showingPicker = true
            } label: {
                Label("Attach Document", systemImage: "paperclip")
                    .frame(minHeight: 44)
            }
            .accessibilityHint("Choose a document from the family library")
            .accessibilityIdentifier("taskAttachDocumentButton")
        }
    }
}

private struct TaskDetailSheet: View {
    let initialTask: TaskDTO
    @ObservedObject var viewModel: TasksViewModel

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState
    @State private var showingEdit = false
    @State private var previewItem: DocumentPreviewItem?
    @State private var previewError: String?
    @State private var isOpeningDocument = false

    private var task: TaskDTO {
        viewModel.tasks.first(where: { $0.id == initialTask.id }) ?? initialTask
    }

    var body: some View {
        NavigationStack {
            List {
                if (!task.isManaged || task.isLibraryManaged),
                   let description = task.description,
                   !description.isEmpty {
                    Section("Notes") {
                        Text(description)
                    }
                }

                if task.isFinanceManaged {
                    Section("Managed in Finance") {
                        Label("Money", systemImage: "wallet.bifold")
                        Text("Marking this done means the task was completed. It does not confirm the payment left the account.")
                            .foregroundStyle(.secondary)
                        if let financeURL = task.managedSource?.financeWebURL {
                            FinanceWebHandoffButton(destination: financeURL) {
                                Label("Open Finance", systemImage: "arrow.up.right.square")
                                    .frame(
                                        maxWidth: .infinity,
                                        minHeight: 44,
                                        alignment: .leading
                                    )
                            }
                            .accessibilityHint("Open this item in the HausKlar web app")
                            .accessibilityIdentifier("taskOpenFinanceLink")
                        }
                    }
                }

                if task.isLibraryManaged {
                    Section("Managed in Library books") {
                        Label("Library", systemImage: "books.vertical")
                        Text("Completing this shared task records that the family dealt with the listed books. It never renews them automatically.")
                            .foregroundStyle(.secondary)
                        Button {
                            appState.openLists(.renewals)
                            dismiss()
                        } label: {
                            Label("Open Library books", systemImage: "arrow.right")
                                .frame(
                                    maxWidth: .infinity,
                                    minHeight: 44,
                                    alignment: .leading
                                )
                        }
                        .accessibilityHint("See the listed books, current status and official renewal links")
                        .accessibilityIdentifier("taskOpenLibraryBooks")
                    }
                }

                Section("Details") {
                    LabeledContent("Priority", value: priorityLabel(task.priority))
                    if let managedCategory = task.managedCategoryLabel {
                        LabeledContent("Category", value: managedCategory)
                    } else if let category = task.category {
                        LabeledContent("Category", value: category.capitalized)
                    }
                    if let dueDate = task.dueDate {
                        LabeledContent("Due", value: formattedDate(dueDate))
                    }
                    if task.recurrenceRule != nil {
                        LabeledContent(
                            "Repeat",
                            value: TaskRecurrenceOption(rule: task.recurrenceRule).title
                        )
                    }
                    if let actionableFrom = task.actionableFrom {
                        LabeledContent("Hide until", value: formattedDate(actionableFrom))
                    }
                    LabeledContent(
                        "Status",
                        value: task.completedAt == nil ? "To do" : "Completed"
                    )
                }

                if !task.assignees.isEmpty {
                    Section("People") {
                        ForEach(task.assignees) { assignee in
                            Label(
                                assignee.assigneeName ?? "Unknown",
                                systemImage: assignee.completedAt == nil
                                    ? "person.example_35fbacff.circle"
                                    : "checkmark.circle.fill"
                            )
                        }
                    }
                }

                if !task.isManaged {
                    attachmentSection
                }

                Section {
                    Button {
                        Task {
                            if task.completedAt == nil {
                                await viewModel.completeTask(task.id)
                            } else {
                                await viewModel.reopenTask(task.id)
                            }
                        }
                    } label: {
                        Label(
                            task.completedAt == nil ? "Complete task" : "Reopen task",
                            systemImage: task.completedAt == nil
                                ? "checkmark.circle"
                                : "arrow.uturn.backward.circle"
                        )
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }
                    .disabled(viewModel.isLoading)
                }
            }
            .navigationTitle(task.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                if viewModel.canEditTask(task) {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Edit") {
                            viewModel.beginEditing(task)
                            showingEdit = true
                        }
                        .accessibilityHint("Edit task details and attachment")
                    }
                }
            }
            .sheet(isPresented: $showingEdit) {
                TaskEditSheet(viewModel: viewModel)
            }
            .sheet(item: $previewItem) { item in
                DocumentPreviewSheet(item: item)
                    .onDisappear {
                        DocumentPreviewStore.remove(item.url)
                    }
            }
        }
    }

    @ViewBuilder
    private var attachmentSection: some View {
        Section("Attachment") {
            if let document = task.sourceDocument {
                VStack(alignment: .leading, spacing: 4) {
                    Label(document.title, systemImage: "paperclip")
                        .font(.body.weight(.medium))
                    Text(document.originalFilename)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(
                        ByteCountFormatter.string(
                            fromByteCount: Int64(document.fileSize),
                            countStyle: .file
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)

                Button {
                    openDocument(document)
                } label: {
                    HStack {
                        Label("Open Original", systemImage: "doc.text.magnifyingglass")
                        Spacer()
                        if isOpeningDocument {
                            ProgressView()
                                .accessibilityLabel("Opening document")
                        }
                    }
                    .frame(minHeight: 44)
                }
                .disabled(isOpeningDocument)
                .accessibilityHint("Open the stored file in a preview")
                .accessibilityIdentifier("taskOpenOriginalDocumentButton")

                if let previewError {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(previewError)
                            .font(.caption)
                            .foregroundStyle(.red)
                        Button("Try Again") { openDocument(document) }
                            .buttonStyle(.bordered)
                            .frame(minHeight: 44)
                    }
                }

                if viewModel.canEditTask(task) {
                    Button("Change or Remove Attachment") {
                        viewModel.beginEditing(task)
                        showingEdit = true
                    }
                    .frame(minHeight: 44)
                }
            } else if viewModel.canEditTask(task) {
                Button {
                    viewModel.beginEditing(task)
                    showingEdit = true
                } label: {
                    Label("Attach Document", systemImage: "paperclip")
                        .frame(minHeight: 44)
                }
            } else {
                Text("No document attached")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func openDocument(_ document: SourceDocumentDTO) {
        guard !isOpeningDocument else { return }
        isOpeningDocument = true
        previewError = nil
        Task {
            defer { isOpeningDocument = false }
            do {
                let url = try await DocumentPreviewStore.download(document)
                previewItem = DocumentPreviewItem(url: url, title: document.title)
            } catch {
                previewError = "The document could not be opened. Check your connection and try again."
            }
        }
    }

    private func priorityLabel(_ priority: Int) -> String {
        switch priority {
        case 3: "High"
        case 2: "Normal"
        default: "Low"
        }
    }

    private func formattedDate(_ value: String) -> String {
        guard let date = ISODateParser.parse(value) else { return value }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

private struct TaskEditSheet: View {
    @ObservedObject var viewModel: TasksViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var didSave = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Task") {
                    TextField("Title", text: $viewModel.formTitle)
                        .textInputAutocapitalization(.sentences)
                    TextField("Notes", text: $viewModel.formDescription, axis: .vertical)
                        .lineLimit(2...6)

                    Picker("Category", selection: $viewModel.formCategory) {
                        ForEach(viewModel.categories, id: \.self) { category in
                            Text(category.capitalized).tag(category)
                        }
                    }

                    Picker("Priority", selection: $viewModel.formPriority) {
                        Text("Low").tag(1)
                        Text("Normal").tag(2)
                        Text("High").tag(3)
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    Toggle(
                        "Has due date",
                        isOn: Binding(
                            get: { viewModel.formHasDueDate },
                            set: { viewModel.setFormHasDueDate($0) }
                        )
                    )
                    if viewModel.formHasDueDate {
                        DatePicker("Due", selection: $viewModel.formDueDate)
                    }
                    Picker(
                        "Repeat",
                        selection: Binding(
                            get: { viewModel.formRecurrence },
                            set: { viewModel.setFormRecurrence($0) }
                        )
                    ) {
                        ForEach(TaskRecurrenceOption.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    Toggle("Hide until", isOn: $viewModel.formShowEarly)
                    if viewModel.formShowEarly {
                        DatePicker("Hide until", selection: $viewModel.formActionableFrom)
                    }
                } header: {
                    Text("When")
                } footer: {
                    if viewModel.formRecurrence != .never {
                        Text("Repeats from the due date.")
                    }
                }

                Section("Who") {
                    if viewModel.familyMembers.isEmpty {
                        Text("No family members available")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(viewModel.familyMembers) { member in
                            Toggle(member.name, isOn: assigneeBinding(member.id))
                        }
                    }
                }

                TaskDocumentAttachmentSection(document: $viewModel.formSourceDocument)

                if let error = viewModel.errorMessage {
                    Section {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Edit Task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        viewModel.cancelEditing()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            if await viewModel.updateTask() {
                                didSave = true
                                dismiss()
                            }
                        }
                    }
                    .disabled(
                        viewModel.formTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || viewModel.isLoading
                    )
                }
            }
            .task {
                if viewModel.familyMembers.isEmpty {
                    await viewModel.loadFamilyMembers()
                }
            }
            .onDisappear {
                if !didSave {
                    viewModel.cancelEditing()
                }
            }
        }
    }

    private func assigneeBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { viewModel.selectedAssignees.contains(id) },
            set: { selected in
                if selected {
                    viewModel.selectedAssignees.insert(id)
                } else {
                    viewModel.selectedAssignees.remove(id)
                }
            }
        )
    }
}

#Preview {
    TasksView()
}
