import Foundation
import SwiftUI
import SwiftData
import os

private let tasksLocalStateLogger = Logger(
    subsystem: "org.example.hausklar",
    category: "TasksLocalState"
)

// DTOs are now in DTOs/TaskDTOs.swift

enum TaskRecurrenceOption: String, CaseIterable, Identifiable {
    case never
    case daily
    case weekly
    case monthly
    case yearly

    var id: Self { self }

    var title: String {
        switch self {
        case .never: "Never"
        case .daily: "Every day"
        case .weekly: "Every week"
        case .monthly: "Every month"
        case .yearly: "Every year"
        }
    }

    init(rule: String?) {
        let value = rule?.uppercased() ?? ""
        if value.contains("FREQ=DAILY") { self = .daily }
        else if value.contains("FREQ=WEEKLY") { self = .weekly }
        else if value.contains("FREQ=MONTHLY") { self = .monthly }
        else if value.contains("FREQ=YEARLY") { self = .yearly }
        else { self = .never }
    }

    func rule(for dueDate: Date, preserving current: String? = nil) -> String? {
        if self != .never,
           let current,
           TaskRecurrenceOption(rule: current) == self {
            return current
        }
        switch self {
        case .never:
            return nil
        case .daily:
            return "FREQ=DAILY"
        case .weekly:
            let symbols = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"]
            let weekday = Calendar.current.component(.weekday, from: dueDate)
            return "FREQ=WEEKLY;BYDAY=\(symbols[max(0, min(weekday - 1, 6))])"
        case .monthly:
            return "FREQ=MONTHLY"
        case .yearly:
            return "FREQ=YEARLY"
        }
    }
}

/// Request body for creating a new task.
struct TaskCreateRequestBody: Encodable, Equatable {
    let id: String
    let title: String
    let description: String?
    let category: String
    let priority: Int
    let dueDate: String?
    let recurrenceRule: String?
    let actionableFrom: String?
    let assignees: [AssigneeInput]?
    let sourceDocumentId: String?
}

/// A sparse task update. Only fields the user changed are encoded; changed
/// optional values encode as JSON null when the user explicitly clears them.
struct TaskUpdateRequestBody: Encodable, Equatable {
    enum Field: Hashable {
        case title, description, assignedTo, category, priority, dueDate
        case recurrenceRule, actionableFrom, assignees, sourceDocumentId
    }

    let title: String
    let description: String?
    let assignedTo: String?
    let category: String
    let priority: Int
    let dueDate: String?
    let recurrenceRule: String?
    let actionableFrom: String?
    let assignees: [AssigneeInput]?
    let sourceDocumentId: String?
    let includedFields: Set<Field>

    var hasChanges: Bool { !includedFields.isEmpty }
    var updatesAssignees: Bool { includedFields.contains(.assignees) }

    enum CodingKeys: String, CodingKey {
        case title, description, assignedTo, category, priority, dueDate
        case recurrenceRule, actionableFrom, assignees, sourceDocumentId
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if includedFields.contains(.title) {
            try container.encode(title, forKey: .title)
        }
        if includedFields.contains(.description) {
            try container.encode(description, forKey: .description)
        }
        if includedFields.contains(.category) {
            try container.encode(category, forKey: .category)
        }
        if includedFields.contains(.priority) {
            try container.encode(priority, forKey: .priority)
        }
        if includedFields.contains(.dueDate) {
            try container.encode(dueDate, forKey: .dueDate)
        }
        if includedFields.contains(.recurrenceRule) {
            try container.encode(recurrenceRule, forKey: .recurrenceRule)
        }
        if includedFields.contains(.actionableFrom) {
            try container.encode(actionableFrom, forKey: .actionableFrom)
        }
        if includedFields.contains(.assignedTo) {
            try container.encode(assignedTo, forKey: .assignedTo)
        }
        if includedFields.contains(.assignees) {
            try container.encode(assignees ?? [], forKey: .assignees)
        }
        if includedFields.contains(.sourceDocumentId) {
            try container.encode(sourceDocumentId, forKey: .sourceDocumentId)
        }
    }
}

struct TaskQuerySignature: Equatable {
    let category: String?
}

typealias TaskListLoader = ([URLQueryItem]) async throws -> [TaskDTO]
typealias TaskCreator = (TaskCreateRequestBody) async throws -> TaskDTO
typealias TaskUpdater = (String, TaskUpdateRequestBody) async throws -> TaskDTO
typealias TaskCompleter = (String) async throws -> TaskDTO
typealias TaskDeleter = (String) async throws -> Void

private enum DurableTaskError: LocalizedError {
    case duplicateLocalRecord
    case invalidLocalRecord

    var errorDescription: String? {
        switch self {
        case .duplicateLocalRecord:
            "More than one local task has the same identifier."
        case .invalidLocalRecord:
            "The task could not be represented safely on this device."
        }
    }
}

/// ViewModel for the Tasks screen. Manages task loading, creation, completion, and deletion.
@MainActor
final class TasksViewModel: ObservableObject {

    // MARK: - Published State

