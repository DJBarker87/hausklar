import CoreGraphics
import Foundation
import WidgetKit

// MARK: - Fetcher

/// Minimal glance fetcher for the widget process. Uses the shared-keychain access
/// token read-only; it must never use or rotate the refresh token — refreshing
/// from two processes races and invalidates the session.
enum GlanceFetcher {
    private static let maximumGlanceBytes = 2 * 1_024 * 1_024
    private static let redirectDelegate = AuthenticatedRedirectDelegate()
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 15
        return URLSession(
            configuration: configuration,
            delegate: redirectDelegate,
            delegateQueue: nil
        )
    }()

    private static var baseURL: String {
        (Bundle.main.object(forInfoDictionaryKey: "APIBaseURL") as? String)
            ?? "http://localhost:8001/api"
    }

    static func fetch() async throws -> GlanceDTO {
        guard let token = KeychainManager.sessionAccessToken() else {
            throw URLError(.userAuthenticationRequired)
        }
        var components = URLComponents(string: baseURL + "/briefing/glance")
        components?.queryItems = [URLQueryItem(name: "timezone", value: TimeZone.current.identifier)]
        guard let url = components?.url else { throw URLError(.badURL) }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (file, response) = try await session.download(for: request)
        let data = try BoundedHTTPPayload.readDownload(
            at: file,
            response: response,
            allowedMediaTypes: ["application/json"],
            maximumBytes: maximumGlanceBytes
        )
        return try GlanceStore.decode(GlanceDTO.self, from: data)
    }
}

// MARK: - Entry

struct GlanceEntry: TimelineEntry {
    let date: Date
    let glance: GlanceDTO?
    let fetchedAt: Date?
    let isStale: Bool
    var memoryImage: CGImage? = nil

    static func sample(date: Date = Date()) -> GlanceEntry {
        let glance = GlanceDTO(
            generatedAt: ISODateParser.stringNoFractional(from: date),
            date: String(ISODateParser.stringNoFractional(from: date).prefix(10)),
            events: [
                GlanceEventDTO(
                    id: "sample-1",
                    title: "Swimming",
                    startTime: ISODateParser.stringNoFractional(from: date.addingTimeInterval(45 * 60)),
                    allDay: false,
                    personName: "Child One"
                ),
                GlanceEventDTO(
                    id: "sample-2",
                    title: "School pickup",
                    startTime: ISODateParser.stringNoFractional(from: date.addingTimeInterval(4 * 3600)),
                    allDay: false,
                    personName: nil
                ),
                GlanceEventDTO(
                    id: "sample-3",
                    title: "Bath night",
                    startTime: ISODateParser.stringNoFractional(from: date.addingTimeInterval(7 * 3600)),
                    allDay: false,
                    personName: nil
                ),
            ],
            tasksDue: [
                GlanceTaskDTO(id: "sample-t1", title: "Book dentist", dueDate: nil),
                GlanceTaskDTO(id: "sample-t2", title: "PE kit", dueDate: nil),
            ],
            dinner: GlanceDinnerDTO(title: "Spaghetti bolognese"),
            medicine: [
                GlanceMedicineDTO(
                    childId: nil,
                    childName: "Child Two",
                    medicineName: "Calpol",
                    nextSafeAt: ISODateParser.stringNoFractional(from: date.addingTimeInterval(95 * 60)),
                    isSafeNow: false,
                    lastGivenAt: ISODateParser.stringNoFractional(from: date.addingTimeInterval(-145 * 60))
                ),
            ],
            tomorrow: nil,
            activeNaps: [
                GlanceNapDTO(
                    id: "sample-nap",
                    childId: "sample-child",
                    childName: "Child Two",
                    startedAt: ISODateParser.stringNoFractional(from: date.addingTimeInterval(-42 * 60)),
                    sleepType: "nap"
                ),
            ],
            dogCare: GlanceDogCareDTO(
                dogName: "Otto",
                activeWalkId: nil,
                breakfastState: "done",
                walkState: "due",
                dinnerState: "upcoming"
            ),
            starChart: GlanceStarChartDTO(
                chartId: "sample-chart",
                childId: "sample-child",
                childName: "Child Two",
                title: "Kind choices",
                totalCells: 10,
                starsCount: 6
            )
        )
        return GlanceEntry(date: date, glance: glance, fetchedAt: date, isStale: false)
    }
}

// MARK: - Derived values

extension GlanceEntry {
    private var currentDayInterval: DateInterval? {
        Calendar.current.dateInterval(of: .day, for: date)
    }

    private var snapshotMatchesCurrentDay: Bool {
        guard let snapshotDate = glance?.date else { return false }
        return snapshotDate == ISODateParser.stringDateOnly(from: date)
    }

