import Foundation
import SwiftUI

@MainActor
final class MealLibraryViewModel: ObservableObject {

    @Published var meals: [MealDTO] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var showingAddMeal = false

    @Published var searchText = ""

    // Add meal form
    @Published var formName = ""
    @Published var formDescription = ""
    @Published var formRecipeURL = ""
    @Published var formTags: [String] = []
    @Published var formPrepMinutes = ""
    @Published var formServings = ""
    @Published var formAllergyNotes = ""
    @Published var formPreferenceNotes = ""
    @Published var formIngredients: [MealIngredientDraft] = []
    @Published var editingMealId: String?

    @Published var showingRecipeImport = false
    @Published var recipeImportText = ""
    @Published var recipeImportURL = ""
    @Published var isReadingRecipe = false
    @Published var removedMeal: MealDTO?
    @Published var statusMessage: String?

    // Meal detail
    @Published var selectedMealForDetail: MealDTO?

    private let apiClient = APIClient.shared

    var filteredMeals: [MealDTO] {
        guard !searchText.trimmingCharacters(in: .whitespaces).isEmpty else {
            return meals
        }
        let query = searchText.lowercased()
        return meals.filter { meal in
            meal.name.lowercased().contains(query) ||
            (meal.tags?.lowercased().contains(query) ?? false) ||
            (meal.description?.lowercased().contains(query) ?? false)
        }
    }

    func loadMeals() async {
        isLoading = true
        errorMessage = nil

        do {
            let loaded: [MealDTO] = try await apiClient.get("/meals/")
            meals = loaded
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "Failed to load meals. Please try again.".localized
        }

        isLoading = false
    }