    @Published var tasks: [TaskDTO] = []
    @Published var selectedCategory: String? = nil
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var showingAddTask = false

    // MARK: - Family Members

    @Published var familyMembers: [FamilyMemberDTO] = []
    @Published var selectedAssignees: Set<String> = []
    @Published var assigneeFilterId: String?
    @Published var assigneeFilterName: String?

    // MARK: - Form Fields

    @Published var formTitle = ""
    @Published var formDescription = ""
    @Published var formCategory = "other"
    @Published var formPriority = 2
    @Published var formDueDate = Date()
    @Published var formHasDueDate = false
    @Published var formRecurrence: TaskRecurrenceOption = .never
    @Published var formShowEarly = false
    @Published var formActionableFrom = Date()
    @Published var formSourceDocument: SourceDocumentDTO? {
        didSet {
            if !isSettingFormState {
                formSourceDocumentTouched = true
            }
        }
    }

    // MARK: - Constants

    let categories = ["bins", "household", "shopping", "admin", "other"]
    private let syncManager: SyncManager
    private let taskListLoader: TaskListLoader
    private let taskCreator: TaskCreator
    private let taskUpdater: TaskUpdater
    private let taskCompleter: TaskCompleter
    private let taskDeleter: TaskDeleter
    private var modelContext: ModelContext?
    private var pendingCreateRequest: TaskCreateRequestBody?
    private var taskBeingEdited: TaskDTO?
    private var isSettingFormState = false
    private var formSourceDocumentTouched = false
    private var loadGeneration = 0

    var querySignature: TaskQuerySignature {
        TaskQuerySignature(category: selectedCategory)
    }

    init(
        assigneeFilterId: String? = nil,
        assigneeFilterName: String? = nil,
        taskListLoader: @escaping TaskListLoader = { queryItems in
            try await APIClient.shared.get("/tasks/", queryItems: queryItems)
        },
        taskCreator: @escaping TaskCreator = { body in
            try await APIClient.shared.post("/tasks/", body: body)
        },
        taskUpdater: @escaping TaskUpdater = { taskId, body in
            try await APIClient.shared.put("/tasks/\(taskId)", body: body)
        },
        taskCompleter: @escaping TaskCompleter = { taskId in
            try await APIClient.shared.patch("/tasks/\(taskId)/complete", body: EmptyBody())
        },
        taskDeleter: @escaping TaskDeleter = { taskId in
            try await APIClient.shared.delete("/tasks/\(taskId)")
        },
        syncManager: SyncManager? = nil
    ) {
        self.assigneeFilterId = assigneeFilterId
        self.assigneeFilterName = assigneeFilterName
        self.taskListLoader = taskListLoader
        self.taskCreator = taskCreator
        self.taskUpdater = taskUpdater
        self.taskCompleter = taskCompleter
        self.taskDeleter = taskDeleter
        self.syncManager = syncManager ?? .shared
    }

    func bindModelContext(_ context: ModelContext) {
        modelContext = context
        loadLocalTasks()
    }

    func selectCategory(_ category: String?) {
        selectedCategory = category
    }

    // MARK: - API Actions

    /// Loads family members for the assignee picker.
    func loadFamilyMembers() async {
        do {
            let result: [FamilyMemberDTO] = try await APIClient.shared.get("/family/members")
            familyMembers = result
        } catch {
            // Non-blocking — picker just won't show members
        }
    }

    /// Loads enough task history for the screen to present open, waiting, and
    /// recently completed work together without another round trip.
    func loadTasks() async {
        loadGeneration &+= 1
        let generation = loadGeneration
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            var queryItems = [
                URLQueryItem(name: "order", value: "attention"),
                URLQueryItem(name: "limit", value: "200"),
            ]

            if let category = selectedCategory {
                queryItems.append(URLQueryItem(name: "category", value: category))
            }
            if let assigneeFilterId, !assigneeFilterId.isEmpty {
                queryItems.append(URLQueryItem(name: "assigned_to", value: assigneeFilterId))
            }

            let result = try await taskListLoader(queryItems)
            guard generation == loadGeneration else { return }
            tasks = mergePendingTasks(with: result)
        } catch let error as APIError {
            guard generation == loadGeneration else { return }
            errorMessage = error.errorDescription
        } catch {
            guard generation == loadGeneration else { return }
            errorMessage = "Failed to load tasks. Please try again.".localized
        }

