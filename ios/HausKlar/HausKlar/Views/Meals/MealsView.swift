import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct MealsView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var libraryVM = MealLibraryViewModel()
    @StateObject private var planVM = MealPlanViewModel()
    @StateObject private var shoppingVM = ShoppingListViewModel()
    @StateObject private var stockVM = StockViewModel()

    @State private var selectedTab: Int
    @State private var showingClearCompletedConfirmation = false
    @State private var showingQuickShopping = false
    @State private var quickShoppingName = ""
    @State private var recipePhoto: PhotosPickerItem?
    @State private var recipePhotoTask: Task<Void, Never>?
    @State private var recipePhotoGeneration: UUID?
    @State private var isReadingRecipePhoto = false
    @State private var showingTescoHistoryFileImporter = false

    init(initialTab: Int = 0) {
        _selectedTab = State(initialValue: initialTab == 0 ? 4 : min(max(initialTab, 0), 4))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Section", selection: $selectedTab) {
                    Text("Tonight").tag(4)
                    Text("This week").tag(1)
                    Text("Shopping").tag(2)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)
                .accessibilityLabel("Meal section selector")

                HStack(spacing: 8) {
                    Text("More")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button {
                        selectedTab = 0
                    } label: {
                        Label("Meal library", systemImage: "books.vertical")
                    }
                    .buttonStyle(.bordered)
                    .tint(selectedTab == 0 ? Color.accentColor : Color.secondary)
                    Button {
                        selectedTab = 3
                    } label: {
                        Label("Pantry", systemImage: "cabinet")
                    }
                    .buttonStyle(.bordered)
                    .tint(selectedTab == 3 ? Color.accentColor : Color.secondary)
                    Spacer()
                }
                .font(.caption)
                .padding(.horizontal)
                .padding(.bottom, 8)

                if let errorMessage = currentErrorMessage {
                    errorBanner(errorMessage)
                }

                switch selectedTab {
                case 0:
                    mealLibraryTab
                case 1:
                    mealPlanTab
                case 2:
                    shoppingListTab
                case 3:
                    groceryTab
                case 4:
                    tonightTab
                default:
                    mealLibraryTab
                }
            }
            .navigationTitle("Meals & Shopping")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if selectedTab == 0 {
                        Menu {
                            Button {
                                libraryVM.showingRecipeImport = true
                            } label: {
                                Label("Copy a recipe", systemImage: "doc.on.clipboard")
                            }
                            Button {
                                libraryVM.resetForm()
                                libraryVM.showingAddMeal = true
                            } label: {
                                Label("New meal", systemImage: "plus")
                            }
                        } label: {
                            Image(systemName: "plus.circle.fill")
                        }
                        .accessibilityLabel("Add meal or recipe")
                    } else if selectedTab == 1 {
                        Button {
                            planVM.showingRatingsHistory = true
                            Task {
                                await planVM.loadRatingsHistory()
                            }
                        } label: {
                            Image(systemName: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                        }
                        .accessibilityLabel("Ratings history")
                    } else if selectedTab == 3 {
                        Menu {
                            Button {
                                stockVM.showingTescoImport = true
                            } label: {
                                Label("Import Tesco", systemImage: "doc.text")
                            }
                            Button {
                                stockVM.beginAddStock()
                            } label: {
                                Label("Add Stock", systemImage: "plus")
                            }
                            Button {
                                stockVM.showingAddFreezerItem = true
                            } label: {
                                Label("Add Freezer Item", systemImage: "snowflake")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .accessibilityLabel("Pantry actions menu")
                    } else if selectedTab == 2 {
                        HStack(spacing: 16) {
                            Button {
                                stockVM.tescoHistoryNotice = nil
                                stockVM.showingTescoHistory = true
                                Task { await stockVM.loadTescoHistorySummary() }
                            } label: {
                                Image(systemName: "clock.arrow.circlepath")
                            }
                            .accessibilityLabel("Tesco history")
                            Button {
                                quickShoppingName = ""
                                showingQuickShopping = true
                            } label: {
                                Image(systemName: "plus")
                            }
                            .accessibilityLabel("Add shopping item")
                        }
                    }
                }
            }
            .sheet(isPresented: $libraryVM.showingAddMeal) {
                addMealSheet
            }
            .sheet(
                isPresented: $libraryVM.showingRecipeImport,
                onDismiss: cancelRecipePhotoImport
            ) {
                recipeImportSheet
            }
            .sheet(isPresented: $shoppingVM.showingPlanReview) {
                planShoppingReviewSheet
            }
            .sheet(isPresented: $showingQuickShopping) {
                quickShoppingSheet
            }
            .sheet(item: $planVM.recommendationForAnotherDay) { recommendation in
                recommendationDateSheet(recommendation)
            }
            .sheet(isPresented: $stockVM.showingAddFreezerItem) {
                addFreezerItemSheet
            }
            .sheet(isPresented: $stockVM.showingAddStock) {
                addStockSheet
            }
            .sheet(isPresented: $stockVM.showingTescoImport) {
                tescoImportSheet
            }
            .sheet(
                isPresented: $stockVM.showingTescoHistory,
                onDismiss: { stockVM.discardTescoHistoryPreview() }
            ) {
                tescoHistorySheet
            }
            .sheet(item: $libraryVM.selectedMealForDetail) { meal in
                mealDetailSheet(meal)
            }
            .sheet(item: $planVM.slotAssignmentContext) { context in
                slotAssignmentSheet(context)
            }
            .sheet(item: $planVM.selectedPlanForRating) { plan in
                ratingsSheet(for: plan)
            }
            .sheet(isPresented: $planVM.showingRatingsHistory) {
                ratingsHistorySheet
            }
            .sheet(item: $stockVM.editingUseByLine) { line in
                editUseBySheet(line)
            }
            .sheet(item: $stockVM.selectedBatchDetail) { batch in
                batchDetailSheet(batch)
            }
            .sheet(item: $stockVM.selectedGroceryItemForEdit) { item in
                groceryItemEditorSheet(item)
            }
            .task {
                if let section = appState.preferredMealsSection {
                    selectedTab = min(max(section, 0), 4)
                    appState.preferredMealsSection = nil
                }
                if let subpage = appState.preferredTescoSubpage {
                    shoppingVM.tescoSubpage = min(max(subpage, 0), 1)
                    appState.preferredTescoSubpage = nil
                }
                await loadForCurrentTab()
            }
            .onChange(of: selectedTab) {
                Task {
                    await loadForCurrentTab()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .shoppingDataChanged)) { _ in
                Task {
                    await shoppingVM.loadShopping()
                    await shoppingVM.loadTescoSuggestions()
                }
            }
            .onChange(of: appState.preferredMealsSection) { _, section in
                guard let section else { return }
                selectedTab = min(max(section, 0), 4)
                appState.preferredMealsSection = nil
            }
            .onChange(of: appState.preferredTescoSubpage) { _, subpage in
                guard let subpage else { return }
                selectedTab = 2
                shoppingVM.tescoSubpage = min(max(subpage, 0), 1)
                appState.preferredTescoSubpage = nil
            }
            .onChange(of: recipePhoto) { _, item in
                guard let item else { return }
                beginRecipePhotoImport(item)
            }
            .onDisappear { cancelRecipePhotoImport() }
        }
    }

    private var currentErrorMessage: String? {
        switch selectedTab {
        case 0: return libraryVM.errorMessage
        case 1: return planVM.errorMessage
        case 2: return shoppingVM.errorMessage
        case 3: return stockVM.errorMessage
        case 4: return planVM.errorMessage
        default: return nil
        }
    }

    private func loadForCurrentTab() async {
        switch selectedTab {
        case 0:
            await libraryVM.loadMeals()
        case 1:
            await planVM.loadMealPlans()
            await planVM.loadChildren()
            await planVM.loadMeals()
        case 2:
            await shoppingVM.loadShopping()
            await shoppingVM.loadTescoSuggestions()
            await stockVM.loadTescoHistorySummary()
        case 3:
            await stockVM.loadGroceryDashboard()
            await shoppingVM.loadShopping()
        case 4:
            await planVM.loadTonightInsights()
        default:
            break
        }
    }

    // MARK: - Meal Library Tab

    private var mealLibraryTab: some View {
        Group {
            if libraryVM.isLoading && libraryVM.meals.isEmpty {
                loadingView("Loading meals...")
            } else if libraryVM.filteredMeals.isEmpty {
                VStack(spacing: 12) {
                    removedMealUndoBanner
                    if libraryVM.meals.isEmpty {
                        emptyStateView(icon: "fork.knife", title: "No meals yet", subtitle: "Tap + to add your first meal")
                    } else {
                        emptyStateView(icon: "magnifyingglass", title: "No results", subtitle: "Try a different search term")
                    }
                }
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        removedMealUndoBanner
                        HStack {
                            Image(systemName: "magnifyingglass")
                                .foregroundStyle(.secondary)
                            TextField("Search meals...", text: $libraryVM.searchText)
                                .textFieldStyle(.plain)
                        }
                        .padding(10)
                        .background(Color(.tertiarySystemFill))
                        .cornerRadius(10)
                        .padding(.horizontal)
                        .padding(.bottom, 12)
                        .accessibilityLabel("Search meals")

                        LazyVGrid(columns: [
                            GridItem(.flexible(), spacing: 12),
                            GridItem(.flexible(), spacing: 12)
                        ], spacing: 12) {
                            ForEach(libraryVM.filteredMeals) { meal in
                                mealCard(meal)
                            }
                        }
                        .padding(.horizontal)
                        .padding(.bottom, 16)
                    }
                    .frame(maxWidth: 700)
                    .frame(maxWidth: .infinity)
                }
                .refreshable {
                    await libraryVM.loadMeals()
                }
            }
        }
    }

    @ViewBuilder
    private var removedMealUndoBanner: some View {
        if let removed = libraryVM.removedMeal {
            HStack {
                Text("\(removed.name) removed")
                    .font(.subheadline)
                Spacer()
                Button("Undo") {
                    Task { await libraryVM.restoreRemovedMeal() }
                }
                .fontWeight(.semibold)
            }
            .padding(12)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal)
            .padding(.bottom, 10)
        }
    }

    private func mealCard(_ meal: MealDTO) -> some View {
        Button {
            libraryVM.selectedMealForDetail = meal
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                Text(meal.name)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .lineLimit(2)

                let tags = MealHelpers.parseTags(meal.tags)
                if !tags.isEmpty {
                    FlowLayout(spacing: 4) {
                        ForEach(tags, id: \.self) { tag in
                            Text(tag)
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.15))
                                .foregroundStyle(.tint)
                                .cornerRadius(4)
                        }
                    }
                }

                if let prep = meal.prepMinutes {
                    Text(String(format: "Prep %dm".localized, prep))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if let servings = meal.servings {
                    Text("Feeds \(servings)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if meal.notForUs == true {
                    Text("Skipped in suggestions")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                if let label = MealHelpers.daysAgoLabel(meal.lastMadeAt) {
                    Text(label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Never made")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 100, alignment: .topLeading)
            .background(Color(.secondarySystemGroupedBackground))
            .cornerRadius(12)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Meal: \(meal.name)")
    }

    // MARK: - Meal Plan Tab

    private var mealPlanTab: some View {
        Group {
            if planVM.isLoading && planVM.mealPlans.isEmpty {
                loadingView("Loading meal plan...")
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("This week")
                                    .font(.headline)
                                Text("Plan first, then add only what is missing.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                guard let start = planVM.weekDays.first, let end = planVM.weekDays.last else { return }
                                Task { await shoppingVM.reviewWeek(start: start, end: end) }
                            } label: {
                                if shoppingVM.isReviewingPlan {
                                    ProgressView()
                                } else {
                                    Label("Check shopping", systemImage: "cart.badge.plus")
                                }
                            }
                            .buttonStyle(.bordered)
                            .disabled(planVM.mealPlans.isEmpty || shoppingVM.isReviewingPlan)
                        }
                        .padding(12)
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))

                        ForEach(planVM.weekDays, id: \.self) { date in
                            mealPlanDayCard(date)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .frame(maxWidth: 700)
                    .frame(maxWidth: .infinity)
                }
                .refreshable {
                    await planVM.loadMealPlans()
                    await planVM.loadChildren()
                }
            }
        }
    }

    private func mealPlanDayCard(_ date: Date) -> some View {
        let isToday = Calendar.current.isDateInToday(date)
        let isExpanded = planVM.isDayExpanded(date)
        let mealTypes = ["breakfast", "lunch", "dinner"]

        return VStack(alignment: .leading, spacing: 8) {
            Button {
                planVM.toggleDayExpanded(date)
            } label: {
                HStack {
                    Image(systemName: isExpanded ? "chevron.down.circle.fill" : "chevron.right.circle")
                        .foregroundStyle(.secondary)
                    Text(MealHelpers.dayAbbreviation(date))
                        .font(.headline)
                        .fontWeight(isToday ? .bold : .semibold)
                        .foregroundStyle(isToday ? Color.accentColor : Color.primary)
                    Text(MealHelpers.dayNumber(date))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if isToday {
                        Text("Today")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundStyle(.tint)
                    }
                    Spacer()
                    if let dinner = planVM.planForSlot(date: date, mealType: "dinner")?.mealName {
                        Text(dinner)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    }
            }
            .buttonStyle(.plain)
            .padding(.top, 8)
            .accessibilityLabel("\(MealHelpers.dayAbbreviation(date)) \(MealHelpers.dayNumber(date))\(isToday ? ", Today" : "")")

            if isExpanded {
                ForEach(mealTypes, id: \.self) { mealType in
                    let plan = planVM.planForSlot(date: date, mealType: mealType)

                    HStack(spacing: 8) {
                        Text(MealHelpers.localizedMealType(mealType))
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundStyle(.secondary)
                            .frame(width: 70, alignment: .leading)

                        if mealType == "breakfast", !planVM.children.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(planVM.children) { child in
                                    let childPlan = planVM.breakfastPlanForChild(date: date, childId: child.id)
                                    HStack {
                                        Button {
                                            planVM.startSlotAssignment(
                                                date: date,
                                                mealType: "breakfast",
                                                childId: child.id,
                                                childName: child.name
                                            )
                                        } label: {
                                            HStack {
                                                Text("\(child.name):")
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                                Text(childPlan?.mealName ?? "Assign breakfast")
                                                    .font(.subheadline)
                                                    .foregroundStyle(childPlan == nil ? .tertiary : .primary)
                                                Spacer()
                                                Image(systemName: "chevron.right")
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel("Assign breakfast for \(child.name)")

                                        if let childPlan {
                                            Button("Rate") {
                                                Task {
                                                    await planVM.prepareRatings(for: childPlan)
                                                }
                                            }
                                            .font(.caption)
                                            .buttonStyle(.bordered)
                                            .controlSize(.mini)
                                            .accessibilityLabel("Rate \(child.name)'s breakfast")
                                        }
                                    }
                                }
                            }
                        } else {
                            Button {
                                planVM.startSlotAssignment(date: date, mealType: mealType)
                            } label: {
                                HStack {
                                    Text(plan?.mealName ?? "Tap to assign meal")
                                        .font(.subheadline)
                                        .foregroundStyle(plan == nil ? .tertiary : .primary)
                                        .lineLimit(1)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Assign \(MealHelpers.localizedMealType(mealType))")
                        }

                        if (mealType == "dinner" || mealType == "lunch"), let plan {
                            Button("Rate") {
                                Task {
                                    await planVM.prepareRatings(for: plan)
                                }
                            }
                            .font(.caption)
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                            .accessibilityLabel("Rate \(MealHelpers.localizedMealType(mealType))")
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            Divider()
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(12)
        .padding(.vertical, 4)
    }

    // MARK: - Shopping List Tab

    private var shoppingListTab: some View {
        Group {
            if shoppingVM.isLoading && shoppingVM.shoppingItems.isEmpty && shoppingVM.grocerySuggestions.isEmpty {
                loadingView("Loading shopping...")
            } else {
                List {
                    Section {
                        HStack(alignment: .center, spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(shoppingVM.shoppingItems.filter { !$0.checked }.count) to buy")
                                    .font(.headline)
                                Text("Shared family list")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                let days = MealHelpers.weekDays
                                guard let start = days.first, let end = days.last else { return }
                                Task { await shoppingVM.reviewWeek(start: start, end: end) }
                            } label: {
                                if shoppingVM.isReviewingPlan {
                                    ProgressView()
                                } else {
                                    Label("From meals", systemImage: "calendar.badge.checkmark")
                                }
                            }
                            .buttonStyle(.bordered)
                            .disabled(shoppingVM.isReviewingPlan)
                        }
                    }

                    if let message = shoppingVM.statusMessage {
                        Section {
                            Label(message, systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                    }

                    if !shoppingVM.grocerySuggestions.isEmpty {
                        Section("Worth topping up?") {
                            ForEach(shoppingVM.grocerySuggestions.prefix(5)) { suggestion in
                                suggestionRow(suggestion)
                            }
                        }
                    }

                    ForEach(shoppingVM.groupedShoppingItems, id: \.category) { group in
                        Section(group.category) {
                            ForEach(group.items) { item in
                                shoppingItemRow(item)
                            }
                        }
                    }

                    if shoppingVM.shoppingItems.isEmpty {
                        Section {
                            ContentUnavailableView(
                                "Shopping list is clear",
                                systemImage: "cart",
                                description: Text("Add something now or check this week's meals.")
                            )
                        }
                    }

                    if shoppingVM.completedItemCount > 0 {
                        Section {
                            Button(role: .destructive) {
                                showingClearCompletedConfirmation = true
                            } label: {
                                Text("Clear bought items (\(shoppingVM.completedItemCount))")
                            }
                            .disabled(shoppingVM.isClearingCompleted)
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .refreshable {
                    await shoppingVM.loadShopping()
                    await shoppingVM.loadTescoSuggestions()
                }
            }
        }
        .confirmationDialog(
            "Clear completed items?",
            isPresented: $showingClearCompletedConfirmation
        ) {
            Button("Clear \(shoppingVM.completedItemCount) completed", role: .destructive) {
                Task { await shoppingVM.clearCompletedItems() }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Only checked items will be removed. Everything still to buy will stay.")
        }
    }

    private func suggestionRow(_ suggestion: GrocerySuggestionDTO) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(suggestion.itemName)
                Spacer()
                Text("\(suggestion.suggestedQty, specifier: "%.1f") \(suggestion.unit)")
                    .font(.subheadline)
            }
            Text(suggestion.reason)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button("Dismiss", role: .destructive) {
                shoppingVM.dismissSuggestion(suggestion.groceryItemId)
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button("Add") {
                Task {
                    await shoppingVM.acceptSingleSuggestion(suggestion.groceryItemId)
                }
            }
            .tint(.green)
        }
        .accessibilityLabel("Suggested top-up: \(suggestion.itemName)")
    }

    private func shoppingItemRow(_ item: ShoppingItemDTO) -> some View {
        Button {
            Task {
                await shoppingVM.toggleShoppingItem(item.id)
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: item.checked ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(item.checked ? .green : .secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.subheadline)
                        .strikethrough(item.checked)
                        .foregroundStyle(item.checked ? .secondary : .primary)

                    if let quantity = item.quantity, !quantity.isEmpty {
                        Text(quantity)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if item.checked {
                        Text("Bought")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }
                }

                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(item.checked ? 0.6 : 1.0)
        .listRowBackground(
            appState.highlightedShoppingResultId == item.id
                ? Color.accentColor.opacity(0.14)
                : Color(.secondarySystemGroupedBackground)
        )
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button("Remove", role: .destructive) {
                Task {
                    await shoppingVM.removeShoppingItem(item.id)
                }
            }
        }
        .accessibilityLabel("\(item.name)\(item.checked ? ", bought" : "")")
    }

    // MARK: - Grocery / Pantry Tab

    private var groceryTab: some View {
        Group {
            if stockVM.isLoading && stockVM.stockLevels.isEmpty {
                loadingView("Checking the pantry...")
            } else {
                List {
                    Section {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Only what needs attention")
                                .font(.headline)
                            Text("The full stock record stays out of the way until something is low or needs using.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }

                    if stockVM.expiringItems.isEmpty && stockVM.criticalLowItems.isEmpty {
                        Section {
                            ContentUnavailableView(
                                "Nothing needs attention",
                                systemImage: "checkmark.circle",
                                description: Text("There are no low or use-soon items right now.")
                            )
                        }
                    }

                    if !stockVM.expiringItems.isEmpty {
                        Section("Use soon") {
                            ForEach(stockVM.expiringItems) { item in
                                HStack(spacing: 10) {
                                    Image(systemName: "clock.badge.exclamationmark")
                                        .foregroundStyle(.orange)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.itemName)
                                        Text(item.daysLeft < 0 ? "Past its use-by date" : item.daysLeft == 0 ? "Use today" : "\(item.daysLeft) days left")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button(shoppingContains(item.itemName) ? "On list" : "Replace") {
                                        Task {
                                            await shoppingVM.addItem(
                                                name: item.itemName,
                                                quantity: "\(item.remainingQty.formatted()) \(item.unit)"
                                            )
                                        }
                                    }
                                    .buttonStyle(.bordered)
                                    .disabled(shoppingContains(item.itemName))
                                }
                            }
                        }
                    }

                    if !stockVM.criticalLowItems.isEmpty {
                        Section("Running low") {
                            ForEach(stockVM.criticalLowItems) { item in
                                HStack(spacing: 10) {
                                    Image(systemName: "cabinet")
                                        .foregroundStyle(.orange)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.itemName)
                                        Text("\(item.remaining.formatted()) \(item.unit) left")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button(shoppingContains(item.itemName) ? "On list" : "Add") {
                                        Task { await shoppingVM.addItem(name: item.itemName) }
                                    }
                                    .buttonStyle(.bordered)
                                    .disabled(shoppingContains(item.itemName))
                                }
                            }
                        }
                    }

                    Section {
                        NavigationLink {
                            pantryManagementView
                                .navigationTitle("Manage Pantry")
                        } label: {
                            Label("See and manage everything at home", systemImage: "list.bullet.rectangle")
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .refreshable {
                    await stockVM.loadGroceryDashboard()
                    await shoppingVM.loadShopping()
                }
            }
        }
    }

    private func shoppingContains(_ name: String) -> Bool {
        shoppingVM.shoppingItems.contains {
            !$0.checked && $0.name.compare(name, options: .caseInsensitive) == .orderedSame
        }
    }

    private var pantryManagementView: some View {
        Group {
            if stockVM.isLoading && stockVM.stockLevels.isEmpty {
                loadingView("Loading pantry stock...")
            } else {
                List {
                    if !stockVM.expiringItems.isEmpty {
                        Section("Expiring Soon") {
                            ForEach(stockVM.expiringItems) { item in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.itemName)
                                        Text(String(format: "Use by %@ • %.1f %@".localized, item.useByDate, item.remainingQty, item.unit))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(MealHelpers.alertLabel(item.alertLevel))
                                        .font(.caption2)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(Color.orange.opacity(0.15))
                                        .cornerRadius(6)
                                }
                                .accessibilityLabel("\(item.itemName), expires \(item.useByDate), \(MealHelpers.alertLabel(item.alertLevel))")
                            }
                        }
                    }

                    Section {
                        HStack {
                            Text("Pantry Stock")
                                .font(.headline)
                            Spacer()
                        }
                    }

                    Section("Stock Items") {
                        if stockVM.stockLevels.isEmpty {
                            Text("No stock data yet")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(stockVM.stockLevels) { stock in
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(stock.itemName)
                                            Text("\(stock.remaining, specifier: "%.1f") \(stock.unit) remaining")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        if let days = stock.daysUntilExpiry {
                                            Text("\(days)d")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    if stockVM.processingStockItemId == stock.id {
                                        ProgressView()
                                            .controlSize(.small)
                                    }
                                }
                                .padding(.vertical, 2)
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button("Gone bad", role: .destructive) {
                                        Task {
                                            await stockVM.logConsumption(for: stock, eventType: "wasted")
                                        }
                                    }
                                }
                                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                    Button("Used") {
                                        Task {
                                            await stockVM.logConsumption(for: stock, eventType: "consumed")
                                        }
                                    }
                                    .tint(.green)
                                }
                                .accessibilityLabel("\(stock.itemName), \(stock.remaining, specifier: "%.1f") \(stock.unit) remaining")
                            }
                        }
                    }

                    Section {
                        HStack {
                            Text("Freezer")
                                .font(.headline)
                            Spacer()
                            Button {
                                stockVM.showingAddFreezerItem = true
                            } label: {
                                Label("Add", systemImage: "plus")
                            }
                            .buttonStyle(.bordered)
                            .accessibilityLabel("Add freezer item")
                        }
                    }

                    Section("Freezer Items") {
                        if stockVM.freezerItems.isEmpty {
                            Text("No freezer items yet")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(stockVM.freezerItems) { item in
                                HStack {
                                    Text(item.itemName)
                                    Spacer()
                                    Text("\(item.qty, specifier: "%.0f")")
                                        .fontWeight(.semibold)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(Color.blue.opacity(0.15))
                                        .cornerRadius(6)
                                }
                            }
                        }
                    }

                    Section("Recent Purchases (Edit Use-by)") {
                        if stockVM.recentPurchaseLines.isEmpty {
                            Text("No recent purchases yet")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(stockVM.recentPurchaseLines.prefix(20)) { line in
                                Button {
                                    stockVM.openUseByEditor(for: line)
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(line.itemName)
                                            Text("\(line.qty, specifier: "%.1f") \(line.unit) • \(MealHelpers.localizedStorage(line.storage))")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                            Text(String(format: "Use by: %@".localized, line.useByDate ?? "Not set".localized))
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Edit use-by date for \(line.itemName)")
                            }
                        }
                    }

                    Section("Recent Batches") {
                        if stockVM.recentBatches.isEmpty {
                            Text("No batches yet")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(stockVM.recentBatches.prefix(10)) { batch in
                                Button {
                                    Task {
                                        await stockVM.openBatchDetail(batch.id)
                                    }
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(MealHelpers.localizedSource(batch.source))
                                            Text(String(format: "%d lines • %@".localized, batch.lines.count, String(batch.purchasedAt.prefix(10))))
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .refreshable {
                    await stockVM.loadGroceryDashboard()
                }
            }
        }
    }

    // MARK: - Tonight Tab

    private var tonightTab: some View {
        MealsTonightView(planVM: planVM)
    }

    // MARK: - Sheets

    private func ratingsSheet(for plan: MealPlanDTO) -> some View {
        NavigationStack {
            Form {
                Section {
                    Text(plan.mealName ?? "Dinner")
                        .font(.headline)
                    Text("Rate tonight for each child")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if planVM.children.isEmpty {
                    Section {
                        Text("No children found")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    let ratingChildren = planVM.children.filter { planVM.ratingsByChildId.keys.contains($0.id) }
                    Section("Ratings") {
                        ForEach(ratingChildren) { child in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(child.name)
                                    .font(.subheadline)
                                Picker("\(child.name) rating", selection: planVM.ratingBinding(for: child.id)) {
                                    Text("Skip next time").tag(1)
                                    Text("Fine").tag(2)
                                    Text("Loved it").tag(3)
                                }
                                .pickerStyle(.segmented)
                                .accessibilityLabel("Rating for \(child.name)")
                            }
                            .padding(.vertical, 4)
                        }
                    }

                    Section {
                        Toggle("Tired household tonight", isOn: $planVM.tiredHouseholdForRating)
                    }
                }

                if let errorMessage = planVM.errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }
            }
            .navigationTitle("Rate Meal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        planVM.selectedPlanForRating = nil
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            await planVM.submitRatingsForSelectedPlan()
                        }
                    }
                    .disabled(planVM.children.isEmpty || planVM.isSubmittingRatings)
                }
            }
        }
    }

    private var addMealSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Meal", text: $libraryVM.formName)

                    TextField("Short description", text: $libraryVM.formDescription, axis: .vertical)
                        .lineLimit(2...4)

                    HStack {
                        TextField("Prep minutes", text: $libraryVM.formPrepMinutes)
                            .keyboardType(.numberPad)
                        TextField("Feeds", text: $libraryVM.formServings)
                            .keyboardType(.numberPad)
                    }

                    TextField("Recipe web address", text: $libraryVM.formRecipeURL)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                }

                Section("Useful labels") {
                    TagInputView(tags: $libraryVM.formTags)
                }

                Section("Ingredients") {
                    if libraryVM.formIngredients.isEmpty {
                        Text("Add these when you want the weekly plan to help with shopping.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(libraryVM.formIngredients.enumerated()), id: \.element.id) { index, _ in
                        VStack(alignment: .leading, spacing: 8) {
                            TextField(
                                "Ingredient",
                                text: Binding(
                                    get: { libraryVM.formIngredients[index].name },
                                    set: { libraryVM.formIngredients[index].name = $0 }
                                )
                            )
                            HStack {
                                TextField(
                                    "Quantity",
                                    text: Binding(
                                        get: { libraryVM.formIngredients[index].quantity },
                                        set: { libraryVM.formIngredients[index].quantity = $0 }
                                    )
                                )
                                TextField(
                                    "Aisle",
                                    text: Binding(
                                        get: { libraryVM.formIngredients[index].category },
                                        set: { libraryVM.formIngredients[index].category = $0 }
                                    )
                                )
                            }
                            Button("Remove ingredient", role: .destructive) {
                                libraryVM.formIngredients.remove(at: index)
                            }
                            .font(.caption)
                        }
                    }
                    Button {
                        libraryVM.formIngredients.append(MealIngredientDraft())
                    } label: {
                        Label("Add ingredient", systemImage: "plus")
                    }
                }

                Section {
                    DisclosureGroup("Allergies and family preferences") {
                        TextField("Safety notes", text: $libraryVM.formAllergyNotes, axis: .vertical)
                            .lineLimit(2...5)
                        TextField("What works for the children", text: $libraryVM.formPreferenceNotes, axis: .vertical)
                            .lineLimit(2...5)
                    }
                }

                if let errorMessage = libraryVM.errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }
            }
            .navigationTitle(libraryVM.editingMealId == nil ? "New Meal" : "Edit Meal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        libraryVM.showingAddMeal = false
                        libraryVM.resetForm()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            await libraryVM.saveMeal()
                        }
                    }
                    .disabled(libraryVM.formName.trimmingCharacters(in: .whitespaces).isEmpty || libraryVM.isLoading)
                }
            }
        }
    }

    private var recipeImportSheet: some View {
        let photoReadInProgress = isReadingRecipePhoto
        return NavigationStack {
            Form {
                Section {
                    Text("Paste a recipe, add its web address, or photograph it. Everything remains editable before saving.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Recipe") {
                    TextField("Web address", text: $libraryVM.recipeImportURL)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                    TextEditor(text: $libraryVM.recipeImportText)
                        .frame(minHeight: 180)
                        .accessibilityLabel("Recipe text")
                    PhotosPicker(selection: $recipePhoto, matching: .images) {
                        Label(
                            (photoReadInProgress ? "Reading recipe photo…" : "Read a recipe photo")
                                .localized,
                            systemImage: "camera.example_e5351f2b"
                        )
                    }
                    .disabled(photoReadInProgress)
                    .accessibilityIdentifier("recipePhotoPicker")
                    if photoReadInProgress {
                        ProgressView("Reading recipe photo…")
                            .accessibilityIdentifier("recipePhotoReading")
                    }
                }
                if let error = libraryVM.errorMessage {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .accessibilityIdentifier("recipePhotoError")
                    }
                }
            }
            .navigationTitle("Copy a Recipe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        cancelRecipePhotoImport()
                        libraryVM.showingRecipeImport = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Review") {
                        Task { await libraryVM.previewRecipe() }
                    }
                    .disabled(
                        libraryVM.isReadingRecipe || isReadingRecipePhoto ||
                        (libraryVM.recipeImportText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                         libraryVM.recipeImportURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    )
                }
            }
        }
    }

    private var planShoppingReviewSheet: some View {
        NavigationStack {
            List {
                Section {
                    Text("Untick anything you already have. Items already on shopping cannot be added twice.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let diff = shoppingVM.planDiff {
                    Section("Ingredients") {
                        if diff.items.isEmpty {
                            Text("No ingredients are attached to this week's meals yet.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(diff.items) { item in
                            Button {
                                shoppingVM.togglePlanDiffItem(item.key)
                            } label: {
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: item.alreadyOnList ? "checkmark.circle.fill" : shoppingVM.selectedPlanDiffKeys.contains(item.key) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(item.alreadyOnList ? Color.secondary : Color.accentColor)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(item.name)
                                            .foregroundStyle(.primary)
                                        Text([item.quantity, item.plannedMeals.joined(separator: " · ")].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        if item.alreadyOnList {
                                            Text("Already on shopping")
                                                .font(.caption2)
                                                .foregroundStyle(.green)
                                        } else if item.likelyAtHome {
                                            Text("Looks like it is at home")
                                                .font(.caption2)
                                                .foregroundStyle(.orange)
                                        }
                                    }
                                    Spacer()
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(item.alreadyOnList)
                        }
                    }
                }
            }
            .navigationTitle("What Do We Need?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { shoppingVM.showingPlanReview = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add \(shoppingVM.selectedPlanDiffKeys.count)") {
                        Task { await shoppingVM.addReviewedIngredients() }
                    }
                    .disabled(shoppingVM.selectedPlanDiffKeys.isEmpty || shoppingVM.isReviewingPlan)
                }
            }
        }
    }

    private var quickShoppingSheet: some View {
        NavigationStack {
            Form {
                Section("Shopping item") {
                    TextField("What do we need?", text: $quickShoppingName)
                        .submitLabel(.done)
                        .onSubmit { Task { await saveQuickShoppingItem() } }
                }
            }
            .navigationTitle("Add to Shopping")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showingQuickShopping = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { Task { await saveQuickShoppingItem() } }
                        .disabled(quickShoppingName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func recommendationDateSheet(_ recommendation: RecommendedMealDTO) -> some View {
        NavigationStack {
            Form {
                Section {
                    Text(recommendation.mealName)
                        .font(.headline)
                    DatePicker("Day", selection: $planVM.recommendationDate, in: Date()..., displayedComponents: .date)
                }
            }
            .navigationTitle("Plan Another Day")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { planVM.recommendationForAnotherDay = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add to week") {
                        Task {
                            await planVM.chooseRecommendation(
                                recommendation,
                                action: "plan_another_day",
                                date: planVM.recommendationDate
                            )
                        }
                    }
                    .disabled(planVM.recommendationBeingSavedId == recommendation.mealId)
                }
            }
        }
    }

    private func saveQuickShoppingItem() async {
        let name = quickShoppingName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        await shoppingVM.addItem(name: name)
        if shoppingVM.errorMessage == nil {
            showingQuickShopping = false
            quickShoppingName = ""
        }
    }

    private func beginRecipePhotoImport(_ item: PhotosPickerItem) {
        recipePhotoTask?.cancel()
        let generation = UUID()
        recipePhotoGeneration = generation
        isReadingRecipePhoto = true
        libraryVM.errorMessage = nil
        recipePhotoTask = Task {
            await readRecipePhoto(item, generation: generation)
        }
    }

    private func readRecipePhoto(_ item: PhotosPickerItem, generation: UUID) async {
        defer { finishRecipePhotoImport(generation: generation) }
        do {
            guard let transfer = try await item.loadTransferable(
                type: StagedDocumentImageTransfer.self
            ) else {
                throw DocumentCaptureError.unreadableFile
            }
            let asset = try transfer.takeAsset()
            defer { DocumentCaptureService.removeTemporaryAsset(asset) }
            let extractedText = try await DocumentCaptureService.extractText(from: asset)
            try Task.checkCancellation()
            guard recipePhotoGeneration == generation else { return }
            libraryVM.recipeImportText = extractedText
        } catch is CancellationError {
            return
        } catch {
            guard recipePhotoGeneration == generation else { return }
            libraryVM.errorMessage =
                "That recipe photo could not be read. You can still paste the text.".localized
        }
    }

    private func finishRecipePhotoImport(generation: UUID) {
        if recipePhotoGeneration == generation {
            recipePhoto = nil
            isReadingRecipePhoto = false
            recipePhotoTask = nil
            recipePhotoGeneration = nil
        }
    }

    private func cancelRecipePhotoImport() {
        recipePhotoGeneration = nil
        recipePhotoTask?.cancel()
        recipePhotoTask = nil
        recipePhoto = nil
        isReadingRecipePhoto = false
    }

    private func mealDetailSheet(_ meal: MealDTO) -> some View {
        MealDetailSheet(libraryVM: libraryVM, planVM: planVM, meal: meal)
    }

    private func slotAssignmentSheet(_ context: SlotAssignmentContext) -> some View {
        NavigationStack {
            Form {
                Section {
                    Text("\(context.date) - \(MealHelpers.localizedMealType(context.mealType))")
                        .font(.headline)
                    if let childName = context.childName {
                        Text(String(format: "For %@".localized, childName))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Picker("Mode", selection: $planVM.slotCreateMode) {
                        Text("Existing Meal").tag(0)
                        Text("New Meal").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityLabel("Assignment mode selector")
                }

                if planVM.slotCreateMode == 0 {
                    Section("Choose Existing Meal") {
                        TextField("Search meals", text: $planVM.slotMealSearchText)
                        ForEach(planVM.slotFilteredMeals()) { meal in
                            Button {
                                Task {
                                    await planVM.assignMealToSlot(
                                        mealId: meal.id,
                                        date: context.date,
                                        mealType: context.mealType,
                                        childId: context.childId
                                    )
                                }
                            } label: {
                                HStack {
                                    Text(meal.name)
                                    Spacer()
                                    Image(systemName: "plus.circle")
                                        .foregroundStyle(.tint)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Assign \(meal.name)")
                        }
                    }
                } else {
                    Section("Create Meal") {
                        TextField("Meal name", text: $planVM.slotCreateMealName)
                        TextField("Description", text: $planVM.slotCreateMealDescription)
                    }

                    Section("Tags") {
                        TagInputView(tags: $planVM.slotCreateMealTags)
                    }

                    Section("Ingredients") {
                        if planVM.slotCreateIngredients.isEmpty {
                            Text("No ingredients yet")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(Array(planVM.slotCreateIngredients.enumerated()), id: \.element.id) { index, _ in
                            VStack(alignment: .leading, spacing: 8) {
                                TextField(
                                    "Ingredient",
                                    text: Binding(
                                        get: { planVM.slotCreateIngredients[index].name },
                                        set: { planVM.slotCreateIngredients[index].name = $0 }
                                    )
                                )
                                HStack {
                                    TextField(
                                        "Qty",
                                        text: Binding(
                                            get: { planVM.slotCreateIngredients[index].quantity },
                                            set: { planVM.slotCreateIngredients[index].quantity = $0 }
                                        )
                                    )
                                    TextField(
                                        "Category",
                                        text: Binding(
                                            get: { planVM.slotCreateIngredients[index].category },
                                            set: { planVM.slotCreateIngredients[index].category = $0 }
                                        )
                                    )
                                }
                                Button(role: .destructive) {
                                    planVM.slotCreateIngredients.remove(at: index)
                                } label: {
                                    Text("Remove ingredient")
                                }
                                .font(.caption)
                            }
                        }
                        Button {
                            planVM.slotCreateIngredients.append(MealIngredientDraft())
                        } label: {
                            Label("Add Ingredient", systemImage: "plus")
                        }
                    }
                    Section {
                        Button("Create and Assign") {
                            Task {
                                await planVM.createAndAssignMealForCurrentSlot()
                            }
                        }
                        .accessibilityLabel("Create new meal and assign to plan")
                    }
                }
            }
            .navigationTitle("Assign Meal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        planVM.slotAssignmentContext = nil
                    }
                }
            }
        }
    }

    private var addFreezerItemSheet: some View {
        NavigationStack {
            Form {
                Section("Freezer Item") {
                    TextField("Item name", text: $stockVM.freezerFormName)
                    TextField("Quantity", text: $stockVM.freezerFormQty)
                        .keyboardType(.numberPad)
                }

                if let errorMessage = stockVM.errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }
            }
            .navigationTitle("Add Freezer Item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        stockVM.showingAddFreezerItem = false
                        stockVM.freezerFormName = ""
                        stockVM.freezerFormQty = ""
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            await stockVM.addFreezerItem()
                        }
                    }
                }
            }
        }
    }

    private var addStockSheet: some View {
        NavigationStack {
            Form {
                Section("Stock Item") {
                    TextField("Item name", text: $stockVM.stockFormName)
                    TextField("Quantity", text: $stockVM.stockFormQty)
                        .keyboardType(.decimalPad)
                    Picker("Unit", selection: $stockVM.stockFormUnit) {
                        Text("each").tag("each")
                        Text("pack").tag("pack")
                        Text("kg").tag("kg")
                        Text("g").tag("g")
                        Text("ml").tag("ml")
                        Text("litre").tag("litre")
                    }
                    Picker("Storage", selection: $stockVM.stockFormStorage) {
                        Text("Fridge").tag("fridge")
                        Text("Pantry").tag("pantry")
                        Text("Freezer").tag("freezer")
                    }
                }

                Section("Use-by Tracking") {
                    Toggle("Set use-by date now", isOn: $stockVM.stockFormHasUseByDate)
                    if stockVM.stockFormHasUseByDate {
                        DatePicker("Use-by date", selection: $stockVM.stockFormUseByDate, displayedComponents: .date)
                    }
                    Toggle("Track use-by for this item", isOn: $stockVM.stockFormTrackUseBy)
                }

                if let errorMessage = stockVM.errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }
            }
            .navigationTitle("Add Stock")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        stockVM.showingAddStock = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            await stockVM.addStockManually()
                        }
                    }
                    .disabled(stockVM.stockFormName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func editUseBySheet(_ line: PurchaseLineSummary) -> some View {
        NavigationStack {
            Form {
                Section {
                    Text(line.itemName)
                        .font(.headline)
                    Text("\(line.qty, specifier: "%.1f") \(line.unit) - \(line.storage.capitalized)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Use-by Date") {
                    DatePicker("Date", selection: $stockVM.useByEditorDate, displayedComponents: .date)
                }
            }
            .navigationTitle("Edit Use-by")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        stockVM.editingUseByLine = nil
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            await stockVM.saveUseByDateForEditingLine()
                        }
                    }
                }
            }
        }
    }

    private var tescoHistorySheet: some View {
        NavigationStack {
            Form {
                if stockVM.tescoHistorySummary.shopCount > 0 {
                    Section {
                        HStack(spacing: 12) {
                            historyMetric(
                                String(stockVM.tescoHistorySummary.shopCount),
                                label: "shops"
                            )
                            Divider()
                            historyMetric(
                                String(stockVM.tescoHistorySummary.lineCount),
                                label: "items"
                            )
                            if let range = tescoHistoryRange {
                                Divider()
                                historyMetric(range, label: "history")
                            }
                        }
                    }

                    if !stockVM.tescoHistorySummary.usuals.isEmpty {
                        Section {
                            ForEach(stockVM.tescoHistorySummary.usuals.prefix(5)) { item in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.name)
                                            .lineLimit(1)
                                        Text("\(item.shopCount) shops")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if let latest = item.latestPricePence {
                                        VStack(alignment: .trailing, spacing: 2) {
                                            Text(Double(latest) / 100, format: .currency(code: "GBP"))
                                                .fontWeight(.semibold)
                                            if let previous = item.previousPricePence,
                                               previous != latest {
                                                let change = latest - previous
                                                Text("\(change > 0 ? "+" : "−")\(abs(change))p")
                                                    .font(.caption)
                                                    .foregroundStyle(change > 0 ? .red : .green)
                                            }
                                        }
                                    }
                                }
                            }
                        } header: {
                            HStack {
                                Text("Regulars")
                                Spacer()
                                if stockVM.tescoHistorySummary.receiptMonitoring {
                                    Label("Receipts on", systemImage: "envelope.badge")
                                        .font(.caption)
                                        .foregroundStyle(.green)
                                }
                            }
                        }
                    }
                } else if !stockVM.tescoHistoryBusy {
                    Section {
                        ContentUnavailableView(
                            "No history yet",
                            systemImage: "cart"
                        )
                    }
                }

                if let notice = stockVM.tescoHistoryNotice {
                    Section {
                        Label(notice, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }

                if stockVM.tescoHistoryBusy {
                    Section {
                        HStack {
                            Spacer()
                            ProgressView("Reading…")
                            Spacer()
                        }
                    }
                }

                if let preview = stockVM.tescoHistoryPreview {
                    Section("Review") {
                        LabeledContent("Shops", value: String(preview.orderCount))
                        LabeledContent("Items", value: String(preview.lineCount))
                        if !preview.sampleItems.isEmpty {
                            Text(preview.sampleItems.prefix(5).joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if preview.alreadyImported {
                            Label("Already included", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                    }
                }

                if let error = stockVM.tescoHistoryError {
                    Section {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Link(
                        "Get Tesco file",
                        destination: URL(
                            string: "https://www.tesco.com/account/data-portability/en-GB/"
                        )!
                    )
                    Button {
                        showingTescoHistoryFileImporter = true
                    } label: {
                        Label("Choose JSON or ZIP", systemImage: "doc.badge.plus")
                    }
                    .disabled(stockVM.tescoHistoryBusy)
                } footer: {
                    Text("HausKlar stores shops, not your Tesco login.")
                }
            }
            .navigationTitle("Tesco history")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        stockVM.showingTescoHistory = false
                    }
                }
                if let preview = stockVM.tescoHistoryPreview,
                   preview.canConfirm,
                   !preview.alreadyImported {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Import") {
                            Task {
                                if await stockVM.confirmTescoHistory() {
                                    HapticManager.success()
                                }
                            }
                        }
                        .disabled(stockVM.tescoHistoryBusy)
                    }
                }
            }
            .fileImporter(
                isPresented: $showingTescoHistoryFileImporter,
                allowedContentTypes: [
                    .json,
                    UTType(filenameExtension: "zip") ?? .data,
                ]
            ) { result in
                switch result {
                case .success(let url):
                    Task { await stockVM.previewTescoHistory(at: url) }
                case .failure(let error):
                    if (error as? CocoaError)?.code != .userCancelled {
                        stockVM.reportTescoHistoryPickerError(error)
                    }
                }
            }
        }
    }

    private func historyMetric(_ value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.headline.monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var tescoHistoryRange: String? {
        guard let firstValue = stockVM.tescoHistorySummary.firstPurchasedAt,
              let lastValue = stockVM.tescoHistorySummary.lastPurchasedAt,
              let first = ISODateParser.parse(firstValue),
              let last = ISODateParser.parse(lastValue) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateFormat = "MMM yy"
        return "\(formatter.string(from: first))–\(formatter.string(from: last))"
    }

    private var tescoImportSheet: some View {
        NavigationStack {
            Form {
                Section("Paste Tesco Text") {
                    TextField("One item per line", text: $stockVM.tescoImportText, axis: .vertical)
                        .lineLimit(6...12)
                    Button {
                        Task {
                            await stockVM.parseTescoImportText()
                        }
                    } label: {
                        if stockVM.isProcessingTescoImport {
                            ProgressView()
                        } else {
                            Text("Parse & Match")
                        }
                    }
                    .disabled(stockVM.tescoImportText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || stockVM.isProcessingTescoImport)
                    .accessibilityLabel("Parse and match Tesco import text")
                }

                Section("Matches") {
                    if stockVM.tescoImportMatches.isEmpty {
                        Text("No parsed lines yet")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(stockVM.tescoImportMatches) { match in
                            HStack {
                                if match.matchedItemId != nil {
                                    Button {
                                        stockVM.toggleTescoImportLine(match.rawLine)
                                    } label: {
                                        Image(systemName: stockVM.tescoImportSelectedRawLines.contains(match.rawLine) ? "checkmark.square.fill" : "square")
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(stockVM.tescoImportSelectedRawLines.contains(match.rawLine) ? "Deselect \(match.rawLine)" : "Select \(match.rawLine)")
                                } else {
                                    Image(systemName: "exclamationmark.triangle")
                                        .foregroundStyle(.orange)
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(match.rawLine)
                                    Text(match.matchedItemName ?? "No match")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(MealHelpers.localizedImportConfidence(match.confidence))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Tesco Import")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        stockVM.showingTescoImport = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create Batch") {
                        Task {
                            await stockVM.createBatchFromTescoImport()
                        }
                    }
                    .disabled(stockVM.tescoImportSelectedRawLines.isEmpty || stockVM.isImportSavingBatch)
                }
            }
        }
    }

    private func batchDetailSheet(_ batch: PurchaseBatchDTO) -> some View {
        NavigationStack {
            List {
                Section {
                    Text(String(format: "Source: %@".localized, MealHelpers.localizedSource(batch.source)))
                    Text(String(format: "Purchased: %@".localized, String(batch.purchasedAt.prefix(10))))
                }
                Section("Lines") {
                    ForEach(batch.lines) { line in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(line.groceryItemName ?? "Unknown item")
                            Text("\(line.qty, specifier: "%.1f") \(line.unit) - \(MealHelpers.localizedStorage(line.storage ?? "fridge"))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(String(format: "Use by: %@".localized, line.useByDate ?? "Not set".localized))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Batch Detail")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        stockVM.selectedBatchDetail = nil
                    }
                }
            }
        }
    }

    private func groceryItemEditorSheet(_ item: GroceryItemListDTO) -> some View {
        NavigationStack {
            Form {
                Section("Item") {
                    TextField("Name", text: $stockVM.itemEditName)
                    TextField("Category", text: $stockVM.itemEditCategory)
                    TextField("Default unit", text: $stockVM.itemEditDefaultUnit)
                    TextField("Default quantity", text: $stockVM.itemEditDefaultQuantity)
                        .keyboardType(.decimalPad)
                    Toggle("Track use-by", isOn: $stockVM.itemEditUseByTracked)
                }
                Section("Matching") {
                    TextField("Aliases (comma separated)", text: $stockVM.itemEditAliases)
                    TextField("Tesco hint", text: $stockVM.itemEditTescoHint)
                }
                Section {
                    Button("Save Changes") {
                        Task {
                            await stockVM.saveEditedGroceryItem()
                        }
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Delete Item", role: .destructive) {
                        Task {
                            await stockVM.deleteEditedGroceryItem()
                        }
                    }
                }
            }
            .navigationTitle(item.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        stockVM.selectedGroceryItemForEdit = nil
                    }
                }
            }
        }
    }

    private var ratingsHistorySheet: some View {
        NavigationStack {
            List {
                Section("Filter") {
                    Picker("Child", selection: $planVM.ratingsHistoryChildFilter) {
                        Text("All").tag(String?.none)
                        ForEach(planVM.children) { child in
                            Text(child.name).tag(Optional(child.id))
                        }
                    }
                    .onChange(of: planVM.ratingsHistoryChildFilter) {
                        Task {
                            await planVM.loadRatingsHistory()
                        }
                    }
                }
                Section("Entries") {
                    if planVM.ratingsHistory.isEmpty {
                        Text("No ratings yet")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(planVM.ratingsHistory) { entry in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.childName ?? "Child")
                                    Text(entry.createdAt.prefix(10))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text("\(entry.rating)")
                                    .font(.headline)
                            }
                            .accessibilityLabel("\(entry.childName ?? "Child"), rating \(entry.rating)")
                        }
                    }
                }
            }
            .navigationTitle("Ratings History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        planVM.showingRatingsHistory = false
                    }
                }
            }
        }
    }

    // MARK: - Common Views

    @ScaledMetric(relativeTo: .title) private var emptyIconSize: CGFloat = 40

    private func loadingView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            ProgressView()
                .controlSize(.large)
            Text(message.localized)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func emptyStateView(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: emptyIconSize))
                .foregroundStyle(.secondary)
            Text(title.localized)
                .font(.headline)
                .foregroundStyle(.secondary)
            Text(subtitle.localized)
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

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
}

#Preview {
    MealsView()
}
