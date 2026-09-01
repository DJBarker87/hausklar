import Charts
import SwiftUI

struct FitnessAnalysisWorkspaceView: View {
    @EnvironmentObject private var networkMonitor: NetworkMonitor
    @StateObject private var viewModel: FitnessAnalysisViewModel
    @StateObject private var consent = AIConsentViewModel()
    @StateObject private var coach = FitnessCoachViewModel(ephemeralMessages: true)
    @State private var category = "all"
    @State private var askingHermes = false
    private let title: String

    init(title: String, surface: String) {
        self.title = title
        _viewModel = StateObject(
            wrappedValue: FitnessAnalysisViewModel(preferredSurface: surface)
        )
    }

    private var categories: [String] {
        ["all"] + Array(Set(viewModel.presets.compactMap(\.category))).sorted()
    }

    private var visiblePresets: [FitnessAnalysisRegistry.DefaultQuery] {
        category == "all" ? viewModel.presets : viewModel.presets.filter { $0.category == category }
    }

    var body: some View {
        List {
            if let error = viewModel.errorMessage {
                Section {
                    Label(error,systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    if viewModel.registry == nil {
                        Button("Try again",systemImage: "arrow.clockwise") {
                            Task { await viewModel.load() }
                        }
                        .disabled(viewModel.isLoading)
                    } else {
                        Button("Run again",systemImage: "arrow.clockwise") {
                            viewModel.startQuery()
                        }
                        .disabled(viewModel.queryProblem != nil || viewModel.isQuerying)
                    }
                }
            }
            if let registry = viewModel.registry {
                catalogueSection
                configurationSection(registry)
                savedSection(registry)
            } else if viewModel.isLoading {
                Section { HStack { Spacer(); ProgressView(); Spacer() } }
            }
            if viewModel.isQuerying {
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                        VStack(alignment: .leading) {
                            Text("Running analysis").font(.headline)
                            Text("Some questions take longer to calculate.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Cancel") { viewModel.cancelQuery() }
                    }
                }
            }
            if let result = viewModel.result {
                Section(result.title) { FitnessAnalysisResultView(result: result) }
            }
            hermesSection
        }
        .navigationTitle(title)
        .task { await viewModel.load() }
        .refreshable { await viewModel.load() }
        .onDisappear { viewModel.cancelQuery() }
        .onChange(of: askingHermes) { _,expanded in
            guard expanded else { return }
            Task {
                await consent.load()
                if consent.hasConsent {
                    coach.intent = .discussion
                    await coach.activateAfterConsent(isOnline: networkMonitor.isConnected)
                }
            }
        }
    }

