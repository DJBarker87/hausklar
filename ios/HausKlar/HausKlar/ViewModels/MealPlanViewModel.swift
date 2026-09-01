import Foundation
import SwiftUI

@MainActor
final class MealPlanViewModel: ObservableObject {

    @Published var mealPlans: [MealPlanDTO] = []
    @Published var meals: [MealDTO] = []
    @Published var children: [ChildDTO] = []

    @Published var recommendations: [RecommendedMealDTO] = []
    @Published var mealContext: MealContextDTO?
    @Published var tonightContextPreview: MealContextDTO?
    @Published var recommendationForAnotherDay: RecommendedMealDTO?
    @Published var recommendationDate = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
    @Published var recommendationBeingSavedId: String?
    @Published var statusMessage: String?

    @Published var isLoading = false
    @Published var isSubmittingRatings = false
    @Published var errorMessage: String?

    @Published var expandedPlanDateKeys: Set<String> = []
    @Published var slotAssignmentContext: SlotAssignmentContext?
    @Published var selectedPlanForRating: MealPlanDTO?
    @Published var ratingsByChildId: [String: Int] = [:]
    @Published var tiredHouseholdForRating = false

    // Slot assignment form state
    @Published var slotMealSearchText = ""
    @Published var slotCreateMealName = ""
    @Published var slotCreateMealDescription = ""
    @Published var slotCreateMealTagsText = ""
    @Published var slotCreateMealTags: [String] = []
    @Published var slotCreateIngredients: [MealIngredientDraft] = []
    @Published var slotCreateMode = 0

    // Ratings history
    @Published var showingRatingsHistory = false
    @Published var ratingsHistory: [MealRatingHistoryDTO] = []
    @Published var ratingsHistoryChildFilter: String?

    private let apiClient = APIClient.shared

    var weekDays: [Date] { MealHelpers.weekDays }

    func loadMealPlans() async {
        guard let startDate = weekDays.first, let endDate = weekDays.last else { return }

        let start = MealFormatters.dateOnly.string(from: startDate)
        let end = MealFormatters.dateOnly.string(from: endDate)

        isLoading = true
        errorMessage = nil

        do {
            let loaded: [MealPlanDTO] = try await apiClient.get(
                "/meals/plan",
                queryItems: [
                    URLQueryItem(name: "start", value: start),
                    URLQueryItem(name: "end", value: end)
                ]
            )
            mealPlans = loaded
            if let today = weekDays.first(where: { Calendar.current.isDateInToday($0) }) {
                expandedPlanDateKeys.insert(MealFormatters.dateOnly.string(from: today))
            }
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "Failed to load meal plan. Please try again.".localized
        }

        isLoading = false
    }

    func loadMeals() async {
        do {
            let loaded: [MealDTO] = try await apiClient.get("/meals/")
            meals = loaded
        } catch {
            // Keep existing meals if refresh fails
        }
    }

    func loadChildren() async {
        do {
            let loaded: [ChildDTO] = try await apiClient.get("/children/")
            children = loaded.sorted(by: { $0.name < $1.name })
        } catch {
            children = []
        }
    }

    func loadTonightInsights() async {
        isLoading = true
        errorMessage = nil

        let date = MealFormatters.dateOnly.string(from: Date())
        async let recommendationsResult: RecommendationsResponseDTO = apiClient.get(
            "/meals/recommendations",
            queryItems: [URLQueryItem(name: "date", value: date)]
        )
        async let contextPreviewResult: RecommendationsContextPreviewDTO = apiClient.get(
            "/meals/recommendations/contextPreview",
            queryItems: [URLQueryItem(name: "date", value: date)]
        )
        async let mealsResult: [MealDTO] = apiClient.get("/meals/")
        async let plansResult: [MealPlanDTO] = apiClient.get(
            "/meals/plan",
            queryItems: [
                URLQueryItem(name: "start", value: date),
                URLQueryItem(name: "end", value: date),
            ]
        )

        do {
            let response = try await recommendationsResult
            let contextPreviewWrapper = try await contextPreviewResult
            let loadedMeals = try await mealsResult
            let loadedPlans = try await plansResult
            recommendations = response.recommendations
            mealContext = response.context
            tonightContextPreview = contextPreviewWrapper.context
            meals = loadedMeals
            mealPlans = loadedPlans
        } catch let error as APIError {
            errorMessage = error.errorDescription
            recommendations = []
            mealContext = nil
            tonightContextPreview = nil
        } catch {
            errorMessage = "Failed to load tonight recommendations.".localized
            recommendations = []
            mealContext = nil
            tonightContextPreview = nil
        }

        isLoading = false
    }

