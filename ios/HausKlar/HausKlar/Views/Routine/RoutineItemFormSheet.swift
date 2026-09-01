import SwiftUI

/// Form sheet for creating or editing a routine item.
struct RoutineItemFormSheet: View {
    @ObservedObject var viewModel: RoutineViewModel
    let isEditing: Bool

    @ScaledMetric(relativeTo: .caption) private var dayButtonFontSize: CGFloat = 12

    var body: some View {
        NavigationStack {
            Form {
                // Suggestions (kids only, new items only)
                if !isEditing && viewModel.isChildSelected {
                    Section("Quick Pick") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(RoutineViewModel.suggestions) { suggestion in
                                    Button {
                                        viewModel.applySuggestion(suggestion)
                                    } label: {
                                        Text(suggestion.name)
                                            .font(.caption)
                                            .fontWeight(.medium)
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 6)
                                            .background(Color(hex: suggestion.defaultColor).opacity(0.2))
                                            .foregroundStyle(Color(hex: suggestion.defaultColor))
                                            .cornerRadius(12)
                                    }
                                    .accessibilityLabel("Use suggestion: \(suggestion.name)")
                                }
                            }
                        }
                    }
                }

                Section("Activity") {
                    TextField("What happens?", text: $viewModel.formItemName)
                    Toggle("Set a time", isOn: $viewModel.formItemHasTime)
                    if viewModel.formItemHasTime {
                        DatePicker(
                            "Time",
                            selection: $viewModel.formItemTime,
                            displayedComponents: .hourAndMinute
                        )
                    }
                }

                Section("Days") {
                    HStack(spacing: 4) {
                        ForEach(0..<7, id: \.self) { day in
                            let isSelected = viewModel.formItemDays.contains(day)
                            let dayName = RoutineViewModel.dayNames[day]
                            Button {
                                if isSelected {
                                    viewModel.formItemDays.remove(day)
                                } else {
                                    viewModel.formItemDays.insert(day)
                                }
                            } label: {
                                Text(dayName)
                                    .font(.system(size: dayButtonFontSize, weight: .medium))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                                    .background(isSelected ? Color.accentColor : Color(.systemGray5))
                                    .foregroundStyle(isSelected ? .white : .primary)
                                    .cornerRadius(8)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(dayName)
                            .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                        }
                    }
                }

                Section {
                    DisclosureGroup("More") {
                        TextField("Location", text: $viewModel.formItemLocation)
                        TextField(
                            "Preparation note",
                            text: $viewModel.formItemPreparation,
                            axis: .vertical
                        )
                        Picker("Reusable packing list", selection: $viewModel.formItemPrepTemplateId) {
                            Text("None").tag("")
                            ForEach(viewModel.prepTemplates) { template in
                                Text(template.name).tag(template.id)
                            }
                        }
                        Picker("Reminder", selection: $viewModel.formItemReminderMinutes) {
                            Text("No reminder").tag(nil as Int?)
                            Text("15 minutes before").tag(15 as Int?)
                            Text("30 minutes before").tag(30 as Int?)
                            Text("1 hour before").tag(60 as Int?)
                            Text("1 day before").tag(1_440 as Int?)
                        }
                        Toggle("Show in family planner", isOn: $viewModel.formItemCalendarProjection)
                        Toggle("Only during term", isOn: $viewModel.formItemTermOnly)

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Colour")
                                .font(.subheadline)
                            ColorPaletteView(selectedColor: $viewModel.formItemColor)
                        }
                    }
                } footer: {
                    Text("Location, preparation, reminders and packing live here when you need them.")
                }

                if let errorMessage = viewModel.errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }
            }
            .navigationTitle(isEditing ? "Edit activity" : "Add activity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        viewModel.showingAddItem = false
                        viewModel.editingItem = nil
                        viewModel.resetItemForm()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            if isEditing {
                                await viewModel.updateItem()
                            } else {
                                await viewModel.createItem()
                            }
                        }
                    }
                    .disabled(
                        viewModel.formItemName.trimmingCharacters(in: .whitespaces).isEmpty
                            || viewModel.formItemDays.isEmpty
                    )
                }
            }
        }
    }
}