    private var hermesSection: some View {
        Section {
            DisclosureGroup(isExpanded: $askingHermes) {
                if consent.isLoading {
                    ProgressView("Checking your AI privacy choice…")
                } else if !consent.hasConsent {
                    Text(consent.status?.disclosure ?? consent.errorMessage ?? "AI privacy settings could not be loaded.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button {
                        Task {
                            await consent.grant()
                            if consent.hasConsent {
                                coach.intent = .discussion
                                await coach.activateAfterConsent(isOnline: networkMonitor.isConnected)
                            }
                        }
                    } label: {
                        if consent.isSaving { ProgressView() }
                        else { Label("Allow and continue",systemImage: "hand.raised.fill") }
                    }
                    .disabled(consent.isSaving || !networkMonitor.isConnected || consent.status == nil)
                } else {
                    if coach.inputText.isEmpty {
                        Button("Ask about the current analysis") {
                            let measure=viewModel.selectedMeasure?.label ?? "my selected Fitness measure"
                            let group=viewModel.availableDimensions.first(where: { $0.key == viewModel.dimensionKey })?.label ?? viewModel.dimensionKey
                            coach.inputText="Help me interpret \(measure) grouped by \(group) for the selected date range. Explain what the evidence supports and what it does not."
                        }
                    }
                    ForEach(coach.messages.suffix(4)) { message in
                        VStack(alignment: .leading,spacing: 5) {
                            Text(message.role == .assistant ? "Hermes" : "You")
                                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            Text(message.content)
                            if !message.evidence.isEmpty {
                                DisclosureGroup("Evidence (\(message.evidence.count))") {
                                    ForEach(message.evidence) { evidence in
                                        VStack(alignment: .leading,spacing: 2) {
                                            Text(evidence.label).font(.caption.weight(.semibold))
                                            Text(evidence.summary).font(.caption).foregroundStyle(.secondary)
                                            if let sample=evidence.sampleSize { Text("Sample: \(sample)").font(.caption2).foregroundStyle(.tertiary) }
                                        }.padding(.vertical,2)
                                    }
                                }
                            }
                        }
                        .padding(.vertical,4)
                    }
                    if let unavailable=coach.runtimeUnavailableMessage {
                        Label(unavailable,systemImage: "bolt.slash")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if let error=coach.errorMessage {
                        Label(error,systemImage: "exclamationmark.triangle")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                    TextEditor(text: $coach.inputText)
                        .frame(minHeight: 80)
                        .overlay(alignment: .topLeading) {
                            if coach.inputText.isEmpty {
                                Text("Ask an editable question about your recorded Fitness data…")
                                    .foregroundStyle(.tertiary).padding(.horizontal,5).padding(.vertical,8)
                                    .allowsHitTesting(false)
                            }
                        }
                    HStack {
                        Text("\(coach.inputText.count)/2,000")
                            .font(.caption2).foregroundStyle(coach.inputText.count > 2_000 ? .red : .secondary)
                        Spacer()
                        Button {
                            coach.intent = .discussion
                            Task { await coach.send(isOnline: networkMonitor.isConnected) }
                        } label: {
                            if coach.isSending { ProgressView() }
                            else { Label("Send",systemImage: "paperplane.fill") }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!coach.canSend || !networkMonitor.isConnected || coach.inputText.count > 2_000)
                        .accessibilityLabel(coach.isSending ? "Sending question" : "Send question")
                    }
                    if !networkMonitor.isConnected {
                        Label("Reconnect to ask Hermes. Your draft stays here.",systemImage: "wifi.slash")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Nothing is sent until you tap Send. This is a one-off chat and is not saved, even when Coach memory is on; discussion cannot change Fitness data.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } label: {
                Label("Ask Hermes about this",systemImage: "sparkles")
            }
        }
    }

    private var catalogueSection: some View {
        Section {
            if categories.count > 2 {
                Picker("Category",selection: $category) {
                    ForEach(categories,id: \.self) { value in
                        Text(categoryLabel(value)).tag(value)
                    }
                }
                .pickerStyle(.menu)
            }
            if visiblePresets.isEmpty {
                Text("No questions are available in this category.")
                    .foregroundStyle(.secondary)
            }
            ForEach(visiblePresets) { preset in
                Button {
                    viewModel.apply(preset)
                } label: {
                    VStack(alignment: .leading,spacing: 3) {
                        Text(preset.label).foregroundStyle(.primary)
                        if let description = preset.description {
                            Text(description).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } header: {
            Text("Questions")
        } footer: {
            Text("Each question can use only a fixed set of private Fitness data. Detailed second-by-second activity data stays in HausKlar.")
        }
    }

    private func configurationSection(_ registry: FitnessAnalysisRegistry) -> some View {
        Section {
            Picker("Measure",selection: $viewModel.measureKey) {
                ForEach(registry.measures) { Text($0.label).tag($0.key) }
            }
            .onChange(of: viewModel.measureKey) { _,value in viewModel.selectMeasure(value) }
            Picker("Group by",selection: $viewModel.dimensionKey) {
                ForEach(viewModel.availableDimensions) { Text($0.label).tag($0.key) }
            }
            Picker("Chart",selection: $viewModel.chartTypeKey) {
                ForEach(viewModel.availableCharts) { Text($0.label).tag($0.key) }
            }
            DatePicker("From",selection: $viewModel.startDate,displayedComponents: .date)
            DatePicker("To",selection: $viewModel.endDate,displayedComponents: .date)
            if !viewModel.availableComparisons.isEmpty {
                Picker("Comparison",selection: $viewModel.comparisonKey) {
                    Text("None").tag("")
                    ForEach(viewModel.availableComparisons) { Text($0.label).tag($0.key) }
                }
            }
            Stepper(
                "Maximum points: \(viewModel.maxPoints)",
                value: $viewModel.maxPoints,
                in: 1...max(1,registry.limits.maxOutputPoints),step: 10
            )
            ForEach($viewModel.filters) { $filter in
                if let definition = registry.filters.first(where: { $0.key == filter.key }) {
                    FitnessRegisteredAnalysisFilterRow(
                        filter: $filter,definition: definition,
                        remove: { viewModel.removeFilter(filter.key) }
                    )
                }
            }
            let unusedFilters = viewModel.availableFilterDefinitions.filter { definition in
                !viewModel.filters.contains { $0.key == definition.key }
            }
            if !unusedFilters.isEmpty,viewModel.filters.count < registry.limits.maxFilters {
                Menu {
                    ForEach(unusedFilters) { definition in
                        Button(definition.label) { viewModel.addFilter(definition) }
                    }
                } label: {
                    Label("Add filter",systemImage: "line.3.horizontal.decrease.circle")
                }
            }
            if let description = viewModel.selectedMeasure?.description {
                Text(description).font(.caption).foregroundStyle(.secondary)
            }
            Button {
                viewModel.startQuery()
            } label: {
                Label("Run analysis",systemImage: "play.fill")
            }
            .disabled(viewModel.queryProblem != nil || viewModel.isQuerying)
            if let problem = viewModel.queryProblem {
                Text(problem).font(.caption).foregroundStyle(.orange)
            }
        } header: {
            Text("Configure analysis")
        }
    }

    private func savedSection(_ registry: FitnessAnalysisRegistry) -> some View {
        Section {
            if let error = viewModel.savedChartError {
                Label(error,systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            if viewModel.savedCharts.isEmpty {
                Text("Save a useful chart setup for quick reuse.")
                    .foregroundStyle(.secondary)
            }
            ForEach(viewModel.savedCharts) { chart in
                HStack {
                    Button {
                        viewModel.apply(chart)
                    } label: {
                        VStack(alignment: .leading,spacing: 2) {
                            Text(chart.name).foregroundStyle(.primary)
                            Text("\(chart.measureKey) by \(chart.dimensionKey) · \(chart.dateWindowDays) days")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button(role: .destructive) {
                        Task { await viewModel.deleteSavedChart(chart) }
                    } label: {
                        Image(systemName: "trash")
                            .frame(minWidth: 44,minHeight: 44)
                    }
                    .accessibilityLabel("Remove \(chart.name)")
                }
            }
            TextField("Saved chart name",text: $viewModel.saveName)
            Button {
                Task { await viewModel.saveCurrentChart() }
            } label: {
                Label("Save chart",systemImage: "bookmark")
            }
            .disabled(viewModel.queryProblem != nil)
        } header: {
            Text("Saved charts")
        } footer: {
            Text("Saved charts keep only the chosen measure, grouping, filters and date window—not the recorded results.")
        }
    }

    private func categoryLabel(_ value: String) -> String {
        value == "all" ? "All" : value.replacingOccurrences(of: "_",with: " ").capitalized
    }
}

private struct FitnessRegisteredAnalysisFilterRow: View {
    @Binding var filter: FitnessAnalysisFilter
    let definition: FitnessAnalysisRegistry.FilterDefinition
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading,spacing: 8) {
            HStack {
                Text(definition.label).font(.subheadline.weight(.semibold))
                Spacer()
                Button(role: .destructive,action: remove) { Image(systemName: "xmark.circle.fill") }
                    .frame(minWidth: 44,minHeight: 44)
                    .accessibilityLabel("Remove \(definition.label) filter")
            }
            Picker("Rule",selection: $filter.operator) {
                ForEach(definition.operators,id: \.rawValue) { value in Text(value.label).tag(value) }
            }
            .onChange(of: filter.operator) { _,value in normalizeValue(for: value) }
            FitnessAnalysisFilterValueEditor(filter: $filter,definition: definition)
        }
        .padding(.vertical,4)
    }

    private func normalizeValue(for operation: FitnessAnalysisFilterOperator) {
        switch operation {
        case .between:
            if case .array = filter.value { return }
            filter.value = .array([filter.value,filter.value])
        case .containsAny:
            if case .array = filter.value { return }
            filter.value = .array([filter.value])
        default:
            if case .array(let values) = filter.value,let first = values.first { filter.value = first }
        }
    }
}

private struct FitnessAnalysisFilterValueEditor: View {
    @Binding var filter: FitnessAnalysisFilter
    let definition: FitnessAnalysisRegistry.FilterDefinition

    var body: some View {
        if let options = definition.values,!options.isEmpty {
            if filter.operator == .containsAny || filter.operator == .between {
                Menu {
                    ForEach(options) { option in
                        Button {
                            toggle(option.key)
                        } label: {
                            if selectedKeys.contains(option.key) {
                                Label(option.label,systemImage: "checkmark")
                            } else {
                                Text(option.label)
                            }
                        }
                    }
                } label: {
                    LabeledContent("Value",value: selectedLabels(options))
                }
            } else {
                Picker("Value",selection: scalarStringBinding) {
                    ForEach(options) { Text($0.label).tag($0.key) }
                }
            }
        } else if definition.valueType == "boolean" {
            Toggle("Value",isOn: booleanBinding)
        } else {
            TextField(
                filter.operator == .between ? "Two values separated by a comma" : "Value",
                text: textBinding
            )
            .keyboardType(definition.valueType == "number" ? .decimalPad : .default)
            .textInputAutocapitalization(.never)
        }
    }

    private var selectedKeys: [String] {
        switch filter.value {
        case .array(let values): values.compactMap(analysisString)
        default: analysisString(filter.value).map { [$0] } ?? []
        }
    }

    private var scalarStringBinding: Binding<String> {
        Binding(
            get: { analysisString(filter.value) ?? definition.values?.first?.key ?? "" },
            set: { filter.value = .string($0) }
        )
    }

    private var booleanBinding: Binding<Bool> {
        Binding(
            get: { if case .bool(let value) = filter.value { return value }; return false },
            set: { filter.value = .bool($0) }
        )
    }

    private var textBinding: Binding<String> {
        Binding(
            get: {
                switch filter.value {
                case .array(let values): values.compactMap(analysisString).joined(separator: ", ")
                default: analysisString(filter.value) ?? ""
                }
            },
            set: { newValue in
                let parts = newValue.split(separator: ",",omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                let values = parts.map(makeValue)
                if filter.operator == .between || filter.operator == .containsAny {
                    filter.value = .array(values)
                } else {
                    filter.value = values.first ?? makeValue("")
                }
            }
        )
    }

    private func toggle(_ key: String) {
        var keys = selectedKeys
        if let index = keys.firstIndex(of: key) { keys.remove(at: index) } else { keys.append(key) }
        let limit = filter.operator == .between ? 2 : (definition.maxValues ?? Int.max)
        filter.value = .array(Array(keys.prefix(limit)).map(JSONValue.string))
    }

    private func selectedLabels(_ options: [FitnessAnalysisRegistry.FilterDefinition.Option]) -> String {
        let labels = selectedKeys.compactMap { key in options.first(where: { $0.key == key })?.label }
        return labels.isEmpty ? "Choose" : labels.joined(separator: ", ")
    }

    private func makeValue(_ value: String) -> JSONValue {
        if definition.valueType == "number",let number = Double(value) { return .double(number) }
        return .string(value)
    }

    private func analysisString(_ value: JSONValue) -> String? {
        switch value {
        case .string(let value): value
        case .int(let value): String(value)
        case .double(let value): String(value)
        case .bool(let value): value ? "true" : "false"
        default: nil
        }
    }
}

struct FitnessAnalysisResultView: View {
    let result: FitnessAnalysisQueryResult
    var showsTechnicalDetails=true

    var body: some View {
        VStack(alignment: .leading,spacing: 14) {
            if let description = result.description { Text(description).foregroundStyle(.secondary) }
            if let summary = result.summary { Text(summary).font(.headline) }
            if result.status == .empty {
                ContentUnavailableView("No recorded data",systemImage: "chart.xyaxis.line")
            } else if result.status == .insufficientSample {
                ContentUnavailableView(
                    "Not enough comparable records",systemImage: "chart.dots.scatter",
                    description: Text("Add a few more activities to build this comparison.")
                )
            } else if !result.series.flatMap(\.points).isEmpty {
                FitnessRegisteredChart(result: result)
            }
            if let difference = result.difference {
                LabeledContent(difference.label,value: formatted(difference.value,unit: difference.unitKey))
            }
            if showsTechnicalDetails {
                HStack(spacing: 10) {
                    Label(result.metadata.classification.label,systemImage: "info.circle")
                    Text("\(result.metadata.sampleSize) samples")
                    Text("\(result.metadata.missingRate.formatted(.percent.precision(.fractionLength(0)))) missing")
                }
                .font(.caption).foregroundStyle(.secondary)
                Text(result.metadata.classification.explanation)
                    .font(.caption).foregroundStyle(
                        result.metadata.classification == .correlational ? Color.orange : Color.secondary
                    )
                DisclosureGroup("Data and quality details") {
                    VStack(alignment: .leading,spacing: 7) {
                        LabeledContent("Period",value: result.metadata.period.label ?? "\(result.metadata.period.start) – \(result.metadata.period.end)")
                        LabeledContent("Readings included",value: plainPolicy(result.metadata.canonicalPolicy))
                        LabeledContent("Duplicates",value: plainPolicy(result.metadata.duplicatePolicy))
                        if !result.metadata.sourceQuality.isEmpty {
                            LabeledContent("Source quality",value: result.metadata.sourceQuality.map(plainPolicy).joined(separator: ", "))
                        }
                        if !result.metadata.measurementQuality.isEmpty {
                            LabeledContent("Measurement quality",value: result.metadata.measurementQuality.map(plainPolicy).joined(separator: ", "))
                        }
                        if let missing = result.metadata.missingCount { LabeledContent("Missing records",value: "\(missing)") }
                    }
                    .font(.caption)
                }
                ForEach(result.limitations,id: \.self) { limitation in
                    Label(limitation,systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func formatted(_ value: Double,unit: String?) -> String {
        [value.formatted(.number.precision(.fractionLength(0...2))),unit].compactMap { $0 }.joined(separator: " ")
    }

    private func plainPolicy(_ value: String) -> String {
        var result=value.replacingOccurrences(of:"_",with:" ")
            .replacingOccurrences(of:"canonical",with:"main",options:.caseInsensitive)
            .replacingOccurrences(of:"owner-scoped",with:"private",options:.caseInsensitive)
        if let first=result.first {
            result=first.uppercased()+String(result.dropFirst())
        }
        return result
    }
}

private struct FitnessRegisteredChart: View {
    let result: FitnessAnalysisQueryResult

    private var points: [PlottedPoint] {
        result.series.flatMap { series in
            series.points.enumerated().map { index,point in
                PlottedPoint(series: series,index: index,point: point)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading,spacing: 10) {
            chart.frame(height: 270)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilitySummary)
            DisclosureGroup("Data table") {
                ForEach(points) { item in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(item.point.label)
                            if result.series.count > 1 {
                                Text(item.series.label).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Text(item.point.value.map { value($0,unit: item.series.unitKey ?? result.unitKey) } ?? "—")
                    }
                    .font(.caption)
                }
            }
        }
    }

    @ViewBuilder private var chart: some View {
        switch result.chartTypeKey {
        case .line:
            lineChart(plottablePoints,false)
        case .rollingAverage:
            lineChart(plottablePoints,true)
        case .bar:
            Chart(plottablePoints) { item in
                if let value = item.point.value {
                    BarMark(x: .value("Group",item.point.axisLabel),y: .value("Value",value))
                        .foregroundStyle(by: .value("Series",item.series.label))
                }
            }
        case .stackedBar:
            Chart(plottablePoints) { item in
                if let value = item.point.value {
                    BarMark(x: .value("Group",item.point.axisLabel),y: .value("Value",value),stacking: .standard)
                        .foregroundStyle(by: .value("Series",item.series.label))
                }
            }
        case .scatter:
            Chart(scatterPoints) { item in
                if let x = item.point.numericX,let value = item.point.value {
                    PointMark(x: .value("X",x),y: .value("Value",value))
                        .foregroundStyle(by: .value("Series",item.series.label))
                        .symbol(by: .value("Series",item.series.label))
                }
            }
        case .histogram:
            Chart(plottablePoints) { item in
                if let value = item.point.value {
                    BarMark(x: .value("Bin",item.point.axisLabel),y: .value("Count",value))
                        .foregroundStyle(by: .value("Series",item.series.label))
                }
            }
        case .calendarHeatmap:
            Chart(calendarPoints) { item in
                RectangleMark(
                    x: .value("Week",item.week),y: .value("Weekday",item.weekday),
                    width: .ratio(0.92),height: .ratio(0.92)
                )
                .foregroundStyle(by: .value("Value",item.value))
            }
            .chartYAxis { AxisMarks(values: Array(1...7)) }
        case .rangeBand:
            Chart(points) { item in
                if let low = item.point.low,let high = item.point.high {
                    AreaMark(
                        x: .value("Group",item.point.axisLabel),
                        yStart: .value("Low",low),yEnd: .value("High",high)
                    )
                    .foregroundStyle(by: .value("Series",item.series.label))
                    .opacity(0.22)
                }
                if let value = item.point.value {
                    LineMark(x: .value("Group",item.point.axisLabel),y: .value("Value",value))
                        .foregroundStyle(by: .value("Series",item.series.label))
                }
            }
        case .table:
            VStack(alignment: .leading,spacing: 8) {
                ForEach(points) { item in
                    LabeledContent(item.point.label,value: item.point.value.map { value($0,unit: item.series.unitKey ?? result.unitKey) } ?? "—")
                }
            }
        }
    }

    private func lineChart(_ values: [PlottedPoint],_ rolling: Bool) -> some View {
        Chart(values) { item in
            if let value = item.point.value {
                LineMark(x: .value("Group",item.point.axisLabel),y: .value("Value",value))
                    .interpolationMethod(rolling ? .catmullRom : .linear)
                    .foregroundStyle(by: .value("Series",item.series.label))
                PointMark(x: .value("Group",item.point.axisLabel),y: .value("Value",value))
                    .foregroundStyle(by: .value("Series",item.series.label))
            }
        }
    }

    private var plottablePoints: [PlottedPoint] { points.filter { $0.point.isPlottable } }
    private var scatterPoints: [PlottedPoint] { points.filter { $0.point.isScatterPlottable } }

    private var calendarPoints: [CalendarPoint] {
        let calendar = Calendar(identifier: .iso8601)
        let dates = plottablePoints.compactMap { item -> (PlottedPoint,Date)? in
            guard let date = Self.dayFormatter.date(from: item.point.axisLabel) else { return nil }
            return (item,date)
        }
        guard let first = dates.map(\.1).min() else {
            return plottablePoints.compactMap { item in
                item.point.value.map { CalendarPoint(id: item.id,week: item.index,weekday: 1,value: $0) }
            }
        }
        return dates.compactMap { item,date in
            guard let value = item.point.value else { return nil }
            let week = calendar.dateComponents([.weekOfYear],from: first,to: date).weekOfYear ?? 0
            let weekday = calendar.component(.weekday,from: date)
            return CalendarPoint(id: item.id,week: week,weekday: weekday,value: value)
        }
    }

    private var accessibilitySummary: String {
        let values = points.compactMap(\.point.value)
        guard let minimum = values.min(),let maximum = values.max() else {
            return "\(result.title). No numeric values."
        }
        return "\(result.title), \(result.chartTypeKey.fallbackLabel) chart with \(values.count) values, from \(minimum.formatted()) to \(maximum.formatted())."
    }

    private func value(_ value: Double,unit: String?) -> String {
        [value.formatted(.number.precision(.fractionLength(0...2))),unit].compactMap { $0 }.joined(separator: " ")
    }

    private struct PlottedPoint: Identifiable {
        let series: FitnessAnalysisSeries
        let index: Int
        let point: FitnessAnalysisPoint
        var id: String { "\(series.key)|\(point.key)|\(index)" }
    }

    private struct CalendarPoint: Identifiable {
        let id: String
        let week: Int
        let weekday: Int
        let value: Double
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