    var tonightDinner: MealPlanDTO? {
        let today = MealFormatters.dateOnly.string(from: Date())
        return mealPlans.first { $0.date == today && $0.mealType == "dinner" }
    }

    func meal(for recommendation: RecommendedMealDTO) -> MealDTO? {
        meals.first { $0.id == recommendation.mealId }
    }

    func chooseRecommendation(
        _ recommendation: RecommendedMealDTO,
        action: String,
        date: Date? = nil
    ) async {
        recommendationBeingSavedId = recommendation.mealId
        errorMessage = nil
        defer { recommendationBeingSavedId = nil }
        do {
            let targetDate = date.map { MealFormatters.dateOnly.string(from: $0) }
            let response: RecommendationDecisionResponse = try await apiClient.post(
                "/meals/recommendations/\(recommendation.mealId)/decision",
                body: RecommendationDecisionRequest(action: action, date: targetDate)
            )
            statusMessage = response.message
            recommendationForAnotherDay = nil
            HapticManager.success()
            await loadTonightInsights()
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "That dinner choice could not be saved."
        }
    }

    func isDayExpanded(_ date: Date) -> Bool {
        expandedPlanDateKeys.contains(MealFormatters.dateOnly.string(from: date))
    }

    func toggleDayExpanded(_ date: Date) {
        let key = MealFormatters.dateOnly.string(from: date)
        if expandedPlanDateKeys.contains(key) {
            expandedPlanDateKeys.remove(key)
        } else {
            expandedPlanDateKeys.insert(key)
        }
    }

    func planForSlot(date: Date, mealType: String) -> MealPlanDTO? {
        let dateString = MealFormatters.dateOnly.string(from: date)
        return mealPlans.first(where: { $0.date == dateString && $0.mealType == mealType })
    }

    func breakfastPlanForChild(date: Date, childId: String) -> MealPlanDTO? {
        let dateString = MealFormatters.dateOnly.string(from: date)
        return mealPlans.first { plan in
            plan.date == dateString &&
            plan.mealType == "breakfast" &&
            MealHelpers.breakfastAssignedChildId(from: plan.notes) == childId
        }
    }

    func plansFor(date: Date, mealType: String) -> [MealPlanDTO] {
        let dateString = MealFormatters.dateOnly.string(from: date)
        return mealPlans.filter { $0.date == dateString && $0.mealType == mealType }
    }

    func startSlotAssignment(date: Date, mealType: String, childId: String? = nil, childName: String? = nil) {
        let dateString = MealFormatters.dateOnly.string(from: date)
        slotAssignmentContext = SlotAssignmentContext(date: dateString, mealType: mealType, childId: childId, childName: childName)
        slotMealSearchText = ""
        slotCreateMealName = ""
        slotCreateMealDescription = ""
        slotCreateMealTagsText = ""
        slotCreateMealTags = []
        slotCreateIngredients = []
        slotCreateMode = 0
    }

    func slotFilteredMeals() -> [MealDTO] {
        let query = slotMealSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if query.isEmpty {
            return meals.sorted(by: { $0.name < $1.name })
        }
        return meals.filter { meal in
            meal.name.lowercased().contains(query) ||
            (meal.description?.lowercased().contains(query) ?? false) ||
            (meal.tags?.lowercased().contains(query) ?? false)
        }
        .sorted(by: { $0.name < $1.name })
    }

