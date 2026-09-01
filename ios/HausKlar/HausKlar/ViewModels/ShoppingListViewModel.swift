import Foundation
import SwiftUI

@MainActor
final class ShoppingListViewModel: ObservableObject {

    @Published var shoppingItems: [ShoppingItemDTO] = []
    @Published var grocerySuggestions: [GrocerySuggestionDTO] = []
    @Published var selectedSuggestionIds: Set<String> = []
    @Published var groceryItems: [GroceryItemListDTO] = []

    @Published var isLoading = false
    @Published var isAcceptingSuggestions = false
    @Published var isClearingCompleted = false
    @Published var errorMessage: String?
    @Published var tescoSubpage = 0 // 0 replenishment, 1 final list
    @Published var showingPlanReview = false
    @Published var planDiff: ShoppingPlanDiffDTO?
    @Published var selectedPlanDiffKeys: Set<String> = []
    @Published var isReviewingPlan = false
    @Published var statusMessage: String?

    // Tesco import
    @Published var showingTescoImport = false
    @Published var tescoImportText = ""
    @Published var tescoImportMatches: [TescoImportMatchDTO] = []
    @Published var tescoImportSelectedRawLines: Set<String> = []
    @Published var isProcessingTescoImport = false
    @Published var isImportSavingBatch = false

    private let apiClient = APIClient.shared

    var groupedShoppingItems: [(category: String, items: [ShoppingItemDTO])] {
        let categorised = Dictionary(grouping: shoppingItems) { item in
            item.category ?? "Other"
        }
        return categorised
            .sorted { $0.key < $1.key }
            .map { (category: $0.key, items: $0.value.sorted { !$0.checked && $1.checked }) }
    }

    var completedItemCount: Int { Self.completedItemIDs(in: shoppingItems).count }

    static func completedItemIDs(in items: [ShoppingItemDTO]) -> [String] {
        items.filter(\.checked).map(\.id)
    }

    func loadShopping() async {
        isLoading = true
        errorMessage = nil

        do {
            let loaded: [ShoppingItemDTO] = try await apiClient.get("/meals/shopping")
            shoppingItems = loaded
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "Failed to load shopping list. Please try again.".localized
        }

        isLoading = false
    }

    func addItem(name: String, quantity: String? = nil, category: String? = nil) async {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        do {
            let created: ShoppingItemDTO = try await apiClient.post(
                "/meals/shopping",
                body: MealShoppingItemCreateRequest(
                    name: trimmedName,
                    quantity: quantity,
                    category: category
                )
            )
            shoppingItems.insert(created, at: 0)
            statusMessage = "\(trimmedName) added to shopping."
            HapticManager.success()
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "That item could not be added."
        }
    }

    func reviewWeek(start: Date, end: Date) async {
        isReviewingPlan = true
        errorMessage = nil
        defer { isReviewingPlan = false }
        do {
            let startText = MealFormatters.dateOnly.string(from: start)
            let endText = MealFormatters.dateOnly.string(from: end)
            let preview: ShoppingPlanDiffDTO = try await apiClient.get(
                "/meals/shopping/plan-diff",
                queryItems: [
                    URLQueryItem(name: "start", value: startText),
                    URLQueryItem(name: "end", value: endText),
                ]
            )
            planDiff = preview
            selectedPlanDiffKeys = Set(
                preview.items
                    .filter { !$0.alreadyOnList && !$0.likelyAtHome }
                    .map(\.key)
            )
            showingPlanReview = true
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "The ingredients could not be checked."
        }
    }

    func togglePlanDiffItem(_ key: String) {
        if selectedPlanDiffKeys.contains(key) {
            selectedPlanDiffKeys.remove(key)
        } else {
            selectedPlanDiffKeys.insert(key)
        }
    }

