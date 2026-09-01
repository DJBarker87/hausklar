import SwiftUI

private enum FitnessNutritionSection: String, CaseIterable, Identifiable {
    case diary, foods, recipes, templates, targets
    var id: String { rawValue }
    var title: String {
        switch self {
        case .diary: "Diary"
        case .foods: "Foods"
        case .recipes: "Recipes"
        case .templates: "Meal templates"
        case .targets: "Targets & day"
        }
    }
    var icon: String {
        switch self {
        case .diary: "apple.logo"
        case .foods: "books.vertical"
        case .recipes: "frying.pan"
        case .templates: "fork.knife"
        case .targets: "slider.horizontal.3"
        }
    }
}

enum FitnessNutritionSheet: Identifiable {
    case newFood
    case log(source: String? = nil)
    case recommendedPortion(itemId: String, meal: FitnessMeal, amount: Double, unit: String)
    case addToMeal(FitnessMeal)
    case editLog(String)
    case newRecipe
    case newTemplate(FitnessMeal?)
    case editTemplate(String)
    case logTemplate(String)
    case newTarget

    var id: String {
        switch self {
        case .newFood: "new-food"
        case .log(let source): "log-\(source ?? "new")"
        case .recommendedPortion(let itemId, let meal, let amount, let unit):
            "recommended-\(itemId)-\(meal.rawValue)-\(amount)-\(unit)"
        case .addToMeal(let meal): "add-to-\(meal.rawValue)"
        case .editLog(let id): "edit-log-\(id)"
        case .newRecipe: "new-recipe"
        case .newTemplate(let meal): "new-template-\(meal?.rawValue ?? "blank")"
        case .editTemplate(let id): "edit-template-\(id)"
        case .logTemplate(let id): "log-template-\(id)"
        case .newTarget: "new-target"
        }
    }
}

struct FitnessNutritionWorkspaceView: View {
    @StateObject private var viewModel = FitnessNutritionViewModel()
    @State private var section = FitnessNutritionSection.foods
    @State private var sheet: FitnessNutritionSheet?

    var body: some View {
        VStack(spacing: 0) {
            if section != .diary {
                HStack {
                    Button {
                        section = .diary
                    } label: {
                        Label("Diary", systemImage: "chevron.left")
                    }
                    Spacer()
                    Label(section.title, systemImage: section.icon).font(.headline)
                }
                .padding(.horizontal).padding(.vertical, 8)
                .background(.bar)
            }

            Group {
                switch section {
                case .diary:
                    FitnessNutritionDiaryView(viewModel: viewModel) { sheet = $0 }
                case .foods:
                    FitnessFoodLibraryView(viewModel: viewModel) { source in
                        sheet = .log(source: source)
                    }
                case .recipes:
                    FitnessRecipeLibraryView(
                        viewModel: viewModel,
                        add: { sheet = .newRecipe },
                        log: { source in sheet = .log(source: source) }
                    )
                case .templates:
                    FitnessMealTemplateLibraryView(viewModel: viewModel) { sheet = $0 }
                case .targets:
                    FitnessNutritionTargetsView(viewModel: viewModel) { sheet = .newTarget }
                }
            }
        }
        .navigationTitle("Food")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                NavigationLink {
                    FitnessBodyMeasurementsView()
                } label: {
                    Image(systemName: "ruler")
                }
                .accessibilityLabel("Body measurements")
                Menu {
                    ForEach(FitnessNutritionSection.allCases) { item in
                        Button {
                            section = item
                        } label: {
                            Label(item.title, systemImage: item.icon)
                        }
                    }
                    Divider()
                    Button {
                        sheet = .newFood
                    } label: {
                        Label("New food", systemImage: "plus")
                    }
                    Button {
                        sheet = .newRecipe
                    } label: {
                        Label("New recipe", systemImage: "frying.pan")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Nutrition tools")
            }
        }
        .overlay {
            if viewModel.isLoading && viewModel.foods.isEmpty {
                ProgressView("Loading Nutrition…")
                    .padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
        }
        .sheet(item: $sheet) { value in
            switch value {
            case .newFood:
                FitnessFoodEditorSheet(viewModel: viewModel)
            case .log(let source):
                FitnessFoodLogEditorSheet(viewModel: viewModel, initialSource: source)
            case .recommendedPortion(let itemId, let meal, let amount, let unit):
                FitnessFoodLogEditorSheet(
                    viewModel: viewModel, initialSource: "food:\(itemId)", initialMeal: meal,
                    initialAmount: amount, initialUnit: unit
                )
            case .addToMeal(let meal):
                FitnessNutritionAddFoodSheet(viewModel: viewModel, meal: meal)
            case .editLog(let id):
                FitnessFoodLogEditorSheet(
                    viewModel: viewModel, editing: viewModel.day.entries.first { $0.id == id }
                )
            case .newRecipe:
                FitnessRecipeEditorSheet(viewModel: viewModel)
            case .newTemplate(let meal):
                FitnessMealTemplateEditorSheet(viewModel: viewModel, seedMeal: meal)
            case .editTemplate(let id):
                FitnessMealTemplateEditorSheet(
                    viewModel: viewModel, editing: viewModel.templates.first { $0.id == id }
                )
            case .logTemplate(let id):
                if let template = viewModel.templates.first(where: { $0.id == id }) {
                    FitnessLogTemplateSheet(viewModel: viewModel, template: template)
                }
            case .newTarget:
                FitnessNutritionTargetEditorSheet(viewModel: viewModel)
            }
        }
        .task { await viewModel.load() }
    }
}

private struct FitnessNutritionDiaryView: View {
    @ObservedObject var viewModel: FitnessNutritionViewModel
    let openSheet: (FitnessNutritionSheet) -> Void
    @State private var repeatDate = Date()
    @State private var deleteEntry: FitnessFoodLogEntry?
    @State private var contributorMetric = FitnessNutritionMetric.caloriesKcal
    private let diaryMeals: [FitnessMeal] = [.breakfast, .lunch, .dinner, .snack]

