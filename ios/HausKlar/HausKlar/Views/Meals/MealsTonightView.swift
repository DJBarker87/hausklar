import SwiftUI

/// State-free presentation of the existing meal-plan view-model's tonight decision.
struct MealsTonightView: View {
    @ObservedObject var planVM: MealPlanViewModel

    var body: some View {
        Group {
            if planVM.isLoading && planVM.recommendations.isEmpty && planVM.tonightDinner == nil {
                loadingView("Finding easy dinner choices...")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Tonight")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)
                            HStack(alignment: .center, spacing: 12) {
                                Image(systemName: "fork.knife.circle.fill")
                                    .font(.largeTitle)
                                    .foregroundStyle(.orange)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(planVM.tonightDinner?.mealName ?? "Dinner is not planned")
                                        .font(.title2.bold())
                                    if let dinner = planVM.tonightDinner,
                                        let meal = planVM.meals.first(where: { $0.id == dinner.mealId }),
                                        let minutes = meal.prepMinutes
                                    {
                                        Text("\(minutes) minutes to prepare")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                            }
                            HStack {
                                if let dinner = planVM.tonightDinner,
                                    let meal = planVM.meals.first(where: { $0.id == dinner.mealId }),
                                    let url = SafeExternalURL.web(meal.recipeUrl)
                                {
                                    Link(destination: url) {
                                        Label("Recipe", systemImage: "safari")
                                    }
                                    .buttonStyle(.bordered)
                                }
                                Button {
                                    planVM.startSlotAssignment(date: Date(), mealType: "dinner")
                                } label: {
                                    Label(planVM.tonightDinner == nil ? "Choose dinner" : "Change", systemImage: "plus")
                                }
                                .buttonStyle(.borderedProminent)
                            }
                        }
                        .padding(16)
                        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
                        .padding(.horizontal)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(planVM.tonightDinner == nil ? "Choose dinner" : "Other good options")
                                .font(.title3.bold())
                            Text("One tap saves the choice for everyone.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal)

                        if planVM.recommendations.filter({ $0.mealId != planVM.tonightDinner?.mealId }).isEmpty {
                            ContentUnavailableView(
                                "No suggestions yet",
                                systemImage: "sparkles",
                                description: Text("Add a few family meals and this decision will become quicker.")
                            )
                            .padding(.horizontal)
                        } else {
                            ForEach(planVM.recommendations.filter { $0.mealId != planVM.tonightDinner?.mealId }.prefix(5)) {
                                recommendation in
                                VStack(alignment: .leading, spacing: 10) {
                                    Text(recommendation.mealName)
                                        .font(.headline)
                                    if let reason = recommendation.reasons.first {
                                        Text(reason)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }

                                    ViewThatFits(in: .horizontal) {
                                        HStack(spacing: 8) {
                                            recommendationActions(recommendation)
                                        }
                                        VStack(alignment: .leading, spacing: 8) {
                                            recommendationActions(recommendation)
                                        }
                                    }
                                }
                                .padding(14)
                                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
                                .padding(.horizontal)
                            }
                        }
                    }
                    .padding(.bottom)
                    .frame(maxWidth: 700)
                    .frame(maxWidth: .infinity)
                }
                .refreshable {
                    await planVM.loadTonightInsights()
                }
            }
        }
    }

    @ViewBuilder
    private func recommendationActions(_ recommendation: RecommendedMealDTO) -> some View {
        Button("Use tonight") {
            Task { await planVM.chooseRecommendation(recommendation, action: "use_tonight") }
        }
        .buttonStyle(.borderedProminent)
        .disabled(planVM.recommendationBeingSavedId == recommendation.mealId)

        Button("Another day") {
            planVM.recommendationDate = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
            planVM.recommendationForAnotherDay = recommendation
        }
        .buttonStyle(.bordered)

        if let meal = planVM.meal(for: recommendation),
            let url = SafeExternalURL.web(meal.recipeUrl)
        {
            Link("Recipe", destination: url)
                .buttonStyle(.bordered)
        }

        Menu {
            Button("Skip in future suggestions") {
                Task { await planVM.chooseRecommendation(recommendation, action: "not_for_us") }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .frame(minWidth: 32, minHeight: 32)
        }
        .accessibilityLabel("More choices for \(recommendation.mealName)")
    }
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
}