    private var allDayEvents: [GlanceEventDTO] {
        glance?.events.filter { $0.allDay && eventOverlapsCurrentDay($0) } ?? []
    }

    private var upcomingTimedEvents: [GlanceEventDTO] {
        (glance?.events ?? [])
            .filter { !$0.allDay && eventOverlapsCurrentDay($0) }
            .compactMap { event -> (GlanceEventDTO, Date)? in
                guard let start = ISODateParser.parse(event.startTime), start >= date else { return nil }
                return (event, start)
            }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
    }

    var nextEvent: GlanceEventDTO? {
        upcomingTimedEvents.first ?? allDayEvents.first
    }

    var remainingEventCount: Int {
        upcomingTimedEvents.count + allDayEvents.count
    }

    /// All-day events first, then remaining timed events by start time.
    var upcomingEvents: [GlanceEventDTO] {
        allDayEvents + upcomingTimedEvents
    }

    var tasksDueCount: Int {
        glance?.tasksDue.count ?? 0
    }

    var activeNap: GlanceNapDTO? {
        guard !isStale, snapshotMatchesCurrentDay else { return nil }
        return (glance?.activeNaps ?? []).min { lhs, rhs in
            guard let left = ISODateParser.parse(lhs.startedAt) else { return false }
            guard let right = ISODateParser.parse(rhs.startedAt) else { return true }
            return left < right
        }
    }

    var currentDinner: GlanceDinnerDTO? {
        guard snapshotMatchesCurrentDay else { return nil }
        return glance?.dinner
    }

    var currentDogCare: GlanceDogCareDTO? {
        guard snapshotMatchesCurrentDay else { return nil }
        return glance?.dogCare
    }

    func timeLabel(for event: GlanceEventDTO) -> String {
        guard !event.allDay else { return "All day".widgetLocalized }
        guard let start = ISODateParser.parse(event.startTime) else { return "" }
        return ISODateParser.timeOnly(from: start)
    }

    /// Medicine entry to surface: soonest upcoming next-safe time, else one already safe.
    var activeMedicine: GlanceMedicineDTO? {
        // A dose recorded on another device can invalidate a cached interval.
        // Never turn stale or prior-day widget data into a safety decision.
        guard !isStale, snapshotMatchesCurrentDay,
              let medicine = glance?.medicine, !medicine.isEmpty else { return nil }
        let pending = medicine
            .compactMap { med -> (GlanceMedicineDTO, Date)? in
                guard let safeAt = med.nextSafeAt.flatMap(ISODateParser.parse), safeAt > date else { return nil }
                return (med, safeAt)
            }
            .sorted { $0.1 < $1.1 }
        return pending.first?.0 ?? medicine.first
    }

    // Fail safe: an unparseable or absent next-safe time is NOT ready. Green requires
    // either isSafeNow or a real parsed nextSafeAt that has already passed.
    func isReady(_ medicine: GlanceMedicineDTO) -> Bool {
        guard !isStale, snapshotMatchesCurrentDay else { return false }
        if medicine.isSafeNow { return true }
        guard let safeAt = medicine.nextSafeAt.flatMap(ISODateParser.parse) else { return false }
        return safeAt <= date
    }

    /// Short caption for the memory thumbnail, e.g. "1y ago".
    var memoryCaption: String? {
        guard let memory = glance?.memory else { return nil }
        return memory.yearsAgo == 1
            ? "1y ago".widgetLocalized
            : WidgetCopy.format("%lldy ago", Int64(memory.yearsAgo))
    }

    var medicineStatusNeedsReview: Bool {
        GlanceMedicineStatusPolicy.needsReview(
            hasSnapshot: glance != nil,
            isStale: isStale,
            snapshotMatchesCurrentDay: snapshotMatchesCurrentDay
        )
    }

    private func eventOverlapsCurrentDay(_ event: GlanceEventDTO) -> Bool {
        guard let day = currentDayInterval,
              let start = eventBoundary(event.startTime, allDay: event.allDay) else {
            return false
        }
        // The lightweight glance event has no end boundary. Only its civil start
        // day can safely be presented as Today.
        return start >= day.start && start < day.end
    }

    private func eventBoundary(_ value: String, allDay: Bool) -> Date? {
        if allDay, value.count == 10 {
            let parts = value.split(separator: "-", omittingEmptySubsequences: false)
            guard parts.count == 3,
                  let year = Int(parts[0]),
                  let month = Int(parts[1]),
                  let day = Int(parts[2]) else { return nil }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .current
            return calendar.date(from: DateComponents(
                timeZone: calendar.timeZone,
                year: year,
                month: month,
                day: day
            ))
        }
        return ISODateParser.parse(value)
    }
}

// MARK: - Provider

struct GlanceProvider: TimelineProvider {
    func placeholder(in context: Context) -> GlanceEntry {
        .sample()
    }

