import SwiftUI
import Charts

/// Displays growth tracking data (height, weight, head circumference) for children,
/// with separate charts for height and weight over time.
struct GrowthView: View {
    @StateObject private var viewModel = GrowthViewModel()
    let initialChildId: String?

    init(initialChildId: String? = nil) { self.initialChildId = initialChildId }

    private struct GrowthPoint: Identifiable {
        let id = UUID()
        let date: Date
        let value: Double
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Child selector
                childSelectorSection

                if !viewModel.children.isEmpty {
                    Button {
                        viewModel.showingAddRecord = true
                    } label: {
                        Label("Add measurement", systemImage: "plus")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.isLoading)
                    .padding(.horizontal)
                    .accessibilityIdentifier("growthAddMeasurement")
                }

                if viewModel.isLoading && viewModel.records.isEmpty {
                    loadingSection
                } else {
                    // Error banner (non-blocking)
                    if let errorMessage = viewModel.errorMessage {
                        errorBanner(errorMessage)
                    }

                    // Latest values
                    if let latest = viewModel.latestRecord {
                        latestValuesSection(latest)
                    }

                    // Growth charts
                    if !viewModel.records.isEmpty {
                        growthChartsSection
                    }

                    // Measurements list
                    measurementsListSection
                }
            }
            .padding(.vertical)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Growth")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    viewModel.showingAddRecord = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add measurement")
                .disabled(viewModel.children.isEmpty || viewModel.isLoading)
            }
        }
        .sheet(isPresented: $viewModel.showingAddRecord) {
            addRecordSheet
        }
        .sheet(item: $viewModel.selectedRecordForEdit) { record in
            editRecordSheet(record)
        }
        .alert("Delete Measurement?", isPresented: Binding(
            get: { viewModel.recordPendingDelete != nil },
            set: { if !$0 { viewModel.recordPendingDelete = nil } }
        )) {
            Button("Delete", role: .destructive) {
                if let record = viewModel.recordPendingDelete {
                    Task { await viewModel.deleteRecord(record) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This measurement will be removed.")
        }
        .refreshable {
            await viewModel.loadRecords()
        }
        .task {
            if let initialChildId { viewModel.selectedChildId = initialChildId }
            await viewModel.loadChildren()
            await viewModel.loadRecords()
        }
        .onChange(of: viewModel.selectedChildId) { _, _ in
            Task {
                await viewModel.loadRecords()
            }
        }
    }

    // MARK: - Child Selector

    private var childSelectorSection: some View {
        Group {
            if viewModel.children.count > 1 {
                ChildSelectorChips(
                    children: viewModel.children,
                    selectedChildId: $viewModel.selectedChildId,
                    nameKeyPath: \.name
                )
                .padding(.horizontal)
            } else if let child = viewModel.children.first {
                Text(child.name)
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
            }
        }
    }

    // MARK: - Latest Values

    private func latestValuesSection(_ record: GrowthRecordDTO) -> some View {
        VStack(spacing: 4) {
            Text("Latest Measurements")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 16) {
                if let height = record.heightCm {
                    latestValueCard(
                        title: "Height",
                        value: String(format: "%.1f", height),
                        unit: "cm",
                        color: .blue
                    )
                }
                if let weight = record.weightKg {
                    latestValueCard(
                        title: "Weight",
                        value: String(format: "%.1f", weight),
                        unit: "kg",
                        color: .green
                    )
                }
                if let headCirc = record.headCircumferenceCm {
                    latestValueCard(
                        title: "Head",
                        value: String(format: "%.1f", headCirc),
                        unit: "cm",
                        color: .orange
                    )
                }
            }

            Text("Measured on \(formatDateDisplay(record.date))")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
    }

    private func latestValueCard(title: String, value: String, unit: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundStyle(color)
                Text(unit)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(color.opacity(0.1))
        .cornerRadius(12)
    }

    // MARK: - Growth Charts

    private var growthChartsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            let heightData = viewModel.records.compactMap { record -> GrowthPoint? in
                guard let value = record.heightCm else { return nil }
                return GrowthPoint(date: parseDate(record.date), value: value)
            }
            let weightData = viewModel.records.compactMap { record -> GrowthPoint? in
                guard let value = record.weightKg else { return nil }
                return GrowthPoint(date: parseDate(record.date), value: value)
            }

            if !heightData.isEmpty {
                Text("Height Over Time")
                    .font(.headline)
                    .padding(.horizontal)

                Chart(heightData) { point in
                    LineMark(
                        x: .value("Date", point.date),
                        y: .value("Height (cm)", point.value)
                    )
                    .foregroundStyle(.blue)
                    .interpolationMethod(.catmullRom)

                    PointMark(
                        x: .value("Date", point.date),
                        y: .value("Height (cm)", point.value)
                    )
                    .foregroundStyle(.blue)
                    .symbolSize(30)
                }
                .chartYAxisLabel("cm")
                .frame(height: 220)
                .padding(.horizontal)
            }

            if !weightData.isEmpty {
                Text("Weight Over Time")
                    .font(.headline)
                    .padding(.horizontal)

                Chart(weightData) { point in
                    LineMark(
                        x: .value("Date", point.date),
                        y: .value("Weight (kg)", point.value)
                    )
                    .foregroundStyle(.green)
                    .interpolationMethod(.catmullRom)

                    PointMark(
                        x: .value("Date", point.date),
                        y: .value("Weight (kg)", point.value)
                    )
                    .foregroundStyle(.green)
                    .symbolSize(30)
                }
                .chartYAxisLabel("kg")
                .frame(height: 220)
                .padding(.horizontal)
            }
        }
        .padding(.vertical, 8)
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .padding(.horizontal)
    }

    // MARK: - Measurements List

    private var measurementsListSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("All Measurements")
                .font(.headline)
                .padding(.horizontal)

            if viewModel.records.isEmpty {
                ContentUnavailableView {
                    Label("No growth records", systemImage: "chart.line.uptrend.xyaxis")
                } description: {
                    Text("Add your child's first measurement to start tracking.")
                } actions: {
                    Button("Add measurement") { viewModel.showingAddRecord = true }
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(viewModel.records.reversed()) { record in
                        measurementRow(record)
                        Divider()
                            .padding(.leading)
                    }
                }
                .background(Color(.systemBackground))
                .cornerRadius(12)
                .padding(.horizontal)
            }
        }
    }

    private func measurementRow(_ record: GrowthRecordDTO) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(formatDateDisplay(record.date))
                .font(.subheadline)
                .fontWeight(.medium)

            HStack(spacing: 16) {
                if let height = record.heightCm {
                    Label(String(format: "%.1f cm", height), systemImage: "ruler")
                        .font(.caption)
                        .foregroundStyle(.blue)
                }
                if let weight = record.weightKg {
                    Label(String(format: "%.1f kg", weight), systemImage: "scalemass")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
                if let headCirc = record.headCircumferenceCm {
                    Label(String(format: "%.1f cm", headCirc), systemImage: "circle.dashed")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            if let notes = record.notes, !notes.isEmpty {
                Text(notes)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .contextMenu {
            Button("Edit") {
                viewModel.startEditing(record)
            }
            Button("Delete", role: .destructive) {
                viewModel.recordPendingDelete = record
            }
        }
    }

    // MARK: - Add Record Sheet

    private var addRecordSheet: some View {
        NavigationStack {
            Form {
                Section("Date") {
                    DatePicker("Measurement Date", selection: $viewModel.formDate, displayedComponents: .date)
                        .datePickerStyle(.graphical)
                }

                Section("Measurements") {
                    Text("You can enter height or weight independently.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack {
                        Text("Height (cm)")
                        Spacer()
                        TextField("e.g. 85.5", text: $viewModel.formHeightCm)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 100)
                    }

                    HStack {
                        Text("Weight (kg)")
                        Spacer()
                        TextField("e.g. 12.3", text: $viewModel.formWeightKg)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 100)
                    }

                    HStack {
                        Text("Head Circ. (cm)")
                        Spacer()
                        TextField("Optional", text: $viewModel.formHeadCircumference)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 100)
                    }
                }

                Section("Notes") {
                    TextField("Any notes...", text: $viewModel.formNotes, axis: .vertical)
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
            .navigationTitle("Add Measurement")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        viewModel.showingAddRecord = false
                        viewModel.resetForm()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            await viewModel.addRecord()
                        }
                    }
                    .disabled(viewModel.isLoading)
                }
            }
        }
    }

    private func editRecordSheet(_ record: GrowthRecordDTO) -> some View {
        NavigationStack {
            Form {
                Section("Date") {
                    DatePicker("Measurement Date", selection: $viewModel.editDate, displayedComponents: .date)
                        .datePickerStyle(.graphical)
                }
                Section("Measurements") {
                    Text("You can enter height or weight independently.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Text("Height (cm)")
                        Spacer()
                        TextField("e.g. 85.5", text: $viewModel.editHeightCm)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 100)
                    }
                    HStack {
                        Text("Weight (kg)")
                        Spacer()
                        TextField("e.g. 12.3", text: $viewModel.editWeightKg)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 100)
                    }
                    HStack {
                        Text("Head Circ. (cm)")
                        Spacer()
                        TextField("Optional", text: $viewModel.editHeadCircumference)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 100)
                    }
                }
                Section("Notes") {
                    TextField("Any notes...", text: $viewModel.editNotes, axis: .vertical)
                        .lineLimit(3...6)
                }
            }
            .navigationTitle("Edit Measurement")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        viewModel.selectedRecordForEdit = nil
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            await viewModel.saveEditedRecord()
                        }
                    }
                    .disabled(viewModel.isLoading)
                }
            }
        }
    }

    // MARK: - Loading

    private var loadingSection: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text("Loading growth data...")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
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

    // MARK: - Helpers

    // MARK: - Cached Formatters

    private static let dateInputFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f
    }()

    private static let dateDisplayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeZone = .current
        return f
    }()

    /// Parses a date-only string (yyyy-MM-dd) into a Date for chart display.
    private func parseDate(_ dateString: String) -> Date {
        Self.dateInputFormatter.date(from: dateString) ?? Date()
    }

    /// Formats a date-only string into a human-readable display string.
    private func formatDateDisplay(_ dateString: String) -> String {
        guard let date = Self.dateInputFormatter.date(from: dateString) else { return dateString }
        return Self.dateDisplayFormatter.string(from: date)
    }
}

#Preview {
    NavigationStack {
        GrowthView()
    }
}
