import Foundation

/// Shared lightweight payload for the PWA and iOS Today experiences.
struct TodayDashboardDTO: Codable {
    let generatedAt: String
    let date: String
    let events: [CalendarEventDTO]
    let tasks: [TaskDTO]
    let naps: [NapDTO]
    let illnesses: [ActiveIllnessDTO]
    let illnessReadings: [String: [TemperatureReadingDTO]]
    let routines: [ActiveRoutineDTO]
    let meals: [MealPlanDTO]
    let dog: DogStatusDTO?
    let coordination: TomorrowCardDTO?
    let memories: [PhotoMemoryDTO]
    let insights: [InsightDTO]
    let prepSuggestions: [PrepPackSuggestionDTO]
    let medicine: [GlanceMedicineDTO]
    let birthdays: [BirthdayFullDTO]
    let homework: [TodayHomeworkDTO]
    let presents: [TodayPresentDTO]?
    let familyMembers: [FamilyMemberDTO]
    let weather: BriefingWeatherDTO?
    let financeAction: TodayFinanceActionDTO?
    let facilityQuickFact: FacilityQuickFactDTO?
    let unavailable: [String]
}

struct TodayHomeworkDTO: Codable, Identifiable, Equatable {
    let id: String
    let childId: String
    let childName: String
    let testDate: String
    let wordCount: Int
    let practiceCount: Int
    let status: String
}

struct TodayPresentDTO: Codable, Identifiable, Equatable {
    let id: String
    let childId: String
    let recipientName: String?
    let title: String
    let deadline: String
    let daysUntilDue: Int
    let status: String
    let ownerId: String?
    let ownerName: String?
    let action: String
}

struct FacilityTimeWindowDTO: Codable, Equatable {
    let start: String
    let end: String

    var label: String { "\(start)–\(end)" }
}

struct FacilityDaySummaryDTO: Codable, Equatable {
    let date: String
    let covered: Bool
    let familySwimming: [FacilityTimeWindowDTO]
    let laneSwimming: [FacilityTimeWindowDTO]
    let weightsRoom: [FacilityTimeWindowDTO]
    let poolClosed: Bool
    let weightsRoomStatus: String
    let weightsRelevant: Bool

    var familySwimmingLabel: String {
        if !familySwimming.isEmpty {
            return "Family swim " + familySwimming.map(\.label).joined(separator: ", ")
        }
        return poolClosed ? "Pool closed" : "No family swimming"
    }

    var weightsRoomLabel: String? {
        guard weightsRelevant else { return nil }
        if !weightsRoom.isEmpty {
            return "Weights " + weightsRoom.map(\.label).joined(separator: ", ")
        }
        return weightsRoomStatus == "closed" ? "Weights closed" : "Weights times unavailable"
    }
}

struct FacilityQuickFactDTO: Codable, Equatable {
    let provider: String
    let sourceTitle: String?
    let sourceDocumentId: String?
    let currentFrom: String?
    let currentTo: String?
    let updateDue: Bool
    let today: FacilityDaySummaryDTO
    let tomorrow: FacilityDaySummaryDTO
}

struct FacilityCalendarPreferenceDTO: Codable, Equatable {
    let showFamilySwimming: Bool
    let showPersonalFacilities: Bool
}

struct FacilityCalendarLayerItemDTO: Codable, Equatable, Identifiable {
    let id: String
    let layerKind: String
    let displayTitle: String
    let startTime: String
    let endTime: String
    let ownerUserId: String?
    let sourceDocumentId: String?
    let sourceTitle: String
    let location: String
    let readOnly: Bool
}

struct FacilityImportCountsDTO: Codable, Equatable {
    let days: Int
    let familySwimmingSessions: Int
    let laneSwimmingSessions: Int
    let weightsRoomOpenDays: Int
    let poolClosedDays: Int
    let weightsRoomClosedDays: Int
}

struct FacilityImportChangesDTO: Codable, Equatable {
    let addedDays: Int
    let changedDays: Int
    let removedDays: Int
}

struct FacilityImportPreviewDTO: Codable, Equatable {
    let filename: String
    let title: String
    let sha256: String
    let validFrom: String
    let validTo: String
    let counts: FacilityImportCountsDTO
    let changes: FacilityImportChangesDTO
    let sampleDays: [FacilityDaySummaryDTO]
    let issues: [String]
    let alreadyImported: Bool
    let canConfirm: Bool
}

struct FacilityImportResultDTO: Codable, Equatable {
    let versionId: String
    let documentId: String?
    let imported: Bool
    let preview: FacilityImportPreviewDTO
}

/// One authorised Finance action selected by the backend for the signed-in adult.
/// A missing value means there is no action or Finance is unavailable to this account.
struct TodayFinanceActionDTO: Codable, Equatable {
    let id: String
    let kind: String
    let spaceId: String
    let spaceKind: String
    let spaceName: String
    let dueDate: String?
    let reviewDate: String?
    let title: String?
    let amountMinor: Int?
    let currency: String?
    let sourceAccountId: String?
    let sourceAccountLabel: String?
    let destinationAccountId: String?
    let destinationAccountLabel: String?
    let lineId: String?
    let purchaseId: String?
    let sourceId: String?

