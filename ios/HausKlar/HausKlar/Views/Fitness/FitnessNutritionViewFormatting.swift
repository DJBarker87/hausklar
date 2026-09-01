import Foundation

enum FitnessNutritionViewFormatting {
    /// A compact, factual bit of positive feedback after logging food. Protein
    /// and fibre are more useful than repeating the food name; calories remain
    /// a neutral fallback when those nutrients are unknown.
    static func addedHighlight(for entry: FitnessFoodLogEntry) -> String? {
        if let protein = entry.proteinG, protein >= 5 {
            return "\(compact(protein)) g protein"
        }
        if let fibre = entry.fibreG, fibre >= 2 {
            return "\(compact(fibre)) g fibre"
        }
        if let protein = entry.proteinG, protein > 0 {
            return "\(compact(protein)) g protein"
        }
        if let calories = entry.kcal, calories > 0 {
            return "\(Int(calories.rounded())) kcal logged"
        }
        return nil
    }

    static func nutritionValue(
        _ values: FitnessNutritionValues,
        _ metric: FitnessNutritionMetric
    ) -> Double? {
        switch metric {
        case .caloriesKcal: values.caloriesKcal
        case .proteinG: values.proteinG
        case .carbohydrateG: values.carbohydrateG
        case .fibreG: values.fibreG
        case .fatG: values.fatG
        case .saturatedFatG: values.saturatedFatG
        case .sugarsG: values.sugarsG
        case .saltG: values.saltG
        }
    }

    static func displayTarget(_ target: FitnessNutritionTarget?) -> Double? {
        guard let target else { return nil }
        switch target.mode {
        case .range: return target.targetMax ?? target.targetMin
        case .trainingRest: return target.restDayValue
        default: return target.targetValue
        }
    }

    static func targetDescription(_ target: FitnessNutritionTarget) -> String {
        let unit = target.metric.unit
        switch target.mode {
        case .range:
            return "\(target.targetMin?.formatted() ?? "?")–\(target.targetMax?.formatted() ?? "?") \(unit) daily"
        case .trainingRest:
            return "\(target.trainingDayValue?.formatted() ?? "?") training · \(target.restDayValue?.formatted() ?? "?") rest \(unit)"
        case .weeklyAverage:
            return "\(target.targetValue?.formatted() ?? "?") \(unit) weekly average"
        case .phase:
            return "\(target.targetValue?.formatted() ?? "?") \(unit) for phase"
        case .fixed:
            return "\(target.targetValue?.formatted() ?? "?") \(unit) daily"
        }
    }

    static func nutrientLine(_ values: FitnessNutritionValues) -> String {
        let line = [
            values.caloriesKcal.map { "\($0.formatted()) kcal" },
            values.proteinG.map { "P \($0.formatted()) g" },
            values.carbohydrateG.map { "C \($0.formatted()) g" },
            values.fatG.map { "F \($0.formatted()) g" },
            values.fibreG.map { "fibre \($0.formatted()) g" },
        ].compactMap { $0 }.joined(separator: " · ")
        return line.isEmpty ? "Nutrients unknown" : line
    }

    static func number(_ value: String) -> Double? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let number = Double(trimmed), number.isFinite else {
            return nil
        }
        return number
    }

    static func emptyNil(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func dayString(_ date: Date) -> String {
        ISODateParser.stringDateOnly(from: date)
    }

    private static func compact(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        return rounded.formatted(.number.precision(.fractionLength(0...1)))
    }
}
