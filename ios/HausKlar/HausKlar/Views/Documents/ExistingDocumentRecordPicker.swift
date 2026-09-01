import SwiftUI

struct ExistingDocumentRecordPicker: View {
    @Environment(\.dismiss) private var dismiss
    let document: DocumentDTO
    let onLinked: () async -> Void

    @StateObject private var viewModel: ExistingDocumentRecordPickerViewModel
    @State private var kind: ExistingDocumentRecordKind = .event
    @State private var searchText = ""
    @State private var replacementChoice: ExistingDocumentRecordChoice?

    init(
        document: DocumentDTO,
        onLinked: @escaping () async -> Void
    ) {
        self.document = document
        self.onLinked = onLinked
        _viewModel = StateObject(
            wrappedValue: ExistingDocumentRecordPickerViewModel(
                documentId: document.id,
                referenceDate: document.documentDate.flatMap(ISODateParser.parse) ?? Date()
            )
        )
    }

    private var filteredChoices: [ExistingDocumentRecordChoice] {
        viewModel.filteredChoices(kind: kind, searchText: searchText)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Record type", selection: $kind) {
                        ForEach(ExistingDocumentRecordKind.allCases) { value in
                            Text(value.rawValue).tag(value)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                if let errorMessage = viewModel.errorMessage {
                    Section {
                        VStack(alignment: .leading, spacing: 10) {
                            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                            Button("Try again") { Task { await viewModel.load() } }
                                .buttonStyle(.bordered)
                        }
                        .padding(.vertical, 6)
                    }
                }

                Section(kind == .event ? "Events near this document" : "Tasks") {
                    if viewModel.isLoading {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Loading \(kind.rawValue.lowercased())…")
                                .foregroundStyle(.secondary)
                        }
                        .frame(minHeight: 52)
                    } else if filteredChoices.isEmpty {
                        ContentUnavailableView(
                            searchText.isEmpty
                                ? "No \(kind.rawValue.lowercased()) available"
                                : "No matches",
                            systemImage: kind == .event ? "calendar" : "checklist",
                            description: Text(
                                searchText.isEmpty
                                    ? "Create a new one, or choose the other record type."
                                    : "Try another title or date."
                            )
                        )
                    } else {
                        ForEach(filteredChoices) { choice in
                            choiceRow(choice)
                        }
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Search \(kind.rawValue.lowercased())")
            .navigationTitle("Attach to Existing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task { await viewModel.load() }
            .refreshable { await viewModel.load() }
            .confirmationDialog(
                "Replace the existing attachment?",
                isPresented: Binding(
                    get: { replacementChoice != nil },
                    set: { if !$0 { replacementChoice = nil } }
                ),
                titleVisibility: .visible,
                presenting: replacementChoice
            ) { choice in
                Button("Replace Attachment") {
                    attach(choice)
                }
                Button("Cancel", role: .cancel) {}
            } message: { choice in
                Text("\(choice.title) already has a document. This will replace that link; the other document remains safely stored.")
            }
        }
    }

    private func choiceRow(_ choice: ExistingDocumentRecordChoice) -> some View {
        let alreadyLinked = choice.sourceDocumentId == document.id
        return Button {
            if choice.sourceDocumentId != nil, !alreadyLinked {
                replacementChoice = choice
            } else {
                attach(choice)
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: choice.kind == .event ? "calendar" : "checkmark.circle")
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 28, height: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(choice.title)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Text(choice.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if viewModel.savingChoiceId == choice.id {
                    ProgressView()
                        .accessibilityLabel("Attaching document")
                } else if alreadyLinked {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .accessibilityLabel("Already attached")
                } else if choice.sourceDocumentId != nil {
                    Image(systemName: "paperclip")
                        .foregroundStyle(.orange)
                        .accessibilityLabel("Has another attachment")
                } else {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(alreadyLinked || viewModel.savingChoiceId != nil)
    }

    private func attach(_ choice: ExistingDocumentRecordChoice) {
        replacementChoice = nil
        Task {
            if await viewModel.attach(to: choice) {
                HapticManager.success()
                await onLinked()
                dismiss()
            } else {
                HapticManager.error()
            }
        }
    }
}
