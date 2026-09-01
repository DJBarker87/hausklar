import PhotosUI
import SwiftUI

private enum FitnessLogHomeSheet: Identifiable {
    case addFood(FitnessMeal)
    case editLog(String)
    case newFood
    case mealPhoto
    case dictation
    case plannedMeal(String)
    case measurement
    case sleep
    case bodyIssue
    case householdLinks
    case nutritionTarget(FitnessNutritionMetric)

    var id: String {
        switch self {
        case .addFood(let meal): "add-food-\(meal.rawValue)"
        case .editLog(let id): "edit-\(id)"
        case .newFood: "new-food"
        case .mealPhoto: "meal-photo"
        case .dictation: "dictation"
        case .plannedMeal(let id): "planned-\(id)"
        case .measurement: "measurement"
        case .sleep: "sleep"
        case .bodyIssue: "body-issue"
        case .householdLinks: "household-links"
        case .nutritionTarget(let metric): "nutrition-target-\(metric.rawValue)"
        }
    }
}

struct FitnessLogHomeView: View {
    @StateObject private var viewModel = FitnessNutritionViewModel()
    @StateObject private var bodyViewModel = FitnessBodyMeasurementsViewModel()
    @StateObject private var recoveryViewModel = FitnessRecoveryViewModel()
    @State private var sheet: FitnessLogHomeSheet?
    @State private var deleteEntry: FitnessFoodLogEntry?
    @State private var addingPlannedMealIds: Set<String> = []
    @AccessibilityFocusState private var undoFocused: Bool
    private let diaryMeals: [FitnessMeal] = [.breakfast, .lunch, .dinner, .snack]

