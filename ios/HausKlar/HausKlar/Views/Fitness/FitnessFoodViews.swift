import PhotosUI
import SwiftUI
import UIKit
import Vision
import VisionKit

private enum FitnessAddFoodTab:String,CaseIterable,Identifiable {
    case all,recent,favourites,meals
    var id:String { rawValue }
    var title:String {
        switch self {
        case .all:"All"
        case .recent:"Recent"
        case .favourites:"Favourites"
        case .meals:"Meals"
        }
    }
}

struct FitnessNutritionAddFoodSheet: View {
    @ObservedObject var viewModel: FitnessNutritionViewModel
    let meal: FitnessMeal
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var selectedTab=FitnessAddFoodTab.all
    @State private var source: FitnessNutritionSourceChoice?
    @State private var template: FitnessMealTemplate?
    @State private var showingNewFood = false
    @State private var showingNewRecipe = false
    @State private var lookupResults: [FitnessFoodBarcodeLookup] = []
    @State private var quickLoggingFoodIds:Set<String>=[]
    @FocusState private var searchFocused:Bool

    private var activeFoods: [FitnessFood] {
        viewModel.foods.filter { $0.active && $0.currentVersion != nil }
    }
    private var recentFoods: [FitnessFood] {
        activeFoods.filter { $0.quickUse?.lastLoggedAtUtc != nil }.sorted {
            ($0.quickUse?.lastLoggedAtUtc ?? .distantPast) > ($1.quickUse?.lastLoggedAtUtc ?? .distantPast)
        }
    }
    private var favourites: [FitnessFood] { activeFoods.filter(\.isFavourite) }
    private var trimmedSearch:String {
        search.trimmingCharacters(in:.whitespacesAndNewlines)
    }
    private var matchingFoods: [FitnessFood] {
        guard !trimmedSearch.isEmpty else { return [] }
        return activeFoods.filter {
            [$0.name, $0.brand ?? "", $0.barcode ?? ""].contains { value in
                value.localizedCaseInsensitiveContains(trimmedSearch)
            }
        }
    }
    private var matchingRecipes: [FitnessRecipe] {
        guard !trimmedSearch.isEmpty else { return [] }
        return viewModel.recipes.filter {
            $0.active && $0.currentVersion != nil && $0.name.localizedCaseInsensitiveContains(trimmedSearch)
        }
    }
    private var sortedFoods:[FitnessFood] {
        activeFoods.sorted { left,right in
            let leftDate=left.quickUse?.lastLoggedAtUtc ?? .distantPast
            let rightDate=right.quickUse?.lastLoggedAtUtc ?? .distantPast
            if leftDate != rightDate { return leftDate > rightDate }
            if left.isFavourite != right.isFavourite { return left.isFavourite }
            return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
        }
    }
    private var visibleFoods:[FitnessFood] {
        if !trimmedSearch.isEmpty { return matchingFoods }
        switch selectedTab {
        case .all:return sortedFoods
        case .recent:return recentFoods
        case .favourites:return favourites
        case .meals:return []
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing:0) {
                searchHeader
                List {
                    if let undo=viewModel.quickLogUndo {
                        Section {
                            HStack(spacing:10) {
                                Image(systemName:"checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                    .accessibilityHidden(true)
                                VStack(alignment:.leading,spacing:2) {
                                    Text("Added \(undo.foodName)")
                                        .font(.subheadline.weight(.semibold))
                                    if let highlight=FitnessNutritionViewFormatting.addedHighlight(for:undo) {
                                        Text(highlight)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Button("Undo") { Task { await viewModel.undoQuickLog() } }
                                    .frame(minHeight:44)
                            }
                            .accessibilityElement(children:.contain)
                        }
                    }
                    if let error=viewModel.errorMessage {
                        Section {
                            Label(error,systemImage:"exclamationmark.circle.fill")
                                .foregroundStyle(.red)
                        }
                    }
                    if !trimmedSearch.isEmpty {
                        Section("Saved matches") {
                            ForEach(visibleFoods) { food in foodRow(food) }
                            ForEach(matchingRecipes) { recipe in recipeButton(recipe) }
                            if visibleFoods.isEmpty && matchingRecipes.isEmpty {
                                Text("No saved foods match “\(trimmedSearch)”.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Section("Full food database") {
                            Button {
                                Task { lookupResults=await viewModel.lookupFoods(named:trimmedSearch) }
                            } label: {
                                if viewModel.isLookingUpFood {
                                    HStack(spacing:8) {
                                        ProgressView()
                                        Text("Searching…")
                                    }
                                    .frame(maxWidth:.infinity,minHeight:44)
                                } else {
                                    Label("Search for “\(trimmedSearch)”",systemImage:"magnifyingglass")
                                        .frame(maxWidth:.infinity,minHeight:44,alignment:.leading)
                                }
                            }
                            .disabled(trimmedSearch.count < 2 || viewModel.isLookingUpFood)
                            ForEach(lookupResults, id: \.barcode) { result in
                                Button {
                                    Task {
                                        if let food = await viewModel.createLookupFood(result) {
                                            source = .init(source: "food:\(food.id)")
                                        }
                                    }
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(result.name)
                                        Text([result.brand, "Open Food Facts"].compactMap { $0 }.joined(separator: " · "))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    .frame(maxWidth:.infinity,minHeight:44,alignment:.leading)
                                }
                            }
                            if let error = viewModel.foodLookupError {
                                VStack(alignment:.leading,spacing:8) {
                                    Text(error).font(.footnote).foregroundStyle(.secondary)
                                    Button("Create this food manually") { showingNewFood=true }
                                        .frame(minHeight:44)
                                }
                            }
                        }
                    } else if selectedTab == .meals {
                        let quickTemplates=viewModel.quickTemplates(for:meal)
                        let activeRecipes=viewModel.recipes.filter { $0.active && $0.currentVersion != nil }
                        if quickTemplates.isEmpty && activeRecipes.isEmpty {
                            Section {
                                ContentUnavailableView(
                                    "No saved meals",
                                    systemImage:"fork.knife",
                                    description:Text("Create a recipe or save a meal you eat often.")
                                )
                            }
                        } else {
                            if !quickTemplates.isEmpty {
                                Section("Meal templates") {
                                    ForEach(quickTemplates) { item in
                                        Button { template=item } label: {
                                            Label(item.name,systemImage:"fork.knife.circle")
                                                .frame(maxWidth:.infinity,minHeight:44,alignment:.leading)
                                        }
                                    }
                                }
                            }
                            if !activeRecipes.isEmpty {
                                Section("Recipes") { ForEach(activeRecipes) { recipe in recipeButton(recipe) } }
                            }
                        }
                    } else {
                        Section(selectedTab.title) {
                            if visibleFoods.isEmpty {
                                ContentUnavailableView(
                                    selectedTab == .recent ? "No recent foods" : "No foods here yet",
                                    systemImage:selectedTab == .favourites ? "star" : "clock",
                                    description:Text("Search above to find any food, or create your own.")
                                )
                            } else {
                                ForEach(visibleFoods) { food in foodRow(food) }
                            }
                        }
                    }
                    Section("Create or scan") {
                        Button { showingNewFood=true } label: {
                            Label("Barcode, nutrition label or custom food",systemImage:"barcode.viewfinder")
                                .frame(maxWidth:.infinity,minHeight:44,alignment:.leading)
                        }
                        Button { showingNewRecipe=true } label: {
                            Label("Create a recipe",systemImage:"frying.pan")
                                .frame(maxWidth:.infinity,minHeight:44,alignment:.leading)
                        }
                    }
                }
                .listStyle(.plain)
                .scrollDismissesKeyboard(.interactively)
            }
            .onSubmit(of:.text) {
                guard trimmedSearch.count >= 2 else { return }
                Task { lookupResults=await viewModel.lookupFoods(named:trimmedSearch) }
            }
            .onChange(of: search) { _, _ in
                lookupResults = []
                viewModel.foodLookupError = nil
            }
            .navigationTitle(meal == .snack ? "Snacks" : meal.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .sheet(item: $source) { choice in
                FitnessFoodLogEditorSheet(
                    viewModel: viewModel, initialSource: choice.source, initialMeal: meal
                )
            }
            .sheet(item: $template) { item in
                FitnessLogTemplateSheet(viewModel: viewModel, template: item)
            }
            .sheet(isPresented: $showingNewFood) { FitnessFoodEditorSheet(viewModel: viewModel) }
            .sheet(isPresented: $showingNewRecipe) { FitnessRecipeEditorSheet(viewModel: viewModel) }
            .onAppear {
                DispatchQueue.main.async { searchFocused=true }
            }
        }
    }

    private var searchHeader:some View {
        VStack(spacing:10) {
            HStack(spacing:10) {
                Image(systemName:"magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Search for a food",text:$search)
                    .focused($searchFocused)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .accessibilityLabel("Search foods")
                if !search.isEmpty {
                    Button {
                        search=""
                        searchFocused=true
                    } label: {
                        Image(systemName:"xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .frame(width:40,height:40)
                    }
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.leading,14)
            .padding(.trailing,search.isEmpty ? 14 : 4)
            .frame(minHeight:48)
            .background(Color(.secondarySystemGroupedBackground),in:RoundedRectangle(cornerRadius:14,style:.continuous))

            ScrollView(.horizontal,showsIndicators:false) {
                HStack(spacing:8) {
                    ForEach(FitnessAddFoodTab.allCases) { tab in
                        Button(tab.title) { selectedTab=tab }
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(selectedTab == tab ? Color.white : Color.primary)
                            .padding(.horizontal,14)
                            .frame(minHeight:40)
                            .background(
                                selectedTab == tab ? Color.accentColor : Color(.secondarySystemGroupedBackground),
                                in:Capsule()
                            )
                            .accessibilityAddTraits(selectedTab == tab ? .isSelected : [])
                    }
                }
            }
        }
        .padding(.horizontal,16)
        .padding(.vertical,10)
        .background(.bar)
        .overlay(alignment:.bottom) { Divider() }
    }

    private func foodRow(_ food:FitnessFood) -> some View {
        HStack(spacing:8) {
            Button {
                source = .init(source:"food:\(food.id)")
            } label: {
                VStack(alignment:.leading,spacing:3) {
                    Text(food.name)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(foodSummary(food))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .frame(maxWidth:.infinity,minHeight:48,alignment:.leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Choose a different amount or serving")
            Button {
                quickAdd(food)
            } label: {
                Group {
                    if quickLoggingFoodIds.contains(food.id) {
                        ProgressView()
                    } else {
                        Image(systemName:"plus")
                            .font(.headline.weight(.semibold))
                    }
                }
                .frame(width:44,height:44)
                .background(Color.accentColor.opacity(0.12),in:Circle())
            }
            .buttonStyle(.plain)
            .disabled(quickLoggingFoodIds.contains(food.id))
            .accessibilityLabel("Quick add \(food.name) to \(meal.title)")
        }
    }

    private func recipeButton(_ recipe: FitnessRecipe) -> some View {
        Button {
            source = .init(source: "recipe:\(recipe.id)")
        } label: {
            HStack {
                Label(recipe.name, systemImage: "frying.pan")
                Spacer()
                Text(recipe.currentVersion?.nutrients.caloriesKcal.map { "\(Int($0.rounded())) kcal" } ?? "—")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .frame(maxWidth:.infinity,minHeight:44,alignment:.leading)
        }
    }

    private func quickAdd(_ food:FitnessFood) {
        guard !quickLoggingFoodIds.contains(food.id) else { return }
        quickLoggingFoodIds.insert(food.id)
        Task {
            defer { quickLoggingFoodIds.remove(food.id) }
            _=await viewModel.quickLog(food,meal:meal)
        }
    }

    private func foodSummary(_ food:FitnessFood) -> String {
        guard let version=food.currentVersion else { return food.brand ?? "Saved food" }
        var amount=food.quickUse?.usualAmount ?? food.quickUse?.lastAmount ?? version.referenceAmount
        var unit=food.quickUse?.usualUnit ?? food.quickUse?.lastUnit ?? version.referenceUnit
        let canonicalAmount:Double
        if unit == version.referenceUnit {
            canonicalAmount=amount
        } else if let serving=food.servings.first(where:{ $0.active && $0.unit == unit && $0.amount > 0 }) {
            canonicalAmount=amount / serving.amount * serving.canonicalAmount
        } else if let serving=food.servings.first(where:{ $0.active && $0.isDefault }) {
            amount=serving.amount
            unit=serving.unit
            canonicalAmount=serving.canonicalAmount
        } else {
            amount=version.referenceAmount
            unit=version.referenceUnit
            canonicalAmount=version.referenceAmount
        }
        let scale=version.referenceAmount > 0 ? canonicalAmount / version.referenceAmount : 1
        let calories=version.caloriesKcal.map { "\(Int(($0 * scale).rounded())) kcal" }
        return [calories,"\(amount.formatted()) \(unit)",food.brand]
            .compactMap { $0 }
            .joined(separator:" · ")
    }
}

private struct FitnessNutritionSourceChoice: Identifiable {
    let id = UUID()
    let source: String
}

struct FitnessFoodLibraryView: View {
    @ObservedObject var viewModel: FitnessNutritionViewModel
    let log: (String) -> Void
    @State private var selectedFood: FitnessFood?
    @State private var quickLoggingFoodIds: Set<String> = []

    var body: some View {
        List {
            if viewModel.quickLogUndo != nil {
                Section {
                    HStack {
                        Label(viewModel.statusMessage ?? "Food added", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Spacer()
                        Button("Undo") { Task { await viewModel.undoQuickLog() } }
                    }
                }
            }
            if !viewModel.labels.isEmpty {
                Section("Nutrition labels on this device") {
                    ForEach(viewModel.labels) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Label(labelStatus(item), systemImage: item.state == .error ? "exclamationmark.triangle" : "lock.example_9ab66176")
                            Text(item.originalFilename).font(.caption).foregroundStyle(.secondary)
                            HStack {
                                if item.state == .error {
                                    Button("Retry") { Task { await viewModel.retryLabel(item) } }
                                }
                                Button("Cancel", role: .destructive) { Task { await viewModel.cancelLabel(item) } }
                            }.buttonStyle(.borderless)
                        }
                    }
                }
            }
            Section {
                Toggle("Include archived", isOn: $viewModel.includeArchived)
                    .onChange(of: viewModel.includeArchived) { _, _ in Task { await viewModel.searchFoods() } }
                if viewModel.foods.isEmpty {
                    ContentUnavailableView.search(text: viewModel.search)
                }
                ForEach(viewModel.foods) { food in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(food.name).foregroundStyle(.primary)
                                if food.householdShared { Image(systemName: "person.example_f47e224f").font(.caption).foregroundStyle(.secondary) }
                                if food.isFavourite { Image(systemName: "star.fill").font(.caption).foregroundStyle(.yellow) }
                            }
                            Text(
                                [food.brand, food.currentVersion.map { "\($0.referenceAmount.formatted()) \($0.referenceUnit) base" }]
                                    .compactMap { $0 }.joined(separator: " · ")
                            )
                            .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        // One diary entry per tap: taps landing while the
                        // first is saving are the usual cause of a food
                        // appearing twice.
                        Button("Add") {
                            guard !quickLoggingFoodIds.contains(food.id) else { return }
                            quickLoggingFoodIds.insert(food.id)
                            Task {
                                defer { quickLoggingFoodIds.remove(food.id) }
                                _ = await viewModel.quickLog(food)
                            }
                        }
                        .disabled(quickLoggingFoodIds.contains(food.id))
                        .buttonStyle(.borderedProminent).controlSize(.small)
                        Button {
                            selectedFood = food
                        } label: {
                            Image(systemName: "info.circle")
                        }
                        .buttonStyle(.borderless).accessibilityLabel("Details for \(food.name)")
                    }
                }
            }
        }
        .searchable(text: $viewModel.search, prompt: "Search name, brand or barcode")
        .onSubmit(of: .search) { Task { await viewModel.searchFoods() } }
        .refreshable { await viewModel.refresh() }
        .sheet(item: $selectedFood) { food in
            FitnessFoodDetailSheet(viewModel: viewModel, foodId: food.id) { log("food:\(food.id)") }
        }
    }

    private func labelStatus(_ item: FitnessPendingNutritionLabel) -> String {
        if item.uploadAcknowledged && !item.referenceAcknowledged { return "Uploaded privately · finishing food details" }
        switch item.state {
        case .pendingUpload: return "Waiting to upload privately"
        case .uploading: return "Uploading privately"
        case .uploadedWaitingReference: return "Uploaded · waiting to finish saving"
        case .acknowledged: return "Saved"
        case .error: return item.lastError ?? "Upload needs attention"
        }
    }
}

private struct FitnessFoodDetailSheet: View {
    @ObservedObject var viewModel: FitnessNutritionViewModel
    let foodId: String
    let log: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var showVersion = false
    @State private var showServing = false
    @State private var showMerge = false
    @State private var mergeTarget = ""
    @State private var mergePreview: FitnessFoodMergePreview?
    @State private var identityEdit = false
    @State private var name = ""
    @State private var brand = ""
    @State private var notes = ""

    private var food: FitnessFood? { viewModel.foods.first { $0.id == foodId } }

    var body: some View {
        NavigationStack {
            Form {
                if let food {
                    let actions = FitnessNutritionActionAvailability.food(food)
                    Section("Food details") {
                        if !food.editable {
                            LabeledContent("Name", value: food.name)
                            if let brand = food.brand { LabeledContent("Brand", value: brand) }
                            Label("Shared food", systemImage: "person.example_f47e224f")
                            Text(
                                "You can log this food or copy it. Only its owner can edit its details and serving sizes, mark it as a favourite, archive it, or merge it."
                            )
                            .font(.footnote).foregroundStyle(.secondary)
                            Button("Copy to my foods", systemImage: "doc.on.doc") {
                                Task { if await viewModel.copyFoodToMine(food) { dismiss() } }
                            }
                        } else if identityEdit {
                            TextField("Name", text: $name)
                            TextField("Brand", text: $brand)
                            TextField("Notes", text: $notes, axis: .vertical)
                            Button("Save food details") {
                                var updated = food
                                updated.name = name
                                updated.brand = FitnessNutritionViewFormatting.emptyNil(brand)
                                updated.notes = FitnessNutritionViewFormatting.emptyNil(notes)
                                Task { if await viewModel.saveFood(updated) { identityEdit = false } }
                            }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        } else {
                            LabeledContent("Name", value: food.name)
                            if let brand = food.brand { LabeledContent("Brand", value: brand) }
                            if let category = food.categoryKey { LabeledContent("Category", value: category) }
                            if let barcode = food.barcode { LabeledContent("Barcode", value: barcode) }
                            Toggle(
                                "Share food with household",
                                isOn: Binding(
                                    get: { food.householdShared },
                                    set: { value in
                                        var copy = food
                                        copy.householdShared = value
                                        Task { _ = await viewModel.saveFood(copy) }
                                    }
                                ))
                            Text("Food details are shared. Each person’s diary remains private.")
                                .font(.footnote).foregroundStyle(.secondary)
                            Button("Edit food details") {
                                name = food.name
                                brand = food.brand ?? ""
                                notes = food.notes ?? ""
                                identityEdit = true
                            }
                        }
                    }
                    Section("Saved nutrition history") {
                        ForEach(food.versions.sorted(by: { ($0.versionNumber ?? 0) > ($1.versionNumber ?? 0) })) { version in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("Nutrition details \(version.versionNumber ?? 1)").font(.headline)
                                    if version.id == food.versionId { Text("Current").font(.caption).foregroundStyle(.green) }
                                }
                                Text(
                                    "\(version.referenceAmount.formatted()) \(version.referenceUnit) · \(version.caloriesKcal.map { "\($0.formatted()) kcal" } ?? "energy unknown")"
                                )
                                Text(FitnessNutritionViewFormatting.nutrientLine(version.nutrients)).font(.caption).foregroundStyle(
                                    .secondary)
                                if version.labelAssetId != nil {
                                    Label("Private label attached", systemImage: "lock.example_9ab66176").font(.caption)
                                }
                            }
                        }
                        if actions.canAddVersion {
                            Button("Add updated nutrition details", systemImage: "plus") { showVersion = true }
                        }
                    }
                    Section("Serving sizes") {
                        ForEach(food.servings.filter(\.active)) { serving in
                            LabeledContent(serving.name) {
                                Text("\(serving.amount.formatted()) \(serving.unit) serving")
                            }
                        }
                        if food.editable { Button("Add serving alias", systemImage: "plus") { showServing = true } }
                    }
                    Section {
                        if actions.canLog {
                            Button("Log this food", systemImage: "apple.logo") {
                                dismiss()
                                log()
                            }
                        }
                        if actions.canFavourite {
                            Button(food.isFavourite ? "Remove favourite" : "Add favourite", systemImage: "star") {
                                var copy = food
                                copy.isFavourite.toggle()
                                Task { _ = await viewModel.saveFood(copy) }
                            }
                        }
                        if actions.canArchive {
                            Button(food.active ? "Archive food" : "Restore food", systemImage: "archivebox") {
                                var copy = food
                                copy.active.toggle()
                                copy.isArchived = !copy.active
                                Task { if await viewModel.saveFood(copy) { dismiss() } }
                            }
                        }
                        if actions.canMerge { Button("Merge duplicate…", systemImage: "arrow.triangle.merge") { showMerge = true } }
                    }
                }
            }
            .navigationTitle(food?.name ?? "Food")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $showVersion) {
                if let food { FitnessFoodEditorSheet(viewModel: viewModel, versionFor: food) }
            }
            .sheet(isPresented: $showServing) {
                if let food { FitnessServingEditorSheet(viewModel: viewModel, food: food) }
            }
            .sheet(isPresented: $showMerge) {
                if let food {
                    NavigationStack {
                        Form {
                            Picker("Merge into", selection: $mergeTarget) {
                                Text("Choose food to keep").tag("")
                                ForEach(viewModel.foods.filter { $0.id != food.id && $0.active }) {
                                    Text($0.name).tag($0.id)
                                }
                            }
                            if let preview = mergePreview {
                                LabeledContent("Nutrition records moved", value: "\(preview.versions)")
                                LabeledContent("Servings checked", value: "\(preview.servings)")
                                ForEach(preview.warnings ?? [], id: \.self) { Text($0).foregroundStyle(.orange) }
                                Button("Confirm merge", role: .destructive) {
                                    Task {
                                        if await viewModel.merge(sourceId: food.id, targetId: mergeTarget) {
                                            showMerge = false
                                            dismiss()
                                        }
                                    }
                                }
                            } else {
                                Button("Preview merge") {
                                    Task {
                                        do {
                                            mergePreview = try await viewModel.mergePreview(
                                                sourceId: food.id, targetId: mergeTarget
                                            )
                                        } catch is CancellationError {
                                            return
                                        } catch {
                                            viewModel.errorMessage = "The merge preview could not be loaded. Try again."
                                        }
                                    }
                                }.disabled(mergeTarget.isEmpty)
                            }
                        }
                        .navigationTitle("Merge duplicate")
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showMerge = false } } }
                    }
                }
            }
        }
    }
}

struct FitnessFoodEditorSheet: View {
    @ObservedObject var viewModel: FitnessNutritionViewModel
    var versionFor: FitnessFood? = nil
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState
    @StateObject private var photoDraft = FitnessNutritionPhotoDraftOwner()
    @State private var name = ""
    @State private var brand = ""
    @State private var category = ""
    @State private var barcode = ""
    @State private var notes = ""
    @State private var householdShared = false
    @State private var favourite = false
    @State private var referenceAmount = "100"
    @State private var referenceUnit = "g"
    @State private var calories = ""
    @State private var sourceEnergy = ""
    @State private var sourceEnergyUnit = "kj"
    @State private var protein = ""
    @State private var carbohydrate = ""
    @State private var sugars = ""
    @State private var fat = ""
    @State private var saturatedFat = ""
    @State private var fibre = ""
    @State private var salt = ""
    @State private var sodium = ""
    @State private var sourceType = "manual"
    @State private var sourceNote = ""
    @State private var confidence = "measured"
    @State private var pickedItem: PhotosPickerItem?
    @State private var labelLoadTask: Task<Void, Never>?
    @State private var labelError: String?
    @State private var showingBarcodeScanner = false
    @State private var barcodeWarnings: [String] = []

    private var activeAccountKey: String? {
        appState.currentUser.map { "\($0.familyId ?? ""):\($0.id)" }
    }

    var body: some View {
        let hasLabelDraft = photoDraft.labelDraft != nil
        NavigationStack {
            Form {
                if versionFor == nil {
                    Section("Food details") {
                        TextField("Name", text: $name)
                        TextField("Brand (optional)", text: $brand)
                        TextField("Category (optional)", text: $category)
                        TextField("Barcode (optional)", text: $barcode)
                            .keyboardType(.numberPad)
                        ViewThatFits(in: .horizontal) {
                            HStack { barcodeButtons }
                            VStack(alignment: .leading) { barcodeButtons }
                        }
                        if viewModel.isLookingUpBarcode {
                            HStack {
                                ProgressView()
                                Text("Looking up product…")
                            }
                        }
                        if let error = viewModel.barcodeLookupError {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption).foregroundStyle(.orange)
                        }
                        TextField("Notes (optional)", text: $notes, axis: .vertical)
                        Toggle("Share food with household", isOn: $householdShared)
                        Toggle("Favourite", isOn: $favourite)
                    }
                }
                Section("Serving details") {
                    TextField("Amount", text: $referenceAmount).keyboardType(.decimalPad)
                    Picker("Unit", selection: $referenceUnit) {
                        ForEach(["g", "ml", "item", "serving", "custom"], id: \.self) { Text($0).tag($0) }
                    }
                }
                Section("Energy") {
                    TextField("Calories (kcal)", text: $calories).keyboardType(.decimalPad)
                }
                Section("Nutrients per serving") {
                    nutrientField("Protein (g)", $protein)
                    nutrientField("Carbohydrate (g)", $carbohydrate)
                    nutrientField("Sugars (g)", $sugars)
                    nutrientField("Fat (g)", $fat)
                    nutrientField("Saturated fat (g)", $saturatedFat)
                    nutrientField("Fibre (g)", $fibre)
                    nutrientField("Salt (g)", $salt)
                    nutrientField("Sodium (mg)", $sodium)
                }
                Section("Nutrition label") {
                    PhotosPicker(selection: $pickedItem, matching: .images) {
                        Label(
                            !hasLabelDraft
                                ? "Choose label photo" : "Label photo ready",
                            systemImage: "camera"
                        )
                    }
                    if let labelError {
                        Text(labelError).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if let error = viewModel.errorMessage { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle(versionFor == nil ? "New food" : "Update nutrition details")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        cleanupLabel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }.disabled(!valid)
                }
            }
            .onChange(of: pickedItem) { _, item in
                guard let item else { return }
                loadLabel(item)
            }
            .onChange(of: activeAccountKey) { oldIdentity, newIdentity in
                guard oldIdentity != newIdentity else { return }
                cleanupLabel()
                dismiss()
            }
            .onDisappear { cleanupLabel() }
            .sheet(isPresented: $showingBarcodeScanner) {
                NavigationStack {
                    FitnessBarcodeScannerView(
                        scanned: { value in
                            barcode = value
                            showingBarcodeScanner = false
                            Task { await lookupBarcode() }
                        },
                        failed: {
                            viewModel.barcodeLookupError = "The barcode scanner could not start. Enter the code instead."
                            showingBarcodeScanner = false
                        }
                    )
                    .ignoresSafeArea(edges: .bottom)
                    .navigationTitle("Scan barcode")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showingBarcodeScanner = false } } }
                }
            }
        }
    }

    @ViewBuilder private var barcodeButtons: some View {
        Button("Scan barcode", systemImage: "barcode.viewfinder") { showingBarcodeScanner = true }
            .disabled(!DataScannerViewController.isSupported || !DataScannerViewController.isAvailable)
        Button("Look up code", systemImage: "magnifyingglass") { Task { await lookupBarcode() } }
            .disabled(viewModel.isLookingUpBarcode || !(8...14).contains(barcode.filter(\.isNumber).count))
    }

    @ViewBuilder private func nutrientField(_ title: String, _ value: Binding<String>) -> some View {
        TextField(title, text: value).keyboardType(.decimalPad)
    }

    private var valid: Bool {
        (versionFor != nil || !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            && (Double(referenceAmount).map { $0.isFinite && $0 > 0 } ?? false)
    }

    private func save() async {
        let version = FitnessFoodVersionDraft(
            referenceAmount: Double(referenceAmount) ?? 0, referenceUnit: referenceUnit,
            caloriesKcal: FitnessNutritionViewFormatting.number(calories),
            sourceEnergyValue: FitnessNutritionViewFormatting.number(sourceEnergy),
            sourceEnergyUnit: sourceEnergy.isEmpty ? nil : sourceEnergyUnit,
            proteinG: FitnessNutritionViewFormatting.number(protein), carbohydrateG: FitnessNutritionViewFormatting.number(carbohydrate),
            sugarsG: FitnessNutritionViewFormatting.number(sugars),
            fatG: FitnessNutritionViewFormatting.number(fat), saturatedFatG: FitnessNutritionViewFormatting.number(saturatedFat),
            fibreG: FitnessNutritionViewFormatting.number(fibre), saltG: FitnessNutritionViewFormatting.number(salt),
            sodiumMg: FitnessNutritionViewFormatting.number(sodium), sourceType: sourceType,
            sourceNote: FitnessNutritionViewFormatting.emptyNil(sourceNote), confidence: confidence
        )
        labelLoadTask?.cancel()
        labelLoadTask = nil
        let label = photoDraft.takeLabelDraft()
        let succeeded: Bool
        if let food = versionFor {
            succeeded = await viewModel.addVersion(foodId: food.id, draft: version, label: label)
        } else {
            succeeded = await viewModel.createFood(
                FitnessFoodDraft(
                    name: name, brand: FitnessNutritionViewFormatting.emptyNil(brand),
                    categoryKey: FitnessNutritionViewFormatting.emptyNil(category),
                    barcode: FitnessNutritionViewFormatting.emptyNil(barcode),
                    notes: FitnessNutritionViewFormatting.emptyNil(notes), householdShared: householdShared, favourite: favourite,
                    version: version
                ), label: label)
        }
        pickedItem = nil
        if succeeded { dismiss() }
    }

    private func loadLabel(_ item: PhotosPickerItem) {
        labelLoadTask?.cancel()
        labelError = nil
        let generation = photoDraft.beginReplacement()
        guard let expectedIdentity = FitnessDatabase.shared.activeIdentity else {
            labelError = FitnessNutritionRepositoryError.inactiveProfile.localizedDescription
            return
        }
        let declaredTypes = item.supportedContentTypes.map(\.identifier)
        labelLoadTask = Task {
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
                    let prepared = try PhotoUploadPrep.prepareStagedFile(
                        ownedFile,
                        declaredTypeIdentifiers: declaredTypes,
                        childId: "fitness-nutrition-label"
                    )
                    guard prepared.byteCount <= FitnessNutritionLabelDraft.maximumByteCount,
                        ["image/jpeg", "image/png", "image/heic", "image/heif"]
                            .contains(prepared.mediaType)
                    else {
                        throw FitnessNutritionRepositoryError.invalidLabel
                    }
                    let fileExtension: String
                    switch prepared.mediaType {
                    case "image/png": fileExtension = "png"
                    case "image/heic": fileExtension = "heic"
                    case "image/heif": fileExtension = "heif"
                    default: fileExtension = "jpg"
                    }
                    let draft = FitnessNutritionLabelDraft(
                        stagedFile: ownedFile,
                        originalFilename: "nutrition-label.\(fileExtension)",
                        mediaType: prepared.mediaType,
                        byteCount: prepared.byteCount,
                        ownerIdentity: expectedIdentity
                    )
                    let recognisedValues: [String: Double]?
                    do {
                        recognisedValues = try Self.recogniseNutritionLabel(
                            at: ownedFile.fileURL
                        )
                    } catch {
                        recognisedValues = nil
                    }
                    return (draft, recognisedValues)
                }
                let (draft, recognisedValues) = try await withTaskCancellationHandler {
                    try await preparation.value
                } onCancel: {
                    preparation.cancel()
                }
                try Task.checkCancellation()
                guard FitnessDatabase.shared.activeIdentity == expectedIdentity else {
                    throw FitnessNutritionRepositoryError.inactiveProfile
                }
                let installed = photoDraft.installLabel(draft, generation: generation)
                stagedFile = nil
                guard installed else { return }
                if let values = recognisedValues {
                    if calories.isEmpty, let value = values["calories"] { calories = String(value) }
                    if protein.isEmpty, let value = values["protein"] { protein = String(value) }
                    if carbohydrate.isEmpty, let value = values["carbohydrate"] { carbohydrate = String(value) }
                    if fat.isEmpty, let value = values["fat"] { fat = String(value) }
                    if !values.isEmpty {
                        sourceType = "label_scan"
                        confidence = "labelled"
                        if sourceNote.isEmpty {
                            sourceNote = "Prefilled by on-device label recognition; review against the attached photo."
                        }
                    }
                    labelError = nil
                } else {
                    labelError = "Photo attached for review. On-device recognition could not prefill it."
                }
            } catch is CancellationError {
                if let stagedFile { PhotoUploadPrep.removeStagedFile(stagedFile) }
            } catch {
                if let stagedFile { PhotoUploadPrep.removeStagedFile(stagedFile) }
                guard !Task.isCancelled else { return }
                labelError = error.localizedDescription
            }
        }
    }

    private func lookupBarcode() async {
        guard let result = await viewModel.lookupBarcode(barcode) else { return }
        let draft = result.reviewDraft
        let version = draft.version
        barcode = draft.barcode ?? ""
        name = draft.name
        brand = draft.brand ?? ""
        referenceAmount = String(version.referenceAmount)
        referenceUnit = version.referenceUnit
        calories = version.caloriesKcal.map { String($0) } ?? ""
        protein = version.proteinG.map { String($0) } ?? ""
        carbohydrate = version.carbohydrateG.map { String($0) } ?? ""
        sugars = version.sugarsG.map { String($0) } ?? ""
        fat = version.fatG.map { String($0) } ?? ""
        saturatedFat = version.saturatedFatG.map { String($0) } ?? ""
        fibre = version.fibreG.map { String($0) } ?? ""
        salt = version.saltG.map { String($0) } ?? ""
        sodium = version.sodiumMg.map { String($0) } ?? ""
        sourceType = version.sourceType
        sourceNote = version.sourceNote ?? ""
        confidence = version.confidence
        barcodeWarnings = result.warnings
        if let serving = result.serving {
            barcodeWarnings.append(
                "Label serving: \(serving.amount.formatted()) \(serving.unit) (\(serving.name)). Save a serving alias after reviewing this food if useful."
            )
        }
    }

    private func cleanupLabel() {
        labelLoadTask?.cancel()
        labelLoadTask = nil
        pickedItem = nil
        photoDraft.discard()
    }

    nonisolated private static func recogniseNutritionLabel(at url: URL) throws -> [String: Double] {
        try Task.checkCancellation()
        guard
            let image = PhotoUploadPrep.displayImage(
                at: url, maxPixelSize: 2_400
            )?.cgImage
        else { throw FitnessNutritionRepositoryError.invalidLabel }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: image)
        try handler.perform([request])
        try Task.checkCancellation()
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string.lowercased() }
        var values: [String: Double] = [:]
        func first(_ patterns: [String]) -> Double? {
            for line in lines where patterns.contains(where: { line.contains($0) }) {
                let expression = "([0-9]+(?:[\\.,][0-9]+)?)"
                guard let range = line.range(of: expression, options: .regularExpression) else { continue }
                return Double(line[range].replacingOccurrences(of: ",", with: "."))
            }
            return nil
        }
        for line in lines where line.contains("kcal") {
            let expression = "([0-9]+(?:[\\.,][0-9]+)?)\\s*kcal"
            if let range = line.range(of: expression, options: .regularExpression),
                let numberRange = line[range].range(
                    of: "[0-9]+(?:[\\.,][0-9]+)?", options: .regularExpression
                )
            {
                values["calories"] = Double(
                    line[numberRange].replacingOccurrences(of: ",", with: ".")
                )
                break
            }
        }
        values["protein"] = first(["protein"])
        values["carbohydrate"] = first(["carbohydrate", "carbs"])
        values["fat"] = first(["fat"])
        return values.compactMapValues { $0 }
    }
}

