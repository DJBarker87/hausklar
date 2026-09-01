import SwiftUI

enum RenewalFormMode: Identifiable {
    case new
    case edit(RenewalDTO)

    var id: String {
        switch self {
        case .new: "new"
        case .edit(let renewal): renewal.id
        }
    }
}

struct RenewalFormView: View {
    @ObservedObject var viewModel: RenewalsViewModel
    let mode: RenewalFormMode

    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var category: RenewalCategory = .document
    @State private var dueDate = Date()
    @State private var hasRecurrence = false
    @State private var recurrenceMonths = 12
    @State private var hasCost = false
    @State private var costPounds = ""
    @State private var provider = ""
    @State private var reference = ""
    @State private var actionUrl = ""
    @State private var comparisonUrl = ""
    @State private var contactUrl = ""
    @State private var notes = ""
    @State private var checklistText = ""
    @State private var sourceDocument: SourceDocumentDTO?
    @State private var showingDocumentPicker = false
    @State private var remindersEnabled = true
    @State private var reminderDaysBefore = 30
    @State private var escalateToOtherAdult = true
    @State private var escalateAfterDays = 3
    @State private var responsibleUserId = ""
    @State private var showInCalendar = false
    @State private var showInTasks = false
    @State private var includeInHouseholdFinance = false
    @State private var paymentHandling = "RENEWAL"
    @State private var prepared = false
    @State private var reviewNote: String?

