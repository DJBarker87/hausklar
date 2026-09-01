import SwiftUI

/// Form sheet for creating or editing a term date range.
struct TermDateFormSheet: View {
    @ObservedObject var viewModel: RoutineViewModel
    let isEditing: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section("Term Details") {
                    TextField("Label (optional)", text: $viewModel.formTermLabel)
                    DatePicker("Start Date", selection: $viewModel.formTermStart, displayedComponents: .date)
                    DatePicker("End Date", selection: $viewModel.formTermEnd, displayedComponents: .date)
                }

                if let errorMessage = viewModel.errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }
            }
            .navigationTitle(isEditing ? "Edit Term" : "New Term")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        viewModel.showingAddTerm = false
                        viewModel.editingTerm = nil
                        viewModel.resetTermForm()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            if isEditing {
                                await viewModel.updateTerm()
                            } else {
                                await viewModel.createTerm()
                            }
                        }
                    }
                }
            }
        }
    }
}
