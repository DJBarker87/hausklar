import SwiftUI

private enum LinkedDocumentRecord: Identifiable {
    case event(LinkedDocumentEventDTO)
    case task(LinkedDocumentTaskDTO)

    var id: String {
        switch self {
        case .event(let event): "event-\(event.id)"
        case .task(let task): "task-\(task.id)"
        }
    }
}

struct DocumentDetailView: View {
    @State private var document: DocumentDTO
    @ObservedObject var viewModel: DocumentsViewModel
    let onPreview: (URL) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isDownloading = false
    @State private var showingDeleteConfirmation = false
    @State private var showingMetadataEditor = false
    @State private var showingExistingRecordPicker = false
    @State private var addingAction = false
    @State private var linkedRecord: LinkedDocumentRecord?

    init(
        document: DocumentDTO,
        viewModel: DocumentsViewModel,
        onPreview: @escaping (URL) -> Void
    ) {
        _document = State(initialValue: document)
        self.viewModel = viewModel
        self.onPreview = onPreview
    }

    var body: some View {
        List {
            Section {
                Button {
                    openDocument()
                } label: {
                    HStack {
                        Label("Open Document", systemImage: "doc.text.magnifyingglass")
                        Spacer()
                        if isDownloading { ProgressView() }
                    }
                }
                .disabled(isDownloading)
            }

            Section("Filed for") {
                if document.people.isEmpty {
                    Text("Everyone")
                } else {
                    ForEach(document.people) { person in
                        Label(
                            person.personName,
                            systemImage: person.personType == "child" ? "figure.child" : "person.example_e864bc8d"
                        )
                    }
                }
            }

            if let notes = document.notes, !notes.isEmpty {
                Section("Notes") {
                    Text(notes)
                        .textSelection(.enabled)
                }
            }

            Section("Details") {
                LabeledContent("Category", value: document.category.title)
                LabeledContent("Document date", value: detailDateLabel)
                LabeledContent("Pages", value: "\(document.pageCount)")
                LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: Int64(document.fileSize), countStyle: .file))
                Button {
                    showingMetadataEditor = true
                } label: {
                    Label("Edit details", systemImage: "pencil")
                }
            }

            if !(document.linkedEvents ?? []).isEmpty || !(document.linkedTasks ?? []).isEmpty {
                Section("Linked calendar and tasks") {
                    ForEach(document.linkedEvents ?? []) { event in
                        HStack(spacing: 8) {
                            Button {
                                linkedRecord = .event(event)
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "calendar")
                                        .foregroundStyle(.blue)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(event.title)
                                            .foregroundStyle(.primary)
                                        Text(linkedEventDate(event))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                                .frame(minHeight: 44)
                            }
                            .buttonStyle(.plain)

                            Menu {
                                Button("Unlink from document", role: .destructive) {
                                    unlinkEvent(event.id)
                                }
                            } label: {
                                Image(systemName: "ellipsis")
                                    .frame(width: 44, height: 44)
                            }
                            .accessibilityLabel("More options for \(event.title)")
                        }
                    }

                    ForEach(document.linkedTasks ?? []) { task in
                        HStack(spacing: 8) {
                            Button {
                                linkedRecord = .task(task)
                            } label: {
                                HStack(spacing: 12) {
                                    Image(
                                        systemName: task.completedAt == nil
                                            ? "checkmark.circle" : "checkmark.circle.fill"
                                    )
                                    .foregroundStyle(task.completedAt == nil ? Color.orange : Color.green)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(task.title)
                                            .foregroundStyle(.primary)
                                        Text(linkedTaskStatus(task))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                                .frame(minHeight: 44)
                            }
                            .buttonStyle(.plain)

                            Menu {
                                Button("Unlink from document", role: .destructive) {
                                    unlinkTask(task.id)
                                }
                            } label: {
                                Image(systemName: "ellipsis")
                                    .frame(width: 44, height: 44)
                            }
                            .accessibilityLabel("More options for \(task.title)")
                        }
                    }
                }
            }

