import SwiftData
import SwiftUI

struct QuickEventSheet: View {
    let initialDate: Date
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @StateObject private var viewModel = CalendarViewModel()
    @State private var showingDetails = false
    @State private var prepared = false
    @State private var showingDocumentPicker = false

    init(initialDate: Date, onSaved: @escaping () -> Void = {}) {
        self.initialDate = initialDate
        self.onSaved = onSaved
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Event") {
                    TextField("What is happening?", text: $viewModel.formTitle)
                        .textInputAutocapitalization(.sentences)

                    Toggle(
                        "All day",
                        isOn: Binding(
                            get: { viewModel.formAllDay },
                            set: { viewModel.setFormAllDay($0) }
                        ))

                    if viewModel.formAllDay {
                        DatePicker(
                            "Date",
                            selection: Binding(
                                get: { viewModel.formStartTime },
                                set: { viewModel.setFormStartTime($0) }
                            ),
                            displayedComponents: .date
                        )
                    } else {
                        DatePicker(
                            "Starts",
                            selection: Binding(
                                get: { viewModel.formStartTime },
                                set: { viewModel.setFormStartTime($0) }
                            )
                        )
                        Picker(
                            "Duration",
                            selection: Binding(
                                get: { viewModel.formDurationOption },
                                set: { viewModel.setFormDuration($0) }
                            )
                        ) {
                            ForEach(CalendarEventDurationOption.allCases) { option in
                                Text(option.label.localized).tag(option)
                            }
                        }
                        if viewModel.formDurationOption == .custom {
                            DatePicker(
                                "Ends",
                                selection: Binding(
                                    get: { viewModel.formEndTime },
                                    set: { viewModel.setFormEndTime($0) }
                                ),
                                in: viewModel.formStartTime.addingTimeInterval(60)...
                            )
                        }
                    }

                    Picker("Repeat", selection: $viewModel.formRecurrence) {
                        Text("Never").tag("never")
                        Text("Daily").tag("daily")
                        Text("Weekly").tag("weekly")
                        Text("Monthly").tag("monthly")
                        Text("Yearly").tag("yearly")
                    }
                }

                Section("Who is going?") {
                    Toggle(
                        "Everyone",
                        isOn: Binding(
                            get: { viewModel.formEveryoneSelected },
                            set: { viewModel.setFormEveryone($0) }
                        ))
                    ForEach(viewModel.familyMembers) { member in
                        Toggle(
                            member.name,
                            isOn: Binding(
                                get: { viewModel.formParticipantIDs.contains(member.id) },
                                set: { viewModel.setFormParticipant(member.id, selected: $0) }
                            ))
                    }
                }

                if !viewModel.formOtherAdults.isEmpty {
                    Section {
                        ForEach(viewModel.formOtherAdults) { adult in
                            Toggle(
                                "Affects \(adult.name) too",
                                isOn: Binding(
                                    get: { viewModel.formAffectedMemberIDs.contains(adult.id) },
                                    set: { viewModel.setFormAffectedAdult(adult.id, selected: $0) }
                                ))
                        }
                    } header: {
                        Text("Also affects")
                    } footer: {
                        Text("Shows the event in their plan because they may need to cover the rest of the family.")
                    }
                }

                Section {
                    DisclosureGroup("More details", isExpanded: $showingDetails) {
                        TextField("Location", text: $viewModel.formLocation)
                        TextField("Notes", text: $viewModel.formDescription, axis: .vertical)
                            .lineLimit(2...5)
                    }
                }