    func addReviewedIngredients() async {
        guard let planDiff, !selectedPlanDiffKeys.isEmpty else { return }
        isReviewingPlan = true
        errorMessage = nil
        defer { isReviewingPlan = false }
        do {
            let response: ApplyShoppingPlanDiffResponse = try await apiClient.post(
                "/meals/shopping/plan-diff/apply",
                body: ApplyShoppingPlanDiffRequest(
                    start: planDiff.start,
                    end: planDiff.end,
                    keys: Array(selectedPlanDiffKeys)
                )
            )
            showingPlanReview = false
            statusMessage = response.created.isEmpty
                ? "Shopping already covers those ingredients."
                : "\(response.created.count) ingredient\(response.created.count == 1 ? "" : "s") added to shopping."
            await loadShopping()
            HapticManager.success()
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "The ingredients could not be added."
        }
    }

    func loadTescoSuggestions() async {
        do {
            let suggestionsResult: GrocerySuggestionsResponseDTO = try await apiClient.get("/grocery/suggestions")
            grocerySuggestions = suggestionsResult.suggestions
            if selectedSuggestionIds.isEmpty {
                selectedSuggestionIds = Set(grocerySuggestions.map(\.groceryItemId))
            } else {
                selectedSuggestionIds = selectedSuggestionIds.intersection(Set(grocerySuggestions.map(\.groceryItemId)))
            }
        } catch {
            grocerySuggestions = []
            selectedSuggestionIds = []
        }
    }

    func loadGroceryItems() async {
        do {
            let items: [GroceryItemListDTO] = try await apiClient.get("/grocery/items", queryItems: [
                URLQueryItem(name: "limit", value: "200")
            ])
            groceryItems = items.sorted { $0.name < $1.name }
        } catch {
            // Keep existing items
        }
    }

    func toggleShoppingItem(_ id: String) async {
        do {
            let updated: ShoppingItemDTO = try await apiClient.patch("/meals/shopping/\(id)/check", body: EmptyBody())
            if let index = shoppingItems.firstIndex(where: { $0.id == id }) {
                shoppingItems[index] = updated
            }
        } catch APIError.offlineQueued {
            if let index = shoppingItems.firstIndex(where: { $0.id == id }) {
                let item = shoppingItems[index]
                shoppingItems[index] = ShoppingItemDTO(
                    id: item.id,
                    name: item.name,
                    quantity: item.quantity,
                    category: item.category,
                    checked: !item.checked
                )
            }
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "Failed to update item. Please try again.".localized
        }
    }

    func removeShoppingItem(_ id: String) async {
        do {
            try await apiClient.delete("/meals/shopping/\(id)")
            shoppingItems.removeAll { $0.id == id }
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "Failed to remove item.".localized
        }
    }

    /// Deletes only items the family has explicitly checked. Each delete is committed
    /// independently so an interrupted request never removes unchecked shopping.
    func clearCompletedItems() async {
        let ids = Self.completedItemIDs(in: shoppingItems)
        guard !ids.isEmpty, !isClearingCompleted else { return }

        isClearingCompleted = true
        errorMessage = nil
        var failedCount = 0

        for id in ids {
            do {
                try await apiClient.delete("/meals/shopping/\(id)")
                shoppingItems.removeAll { $0.id == id }
            } catch {
                failedCount += 1
            }
        }

        // Reconcile with the server even after a partial failure; unchecked items remain.
        await loadShopping()
        let reconciliationError = errorMessage
        await loadTescoSuggestions()
        isClearingCompleted = false

        if failedCount > 0 {
            errorMessage = failedCount == 1
                ? "One completed item could not be cleared. The list has been refreshed."
                : "\(failedCount) completed items could not be cleared. The list has been refreshed."
            HapticManager.error()
        } else if reconciliationError != nil {
            HapticManager.error()
        } else {
            HapticManager.success()
        }
    }

    func acceptAllSuggestions() async {
        guard !grocerySuggestions.isEmpty else { return }

        isAcceptingSuggestions = true
        defer { isAcceptingSuggestions = false }

        do {
            let _: AcceptSuggestionsResponse = try await apiClient.post(
                "/grocery/suggestions/accept",
                body: AcceptSuggestionsRequest(groceryItemIds: nil)
            )
            await loadShopping()
            await loadTescoSuggestions()
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "Failed to add grocery suggestions to shopping.".localized
        }
    }