            Section("Actions") {
                Button {
                    showingExistingRecordPicker = true
                } label: {
                    Label("Attach to existing event or task", systemImage: "paperclip")
                }
                .accessibilityIdentifier("documentAttachExistingRecord")

                Button {
                    addingAction = true
                } label: {
                    Label("Create new event or task", systemImage: "plus.circle")
                }

                if visibleActions.isEmpty {
                    Text("No actions")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(visibleActions) { suggestion in
                        HStack {
                            Image(
                                systemName: suggestion.resultStatus == "completed"
                                    ? "checkmark.circle.fill"
                                    : suggestion.kind.icon
                            )
                            .foregroundStyle(suggestion.resultStatus == "completed" ? Color.green : Color.accentColor)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(suggestion.title)
                                Text(actionStatus(suggestion))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if suggestion.kind == .task && suggestion.resultStatus == "open" {
                                Button {
                                    complete(suggestion)
                                } label: {
                                    Image(systemName: "circle")
                                        .font(.title3)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Complete action")
                            }
                        }
                    }
                }
            }

            if let text = document.extractedText, !text.isEmpty {
                Section("Extracted text") {
                    Text(text)
                        .textSelection(.enabled)
                        .font(.callout)
                }
            }

            Section {
                if document.status == "inbox" {
                    if document.readyForBatchFiling == true {
                        Button("File document") {
                            Task {
                                if await viewModel.fileDocument(document) {
                                    await reload()
                                }
                            }
                        }
                    } else {
                        Button("Review filing details") {
                            showingMetadataEditor = true
                        }
                    }
                } else if document.status == "archived" {
                    Button("Restore to Filed") {
                        Task {
                            if await viewModel.restoreDocument(document) {
                                dismiss()
                            }
                        }
                    }
                }
                if document.status != "archived" {
                    Button("Archive") {
                        Task {
                            if await viewModel.archiveDocument(document) {
                                dismiss()
                            }
                        }
                    }
                }
                Button("Delete Document", role: .destructive) {
                    showingDeleteConfirmation = true
                }
            }
        }
        .navigationTitle(document.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await reload() }
        .confirmationDialog(
            "Delete this document?",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task {
                    if await viewModel.deleteDocument(document) { dismiss() }
                }
            }
        } message: {
            Text("It will be removed from every person's document library.")
        }
        .sheet(isPresented: $showingExistingRecordPicker) {
            ExistingDocumentRecordPicker(document: document) {
                await reload()
            }
        }
        .sheet(isPresented: $showingMetadataEditor) {
            DocumentMetadataEditorView(
                document: document,
                familyMembers: viewModel.familyMembers
            ) { title, category, date, notes, people in
                guard
                    let updated = await viewModel.updateMetadata(
                        document,
                        title: title,
                        category: category,
                        documentDate: date,
                        notes: notes,
                        personIds: people
                    )
                else { return false }
                document = updated
                return true
            }
        }
        .sheet(isPresented: $addingAction) {
            SuggestionReviewView(
                draft: CaptureSuggestionDraft(
                    kind: .task,
                    title: "",
                    details: "From \(document.title)",
                    confidence: 1
                ),
                familyMembers: viewModel.familyMembers,
                title: "Create Linked Action"
            ) { draft in
                let saved = await viewModel.addAction(documentId: document.id, draft: draft)
                if saved { await reload() }
                return saved
            }
        }
        .sheet(item: $linkedRecord) { record in
            LinkedDocumentRecordSheet(record: record)
        }
    }

    private func reload() async {
        do {
            document = try await viewModel.detail(for: document.id)
        } catch is CancellationError {
            return
        } catch {
            viewModel.errorMessage = "Document details could not be refreshed. Try again."
        }
    }

    private var detailDateLabel: String {
        guard let value = document.documentDate else { return "Not set" }
        guard let date = ISODateParser.parse(value) else { return String(value.prefix(10)) }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    private var visibleActions: [CaptureSuggestionDTO] {
        document.suggestions.filter { $0.status != "dismissed" }
    }

    private func openDocument() {
        isDownloading = true
        Task {
            defer { isDownloading = false }
            do {
                let url = try await viewModel.previewURL(for: document)
                onPreview(url)
            } catch is CancellationError {
                return
            } catch {
                viewModel.errorMessage = "The document preview could not be opened. Try again."
            }
        }
    }

    private func complete(_ suggestion: CaptureSuggestionDTO) {
        Task {
            if await viewModel.completeAction(suggestion) { await reload() }
        }
    }

    private func unlinkEvent(_ id: String) {
        Task {
            do {
                let _: CalendarEventDTO = try await APIClient.shared.put(
                    "/calendar/\(id)",
                    body: SourceDocumentLinkUpdateRequest(sourceDocumentId: nil)
                )
                await reload()
                HapticManager.success()
            } catch let error as APIError {
                viewModel.errorMessage = error.errorDescription
                HapticManager.error()
            } catch {
                viewModel.errorMessage = "The event could not be unlinked."
                HapticManager.error()
            }
        }
    }

    private func unlinkTask(_ id: String) {
        Task {
            do {
                let _: TaskDTO = try await APIClient.shared.put(
                    "/tasks/\(id)",
                    body: SourceDocumentLinkUpdateRequest(sourceDocumentId: nil)
                )
                await reload()
                HapticManager.success()
            } catch let error as APIError {
                viewModel.errorMessage = error.errorDescription
                HapticManager.error()
            } catch {
                viewModel.errorMessage = "The task could not be unlinked."
                HapticManager.error()
            }
        }
    }

    private func linkedEventDate(_ event: LinkedDocumentEventDTO) -> String {
        guard let date = ISODateParser.parse(event.startTime) else { return event.startTime }
        return event.allDay
            ? date.formatted(date: .abbreviated, time: .omitted)
            : date.formatted(date: .abbreviated, time: .shortened)
    }

    private func linkedTaskStatus(_ task: LinkedDocumentTaskDTO) -> String {
        if task.completedAt != nil { return "Completed" }
        guard let due = task.dueDate, let date = ISODateParser.parse(due) else { return "Outstanding" }
        return "Due \(date.formatted(date: .abbreviated, time: .shortened))"
    }

    private func actionStatus(_ suggestion: CaptureSuggestionDTO) -> String {
        let status =
            switch suggestion.resultStatus {
            case "completed": "Completed"
            case "open": "Outstanding"
            case "scheduled": "On calendar"
            case "pending": "Needs review"
            case "dismissed": "Dismissed"
            default: "Unavailable"
            }
        if let name = suggestion.assignedToName { return "\(status) · \(name)" }
        return status
    }
}

