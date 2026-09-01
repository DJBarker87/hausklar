import Foundation

// MARK: - Glance DTOs
// Contract for GET /briefing/glance — shared between the app and the widget extension.

struct GlanceEventDTO: Codable, Identifiable {
    let id: String
    let title: String
    let startTime: String
    let allDay: Bool
    let personName: String?
}

struct GlanceTaskDTO: Codable, Identifiable {
    let id: String
    let title: String
    let dueDate: String?
}

struct GlanceDinnerDTO: Codable {
    let title: String
}

struct GlanceMedicineDTO: Codable, Identifiable {
    let medicineTypeId: String?
    let childId: String?
    let childName: String
    let medicineName: String
    let nextSafeAt: String?
    let isSafeNow: Bool
    let lastGivenAt: String?

    var id: String { "\(childId ?? childName)-\(medicineName)" }

    init(
        medicineTypeId: String? = nil,
        childId: String?,
        childName: String,
        medicineName: String,
        nextSafeAt: String?,
        isSafeNow: Bool,
        lastGivenAt: String?
    ) {
        self.medicineTypeId = medicineTypeId
        self.childId = childId
        self.childName = childName
        self.medicineName = medicineName
        self.nextSafeAt = nextSafeAt
        self.isSafeNow = isSafeNow
        self.lastGivenAt = lastGivenAt
    }
}

/// Medicine timing is the one glance surface that must never turn an absent or
/// superseded snapshot into an all-clear state.
enum GlanceMedicineStatusPolicy {
    static func needsReview(
        hasSnapshot: Bool,
        isStale: Bool,
        snapshotMatchesCurrentDay: Bool
    ) -> Bool {
        !hasSnapshot || isStale || !snapshotMatchesCurrentDay
    }
}

struct GlanceTomorrowEventDTO: Codable {
    let title: String
    let startTime: String?
    let allDay: Bool
}

struct GlanceTomorrowDTO: Codable {
    let firstEvent: GlanceTomorrowEventDTO?
    let eventCount: Int
}

/// "On this day" photo memory. Optional field — absent until the photos feature is deployed.
struct GlanceMemoryDTO: Codable {
    let assetId: String
    let takenAt: String
    let yearsAgo: Int
}

struct GlanceNapDTO: Codable, Identifiable {
    let id: String
    let childId: String
    let childName: String
    let startedAt: String
    let sleepType: String
}

struct GlanceDogCareDTO: Codable {
    let dogName: String
    let activeWalkId: String?
    let breakfastState: String
    let walkState: String
    let dinnerState: String

    var nextJob: GlanceDogJob {
        if let activeWalkId {
            return GlanceDogJob(
                action: "active_walk",
                activityId: activeWalkId,
                title: "\(dogName)'s walk",
                detail: "In progress"
            )
        }

        let jobs = [
            (action: "feed_breakfast", title: "Breakfast for \(dogName)", state: breakfastState),
            (action: "walk", title: "\(dogName)'s walk", state: walkState),
            (action: "feed_dinner", title: "Dinner for \(dogName)", state: dinnerState),
        ]
        for state in ["overdue", "due", "upcoming"] {
            if let job = jobs.first(where: { $0.state == state }) {
                let detail: String
                switch state {
                case "overdue": detail = "Overdue"
                case "due": detail = "Due now"
                default: detail = "Later today"
                }
                return GlanceDogJob(
                    action: job.action,
                    activityId: nil,
                    title: job.title,
                    detail: detail
                )
            }
        }
        return GlanceDogJob(
            action: "overview",
            activityId: nil,
            title: "\(dogName)'s care",
            detail: "All done today"
        )
    }
}

struct GlanceDogJob {
    let action: String
    let activityId: String?
    let title: String
    let detail: String
}

struct GlanceStarChartDTO: Codable, Identifiable {
    let chartId: String
    let childId: String
    let childName: String
    let title: String
    let totalCells: Int
    let starsCount: Int

    var id: String { chartId }
}

/// One URL contract for widgets, Live Activities, notifications and App Intents.
/// All mutating family jobs open a review surface; none are encoded as commands.
enum AmbientDeepLink {
    static let today = make(host: "today")
    static let naps = make(host: "naps")
    static let starCharts = make(host: "star-chart")

    static func calendarEvent(id: String) -> URL {
        make(host: "calendar", queryItems: [URLQueryItem(name: "event", value: id)])
    }

    static func activeNap(napId: String, childId: String) -> URL {
        make(
            host: "naps",
            queryItems: [
                URLQueryItem(name: "nap_id", value: napId),
                URLQueryItem(name: "child_id", value: childId),
            ]
        )
    }

    static func dogCare(action: String? = nil, activityId: String? = nil) -> URL {
        make(
            host: "dog",
            queryItems: [
                URLQueryItem(name: "action", value: action),
                URLQueryItem(name: "activity_id", value: activityId),
            ].filter { $0.value != nil }
        )
    }

    static func capture(text: String? = nil) -> URL {
        make(
            host: "capture",
            queryItems: text.map { [URLQueryItem(name: "text", value: $0)] } ?? []
        )
    }

