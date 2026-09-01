import Foundation
import SwiftData

// MARK: - Frozen released schemas

/// The original LegacyHausKlar SwiftData shape from a private pre-release revision. This store predates
/// VersionedSchema and persisted timestamps as ISO-8601 strings. Keep these
/// definitions exact: they are useful for recognising and inspecting a legacy
/// store even though automatic conversion to V2 is deliberately unsupported.
enum HausKlarSchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)
    static let provenanceCommit = "a private pre-release revision"

    @Model
    final class CalendarEvent {
        @Attribute(.unique) var id: String
        var title: String
        var eventDescription: String?
        var startTime: String
        var endTime: String
        var allDay: Bool
        var recurrenceRule: String?
        var location: String?
        var familyMemberIds: String?
        var createdAt: String
        var updatedAt: String
        var createdBy: String?
        var deletedAt: String?

        init() {
            id = UUID().uuidString
            title = ""
            eventDescription = nil
            startTime = ""
            endTime = ""
            allDay = false
            recurrenceRule = nil
            location = nil
            familyMemberIds = nil
            createdAt = ""
            updatedAt = ""
            createdBy = nil
            deletedAt = nil
        }
    }

    @Model
    final class FamilyTask {
        @Attribute(.unique) var id: String
        var title: String
        var taskDescription: String?
        var assignedTo: String?
        var dueDate: String?
        var completedAt: String?
        var category: String?
        var recurrenceRule: String?
        var priority: Int
        var createdAt: String
        var updatedAt: String
        var createdBy: String?
        var deletedAt: String?

        init() {
            id = UUID().uuidString
            title = ""
            taskDescription = nil
            assignedTo = nil
            dueDate = nil
            completedAt = nil
            category = nil
            recurrenceRule = nil
            priority = 1
            createdAt = ""
            updatedAt = ""
            createdBy = nil
            deletedAt = nil
        }
    }

    @Model
    final class MedicineType {
        @Attribute(.unique) var id: String
        var name: String
        var minHoursBetweenDoses: Double
        var maxDoses24h: Int
        var notes: String?
        var childId: String?
        var createdAt: String
        var updatedAt: String
        var createdBy: String?
        var deletedAt: String?

        init() {
            id = UUID().uuidString
            name = ""
            minHoursBetweenDoses = 4
            maxDoses24h = 4
            notes = nil
            childId = nil
            createdAt = ""
            updatedAt = ""
            createdBy = nil
            deletedAt = nil
        }
    }

    @Model
    final class MedicineDose {
        @Attribute(.unique) var id: String
        var medicineTypeId: String
        var childId: String
        var givenAt: String
        var givenBy: String?
        var doseAmount: String?
        var notes: String?
        var createdAt: String
        var updatedAt: String
        var createdBy: String?
        var deletedAt: String?

        init() {
            id = UUID().uuidString
            medicineTypeId = ""
            childId = ""
            givenAt = ""
            givenBy = nil
            doseAmount = nil
            notes = nil
            createdAt = ""
            updatedAt = ""
            createdBy = nil
            deletedAt = nil
        }
    }

    @Model
    final class Nap {
        @Attribute(.unique) var id: String
        var childId: String
        var startedAt: String
        var endedAt: String?
        var location: String?
        var notes: String?
        var createdAt: String
        var updatedAt: String
        var createdBy: String?
        var deletedAt: String?

        init() {
            id = UUID().uuidString
            childId = ""
            startedAt = ""
            endedAt = nil
            location = nil
            notes = nil
            createdAt = ""
            updatedAt = ""
            createdBy = nil
            deletedAt = nil
        }
    }

    @Model
    final class DogActivity {
        @Attribute(.unique) var id: String
        var activityType: String
        var startedAt: String
        var endedAt: String?
        var notes: String?
        var doneBy: String?
        var createdAt: String
        var updatedAt: String
        var createdBy: String?
        var deletedAt: String?

        init() {
            id = UUID().uuidString
            activityType = "walk"
            startedAt = ""
            endedAt = nil
            notes = nil
            doneBy = nil
            createdAt = ""
            updatedAt = ""
            createdBy = nil
            deletedAt = nil
        }
    }

    @Model
    final class Birthday {
        @Attribute(.unique) var id: String
        var personName: String
        var dateOfBirth: String
        var relationship: String?
        var reminderDaysBefore: Int
        var createdAt: String
        var updatedAt: String
        var createdBy: String?
        var deletedAt: String?

        init() {
            id = UUID().uuidString
            personName = ""
            dateOfBirth = ""
            relationship = nil
            reminderDaysBefore = 7
            createdAt = ""
            updatedAt = ""
            createdBy = nil
            deletedAt = nil
        }
    }

    @Model
    final class Meal {
        @Attribute(.unique) var id: String
        var name: String
        var mealDescription: String?
        var recipeURL: String?
        var tags: String?
        var ingredients: String?
        var lastMadeAt: String?
        var createdAt: String
        var updatedAt: String
        var createdBy: String?
        var deletedAt: String?

        init() {
            id = UUID().uuidString
            name = ""
            mealDescription = nil
            recipeURL = nil
            tags = nil
            ingredients = nil
            lastMadeAt = nil
            createdAt = ""
            updatedAt = ""
            createdBy = nil
            deletedAt = nil
        }
    }

    @Model
    final class MealPlan {
        @Attribute(.unique) var id: String
        var mealId: String
        var date: String
        var mealType: String
        var createdAt: String
        var updatedAt: String
        var createdBy: String?
        var deletedAt: String?

        init() {
            id = UUID().uuidString
            mealId = ""
            date = ""
            mealType = "dinner"
            createdAt = ""
            updatedAt = ""
            createdBy = nil
            deletedAt = nil
        }
    }

    @Model
    final class ShoppingItem {
        @Attribute(.unique) var id: String
        var name: String
        var quantity: String?
        var category: String?
        var mealPlanId: String?
        var checked: Bool
        var createdAt: String
        var updatedAt: String
        var createdBy: String?
        var deletedAt: String?

        init() {
            id = UUID().uuidString
            name = ""
            quantity = nil
            category = nil
            mealPlanId = nil
            checked = false
            createdAt = ""
            updatedAt = ""
            createdBy = nil
            deletedAt = nil
        }
    }

    @Model
    final class HealthRecord {
        @Attribute(.unique) var id: String
        var source: String
        var dataType: String
        var value: Double
        var unit: String
        var recordedAt: String
        var metadata: String?
        var createdAt: String
        var updatedAt: String
        var createdBy: String?
        var deletedAt: String?

        init() {
            id = UUID().uuidString
            source = ""
            dataType = ""
            value = 0
            unit = ""
            recordedAt = ""
            metadata = nil
            createdAt = ""
            updatedAt = ""
            createdBy = nil
            deletedAt = nil
        }
    }

    @Model
    final class ReadingLog {
        @Attribute(.unique) var id: String
        var childId: String
        var bookTitle: String
        var minutes: Int
        var date: String
        var notes: String?
        var createdAt: String
        var updatedAt: String
        var createdBy: String?
        var deletedAt: String?

        init() {
            id = UUID().uuidString
            childId = ""
            bookTitle = ""
            minutes = 0
            date = ""
            notes = nil
            createdAt = ""
            updatedAt = ""
            createdBy = nil
            deletedAt = nil
        }
    }

    @Model
    final class SpellingEntry {
        @Attribute(.unique) var id: String
        var childId: String
        var wordList: String
        var testDate: String?
        var score: Int?
        var practiceCount: Int
        var createdAt: String
        var updatedAt: String
        var createdBy: String?
        var deletedAt: String?

        init() {
            id = UUID().uuidString
            childId = ""
            wordList = "[]"
            testDate = nil
            score = nil
            practiceCount = 0
            createdAt = ""
            updatedAt = ""
            createdBy = nil
            deletedAt = nil
        }
    }

    @Model
    final class GrowthRecord {
        @Attribute(.unique) var id: String
        var childId: String
        var date: String
        var heightCm: Double?
        var weightKg: Double?
        var headCircumferenceCm: Double?
        var notes: String?
        var createdAt: String
        var updatedAt: String
        var createdBy: String?
        var deletedAt: String?

        init() {
            id = UUID().uuidString
            childId = ""
            date = ""
            heightCm = nil
            weightKg = nil
            headCircumferenceCm = nil
            notes = nil
            createdAt = ""
            updatedAt = ""
            createdBy = nil
            deletedAt = nil
        }
    }

    @Model
    final class Child {
        @Attribute(.unique) var id: String
        var name: String
        var dateOfBirth: String
        var notes: String?
        var createdAt: String
        var updatedAt: String
        var createdBy: String?
        var deletedAt: String?

        init() {
            id = UUID().uuidString
            name = ""
            dateOfBirth = ""
            notes = nil
            createdAt = ""
            updatedAt = ""
            createdBy = nil
            deletedAt = nil
        }
    }

    @Model
    final class OfflineAction {
        @Attribute(.unique) var id: String
        var operation: String
        var tableName: String
        var recordId: String
        var payload: String
        var createdAt: String
        var status: String
        var retryCount: Int

        init() {
            id = UUID().uuidString
            operation = "create"
            tableName = ""
            recordId = ""
            payload = "{}"
            createdAt = ""
            status = "pending"
            retryCount = 0
        }
    }

    static let models: [any PersistentModel.Type] = [
        CalendarEvent.self,
        FamilyTask.self,
        MedicineType.self,
        MedicineDose.self,
        Nap.self,
        DogActivity.self,
        Birthday.self,
        Meal.self,
        MealPlan.self,
        ShoppingItem.self,
        HealthRecord.self,
        ReadingLog.self,
        SpellingEntry.self,
        GrowthRecord.self,
        Child.self,
        OfflineAction.self,
    ]
}

