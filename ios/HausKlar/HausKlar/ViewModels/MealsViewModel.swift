import Foundation
import SwiftUI

// MARK: - MealsViewModel (Legacy Coordinator)
// This class is retained for backward compatibility. New code should use
// MealLibraryViewModel, MealPlanViewModel, ShoppingListViewModel, or StockViewModel directly.
// All DTOs have been moved to DTOs/MealDTOs.swift.

@MainActor
final class MealsViewModel: ObservableObject {

    @Published var selectedTab = 0  // 0 meals, 1 plan, 2 shopping, 3 grocery, 4 tonight

    // Aggregate error from any sub-VM
    var errorMessage: String? {
        switch selectedTab {
        case 0: return libraryVM.errorMessage
        case 1: return planVM.errorMessage
        case 2: return shoppingVM.errorMessage
        case 3: return stockVM.errorMessage
        case 4: return planVM.errorMessage
        default: return nil
        }
    }

    let libraryVM = MealLibraryViewModel()
    let planVM = MealPlanViewModel()
    let shoppingVM = ShoppingListViewModel()
    let stockVM = StockViewModel()
}