    func toggleSuggestionSelection(_ groceryItemId: String) {
        if selectedSuggestionIds.contains(groceryItemId) {
            selectedSuggestionIds.remove(groceryItemId)
        } else {
            selectedSuggestionIds.insert(groceryItemId)
        }
    }

    func acceptSelectedSuggestions() async {
        guard !selectedSuggestionIds.isEmpty else { return }

        isAcceptingSuggestions = true
        defer { isAcceptingSuggestions = false }

        do {
            let _: AcceptSuggestionsResponse = try await apiClient.post(
                "/grocery/suggestions/accept",
                body: AcceptSuggestionsRequest(groceryItemIds: Array(selectedSuggestionIds))
            )
            await loadShopping()
            await loadTescoSuggestions()
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "Failed to add selected suggestions.".localized
        }
    }

    func acceptSingleSuggestion(_ groceryItemId: String) async {
        isAcceptingSuggestions = true
        defer { isAcceptingSuggestions = false }
        do {
            let _: AcceptSuggestionsResponse = try await apiClient.post(
                "/grocery/suggestions/accept",
                body: AcceptSuggestionsRequest(groceryItemIds: [groceryItemId])
            )
            grocerySuggestions.removeAll { $0.groceryItemId == groceryItemId }
            selectedSuggestionIds.remove(groceryItemId)
            await loadShopping()
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "Failed to add suggestion.".localized
        }
    }

    func dismissSuggestion(_ groceryItemId: String) {
        grocerySuggestions.removeAll { $0.groceryItemId == groceryItemId }
        selectedSuggestionIds.remove(groceryItemId)
    }

    func parseTescoImportText() async {
        let text = tescoImportText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            errorMessage = "Paste Tesco lines first.".localized
            return
        }
        isProcessingTescoImport = true
        defer { isProcessingTescoImport = false }

        do {
            let response: TescoImportResponseDTO = try await apiClient.post(
                "/grocery/import",
                body: TescoImportRequest(rawText: text)
            )
            tescoImportMatches = response.matches
            tescoImportSelectedRawLines = Set(response.matches.compactMap { $0.matchedItemId == nil ? nil : $0.rawLine })
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "Failed to parse Tesco text.".localized
        }
    }

    func toggleTescoImportLine(_ rawLine: String) {
        if tescoImportSelectedRawLines.contains(rawLine) {
            tescoImportSelectedRawLines.remove(rawLine)
        } else {
            tescoImportSelectedRawLines.insert(rawLine)
        }
    }

    func createBatchFromTescoImport() async {
        let selected = tescoImportMatches.filter {
            tescoImportSelectedRawLines.contains($0.rawLine) && $0.matchedItemId != nil
        }
        guard !selected.isEmpty else {
            errorMessage = "No matched lines selected.".localized
            return
        }
        isImportSavingBatch = true
        defer { isImportSavingBatch = false }

        do {
            let lines = selected.compactMap { match -> CreatePurchaseLineRequest? in
                guard let itemId = match.matchedItemId else { return nil }
                let unit = groceryItems.first(where: { $0.id == itemId })?.defaultUnit ?? "each"
                return CreatePurchaseLineRequest(
                    groceryItemId: itemId,
                    qty: 1.0,
                    unit: unit,
                    useByDate: nil,
                    storage: "fridge"
                )
            }
            let _: PurchaseBatchDTO = try await apiClient.post(
                "/grocery/batches",
                body: CreatePurchaseBatchRequest(
                    purchasedAt: MealFormatters.eventISO.string(from: Date()),
                    source: "tesco",
                    notes: "Imported from Tesco text",
                    lines: lines
                )
            )
            showingTescoImport = false
            tescoImportText = ""
            tescoImportMatches = []
            tescoImportSelectedRawLines = []
            await loadShopping()
            await loadTescoSuggestions()
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "Failed to create batch from import.".localized
        }
    }
}