    func getSnapshot(in context: Context, completion: @escaping (GlanceEntry) -> Void) {
        if let cached = GlanceStore.load() {
            completion(GlanceEntry(
                date: Date(), glance: cached.glance, fetchedAt: cached.fetchedAt, isStale: true,
                memoryImage: Self.cachedMemoryImage(for: cached.glance)
            ))
        } else {
            completion(.sample())
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<GlanceEntry>) -> Void) {
        guard let glanceOwner = GlanceStore.activeIdentity else {
            completion(Self.emptyTimeline())
            return
        }
        let completion = TimelineCompletionBox(completion)
        Task {
            do {
                let glance = try await GlanceFetcher.fetch()
                GlanceStore.save(glance, for: glanceOwner)
                let memoryImage = Self.cachedMemoryImage(for: glance)
                guard GlanceStore.activeIdentity == glanceOwner else {
                    completion.call(Self.emptyTimeline())
                    return
                }
                completion.call(
                    Self.makeTimeline(
                        glance: glance,
                        fetchedAt: Date(),
                        isStale: false,
                        memoryImage: memoryImage
                    )
                )
            } catch {
                guard GlanceStore.activeIdentity == glanceOwner else {
                    completion.call(Self.emptyTimeline())
                    return
                }
                if let cached = GlanceStore.load() {
                    let memoryImage = Self.cachedMemoryImage(for: cached.glance)
                    completion.call(
                        Self.makeTimeline(
                            glance: cached.glance,
                            fetchedAt: cached.fetchedAt,
                            isStale: true,
                            memoryImage: memoryImage
                        )
                    )
                } else {
                    let entry = GlanceEntry(date: Date(), glance: nil, fetchedAt: nil, isStale: true)
                    completion.call(
                        Timeline(
                            entries: [entry],
                            policy: .after(Date().addingTimeInterval(15 * 60))
                        )
                    )
                }
            }
        }
    }

    private static func emptyTimeline() -> Timeline<GlanceEntry> {
        Timeline(
            entries: [GlanceEntry(date: Date(), glance: nil, fetchedAt: nil, isStale: true)],
            policy: .after(Date().addingTimeInterval(15 * 60))
        )
    }

    private static func cachedMemoryImage(for glance: GlanceDTO) -> CGImage? {
        guard let memory = glance.memory,
              let cached = GlanceStore.loadMemoryThumbnail(assetId: memory.assetId) else {
            return nil
        }
        return cached.decodedImage
    }

    /// Entries at "now" plus each moment the display should roll over
    /// (event starts, medicine becoming safe), capped to keep the timeline small.
    static func makeTimeline(
        glance: GlanceDTO,
        fetchedAt: Date,
        isStale: Bool,
        memoryImage: CGImage? = nil
    ) -> Timeline<GlanceEntry> {
        let now = Date()
        let startOfTomorrow = Calendar.current.dateInterval(of: .day, for: now)?.end
            ?? now.addingTimeInterval(24 * 60 * 60)
        var dates: Set<Date> = [now, startOfTomorrow]
        for event in glance.events where !event.allDay {
            if let start = ISODateParser.parse(event.startTime), start > now {
                dates.insert(start.addingTimeInterval(1))
            }
        }
        for med in glance.medicine {
            if let safeAt = med.nextSafeAt.flatMap(ISODateParser.parse), safeAt > now {
                dates.insert(safeAt.addingTimeInterval(1))
            }
        }
        var entryDates = Array(dates.sorted().prefix(11))
        if !entryDates.contains(startOfTomorrow) {
            entryDates.append(startOfTomorrow)
            entryDates.sort()
        }
        let entries = entryDates.map {
            GlanceEntry(
                date: $0,
                glance: glance,
                fetchedAt: fetchedAt,
                isStale: isStale,
                memoryImage: memoryImage
            )
        }
        let refresh = min(
            now.addingTimeInterval(isStale ? 20 * 60 : 45 * 60),
            startOfTomorrow.addingTimeInterval(60)
        )
        return Timeline(entries: Array(entries), policy: .after(refresh))
    }
}

/// WidgetKit's timeline callback predates Sendable annotations, but its API
/// explicitly permits asynchronous completion. The lock guarantees the callback
/// is consumed exactly once even if future fetch/fallback paths race; that
/// synchronization is the basis for the unchecked Sendable conformance.
private final class TimelineCompletionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: ((Timeline<GlanceEntry>) -> Void)?

    init(_ completion: @escaping (Timeline<GlanceEntry>) -> Void) {
        self.completion = completion
    }

    func call(_ timeline: Timeline<GlanceEntry>) {
        lock.lock()
        let completion = completion
        self.completion = nil
        lock.unlock()
        completion?(timeline)
    }
}
