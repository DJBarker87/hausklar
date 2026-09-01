import SwiftUI

struct MealDetailSheet: View {
    @ObservedObject var libraryVM: MealLibraryViewModel
    @ObservedObject var planVM: MealPlanViewModel
    let meal: MealDTO

    @State private var assignDate: Date = Date()
    @State private var assignMealType: String = "dinner"
    @State private var assignBreakfastChildId: String?

    private var currentMeal: MealDTO {
        libraryVM.meals.first(where: { $0.id == meal.id }) ?? meal
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(currentMeal.name)
                        .font(.headline)
                    if let description = currentMeal.description, !description.isEmpty {
                        Text(description)
                            .foregroundStyle(.secondary)
                    }
                    if let prep = currentMeal.prepMinutes {
                        Text(String(format: "Prep: %d minutes".localized, prep))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let servings = currentMeal.servings {
                        Text("Feeds \(servings)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let url = SafeExternalURL.web(currentMeal.recipeUrl) {
                        Link(destination: url) {
                            Label("Open recipe", systemImage: "safari")
                        }
                    }
                }

                Section("Ingredients") {
                    let ingredients = MealHelpers.parseIngredients(currentMeal.ingredients)
                    if ingredients.isEmpty {
                        Text("No ingredients listed")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(ingredients) { ingredient in
                            HStack {
                                Text(ingredient.name)
                                Spacer()
                                if let quantity = ingredient.quantity, !quantity.isEmpty {
                                    Text(quantity)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                Section("Assign to Plan") {
                    DatePicker("Day", selection: $assignDate, displayedComponents: .date)
                    Picker("Meal", selection: $assignMealType) {
                        Text("Breakfast").tag("breakfast")
                        Text("Lunch").tag("lunch")
                        Text("Dinner").tag("dinner")
                    }
                    .pickerStyle(.segmented)
                    .accessibilityLabel("Meal type selector")

                    if assignMealType == "breakfast" {
                        Picker("Child", selection: $assignBreakfastChildId) {
                            Text("Select child").tag(String?.none)
                            ForEach(planVM.children) { child in
                                Text(child.name).tag(Optional(child.id))
                            }
                        }
                    }

                    Button("Assign Meal") {
                        let dateString = MealFormatters.dateOnly.string(from: assignDate)
                        Task {
                            await planVM.assignMealToSlot(
                                mealId: meal.id,
                                date: dateString,
                                mealType: assignMealType,
                                childId: assignMealType == "breakfast" ? assignBreakfastChildId : nil
                            )
                            if planVM.errorMessage == nil {
                                libraryVM.selectedMealForDetail = nil
                            }
                        }
                    }
                    .disabled(assignMealType == "breakfast" && (assignBreakfastChildId == nil || assignBreakfastChildId?.isEmpty == true))
                    .accessibilityLabel("Assign \(meal.name) to meal plan")
                }

                if let allergies = currentMeal.allergyNotes, !allergies.isEmpty {
                    Section("Safety Notes") {
                        Text(allergies)
                    }
                }

                if let preferences = currentMeal.preferenceNotes, !preferences.isEmpty {
                    Section("What Works for the Family") {
                        Text(preferences)
                    }
                }

                Section {
                    Toggle(
                        "Include in dinner suggestions",
                        isOn: Binding(
                            get: { !(currentMeal.notForUs ?? false) },
                            set: { value in Task { await libraryVM.setSuggested(value, for: currentMeal) } }
                        )
                    )
                }
            }
            .navigationTitle("Meal Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        libraryVM.selectedMealForDetail = nil
                    }
                }
                ToolbarItemGroup(placement: .confirmationAction) {
                    Button("Edit") {
                        libraryVM.beginEditing(meal)
                    }
                    Menu {
                        Button("Remove meal", role: .destructive) {
                            Task { await libraryVM.removeMeal(meal) }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("More meal actions")
                }
            }
            .task {
                if planVM.children.isEmpty {
                    await planVM.loadChildren()
                }
            }
        }
    }
}
