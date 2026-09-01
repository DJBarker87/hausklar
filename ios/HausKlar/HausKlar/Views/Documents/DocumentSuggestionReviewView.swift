import SwiftUI

struct SuggestionReviewContext: Identifiable {
    let documentId: String
    let draft: CaptureSuggestionDraft
    var id: String { draft.id }
}

struct SuggestionReviewView: View {
    let familyMembers: [FamilyMemberDTO]
    let onAccept: (CaptureSuggestionDraft) async -> Bool
    let title: String

    @Environment(\.dismiss) private var dismiss
    @State private var draft: CaptureSuggestionDraft
    @State private var date: Date
    @State private var hasDate: Bool
    @State private var isSaving = false

    init(
        draft: CaptureSuggestionDraft,
        familyMembers: [FamilyMemberDTO],
        title: String = "Review Suggestion",
        onAccept: @escaping (CaptureSuggestionDraft) async -> Bool
    ) {
        self.familyMembers = familyMembers
        self.onAccept = onAccept
        self.title = title
        _draft = State(initialValue: draft)
        let rawDate = draft.kind == .event ? draft.startTime : draft.dueDate
        _date = State(initialValue: rawDate.flatMap(ISODateParser.parse) ?? Date())
        _hasDate = State(initialValue: rawDate != nil || draft.kind == .event)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Create") {
                    Picker("Type", selection: $draft.kind) {
                        ForEach(CaptureSuggestionKind.allCases) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    TextField("Title", text: $draft.title)

                    Picker("Who", selection: $draft.assignedTo) {
                        Text("Everyone").tag(String?.none)
                        ForEach(familyMembers) { member in
                            Text(member.name).tag(String?.some(member.id))
                        }
                    }
                }

                Section("When") {
                    if draft.kind == .event {
                        Toggle("All day", isOn: $draft.allDay)
                        DatePicker(
                            draft.allDay ? "Date" : "Starts",
                            selection: $date,
                            displayedComponents: draft.allDay ? .date : [.date, .hourAndMinute]
                        )
                    } else {
                        Toggle("Has deadline", isOn: $hasDate)
                        if hasDate {
                            DatePicker("Due", selection: $date)
                        }
                    }
                }

                Section("Details") {
                    TextField("Notes", text: detailsBinding, axis: .vertical)
                        .lineLimit(3...8)
                    if let source = draft.sourceText, !source.isEmpty {
                        Text(source)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { accept() }
                        .disabled(isSaving || draft.title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onChange(of: draft.kind) { _, kind in
                if kind == .event { hasDate = true }
            }
        }
    }

    private var detailsBinding: Binding<String> {
        Binding(get: { draft.details ?? "" }, set: { draft.details = $0.isEmpty ? nil : $0 })
    }

    private func accept() {
        isSaving = true
        if draft.kind == .event {
            draft.startTime =
                draft.allDay
                ? ISODateParser.dateOnly(from: date)
                : ISODateParser.stringNoFractional(from: date)
            draft.dueDate = nil
        } else {
            draft.dueDate = hasDate ? ISODateParser.stringNoFractional(from: date) : nil
            draft.startTime = nil
            draft.endTime = nil
        }
        Task {
            if await onAccept(draft) { dismiss() }
            isSaving = false
        }
    }
}
