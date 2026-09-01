import SwiftUI

/// The dog management screen. Shows today's walk/feed status, quick action buttons,
/// and a scrollable history of recent dog activities.
struct DogView: View {
    @StateObject private var viewModel = DogViewModel()

    @State private var showDeleteConfirmation = false
    @State private var activityToDelete: DogActivityDTO?
    @State private var vaccinationToDelete: DogVaccinationDTO?
    @State private var editingVaccination: DogVaccinationDTO?
    @State private var editingWeight: DogWeightDTO?
    @State private var documentToRemove: DogDocumentDTO?
    @State private var pendingDocument: SourceDocumentDTO?
    @State private var showingDocumentRole = false
    @State private var previewItem: DocumentPreviewItem?
    @State private var isOpeningDocument = false
    @State private var showingPetRecord = false
    @State private var showBreakfastDuplicateAlert = false
    @State private var showDinnerDuplicateAlert = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // Status header
                    statusHeaderView

                    // Quick action buttons
                    quickActionsView

                    // Error banner
                    if let errorMessage = viewModel.errorMessage {
                        errorBanner(errorMessage)
                    }

                    // Activity history
                    activityHistoryView

                    petRecordView
                }
                .padding(.vertical)
                .frame(maxWidth: 700)
                .frame(maxWidth: .infinity)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(viewModel.profile.name)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        viewModel.resetForm()
                        viewModel.formActivityType = "vet"
                        viewModel.showingAddActivity = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $viewModel.showingAddActivity) {
                addActivitySheet
            }
            .sheet(isPresented: $viewModel.showingAddVaccination) {
                addVaccinationSheet
            }
            .sheet(isPresented: $viewModel.showingProfileEditor) {
                DogProfileEditorSheet(viewModel: viewModel)
            }
            .sheet(isPresented: $viewModel.showingAddWeight) {
                DogWeightEditorSheet(viewModel: viewModel)
            }
            .sheet(item: $editingWeight) { weight in
                DogWeightEditorSheet(viewModel: viewModel, weight: weight)
            }
            .sheet(item: $editingVaccination) { vaccination in
                DogVaccinationEditorSheet(viewModel: viewModel, vaccination: vaccination)
            }
            .sheet(isPresented: $viewModel.showingDocumentPicker) {
                DocumentAttachmentPicker(selectedDocument: nil) { document in
                    guard let document else { return }
                    pendingDocument = document
                    showingDocumentRole = true
                }
            }
            .sheet(item: $previewItem) { item in
                QuickLookPreview(url: item.url)
                    .ignoresSafeArea()
            }
            .sheet(item: $viewModel.editingActivity) { activity in
                DogActivityCorrectionSheet(viewModel: viewModel, activity: activity)
            }
            .confirmationDialog("Remove this record?", isPresented: $showDeleteConfirmation, presenting: activityToDelete) { activity in
                Button("Remove Record", role: .destructive) {
                    Task {
                        await viewModel.deleteActivity(activity)
                    }
                }
                Button("Cancel", role: .cancel) { }
            } message: { activity in
                Text("You can undo immediately if this was a mistake.")
            }
            .confirmationDialog(
                "Delete this vaccination?",
                isPresented: Binding(
                    get: { vaccinationToDelete != nil },
                    set: { if !$0 { vaccinationToDelete = nil } }
                ),
                presenting: vaccinationToDelete
            ) { vaccination in
                Button("Delete record", role: .destructive) {
                    Task { await viewModel.deleteVaccination(vaccination.id) }
                }
                Button("Cancel", role: .cancel) { }
            } message: { vaccination in
                Text("This removes the \(vaccination.vaccineName) record.")
            }
            .confirmationDialog(
                "What kind of document is this?",
                isPresented: $showingDocumentRole,
                titleVisibility: .visible
            ) {
                ForEach(["insurance", "vet", "microchip", "medicine", "other"], id: \.self) { role in
                    Button(documentRoleLabel(role)) {
                        guard let pendingDocument else { return }
                        Task {
                            _ = await viewModel.linkDocument(pendingDocument, role: role)
                            self.pendingDocument = nil
                        }
                    }
                }
                Button("Cancel", role: .cancel) { pendingDocument = nil }
            }
            .confirmationDialog(
                "Remove this document from the pet record?",
                isPresented: Binding(
                    get: { documentToRemove != nil },
                    set: { if !$0 { documentToRemove = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Remove Link", role: .destructive) {
                    guard let documentToRemove else { return }
                    Task {
                        await viewModel.unlinkDocument(documentToRemove)
                        self.documentToRemove = nil
                    }
                }
                Button("Cancel", role: .cancel) { documentToRemove = nil }
            }
            .alert("Already Fed Breakfast", isPresented: $showBreakfastDuplicateAlert) {
                Button("Log Again Anyway") {
                    Task { await viewModel.logQuickBreakfast() }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                if let activity = viewModel.breakfastActivityToday {
                    Text(viewModel.alreadyFedDescription(for: activity))
                }
            }
            .alert("Already Fed Dinner", isPresented: $showDinnerDuplicateAlert) {
                Button("Log Again Anyway") {
                    Task { await viewModel.logQuickDinner() }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                if let activity = viewModel.dinnerActivityToday {
                    Text(viewModel.alreadyFedDescription(for: activity))
                }
            }
            .task {
                await viewModel.loadData()
            }
            .refreshable {
                await viewModel.loadData()
            }
            .safeAreaInset(edge: .bottom) {
                if viewModel.recentlyDeletedActivity != nil
                    || viewModel.recentlyDeletedVaccination != nil
                    || viewModel.recentlyDeletedWeight != nil {
                    HStack(spacing: 12) {
                        Text(undoLabel)
                            .font(.subheadline)
                        Spacer()
                        Button("Undo") {
                            Task { await undoLastRemoval() }
                        }
                        .fontWeight(.semibold)
                        .frame(minHeight: 44)
                        Button {
                            viewModel.recentlyDeletedActivity = nil
                            viewModel.recentlyDeletedVaccination = nil
                            viewModel.recentlyDeletedWeight = nil
                        } label: {
                            Image(systemName: "xmark")
                                .frame(width: 44, height: 44)
                        }
                        .accessibilityLabel("Dismiss undo")
                    }
                    .padding(.horizontal)
                    .background(.bar)
                }
            }
        }
    }

    private var undoLabel: String {
        if let activity = viewModel.recentlyDeletedActivity {
            return "\(viewModel.displayLabel(for: activity.activityType)) removed"
        }
        if viewModel.recentlyDeletedVaccination != nil { return "Vaccination removed" }
        return "Weight removed"
    }

    private func undoLastRemoval() async {
        if viewModel.recentlyDeletedActivity != nil {
            await viewModel.undoDeleteActivity()
        } else if viewModel.recentlyDeletedVaccination != nil {
            await viewModel.undoDeleteVaccination()
        } else {
            await viewModel.undoDeleteWeight()
        }
    }

    private var petRecordView: some View {
        DisclosureGroup(isExpanded: $showingPetRecord) {
            VStack(alignment: .leading, spacing: 18) {
                petProfileSummary
                weightRecordsView
                vaccinationRecordsView
                documentRecordsView
            }
            .padding(.top, 14)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "cross.case.fill")
                    .foregroundStyle(.teal)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pet record")
                        .font(.headline)
                    Text("Vet, insurance, health and documents")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 44)
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal)
    }

    private var petProfileSummary: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Important details")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button("Edit") { viewModel.showingProfileEditor = true }
                    .frame(minHeight: 44)
            }

            let details: [(String, String?)] = [
                ("Breed", viewModel.profile.breed),
                ("Microchip", viewModel.profile.microchipNumber),
                ("Insurance", viewModel.profile.insuranceProvider),
                ("Vet", viewModel.profile.vetName),
                ("Allergies", viewModel.profile.allergies),
                ("Medicine", viewModel.profile.medicineNotes),
            ]
            let visible = details.filter { !($0.1 ?? "").isEmpty }
            if visible.isEmpty {
                Text("Add the details you would want during a vet call.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(visible, id: \.0) { label, value in
                    HStack(alignment: .firstTextBaseline) {
                        Text(label)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(value ?? "")
                            .multilineTextAlignment(.trailing)
                    }
                    .font(.caption)
                }
            }
        }
    }

    private var weightRecordsView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Weight")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    viewModel.showingAddWeight = true
                } label: {
                    Label("Add", systemImage: "plus")
                        .frame(minHeight: 44)
                }
            }
            if viewModel.weights.isEmpty {
                Text("No weight recorded")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.weights.prefix(5)) { weight in
                    Button {
                        editingWeight = weight
                    } label: {
                        HStack {
                            Text("\(weight.weightKg.formatted(.number.precision(.fractionLength(0...1)))) kg")
                                .font(.subheadline.weight(.semibold))
                            Text(viewModel.formattedDate(weight.measuredOn))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var documentRecordsView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Documents")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    viewModel.showingDocumentPicker = true
                } label: {
                    Label("Add", systemImage: "paperclip")
                        .frame(minHeight: 44)
                }
            }
            if viewModel.documents.isEmpty {
                Text("Insurance, microchip and vet documents can live here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.documents) { document in
                    HStack(spacing: 8) {
                        Button {
                            openDocument(document)
                        } label: {
                            HStack(spacing: 10) {
                            Image(systemName: "doc.fill")
                            VStack(alignment: .leading, spacing: 2) {
                                Text(document.title)
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)
                                Text(documentRoleLabel(document.role))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if isOpeningDocument { ProgressView() }
                            }
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        }
                        .buttonStyle(.plain)

                        Button {
                            documentToRemove = document
                        } label: {
                            Image(systemName: "xmark")
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(document.title) from the pet record")
                    }
                }
            }
        }
    }

    private func openDocument(_ document: DogDocumentDTO) {
        guard !isOpeningDocument else { return }
        isOpeningDocument = true
        Task {
            defer { isOpeningDocument = false }
            do {
                let url = try await DocumentPreviewStore.download(document.sourceDocument)
                previewItem = DocumentPreviewItem(url: url, title: document.title)
            } catch {
                viewModel.errorMessage = "The document couldn't be opened. Try again.".localized
            }
        }
    }

    private func documentRoleLabel(_ role: String) -> String {
        switch role {
        case "insurance": return "Insurance"
        case "vet": return "Vet record"
        case "microchip": return "Microchip"
        case "medicine": return "Medicine"
        default: return "Pet record"
        }
    }

    // MARK: - Vaccination Records

    private var vaccinationRecordsView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Vaccinations")
                        .font(.subheadline.weight(.semibold))
                }
                Spacer()
                Button {
                    viewModel.errorMessage = nil
                    viewModel.resetVaccinationForm()
                    viewModel.showingAddVaccination = true
                } label: {
                    Label("Add vaccination", systemImage: "plus")
                        .font(.subheadline.weight(.semibold))
                        .frame(minHeight: 44)
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.isLoading)
            }

            if viewModel.isLoading && viewModel.vaccinations.isEmpty {
                ProgressView("Loading vaccinations...")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            } else if viewModel.vaccinations.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "syringe")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("No vaccinations recorded")
                        .font(.subheadline.weight(.semibold))
                    Text("Add past vaccinations and any known renewal dates.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Add vaccination") {
                        viewModel.errorMessage = nil
                        viewModel.resetVaccinationForm()
                        viewModel.showingAddVaccination = true
                    }
                    .buttonStyle(.bordered)
                    .frame(minHeight: 44)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(viewModel.vaccinations) { vaccination in
                        vaccinationRow(vaccination)
                    }
                }
            }
        }
    }

    private func vaccinationRow(_ vaccination: DogVaccinationDTO) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "syringe.fill")
                .foregroundStyle(.teal)
                .frame(width: 36, height: 36)
                .background(Color.teal.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))

            Button {
                editingVaccination = vaccination
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(vaccination.vaccineName)
                        .font(.subheadline.weight(.semibold))
                    Text("Given \(viewModel.formattedDate(vaccination.givenOn))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let nextDue = vaccination.nextDueOn {
                        Text("Next due \(viewModel.formattedDate(nextDue))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let notes = vaccination.notes, !notes.isEmpty {
                        Text(notes)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens this vaccination for correction")

            Spacer(minLength: 8)

            Button(role: .destructive) {
                vaccinationToDelete = vaccination
            } label: {
                Image(systemName: "trash")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delete \(vaccination.vaccineName) vaccination")
        }
        .padding(.vertical, 6)
    }

    // MARK: - Status Header

    private var statusHeaderView: some View {
        HStack(spacing: 12) {
            statusCard(
                title: viewModel.activeWalk != nil
                    ? "Walking now"
                    : careTitle("Walk", state: viewModel.walkState),
                symbol: viewModel.activeWalk != nil
                    ? "figure.walk.motion"
                    : careSymbol("figure.walk.circle", state: viewModel.walkState),
                color: viewModel.activeWalk != nil ? .blue : careColor(viewModel.walkState)
            )
            statusCard(
                title: careTitle("Breakfast", state: viewModel.breakfastState),
                symbol: careSymbol("sunrise", state: viewModel.breakfastState),
                color: careColor(viewModel.breakfastState)
            )
            statusCard(
                title: careTitle("Dinner", state: viewModel.dinnerState),
                symbol: careSymbol("sunset", state: viewModel.dinnerState),
                color: careColor(viewModel.dinnerState)
            )
        }
        .padding(.horizontal)
    }

    private func careTitle(_ label: String, state: String) -> String {
        switch state {
        case "done": return "\(label) done"
        case "overdue": return "\(label) overdue"
        case "due": return "\(label) due"
        default: return "\(label) later"
        }
    }

    private func careSymbol(_ fallback: String, state: String) -> String {
        state == "done" ? "checkmark.circle.fill" : fallback
    }

    private func careColor(_ state: String) -> Color {
        switch state {
        case "done": return .green
        case "due", "overdue": return .orange
        default: return Color(.secondaryLabel)
        }
    }

    private func statusCard(title: String, symbol: String, color: Color) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 32))
                .foregroundStyle(color)

            Text(title)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(color)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(color.opacity(0.1))
        .cornerRadius(16)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title)")
    }

    // MARK: - Quick Actions

    private var quickActionsView: some View {
        VStack(spacing: 12) {
            Button {
                Task {
                    await viewModel.logQuickWalk()
                }
            } label: {
                HStack {
                    Label(
                        viewModel.activeWalk == nil ? "Start Walk" : "End Walk",
                        systemImage: viewModel.activeWalk == nil ? "figure.walk" : "stop.circle.fill"
                    )
                    .font(.subheadline.weight(.semibold))
                    if let activeWalk = viewModel.activeWalk,
                       let started = ISODateParser.parse(activeWalk.startedAt) {
                        Spacer()
                        Text(started, style: .timer)
                            .monospacedDigit()
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .tint(viewModel.activeWalk == nil ? .blue : .orange)
            .disabled(viewModel.isLoading)

            HStack(spacing: 12) {
                // Breakfast button with duplicate prevention
                Button {
                    if viewModel.breakfastActivityToday != nil {
                        showBreakfastDuplicateAlert = true
                    } else {
                        Task { await viewModel.logQuickBreakfast() }
                    }
                } label: {
                    VStack(spacing: 4) {
                        Label("Fed Breakfast", systemImage: "sunrise.fill")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        if let activity = viewModel.breakfastActivityToday {
                            Text(viewModel.alreadyFedDescription(for: activity))
                                .font(.caption2)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .tint(viewModel.breakfastActivityToday != nil ? .gray : .orange)
                .disabled(viewModel.isLoading)

                // Dinner button with duplicate prevention
                Button {
                    if viewModel.dinnerActivityToday != nil {
                        showDinnerDuplicateAlert = true
                    } else {
                        Task { await viewModel.logQuickDinner() }
                    }
                } label: {
                    VStack(spacing: 4) {
                        Label("Fed Dinner", systemImage: "sunset.fill")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        if let activity = viewModel.dinnerActivityToday {
                            Text(viewModel.alreadyFedDescription(for: activity))
                                .font(.caption2)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .tint(viewModel.dinnerActivityToday != nil ? .gray : .orange)
                .disabled(viewModel.isLoading)
            }
        }
        .padding(.horizontal)
    }

    // MARK: - Activity History

    private var activityHistoryView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent Activity")
                .font(.headline)
                .padding(.horizontal)

            if viewModel.isLoading && viewModel.activities.isEmpty {
                loadingView
            } else if viewModel.activities.isEmpty {
                emptyStateView
            } else {
                List {
                    ForEach(viewModel.activities) { activity in
                        activityRow(activity)
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.hidden)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    activityToDelete = activity
                                    showDeleteConfirmation = true
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                }
                .listStyle(.plain)
                .frame(minHeight: CGFloat(viewModel.activities.count) * 60)
                .background(Color(.secondarySystemGroupedBackground))
                .cornerRadius(12)
                .padding(.horizontal)
                .scrollDisabled(true)
            }
        }
    }

    private func activityRow(_ activity: DogActivityDTO) -> some View {
        Button {
            viewModel.errorMessage = nil
            viewModel.editingActivity = activity
        } label: {
            HStack(spacing: 12) {
                Image(systemName: viewModel.iconName(for: activity.activityType))
                    .font(.title3)
                    .foregroundStyle(viewModel.iconColor(for: activity.activityType))
                    .frame(width: 36, height: 36)
                    .background(viewModel.iconColor(for: activity.activityType).opacity(0.15))
                    .cornerRadius(8)

                VStack(alignment: .leading, spacing: 2) {
                    Text(viewModel.displayLabel(for: activity.activityType))
                        .font(.subheadline)
                        .fontWeight(.semibold)

                    Text(viewModel.formattedDateTime(activity.startedAt))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if activity.isActive {
                        Text("In progress")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.blue)
                    }

                    if let endedAt = activity.endedAt,
                       let started = ISODateParser.parse(activity.startedAt),
                       let ended = ISODateParser.parse(endedAt), ended > started {
                        Text("\(Int(ended.timeIntervalSince(started) / 60)) minutes")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let notes = activity.notes, !notes.isEmpty {
                        Text(notes)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                    }
                }

                Spacer()

                if let doneByDisplay = viewModel.displayDoneBy(activity.doneBy) {
                    Text(doneByDisplay)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color(.tertiarySystemFill))
                        .cornerRadius(6)
                }

                Image(systemName: "pencil")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens this record for correction")
    }

    // MARK: - States

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text("Loading activities...")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Image(systemName: "pawprint")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("No activities yet")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Use the quick actions above or tap + to log an activity")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .padding(.horizontal)
    }

    // MARK: - Error Banner

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding()
        .background(Color.orange.opacity(0.1))
        .cornerRadius(12)
        .padding(.horizontal)
    }

    // MARK: - Add Activity Sheet

    private var addActivitySheet: some View {
        NavigationStack {
            Form {
                Section("Activity Details") {
                    Picker("Type", selection: $viewModel.formActivityType) {
                        ForEach(viewModel.activityTypes, id: \.self) { type in
                            Label(viewModel.displayLabel(for: type), systemImage: viewModel.iconName(for: type))
                                .tag(type)
                        }
                    }

                    DatePicker(
                        viewModel.formActivityType == "walk" ? "Started" : "Time",
                        selection: $viewModel.formStartedAt,
                        in: ...Date()
                    )
                    if viewModel.formActivityType == "walk" {
                        Toggle("Record when the walk ended", isOn: $viewModel.formHasEndTime)
                        if viewModel.formHasEndTime {
                            DatePicker(
                                "Ended",
                                selection: $viewModel.formEndedAt,
                                in: viewModel.formStartedAt...Date()
                            )
                        }
                    }
                }

                Section("Notes") {
                    TextField("Optional notes", text: $viewModel.formNotes, axis: .vertical)
                        .lineLimit(3...6)
                }

                if let errorMessage = viewModel.errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }
            }
            .navigationTitle("Log Activity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        viewModel.showingAddActivity = false
                        viewModel.resetForm()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            await viewModel.logActivity()
                        }
                    }
                    .disabled(viewModel.isLoading)
                }
            }
            .onChange(of: viewModel.formStartedAt) { _, startedAt in
                if viewModel.formEndedAt < startedAt {
                    viewModel.formEndedAt = startedAt
                }
            }
        }
    }

    private var addVaccinationSheet: some View {
        NavigationStack {
            Form {
                Section("Vaccination") {
                    TextField("Vaccine name", text: $viewModel.vaccinationName)
                        .textInputAutocapitalization(.words)
                        .onChange(of: viewModel.vaccinationName) { _, value in
                            if value.count > 120 {
                                viewModel.vaccinationName = String(value.prefix(120))
                            }
                        }
                    DatePicker(
                        "Given on",
                        selection: $viewModel.vaccinationGivenOn,
                        in: ...Date(),
                        displayedComponents: .date
                    )
                    Toggle("Add next due date", isOn: $viewModel.vaccinationHasNextDue)
                    if viewModel.vaccinationHasNextDue {
                        DatePicker(
                            "Next due",
                            selection: $viewModel.vaccinationNextDueOn,
                            in: Calendar.current.startOfDay(for: viewModel.vaccinationGivenOn)...,
                            displayedComponents: .date
                        )
                    }
                }

                Section("Notes (optional)") {
                    TextField("For example, annual booster", text: $viewModel.vaccinationNotes, axis: .vertical)
                        .lineLimit(2...5)
                        .onChange(of: viewModel.vaccinationNotes) { _, value in
                            if value.count > 2_000 {
                                viewModel.vaccinationNotes = String(value.prefix(2_000))
                            }
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
            .navigationTitle("Add dog vaccination")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(viewModel.isLoading)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        viewModel.showingAddVaccination = false
                    }
                    .disabled(viewModel.isLoading)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        Task {
                            if await viewModel.addVaccination() {
                                viewModel.showingAddVaccination = false
                            }
                        }
                    }
                    .disabled(
                        viewModel.vaccinationName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || viewModel.isLoading
                    )
                }
            }
            .onChange(of: viewModel.vaccinationGivenOn) { _, givenOn in
                if viewModel.vaccinationNextDueOn < givenOn {
                    viewModel.vaccinationNextDueOn = givenOn
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct DogProfileEditorSheet: View {
    @ObservedObject var viewModel: DogViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var breed: String
    @State private var hasBirthDate: Bool
    @State private var birthDate: Date
    @State private var breakfastStart: Date
    @State private var breakfastEnd: Date
    @State private var walkStart: Date
    @State private var walkEnd: Date
    @State private var dinnerStart: Date
    @State private var dinnerEnd: Date
    @State private var microchip: String
    @State private var insuranceProvider: String
    @State private var insurancePolicy: String
    @State private var vetName: String
    @State private var vetPhone: String
    @State private var allergies: String
    @State private var medicineNotes: String

    init(viewModel: DogViewModel) {
        self.viewModel = viewModel
        let profile = viewModel.profile
        _name = State(initialValue: profile.name)
        _breed = State(initialValue: profile.breed ?? "")
        let parsedBirthDate = profile.dateOfBirth.flatMap(ISODateParser.parse)
        _hasBirthDate = State(initialValue: parsedBirthDate != nil)
        _birthDate = State(initialValue: parsedBirthDate ?? Date())
        _breakfastStart = State(initialValue: Self.time(profile.breakfastWindowStart))
        _breakfastEnd = State(initialValue: Self.time(profile.breakfastWindowEnd))
        _walkStart = State(initialValue: Self.time(profile.walkWindowStart))
        _walkEnd = State(initialValue: Self.time(profile.walkWindowEnd))
        _dinnerStart = State(initialValue: Self.time(profile.dinnerWindowStart))
        _dinnerEnd = State(initialValue: Self.time(profile.dinnerWindowEnd))
        _microchip = State(initialValue: profile.microchipNumber ?? "")
        _insuranceProvider = State(initialValue: profile.insuranceProvider ?? "")
        _insurancePolicy = State(initialValue: profile.insurancePolicyNumber ?? "")
        _vetName = State(initialValue: profile.vetName ?? "")
        _vetPhone = State(initialValue: profile.vetPhone ?? "")
        _allergies = State(initialValue: profile.allergies ?? "")
        _medicineNotes = State(initialValue: profile.medicineNotes ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("About") {
                    TextField("Name", text: $name)
                    TextField("Breed (optional)", text: $breed)
                    Toggle("Add date of birth", isOn: $hasBirthDate)
                    if hasBirthDate {
                        DatePicker("Date of birth", selection: $birthDate, in: ...Date(), displayedComponents: .date)
                    }
                }

                Section {
                    careWindow("Breakfast", start: $breakfastStart, end: $breakfastEnd)
                    careWindow("Walk", start: $walkStart, end: $walkEnd)
                    careWindow("Dinner", start: $dinnerStart, end: $dinnerEnd)
                } header: {
                    Text("Usual care times")
                } footer: {
                    Text("These times decide when Today says something is due or overdue.")
                }

                Section("Vet and identification") {
                    TextField("Vet", text: $vetName)
                    TextField("Vet phone", text: $vetPhone)
                        .keyboardType(.phonePad)
                    TextField("Microchip number", text: $microchip)
                    TextField("Insurance provider", text: $insuranceProvider)
                    TextField("Policy number", text: $insurancePolicy)
                }

                Section("Important health notes") {
                    TextField("Allergies", text: $allergies, axis: .vertical)
                        .lineLimit(2...5)
                    TextField("Regular medicine", text: $medicineNotes, axis: .vertical)
                        .lineLimit(2...5)
                }

                if let error = viewModel.errorMessage {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Pet record")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(viewModel.isLoading)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(viewModel.isLoading)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            let request = DogProfileUpdateRequest(
                                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                dateOfBirth: hasBirthDate ? RenewalsViewModel.dateString(birthDate) : nil,
                                breed: optional(breed),
                                microchipNumber: optional(microchip),
                                insuranceProvider: optional(insuranceProvider),
                                insurancePolicyNumber: optional(insurancePolicy),
                                vetName: optional(vetName),
                                vetPhone: optional(vetPhone),
                                allergies: optional(allergies),
                                medicineNotes: optional(medicineNotes),
                                breakfastWindowStart: Self.timeString(breakfastStart),
                                breakfastWindowEnd: Self.timeString(breakfastEnd),
                                walkWindowStart: Self.timeString(walkStart),
                                walkWindowEnd: Self.timeString(walkEnd),
                                dinnerWindowStart: Self.timeString(dinnerStart),
                                dinnerWindowEnd: Self.timeString(dinnerEnd)
                            )
                            if await viewModel.saveProfile(request) { dismiss() }
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.isLoading)
                }
            }
        }
    }

    @ViewBuilder
    private func careWindow(_ label: String, start: Binding<Date>, end: Binding<Date>) -> some View {
        LabeledContent(label) {
            HStack(spacing: 8) {
                DatePicker("Start", selection: start, displayedComponents: .hourAndMinute)
                    .labelsHidden()
                Text("to").foregroundStyle(.secondary)
                DatePicker("End", selection: end, displayedComponents: .hourAndMinute)
                    .labelsHidden()
            }
        }
    }

    private func optional(_ value: String) -> String? {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }

    private static func time(_ value: String) -> Date {
        let parts = value.split(separator: ":").compactMap { Int($0) }
        var components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        components.hour = parts.first ?? 0
        components.minute = parts.count > 1 ? parts[1] : 0
        return Calendar.current.date(from: components) ?? Date()
    }

    private static func timeString(_ date: Date) -> String {
        let values = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", values.hour ?? 0, values.minute ?? 0)
    }
}

private struct DogWeightEditorSheet: View {
    @ObservedObject var viewModel: DogViewModel
    let weight: DogWeightDTO?
    @Environment(\.dismiss) private var dismiss
    @State private var measuredOn: Date
    @State private var weightText: String
    @State private var notes: String
    @State private var confirmingRemoval = false

    init(viewModel: DogViewModel, weight: DogWeightDTO? = nil) {
        self.viewModel = viewModel
        self.weight = weight
        let measuredDate = weight.flatMap { ISODateParser.parse($0.measuredOn) }
        _measuredOn = State(initialValue: measuredDate ?? Date())
        _weightText = State(initialValue: weight.map { $0.weightKg.formatted(.number.precision(.fractionLength(0...1))) } ?? "")
        _notes = State(initialValue: weight?.notes ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Measurement") {
                    TextField("Weight in kg", text: $weightText)
                        .keyboardType(.decimalPad)
                    DatePicker("Date", selection: $measuredOn, in: ...Date(), displayedComponents: .date)
                    TextField("Notes (optional)", text: $notes, axis: .vertical)
                }
                if let error = viewModel.errorMessage {
                    Section { Text(error).foregroundStyle(.red) }
                }
                if weight != nil {
                    Section {
                        Button("Remove Measurement", role: .destructive) { confirmingRemoval = true }
                    }
                }
            }
            .navigationTitle(weight == nil ? "Add weight" : "Correct weight")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            let saved: Bool
                            if let weight {
                                saved = await viewModel.updateWeight(
                                    weight,
                                    measuredOn: measuredOn,
                                    weightText: weightText,
                                    notes: notes
                                )
                            } else {
                                saved = await viewModel.addWeight(
                                    measuredOn: measuredOn,
                                    weightText: weightText,
                                    notes: notes
                                )
                            }
                            if saved { dismiss() }
                        }
                    }
                    .disabled(weightText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.isLoading)
                }
            }
            .confirmationDialog("Remove this measurement?", isPresented: $confirmingRemoval) {
                if let weight {
                    Button("Remove Measurement", role: .destructive) {
                        Task {
                            await viewModel.deleteWeight(weight)
                            dismiss()
                        }
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }
}

private struct DogVaccinationEditorSheet: View {
    @ObservedObject var viewModel: DogViewModel
    let vaccination: DogVaccinationDTO
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var givenOn: Date
    @State private var hasNextDue: Bool
    @State private var nextDueOn: Date
    @State private var notes: String
    @State private var confirmingRemoval = false

    init(viewModel: DogViewModel, vaccination: DogVaccinationDTO) {
        self.viewModel = viewModel
        self.vaccination = vaccination
        let given = ISODateParser.parse(vaccination.givenOn) ?? Date()
        let next = vaccination.nextDueOn.flatMap(ISODateParser.parse)
        _name = State(initialValue: vaccination.vaccineName)
        _givenOn = State(initialValue: given)
        _hasNextDue = State(initialValue: next != nil)
        _nextDueOn = State(initialValue: next ?? given)
        _notes = State(initialValue: vaccination.notes ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Vaccination") {
                    TextField("Vaccine name", text: $name)
                    DatePicker("Given on", selection: $givenOn, in: ...Date(), displayedComponents: .date)
                    Toggle("Add next due date", isOn: $hasNextDue)
                    if hasNextDue {
                        DatePicker("Next due", selection: $nextDueOn, in: givenOn..., displayedComponents: .date)
                    }
                    TextField("Notes (optional)", text: $notes, axis: .vertical)
                }
                if let error = viewModel.errorMessage {
                    Section { Text(error).foregroundStyle(.red) }
                }
                Section {
                    Button("Remove Vaccination", role: .destructive) { confirmingRemoval = true }
                }
            }
            .navigationTitle("Correct vaccination")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            if await viewModel.updateVaccination(
                                vaccination,
                                name: name,
                                givenOn: givenOn,
                                nextDueOn: hasNextDue ? nextDueOn : nil,
                                notes: notes
                            ) { dismiss() }
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.isLoading)
                }
            }
            .confirmationDialog("Remove this vaccination?", isPresented: $confirmingRemoval) {
                Button("Remove Vaccination", role: .destructive) {
                    Task {
                        await viewModel.deleteVaccination(vaccination.id)
                        dismiss()
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }
}

private struct DogActivityCorrectionSheet: View {
    @ObservedObject var viewModel: DogViewModel
    let activity: DogActivityDTO
    @Environment(\.dismiss) private var dismiss
    @State private var activityType: String
    @State private var startedAt: Date
    @State private var hasEndTime: Bool
    @State private var endedAt: Date
    @State private var notes: String
    @State private var confirmingRemoval = false

    init(viewModel: DogViewModel, activity: DogActivityDTO) {
        self.viewModel = viewModel
        self.activity = activity
        let start = ISODateParser.parse(activity.startedAt) ?? Date()
        let end = activity.endedAt.flatMap(ISODateParser.parse)
        _activityType = State(initialValue: activity.activityType)
        _startedAt = State(initialValue: start)
        _hasEndTime = State(initialValue: end != nil)
        _endedAt = State(initialValue: end ?? start)
        _notes = State(initialValue: activity.notes ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("What Happened") {
                    Picker("Activity", selection: $activityType) {
                        ForEach(viewModel.activityTypes, id: \.self) { type in
                            Label(
                                viewModel.displayLabel(for: type),
                                systemImage: viewModel.iconName(for: type)
                            )
                            .tag(type)
                        }
                    }
                    DatePicker("Started", selection: $startedAt, in: ...Date())
                    if activityType == "walk" {
                        Toggle("Record an end time", isOn: $hasEndTime)
                        if hasEndTime {
                            DatePicker("Ended", selection: $endedAt, in: startedAt...Date())
                        }
                    }
                    TextField("Notes (optional)", text: $notes, axis: .vertical)
                        .lineLimit(2...5)
                }

                if let error = viewModel.errorMessage {
                    Section {
                        Label(error, systemImage: "exclamationmark.circle")
                            .font(.subheadline)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button {
                        Task {
                            if await viewModel.updateActivity(
                                activity,
                                activityType: activityType,
                                startedAt: startedAt,
                                endedAt: activityType == "walk" && hasEndTime ? endedAt : nil,
                                notes: notes
                            ) {
                                dismiss()
                            }
                        }
                    } label: {
                        HStack {
                            if viewModel.isLoading { ProgressView() }
                            Text("Save Correction")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .disabled(viewModel.isLoading)
                }

                Section {
                    Button("Remove Mistaken Record", role: .destructive) {
                        confirmingRemoval = true
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
            }
            .navigationTitle("Correct Dog Care")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(viewModel.isLoading)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(viewModel.isLoading)
                }
            }
            .onChange(of: startedAt) { _, start in
                if endedAt < start { endedAt = start }
            }
            .confirmationDialog(
                "Remove this record?",
                isPresented: $confirmingRemoval,
                titleVisibility: .visible
            ) {
                Button("Remove Record", role: .destructive) {
                    Task {
                        await viewModel.deleteActivity(activity)
                        if viewModel.recentlyDeletedActivity?.id == activity.id {
                            dismiss()
                        }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("You can undo immediately if this was a mistake.")
            }
        }
    }
}

// MARK: - Preview

#Preview {
    DogView()
}