    var body: some View {
        List {
            if let error = viewModel.errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                    Button("Try again") {
                        Task { await viewModel.loadLogHome(refresh: true) }
                    }
                }
            }
            dayNavigationSection
            dailySummarySection
            Section {
                Button {
                    sheet = .addFood(currentMeal)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "magnifyingglass")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 36,height: 36)
                            .background(Color.accentColor.opacity(0.12),in:Circle())
                        VStack(alignment:.leading,spacing:2) {
                            Text("Search and add food")
                                .font(.headline)
                                .foregroundStyle(.primary)
                            Text("\(currentMeal.title) is selected")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength:8)
                        Image(systemName:"chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth:.infinity,minHeight:52,alignment:.leading)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("fitnessFoodSearch")
            }
            ForEach(diaryMeals) { meal in
                diarySection(meal)
            }
            plannedMealSection
            addSection
            recordSection
            Section("Manage") {
                Button {
                    sheet = .householdLinks
                } label: {
                    Label("Recipes for household meals", systemImage: "house.and.flag")
                }
                .frame(minHeight: 44)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Food diary")
        .overlay {
            if viewModel.isLoading && viewModel.foods.isEmpty { ProgressView("Loading diary…") }
        }
        .refreshable { await viewModel.refreshLogHome() }
        .safeAreaInset(edge: .bottom) {
            if let undo = viewModel.quickLogUndo {
                HStack(spacing: 12) {
                    Image(systemName:"checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .accessibilityHidden(true)
                    VStack(alignment:.leading,spacing:2) {
                        Text("Added \(undo.foodName)")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if let highlight = FitnessNutritionViewFormatting.addedHighlight(for: undo) {
                            Text(highlight)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Undo") { Task { await viewModel.undoQuickLog() } }
                        .fontWeight(.semibold).frame(minHeight: 44)
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(.bar)
                .overlay(alignment: .top) { Divider() }
                .accessibilityElement(children:.contain)
                .accessibilityFocused($undoFocused)
            }
        }
        .sheet(item: $sheet) { item in sheetContent(item) }
        .confirmationDialog(
            "Remove this diary entry?",
            isPresented: Binding(
                get: { deleteEntry != nil },
                set: { if !$0 { deleteEntry = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove entry", role: .destructive) {
                guard let entry = deleteEntry else { return }
                Task {
                    _ = await viewModel.deleteLog(entry)
                    deleteEntry = nil
                }
            }
        }
        .task { await viewModel.loadLogHome() }
        .onChange(of: viewModel.quickLogUndo?.id) { _, id in
            undoFocused = FitnessLogAccessibilityTarget.afterQuickLog(entryId: id) == .undo
        }
    }

    private var dayNavigationSection: some View {
        Section {
            HStack(spacing:12) {
                Button {
                    moveDay(-1)
                } label: {
                    Image(systemName:"chevron.left")
                        .frame(width:44,height:44)
                }
                .accessibilityLabel("Previous day")
                Spacer(minLength:0)
                VStack(spacing:2) {
                    Text(dayTitle)
                        .font(.headline)
                    if !Calendar.current.isDateInToday(viewModel.selectedDate) {
                        Button("Back to today") {
                            Task { await selectDay(Date()) }
                        }
                        .font(.caption.weight(.semibold))
                    }
                }
                .frame(maxWidth:.infinity)
                Spacer(minLength:0)
                Button {
                    moveDay(1)
                } label: {
                    Image(systemName:"chevron.right")
                        .frame(width:44,height:44)
                }
                .accessibilityLabel("Next day")
            }
        }
    }

    private var dailySummarySection: some View {
        Section("Daily nutrition") {
            HStack(spacing:0) {
                nutritionSummary(.caloriesKcal,symbol:"flame.fill",tint:.orange)
                Divider().frame(height:54)
                nutritionSummary(.proteinG,symbol:"p.circle.fill",tint:.indigo)
            }
            .padding(.vertical,4)
        }
    }

    private func nutritionSummary(
        _ metric: FitnessNutritionMetric,
        symbol: String,
        tint: Color
    ) -> some View {
        let target = viewModel.effectiveTarget(for: metric)
        let value = FitnessNutritionViewFormatting.nutritionValue(viewModel.day.totals,metric)
        let targetValue = FitnessNutritionViewFormatting.displayTarget(target)
        return Button {
            sheet = .nutritionTarget(metric)
        } label: {
            VStack(alignment:.leading,spacing:4) {
                HStack(spacing:6) {
                Image(systemName: symbol)
                        .foregroundStyle(tint)
                    Text(metric.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Text(summaryValue(value,metric:metric))
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.primary)
                    .monospacedDigit()
                Text(targetValue.map { "of \(summaryValue($0,metric:metric))" } ?? "Tap to set a target")
                    .font(.caption)
                    .foregroundStyle(targetValue == nil ? Color.accentColor : Color.secondary)
            }
            .frame(maxWidth:.infinity,minHeight:64,alignment:.leading)
            .padding(.horizontal,12)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            "\(target == nil ? "Set" : "Change") \(metric.title.lowercased()) target"
        )
        .accessibilityIdentifier("fitnessNutritionTarget-\(metric.rawValue)")
    }

    @ViewBuilder private func diarySection(_ meal:FitnessMeal) -> some View {
        let mealEntries=entries(for:meal)
        Section {
            ForEach(mealEntries) { entry in
                Button {
                    sheet = .editLog(entry.id)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.foodName).foregroundStyle(.primary)
                            Text(entryDetail(entry))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(entry.kcal.map { "\(Int($0.rounded())) kcal" } ?? "—")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .frame(maxWidth:.infinity,minHeight:44,alignment:.leading)
                }
                .buttonStyle(.plain)
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        deleteEntry = entry
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
                .accessibilityIdentifier("fitnessLogTodayEntry-\(entry.id)")
            }
            Button {
                sheet = .addFood(meal)
            } label: {
                Label("Add food",systemImage:"plus.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth:.infinity,minHeight:44,alignment:.leading)
            }
            .accessibilityIdentifier("fitnessAddFood-\(meal.rawValue)")
        } header: {
            HStack(alignment:.firstTextBaseline) {
                Text(meal == .snack ? "Snacks" : meal.title)
                Spacer(minLength:8)
                if !mealEntries.isEmpty {
                    Text(mealSubtotal(mealEntries))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
    }

    @ViewBuilder private var plannedMealSection: some View {
        if FitnessPlannedMealShortcutPolicy.isVisible(
            plannedMealCount: viewModel.plannedMeals.count, useMealPlanForCoach: false
        ) {
            Section("From the meal plan") {
                ForEach(viewModel.plannedMeals) { meal in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(meal.recipeName)
                            Text("\(meal.mealType.title) · \(meal.mealName)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if viewModel.isPlannedMealAdded(meal) {
                            Label("Added", systemImage: "checkmark.circle.fill")
                                .font(.subheadline).foregroundStyle(.green)
                        } else {
                            Button("Add") {
                                // One queued planned-meal log per tap: a second
                                // tap while the first is saving would queue a
                                // duplicate the server then has to reject.
                                guard !addingPlannedMealIds.contains(meal.mealPlanId) else { return }
                                addingPlannedMealIds.insert(meal.mealPlanId)
                                Task {
                                    defer { addingPlannedMealIds.remove(meal.mealPlanId) }
                                    do {
                                        _ = await viewModel.logPlannedMeal(
                                            .init(
                                                plannedMeal: meal,
                                                clientId: try APIClient.shared.clientId
                                            ))
                                    } catch {
                                        viewModel.errorMessage = error.localizedDescription
                                    }
                                }
                            }
                            .disabled(addingPlannedMealIds.contains(meal.mealPlanId))
                            .buttonStyle(.borderedProminent).controlSize(.small)
                            Button {
                                sheet = .plannedMeal(meal.id)
                            } label: {
                                Image(systemName: "slider.horizontal.3")
                            }
                            .buttonStyle(.borderless)
                            .frame(minWidth: 44, minHeight: 44)
                            .accessibilityLabel("Adjust portion for \(meal.recipeName)")
                        }
                    }
                    .frame(minHeight: 52)
                }
            }
        }
    }

    private var addSection: some View {
        Section("More ways to add") {
            Button {
                sheet = .newFood
            } label: {
                Label("Custom food, barcode or label", systemImage: "barcode.viewfinder")
            }
            .frame(minHeight: 44)
            Button {
                sheet = .mealPhoto
            } label: {
                Label("Use a meal photo", systemImage: "camera.example_5f7f1d8c")
            }
            .frame(minHeight: 44)
            Button {
                sheet = .dictation
            } label: {
                Label("Dictate what you ate", systemImage: "mic.fill")
            }
            .frame(minHeight: 44)
        }
    }

    private var recordSection: some View {
        Section("Record something else") {
            Button {
                sheet = .measurement
            } label: {
                Label("Measurement", systemImage: "ruler")
            }.frame(minHeight: 44)
            Button {
                sheet = .sleep
            } label: {
                Label("Sleep", systemImage: "bed.double.fill")
            }.frame(minHeight: 44)
            Button {
                sheet = .bodyIssue
            } label: {
                Label("Body issue", systemImage: "figure.arms.open")
            }.frame(minHeight: 44)
        }
    }

    @ViewBuilder private func sheetContent(_ item: FitnessLogHomeSheet) -> some View {
        switch item {
        case .addFood(let meal):
            FitnessNutritionAddFoodSheet(viewModel:viewModel,meal:meal)
        case .editLog(let id):
            if let entry = viewModel.day.entries.first(where: { $0.id == id }) {
                FitnessFoodLogEditorSheet(viewModel: viewModel, editing: entry)
            }
        case .newFood:
            FitnessFoodEditorSheet(viewModel: viewModel)
        case .mealPhoto:
            FitnessMealPhotoDraftSheet(viewModel: viewModel, initialMeal: currentMeal)
        case .dictation:
            FitnessDictatedFoodDraftSheet(viewModel: viewModel, initialMeal: currentMeal)
        case .plannedMeal(let id):
            if let meal = viewModel.plannedMeals.first(where: { $0.id == id }) {
                FitnessPlannedMealEditorSheet(viewModel: viewModel, meal: meal)
            }
        case .measurement:
            FitnessQuickMeasurementSheet(viewModel: bodyViewModel)
        case .sleep:
            FitnessManualSleepSheet(viewModel: recoveryViewModel, existing: nil)
        case .bodyIssue:
            FitnessNewBodyIssueSheet(viewModel: recoveryViewModel)
        case .householdLinks:
            FitnessHouseholdRecipeLinksView(viewModel: viewModel)
        case .nutritionTarget(let metric):
            FitnessNutritionTargetEditorSheet(
                viewModel: viewModel,
                initialMetric: metric,
                editing: viewModel.effectiveTarget(for: metric)
            )
        }
    }

    private var currentMeal: FitnessMeal {
        switch Calendar.current.component(.hour, from: Date()) {
        case 4..<11: .breakfast
        case 11..<15: .lunch
        case 17..<22: .dinner
        default: .snack
        }
    }

    private var dayTitle:String {
        Calendar.current.isDateInToday(viewModel.selectedDate)
            ? "Today"
            : viewModel.selectedDate.formatted(date:.abbreviated,time:.omitted)
    }

    private func moveDay(_ offset:Int) {
        guard let date=Calendar.current.date(byAdding:.day,value:offset,to:viewModel.selectedDate) else { return }
        Task { await selectDay(date) }
    }

    private func selectDay(_ date:Date) async {
        await viewModel.selectLogDate(date)
    }

    private func entries(for meal:FitnessMeal) -> [FitnessFoodLogEntry] {
        if meal != .snack { return viewModel.day.entries.filter { $0.meal == meal } }
        return viewModel.day.entries.filter { ![.breakfast,.lunch,.dinner].contains($0.meal) }
    }

    private func mealSubtotal(_ entries:[FitnessFoodLogEntry]) -> String {
        let known=entries.compactMap(\.kcal)
        guard !known.isEmpty else { return "Energy unknown" }
        return "\(Int(known.reduce(0,+).rounded())) kcal"
    }

    private func entryDetail(_ entry:FitnessFoodLogEntry) -> String {
        var values=["\(entry.enteredAmount.formatted()) \(entry.enteredUnit)"]
        if let protein=entry.proteinG,protein > 0 {
            values.append("\(protein.formatted(.number.precision(.fractionLength(0...1)))) g protein")
        }
        return values.joined(separator:" · ")
    }

    private func summaryValue(_ value:Double?,metric:FitnessNutritionMetric) -> String {
        guard let value else { return "—" }
        let amount=value.formatted(.number.precision(.fractionLength(0...1)))
        return metric == .caloriesKcal ? "\(Int(value.rounded())) kcal" : "\(amount) \(metric.unit)"
    }
}

private struct FitnessPlannedMealEditorSheet: View {
    @ObservedObject var viewModel: FitnessNutritionViewModel
    let meal: FitnessPlannedHouseholdMeal
    @Environment(\.dismiss) private var dismiss
    @State private var portion: String
    @State private var notes = ""

    init(viewModel: FitnessNutritionViewModel, meal: FitnessPlannedHouseholdMeal) {
        self.viewModel = viewModel
        self.meal = meal
        _portion = State(initialValue: String(format: "%g", meal.suggestedPortion))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Portion") {
                    HStack {
                        TextField("Amount", text: $portion).keyboardType(.decimalPad)
                        Text(meal.suggestedUnit.title).foregroundStyle(.secondary)
                    }
                    TextField("Note (optional)", text: $notes, axis: .vertical)
                }
                Section {
                    LabeledContent("Meal", value: meal.mealName)
                    LabeledContent("Recipe", value: meal.recipeName)
                }
                if let error = viewModel.errorMessage {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Add planned meal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        guard let value = Double(portion) else { return }
                        Task {
                            do {
                                if await viewModel.logPlannedMeal(
                                    .init(
                                        plannedMeal: meal, portion: value, unit: meal.suggestedUnit,
                                        notes: FitnessNutritionViewFormatting.emptyNil(notes), clientId: try APIClient.shared.clientId
                                    ))
                                {
                                    dismiss()
                                }
                            } catch {
                                viewModel.errorMessage = error.localizedDescription
                            }
                        }
                    }
                    .disabled(!(Double(portion).map { $0.isFinite && $0 > 0 } ?? false))
                }
            }
        }
    }
}

private struct FitnessHouseholdRecipeLinksView: View {
    @ObservedObject var viewModel: FitnessNutritionViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedMeal: FitnessHouseholdMeal?

    var body: some View {
        NavigationStack {
            List {
                if let status = viewModel.statusMessage {
                    Section { Label(status, systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                }
                if let error = viewModel.errorMessage {
                    Section {
                        Text(error).foregroundStyle(.red)
                        Button("Try again") { Task { await viewModel.loadHouseholdRecipeLinks(refresh: true) } }
                    }
                }
                Section("Household meals") {
                    if viewModel.householdMeals.isEmpty && !viewModel.isLoading {
                        Text("No household meals yet").foregroundStyle(.secondary)
                    }
                    ForEach(viewModel.householdMeals) { meal in
                        Button {
                            selectedMeal = meal
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(meal.name).foregroundStyle(.primary)
                                    Text(link(for: meal)?.recipeName ?? "Choose a recipe")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                            }
                            .frame(minHeight: 44)
                        }
                    }
                }
                Section("Recipes available to the household") {
                    if viewModel.recipes.isEmpty && !viewModel.isLoading {
                        Text("Create a recipe first, then make it available here.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(viewModel.recipes.filter { $0.active && $0.editable }) { recipe in
                        Toggle(
                            recipe.name,
                            isOn: Binding(
                                get: { recipe.householdShared },
                                set: { value in
                                    var copy = recipe
                                    copy.householdShared = value
                                    Task { _ = await viewModel.saveRecipe(copy) }
                                }
                            )
                        )
                        .frame(minHeight: 44)
                    }
                }
            }
            .navigationTitle("Household meal recipes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .overlay { if viewModel.isLoading && viewModel.householdMeals.isEmpty { ProgressView() } }
            .task { await viewModel.loadHouseholdRecipeLinks() }
            .sheet(item: $selectedMeal) { meal in
                FitnessHouseholdRecipeLinkEditor(
                    viewModel: viewModel, meal: meal, current: link(for: meal)
                )
            }
        }
    }

    private func link(for meal: FitnessHouseholdMeal) -> FitnessHouseholdMealLink? {
        viewModel.householdMealLinks.first { $0.mealId == meal.id }
    }
}

private struct FitnessHouseholdRecipeLinkEditor: View {
    @ObservedObject var viewModel: FitnessNutritionViewModel
    let meal: FitnessHouseholdMeal
    let current: FitnessHouseholdMealLink?
    @Environment(\.dismiss) private var dismiss
    @State private var recipeId: String

    init(
        viewModel: FitnessNutritionViewModel, meal: FitnessHouseholdMeal,
        current: FitnessHouseholdMealLink?
    ) {
        self.viewModel = viewModel
        self.meal = meal
        self.current = current
        _recipeId = State(initialValue: current?.recipeId ?? "")
    }

    private var sharedRecipes: [FitnessRecipe] {
        viewModel.recipes.filter { $0.active && $0.householdShared && $0.currentVersion != nil }
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("Recipe", selection: $recipeId) {
                    Text("Choose recipe").tag("")
                    ForEach(sharedRecipes) { Text($0.name).tag($0.id) }
                }
                if sharedRecipes.isEmpty {
                    Text("Make a recipe available to the household first.")
                        .foregroundStyle(.secondary)
                }
                if current != nil {
                    Button("Remove recipe link", role: .destructive) {
                        Task { if await viewModel.unlinkHouseholdMeal(meal) { dismiss() } }
                    }
                }
                if let error = viewModel.errorMessage { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle(meal.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let recipe = viewModel.recipes.first(where: { $0.id == recipeId }) else { return }
                        Task { if await viewModel.linkHouseholdMeal(meal, to: recipe) { dismiss() } }
                    }
                    .disabled(recipeId.isEmpty)
                }
            }
        }
    }
}

private struct FitnessMealPhotoDraftSheet: View {
    @ObservedObject var viewModel: FitnessNutritionViewModel
    let initialMeal: FitnessMeal
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState
    @StateObject private var photoDraft = FitnessNutritionPhotoDraftOwner()
    @State private var pickedItem: PhotosPickerItem?
    @State private var photoLoadTask: Task<Void, Never>?
    @State private var photoError: String?
    @State private var isSaving = false
    // Minted with the sheet so a repeated tap updates this entry rather than
    // adding a second copy of the same food.
    @State private var draftEntryId = UUID().uuidString
    @State private var source = ""
    @State private var amount = ""
    @State private var meal: FitnessMeal
    @State private var note = ""

    init(viewModel: FitnessNutritionViewModel, initialMeal: FitnessMeal) {
        self.viewModel = viewModel
        self.initialMeal = initialMeal
        _meal = State(initialValue: initialMeal)
    }

    private var activeAccountKey: String? {
        appState.currentUser.map { "\($0.familyId ?? ""):\($0.id)" }
    }

    var body: some View {
        let hasMealPreview = photoDraft.mealPreview != nil
        NavigationStack {
            Form {
                Section("Photo") {
                    PhotosPicker(selection: $pickedItem, matching: .images) {
                        Label(
                            !hasMealPreview
                                ? "Choose meal photo" : "Choose another photo",
                            systemImage: "photo"
                        )
                        .frame(minHeight: 44)
                    }
                    if let image = photoDraft.mealPreview {
                        Image(uiImage: image)
                            .resizable().scaledToFit()
                            .frame(maxHeight: 240).clipShape(RoundedRectangle(cornerRadius: 14))
                            .accessibilityLabel("Selected meal photo")
                    }
                    Text("Use the photo while you review the item and portion below.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if let photoError {
                        Text(photoError).font(.footnote).foregroundStyle(.red)
                    }
                }
                captureFields
                if let error = viewModel.errorMessage { Section { Text(error).foregroundStyle(.red) } }
            }
            .navigationTitle("Review meal photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        cleanupPhoto()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { Task { await save() } }.disabled(!isValid || isSaving)
                }
            }
            .onChange(of: pickedItem) { _, item in
                guard let item else { return }
                loadMealPhoto(item)
            }
            .onChange(of: activeAccountKey) { oldIdentity, newIdentity in
                guard oldIdentity != newIdentity else { return }
                cleanupPhoto()
                dismiss()
            }
            .onDisappear { cleanupPhoto() }
            .onChange(of: source) { _, _ in seedAmount() }
        }
    }

    private var captureFields: some View {
        Section("Review entry") {
            FitnessCaptureSourcePicker(viewModel: viewModel, source: $source)
            HStack {
                TextField("Portion", text: $amount).keyboardType(.decimalPad)
                Text(fitnessCaptureUnit(source: source, viewModel: viewModel) ?? "")
                    .foregroundStyle(.secondary)
            }
            Picker("Meal", selection: $meal) {
                ForEach(FitnessMeal.allCases) { Text($0.title).tag($0) }
            }
            TextField("What was on the plate? (optional)", text: $note, axis: .vertical)
        }
    }

    private var isValid: Bool {
        photoDraft.mealPreview != nil
            && fitnessCaptureDraft(
                source: source, amount: Double(amount) ?? 0, meal: meal,
                notes: FitnessNutritionViewFormatting.emptyNil(note), viewModel: viewModel
            ) != nil
    }

    private func seedAmount() {
        amount =
            fitnessCaptureDefaultAmount(source: source, viewModel: viewModel)
            .map { String(format: "%g", $0) } ?? ""
    }

    private func save() async {
        guard !isSaving else { return }
        guard
            let draft = fitnessCaptureDraft(
                source: source, amount: Double(amount) ?? 0, meal: meal,
                notes: FitnessNutritionViewFormatting.emptyNil(note), viewModel: viewModel
            )
        else {
            cleanupPhoto()
            return
        }
        isSaving = true
        defer { isSaving = false }
        let succeeded = await viewModel.saveLog(draft, entryId: draftEntryId)
        cleanupPhoto()
        if succeeded { dismiss() }
    }

    private func loadMealPhoto(_ item: PhotosPickerItem) {
        photoLoadTask?.cancel()
        photoError = nil
        let generation = photoDraft.beginReplacement()
        guard let expectedIdentity = FitnessDatabase.shared.activeIdentity else {
            photoError = FitnessNutritionRepositoryError.inactiveProfile.localizedDescription
            return
        }
        let declaredTypes = item.supportedContentTypes.map(\.identifier)
        photoLoadTask = Task {
            var stagedFile: PhotoUploadPrep.StagedFile?
            do {
                guard
                    let transfer = try await item.loadTransferable(
                        type: StagedPhotoTransfer.self
                    )
                else { throw PhotoUploadPrepError.unreadableFile }
                let ownedFile = try transfer.takeStagedFile()
                stagedFile = ownedFile
                let preparation = Task.detached(priority: .userInitiated) {
                    _ = try PhotoUploadPrep.validatedStagedImageByteCount(
                        ownedFile, declaredTypeIdentifiers: declaredTypes
                    )
                    try Task.checkCancellation()
                    guard
                        let preview = PhotoUploadPrep.displayImage(
                            at: ownedFile.fileURL, maxPixelSize: 1_600
                        )
                    else { throw PhotoUploadPrepError.unreadableFile }
                    return preview
                }
                let preview = try await withTaskCancellationHandler {
                    try await preparation.value
                } onCancel: {
                    preparation.cancel()
                }
                try Task.checkCancellation()
                guard FitnessDatabase.shared.activeIdentity == expectedIdentity else {
                    throw FitnessNutritionRepositoryError.inactiveProfile
                }
                _ = photoDraft.installMealPhoto(
                    ownedFile, preview: preview, generation: generation
                )
                stagedFile = nil
            } catch is CancellationError {
                if let stagedFile { PhotoUploadPrep.removeStagedFile(stagedFile) }
            } catch {
                if let stagedFile { PhotoUploadPrep.removeStagedFile(stagedFile) }
                guard !Task.isCancelled else { return }
                photoError = error.localizedDescription
            }
        }
    }

    private func cleanupPhoto() {
        photoLoadTask?.cancel()
        photoLoadTask = nil
        pickedItem = nil
        photoDraft.discard()
    }
}

private struct FitnessDictatedFoodDraftSheet: View {
    @ObservedObject var viewModel: FitnessNutritionViewModel
    let initialMeal: FitnessMeal
    @Environment(\.dismiss) private var dismiss
    @StateObject private var dictation = DictationService()
    @State private var reviewedText = ""
    @State private var dictationPrefix = ""
    @State private var source = ""
    @State private var amount = ""
    @State private var meal: FitnessMeal
    @State private var isSaving = false
    // Minted with the sheet so a repeated tap updates this entry rather than
    // adding a second copy of the same food.
    @State private var draftEntryId = UUID().uuidString

    init(viewModel: FitnessNutritionViewModel, initialMeal: FitnessMeal) {
        self.viewModel = viewModel
        self.initialMeal = initialMeal
        _meal = State(initialValue: initialMeal)
    }

    private var matches: [FitnessFood] {
        guard FitnessCapturePolicy.canSaveReviewedText(reviewedText) else { return [] }
        let words = reviewedText.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        return viewModel.foods.filter { food in
            let name = food.name.lowercased()
            return name.count > 2
                && (reviewedText.localizedCaseInsensitiveContains(food.name)
                    || words.contains(where: { $0.count > 2 && name.contains($0) }))
        }.prefix(5).map { $0 }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("What did you eat?") {
                    TextEditor(text: $reviewedText)
                        .frame(minHeight: 110)
                        .accessibilityLabel("Editable food description")
                    Button {
                        toggleDictation()
                    } label: {
                        Label(
                            dictation.isRecording ? "Stop dictation" : "Dictate",
                            systemImage: dictation.isRecording ? "stop.fill" : "mic.fill"
                        )
                    }
                    .frame(minHeight: 44)
                    .tint(dictation.isRecording ? .red : nil)
                    if let error = dictation.errorMessage {
                        Text(error).foregroundStyle(.red)
                    }
                    Text("Edit the words before you add anything.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if !matches.isEmpty {
                    Section("Matches") {
                        ForEach(matches) { food in
                            Button(food.name) {
                                source = "food:\(food.id)"
                                seedAmount()
                            }
                            .frame(minHeight: 44)
                        }
                    }
                }
                Section("Review entry") {
                    FitnessCaptureSourcePicker(viewModel: viewModel, source: $source)
                    HStack {
                        TextField("Portion", text: $amount).keyboardType(.decimalPad)
                        Text(fitnessCaptureUnit(source: source, viewModel: viewModel) ?? "")
                            .foregroundStyle(.secondary)
                    }
                    Picker("Meal", selection: $meal) {
                        ForEach(FitnessMeal.allCases) { Text($0.title).tag($0) }
                    }
                }
                if let error = viewModel.errorMessage { Section { Text(error).foregroundStyle(.red) } }
            }
            .navigationTitle("Review dictation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { Task { await save() } }.disabled(!isValid || isSaving)
                }
            }
            .onChange(of: dictation.transcript) { _, transcript in
                reviewedText = dictationPrefix + transcript
            }
            .onChange(of: source) { _, _ in seedAmount() }
            .onDisappear { dictation.stop() }
        }
    }

    private var isValid: Bool {
        FitnessCapturePolicy.canSaveReviewedText(reviewedText)
            && fitnessCaptureDraft(
                source: source, amount: Double(amount) ?? 0, meal: meal,
                notes: reviewedText.trimmingCharacters(in: .whitespacesAndNewlines), viewModel: viewModel
            ) != nil
    }

    private func toggleDictation() {
        if dictation.isRecording {
            dictation.stop()
            return
        }
        let existing = reviewedText.trimmingCharacters(in: .whitespacesAndNewlines)
        dictationPrefix = existing.isEmpty ? "" : existing + " "
        Task { await dictation.start() }
    }

    private func seedAmount() {
        amount =
            fitnessCaptureDefaultAmount(source: source, viewModel: viewModel)
            .map { String(format: "%g", $0) } ?? ""
    }

    private func save() async {
        guard !isSaving else { return }
        dictation.stop()
        guard
            let draft = fitnessCaptureDraft(
                source: source, amount: Double(amount) ?? 0, meal: meal,
                notes: reviewedText.trimmingCharacters(in: .whitespacesAndNewlines), viewModel: viewModel
            )
        else { return }
        isSaving = true
        defer { isSaving = false }
        if await viewModel.saveLog(draft, entryId: draftEntryId) { dismiss() }
    }
}

private struct FitnessCaptureSourcePicker: View {
    @ObservedObject var viewModel: FitnessNutritionViewModel
    @Binding var source: String

    var body: some View {
        Picker("Saved item", selection: $source) {
            Text("Choose item").tag("")
            Section("Foods") {
                ForEach(viewModel.foods.filter { $0.active && $0.currentVersion != nil }) {
                    Text($0.name).tag("food:\($0.id)")
                }
            }
            Section("Recipes") {
                ForEach(viewModel.recipes.filter { $0.active && $0.currentVersion != nil }) {
                    Text($0.name).tag("recipe:\($0.id)")
                }
            }
        }
    }
}

private struct FitnessQuickMeasurementSheet: View {
    @ObservedObject var viewModel: FitnessBodyMeasurementsViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var metricKey = "body.weight_kg"
    @State private var value = ""
    @State private var unit = "kg"
    @State private var measuredAt = Date()
    @State private var notes = ""

    var body: some View {
        NavigationStack {
            Form {
                Picker("Measurement", selection: $metricKey) {
                    ForEach(FitnessBodyMetricPreset.values) { preset in
                        Text(preset.title).tag(preset.key)
                    }
                }
                .onChange(of: metricKey) { _, key in
                    if let preset = FitnessBodyMetricPreset.values.first(where: { $0.key == key }) {
                        unit = preset.unit
                    }
                }
                HStack {
                    TextField("Value", text: $value).keyboardType(.decimalPad)
                    Text(unit).foregroundStyle(.secondary)
                }
                DatePicker("When", selection: $measuredAt)
                TextField("Note (optional)", text: $notes, axis: .vertical)
                if let error = viewModel.errorMessage { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("Add measurement")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let number = Double(value) else { return }
                        Task {
                            if await viewModel.save(
                                existing: nil, metricKey: metricKey, value: number, unitKey: unit,
                                notes: FitnessNutritionViewFormatting.emptyNil(notes), measuredAt: measuredAt, quality: "measured"
                            ) {
                                dismiss()
                            }
                        }
                    }
                    .disabled(!(Double(value).map { $0.isFinite && $0 > 0 } ?? false))
                }
            }
        }
    }
}

@MainActor private func fitnessCaptureUnit(
    source: String, viewModel: FitnessNutritionViewModel
) -> String? {
    if source.hasPrefix("food:"),
        let food = viewModel.foods.first(where: { $0.id == String(source.dropFirst(5)) })
    {
        return food.currentVersion?.referenceUnit
    }
    if source.hasPrefix("recipe:"),
        let recipe = viewModel.recipes.first(where: { $0.id == String(source.dropFirst(7)) }),
        let version = recipe.currentVersion
    {
        return version.servings != nil ? "serving" : "g"
    }
    return nil
}

@MainActor private func fitnessCaptureDefaultAmount(
    source: String, viewModel: FitnessNutritionViewModel
) -> Double? {
    if source.hasPrefix("food:"),
        let food = viewModel.foods.first(where: { $0.id == String(source.dropFirst(5)) }),
        let version = food.currentVersion
    {
        let quick = food.quickUse
        let unit = quick?.usualUnit ?? quick?.lastUnit
        if unit == version.referenceUnit, let value = quick?.usualAmount ?? quick?.lastAmount { return value }
        return version.referenceAmount
    }
    if source.hasPrefix("recipe:"),
        let recipe = viewModel.recipes.first(where: { $0.id == String(source.dropFirst(7)) }),
        let version = recipe.currentVersion
    {
        return version.servings != nil ? 1 : min(version.finishedWeightG ?? 100, 100)
    }
    return nil
}

@MainActor private func fitnessCaptureDraft(
    source: String, amount: Double, meal: FitnessMeal, notes: String?,
    viewModel: FitnessNutritionViewModel
) -> FitnessFoodLogDraft? {
    guard amount.isFinite, amount > 0 else { return nil }
    if source.hasPrefix("food:"),
        let food = viewModel.foods.first(where: { $0.id == String(source.dropFirst(5)) }),
        let version = food.currentVersion
    {
        return FitnessFoodLogDraft(
            foodVersionId: version.id, recipeVersionId: nil, label: food.name,
            loggedAt: Date(), localTimezone: TimeZone.current.identifier, meal: meal,
            enteredAmount: amount, enteredUnit: version.referenceUnit,
            canonicalAmount: amount, canonicalUnit: version.referenceUnit,
            measurementQuality: .estimated, notes: notes, contextTags: []
        )
    }
    if source.hasPrefix("recipe:"),
        let recipe = viewModel.recipes.first(where: { $0.id == String(source.dropFirst(7)) }),
        let version = recipe.currentVersion
    {
        let unit = version.servings != nil ? "serving" : "g"
        return FitnessFoodLogDraft(
            foodVersionId: nil, recipeVersionId: version.id, label: recipe.name,
            loggedAt: Date(), localTimezone: TimeZone.current.identifier, meal: meal,
            enteredAmount: amount, enteredUnit: unit, canonicalAmount: amount, canonicalUnit: unit,
            measurementQuality: .estimated, notes: notes, contextTags: []
        )
    }
    return nil
}