    /// Some Finance actions still need the web app. This sends only opaque record
    /// identifiers and scope, never account labels, amounts or other private context.
    var financeWebURL: URL? {
        guard let router = FinanceWebRouter.configured() else { return nil }
        let scope: FinanceWebScope = spaceKind == "HOUSEHOLD" ? .household : .mine
        if kind == "PURCHASE_REVIEW", let lineId {
            return router.url(
                section: "activity",
                scope: scope,
                recordQueryItems: [URLQueryItem(name: "line", value: lineId)]
            )
        }
        return router.url(
            section: "coach",
            scope: scope,
            recordQueryItems: [URLQueryItem(name: "action", value: id)]
        )
    }
}

/// The deliberately compact, owner-only Fitness contribution to Today.
/// Health readings, coaching context and workout steps are not part of this
/// contract; the card only needs enough information to take the next action.
struct FitnessTodayCardDTO: Codable, Equatable {
    let date: String
    let hasCompletedActivityToday: Bool?
    let session: FitnessTodayCardSessionDTO?
    let primaryAction: FitnessTodayCardActionDTO?
    let secondaryAction: FitnessTodayCardActionDTO?
    let nutrition: FitnessTodayNutritionDTO?
}

struct FitnessTodayNutritionDTO: Codable, Equatable {
    let caloriesKcal: Double
    let calorieTargetKcal: Double?
    let proteinG: Double
    let proteinTargetG: Double?
    let entryCount: Int
    let caloriesComplete: Bool
    let proteinComplete: Bool
}

struct FitnessTodayCardSessionDTO: Codable, Equatable, Identifiable {
    let id: String
    let kind: String
    let title: String
    let sportKey: String
    let status: String
    let startsAt: String?
    let scheduledDate: String?
    let durationMinutes: Int?
    let movable: Bool
}

struct FitnessTodayCardActionDTO: Codable, Equatable {
    let kind: String
    let label: String
    let destination: FitnessDeepLinkDestination
    let targetId: String?
}

/// Shared medicine dose payload used by medicine tracking and family summaries.
struct MedicineSafetyWarningDTO: Codable, Identifiable {
    var id: String { "\(type)_\(message)" }
    let type: String
    let message: String
    let nextSafeAt: String?
}

struct MedicineDoseDTO: Codable, Identifiable {
    let id: String
    let medicineTypeId: String?
    let childId: String
    let givenAt: String
    let givenBy: String?
    let doseAmount: String?
    let medicineName: String?
    let notes: String?
    let warnings: [MedicineSafetyWarningDTO]

    init(
        id: String,
        medicineTypeId: String?,
        childId: String,
        givenAt: String,
        givenBy: String?,
        doseAmount: String?,
        medicineName: String?,
        notes: String?,
        warnings: [MedicineSafetyWarningDTO] = []
    ) {
        self.id = id
        self.medicineTypeId = medicineTypeId
        self.childId = childId
        self.givenAt = givenAt
        self.givenBy = givenBy
        self.doseAmount = doseAmount
        self.medicineName = medicineName
        self.notes = notes
        self.warnings = warnings
    }

    enum CodingKeys: String, CodingKey {
        case id, medicineTypeId, childId, givenAt, givenBy
        case doseAmount, medicineName, notes, warnings
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        medicineTypeId = try values.decodeIfPresent(String.self, forKey: .medicineTypeId)
        childId = try values.decode(String.self, forKey: .childId)
        givenAt = try values.decode(String.self, forKey: .givenAt)
        givenBy = try values.decodeIfPresent(String.self, forKey: .givenBy)
        doseAmount = try values.decodeIfPresent(String.self, forKey: .doseAmount)
        medicineName = try values.decodeIfPresent(String.self, forKey: .medicineName)
        notes = try values.decodeIfPresent(String.self, forKey: .notes)
        warnings = try values.decodeIfPresent(
            [MedicineSafetyWarningDTO].self,
            forKey: .warnings
        ) ?? []
    }
}

struct DogStatusDTO: Codable {
    let walkedToday: Bool
    let fedBreakfastToday: Bool
    let fedDinnerToday: Bool
    let lastWalk: DogActivityDTO?
    let lastFeedBreakfast: DogActivityDTO?
    let lastFeedDinner: DogActivityDTO?
}

struct ActiveIllnessDTO: Codable, Identifiable {
    let id: String
    let childId: String
    let startedAt: String
    let notes: String?
}

struct BriefingWeatherDTO: Codable {
    let description: String
    let tempHigh: Double
    let tempLow: Double
    let rainChance: Int
}

struct BriefingCalendarEventDTO: Codable, Identifiable {
    var id: String { "\(title)-\(startTime ?? "all-day")" }
    let title: String
    let startTime: String?
    let endTime: String?
    let allDay: Bool
    let location: String?
}

struct BriefingTaskDTO: Codable, Identifiable {
    var id: String { "\(title)-\(dueDate ?? "no-due")" }
    let title: String
    let dueDate: String?
    let category: String?
}

struct BriefingBirthdayDTO: Codable, Identifiable {
    var id: String { "\(personName)-\(dateOfBirth ?? "unknown-year")" }
    let personName: String
    let dateOfBirth: String?
    let daysUntil: Int
    let turningAge: Int?
}

struct DailyBriefingDTO: Codable {
    let date: String
    let generatedAt: String
    let calendarEvents: [BriefingCalendarEventDTO]
    let tasksDue: [BriefingTaskDTO]
    let upcomingBirthdays: [BriefingBirthdayDTO]
    let weather: BriefingWeatherDTO?
}

struct ChildDailyBriefingRow: Identifiable {
    let childId: String
    let childName: String
    let clubs: [String]
    let hasPE: Bool
    let booksDueBack: Bool

    var id: String { childId }
}
