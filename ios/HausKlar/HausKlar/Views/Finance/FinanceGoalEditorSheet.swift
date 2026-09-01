import SwiftUI

struct FinanceGoalEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    let goal: FinanceGoalSummaryDTO?
    let isSaving: Bool
    let onSave: (String, Int, String, Int, String) async -> Bool

    @State private var name: String
    @State private var target: String
    @State private var allocated: String
    @State private var deadline: Date
    @State private var currency: String
    @State private var validationMessage: String?

    init(
        goal: FinanceGoalSummaryDTO?,
        defaultCurrency: String,
        isSaving: Bool,
        onSave: @escaping (String, Int, String, Int, String) async -> Bool
    ) {
        self.goal = goal
        self.isSaving = isSaving
        self.onSave = onSave
        _name = State(initialValue: goal?.name ?? "")
        _target = State(initialValue: Self.decimalText(goal?.targetMinor))
        _allocated = State(initialValue: Self.decimalText(goal?.currentlyAllocatedMinor))
        _deadline = State(
            initialValue: goal.flatMap { ISODateParser.parse($0.deadline) }
                ?? Calendar.current.date(byAdding: .year, value: 1, to: Date())
                ?? Date()
        )
        _currency = State(initialValue: goal?.currency ?? defaultCurrency)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Goal") {
                    TextField("What are you saving for?", text: $name)
                        .textInputAutocapitalization(.sentences)
                    HStack {
                        Text(currency.uppercased())
                            .foregroundStyle(.secondary)
                        TextField("Target amount", text: $target)
                            .keyboardType(.decimalPad)
                    }
                    HStack {
                        Text(currency.uppercased())
                            .foregroundStyle(.secondary)
                        TextField("Already saved", text: $allocated)
                            .keyboardType(.decimalPad)
                    }
                    DatePicker("Target date", selection: $deadline, displayedComponents: .date)
                    TextField("Currency", text: $currency)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                }

                Section {
                    Text("This changes the target only. Monthly plan choices stay tucked away until you ask to compare them.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let validationMessage {
                    Section {
                        Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle((goal == nil ? "Add Goal" : "Edit Goal").localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button((isSaving ? "Saving…" : "Save").localized) {
                        Task { await save() }
                    }
                    .disabled(isSaving)
                }
            }
        }
    }

    private func save() async {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanCurrency = currency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !cleanName.isEmpty else {
            validationMessage = "Give this goal a name.".localized
            return
        }
        guard let targetMinor = Self.minorUnits(target), targetMinor > 0 else {
            validationMessage = "Enter a target greater than zero.".localized
            return
        }
        guard let allocatedMinor = Self.minorUnits(allocated), allocatedMinor >= 0 else {
            validationMessage = "Enter zero or a positive amount already saved.".localized
            return
        }
        guard cleanCurrency.count == 3 else {
            validationMessage = "Use a three-letter currency code such as GBP.".localized
            return
        }
        validationMessage = nil
        let saved = await onSave(
            cleanName,
            targetMinor,
            Self.dateText(deadline),
            allocatedMinor,
            cleanCurrency
        )
        if !saved {
            validationMessage = "That goal could not be saved. Check the details and try again.".localized
        }
    }

    private static func minorUnits(_ value: String) -> Int? {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard let decimal = Decimal(string: clean), decimal >= 0 else { return nil }
        let number = NSDecimalNumber(decimal: decimal * 100)
        guard number != .notANumber else { return nil }
        let rounded = number.rounding(
            accordingToBehavior: NSDecimalNumberHandler(
                roundingMode: .plain,
                scale: 0,
                raiseOnExactness: false,
                raiseOnOverflow: false,
                raiseOnUnderflow: false,
                raiseOnDivideByZero: false
            ))
        guard rounded == number else { return nil }
        return rounded.intValue
    }

    private static func decimalText(_ minor: Int?) -> String {
        guard let minor else { return "" }
        return String(format: "%.2f", Double(minor) / 100)
    }

    private static func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