    func assignMealToSlot(mealId: String, date: String, mealType: String, childId: String? = nil) async {
        if mealType == "breakfast" && (childId == nil || childId?.isEmpty == true) {
            errorMessage = "Choose a child for breakfast.".localized
            return
        }
        do {
            let existing = mealPlans.filter { plan in
                guard plan.date == date && plan.mealType == mealType else { return false }
                if mealType == "breakfast", let childId {
                    return MealHelpers.breakfastAssignedChildId(from: plan.notes) == childId
                }
                return true
            }
            for plan in existing {
                try await apiClient.delete("/meals/plan/\(plan.id)")
            }

            let notes: String? = (mealType == "breakfast") ? childId.map { "child:\($0)" } : nil
            let _: MealPlanDTO = try await apiClient.post(
                "/meals/plan",
                body: CreateMealPlanRequest(mealId: mealId, date: date, mealType: mealType, notes: notes)
            )
            await loadMealPlans()
            slotAssignmentContext = nil
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "Failed to assign meal.".localized
        }
    }

    func createAndAssignMealForCurrentSlot() async {
        guard let context = slotAssignmentContext else { return }
        let name = slotCreateMealName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            errorMessage = "Please enter a meal name.".localized
            return
        }

        let ingredientsPayload: [[String: String]] = slotCreateIngredients.map { ingredient in
            [
                "name": ingredient.name,
                "quantity": ingredient.quantity,
                "category": ingredient.category,
            ]
        }

        do {
            let created: MealDTO = try await apiClient.post(
                "/meals/",
                body: CreateMealRequest(
                    name: name,
                    description: slotCreateMealDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? nil
                        : slotCreateMealDescription.trimmingCharacters(in: .whitespacesAndNewlines),
                    recipeUrl: nil,
                    tags: slotCreateMealTags.isEmpty ? nil : slotCreateMealTags,
                    ingredients: ingredientsPayload.isEmpty ? nil : ingredientsPayload
                )
            )
            meals.append(created)
            await assignMealToSlot(
                mealId: created.id,
                date: context.date,
                mealType: context.mealType,
                childId: context.childId
            )
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "Failed to create and assign meal.".localized
        }
    }

    func prepareRatings(for plan: MealPlanDTO) async {
        selectedPlanForRating = plan
        tiredHouseholdForRating = plan.tiredHousehold
        var initial: [String: Int] = [:]
        if plan.mealType == "breakfast",
           let childId = MealHelpers.breakfastAssignedChildId(from: plan.notes) {
            initial[childId] = 2
        } else {
            for child in children {
                initial[child.id] = 2
            }
        }
        ratingsByChildId = initial

        do {
            let response: MealPlanWithRatingsDTO = try await apiClient.get("/meals/plan/\(plan.id)/ratings")
            for rating in response.ratings {
                if ratingsByChildId.keys.contains(rating.childId) || plan.mealType != "breakfast" {
                    ratingsByChildId[rating.childId] = rating.rating
                }
            }
        } catch {
            // Keep defaults if prefill fetch fails.
        }
    }

    func ratingBinding(for childId: String) -> Binding<Int> {
        Binding(
            get: { self.ratingsByChildId[childId] ?? 2 },
            set: { self.ratingsByChildId[childId] = min(max($0, 1), 3) }
        )
    }

    func submitRatingsForSelectedPlan() async {
        guard let plan = selectedPlanForRating else { return }
        guard !ratingsByChildId.isEmpty else {
            errorMessage = "No child ratings to submit.".localized
            return
        }

        isSubmittingRatings = true
        defer { isSubmittingRatings = false }

        let ratings = ratingsByChildId.map { MealRatingInputRequest(childId: $0.key, rating: $0.value) }

        do {
            let _: MealPlanDTO = try await apiClient.post(
                "/meals/plan/\(plan.id)/ratings",
                body: SubmitMealRatingsRequest(ratings: ratings, tiredHousehold: tiredHouseholdForRating)
            )
            selectedPlanForRating = nil
            ratingsByChildId = [:]
            await loadMealPlans()
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "Failed to submit ratings.".localized
        }
    }

    func loadRatingsHistory() async {
        do {
            var query: [URLQueryItem] = [URLQueryItem(name: "limit", value: "200")]
            if let childId = ratingsHistoryChildFilter, !childId.isEmpty {
                query.append(URLQueryItem(name: "child_id", value: childId))
            }
            let history: [MealRatingHistoryDTO] = try await apiClient.get(
                "/meals/ratings/history",
                queryItems: query
            )
            ratingsHistory = history
        } catch let error as APIError {
            errorMessage = error.errorDescription
            ratingsHistory = []
        } catch {
            errorMessage = "Failed to load rating history.".localized
            ratingsHistory = []
        }
    }
}