private struct FitnessBarcodeScannerView: UIViewControllerRepresentable {
    let scanned: (String) -> Void
    let failed: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(scanned: scanned) }
    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.ean8, .ean13, .upce, .code128])],
            qualityLevel: .balanced, recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false, isPinchToZoomEnabled: true,
            isGuidanceEnabled: true, isHighlightingEnabled: true
        )
        controller.delegate = context.coordinator
        do {
            try controller.startScanning()
        } catch {
            Task { @MainActor in failed() }
        }
        return controller
    }
    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {}
    static func dismantleUIViewController(_ uiViewController: DataScannerViewController, coordinator: Coordinator) {
        uiViewController.stopScanning()
    }
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let scanned: (String) -> Void
        init(scanned: @escaping (String) -> Void) { self.scanned = scanned }
        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            for item in addedItems {
                if case .barcode(let code) = item, let value = code.payloadStringValue {
                    scanned(value)
                    dataScanner.stopScanning()
                    return
                }
            }
        }
    }
}

private struct FitnessServingEditorSheet: View {
    @ObservedObject var viewModel: FitnessNutritionViewModel
    let food: FitnessFood
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var amount = "1"
    @State private var unit = "slice"
    @State private var canonicalAmount = ""
    @State private var canonicalUnit = "g"
    @State private var quality = FitnessNutritionMeasurementQuality.standardServing
    @State private var isDefault = false