    static func starChart(childId: String, chartId: String) -> URL {
        make(
            host: "star-chart",
            queryItems: [
                URLQueryItem(name: "child_id", value: childId),
                URLQueryItem(name: "chart_id", value: chartId),
            ]
        )
    }

    static func medicineReview(childId: String?, medicineTypeId: String?) -> URL {
        make(
            host: "medicine",
            queryItems: [
                URLQueryItem(name: "child_id", value: childId),
                URLQueryItem(name: "medicine_type_id", value: medicineTypeId),
            ].filter { $0.value != nil }
        )
    }

    static func photo(assetId: String) -> URL {
        make(host: "photos", queryItems: [URLQueryItem(name: "asset_id", value: assetId)])
    }

    private static func make(host: String, queryItems: [URLQueryItem] = []) -> URL {
        var components = URLComponents()
        components.scheme = "hausklar"
        components.host = host
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        // A builder failure is not recoverable user input. Return an inert local
        // URL that the typed deep-link boundary will reject rather than crash.
        return components.url ?? URL(fileURLWithPath: "/")
    }
}

struct GlanceDTO: Codable {
    let generatedAt: String
    let date: String
    let events: [GlanceEventDTO]
    let tasksDue: [GlanceTaskDTO]
    let dinner: GlanceDinnerDTO?
    let medicine: [GlanceMedicineDTO]
    let tomorrow: GlanceTomorrowDTO?
    let memory: GlanceMemoryDTO?
    let activeNaps: [GlanceNapDTO]
    let dogCare: GlanceDogCareDTO?
    let starChart: GlanceStarChartDTO?

    enum CodingKeys: String, CodingKey {
        case generatedAt, date, events, tasksDue, dinner, medicine, tomorrow, memory
        case activeNaps, dogCare, starChart
    }

    init(
        generatedAt: String,
        date: String,
        events: [GlanceEventDTO],
        tasksDue: [GlanceTaskDTO],
        dinner: GlanceDinnerDTO?,
        medicine: [GlanceMedicineDTO],
        tomorrow: GlanceTomorrowDTO?,
        memory: GlanceMemoryDTO? = nil,
        activeNaps: [GlanceNapDTO] = [],
        dogCare: GlanceDogCareDTO? = nil,
        starChart: GlanceStarChartDTO? = nil
    ) {
        self.generatedAt = generatedAt
        self.date = date
        self.events = events
        self.tasksDue = tasksDue
        self.dinner = dinner
        self.medicine = medicine
        self.tomorrow = tomorrow
        self.memory = memory
        self.activeNaps = activeNaps
        self.dogCare = dogCare
        self.starChart = starChart
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        generatedAt = try container.decode(String.self, forKey: .generatedAt)
        date = try container.decode(String.self, forKey: .date)
        events = try container.decode([GlanceEventDTO].self, forKey: .events)
        tasksDue = try container.decode([GlanceTaskDTO].self, forKey: .tasksDue)
        dinner = try container.decodeIfPresent(GlanceDinnerDTO.self, forKey: .dinner)
        medicine = try container.decode([GlanceMedicineDTO].self, forKey: .medicine)
        tomorrow = try container.decodeIfPresent(GlanceTomorrowDTO.self, forKey: .tomorrow)
        // Decoded defensively: a missing, null or malformed memory never breaks the glance.
        memory = try? container.decodeIfPresent(GlanceMemoryDTO.self, forKey: .memory)
        // Ambient fields are additive so an older server or cache remains usable.
        activeNaps = (try? container.decode([GlanceNapDTO].self, forKey: .activeNaps)) ?? []
        dogCare = try? container.decodeIfPresent(GlanceDogCareDTO.self, forKey: .dogCare)
        starChart = try? container.decodeIfPresent(GlanceStarChartDTO.self, forKey: .starChart)
    }
}

extension GlanceDTO {
    func nextEvent(at date: Date = Date()) -> GlanceEventDTO? {
        let timed = events
            .filter { !$0.allDay }
            .compactMap { event -> (GlanceEventDTO, Date)? in
                guard let start = ISODateParser.parse(event.startTime), start >= date else {
                    return nil
                }
                return (event, start)
            }
            .sorted { $0.1 < $1.1 }
            .first?.0
        return timed ?? events.first(where: \.allDay)
    }

    var longestActiveNap: GlanceNapDTO? {
        activeNaps.min { lhs, rhs in
            guard let left = ISODateParser.parse(lhs.startedAt) else { return false }
            guard let right = ISODateParser.parse(rhs.startedAt) else { return true }
            return left < right
        }
    }

    func medicineToReview(at date: Date = Date()) -> GlanceMedicineDTO? {
        let pending = medicine
            .compactMap { item -> (GlanceMedicineDTO, Date)? in
                guard let safeAt = item.nextSafeAt.flatMap(ISODateParser.parse), safeAt > date else {
                    return nil
                }
                return (item, safeAt)
            }
            .sorted { $0.1 < $1.1 }
        return pending.first?.0 ?? medicine.first
    }
}