        if generation == loadGeneration {
            isLoading = false
        }
    }

    /// Creates a new task using the current form field values.
    func createTask() async {
        guard !formTitle.trimmingCharacters(in: .whitespaces).isEmpty else {
            errorMessage = "Please enter a task title.".localized
            return
        }
        guard formRecurrence == .never || formHasDueDate else {
            errorMessage = "Choose a due date for the repeating task.".localized
            return
        }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        let dueDateString: String? = formHasDueDate ? ISODateParser.stringNoFractional(from: formDueDate) : nil
        let recurrenceRule = formRecurrence.rule(for: formDueDate)
        let actionableFromString: String? = formShowEarly ? ISODateParser.stringNoFractional(from: formActionableFrom) : nil
        let descriptionValue: String? = formDescription.trimmingCharacters(in: .whitespaces).isEmpty ? nil : formDescription

        // Build assignees from selected family members
        let assigneeInputs: [AssigneeInput]? = selectedAssignees.isEmpty ? nil : selectedAssignees.sorted().compactMap { memberId in
            guard let member = familyMembers.first(where: { $0.id == memberId }) else { return nil }
            return AssigneeInput(assigneeId: member.id, assigneeType: member.memberType)
        }

        let candidate = TaskCreateRequestBody(
            id: pendingCreateRequest?.id ?? UUID().uuidString,
            title: formTitle.trimmingCharacters(in: .whitespaces),
            description: descriptionValue,
            category: formCategory,
            priority: formPriority,
            dueDate: dueDateString,
            recurrenceRule: recurrenceRule,
            actionableFrom: actionableFromString,
            assignees: assigneeInputs,
            sourceDocumentId: formSourceDocument?.id
        )
        let body = candidate
        pendingCreateRequest = body
        guard let modelContext,
              let identityLease = syncManager.currentIdentityLease else {
            errorMessage = "Task could not be saved securely on this device. Please try again.".localized
            return
        }
        let now = ISODateParser.stringNoFractional(from: Date())
        let optimisticAssignees = (body.assignees ?? []).map { input in
            TaskAssigneeDTO(
                id: "offline-\(body.id)-\(input.assigneeId)",
                assigneeId: input.assigneeId,
                assigneeType: input.assigneeType,
                assigneeName: familyMembers.first(where: { $0.id == input.assigneeId })?.name,
                completedAt: nil,
                completedBy: nil
            )
        }
        let optimistic = TaskDTO(
            id: body.id,
            title: body.title,
            description: body.description,
            assignedTo: nil,
            dueDate: body.dueDate,
            completedAt: nil,
            category: body.category,
            recurrenceRule: body.recurrenceRule,
            priority: body.priority,
            createdAt: now,
            updatedAt: now,
            createdBy: nil,
            actionableFrom: body.actionableFrom,
            assignees: optimisticAssignees,
            sourceDocumentId: body.sourceDocumentId,
            sourceDocument: formSourceDocument
        )
        let outcome = await syncManager.performDurableMutation(
            modelContext: modelContext,
            actionID: body.id,
            operation: .create,
            tableName: "tasks",
            recordId: body.id,
            payload: [
                "title": body.title,
                "description": body.description ?? NSNull(),
                "category": body.category,
                "priority": body.priority,
                "due_date": body.dueDate ?? NSNull(),
                "recurrence_rule": body.recurrenceRule ?? NSNull(),
                "actionable_from": body.actionableFrom ?? NSNull(),
                "source_document_id": body.sourceDocumentId ?? NSNull(),
                "assignees": (body.assignees ?? []).map {
                    [
                        "assignee_id": $0.assigneeId,
                        "assignee_type": $0.assigneeType,
                    ]
                },
            ],
            expectedIdentityLease: identityLease
        ) {
            try Self.insertTask(optimistic, in: modelContext)
        } onStaged: { [weak self] in
            self?.replaceTask(optimistic)
            self?.resetForm()
            self?.showingAddTask = false
        } transport: { [taskCreator] in
            try await taskCreator(body)
        } validateAcknowledgement: { value in
            value.id == body.id ? nil : "The server acknowledged a different task."
        } applyAcknowledgedResult: { value in
            try Self.upsertTask(value, in: modelContext)
        }

        switch outcome {
        case .acknowledged(let value):
            replaceTask(value)
            await loadTasks()
        case .queued, .transportFailed(status: .pending, error: _):
            errorMessage = "No connection. Task queued and will sync when online.".localized
        case .transportFailed(status: .retryable, error: _):
            errorMessage = "Task was saved on this device and will retry automatically.".localized
        case .transportFailed(status: .permanent, error: _):
            errorMessage = "Task was saved locally, but the server rejected it. Review the offline queue.".localized
        case .acknowledgementPending:
            errorMessage = "Task was saved. Its server receipt will replay safely.".localized
        case .stagingFailed:
            errorMessage = "This task was not saved, so nothing was sent. Please try again.".localized
        case .transportFailed(status: nil, error: _),
             .transportFailed(status: .directAttempt, error: _),
             .transportFailed(status: .inFlight, error: _),
             .transportFailed(status: .syncing, error: _),
             .transportFailed(status: .synced, error: _),
             .transportFailed(status: .failed, error: _):
            errorMessage = "Task was saved locally. Its exact replay state will recover automatically.".localized
        }
    }

    /// Marks a task as completed.
    func completeTask(_ id: String) async {
        guard let original = tasks.first(where: { $0.id == id }) else { return }
        if original.isManaged {
            do {
                _ = try await taskCompleter(id)
                await loadTasks()
            } catch let error as APIError {
                if case .networkError = error {
                    errorMessage = original.isLibraryManaged
                        ? "Reconnect to complete this library task.".localized
                        : "Reconnect to complete this Finance-managed task.".localized
                } else {
                    errorMessage = error.errorDescription
                }
            } catch {
                errorMessage = "Failed to complete task. Please try again.".localized
            }
            return
        }
        guard let modelContext,
              let identityLease = syncManager.currentIdentityLease else {
            errorMessage = "Task could not be saved securely on this device. Please try again.".localized
            return
        }
        let completedAt = ISODateParser.stringNoFractional(from: Date())
        let optimistic = completing(original, at: completedAt)
        let outcome = await syncManager.performDurableMutation(
            modelContext: modelContext,
            actionID: UUID().uuidString,
            operation: .update,
            tableName: "tasks",
            recordId: id,
            payload: ["completed_at": completedAt],
            expectedIdentityLease: identityLease
        ) {
            try Self.upsertTask(optimistic, in: modelContext)
        } onStaged: { [weak self] in
            self?.replaceTask(optimistic)
        } transport: { [taskCompleter] in
            try await taskCompleter(id)
        } validateAcknowledgement: { value in
            value.id == id ? nil : "The server acknowledged a different task."
        } applyAcknowledgedResult: { value in
            try Self.upsertTask(value, in: modelContext)
        }

        switch outcome {
        case .acknowledged(let value):
            replaceTask(value)
            await loadTasks()
        case .queued, .transportFailed(status: .pending, error: _):
            errorMessage = "No connection. Completion queued for sync.".localized
        case .transportFailed(status: .retryable, error: _):
            errorMessage = "Completion was saved on this device and will retry automatically.".localized
        case .transportFailed(status: .permanent, error: _):
            errorMessage = "Completion was saved locally, but the server rejected it. Review the offline queue.".localized
        case .acknowledgementPending:
            errorMessage = "Completion was saved. Its server receipt will replay safely.".localized
        case .stagingFailed:
            errorMessage = "This completion was not saved, so nothing was sent. Please try again.".localized
        case .transportFailed(status: nil, error: _),
             .transportFailed(status: .directAttempt, error: _),
             .transportFailed(status: .inFlight, error: _),
             .transportFailed(status: .syncing, error: _),
             .transportFailed(status: .synced, error: _),
             .transportFailed(status: .failed, error: _):
            errorMessage = "Completion was saved locally. Its exact replay state will recover automatically.".localized
        }
    }

    /// Reopens a completed task. The server also restores its assignee state.
    func reopenTask(_ id: String) async {
        do {
            let _: TaskDTO = try await APIClient.shared.patch("/tasks/\(id)/reopen", body: EmptyBody())
            await loadTasks()
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "Failed to reopen task. Please try again.".localized
        }
    }

    /// Marks one person's assignment as complete (does not complete the overall task).
    func completeTaskForPerson(taskId: String, assigneeId: String) async {
        if tasks.first(where: { $0.id == taskId })?.isManaged == true {
            errorMessage = "Complete this managed task as a whole.".localized
            return
        }
        do {
            let _: TaskDTO = try await APIClient.shared.patch("/tasks/\(taskId)/complete/\(assigneeId)", body: EmptyBody())
            await loadTasks()
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "Failed to complete assignment. Please try again.".localized
        }
    }

    /// Deletes a task by its ID.
    func deleteTask(_ id: String) async {
        guard let task = tasks.first(where: { $0.id == id }) else { return }
        if !canDeleteTask(task) {
            errorMessage = task.isManaged
                ? "This task is managed in \(task.managedLocationLabel ?? "its source").".localized
                : "This task is managed from the council schedule.".localized
            return
        }
        guard let modelContext,
              let identityLease = syncManager.currentIdentityLease else {
            errorMessage = "Task deletion could not be saved securely on this device. Please try again.".localized
            return
        }
        let outcome: SyncManager.DurableMutationOutcome<Void> = await syncManager.performDurableMutation(
            modelContext: modelContext,
            actionID: UUID().uuidString,
            operation: .delete,
            tableName: "tasks",
            recordId: id,
            payload: nil,
            expectedIdentityLease: identityLease
        ) {
            try Self.markTaskDeleted(task, in: modelContext)
        } onStaged: { [weak self] in
            self?.tasks.removeAll { $0.id == id }
        } transport: { [taskDeleter] in
            try await taskDeleter(id)
        } applyAcknowledgedResult: { _ in }

        switch outcome {
        case .acknowledged:
            await loadTasks()
        case .queued, .transportFailed(status: .pending, error: _):
            errorMessage = "No connection. Deletion queued for sync.".localized
        case .transportFailed(status: .retryable, error: _):
            errorMessage = "Deletion was saved on this device and will retry automatically.".localized
        case .transportFailed(status: .permanent, error: _):
            errorMessage = "Deletion was saved locally, but the server rejected it. Review the offline queue.".localized
        case .acknowledgementPending:
            errorMessage = "Deletion was saved. Its server receipt will replay safely.".localized
        case .stagingFailed:
            errorMessage = "This deletion was not saved, so nothing was sent. Please try again.".localized
        case .transportFailed(status: nil, error: _),
             .transportFailed(status: .directAttempt, error: _),
             .transportFailed(status: .inFlight, error: _),
             .transportFailed(status: .syncing, error: _),
             .transportFailed(status: .synced, error: _),
             .transportFailed(status: .failed, error: _):
            errorMessage = "Deletion was saved locally. Its exact replay state will recover automatically.".localized
        }
    }

    func canDeleteTask(_ task: TaskDTO) -> Bool {
        task.createdBy != "bin-scraper" && !task.isManaged
    }

    func canEditTask(_ task: TaskDTO) -> Bool {
        task.createdBy != "bin-scraper" && !task.isManaged
    }

    func taskIsVisibleInMine(_ task: TaskDTO, currentUserId: String) -> Bool {
        if task.createdBy == "bin-scraper" {
            return true
        }
        let hasAssignments = !task.assignees.isEmpty || task.assignedTo != nil
        return task.assignees.contains { $0.assigneeId == currentUserId }
            || task.assignedTo == currentUserId
            || task.createdBy == currentUserId
            || !hasAssignments
    }

    // MARK: - Editing

    func beginEditing(_ task: TaskDTO) {
        isSettingFormState = true
        defer {
            isSettingFormState = false
            formSourceDocumentTouched = false
        }
        taskBeingEdited = task
        formTitle = task.title
        formDescription = task.description ?? ""
        formCategory = task.category ?? "other"
        formPriority = task.priority
        formHasDueDate = task.dueDate != nil
        formDueDate = task.dueDate.flatMap(ISODateParser.parse) ?? Date()
        formRecurrence = TaskRecurrenceOption(rule: task.recurrenceRule)
        formShowEarly = task.actionableFrom != nil
        formActionableFrom = task.actionableFrom.flatMap(ISODateParser.parse) ?? Date()
        selectedAssignees = Set(task.assignees.map(\.assigneeId))
        if let assignedTo = task.assignedTo {
            selectedAssignees.insert(assignedTo)
        }
        formSourceDocument = task.sourceDocument
        errorMessage = nil
    }

    func cancelEditing() {
        resetForm()
        errorMessage = nil
    }

    @discardableResult
    func updateTask() async -> Bool {
        guard let original = taskBeingEdited else {
            errorMessage = "Choose a task to edit.".localized
            return false
        }
        guard !formTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "Please enter a task title.".localized
            return false
        }
        guard canEditTask(original) else {
            errorMessage = original.isManaged
                ? "This task is managed in \(original.managedLocationLabel ?? "its source").".localized
                : "This task is managed from the council schedule.".localized
            return false
        }
        guard formRecurrence == .never || formHasDueDate else {
            errorMessage = "Choose a due date for the repeating task.".localized
            return false
        }

        let assigneeInputs = selectedAssignees.sorted().compactMap { assigneeInput(
            for: $0,
            original: original
        ) }
        var originalAssigneeIds = Set(original.assignees.map(\.assigneeId))
        if let assignedTo = original.assignedTo {
            originalAssigneeIds.insert(assignedTo)
        }
        let updatesAssignees = originalAssigneeIds != selectedAssignees
        let title = formTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = normalizedOptional(formDescription)
        let category = formCategory
        let priority = formPriority
        let dueDate = formDateValue(
            enabled: formHasDueDate,
            date: formDueDate,
            original: original.dueDate
        )
        let dueDateChanged = dueDate != original.dueDate
        let recurrenceRule = formRecurrence.rule(
            for: formDueDate,
            preserving: dueDateChanged ? nil : original.recurrenceRule
        )
        let actionableFrom = formDateValue(
            enabled: formShowEarly,
            date: formActionableFrom,
            original: original.actionableFrom
        )
        let sourceDocumentId = formSourceDocument?.id
        var includedFields: Set<TaskUpdateRequestBody.Field> = []
        if title != original.title { includedFields.insert(.title) }
        if description != normalizedOptional(original.description ?? "") {
            includedFields.insert(.description)
        }
        if category != (original.category ?? "other") { includedFields.insert(.category) }
        if priority != original.priority { includedFields.insert(.priority) }
        if dueDate != original.dueDate { includedFields.insert(.dueDate) }
        if recurrenceRule != original.recurrenceRule {
            includedFields.insert(.recurrenceRule)
        }
        if actionableFrom != original.actionableFrom {
            includedFields.insert(.actionableFrom)
        }
        if updatesAssignees {
            includedFields.formUnion([.assignedTo, .assignees])
        }
        if formSourceDocumentTouched && sourceDocumentId != original.sourceDocumentId {
            includedFields.insert(.sourceDocumentId)
        }
        let body = TaskUpdateRequestBody(
            title: title,
            description: description,
            assignedTo: nil,
            category: category,
            priority: priority,
            dueDate: dueDate,
            recurrenceRule: recurrenceRule,
            actionableFrom: actionableFrom,
            assignees: updatesAssignees ? assigneeInputs : nil,
            sourceDocumentId: sourceDocumentId,
            includedFields: includedFields
        )

        guard body.hasChanges else {
            resetForm()
            return true
        }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        guard let modelContext,
              let identityLease = syncManager.currentIdentityLease else {
            errorMessage = "Task changes could not be saved securely on this device. Please try again.".localized
            return false
        }
        let optimistic = optimisticTask(from: original, applying: body)
        let outcome = await syncManager.performDurableMutation(
            modelContext: modelContext,
            actionID: UUID().uuidString,
            operation: .update,
            tableName: "tasks",
            recordId: original.id,
            payload: offlinePayload(for: body),
            expectedIdentityLease: identityLease
        ) {
            try Self.upsertTask(optimistic, in: modelContext)
        } onStaged: { [weak self] in
            self?.replaceTask(optimistic)
            self?.resetForm()
        } transport: { [taskUpdater] in
            try await taskUpdater(original.id, body)
        } validateAcknowledgement: { value in
            value.id == original.id ? nil : "The server acknowledged a different task."
        } applyAcknowledgedResult: { value in
            try Self.upsertTask(value, in: modelContext)
        }

        switch outcome {
        case .acknowledged(let value):
            replaceTask(value)
            NotificationCenter.default.post(name: .taskDataChanged, object: nil)
            HapticManager.success()
            return true
        case .queued, .transportFailed(status: .pending, error: _):
            errorMessage = "No connection. Changes queued and will sync when online.".localized
            return true
        case .transportFailed(status: .retryable, error: _):
            errorMessage = "Changes were saved on this device and will retry automatically.".localized
            return true
        case .transportFailed(status: .permanent, error: _):
            errorMessage = "Changes were saved locally, but the server rejected them. Review the offline queue.".localized
            return true
        case .acknowledgementPending:
            errorMessage = "Changes were saved. Their server receipt will replay safely.".localized
            return true
        case .stagingFailed:
            errorMessage = "These changes were not saved, so nothing was sent. Please try again.".localized
            return false
        case .transportFailed(status: nil, error: _),
             .transportFailed(status: .directAttempt, error: _),
             .transportFailed(status: .inFlight, error: _),
             .transportFailed(status: .syncing, error: _),
             .transportFailed(status: .synced, error: _),
             .transportFailed(status: .failed, error: _):
            errorMessage = "Changes were saved locally. Their exact replay state will recover automatically.".localized
            return true
        }
    }

    private func assigneeInput(for id: String, original: TaskDTO) -> AssigneeInput? {
        if let member = familyMembers.first(where: { $0.id == id }) {
            return AssigneeInput(assigneeId: id, assigneeType: member.memberType)
        }
        if let assignment = original.assignees.first(where: { $0.assigneeId == id }) {
            return AssigneeInput(assigneeId: id, assigneeType: assignment.assigneeType)
        }
        if original.assignedTo == id {
            return AssigneeInput(assigneeId: id, assigneeType: "user")
        }
        return nil
    }

    private func offlinePayload(for body: TaskUpdateRequestBody) -> [String: Any] {
        var payload: [String: Any] = [:]
        if body.includedFields.contains(.title) { payload["title"] = body.title }
        if body.includedFields.contains(.description) {
            payload["description"] = body.description ?? NSNull()
        }
        if body.includedFields.contains(.category) { payload["category"] = body.category }
        if body.includedFields.contains(.priority) { payload["priority"] = body.priority }
        if body.includedFields.contains(.dueDate) {
            payload["due_date"] = body.dueDate ?? NSNull()
        }
        if body.includedFields.contains(.recurrenceRule) {
            payload["recurrence_rule"] = body.recurrenceRule ?? NSNull()
        }
        if body.includedFields.contains(.actionableFrom) {
            payload["actionable_from"] = body.actionableFrom ?? NSNull()
        }
        if body.includedFields.contains(.sourceDocumentId) {
            payload["source_document_id"] = body.sourceDocumentId ?? NSNull()
        }
        if body.includedFields.contains(.assignedTo) {
            payload["assigned_to"] = NSNull()
        }
        if body.includedFields.contains(.assignees) {
            payload["assignees"] = (body.assignees ?? []).map {
                ["assignee_id": $0.assigneeId, "assignee_type": $0.assigneeType]
            }
        }
        return payload
    }

    private func optimisticTask(
        from original: TaskDTO,
        applying body: TaskUpdateRequestBody
    ) -> TaskDTO {
        let updatedAt = ISODateParser.stringNoFractional(from: Date())
        let assignments = (body.assignees ?? []).map { input in
            if let existing = original.assignees.first(where: {
                $0.assigneeId == input.assigneeId && $0.assigneeType == input.assigneeType
            }) {
                return existing
            }
            return TaskAssigneeDTO(
                id: "offline-\(original.id)-\(input.assigneeId)",
                assigneeId: input.assigneeId,
                assigneeType: input.assigneeType,
                assigneeName: familyMembers.first(where: { $0.id == input.assigneeId })?.name,
                completedAt: nil,
                completedBy: nil
            )
        }
        return TaskDTO(
            id: original.id,
            title: body.includedFields.contains(.title) ? body.title : original.title,
            description: body.includedFields.contains(.description)
                ? body.description
                : original.description,
            assignedTo: body.includedFields.contains(.assignedTo) ? nil : original.assignedTo,
            dueDate: body.includedFields.contains(.dueDate) ? body.dueDate : original.dueDate,
            completedAt: original.completedAt,
            category: body.includedFields.contains(.category) ? body.category : original.category,
            recurrenceRule: body.includedFields.contains(.recurrenceRule)
                ? body.recurrenceRule
                : original.recurrenceRule,
            priority: body.includedFields.contains(.priority) ? body.priority : original.priority,
            createdAt: original.createdAt,
            updatedAt: updatedAt,
            createdBy: original.createdBy,
            actionableFrom: body.includedFields.contains(.actionableFrom)
                ? body.actionableFrom
                : original.actionableFrom,
            assignees: body.updatesAssignees ? assignments : original.assignees,
            sourceDocumentId: body.includedFields.contains(.sourceDocumentId)
                ? body.sourceDocumentId
                : original.sourceDocumentId,
            sourceDocument: body.includedFields.contains(.sourceDocumentId)
                ? formSourceDocument
                : original.sourceDocument
        )
    }

    private func completing(_ task: TaskDTO, at completedAt: String) -> TaskDTO {
        TaskDTO(
            id: task.id,
            title: task.title,
            description: task.description,
            assignedTo: task.assignedTo,
            dueDate: task.dueDate,
            completedAt: completedAt,
            category: task.category,
            recurrenceRule: task.recurrenceRule,
            priority: task.priority,
            createdAt: task.createdAt,
            updatedAt: completedAt,
            createdBy: task.createdBy,
            actionableFrom: task.actionableFrom,
            assignees: task.assignees,
            sourceDocumentId: task.sourceDocumentId,
            sourceDocument: task.sourceDocument,
            sourceEventId: task.sourceEventId,
            prepOccurrenceId: task.prepOccurrenceId,
            prepOccurrenceStart: task.prepOccurrenceStart,
            readOnly: task.readOnly,
            managedSource: task.managedSource
        )
    }

    private static func insertTask(_ task: TaskDTO, in modelContext: ModelContext) throws {
        let requestedID = task.id
        let matches = try modelContext.fetch(FetchDescriptor<FamilyTask>(
            predicate: #Predicate { $0.id == requestedID }
        ))
        guard matches.isEmpty else { throw DurableTaskError.duplicateLocalRecord }
        try upsertTask(task, in: modelContext)
    }

    private static func upsertTask(_ task: TaskDTO, in modelContext: ModelContext) throws {
        guard !task.id.isEmpty,
              !task.title.isEmpty,
              let createdAt = ISODateParser.parse(task.createdAt),
              let updatedAt = ISODateParser.parse(task.updatedAt),
              task.dueDate == nil || task.dueDate.flatMap(ISODateParser.parse) != nil,
              task.completedAt == nil || task.completedAt.flatMap(ISODateParser.parse) != nil else {
            throw DurableTaskError.invalidLocalRecord
        }
        let assigneeData = try JSONEncoder().encode(task.assignees)
        guard let assigneesJSON = String(data: assigneeData, encoding: .utf8) else {
            throw DurableTaskError.invalidLocalRecord
        }
        let requestedID = task.id
        let matches = try modelContext.fetch(FetchDescriptor<FamilyTask>(
            predicate: #Predicate { $0.id == requestedID }
        ))
        guard matches.count <= 1 else { throw DurableTaskError.duplicateLocalRecord }
        let item: FamilyTask
        if let existing = matches.first {
            item = existing
        } else {
            item = FamilyTask(id: task.id)
            modelContext.insert(item)
        }
        item.title = task.title
        item.taskDescription = task.description
        item.assignedTo = task.assignedTo
        item.dueDate = task.dueDate.flatMap(ISODateParser.parse)
        item.completedAt = task.completedAt.flatMap(ISODateParser.parse)
        item.category = task.category
        item.recurrenceRule = task.recurrenceRule
        item.priority = task.priority
        item.createdAt = createdAt
        item.updatedAt = updatedAt
        item.createdBy = task.createdBy
        item.deletedAt = nil
        item.assigneesJSON = assigneesJSON
    }

    private static func markTaskDeleted(
        _ task: TaskDTO,
        in modelContext: ModelContext
    ) throws {
        try upsertTask(task, in: modelContext)
        let requestedID = task.id
        let matches = try modelContext.fetch(FetchDescriptor<FamilyTask>(
            predicate: #Predicate { $0.id == requestedID }
        ))
        guard matches.count == 1, let item = matches.first else {
            throw DurableTaskError.invalidLocalRecord
        }
        let now = Date()
        item.deletedAt = now
        item.updatedAt = now
    }

    private func loadLocalTasks() {
        guard let modelContext else { return }
        do {
            let rows = try modelContext.fetch(FetchDescriptor<FamilyTask>(
                predicate: #Predicate { $0.deletedAt == nil },
                sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
            ))
            guard !rows.isEmpty else { return }
            let existingByID = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
            tasks = rows.map { taskDTO($0, preserving: existingByID[$0.id]) }
        } catch {
            errorMessage = "Saved tasks could not be loaded from this device.".localized
        }
    }

    private func mergePendingTasks(with remote: [TaskDTO]) -> [TaskDTO] {
        guard let modelContext else { return remote }
        do {
            let tableName = "tasks"
            let synced = OfflineStatus.synced
            let actions = try modelContext.fetch(FetchDescriptor<OfflineAction>(
                predicate: #Predicate {
                    $0.tableName == tableName && $0.status != synced
                },
                sortBy: [SortDescriptor(\.createdAt, order: .forward)]
            ))
            guard !actions.isEmpty else { return remote }
            let ids = Array(Set(actions.map(\.recordId)))
            let rows = try modelContext.fetch(FetchDescriptor<FamilyTask>(
                predicate: #Predicate { ids.contains($0.id) }
            ))
            let rowsByID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
            var merged = Dictionary(uniqueKeysWithValues: remote.map { ($0.id, $0) })
            let previous = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
            for id in ids {
                guard let latest = actions.last(where: { $0.recordId == id }) else { continue }
                if latest.operation == .delete {
                    merged[id] = nil
                } else if let row = rowsByID[id], row.deletedAt == nil {
                    merged[id] = taskDTO(
                        row,
                        preserving: previous[id] ?? merged[id]
                    )
                }
            }
            return Array(merged.values).sorted { $0.updatedAt > $1.updatedAt }
        } catch {
            return remote
        }
    }

    private func taskDTO(_ task: FamilyTask, preserving original: TaskDTO?) -> TaskDTO {
        let assignees: [TaskAssigneeDTO]
        if let json = task.assigneesJSON {
            do {
                guard let data = json.data(using: .utf8) else {
                    throw CocoaError(.fileReadInapplicableStringEncoding)
                }
                assignees = try JSONDecoder().decode([TaskAssigneeDTO].self, from: data)
            } catch {
                // Prefer the last verified server value over silently presenting
                // a corrupt local assignment as "nobody". Keep the task itself
                // available and make the repair need visible.
                assignees = original?.assignees ?? []
                errorMessage = "One saved task assignment could not be read. Refresh tasks before changing who it belongs to.".localized
                tasksLocalStateLogger.error(
                    "A local task assignment payload could not be decoded: \(error.localizedDescription, privacy: .private)"
                )
            }
        } else {
            assignees = original?.assignees ?? []
        }
        return TaskDTO(
            id: task.id,
            title: task.title,
            description: task.taskDescription,
            assignedTo: task.assignedTo,
            dueDate: task.dueDate.map(ISODateParser.stringNoFractional),
            completedAt: task.completedAt.map(ISODateParser.stringNoFractional),
            category: task.category,
            recurrenceRule: task.recurrenceRule,
            priority: task.priority,
            createdAt: ISODateParser.stringNoFractional(from: task.createdAt),
            updatedAt: ISODateParser.stringNoFractional(from: task.updatedAt),
            createdBy: task.createdBy,
            actionableFrom: original?.actionableFrom,
            assignees: assignees,
            sourceDocumentId: original?.sourceDocumentId,
            sourceDocument: original?.sourceDocument,
            sourceEventId: original?.sourceEventId,
            prepOccurrenceId: original?.prepOccurrenceId,
            prepOccurrenceStart: original?.prepOccurrenceStart,
            readOnly: original?.readOnly ?? false,
            managedSource: original?.managedSource
        )
    }

    private func replaceTask(_ task: TaskDTO) {
        if let index = tasks.firstIndex(where: { $0.id == task.id }) {
            tasks[index] = task
        } else {
            tasks.insert(task, at: 0)
        }
    }

    private func normalizedOptional(_ value: String) -> String? {
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    private func formDateValue(enabled: Bool, date: Date, original: String?) -> String? {
        guard enabled else { return nil }
        if let original,
           let originalDate = ISODateParser.parse(original),
           abs(originalDate.timeIntervalSince(date)) < 0.5 {
            return original
        }
        return ISODateParser.stringNoFractional(from: date)
    }

    func setFormHasDueDate(_ enabled: Bool) {
        formHasDueDate = enabled
        if !enabled {
            formRecurrence = .never
        }
    }

    func setFormRecurrence(_ recurrence: TaskRecurrenceOption) {
        formRecurrence = recurrence
        if recurrence != .never {
            formHasDueDate = true
        }
    }

    /// Resets all form fields to their default values.
    func resetForm() {
        isSettingFormState = true
        defer {
            isSettingFormState = false
            formSourceDocumentTouched = false
        }
        formTitle = ""
        formDescription = ""
        formCategory = "other"
        formPriority = 2
        formDueDate = Date()
        formHasDueDate = false
        formRecurrence = .never
        formShowEarly = false
        formActionableFrom = Date()
        formSourceDocument = nil
        selectedAssignees = []
        pendingCreateRequest = nil
        taskBeingEdited = nil
    }
}