    var body: some View {
        NavigationStack {
            Form {
                TextField("Serving name", text: $name)
                TextField("Serving amount", text: $amount).keyboardType(.decimalPad)
                TextField("Serving unit", text: $unit)
                TextField("Base amount", text: $canonicalAmount).keyboardType(.decimalPad)
                TextField("Base unit", text: $canonicalUnit)
                Picker("Quality", selection: $quality) {
                    ForEach(FitnessNutritionMeasurementQuality.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Default serving", isOn: $isDefault)
            }
            .navigationTitle("Serving alias")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            if await viewModel.addServing(
                                foodId: food.id,
                                draft: FitnessFoodServingDraft(
                                    name: name, amount: Double(amount) ?? 0, unit: unit,
                                    canonicalAmount: Double(canonicalAmount) ?? 0, canonicalUnit: canonicalUnit,
                                    measurementQuality: quality, isDefault: isDefault
                                ))
                            {
                                dismiss()
                            }
                        }
                    }.disabled(name.isEmpty || Double(amount) == nil || Double(canonicalAmount) == nil)
                }
            }
        }
    }
}

struct FitnessFoodLogEditorSheet: View {
    @ObservedObject var viewModel: FitnessNutritionViewModel
    var editing: FitnessFoodLogEntry? = nil
    private let initialAmount: Double?
    private let initialUnit: String?
    @Environment(\.dismiss) private var dismiss
    @State private var source = ""
    @State private var servingId = ""
    @State private var amount = ""
    @State private var loggedAt = Date()
    @State private var meal = FitnessMeal.snack
    @State private var quality = FitnessNutritionMeasurementQuality.estimated
    @State private var notes = ""
    @State private var didSeed = false
    @State private var isSaving = false
    // One logging intent, one diary entry: the id is minted with the sheet, so
    // a second tap while the first save runs updates that entry rather than
    // adding another copy of the same food.
    @State private var draftEntryId = UUID().uuidString