    var body: some View {
        VStack(spacing: 0) {
            dailySummary
            List {
                if let error = viewModel.errorMessage {
                    Section { Text(error).foregroundStyle(.red) }
                }
                if let status = viewModel.statusMessage {
                    Section { Label(status, systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                }
                Section {
                    HStack {
                        Button {
                            moveDay(-1)
                        } label: {
                            Image(systemName: "chevron.left")
                        }
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityLabel("Previous day")
                        Spacer()
                        if Calendar.current.isDateInToday(viewModel.selectedDate) {
                            Text("Today").font(.headline)
                        } else {
                            DatePicker(
                                "Nutrition day",
                                selection: Binding(
                                    get: { viewModel.selectedDate },
                                    set: { value in Task { await viewModel.selectDate(value) } }
                                ), displayedComponents: .date
                            )
                            .labelsHidden()
                            Button("Today") { Task { await viewModel.selectDate(Date()) } }
                                .font(.caption)
                        }
                        Spacer()
                        Button {
                            moveDay(1)
                        } label: {
                            Image(systemName: "chevron.right")
                        }
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityLabel("Next day")
                    }
                    Text("Your day changes at \(boundaryText). Missing nutrients stay unknown rather than becoming zero.")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                ForEach(diaryMeals) { meal in
                    let entries = entries(for: meal)
                    Section {
                        if entries.isEmpty {
                            Text("Nothing logged").foregroundStyle(.secondary)
                        }
                        ForEach(entries) { entry in
                            Button {
                                openSheet(.editLog(entry.id))
                            } label: {
                                HStack(alignment: .firstTextBaseline) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(entry.foodName).foregroundStyle(.primary)
                                        Text(entryDetail(entry))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(entry.kcal.map { "\(Int($0.rounded())) kcal" } ?? "—")
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    deleteEntry = entry
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                        Button("Add food", systemImage: "plus.circle.fill") {
                            openSheet(.addToMeal(meal))
                        }
                        .fontWeight(.semibold)
                        Menu("Meal actions", systemImage: "ellipsis") {
                            Button("Repeat on selected date", systemImage: "repeat") {
                                Task { _ = await viewModel.repeatEntries(entries, on: repeatDate) }
                            }.disabled(entries.isEmpty)
                            Button("Save as meal template", systemImage: "bookmark") {
                                openSheet(.newTemplate(meal))
                            }.disabled(entries.isEmpty)
                            if meal == .breakfast {
                                Button("Repeat yesterday’s breakfast", systemImage: "clock.arrow.circlepath") {
                                    Task { _ = await viewModel.repeatYesterdayBreakfast() }
                                }
                            }
                        }
                    } header: {
                        HStack {
                            Text(meal == .snack ? "Snacks" : meal.title)
                            Spacer()
                            Text(mealSubtotal(entries))
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Day actions") {
                    DatePicker("Repeat on", selection: $repeatDate, displayedComponents: .date)
                    Button("Repeat entire day", systemImage: "repeat.circle") {
                        Task { _ = await viewModel.repeatEntries(viewModel.day.entries, on: repeatDate) }
                    }.disabled(viewModel.day.entries.isEmpty)
                    if let measured = viewModel.day.measuredShare, let estimated = viewModel.day.estimatedShare {
                        LabeledContent("Entry quality") {
                            Text(
                                "\(measured.formatted(.percent.precision(.fractionLength(0)))) measured · \(estimated.formatted(.percent.precision(.fractionLength(0)))) estimated"
                            )
                        }.foregroundStyle(.secondary)
                    }
                    if !viewModel.day.entries.isEmpty {
                        DisclosureGroup("What contributed today") {
                            Picker("Nutrient", selection: $contributorMetric) {
                                ForEach(contributorMetrics) { metric in
                                    Text(metric.title).tag(metric)
                                }
                            }
                            ForEach(contributors(for: contributorMetric)) { contributor in
                                LabeledContent {
                                    Text(
                                        "\(contributor.value.formatted(.number.precision(.fractionLength(0...1)))) \(contributorMetric.unit)"
                                    )
                                    .monospacedDigit()
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(contributor.label)
                                        Text("\(contributor.entryCount) entr\(contributor.entryCount == 1 ? "y" : "ies")")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            if viewModel.day.uncertainMetrics.contains(contributorMetric) {
                                Label(
                                    "These are exact known contributors, but at least one diary entry has no \(contributorMetric.title.lowercased()) value, so the full-day total remains unknown.",
                                    systemImage: "exclamationmark.triangle"
                                )
                                .font(.caption).foregroundStyle(.orange)
                            }
                        }
                    }
                    recentAnalysis
                }
            }
            .refreshable { await viewModel.refresh() }
        }
        .confirmationDialog(
            "Remove this diary entry?",
            isPresented: Binding(
                get: { deleteEntry != nil }, set: { if !$0 { deleteEntry = nil } }
            ), titleVisibility: .visible
        ) {
            Button("Remove entry", role: .destructive) {
                if let entry = deleteEntry {
                    Task {
                        _ = await viewModel.deleteLog(entry)
                        deleteEntry = nil
                    }
                }
            }
        }
        .onChange(of: viewModel.day.nutritionDate, initial: true) { _, nutritionDate in
            guard
                let next = FitnessCalculations.nutritionDayDate(
                    nutritionDate, addingDays: 1, calendar: .current
                )
            else { return }
            repeatDate = next
        }
    }

    private func moveDay(_ value: Int) {
        guard let date = Calendar.current.date(byAdding: .day, value: value, to: viewModel.selectedDate) else { return }
        Task { await viewModel.selectDate(date) }
    }

    private var boundaryText: String {
        String(format: "%02d:%02d", viewModel.settings.nutritionDayStartMinutes / 60, viewModel.settings.nutritionDayStartMinutes % 60)
    }

    private var dailySummary: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 18) {
                calorieSummary
                Spacer()
                macro("Protein", .proteinG)
                macro("Carbs", .carbohydrateG)
                macro("Fat", .fatG)
            }
            VStack(alignment: .leading, spacing: 10) {
                calorieSummary
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 20) {
                        macro("Protein", .proteinG)
                        macro("Carbs", .carbohydrateG)
                        macro("Fat", .fatG)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        macro("Protein", .proteinG)
                        macro("Carbs", .carbohydrateG)
                        macro("Fat", .fatG)
                    }
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.bar)
        .accessibilityElement(children: .combine)
    }

    private var calorieSummary: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(summaryDayLabel).font(.caption).foregroundStyle(.secondary)
            Text(nutrientText(.caloriesKcal)).font(.title3.bold()).monospacedDigit()
            if let remaining = remaining(.caloriesKcal) {
                Text(FitnessCalculations.nutritionBalanceText(remaining, unit: "kcal"))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var summaryDayLabel: String {
        Calendar.current.isDateInToday(viewModel.selectedDate)
            ? "Today"
            : viewModel.selectedDate.formatted(date: .abbreviated, time: .omitted)
    }

    private func macro(_ title: String, _ metric: FitnessNutritionMetric) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(nutrientText(metric)).font(.subheadline.bold()).monospacedDigit()
            if metric == .proteinG, let remaining = remaining(metric) {
                Text(FitnessCalculations.nutritionBalanceText(remaining, unit: "g"))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func remaining(_ metric: FitnessNutritionMetric) -> Double? {
        guard let target = FitnessNutritionViewFormatting.displayTarget(viewModel.effectiveTarget(for: metric)),
            let consumed = FitnessNutritionViewFormatting.nutritionValue(viewModel.day.totals, metric)
        else { return nil }
        return FitnessCalculations.nutritionTargetBalance(target: target, consumed: consumed)
    }

    private var contributorMetrics: [FitnessNutritionMetric] {
        [.caloriesKcal, .proteinG, .fibreG, .sugarsG, .saturatedFatG, .saltG]
    }

    private func contributors(for metric: FitnessNutritionMetric) -> [FitnessDiaryContributor] {
        var grouped: [String: FitnessDiaryContributor] = [:]
        for entry in viewModel.day.entries {
            guard let value = FitnessNutritionViewFormatting.nutritionValue(entry.nutrients, metric), value.isFinite else { continue }
            let key = entry.foodId ?? entry.recipeVersionId ?? entry.foodName
            if var existing = grouped[key] {
                existing.value += value
                existing.entryCount += 1
                grouped[key] = existing
            } else {
                grouped[key] = FitnessDiaryContributor(
                    id: "\(metric.rawValue):\(key)", label: entry.foodName, value: value, entryCount: 1
                )
            }
        }
        return grouped.values.sorted {
            if $0.value != $1.value { return $0.value > $1.value }
            return $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending
        }
    }

    @ViewBuilder private var recentAnalysis: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Recent pattern", systemImage: "chart.line.uptrend.xyaxis")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Picker(
                    "Analysis period",
                    selection: Binding(
                        get: { viewModel.analysisPeriodDays },
                        set: { days in Task { await viewModel.selectAnalysisPeriod(days) } }
                    )
                ) {
                    ForEach([7, 14, 28, 90], id: \.self) { days in
                        Text("\(days) days").tag(days)
                    }
                }
                .pickerStyle(.menu)
            }
            if viewModel.isLoadingAnalysis {
                ProgressView("Calculating from your diary…")
            } else if let analysis = viewModel.analysis {
                Text(
                    "\(analysis.sampleDays) of \(analysis.calendarDays) days logged · \(displayDate(analysis.start))–\(displayDate(analysis.end))"
                )
                .font(.caption).foregroundStyle(.secondary)
                Picker("Contributor nutrient", selection: $contributorMetric) {
                    ForEach(contributorMetrics) { metric in
                        Text(metric.title).tag(metric)
                    }
                }
                .pickerStyle(.menu)
                let periodContributors = analysis.contributors.filter {
                    $0.nutrientKey == contributorMetric.rawValue
                }
                if periodContributors.isEmpty {
                    Text("No exact \(contributorMetric.title.lowercased()) contributors were recorded in this period.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    DisclosureGroup("Top \(contributorMetric.title.lowercased()) contributors") {
                        ForEach(periodContributors) { contributor in
                            LabeledContent {
                                Text("\(contributor.total.formatted(.number.precision(.fractionLength(0...1)))) \(contributorMetric.unit)")
                                    .monospacedDigit()
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(contributor.label)
                                    Text(periodContributorDetail(contributor))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                if let recommendation = analysis.recommendation {
                    recommendationView(recommendation)
                } else {
                    Text(
                        "No reduction is suggested. HausKlar only proposes one when at least 7 sufficiently complete logged days are clearly above a saved calorie target and a recurring portion fits that gap."
                    )
                    .font(.footnote).foregroundStyle(.secondary)
                }
                if let error = viewModel.analysisErrorMessage {
                    Label(error, systemImage: "wifi.exclamationmark")
                        .font(.caption).foregroundStyle(.orange)
                }
            } else {
                Text("Recent-pattern analysis needs a connection. Today’s diary and exact local totals remain available offline.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("Try recent analysis", systemImage: "arrow.clockwise") {
                    Task { await viewModel.loadAnalysis(refresh: true) }
                }
                .frame(minHeight: 44)
            }
        }
        .padding(.vertical, 4)
    }

    private func recommendationView(_ recommendation: FitnessNutritionRecommendation) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Calculated improvement", systemImage: "function")
                .font(.subheadline.weight(.semibold))
            Text(recommendation.proposedChange.description)
                .font(.footnote)
            LabeledContent("Average vs target") {
                Text(
                    "\(Int(recommendation.calculation.observedAverageCaloriesKcal.rounded())) vs \(Int(recommendation.calculation.targetAverageCaloriesKcal.rounded())) kcal/day"
                )
                .multilineTextAlignment(.trailing)
            }
            .font(.caption)
            LabeledContent("Recorded gap") {
                Text("\(Int(recommendation.calculation.averageGapCaloriesKcal.rounded())) kcal/day")
            }
            .font(.caption)
            LabeledContent("Observed") {
                Text("\(recommendation.frequency.entries) entries on \(recommendation.frequency.days) days")
            }
            .font(.caption)
            LabeledContent("Typical amount") {
                Text(
                    "\(recommendation.typicalAmount.value.formatted(.number.precision(.fractionLength(0...1)))) \(recommendation.typicalAmount.unit)"
                )
            }
            .font(.caption)
            LabeledContent("Expected effect") {
                Text(
                    "≈\(Int(recommendation.expectedEffect.perOccurrenceCaloriesKcal.rounded())) kcal each time · ≈\(Int(recommendation.expectedEffect.weeklyCaloriesKcal.rounded())) kcal/week"
                )
                .multilineTextAlignment(.trailing)
            }
            .font(.caption)
            Text(recommendation.whyPractical)
                .font(.caption).foregroundStyle(.secondary)
            Text("Targets covered all \(recommendation.calculation.targetDays) logged days used in the calculation.")
                .font(.caption).foregroundStyle(.secondary)
            Label(recommendation.uncertainty.description, systemImage: "info.circle")
                .font(.caption).foregroundStyle(.secondary)
            if recommendation.itemKind == "food",
                let meal = FitnessMeal(rawValue: recommendation.mealKey)
            {
                Button("Use this portion next time", systemImage: "arrow.right.circle.fill") {
                    openSheet(
                        .recommendedPortion(
                            itemId: recommendation.itemId, meal: meal,
                            amount: recommendation.proposedChange.resultingAmount,
                            unit: recommendation.proposedChange.unit
                        ))
                }
                .buttonStyle(.borderedProminent)
            }
            Text("This is calculated tracking guidance, not medical advice.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.top, 4)
    }

    private func periodContributorDetail(_ contributor: FitnessNutritionAnalysisContributor) -> String {
        let meal =
            FitnessMeal(rawValue: contributor.mealKey)?.title ?? contributor.mealKey.replacingOccurrences(of: "_", with: " ").capitalized
        var details = [
            "\(meal) · \(contributor.entryCount) entr\(contributor.entryCount == 1 ? "y" : "ies") on \(contributor.sampleDays) days"
        ]
        if let amount = contributor.typicalAmount, let unit = contributor.typicalUnit {
            details.append("typical \(amount.formatted(.number.precision(.fractionLength(0...1)))) \(unit)")
        }
        if let share = contributor.share {
            details.append(share.formatted(.percent.precision(.fractionLength(0))))
        }
        return details.joined(separator: " · ")
    }

    private func displayDate(_ value: String) -> String {
        guard let date = ISODateParser.parseDateOnly(value) else { return value }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }

    private func nutrientText(_ metric: FitnessNutritionMetric) -> String {
        FitnessNutritionViewFormatting.nutritionValue(viewModel.day.totals, metric).map {
            "\(Int($0.rounded())) \(metric.unit)"
        } ?? "—"
    }
    private func entries(for meal: FitnessMeal) -> [FitnessFoodLogEntry] {
        if meal != .snack { return viewModel.day.entries.filter { $0.meal == meal } }
        return viewModel.day.entries.filter { ![.breakfast, .lunch, .dinner].contains($0.meal) }
    }
    private func mealSubtotal(_ entries: [FitnessFoodLogEntry]) -> String {
        let known = entries.compactMap(\.kcal).reduce(0, +)
        guard !entries.isEmpty else { return "0 kcal" }
        return "\(Int(known.rounded())) kcal\(entries.contains { $0.kcal == nil } ? " + ?" : "")"
    }
    private func entryDetail(_ entry: FitnessFoodLogEntry) -> String {
        let amount = "\(entry.enteredAmount.formatted()) \(entry.enteredUnit)"
        let quality = entry.measurementQuality.title
        guard ![.breakfast, .lunch, .dinner, .snack].contains(entry.meal) else {
            return "\(amount) · \(quality)"
        }
        return "\(entry.meal.title) · \(amount) · \(quality)"
    }
}

private struct FitnessDiaryContributor: Identifiable {
    let id: String
    let label: String
    var value: Double
    var entryCount: Int
}