/// First versioned HausKlar schema, frozen from 452727d.
enum HausKlarSchemaV2: VersionedSchema {
    static let versionIdentifier = Schema.Version(2, 0, 0)
    static let provenanceCommit = "452727d"

    @Model
    final class CalendarEvent {
        @Attribute(.unique) var id: String
        var title: String
        var eventDescription: String?
        var startTime: Date
        var endTime: Date
        var allDay: Bool
        var recurrenceRule: String?
        var location: String?
        var familyMemberIds: String?
        var createdAt: Date
        var updatedAt: Date
        var createdBy: String?
        var deletedAt: Date?
        var assignedTo: String?

        init() {
            id = UUID().uuidString
            title = ""
            eventDescription = nil
            startTime = Date()
            endTime = Date()
            allDay = false
            recurrenceRule = nil
            location = nil
            familyMemberIds = nil
            createdAt = Date()
            updatedAt = Date()
            createdBy = nil
            deletedAt = nil
            assignedTo = nil
        }
    }

    @Model
    final class FamilyTask {
        @Attribute(.unique) var id: String
        var title: String
        var taskDescription: String?
        var assignedTo: String?
        var dueDate: Date?
        var completedAt: Date?
        var category: String?
        var recurrenceRule: String?
        var priority: Int
        var createdAt: Date
        var updatedAt: Date
        var createdBy: String?
        var deletedAt: Date?
        var assigneesJSON: String?

        init() {
            id = UUID().uuidString
            title = ""
            taskDescription = nil
            assignedTo = nil
            dueDate = nil
            completedAt = nil
            category = nil
            recurrenceRule = nil
            priority = 1
            createdAt = Date()
            updatedAt = Date()
            createdBy = nil
            deletedAt = nil
            assigneesJSON = nil
        }
    }

    @Model
    final class Child {
        @Attribute(.unique) var id: String
        var name: String
        var dateOfBirth: Date
        var notes: String?
        var createdAt: Date
        var updatedAt: Date
        var createdBy: String?
        var deletedAt: Date?

        init() {
            id = UUID().uuidString
            name = ""
            dateOfBirth = Date()
            notes = nil
            createdAt = Date()
            updatedAt = Date()
            createdBy = nil
            deletedAt = nil
        }
    }