    private let recurrenceOptions = [1, 3, 6, 12, 24, 36, 60, 120]
    private let reminderOptions = [7, 14, 21, 30, 60, 90]

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !viewModel.isSaving
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        showingDocumentPicker = true
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: sourceDocument == nil ? "doc.badge.plus" : "doc.fill")
                                .font(.title3)
                                .foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(sourceDocument?.title ?? "Add the renewal document")
                                    .foregroundStyle(.primary)
                                Text(sourceDocument == nil ? "Scan, upload, or choose one already filed" : "Tap to replace or remove")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    if let document = sourceDocument {
                        Button {
                            Task { await fillFromDocument(document) }
                        } label: {
                            if viewModel.workingId == "preview" {
                                ProgressView()
                            } else {
                                Label("Fill details from this document", systemImage: "text.viewfinder")
                            }
                        }
                        .disabled(viewModel.workingId != nil)
                    }
                    if let reviewNote {
                        Label(reviewNote, systemImage: "checkmark.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("What renews?") {
                    TextField("Name, e.g. Car insurance", text: $title)
                        .textInputAutocapitalization(.sentences)
                    Picker("Category", selection: $category) {
                        ForEach(RenewalCategory.allCases) { option in
                            Label(option.label, systemImage: option.icon).tag(option)
                        }
                    }
                    TextField("Provider", text: $provider)
                    TextField("Policy or reference", text: $reference)
                        .textInputAutocapitalization(.characters)
                }

                Section("When is it due?") {
                    DatePicker("Due date", selection: $dueDate, displayedComponents: .date)
                    Toggle("Repeats", isOn: $hasRecurrence)
                    if hasRecurrence {
                        Picker("Every", selection: $recurrenceMonths) {
                            ForEach(recurrenceOptions, id: \.self) { months in
                                Text(recurrenceLabel(months)).tag(months)
                            }
                        }
                    }
                    Toggle("Save the expected cost", isOn: $hasCost)
                    if hasCost {
                        HStack {
                            Text("£").foregroundStyle(.secondary)
                            TextField("0.00", text: $costPounds)
                                .keyboardType(.decimalPad)
                        }
                    }
                }

                Section("Who handles it?") {
                    Picker("Responsible adult", selection: $responsibleUserId) {
                        Text("Not assigned").tag("")
                        ForEach(viewModel.adults) { adult in
                            Text(adult.name).tag(adult.id)
                        }
                    }
                    Toggle("Send a reminder", isOn: $remindersEnabled)
                    if remindersEnabled {
                        Picker("First reminder", selection: $reminderDaysBefore) {
                            ForEach(reminderOptions, id: \.self) { days in
                                Text("\(days) days before").tag(days)
                            }
                        }
                        Toggle("Tell the other adult if overdue", isOn: $escalateToOtherAdult)
                        if escalateToOtherAdult {
                            Stepper(
                                "After \(escalateAfterDays) day\(escalateAfterDays == 1 ? "" : "s")",
                                value: $escalateAfterDays,
                                in: 0...30
                            )
                        }
                    }
                }

                Section("Show elsewhere") {
                    Toggle(isOn: $showInCalendar) {
                        Label("Calendar", systemImage: "calendar")
                    }
                    Toggle(isOn: $showInTasks) {
                        Label("Tasks", systemImage: "checkmark.circle")
                    }
                    Toggle(isOn: $includeInHouseholdFinance) {
                        Label("Household Finance", systemImage: "sterlingsign.circle")
                    }
                    if includeInHouseholdFinance {
                        Picker("Payment", selection: $paymentHandling) {
                            Text("Review or renew first").tag("RENEWAL")
                            Text("Automatic payment").tag("AUTOMATIC")
                            Text("Manual payment").tag("MANUAL")
                        }
                    }
                }

                Section("Useful links") {
                    TextField("Renew online", text: $actionUrl)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                    TextField("Comparison page", text: $comparisonUrl)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                    TextField("Contact link", text: $contactUrl)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                }

                if !isEditing {
                    Section("Steps for next time") {
                        TextField("One step per line", text: $checklistText, axis: .vertical)
                            .lineLimit(3...7)
                        Text("For example: compare the price, check cover, confirm payment.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Notes") {
                    TextField("Anything else worth keeping", text: $notes, axis: .vertical)
                        .lineLimit(2...5)
                }

                if let error = viewModel.errorMessage {
                    Section {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(isEditing ? "Edit Renewal" : "Add Renewal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(!canSave)
                }
            }
            .overlay {
                if viewModel.isSaving {
                    ProgressView("Saving...")
                        .padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .sheet(isPresented: $showingDocumentPicker) {
                DocumentAttachmentPicker(selectedDocument: sourceDocument) { document in
                    sourceDocument = document
                }
            }
            .task { prepareOnce() }
        }
    }

    private func prepareOnce() {
        guard !prepared else { return }
        prepared = true
        viewModel.errorMessage = nil
        if responsibleUserId.isEmpty {
            responsibleUserId = viewModel.adults.first?.id ?? ""
        }
        guard case .edit(let renewal) = mode else { return }
        title = renewal.title
        category = renewal.categoryValue
        if let parsed = ISODateParser.parse(renewal.dueDate) { dueDate = parsed }
        if let months = renewal.recurrenceMonths {
            hasRecurrence = true
            recurrenceMonths = months
        }
        if let pence = renewal.costPence {
            hasCost = true
            costPounds = String(format: "%.2f", Double(pence) / 100)
        }
        provider = renewal.provider ?? ""
        reference = renewal.reference ?? ""
        actionUrl = renewal.actionUrl ?? ""
        comparisonUrl = renewal.comparisonUrl ?? ""
        contactUrl = renewal.contactUrl ?? ""
        notes = renewal.notes ?? ""
        sourceDocument = renewal.sourceDocument
        remindersEnabled = renewal.remindersEnabled ?? true
        reminderDaysBefore = renewal.reminderDaysBefore
        if let escalation = renewal.escalateAfterDays {
            escalateToOtherAdult = true
            escalateAfterDays = escalation
        } else {
            escalateToOtherAdult = false
        }
        responsibleUserId = renewal.responsibleUserId ?? ""
        showInCalendar = renewal.showInCalendar ?? false
        showInTasks = renewal.showInTasks ?? false
        includeInHouseholdFinance = renewal.financeCommitmentId != nil
        paymentHandling = renewal.paymentHandling ?? "RENEWAL"
    }

    private func fillFromDocument(_ document: SourceDocumentDTO) async {
        guard let preview = await viewModel.preview(documentId: document.id) else { return }
        if let value = preview.title { title = value }
        category = RenewalCategory(rawValue: preview.category) ?? .other
        if let value = preview.dueDate, let parsed = ISODateParser.parse(value) { dueDate = parsed }
        if let value = preview.recurrenceMonths {
            hasRecurrence = true
            recurrenceMonths = value
        }
        if let value = preview.costPence {
            hasCost = true
            costPounds = String(format: "%.2f", Double(value) / 100)
        }
        if let value = preview.provider { provider = value }
        if let value = preview.reference { reference = value }
        if let value = preview.actionUrl { actionUrl = value }
        reviewNote = preview.uncertainFields.isEmpty
            ? "Details filled in. Check them, then save."
            : "Check \(preview.uncertainFields.joined(separator: ", ")) before saving."
    }

    private func recurrenceLabel(_ months: Int) -> String {
        switch months {
        case 1: "Month"
        case 12: "Year"
        case 24: "2 years"
        case 36: "3 years"
        case 60: "5 years"
        case 120: "10 years"
        default: "\(months) months"
        }
    }

    private var costPence: Int? {
        guard hasCost else { return nil }
        let cleaned = costPounds.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard let pounds = Double(cleaned), pounds >= 0 else { return nil }
        return Int((pounds * 100).rounded())
    }

    private func save() async {
        if hasCost && costPence == nil {
            viewModel.errorMessage = "Enter the cost in pounds, for example 82.50."
            return
        }
        if includeInHouseholdFinance && costPence == nil {
            viewModel.errorMessage = "Add the expected cost before including it in Household Finance."
            return
        }
        if (remindersEnabled || showInTasks) && responsibleUserId.isEmpty {
            viewModel.errorMessage = "Choose the adult who will handle this."
            return
        }
        if remindersEnabled {
            _ = await NotificationService.shared.requestPermission()
        }
        let values = RenewalSaveValues(
            title: title,
            category: category,
            dueDate: dueDate,
            recurrenceMonths: hasRecurrence ? recurrenceMonths : nil,
            costPence: costPence,
            reminderDaysBefore: reminderDaysBefore,
            sourceDocumentId: sourceDocument?.id,
            provider: provider,
            reference: reference,
            actionUrl: actionUrl,
            comparisonUrl: comparisonUrl,
            contactUrl: contactUrl,
            notes: notes,
            includeInHouseholdFinance: includeInHouseholdFinance,
            paymentHandling: paymentHandling,
            showInCalendar: showInCalendar,
            showInTasks: showInTasks,
            responsibleUserId: responsibleUserId.isEmpty ? nil : responsibleUserId,
            remindersEnabled: remindersEnabled,
            escalateAfterDays: remindersEnabled && escalateToOtherAdult ? escalateAfterDays : nil,
            checklist: checklistText
                .split(whereSeparator: \.isNewline)
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
        let succeeded: Bool
        switch mode {
        case .new:
            succeeded = await viewModel.create(values)
        case .edit(let renewal):
            succeeded = await viewModel.update(renewal, values: values)
        }
        if succeeded { dismiss() }
    }
}