                Section("Attachment") {
                    Button {
                        showingDocumentPicker = true
                    } label: {
                        HStack {
                            Label(
                                viewModel.formSourceDocumentId == nil
                                    ? "Attach document" : "Change document",
                                systemImage: "paperclip"
                            )
                            Spacer()
                            if let document = viewModel.formSourceDocument {
                                Text(document.title)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .frame(minHeight: 44)
                    }
                    if viewModel.formSourceDocumentId != nil {
                        Button("Remove attachment", role: .destructive) {
                            viewModel.formSourceDocumentId = nil
                            viewModel.formSourceDocument = nil
                        }
                    }
                }

                if let error = viewModel.errorMessage {
                    Section {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Add Event")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        Task {
                            await viewModel.createEvent {
                                NotificationCenter.default.post(name: .calendarDataChanged, object: nil)
                                onSaved()
                                dismiss()
                            }
                        }
                    }
                    .disabled(
                        viewModel.formTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || (!viewModel.formWholeFamily
                                && !viewModel.familyMembers.isEmpty
                                && viewModel.formParticipantIDs.isEmpty)
                            || viewModel.isLoading
                    )
                }
            }
            .task {
                guard !prepared else { return }
                prepared = true
                viewModel.bindModelContext(modelContext)
                viewModel.prepareNewEvent(on: roundedUp(initialDate))
                viewModel.setFormAllDay(false)
                await viewModel.loadFamilyMembers()
            }
            .sheet(isPresented: $showingDocumentPicker) {
                DocumentAttachmentPicker(selectedDocument: viewModel.formSourceDocument) { document in
                    viewModel.formSourceDocument = document
                    viewModel.formSourceDocumentId = document?.id
                }
            }
        }
    }

    private func roundedUp(_ date: Date) -> Date {
        let interval: TimeInterval = 15 * 60
        return Date(timeIntervalSince1970: ceil(date.timeIntervalSince1970 / interval) * interval)
    }
}

struct QuickTaskSheet: View {
    let initialDate: Date
    let startsWithDueDate: Bool
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @StateObject private var viewModel = TasksViewModel()
    @State private var showingDetails = false
    @State private var prepared = false

    init(
        initialDate: Date,
        startsWithDueDate: Bool = true,
        onSaved: @escaping () -> Void = {}
    ) {
        self.initialDate = initialDate
        self.startsWithDueDate = startsWithDueDate
        self.onSaved = onSaved
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Task") {
                    TextField("What needs doing?", text: $viewModel.formTitle)
                        .textInputAutocapitalization(.sentences)
                }

                if !viewModel.familyMembers.isEmpty {
                    Section("Owner") {
                        ForEach(viewModel.familyMembers) { member in
                            Toggle(member.name, isOn: assigneeBinding(member.id))
                        }
                    }
                }

                Section {
                    Toggle(
                        "Add a due date",
                        isOn: Binding(
                            get: { viewModel.formHasDueDate },
                            set: { viewModel.setFormHasDueDate($0) }
                        )
                    )
                    if viewModel.formHasDueDate {
                        DatePicker(
                            "Due",
                            selection: $viewModel.formDueDate,
                            displayedComponents: [.date, .hourAndMinute]
                        )
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
                } header: {
                    Text("When")
                } footer: {
                    if viewModel.formRecurrence != .never {
                        Text("Repeats from the due date.")
                    }
                }

                Section {
                    DisclosureGroup("More details", isExpanded: $showingDetails) {
                        Picker("Priority", selection: $viewModel.formPriority) {
                            Text("Low").tag(1)
                            Text("Normal").tag(2)
                            Text("High").tag(3)
                        }
                        Picker("Category", selection: $viewModel.formCategory) {
                            ForEach(viewModel.categories, id: \.self) { category in
                                Text(category.capitalized).tag(category)
                            }
                        }
                        TextField("Notes", text: $viewModel.formDescription, axis: .vertical)
                            .lineLimit(2...5)
                        Toggle("Hide until", isOn: $viewModel.formShowEarly)
                        if viewModel.formShowEarly {
                            DatePicker(
                                "Hide until",
                                selection: $viewModel.formActionableFrom,
                                displayedComponents: [.date, .hourAndMinute]
                            )
                        }
                        TaskDocumentAttachmentSection(
                            document: $viewModel.formSourceDocument,
                            sectioned: false
                        )
                    }
                }

                if let error = viewModel.errorMessage {
                    Section {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Add Task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        Task {
                            await viewModel.createTask()
                            if viewModel.errorMessage == nil || viewModel.errorMessage?.contains("queued") == true {
                                NotificationCenter.default.post(name: .taskDataChanged, object: nil)
                                onSaved()
                                HapticManager.success()
                                dismiss()
                            }
                        }
                    }
                    .disabled(viewModel.formTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.isLoading)
                }
            }
            .task {
                guard !prepared else { return }
                prepared = true
                viewModel.bindModelContext(modelContext)
                viewModel.formHasDueDate = startsWithDueDate
                viewModel.formDueDate = initialDate
                await viewModel.loadFamilyMembers()
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