    @Model
    final class MedicineType {
        @Attribute(.unique) var id: String
        var name: String
        var minHoursBetweenDoses: Double
        var maxDoses24h: Int
        var notes: String?
        var color: String?
        var defaultDoseAmount: String?
        var childId: String?
        var createdAt: Date
        var updatedAt: Date
        var createdBy: String?
        var deletedAt: Date?

        init() {
            id = UUID().uuidString
            name = ""
            minHoursBetweenDoses = 4
            maxDoses24h = 4
            notes = nil
            color = nil
            defaultDoseAmount = nil
            childId = nil
            createdAt = Date()
            updatedAt = Date()
            createdBy = nil
            deletedAt = nil
        }
    }

    @Model
    final class MedicineDose {
        @Attribute(.unique) var id: String
        var medicineTypeId: String
        var childId: String
        var givenAt: Date
        var givenBy: String?
        var doseAmount: String?
        var notes: String?
        var createdAt: Date
        var updatedAt: Date
        var createdBy: String?
        var deletedAt: Date?

        init() {
            id = UUID().uuidString
            medicineTypeId = ""
            childId = ""
            givenAt = Date()
            givenBy = nil
            doseAmount = nil
            notes = nil
            createdAt = Date()
            updatedAt = Date()
            createdBy = nil
            deletedAt = nil
        }
    }

    @Model
    final class Nap {
        @Attribute(.unique) var id: String
        var childId: String
        var startedAt: Date
        var endedAt: Date?
        var location: String?
        var notes: String?
        var createdAt: Date
        var updatedAt: Date
        var createdBy: String?
        var deletedAt: Date?

        init() {
            id = UUID().uuidString
            childId = ""
            startedAt = Date()
            endedAt = nil
            location = nil
            notes = nil
            createdAt = Date()
            updatedAt = Date()
            createdBy = nil
            deletedAt = nil
        }
    }

    @Model
    final class DogActivity {
        @Attribute(.unique) var id: String
        var activityType: String
        var startedAt: Date
        var endedAt: Date?
        var notes: String?
        var doneBy: String?
        var createdAt: Date
        var updatedAt: Date
        var createdBy: String?
        var deletedAt: Date?

        init() {
            id = UUID().uuidString
            activityType = "walk"
            startedAt = Date()
            endedAt = nil
            notes = nil
            doneBy = nil
            createdAt = Date()
            updatedAt = Date()
            createdBy = nil
            deletedAt = nil
        }
    }

    @Model
    final class Birthday {
        @Attribute(.unique) var id: String
        var personName: String
        var dateOfBirth: Date
        var relationship: String?
        var reminderDaysBefore: Int
        var createdAt: Date
        var updatedAt: Date
        var createdBy: String?
        var deletedAt: Date?

        init() {
            id = UUID().uuidString
            personName = ""
            dateOfBirth = Date()
            relationship = nil
            reminderDaysBefore = 7
            createdAt = Date()
            updatedAt = Date()
            createdBy = nil
            deletedAt = nil
        }
    }

    @Model
    final class Meal {
        @Attribute(.unique) var id: String
        var name: String
        var mealDescription: String?
        var recipeURL: String?
        var tags: String?
        var ingredients: String?
        var lastMadeAt: Date?
        var createdAt: Date
        var updatedAt: Date
        var createdBy: String?
        var deletedAt: Date?

        init() {
            id = UUID().uuidString
            name = ""
            mealDescription = nil
            recipeURL = nil
            tags = nil
            ingredients = nil
            lastMadeAt = nil
            createdAt = Date()
            updatedAt = Date()
            createdBy = nil
            deletedAt = nil
        }
    }

    @Model
    final class MealPlan {
        @Attribute(.unique) var id: String
        var mealId: String
        var date: Date
        var mealType: String
        var createdAt: Date
        var updatedAt: Date
        var createdBy: String?
        var deletedAt: Date?

        init() {
            id = UUID().uuidString
            mealId = ""
            date = Date()
            mealType = "dinner"
            createdAt = Date()
            updatedAt = Date()
            createdBy = nil
            deletedAt = nil
        }
    }

    @Model
    final class ShoppingItem {
        @Attribute(.unique) var id: String
        var name: String
        var quantity: String?
        var category: String?
        var mealPlanId: String?
        var checked: Bool
        var createdAt: Date
        var updatedAt: Date
        var createdBy: String?
        var deletedAt: Date?

        init() {
            id = UUID().uuidString
            name = ""
            quantity = nil
            category = nil
            mealPlanId = nil
            checked = false
            createdAt = Date()
            updatedAt = Date()
            createdBy = nil
            deletedAt = nil
        }
    }

    @Model
    final class HealthRecord {
        @Attribute(.unique) var id: String
        var source: String
        var dataType: String
        var value: Double
        var unit: String
        var recordedAt: Date
        var metadata: String?
        var createdAt: Date
        var updatedAt: Date
        var createdBy: String?
        var deletedAt: Date?

        init() {
            id = UUID().uuidString
            source = ""
            dataType = ""
            value = 0
            unit = ""
            recordedAt = Date()
            metadata = nil
            createdAt = Date()
            updatedAt = Date()
            createdBy = nil
            deletedAt = nil
        }
    }

    @Model
    final class ReadingLog {
        @Attribute(.unique) var id: String
        var childId: String
        var bookTitle: String
        var minutes: Int
        var date: Date
        var notes: String?
        var createdAt: Date
        var updatedAt: Date
        var createdBy: String?
        var deletedAt: Date?

        init() {
            id = UUID().uuidString
            childId = ""
            bookTitle = ""
            minutes = 0
            date = Date()
            notes = nil
            createdAt = Date()
            updatedAt = Date()
            createdBy = nil
            deletedAt = nil
        }
    }

    @Model
    final class SpellingEntry {
        @Attribute(.unique) var id: String
        var childId: String
        var wordList: String
        var testDate: Date?
        var score: Int?
        var practiceCount: Int
        var createdAt: Date
        var updatedAt: Date
        var createdBy: String?
        var deletedAt: Date?