    init(
        viewModel: FitnessNutritionViewModel,
        initialSource: String? = nil,
        initialMeal: FitnessMeal? = nil,
        initialAmount: Double? = nil,
        initialUnit: String? = nil,
        editing: FitnessFoodLogEntry? = nil
    ) {
        self.viewModel = viewModel
        self.editing = editing
        self.initialAmount = initialAmount
        self.initialUnit = initialUnit
        _source = State(initialValue: initialSource ?? "")
        _meal = State(initialValue: initialMeal ?? Self.defaultMeal())
    }

    private var selectedFood: FitnessFood? {
        guard source.hasPrefix("food:") else { return nil }
        return viewModel.foods.first { $0.id == String(source.dropFirst(5)) }
    }
    private var selectedRecipe: FitnessRecipe? {
        guard source.hasPrefix("recipe:") else { return nil }
        return viewModel.recipes.first { $0.id == String(source.dropFirst(7)) }
    }
    private var selectedServing: FitnessFoodServing? {
        selectedFood?.servings.first { $0.id == servingId }
    }
    private var foodVersion: FitnessFoodVersion? {
        if let editing, let id = editing.foodVersionId {
            return selectedFood?.versions.first { $0.id == id }
        }
        return selectedFood?.currentVersion
    }
    private var recipeVersion: FitnessRecipeVersion? {
        if let editing, let id = editing.recipeVersionId {
            return selectedRecipe?.versions.first { $0.id == id }
        }
        return selectedRecipe?.currentVersion
    }