    func saveMeal() async {
        guard !formName.trimmingCharacters(in: .whitespaces).isEmpty else {
            errorMessage = "Please enter a meal name.".localized
            return
        }

        let trimmedDescription = formDescription.trimmingCharacters(in: .whitespaces)
        let trimmedURL = formRecipeURL.trimmingCharacters(in: .whitespaces)

        let ingredientPayload = formIngredients
            .filter { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { ingredient in
                [
                    "name": ingredient.name.trimmingCharacters(in: .whitespacesAndNewlines),
                    "quantity": ingredient.quantity.trimmingCharacters(in: .whitespacesAndNewlines),
                    "category": ingredient.category.trimmingCharacters(in: .whitespacesAndNewlines),
                ]
            }
        let prepMinutes = Int(formPrepMinutes.trimmingCharacters(in: .whitespacesAndNewlines))
        let servings = Int(formServings.trimmingCharacters(in: .whitespacesAndNewlines))
        let allergyNotes = formAllergyNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        let preferenceNotes = formPreferenceNotes.trimmingCharacters(in: .whitespacesAndNewlines)

        let body = CreateMealRequest(
            name: formName.trimmingCharacters(in: .whitespaces),
            description: trimmedDescription.isEmpty ? nil : trimmedDescription,
            recipeUrl: trimmedURL.isEmpty ? nil : trimmedURL,
            tags: formTags.isEmpty ? nil : formTags,
            ingredients: ingredientPayload.isEmpty ? nil : ingredientPayload,
            prepMinutes: prepMinutes,
            servings: servings,
            allergyNotes: allergyNotes.isEmpty ? nil : allergyNotes,
            preferenceNotes: preferenceNotes.isEmpty ? nil : preferenceNotes
        )

        isLoading = true
        errorMessage = nil

        do {
            if let editingMealId {
                let updated: MealDTO = try await apiClient.put(
                    "/meals/\(editingMealId)",
                    body: UpdateMealRequest(
                        name: body.name,
                        description: body.description,
                        recipeUrl: body.recipeUrl,
                        tags: body.tags ?? [],
                        ingredients: body.ingredients ?? [],
                        prepMinutes: body.prepMinutes,
                        servings: body.servings,
                        allergyNotes: body.allergyNotes,
                        preferenceNotes: body.preferenceNotes,
                        notForUs: nil,
                        replacingDetails: true
                    )
                )
                if let index = meals.firstIndex(where: { $0.id == updated.id }) {
                    meals[index] = updated
                }
                statusMessage = "Meal updated."
            } else {
                let created: MealDTO = try await apiClient.post("/meals/", body: body)
                meals.append(created)
                statusMessage = "Meal added."
            }
            meals.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            showingAddMeal = false
            resetForm()
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "Failed to create meal. Please try again.".localized
        }

        isLoading = false
    }

    func resetForm() {
        editingMealId = nil
        formName = ""
        formDescription = ""
        formRecipeURL = ""
        formTags = []
        formPrepMinutes = ""
        formServings = ""
        formAllergyNotes = ""
        formPreferenceNotes = ""
        formIngredients = []
    }

    func beginEditing(_ meal: MealDTO) {
        editingMealId = meal.id
        formName = meal.name
        formDescription = meal.description ?? ""
        formRecipeURL = meal.recipeUrl ?? ""
        formTags = MealHelpers.parseTags(meal.tags)
        formPrepMinutes = meal.prepMinutes.map(String.init) ?? ""
        formServings = meal.servings.map(String.init) ?? ""
        formAllergyNotes = meal.allergyNotes ?? ""
        formPreferenceNotes = meal.preferenceNotes ?? ""
        formIngredients = MealHelpers.parseIngredients(meal.ingredients).map { ingredient in
            var draft = MealIngredientDraft()
            draft.name = ingredient.name
            draft.quantity = ingredient.quantity ?? ""
            draft.category = ingredient.category ?? ""
            return draft
        }
        selectedMealForDetail = nil
        showingAddMeal = true
    }

    func previewRecipe() async {
        let text = recipeImportText.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = recipeImportURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !url.isEmpty else {
            errorMessage = "Paste recipe text or add its web address."
            return
        }
        isReadingRecipe = true
        errorMessage = nil
        defer { isReadingRecipe = false }
        do {
            let preview: RecipePreviewDTO = try await apiClient.post(
                "/meals/recipe-preview",
                body: RecipePreviewRequest(text: text.isEmpty ? nil : text, recipeUrl: url.isEmpty ? nil : url)
            )
            resetForm()
            formName = preview.name
            formRecipeURL = preview.recipeUrl ?? ""
            formPrepMinutes = preview.prepMinutes.map(String.init) ?? ""
            formServings = preview.servings.map(String.init) ?? ""
            formIngredients = preview.ingredients.map { ingredient in
                var draft = MealIngredientDraft()
                draft.name = ingredient.name
                draft.quantity = ingredient.quantity ?? ""
                draft.category = ingredient.category ?? ""
                return draft
            }
            recipeImportText = ""
            recipeImportURL = ""
            showingRecipeImport = false
            showingAddMeal = true
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "That recipe could not be read."
        }
    }

    func removeMeal(_ meal: MealDTO) async {
        do {
            try await apiClient.delete("/meals/\(meal.id)")
            meals.removeAll { $0.id == meal.id }
            selectedMealForDetail = nil
            removedMeal = meal
            statusMessage = "\(meal.name) removed."
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "The meal could not be removed."
        }
    }

    func restoreRemovedMeal() async {
        guard let removedMeal else { return }
        do {
            let restored: MealDTO = try await apiClient.post("/meals/\(removedMeal.id)/restore", body: EmptyBody())
            meals.append(restored)
            meals.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            self.removedMeal = nil
            statusMessage = "\(restored.name) is back."
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "The meal could not be restored."
        }
    }

    func setSuggested(_ suggested: Bool, for meal: MealDTO) async {
        do {
            let updated: MealDTO = try await apiClient.put(
                "/meals/\(meal.id)",
                body: UpdateMealRequest(
                    name: nil,
                    description: nil,
                    recipeUrl: nil,
                    tags: nil,
                    ingredients: nil,
                    prepMinutes: nil,
                    servings: nil,
                    allergyNotes: nil,
                    preferenceNotes: nil,
                    notForUs: !suggested
                )
            )
            if let index = meals.firstIndex(where: { $0.id == updated.id }) {
                meals[index] = updated
            }
            selectedMealForDetail = updated
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "That dinner preference could not be saved."
        }
    }
}