        init() {
            id = UUID().uuidString
            childId = ""
            wordList = "[]"
            testDate = nil
            score = nil
            practiceCount = 0
            createdAt = Date()
            updatedAt = Date()
            createdBy = nil
            deletedAt = nil
        }
    }

    @Model
    final class GrowthRecord {
        @Attribute(.unique) var id: String
        var childId: String
        var date: Date
        var heightCm: Double?
        var weightKg: Double?
        var headCircumferenceCm: Double?
        var notes: String?
        var createdAt: Date
        var updatedAt: Date
        var createdBy: String?
        var deletedAt: Date?

        init() {
            id = UUID().uuidString
            childId = ""
            date = Date()
            heightCm = nil
            weightKg = nil
            headCircumferenceCm = nil
            notes = nil
            createdAt = Date()
            updatedAt = Date()
            createdBy = nil
            deletedAt = nil
        }
    }

    @Model
    final class OfflineAction {
        @Attribute(.unique) var id: String
        var operation: OfflineOperation
        var tableName: String
        var recordId: String
        var payload: String
        var createdAt: Date
        var status: OfflineStatus
        var retryCount: Int

        init() {
            id = UUID().uuidString
            operation = .create
            tableName = ""
            recordId = ""
            payload = "{}"
            createdAt = Date()
            status = .pending
            retryCount = 0
        }
    }

    @Model
    final class RoutineItem {
        @Attribute(.unique) var id: String
        var personId: String
        var name: String
        var color: String
        var daysOfWeek: String
        var sortOrder: Int
        var createdAt: Date
        var updatedAt: Date
        var createdBy: String?
        var deletedAt: Date?

        init() {
            id = UUID().uuidString
            personId = ""
            name = ""
            color = "#FF6B6B"
            daysOfWeek = "[]"
            sortOrder = 0
            createdAt = Date()
            updatedAt = Date()
            createdBy = nil
            deletedAt = nil
        }
    }

    static let models: [any PersistentModel.Type] = [
        CalendarEvent.self,
        FamilyTask.self,
        Child.self,
        MedicineType.self,
        MedicineDose.self,
        Nap.self,
        DogActivity.self,
        Birthday.self,
        Meal.self,
        MealPlan.self,
        ShoppingItem.self,
        HealthRecord.self,
        ReadingLog.self,
        SpellingEntry.self,
        GrowthRecord.self,
        OfflineAction.self,
        RoutineItem.self,
    ]
}
/// Universal-capture schema, frozen from eb3e660.
enum HausKlarSchemaV3: VersionedSchema {
    static let versionIdentifier = Schema.Version(3, 0, 0)
    static let provenanceCommit = "eb3e660"

    @Model
    final class CalendarEvent {
        @Attribute(.unique) var id: String
        var title: String
        var eventDescription: String?
        var startTime: Date
        var endTime: Date
        var allDay: Bool
        var recurrenceRule: String?
        var location: String?
        var familyMemberIds: String?
        var createdAt: Date
        var updatedAt: Date
        var createdBy: String?
        var deletedAt: Date?
        var assignedTo: String?

        init() {
            id = UUID().uuidString
            title = ""
            eventDescription = nil
            startTime = Date()
            endTime = Date()
            allDay = false
            recurrenceRule = nil
            location = nil
            familyMemberIds = nil
            createdAt = Date()
            updatedAt = Date()
            createdBy = nil
            deletedAt = nil
            assignedTo = nil
        }
    }

    @Model
    final class FamilyTask {
        @Attribute(.unique) var id: String
        var title: String
        var taskDescription: String?
        var assignedTo: String?
        var dueDate: Date?
        var completedAt: Date?
        var category: String?
        var recurrenceRule: String?
        var priority: Int
        var createdAt: Date
        var updatedAt: Date
        var createdBy: String?
        var deletedAt: Date?
        var assigneesJSON: String?

        init() {
            id = UUID().uuidString
            title = ""
            taskDescription = nil
            assignedTo = nil
            dueDate = nil
            completedAt = nil
            category = nil
            recurrenceRule = nil
            priority = 1
            createdAt = Date()
            updatedAt = Date()
            createdBy = nil
            deletedAt = nil
            assigneesJSON = nil
        }
    }

    @Model
    final class Child {
        @Attribute(.unique) var id: String
        var name: String
        var dateOfBirth: Date
        var notes: String?
        var createdAt: Date
        var updatedAt: Date
        var createdBy: String?
        var deletedAt: Date?

        init() {
            id = UUID().uuidString
            name = ""
            dateOfBirth = Date()
            notes = nil
            createdAt = Date()
            updatedAt = Date()
            createdBy = nil
            deletedAt = nil
        }
    }

    @Model
    final class MedicineType {
        @Attribute(.unique) var id: String
        var name: String
        var minHoursBetweenDoses: Double
        var maxDoses24h: Int
        var notes: String?
        var color: String?
        var defaultDoseAmount: String?
        var childId: String?
        var createdAt: Date
        var updatedAt: Date
        var createdBy: String?
        var deletedAt: Date?

        init() {
            id = UUID().uuidString
            name = ""
            minHoursBetweenDoses = 4
            maxDoses24h = 4
            notes = nil
            color = nil
            defaultDoseAmount = nil
            childId = nil
            createdAt = Date()
            updatedAt = Date()
            createdBy = nil
            deletedAt = nil
        }
    }

    @Model
    final class MedicineDose {
        @Attribute(.unique) var id: String
        var medicineTypeId: String
        var childId: String
        var givenAt: Date
        var givenBy: String?
        var doseAmount: String?
        var notes: String?
        var createdAt: Date
        var updatedAt: Date
        var createdBy: String?
        var deletedAt: Date?

        init() {
            id = UUID().uuidString
            medicineTypeId = ""
            childId = ""
            givenAt = Date()
            givenBy = nil
            doseAmount = nil
            notes = nil
            createdAt = Date()
            updatedAt = Date()
            createdBy = nil
            deletedAt = nil
        }
    }