private struct LinkedDocumentRecordSheet: View {
    @Environment(\.dismiss) private var dismiss
    let record: LinkedDocumentRecord

    var body: some View {
        NavigationStack {
            List {
                switch record {
                case .event(let event):
                    Section("Event") {
                        LabeledContent("Title", value: event.title)
                        LabeledContent("Starts", value: formatted(event.startTime, allDay: event.allDay))
                        if let end = event.endTime {
                            LabeledContent("Ends", value: formatted(end, allDay: event.allDay))
                        }
                    }
                case .task(let task):
                    Section("Task") {
                        LabeledContent("Title", value: task.title)
                        if let due = task.dueDate {
                            LabeledContent("Due", value: formatted(due, allDay: false))
                        }
                        LabeledContent("Status", value: task.completedAt == nil ? "Outstanding" : "Completed")
                    }
                }
            }
            .navigationTitle("Linked Record")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func formatted(_ value: String, allDay: Bool) -> String {
        guard let date = ISODateParser.parse(value) else { return value }
        return date.formatted(date: .abbreviated, time: allDay ? .omitted : .shortened)
    }
}

private struct DocumentMetadataEditorView: View {
    let document: DocumentDTO
    let familyMembers: [FamilyMemberDTO]
    let onSave: (String, DocumentCategory, Date?, String, [String]) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var category: DocumentCategory
    @State private var hasDate: Bool
    @State private var documentDate: Date
    @State private var notes: String
    @State private var selectedPeople: Set<String>
    @State private var isSaving = false

    init(
        document: DocumentDTO,
        familyMembers: [FamilyMemberDTO],
        onSave: @escaping (String, DocumentCategory, Date?, String, [String]) async -> Bool
    ) {
        self.document = document
        self.familyMembers = familyMembers
        self.onSave = onSave
        _title = State(initialValue: document.title)
        _category = State(initialValue: document.category)
        _hasDate = State(initialValue: document.documentDate != nil)
        _documentDate = State(
            initialValue: document.documentDate.flatMap(ISODateParser.parse) ?? Date()
        )
        _notes = State(initialValue: document.notes ?? "")
        _selectedPeople = State(initialValue: Set(document.people.map(\.personId)))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Document") {
                    TextField("Title", text: $title)
                    Picker("Category", selection: $category) {
                        ForEach(DocumentCategory.allCases) { option in
                            Label(option.title, systemImage: option.icon).tag(option)
                        }
                    }
                    if let confidence = document.categoryConfidence {
                        Text(
                            confidence >= 0.8
                                ? "Suggested filing — it looks reliable. Saving confirms it."
                                : "Suggested filing — please check it before saving."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Toggle("Document has a date", isOn: $hasDate)
                    if hasDate {
                        DatePicker(
                            "Document date",
                            selection: $documentDate,
                            displayedComponents: .date
                        )
                        if let confidence = document.documentDateConfidence {
                            Text(
                                confidence >= 0.8
                                    ? "Suggested date — it looks reliable. Saving confirms it."
                                    : "This may only be the email date. Check it or leave it blank."
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(2...6)
                }

                Section {
                    if familyMembers.isEmpty {
                        Text("No family members are available. The document will stay filed for everyone.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(familyMembers) { member in
                            Toggle(member.name, isOn: personBinding(member.id))
                        }
                    }
                } header: {
                    Text("File for")
                } footer: {
                    Text("This helps you find the file; it does not change who can open it.")
                }
            }
            .navigationTitle("Edit Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        save()
                    } label: {
                        if isSaving { ProgressView() } else { Text("Save") }
                    }
                    .disabled(
                        isSaving
                            || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                }
            }
        }
    }

    private func personBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { selectedPeople.contains(id) },
            set: { selected in
                if selected { selectedPeople.insert(id) } else { selectedPeople.remove(id) }
            }
        )
    }

    private func save() {
        isSaving = true
        Task {
            let saved = await onSave(
                title,
                category,
                hasDate ? documentDate : nil,
                notes,
                Array(selectedPeople)
            )
            isSaving = false
            if saved { dismiss() }
        }
    }
}
