import SwiftUI

/// The NHS routine vaccination schedule with computed due dates and status. Tap a
/// vaccine to record it as given, or to unrecord it.
struct VaccinationsSection: View {
    @ObservedObject var viewModel: HealthRecordViewModel
    let initialVaccinationKey: String?
    @State private var editing: VaccinationItemDTO?
    @State private var showingAddVaccination = false
    @State private var consumedInitialVaccination = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let response = viewModel.vaccinations {
                HealthDisclaimerBanner(
                    text: "Use this as a reminder record. Check your child's Red Book and confirm the exact schedule with your GP."
                )

                Button {
                    showingAddVaccination = true
                } label: {
                    Label("Add vaccination", systemImage: "plus")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isSaving)

                if response.vaccinations.isEmpty {
                    ContentUnavailableView(
                        "No vaccinations",
                        systemImage: "syringe",
                        description: Text("There is no routine schedule to show for this child yet.")
                    )
                } else {
                    let additional = response.vaccinations.filter(\.isAdditional)
                    let routine = response.vaccinations.filter { !$0.isAdditional }

                    if !additional.isEmpty {
                        Text("Additional vaccinations")
                            .font(.headline)
                        LazyVStack(spacing: 10) {
                            ForEach(additional) { vaccine in
                                vaccineButton(vaccine)
                            }
                        }
                    }

                    if !routine.isEmpty {
                        Text("Routine schedule")
                            .font(.headline)
                            .padding(.top, additional.isEmpty ? 0 : 6)
                        LazyVStack(spacing: 10) {
                            ForEach(routine) { vaccine in
                                vaccineButton(vaccine)
                            }
                        }
                    }
                }
            } else if viewModel.isLoading {
                ProgressView("Loading vaccinations...")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 30)
            }
        }
        .sheet(item: $editing) { vaccine in
            VaccinationRecordSheet(viewModel: viewModel, vaccine: vaccine)
        }
        .sheet(isPresented: $showingAddVaccination) {
            AdditionalVaccinationSheet(viewModel: viewModel)
        }
        .onChange(of: viewModel.vaccinations?.vaccinations.map(\.key) ?? []) { _, _ in
            openInitialVaccinationIfNeeded()
        }
        .onAppear {
            openInitialVaccinationIfNeeded()
        }
    }

    private func openInitialVaccinationIfNeeded() {
        guard !consumedInitialVaccination,
              let initialVaccinationKey,
              let vaccine = viewModel.vaccinations?.vaccinations.first(where: { $0.key == initialVaccinationKey }) else { return }
        consumedInitialVaccination = true
        editing = vaccine
    }

    private func vaccineButton(_ vaccine: VaccinationItemDTO) -> some View {
        Button {
            editing = vaccine
        } label: {
            VaccinationRow(vaccine: vaccine)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens this vaccination record")
    }
}

private struct VaccinationRow: View {
    let vaccine: VaccinationItemDTO

    private var isGiven: Bool { vaccine.status == .given }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: isGiven ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(isGiven ? .green : .secondary)

            VStack(alignment: .leading, spacing: 3) {
                Text(vaccine.name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .strikethrough(isGiven, color: .secondary)

                Text(vaccine.isAdditional ? "Additional vaccination" : "Due at \(vaccine.dueAgeLabel)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if isGiven, let on = vaccine.givenOn, let date = ISODateParser.parse(on) {
                    Text("Given \(ISODateParser.dateOnly(from: date))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let due = vaccine.dueDateDisplay {
                    Text("Expected \(due)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 6)

            Text(vaccine.status.vaccinationLabel)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(vaccine.status.vaccinationColor.opacity(0.16), in: Capsule())
                .foregroundStyle(vaccine.status.vaccinationColor)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
    }
}

/// Records a vaccine as given (date), or unrecords it.
private struct VaccinationRecordSheet: View {
    @ObservedObject var viewModel: HealthRecordViewModel
    let vaccine: VaccinationItemDTO
    @Environment(\.dismiss) private var dismiss

    @State private var givenOn = Date()
    @State private var prepared = false

    private var isGiven: Bool { vaccine.status == .given }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(vaccine.name)
                        .font(.headline)
                    Text(vaccine.isAdditional ? "Additional vaccination" : "Due at \(vaccine.dueAgeLabel)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if isGiven {
                    Section {
                        Button(role: .destructive) {
                            Task {
                                if await viewModel.unrecordVaccination(vaccine) {
                                    dismiss()
                                }
                            }
                        } label: {
                            Label("Remove this record", systemImage: "arrow.uturn.backward")
                        }
                        .disabled(viewModel.isSaving)
                    } footer: {
                        Text("This clears the given date from \(viewModel.selectedChildName)'s record.")
                    }
                } else {
                    Section("When was it given?") {
                        DatePicker("Given on", selection: $givenOn, in: ...Date(), displayedComponents: .date)
                    }
                }

                if let error = viewModel.errorMessage {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(isGiven ? "Vaccination" : "Record vaccination")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(viewModel.isSaving)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                if !isGiven {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Given") {
                            Task {
                                if await viewModel.markVaccination(vaccine, givenOn: givenOn) {
                                    dismiss()
                                }
                            }
                        }
                        .disabled(viewModel.isSaving)
                    }
                }
            }
            .task {
                guard !prepared else { return }
                prepared = true
                viewModel.errorMessage = nil
                // Default to the expected due date when it is in the past, else today.
                if let due = vaccine.dueDate, let date = ISODateParser.parse(due), date <= Date() {
                    givenOn = date
                }
            }
        }
        .presentationDetents([.medium])
    }
}

/// Adds a named vaccine that is not part of the built-in routine schedule.
private struct AdditionalVaccinationSheet: View {
    @ObservedObject var viewModel: HealthRecordViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var vaccineName = ""
    @State private var givenOn = Date()

    private var trimmedName: String {
        vaccineName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Vaccine name", text: $vaccineName)
                        .textInputAutocapitalization(.words)
                        .onChange(of: vaccineName) { _, value in
                            if value.count > 120 {
                                vaccineName = String(value.prefix(120))
                            }
                        }
                    DatePicker("Given on", selection: $givenOn, in: ...Date(), displayedComponents: .date)
                } header: {
                    Text("Vaccine")
                } footer: {
                    Text("For example, Chickenpox or a travel vaccination.")
                }

                if let error = viewModel.errorMessage {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Add vaccination")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(viewModel.isSaving)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(viewModel.isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        Task {
                            if await viewModel.addVaccination(named: trimmedName, givenOn: givenOn) {
                                dismiss()
                            }
                        }
                    }
                    .disabled(trimmedName.isEmpty || viewModel.isSaving)
                }
            }
        }
        .presentationDetents([.medium])
    }
}