    @Model
    final class Nap {
        @Attribute(.unique) var id: String
        var childId: String
        var startedAt: Date
        var endedAt: Date?
        var location: String?
        var notes: String?
        var createdAt: Date
        var updatedAt: Date
        var createdBy: String?
        var deletedAt: Date?

        init() {
            id = UUID().uuidString
            childId = ""
            startedAt = Date()
            endedAt = nil
            location = nil
            notes = nil
            createdAt = Date()
            updatedAt = Date()
            createdBy = nil
            deletedAt = nil
        }
    }

    @Model
    final class DogActivity {
        @Attribute(.unique) var id: String
        var activityType: String
        var startedAt: Date
        var endedAt: Date?
        var notes: String?
        var doneBy: String?
        var createdAt: Date
        var updatedAt: Date
        var createdBy: String?
        var deletedAt: Date?

        init() {
            id = UUID().uuidString
            activityType = "walk"
            startedAt = Date()
            endedAt = nil
            notes = nil
            doneBy = nil
            createdAt = Date()
            updatedAt = Date()
            createdBy = nil
            deletedAt = nil
        }
    }

    @Model
    final class Birthday {
        @Attribute(.unique) var id: String
        var personName: String
        var dateOfBirth: Date
        var relationship: String?
        var reminderDaysBefore: Int
        var createdAt: Date
        var updatedAt: Date
        var createdBy: String?
        var deletedAt: Date?

        init() {
            id = UUID().uuidString
            personName = ""
            dateOfBirth = Date()
            relationship = nil
            reminderDaysBefore = 7
            createdAt = Date()
            updatedAt = Date()
            createdBy = nil
            deletedAt = nil
        }
    }

    @Model
    final class Meal {
        @Attribute(.unique) var id: String
        var name: String
        var mealDescription: String?
        var recipeURL: String?
        var tags: String?
        var ingredients: String?
        var lastMadeAt: Date?
        var createdAt: Date
        var updatedAt: Date
        var createdBy: String?
        var deletedAt: Date?

        init() {
            id = UUID().uuidString
            name = ""
            mealDescription = nil
            recipeURL = nil
            tags = nil
            ingredients = nil
            lastMadeAt = nil
            createdAt = Date()
            updatedAt = Date()
            createdBy = nil
            deletedAt = nil
        }
    }

    @Model
    final class MealPlan {
        @Attribute(.unique) var id: String
        var mealId: String
        var date: Date
        var mealType: String
        var createdAt: Date
        var updatedAt: Date
        var createdBy: String?
        var deletedAt: Date?

        init() {
            id = UUID().uuidString
            mealId = ""
            date = Date()
            mealType = "dinner"
            createdAt = Date()
            updatedAt = Date()
            createdBy = nil
            deletedAt = nil
        }
    }

    @Model
    final class ShoppingItem {
        @Attribute(.unique) var id: String
        var name: String
        var quantity: String?
        var category: String?
        var mealPlanId: String?
        var checked: Bool
        var createdAt: Date
        var updatedAt: Date
        var createdBy: String?
        var deletedAt: Date?

        init() {
            id = UUID().uuidString
            name = ""
            quantity = nil
            category = nil
            mealPlanId = nil
            checked = false
            createdAt = Date()
            updatedAt = Date()
            createdBy = nil
            deletedAt = nil
        }
    }

    @Model
    final class HealthRecord {
        @Attribute(.unique) var id: String
        var source: String
        var dataType: String
        var value: Double
        var unit: String
        var recordedAt: Date
        var metadata: String?
        var createdAt: Date
        var updatedAt: Date
        var createdBy: String?
        var deletedAt: Date?

        init() {
            id = UUID().uuidString
            source = ""
            dataType = ""
            value = 0
            unit = ""
            recordedAt = Date()
            metadata = nil
            createdAt = Date()
            updatedAt = Date()
            createdBy = nil
            deletedAt = nil
        }
    }

    @Model
    final class ReadingLog {
        @Attribute(.unique) var id: String
        var childId: String
        var bookTitle: String
        var minutes: Int
        var date: Date
        var notes: String?
        var createdAt: Date
        var updatedAt: Date
        var createdBy: String?
        var deletedAt: Date?

        init() {
            id = UUID().uuidString
            childId = ""
            bookTitle = ""
            minutes = 0
            date = Date()
            notes = nil
            createdAt = Date()
            updatedAt = Date()
            createdBy = nil
            deletedAt = nil
        }
    }

    @Model
    final class SpellingEntry {
        @Attribute(.unique) var id: String
        var childId: String
        var wordList: String
        var testDate: Date?
        var score: Int?
        var practiceCount: Int
        var createdAt: Date
        var updatedAt: Date
        var createdBy: String?
        var deletedAt: Date?

        init() {
            id = UUID().uuidString
            childId = ""
            wordList = "[]"
            testDate = nil
            score = nil
            practiceCount = 0
            createdAt = Date()
            updatedAt = Date()
            createdBy = nil
            deletedAt = nil
        }
    }

    @Model
    final class GrowthRecord {
        @Attribute(.unique) var id: String
        var childId: String
        var date: Date
        var heightCm: Double?
        var weightKg: Double?
        var headCircumferenceCm: Double?
        var notes: String?
        var createdAt: Date
        var updatedAt: Date
        var createdBy: String?
        var deletedAt: Date?

        init() {
            id = UUID().uuidString
            childId = ""
            date = Date()
            heightCm = nil
            weightKg = nil
            headCircumferenceCm = nil
            notes = nil
            createdAt = Date()
            updatedAt = Date()
            createdBy = nil
            deletedAt = nil
        }
    }

    @Model
    final class OfflineAction {
        @Attribute(.unique) var id: String
        var operation: OfflineOperation
        var tableName: String
        var recordId: String
        var payload: String
        var createdAt: Date
        var status: OfflineStatus
        var retryCount: Int

        init() {
            id = UUID().uuidString
            operation = .create
            tableName = ""
            recordId = ""
            payload = "{}"
            createdAt = Date()
            status = .pending
            retryCount = 0
        }
    }

