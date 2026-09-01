import SwiftUI


/// The medicine tracking view. This is the most SAFETY-CRITICAL view in the app.
/// All warnings are displayed prominently and never suppressed.
struct MedicineView: View {
    @StateObject private var viewModel = MedicineViewModel()
    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var timelineMedicine: MedicineTypeDTO?
    @State private var medicinePendingArchive: MedicineTypeDTO?
    let initialChildId: String?
    let initialMedicineTypeId: String?
    let reviewRequestId: UUID?
    let startWithLogDose: Bool

    init(
        initialChildId: String? = nil,
        initialMedicineTypeId: String? = nil,
        reviewRequestId: UUID? = nil,
        startWithLogDose: Bool = false
    ) {
        self.initialChildId = initialChildId
        self.initialMedicineTypeId = initialMedicineTypeId
        self.reviewRequestId = reviewRequestId
        self.startWithLogDose = startWithLogDose
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // MARK: - Child Selector
                childSelector

                // MARK: - Ill Mode Banner
                illModeBanner

                if viewModel.showWarnings && !viewModel.lastDoseWarnings.isEmpty {
                    warningsBanner(warnings: viewModel.lastDoseWarnings)
                }

                if viewModel.isLoading && viewModel.medicineTypes.isEmpty {
                    loadingView
                } else if let error = viewModel.errorMessage,
                          viewModel.medicineTypes.isEmpty {
                    errorView(message: error)
                } else {
                    medicineTypesSection
                }

                logDoseButton
                recentDosesSection
                disclaimerView

                if let error = viewModel.errorMessage,
                   !viewModel.medicineTypes.isEmpty {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier(HausKlarAccessibilityID.Medicine.error)
                }
            }
            .padding()
        }
        .navigationTitle("Medicine")
        .accessibilityIdentifier(HausKlarAccessibilityID.Medicine.screen)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("New medicine", systemImage: "plus") {
                    viewModel.prepareNewMedicineType()
                }
                .accessibilityLabel("Add medicine type")
                .accessibilityIdentifier(HausKlarAccessibilityID.Medicine.addType)
            }
        }
        .sheet(isPresented: $viewModel.showingLogDose) {
            LogDoseSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $viewModel.showingAddType) {
            AddMedicineTypeSheet(viewModel: viewModel)
        }
        .sheet(item: $timelineMedicine) { medicine in
            MedicineTimelineSheet(
                viewModel: viewModel,
                medicine: medicine
            )
        }
        .sheet(item: $viewModel.editingDose) { dose in
            MedicineDoseCorrectionSheet(viewModel: viewModel, dose: dose)
        }
        .confirmationDialog(
            "Archive \(medicinePendingArchive?.name ?? "this medicine")?",
            isPresented: Binding(
                get: { medicinePendingArchive != nil },
                set: { if !$0 { medicinePendingArchive = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let medicinePendingArchive {
                Button("Archive Medicine", role: .destructive) {
                    Task {
                        await viewModel.archiveMedicineType(medicinePendingArchive)
                        self.medicinePendingArchive = nil
                    }
                }
            }
            Button("Cancel", role: .cancel) {
                medicinePendingArchive = nil
            }
        } message: {
            Text("Past dose records stay in the family history.")
        }
        .safeAreaInset(edge: .bottom) {
            if let dose = viewModel.recentlyDeletedDose {
                HStack(spacing: 12) {
                    Text("Dose record removed")
                        .font(.subheadline)
                    Spacer()
                    Button("Undo") {
                        Task { await viewModel.undoDeleteDose() }
                    }
                    .fontWeight(.semibold)
                    .frame(minHeight: 44)
                    Button {
                        viewModel.recentlyDeletedDose = nil
                    } label: {
                        Image(systemName: "xmark")
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Dismiss undo for \(viewModel.doseDisplayName(dose))")
                }
                .padding(.horizontal)
                .background(.bar)
            }
        }
        .task(id: reviewRequestId) {
            if let initialChildId { viewModel.selectedChildId = initialChildId }
            viewModel.bindModelContext(modelContext)
            await viewModel.loadData()
            if let initialMedicineTypeId,
               let medicine = viewModel.medicineTypes.first(where: { $0.id == initialMedicineTypeId }) {
                viewModel.prepareDoseReview(for: medicine)
            } else if startWithLogDose {
                viewModel.resetLogDoseForm()
                viewModel.showingLogDose = true
            }
        }
        .refreshable {
            await viewModel.loadData()
        }
    }

    // MARK: - Child Selector

    private var childSelector: some View {
        Group {
            if viewModel.children.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(viewModel.children) { child in
                            Button {
                                viewModel.selectedChildId = child.id
                                Task {
                                    await viewModel.loadData()
                                }
                            } label: {
                                Text(child.name)
                                    .font(.subheadline)
                                    .fontWeight(viewModel.selectedChildId == child.id ? .semibold : .regular)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 8)
                                    .background(
                                        viewModel.selectedChildId == child.id
                                            ? Color.accentColor
                                            : Color(.systemGray5)
                                    )
                                    .foregroundStyle(
                                        viewModel.selectedChildId == child.id
                                            ? .white
                                            : .primary
                                    )
                                    .clipShape(Capsule())
                            }
                            .accessibilityAddTraits(viewModel.selectedChildId == child.id ? .isSelected : [])
                        }
                    }
                    .padding(.horizontal, 4)
                }
                .accessibilityIdentifier(HausKlarAccessibilityID.Medicine.childSelector)
            }
        }
    }

    // MARK: - Ill Mode Banner

    private var illModeBanner: some View {
        Group {
            if viewModel.activeIllness != nil {
                NavigationLink {
                    IllnessDetailView(initialChildId: viewModel.selectedChildId)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "thermometer.high")
                            .font(.title2)
                            .foregroundStyle(.red)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Ill Mode Active")
                                .font(.headline)
                                .foregroundStyle(.red)
                            Text("Tap to view illness tracker")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Image(systemName: "chevron.right")
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                    .background(Color.red.opacity(0.1))
                    .cornerRadius(12)
                }
                .buttonStyle(.plain)
            } else {
                NavigationLink {
                    IllnessDetailView(initialChildId: viewModel.selectedChildId)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "heart.fill")
                            .foregroundStyle(.green)
                        Text("Illness Tracker")
                            .font(.subheadline)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(12)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Medicine Types Section

    private var medicineTypesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Medicines")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)

            if viewModel.filteredMedicineTypes.isEmpty {
                emptyMedicineTypesView
            } else {
                ForEach(viewModel.filteredMedicineTypes) { type in
                    medicineTypeCard(type)
                }
            }
        }
    }

    private func medicineTypeCard(_ type: MedicineTypeDTO) -> some View {
        let safetyColor = viewModel.safetyColor(for: type)
        let dosesUsed = viewModel.dosesIn24h(for: type)
        let hasCompleteSummary = viewModel.hasCompleteSafetySummary(for: type)
        let brandColor = type.color.flatMap { Color(hex: $0) }
        let lastDoseInfo = viewModel.lastDoseInfo(for: type)

        return HStack(spacing: 0) {
            if let brandColor {
                RoundedRectangle(cornerRadius: 4)
                    .fill(brandColor)
                    .frame(width: 5)
                    .padding(.vertical, 8)
            }

            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(type.name)
                        .font(.headline)
                        .foregroundStyle(.primary)

                    if let defaultDose = type.defaultDoseAmount {
                        Text(defaultDose)
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background((brandColor ?? .secondary).opacity(0.12))
                            .clipShape(Capsule())
                    }

                    Spacer()
                    Menu {
                        Button("Edit Medicine", systemImage: "pencil") {
                            viewModel.prepareMedicineTypeEditor(type)
                        }
                        Button("Archive Medicine", systemImage: "archivebox", role: .destructive) {
                            medicinePendingArchive = type
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("More options for \(type.name)")
                }

                if let notes = type.notes, !notes.isEmpty {
                    Text(notes)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 5) {
                    if hasCompleteSummary, lastDoseInfo != nil {
                        Label {
                            Text(safetyLabel(for: safetyColor))
                                .foregroundStyle(.primary)
                        } icon: {
                            Image(systemName: safetyIcon(for: safetyColor))
                                .foregroundStyle(safetyColor)
                        }
                        .font(.caption.weight(.semibold))
                        .accessibilityLabel(safetyAccessibilityLabel(for: safetyColor))
                    }
                    if !hasCompleteSummary {
                        Text("Saved-limit summary unavailable. Review dose history before recording.")
                    } else if let lastInfo = lastDoseInfo {
                        Text(lastInfo)
                    } else {
                        Text("No dose recorded yet")
                    }
                    if hasCompleteSummary {
                        Text("\(dosesUsed) of \(type.maxDoses24h) recorded in the last 24 hours")
                    }
                    if let nextSafe = viewModel.nextSafeTime(for: type) {
                        Text("Saved interval ends at \(nextSafe)")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if safetyColor == .red || dosesUsed >= type.maxDoses24h {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        Text(
                            dosesUsed >= type.maxDoses24h
                                ? "The saved 24-hour count has been reached. Review before recording another dose."
                                : "The saved interval has not elapsed. Review the timing before recording another dose."
                        )
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundStyle(.primary)
                    }
                }

                doseActions(for: type)
            }
            .padding()
        }
        .background(Color(.secondarySystemBackground))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder((brandColor ?? Color.secondary).opacity(0.3), lineWidth: 1)
        )
        .cornerRadius(12)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(HausKlarAccessibilityID.Medicine.typeCard(type.id))
    }

    @ViewBuilder
    private func doseActions(for type: MedicineTypeDTO) -> some View {
        let review = Button {
            viewModel.prepareDoseReview(for: type)
        } label: {
            Label("Review Dose", systemImage: "cross.case.fill")
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier(HausKlarAccessibilityID.Medicine.reviewDose(type.id))

        let history = Button {
            timelineMedicine = type
        } label: {
            Label("History", systemImage: "clock.arrow.circlepath")
                .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : nil)
                .frame(minHeight: 44)
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier(HausKlarAccessibilityID.Medicine.history(type.id))

        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: 8) {
                review
                history
            }
        } else {
            HStack(spacing: 8) {
                review
                history
            }
        }
    }

    // MARK: - Log Dose Button

    private var logDoseButton: some View {
        Button {
            viewModel.prepareOtherDoseReview()
        } label: {
            HStack {
                Image(systemName: "cross.case.fill")
                Text("Record Another Medicine")
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .accessibilityLabel("Review a dose for another medicine")
        .accessibilityIdentifier(HausKlarAccessibilityID.Medicine.logOther)
    }

    // MARK: - Recent Doses Section

    private var recentDosesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recorded Today")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)

            if viewModel.filteredRecentDoses.isEmpty {
                Text("No doses recorded today.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            } else {
                ForEach(viewModel.filteredRecentDoses) { dose in
                    doseRow(dose)
                }
            }
        }
    }

    private func doseRow(_ dose: MedicineDoseDTO) -> some View {
        Button {
            viewModel.editingDose = dose
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(viewModel.doseDisplayName(dose))
                        .font(.subheadline)
                        .fontWeight(.medium)

                    Spacer()

                    Text(viewModel.formattedTime(dose.givenAt))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Image(systemName: "pencil")
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 12) {
                    if let amount = dose.doseAmount, !amount.isEmpty {
                        Text(amount)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let givenBy = dose.givenBy, !givenBy.isEmpty {
                        Text("by \(givenBy)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Text(viewModel.relativeTime(dose.givenAt))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !dose.warnings.isEmpty {
                    inlineWarnings(dose.warnings)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(8)
        .accessibilityHint("Opens this dose for correction")
        .accessibilityIdentifier(HausKlarAccessibilityID.Medicine.recentDose(dose.id))
    }

    // MARK: - Warning Displays

    /// Prominent banner shown after logging a dose with warnings.
    private func warningsBanner(warnings: [SafetyWarningDTO]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.title3)
                Text("Saved-Limit Warnings")
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button {
                    if reduceMotion {
                        viewModel.showWarnings = false
                    } else {
                        withAnimation {
                            viewModel.showWarnings = false
                        }
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Dismiss warnings")
            }

            ForEach(warnings) { warning in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.subheadline)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(warning.message)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                        if let nextSafe = warning.nextSafeAt {
                            Text("Saved reminder interval ends: \(viewModel.formattedTime(nextSafe))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding()
        .background(Color.red.opacity(0.1))
        .cornerRadius(12)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(HausKlarAccessibilityID.Medicine.warnings)
    }

    /// Inline warning display for individual dose rows.
    private func inlineWarnings(_ warnings: [SafetyWarningDTO]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(warnings) { warning in
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                    Text(warning.message)
                        .font(.caption)
                        .foregroundStyle(.primary)
                }
            }
        }
        .padding(.top, 2)
    }

    // MARK: - Disclaimer

    private var disclaimerView: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
            Text("This app provides record-keeping reminders only. It does not recommend a dose or determine whether medicine is safe or appropriate. Follow the label or prescriber's instructions and consult a healthcare professional.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(8)
    }

    // MARK: - Empty / Loading / Error States

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Loading medicine data...")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(HausKlarAccessibilityID.Medicine.loading)
    }

    private func errorView(message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
            Button("Try Again") {
                Task {
                    await viewModel.loadData()
                }
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(HausKlarAccessibilityID.Medicine.error)
    }

    private var emptyMedicineTypesView: some View {
        VStack(spacing: 8) {
            Text("No medicines set up yet.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Add Medicine") {
                viewModel.prepareNewMedicineType()
            }
            .font(.subheadline)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .accessibilityIdentifier(HausKlarAccessibilityID.Medicine.empty)
    }

    // MARK: - Helpers

    private func safetyAccessibilityLabel(for color: Color) -> String {
        switch color {
        case .green:
            return "Saved reminder interval elapsed".localized
        case .orange:
            return "Approaching saved reminder interval".localized
        case .red:
            return "Saved reminder interval has not elapsed".localized
        default:
            return "Check the saved records".localized
        }
    }

    private func safetyIcon(for color: Color) -> String {
        switch color {
        case .green:
            return "checkmark.circle"
        case .orange:
            return "clock"
        case .red:
            return "xmark.circle"
        default:
            return "questionmark.circle"
        }
    }

    private func safetyLabel(for color: Color) -> String {
        switch color {
        case .green:
            return "Interval elapsed".localized
        case .orange:
            return "Interval ending".localized
        case .red:
            return "Interval active".localized
        default:
            return "Unknown".localized
        }
    }
}

// MARK: - Log Dose Sheet

/// Sheet for logging a new medicine dose. Includes a safety check before submission.
struct LogDoseSheet: View {
    @ObservedObject var viewModel: MedicineViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                // MARK: Child Picker
                if viewModel.children.count > 1 {
                    Section("Child") {
                        Picker("Child", selection: $viewModel.selectedChildId) {
                            ForEach(viewModel.children) { child in
                                Text(child.name).tag(child.id as String?)
                            }
                        }
                    }
                }

                // MARK: Medicine Type Picker
                Section("Medicine") {
                    Toggle("Other medicine", isOn: $viewModel.isOtherMedicine)

                    if viewModel.isOtherMedicine {
                        TextField("Medicine name", text: $viewModel.otherMedicineName)
                    } else {
                        Picker("Medicine Type", selection: $viewModel.selectedMedicineTypeId) {
                            Text("Select medicine...")
                                .tag(nil as String?)
                            ForEach(viewModel.filteredMedicineTypes) { type in
                                Text(type.name).tag(type.id as String?)
                            }
                        }
                        .accessibilityIdentifier(HausKlarAccessibilityID.Medicine.medicinePicker)
                    }
                }

                // MARK: Dose Details
                Section("Dose Details") {
                    TextField("Dose amount (e.g., 5ml, 1 tablet)", text: $viewModel.doseAmount)
                        .accessibilityIdentifier(HausKlarAccessibilityID.Medicine.amount)

                    DatePicker(
                        "Time given",
                        selection: $viewModel.givenAt,
                        in: ...Date(),
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    .accessibilityIdentifier(HausKlarAccessibilityID.Medicine.givenAt)

                    TextField("Notes (optional)", text: $viewModel.notes, axis: .vertical)
                        .lineLimit(2...4)
                }

                // MARK: Safety Check
                if viewModel.isCheckingSafety {
                    Section("Saved-Limit Check") {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Checking your saved timing and count limits…")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier(HausKlarAccessibilityID.Medicine.safetyCheck)
                } else if let checkError = viewModel.safetyCheckErrorMessage {
                    Section("Saved-Limit Check") {
                        Label(checkError, systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                    }
                    .accessibilityIdentifier(HausKlarAccessibilityID.Medicine.safetyCheck)
                } else if let check = viewModel.preSubmitSafetyCheck {
                    Section("Saved-Limit Check") {
                        if check.safe {
                            HStack(spacing: 8) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                Text("No timing or count warning from your saved limits")
                                    .font(.subheadline)
                            }
                        } else {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(check.warnings) { warning in
                                    HStack(alignment: .top, spacing: 8) {
                                        Image(systemName: "exclamationmark.triangle.fill")
                                            .foregroundStyle(.red)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(warning.message)
                                                .font(.subheadline)
                                                .foregroundStyle(.primary)
                                            if let nextSafe = warning.nextSafeAt {
                                                Text("Saved reminder interval ends: \(viewModel.formattedTime(nextSafe))")
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                            .accessibilityElement(children: .contain)

                            Text("You may still log this dose if you are sure.")
                                .font(.caption)
                                .foregroundStyle(.primary)
                        }
                    }
                    .accessibilityIdentifier(HausKlarAccessibilityID.Medicine.safetyCheck)
                }

                // MARK: Error
                if let error = viewModel.errorMessage {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                    }
                }

                // MARK: Submit
                Section {
                    Button {
                        Task {
                            await viewModel.logDose()
                        }
                    } label: {
                        HStack {
                            if viewModel.isLoading {
                                ProgressView()
                                    .padding(.trailing, 4)
                            }
                            Text("Record Dose")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .disabled(
                        viewModel.isLoading
                        || (!viewModel.isOtherMedicine && viewModel.selectedMedicineTypeId == nil)
                        || (viewModel.isOtherMedicine && viewModel.otherMedicineName.trimmingCharacters(in: .whitespaces).isEmpty)
                    )
                    .accessibilityLabel(
                        Text(viewModel.isLoading ? "Saving dose".localized : "Record Dose".localized)
                    )
                    .accessibilityIdentifier(HausKlarAccessibilityID.Medicine.submitDose)
                }

                // MARK: Disclaimer
                Section {
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.secondary)
                        Text("HausKlar compares your records with limits you enter. It does not recommend a dose or determine whether medicine is safe or appropriate.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .accessibilityIdentifier(HausKlarAccessibilityID.Medicine.logForm)
            .navigationTitle("Review Dose")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        viewModel.resetLogDoseForm()
                        dismiss()
                    }
                }
            }
            .onChange(of: viewModel.selectedMedicineTypeId) { _, newValue in
                // Pre-fill dose amount from default and run safety check
                guard !viewModel.isOtherMedicine,
                      let typeId = newValue,
                      let childId = viewModel.selectedChildId else {
                    viewModel.cancelSafetyCheck()
                    return
                }
                if let selectedType = viewModel.filteredMedicineTypes.first(where: { $0.id == typeId }),
                   let defaultDose = selectedType.defaultDoseAmount {
                    viewModel.doseAmount = defaultDose
                }
                viewModel.requestSafetyCheck(
                    typeId: typeId,
                    childId: childId,
                    givenAt: viewModel.givenAt
                )
            }
            .onChange(of: viewModel.selectedChildId) { _, _ in
                // Re-run safety check when child changes
                guard !viewModel.isOtherMedicine,
                      let typeId = viewModel.selectedMedicineTypeId,
                      let childId = viewModel.selectedChildId else {
                    viewModel.cancelSafetyCheck()
                    return
                }
                viewModel.requestSafetyCheck(
                    typeId: typeId,
                    childId: childId,
                    givenAt: viewModel.givenAt
                )
            }
            .onChange(of: viewModel.givenAt) { _, givenAt in
                guard !viewModel.isOtherMedicine,
                      let typeId = viewModel.selectedMedicineTypeId,
                      let childId = viewModel.selectedChildId else {
                    viewModel.cancelSafetyCheck()
                    return
                }
                viewModel.requestSafetyCheck(
                    typeId: typeId,
                    childId: childId,
                    givenAt: givenAt
                )
            }
            .onChange(of: viewModel.isOtherMedicine) { _, isOther in
                if isOther {
                    viewModel.selectedMedicineTypeId = nil
                    viewModel.cancelSafetyCheck()
                    viewModel.doseAmount = ""
                } else {
                    viewModel.otherMedicineName = ""
                }
            }
            .onChange(of: viewModel.showingLogDose) { _, isShowing in
                if !isShowing {
                    viewModel.resetLogDoseForm()
                }
            }
        }
    }
}

// MARK: - Add Medicine Type Sheet

/// Sheet for adding or editing a medicine and its saved reminder limits.
struct AddMedicineTypeSheet: View {
    @ObservedObject var viewModel: MedicineViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Medicine Details") {
                    TextField("Name (e.g., Calpol, Nurofen)", text: $viewModel.typeName)

                    TextField(
                        "Usual amount (e.g., 5ml, 1 tablet)",
                        text: $viewModel.typeDefaultDoseAmount
                    )

                    TextField("Notes (optional)", text: $viewModel.typeNotes, axis: .vertical)
                        .lineLimit(2...4)

                    Picker("Colour", selection: $viewModel.typeColor) {
                        Text("Blue").tag("#5B8DEF")
                        Text("Purple").tag("#8B5CF6")
                        Text("Green").tag("#2E9D68")
                        Text("Orange").tag("#D97706")
                        Text("Pink").tag("#DB5A8D")
                    }
                }

                Section {
                    HStack {
                        Text("Reminder interval (hours)")
                        Spacer()
                        Text(String(format: "%.1f", viewModel.typeMinHours))
                            .foregroundStyle(.secondary)
                    }
                    Stepper(
                        value: $viewModel.typeMinHours,
                        in: 1...24,
                        step: 0.5
                    ) {
                        EmptyView()
                    }

                    HStack {
                        Text("Reminder count in 24 hours")
                        Spacer()
                        Text("\(viewModel.typeMaxDoses)")
                            .foregroundStyle(.secondary)
                    }
                    Stepper(
                        value: $viewModel.typeMaxDoses,
                        in: 1...12
                    ) {
                        EmptyView()
                    }
                } header: {
                    Text("Your Label or Prescriber Limits")
                } footer: {
                    Text("Enter values from the medicine label or a prescriber. HausKlar only compares saved entries with these values; it does not calculate or recommend a dose.")
                }

                if viewModel.children.count > 1 {
                    Section("Child") {
                        Picker("Child", selection: $viewModel.typeChildId) {
                            Text("Choose a child")
                                .tag(nil as String?)
                            ForEach(viewModel.children) { child in
                                Text(child.name).tag(child.id as String?)
                            }
                        }
                    }
                }

                if let error = viewModel.errorMessage {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                    }
                }

                Section {
                    Button {
                        Task {
                            await viewModel.saveMedicineType()
                        }
                    } label: {
                        HStack {
                            if viewModel.isLoading {
                                ProgressView()
                                    .padding(.trailing, 4)
                            }
                            Text(
                                (viewModel.editingMedicineType == nil
                                    ? "Add Medicine"
                                    : "Save Changes").localized
                            )
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .disabled(
                        viewModel.typeName.trimmingCharacters(in: .whitespaces).isEmpty
                            || (viewModel.typeChildId ?? viewModel.selectedChildId) == nil
                            || viewModel.isLoading
                    )
                }
            }
            .navigationTitle(
                (viewModel.editingMedicineType == nil ? "Add Medicine" : "Edit Medicine").localized
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        viewModel.resetAddTypeForm()
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - Medicine History

struct MedicineTimelineSheet: View {
    @ObservedObject var viewModel: MedicineViewModel
    let medicine: MedicineTypeDTO
    @Environment(\.dismiss) private var dismiss
    @State private var correctionDose: MedicineDoseDTO?

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.doses(for: medicine).isEmpty {
                    ContentUnavailableView {
                        Label("No doses recorded", systemImage: "clock.arrow.circlepath")
                    } description: {
                        Text("\(medicine.name) history will appear here.")
                    } actions: {
                        Button("Review a Dose") {
                            dismiss()
                            viewModel.prepareDoseReview(for: medicine)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    List(viewModel.doses(for: medicine)) { dose in
                        Button {
                            correctionDose = dose
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(dateAndTime(dose.givenAt))
                                        .font(.subheadline)
                                        .fontWeight(.semibold)
                                    Spacer()
                                    Image(systemName: "pencil")
                                        .foregroundStyle(.secondary)
                                }
                                HStack(spacing: 10) {
                                    if let amount = dose.doseAmount, !amount.isEmpty {
                                        Text(amount)
                                    }
                                    if let givenBy = dose.givenBy, !givenBy.isEmpty {
                                        Text("by \(givenBy)")
                                    }
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)

                                if let notes = dose.notes, !notes.isEmpty {
                                    Text(notes)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                ForEach(dose.warnings) { warning in
                                    Label(warning.message, systemImage: "exclamationmark.triangle.fill")
                                        .font(.caption)
                                        .foregroundStyle(.primary)
                                }
                            }
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Opens this dose for correction")
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("\(medicine.name) History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $correctionDose) { dose in
                MedicineDoseCorrectionSheet(
                    viewModel: viewModel,
                    dose: dose,
                    onDeleted: { dismiss() }
                )
            }
        }
    }

    private func dateAndTime(_ value: String) -> String {
        guard let date = ISODateParser.parse(value) else { return value }
        return date.formatted(
            .dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()
        )
    }
}

struct MedicineDoseCorrectionSheet: View {
    @ObservedObject var viewModel: MedicineViewModel
    let dose: MedicineDoseDTO
    let onDeleted: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var givenAt: Date
    @State private var doseAmount: String
    @State private var medicineName: String
    @State private var notes: String
    @State private var confirmingRemoval = false

    init(
        viewModel: MedicineViewModel,
        dose: MedicineDoseDTO,
        onDeleted: @escaping () -> Void = {}
    ) {
        self.viewModel = viewModel
        self.dose = dose
        self.onDeleted = onDeleted
        _givenAt = State(initialValue: ISODateParser.parse(dose.givenAt) ?? Date())
        _doseAmount = State(initialValue: dose.doseAmount ?? "")
        _medicineName = State(initialValue: dose.medicineName ?? "")
        _notes = State(initialValue: dose.notes ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("What Was Given") {
                    if dose.medicineTypeId == nil {
                        TextField("Medicine name", text: $medicineName)
                    } else {
                        LabeledContent("Medicine", value: viewModel.doseDisplayName(dose))
                    }
                    TextField("Amount (optional)", text: $doseAmount)
                    DatePicker(
                        "Actual time",
                        selection: $givenAt,
                        in: ...Date(),
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    TextField("Notes (optional)", text: $notes, axis: .vertical)
                        .lineLimit(2...4)
                }

                if !dose.warnings.isEmpty {
                    Section("Warning Saved With This Record") {
                        ForEach(dose.warnings) { warning in
                            Label(warning.message, systemImage: "exclamationmark.triangle.fill")
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                        }
                    }
                }

                if let error = viewModel.errorMessage {
                    Section {
                        Label(error, systemImage: "exclamationmark.circle")
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                    }
                }

                Section {
                    Button {
                        Task {
                            if await viewModel.updateDose(
                                dose,
                                givenAt: givenAt,
                                doseAmount: doseAmount,
                                medicineName: medicineName,
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
                    .disabled(
                        viewModel.isLoading
                            || (dose.medicineTypeId == nil
                                && medicineName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    )
                }

                Section {
                    Button("Remove Mistaken Record", role: .destructive) {
                        confirmingRemoval = true
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                } footer: {
                    Text("Use this only when the record itself is wrong. You can undo immediately.")
                }
            }
            .navigationTitle("Correct Dose")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(viewModel.isLoading)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(viewModel.isLoading)
                }
            }
            .confirmationDialog(
                "Remove this dose record?",
                isPresented: $confirmingRemoval,
                titleVisibility: .visible
            ) {
                Button("Remove Record", role: .destructive) {
                    Task {
                        if await viewModel.deleteDose(dose) {
                            dismiss()
                            onDeleted()
                        }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This does not change what was actually given. It only corrects the family record.")
            }
        }
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        MedicineView()
    }
}