    private var sourceName: String {
        selectedFood?.name ?? selectedRecipe?.name ?? editing?.foodName ?? "Food"
    }

    private var quickAmounts: [(label: String, amount: Double, unit: String)] {
        guard let quick = selectedFood?.quickUse else { return [] }
        var values: [(String, Double, String)] = []
        if let amount = quick.usualAmount, amount > 0,
           let unit = quick.usualUnit, canSelect(unit: unit) {
            values.append(("Usual", amount, unit))
        }
        if let amount = quick.lastAmount, amount > 0,
           let unit = quick.lastUnit, canSelect(unit: unit),
           !values.contains(where: { $0.1 == amount && $0.2 == unit }) {
            values.append(("Last", amount, unit))
        }
        return values
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Food", value: sourceName)
                }
                DatePicker("When", selection: $loggedAt)
                Picker("Meal", selection: $meal) {
                    ForEach(FitnessMeal.allCases) { Text($0.title).tag($0) }
                }
                if let food = selectedFood, !food.servings.filter(\.active).isEmpty {
                    Picker("Unit", selection: $servingId) {
                        Text(foodVersion?.referenceUnit ?? "Base unit").tag("")
                        ForEach(food.servings.filter(\.active)) {
                            Text($0.name == $0.unit ? $0.unit : "\($0.name) (\($0.unit))")
                                .tag($0.id)
                        }
                    }.onChange(of: servingId) { _, _ in seedServing() }
                }
                HStack {
                    TextField("Amount", text: $amount).keyboardType(.decimalPad)
                    Text(displayUnit).foregroundStyle(.secondary)
                }
                if !quickAmounts.isEmpty {
                    Section("Suggested amounts") {
                        ForEach(Array(quickAmounts.enumerated()), id: \.offset) { _, suggestion in
                            Button("\(suggestion.label) · \(suggestion.amount.formatted()) \(suggestion.unit)") {
                                applyQuickAmount(suggestion.amount, unit: suggestion.unit)
                            }
                        }
                    }
                }
                TextField("Notes (optional)", text: $notes, axis: .vertical)
                if let error = viewModel.errorMessage { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle(editing == nil ? "Log food" : "Edit diary entry")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(editing == nil ? "Add" : "Save") { Task { await save() } }
                        .disabled(!valid || isSaving)
                }
            }
            .onAppear { seedEditingIfNeeded() }
        }
    }

    private var displayUnit: String {
        selectedServing?.unit ?? foodVersion?.referenceUnit
            ?? (recipeVersion?.finishedWeightG == nil ? "serving" : "g")
    }
    private var valid: Bool {
        !source.isEmpty && (Double(amount).map { $0.isFinite && $0 > 0 } ?? false)
            && (foodVersion != nil || recipeVersion != nil)
    }

    private func seedAmount() {
        servingId = ""
        if let food = selectedFood, let version = food.currentVersion {
            amount = String(defaultBaseAmount(for: food, version: version))
            quality = .estimated
        } else if let version = selectedRecipe?.currentVersion {
            amount = String(version.finishedWeightG == nil ? 1 : min(version.finishedWeightG ?? 100, 100))
            quality = .estimated
        }
    }
    private func seedServing() {
        guard let serving = selectedServing else { return }
        amount = String(serving.amount)
        quality = serving.measurementQuality
    }

    private func canSelect(unit: String) -> Bool {
        unit == foodVersion?.referenceUnit
            || selectedFood?.servings.contains(where: { $0.active && $0.unit == unit }) == true
    }

    private func applyQuickAmount(_ value: Double, unit: String) {
        if unit == foodVersion?.referenceUnit {
            servingId = ""
            amount = String(value)
            quality = .estimated
            return
        }
        guard let serving = selectedFood?.servings.first(where: { $0.active && $0.unit == unit }) else {
            return
        }
        servingId = serving.id
        amount = String(value)
        quality = serving.measurementQuality
    }

    private func defaultBaseAmount(for food: FitnessFood, version: FitnessFoodVersion) -> Double {
        let candidates = [
            (food.quickUse?.usualAmount, food.quickUse?.usualUnit),
            (food.quickUse?.lastAmount, food.quickUse?.lastUnit),
        ]
        for (candidateAmount, candidateUnit) in candidates {
            guard let candidateAmount, candidateAmount > 0, let candidateUnit else { continue }
            if candidateUnit == version.referenceUnit { return candidateAmount }
            if let serving = food.servings.first(where: {
                $0.active && $0.unit == candidateUnit && $0.amount > 0
                    && $0.canonicalUnit == version.referenceUnit
            }) {
                return candidateAmount / serving.amount * serving.canonicalAmount
            }
        }
        return version.referenceAmount
    }
    private func seedEditingIfNeeded() {
        guard !didSeed else { return }
        didSeed = true
        guard let editing else {
            if !source.isEmpty, !seedRecommendedAmount() { seedAmount() }
            return
        }
        if let versionId = editing.foodVersionId,
            let food = viewModel.foods.first(where: { $0.versions.contains(where: { $0.id == versionId }) })
        {
            source = "food:\(food.id)"
        } else if let versionId = editing.recipeVersionId,
            let recipe = viewModel.recipes.first(where: { $0.versions.contains(where: { $0.id == versionId }) })
        {
            source = "recipe:\(recipe.id)"
        }
        amount = String(editing.enteredAmount)
        loggedAt = editing.loggedAt
        meal = editing.meal
        quality = editing.measurementQuality
        notes = editing.notes ?? ""
    }
    private func seedRecommendedAmount() -> Bool {
        guard let initialAmount, initialAmount > 0, let initialUnit,
            let food = selectedFood, let version = food.currentVersion
        else { return false }
        if version.referenceUnit == initialUnit {
            servingId = ""
            amount = String(initialAmount)
            quality = .estimated
            return true
        }
        if let serving = food.servings.first(where: { $0.active && $0.unit == initialUnit }) {
            servingId = serving.id
            amount = String(initialAmount)
            quality = serving.measurementQuality
            return true
        }
        return false
    }
    private func save() async {
        guard !isSaving,let amountValue = Double(amount) else { return }
        isSaving = true
        defer { isSaving = false }
        let canonicalAmount: Double
        let canonicalUnit: String
        if let serving = selectedServing {
            canonicalAmount = amountValue / serving.amount * serving.canonicalAmount
            canonicalUnit = serving.canonicalUnit
        } else if let version = foodVersion {
            canonicalAmount = amountValue
            canonicalUnit = version.referenceUnit
        } else if let version = recipeVersion {
            canonicalAmount = amountValue
            canonicalUnit = version.finishedWeightG == nil ? "serving" : "g"
        } else {
            return
        }
        let label = selectedFood?.name ?? selectedRecipe?.name ?? editing?.foodName ?? "Saved item"
        let succeeded = await viewModel.saveLog(
            FitnessFoodLogDraft(
                foodVersionId: foodVersion?.id, recipeVersionId: recipeVersion?.id, label: label,
                loggedAt: loggedAt, localTimezone: TimeZone.current.identifier, meal: meal,
                enteredAmount: amountValue, enteredUnit: displayUnit, canonicalAmount: canonicalAmount,
                canonicalUnit: canonicalUnit, measurementQuality: quality, notes: FitnessNutritionViewFormatting.emptyNil(notes),
                contextTags: []
            ), editing: editing, entryId: draftEntryId)
        if succeeded { dismiss() }
    }

    private static func defaultMeal(at date: Date = Date()) -> FitnessMeal {
        switch Calendar.current.component(.hour, from: date) {
        case 4..<11: .breakfast
        case 11..<15: .lunch
        case 17..<22: .dinner
        default: .snack
        }
    }
}