    @Model
    final class RoutineItem {
        @Attribute(.unique) var id: String
        var personId: String
        var name: String
        var color: String
        var daysOfWeek: String
        var sortOrder: Int
        var createdAt: Date
        var updatedAt: Date
        var createdBy: String?
        var deletedAt: Date?

        init() {
            id = UUID().uuidString
            personId = ""
            name = ""
            color = "#FF6B6B"
            daysOfWeek = "[]"
            sortOrder = 0
            createdAt = Date()
            updatedAt = Date()
            createdBy = nil
            deletedAt = nil
        }
    }

    @Model
    final class PendingDocumentUpload {
        @Attribute(.unique) var id: String
        var filePath: String
        var filename: String
        var mediaType: String
        var title: String
        var source: String
        var category: String
        var documentDate: String?
        var pageCount: Int
        var extractedText: String?
        var notes: String?
        var personIdsJSON: String
        var suggestionsJSON: String
        var useHermes: Bool
        var status: DocumentUploadStatus
        var errorMessage: String?
        var createdAt: Date

        init() {
            id = UUID().uuidString
            filePath = ""
            filename = ""
            mediaType = ""
            title = ""
            source = ""
            category = ""
            documentDate = nil
            pageCount = 1
            extractedText = nil
            notes = nil
            personIdsJSON = "[]"
            suggestionsJSON = "[]"
            useHermes = true
            status = .pending
            errorMessage = nil
            createdAt = Date()
        }
    }

    static let models: [any PersistentModel.Type] = [
        CalendarEvent.self,
        FamilyTask.self,
        Child.self,
        MedicineType.self,
        MedicineDose.self,
        Nap.self,
        DogActivity.self,
        Birthday.self,
        Meal.self,
        MealPlan.self,
        ShoppingItem.self,
        HealthRecord.self,
        ReadingLog.self,
        SpellingEntry.self,
        GrowthRecord.self,
        OfflineAction.self,
        RoutineItem.self,
        PendingDocumentUpload.self,
    ]
}

/// Fitness-release application schema, frozen from d8b16d7.
enum HausKlarSchemaV4: VersionedSchema {
    static let versionIdentifier = Schema.Version(4, 0, 0)
    static let provenanceCommit = "d8b16d7"

    @Model
    final class CalendarEvent {
        @Attribute(.unique) var id: String
        var title: String
        var eventDescription: String?
        var startTime: Date
        var endTime: Date
        var allDay: Bool
        var recurrenceRule: String?
        var location: String?
        var familyMemberIds: String?
        var createdAt: Date
        var updatedAt: Date
        var createdBy: String?
        var deletedAt: Date?
        var assignedTo: String?

        init() {
            id = UUID().uuidString
            title = ""
            eventDescription = nil
            startTime = Date()
            endTime = Date()
            allDay = false
            recurrenceRule = nil
            location = nil
            familyMemberIds = nil
            createdAt = Date()
            updatedAt = Date()
            createdBy = nil
            deletedAt = nil
            assignedTo = nil
        }
    }

    @Model
    final class FamilyTask {
        @Attribute(.unique) var id: String
        var title: String
        var taskDescription: String?
        var assignedTo: String?
        var dueDate: Date?
        var completedAt: Date?
        var category: String?
        var recurrenceRule: String?
        var priority: Int
        var createdAt: Date
        var updatedAt: Date
        var createdBy: String?
        var deletedAt: Date?
        var assigneesJSON: String?

        init() {
            id = UUID().uuidString
            title = ""
            taskDescription = nil
            assignedTo = nil
            dueDate = nil
            completedAt = nil
            category = nil
            recurrenceRule = nil
            priority = 1
            createdAt = Date()
            updatedAt = Date()
            createdBy = nil
            deletedAt = nil
            assigneesJSON = nil
        }
    }

    @Model
    final class Child {
        @Attribute(.unique) var id: String
        var name: String
        var dateOfBirth: Date
        var notes: String?
        var createdAt: Date
        var updatedAt: Date
        var createdBy: String?
        var deletedAt: Date?

        init() {
            id = UUID().uuidString
            name = ""
            dateOfBirth = Date()
            notes = nil
            createdAt = Date()
            updatedAt = Date()
            createdBy = nil
            deletedAt = nil
        }
    }

    @Model
    final class MedicineType {
        @Attribute(.unique) var id: String
        var name: String
        var minHoursBetweenDoses: Double
        var maxDoses24h: Int
        var notes: String?
        var color: String?
        var defaultDoseAmount: String?
        var childId: String?
        var createdAt: Date
        var updatedAt: Date
        var createdBy: String?
        var deletedAt: Date?

        init() {
            id = UUID().uuidString
            name = ""
            minHoursBetweenDoses = 4
            maxDoses24h = 4
            notes = nil
            color = nil
            defaultDoseAmount = nil
            childId = nil
            createdAt = Date()
            updatedAt = Date()
            createdBy = nil
            deletedAt = nil
        }
    }

    @Model
    final class MedicineDose {
        @Attribute(.unique) var id: String
        var medicineTypeId: String
        var childId: String
        var givenAt: Date
        var givenBy: String?
        var doseAmount: String?
        var notes: String?
        var createdAt: Date
        var updatedAt: Date
        var createdBy: String?
        var deletedAt: Date?

        init() {
            id = UUID().uuidString
            medicineTypeId = ""
            childId = ""
            givenAt = Date()
            givenBy = nil
            doseAmount = nil
            notes = nil
            createdAt = Date()
            updatedAt = Date()
            createdBy = nil
            deletedAt = nil
        }
    }

    @Model
    final class Nap {
        @Attribute(.unique) var id: String
        var childId: String
        var startedAt: Date
        var endedAt: Date?
        var location: String?
        var notes: String?
        var sleepType: String = "nap"
        var createdAt: Date
        var updatedAt: Date
        var createdBy: String?
        var deletedAt: Date?

        init() {
            id = UUID().uuidString
            childId = ""
            startedAt = Date()
            endedAt = nil
            location = nil
            notes = nil
            sleepType = "nap"
            createdAt = Date()
            updatedAt = Date()
            createdBy = nil
            deletedAt = nil
        }
    }

    @Model
    final class DogActivity {
        @Attribute(.unique) var id: String
        var activityType: String
        var startedAt: Date
        var endedAt: Date?
        var notes: String?
        var doneBy: String?
        var createdAt: Date
        var updatedAt: Date
        var createdBy: String?
        var deletedAt: Date?

        init() {
            id = UUID().uuidString
            activityType = "walk"
            startedAt = Date()
            endedAt = nil
            notes = nil
            doneBy = nil
            createdAt = Date()
            updatedAt = Date()
            createdBy = nil
            deletedAt = nil
        }
    }

    @Model
    final class Birthday {
        @Attribute(.unique) var id: String
        var personName: String
        var dateOfBirth: Date
        var relationship: String?
        var reminderDaysBefore: Int
        var createdAt: Date
        var updatedAt: Date
        var createdBy: String?
        var deletedAt: Date?

        init() {
            id = UUID().uuidString
            personName = ""
            dateOfBirth = Date()
            relationship = nil
            reminderDaysBefore = 7
            createdAt = Date()
            updatedAt = Date()
            createdBy = nil
            deletedAt = nil
        }
    }

    @Model
    final class Meal {
        @Attribute(.unique) var id: String
        var name: String
        var mealDescription: String?
        var recipeURL: String?
        var tags: String?
        var ingredients: String?
        var lastMadeAt: Date?
        var createdAt: Date
        var updatedAt: Date
        var createdBy: String?
        var deletedAt: Date?

        init() {
            id = UUID().uuidString
            name = ""
            mealDescription = nil
            recipeURL = nil
            tags = nil
            ingredients = nil
            lastMadeAt = nil
            createdAt = Date()
            updatedAt = Date()
            createdBy = nil
            deletedAt = nil
        }
    }

    @Model
    final class MealPlan {
        @Attribute(.unique) var id: String
        var mealId: String
        var date: Date
        var mealType: String
        var createdAt: Date
        var updatedAt: Date
        var createdBy: String?
        var deletedAt: Date?

        init() {
            id = UUID().uuidString
            mealId = ""
            date = Date()
            mealType = "dinner"
            createdAt = Date()
            updatedAt = Date()
            createdBy = nil
            deletedAt = nil
        }
    }

    @Model
    final class ShoppingItem {
        @Attribute(.unique) var id: String
        var name: String
        var quantity: String?
        var category: String?
        var mealPlanId: String?
        var checked: Bool
        var createdAt: Date
        var updatedAt: Date
        var createdBy: String?
        var deletedAt: Date?

        init() {
            id = UUID().uuidString
            name = ""
            quantity = nil
            category = nil
            mealPlanId = nil
            checked = false
            createdAt = Date()
            updatedAt = Date()
            createdBy = nil
            deletedAt = nil
        }
    }

    @Model
    final class HealthRecord {
        @Attribute(.unique) var id: String
        var source: String
        var dataType: String
        var value: Double
        var unit: String
        var recordedAt: Date
        var metadata: String?
        var createdAt: Date
        var updatedAt: Date
        var createdBy: String?
        var deletedAt: Date?

        init() {
            id = UUID().uuidString
            source = ""
            dataType = ""
            value = 0
            unit = ""
            recordedAt = Date()
            metadata = nil
            createdAt = Date()
            updatedAt = Date()
            createdBy = nil
            deletedAt = nil
        }
    }

    @Model
    final class ReadingLog {
        @Attribute(.unique) var id: String
        var childId: String
        var bookTitle: String
        var minutes: Int
        var date: Date
        var notes: String?
        var createdAt: Date
        var updatedAt: Date
        var createdBy: String?
        var deletedAt: Date?

        init() {
            id = UUID().uuidString
            childId = ""
            bookTitle = ""
            minutes = 0
            date = Date()
            notes = nil
            createdAt = Date()
            updatedAt = Date()
            createdBy = nil
            deletedAt = nil
        }
    }

    @Model
    final class SpellingEntry {
        @Attribute(.unique) var id: String
        var childId: String
        var wordList: String
        var testDate: Date?
        var score: Int?
        var practiceCount: Int
        var createdAt: Date
        var updatedAt: Date
        var createdBy: String?
        var deletedAt: Date?

        init() {
            id = UUID().uuidString
            childId = ""
            wordList = "[]"
            testDate = nil
            score = nil
            practiceCount = 0
            createdAt = Date()
            updatedAt = Date()
            createdBy = nil
            deletedAt = nil
        }
    }

    @Model
    final class GrowthRecord {
        @Attribute(.unique) var id: String
        var childId: String
        var date: Date
        var heightCm: Double?
        var weightKg: Double?
        var headCircumferenceCm: Double?
        var notes: String?
        var createdAt: Date
        var updatedAt: Date
        var createdBy: String?
        var deletedAt: Date?

        init() {
            id = UUID().uuidString
            childId = ""
            date = Date()
            heightCm = nil
            weightKg = nil
            headCircumferenceCm = nil
            notes = nil
            createdAt = Date()
            updatedAt = Date()
            createdBy = nil
            deletedAt = nil
        }
    }

    @Model
    final class OfflineAction {
        @Attribute(.unique) var id: String
        var operation: OfflineOperation
        var tableName: String
        var recordId: String
        var payload: String
        var createdAt: Date
        var status: OfflineStatus
        var retryCount: Int

        init() {
            id = UUID().uuidString
            operation = .create
            tableName = ""
            recordId = ""
            payload = "{}"
            createdAt = Date()
            status = .pending
            retryCount = 0
        }
    }

    @Model
    final class RoutineItem {
        @Attribute(.unique) var id: String
        var personId: String
        var name: String
        var color: String
        var daysOfWeek: String
        var sortOrder: Int
        var createdAt: Date
        var updatedAt: Date
        var createdBy: String?
        var deletedAt: Date?

        init() {
            id = UUID().uuidString
            personId = ""
            name = ""
            color = "#FF6B6B"
            daysOfWeek = "[]"
            sortOrder = 0
            createdAt = Date()
            updatedAt = Date()
            createdBy = nil
            deletedAt = nil
        }
    }

    @Model
    final class PendingDocumentUpload {
        @Attribute(.unique) var id: String
        var filePath: String
        var filename: String
        var mediaType: String
        var title: String
        var source: String
        var category: String
        var documentDate: String?
        var pageCount: Int
        var extractedText: String?
        var notes: String?
        var personIdsJSON: String
        var suggestionsJSON: String
        var useHermes: Bool
        var status: DocumentUploadStatus
        var errorMessage: String?
        var createdAt: Date

        init() {
            id = UUID().uuidString
            filePath = ""
            filename = ""
            mediaType = ""
            title = ""
            source = ""
            category = ""
            documentDate = nil
            pageCount = 1
            extractedText = nil
            notes = nil
            personIdsJSON = "[]"
            suggestionsJSON = "[]"
            useHermes = true
            status = .pending
            errorMessage = nil
            createdAt = Date()
        }
    }

    static let models: [any PersistentModel.Type] = [
        CalendarEvent.self,
        FamilyTask.self,
        Child.self,
        MedicineType.self,
        MedicineDose.self,
        Nap.self,
        DogActivity.self,
        Birthday.self,
        Meal.self,
        MealPlan.self,
        ShoppingItem.self,
        HealthRecord.self,
        ReadingLog.self,
        SpellingEntry.self,
        GrowthRecord.self,
        OfflineAction.self,
        RoutineItem.self,
        PendingDocumentUpload.self,
    ]
}

/// Current schema. Unlike V1-V4, this intentionally follows the live models;
/// the next release must copy these definitions into a new frozen namespace
/// before changing any persisted property again.
enum HausKlarSchemaV5: VersionedSchema {
    static let versionIdentifier = Schema.Version(5, 0, 0)

    static let models: [any PersistentModel.Type] = [
        CalendarEvent.self,
        FamilyTask.self,
        Child.self,
        MedicineType.self,
        MedicineDose.self,
        Nap.self,
        DogActivity.self,
        Birthday.self,
        Meal.self,
        MealPlan.self,
        ShoppingItem.self,
        HealthRecord.self,
        ReadingLog.self,
        SpellingEntry.self,
        GrowthRecord.self,
        OfflineAction.self,
        RoutineItem.self,
        PendingDocumentUpload.self,
    ]
}

enum HausKlarMigrationPlan: SchemaMigrationPlan {
    /// V1 was an unversioned LegacyHausKlar store. Its String -> Date and String ->
    /// enum changes cannot be expressed by SwiftData's migration hooks without
    /// an external, crash-safe copy of every row. Listing a fake lightweight
    /// stage would risk data loss, so automatic migration starts at the first
    /// actually versioned release. LocalStoreRecovery archives an unrecognised
    /// V1 store and its WAL/SHM files before creating any replacement store.
    static let automaticallyMigratableVersions = 2...5

    static let schemas: [any VersionedSchema.Type] = [
        HausKlarSchemaV2.self,
        HausKlarSchemaV3.self,
        HausKlarSchemaV4.self,
        HausKlarSchemaV5.self,
    ]

    static let stages: [MigrationStage] = [
        .lightweight(fromVersion: HausKlarSchemaV2.self, toVersion: HausKlarSchemaV3.self),
        .lightweight(fromVersion: HausKlarSchemaV3.self, toVersion: HausKlarSchemaV4.self),
        .lightweight(fromVersion: HausKlarSchemaV4.self, toVersion: HausKlarSchemaV5.self),
    ]
}

/// A deterministic, public-API-only schema description used by regression
/// tests. SwiftData does not expose its private Core Data model checksum, so
/// this captures every entity/property name, storage type, optionality,
/// uniqueness, original name, and declared default that affects our schemas.
enum HausKlarSchemaFingerprint {
    static func manifest(for version: any VersionedSchema.Type) -> String {
        let schema = Schema(versionedSchema: version)
        let entities = schema.entities.sorted { $0.name < $1.name }

        return entities.map { entity in
            let properties = entity.properties.sorted { $0.name < $1.name }.map { property in
                let defaultValue: String
                if let attribute = property as? Schema.Attribute {
                    defaultValue = normalizedDefault(attribute.defaultValue)
                } else {
                    defaultValue = "-"
                }
                return [
                    property.name,
                    property.originalName,
                    normalizedType(property.valueType),
                    property.isOptional ? "optional" : "required",
                    property.isUnique ? "unique" : "nonunique",
                    property.isAttribute ? "attribute" : "relationship",
                    property.isTransient ? "transient" : "stored",
                    defaultValue,
                ].joined(separator: ":")
            }.joined(separator: ",")
            let constraints = entity.uniquenessConstraints
                .map { $0.sorted().joined(separator: "+") }
                .sorted()
                .joined(separator: ",")
            return "\(entity.name)[\(properties)]{\(constraints)}"
        }.joined(separator: "\n")
    }

    static func value(for version: any VersionedSchema.Type) -> String {
        // FNV-1a is deliberately small and deterministic; this is a schema
        // change detector, not a cryptographic integrity primitive.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in manifest(for: version).utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100_0000_01b3
        }
        return String(format: "%016llx", hash)
    }

    private static func normalizedType(_ type: Any.Type) -> String {
        String(reflecting: type)
            .replacingOccurrences(of: "HausKlar.", with: "")
            .replacingOccurrences(of: "HausKlarTests.", with: "")
    }

    private static func normalizedDefault(_ value: Any?) -> String {
        guard let value else { return "nil" }
        switch value {
        case let value as String:
            return "string(\(value))"
        case let value as Bool:
            return "bool(\(value))"
        case let value as Int:
            return "int(\(value))"
        case let value as Double:
            return "double(\(value))"
        default:
            return String(reflecting: value)
        }
    }
}
