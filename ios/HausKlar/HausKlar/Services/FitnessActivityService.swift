import Foundation
import os

private let fitnessActivityServiceLogger = Logger(
    subsystem: "org.example.hausklar",
    category: "FitnessActivityService"
)

struct FitnessLoadResult<Value: Sendable>: Sendable {
    let value: Value
    let isFromCache: Bool
}

enum FitnessRunPlanError: LocalizedError {
    case invalid([String])
    case missingPublishedVersion

    var errorDescription: String? {
        switch self {
        case .invalid(let errors): errors.joined(separator: " ")
        case .missingPublishedVersion: "The server did not return the published workout version."
        }
    }
}

enum FitnessAnalysisServiceError: LocalizedError {
    case invalid(String)
    case failed(String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .invalid(let message),.failed(let message): message
        case .timedOut:
            "This analysis is still taking longer than expected. You can run it again later without losing any records."
        }
    }
}

private struct FitnessGearCreateRequest: Encodable {
    let id: String
    let clientId: String
    let clientTimestamp: String
    let gearTypeKey: String
    let name: String
    let brand: String?
    let model: String?
    let variant: String?
    let startedAt: String?
    let initialUsageDistanceM: Double?
    let notes: String?
    let active: Bool
}

private struct FitnessGearDefaultRequest: Encodable { let sportKey: String }

private struct FitnessWorkoutVersionCreateRequest: Encodable {
    let id: String
    let clientId: String
    let clientTimestamp: String
    let title: String
    let purpose: String?
    let estimatedDurationS: Double?
    let estimatedDistanceM: Double?
    let structuredSummary: [String: JSONValue]
    let versionSource: String
    let exerciseItems: [JSONValue]
    let runSteps: [FitnessRunWorkoutStep]
    let runCues: [FitnessRunWorkoutCue]
}

private struct FitnessWorkoutDefinitionCreateRequest: Encodable {
    let id: String
    let clientId: String
    let clientTimestamp: String
    let sportKey: String
    let name: String
    let description: String?
    let active: Bool
    let version: FitnessWorkoutVersionCreateRequest
}

private struct FitnessPlannedRunCreateRequest: Encodable {
    let id: String
    let clientId: String
    let clientTimestamp: String
    let sportKey: String
    let title: String
    let localTimezone: String
    let trainingProgrammeId: String?
    let workoutVersionId: String
    let status: String
    let sessionSource: String
    let scheduledStartUtc: String?
    let scheduledDate: String?
    let timeWindowStartUtc: String?
    let timeWindowEndUtc: String?
    let expectedDurationS: Double?
    let expectedDistanceM: Double?
    let priority: Int
    let movable: Bool
    let visibility: String
    let sharedTitle: String?
    let reasonForPlacement: String?
    let goalLinks: [JSONValue]
    let exerciseItems: [JSONValue]
}

actor FitnessActivityService {
    static let shared = FitnessActivityService()

    private let repository: FitnessActivityRepository
    private let apiClient: APIClient
    private let database: FitnessDatabase
    private var identity: String?
    private var storeLease: FitnessStoreLease?
    private var flushTask: Task<Void, Never>?

    init(
        repository: FitnessActivityRepository = .shared,
        apiClient: APIClient = .shared,
        database: FitnessDatabase = .shared
    ) {
        self.repository = repository
        self.apiClient = apiClient
        self.database = database
    }

    func activate(identity: String) async {
        if self.identity == identity, let storeLease {
            do {
                try database.validate(storeLease)
                return
            } catch {
                fitnessActivityServiceLogger.error(
                    "Active Fitness activity lease became invalid: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        await suspend()
        do {
            let lease = try database.lease(for: identity)
            _ = try await database.withLease(lease) {
                try await repository.reconcilePendingFITFiles()
            }
            try database.validate(lease)
            self.identity = identity
            storeLease = lease
        } catch {
            fitnessActivityServiceLogger.error(
                "Fitness activity activation failed; pending FIT state was left untouched: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func suspend() async {
        identity = nil
        storeLease = nil
        // AppState owns the cross-process FIT account boundary. Stopping this
        // worker must not turn off sharing for a signed-in account.
        let pendingFlush = flushTask
        flushTask = nil
        pendingFlush?.cancel()
        if let pendingFlush { await pendingFlush.value }
    }

    func processInboxNow() async {
        await flushBackgroundWork()
    }

    private func flushBackgroundWork() async {
        guard let identity, let lease = storeLease else { return }
        if let flushTask {
            await flushTask.value
            return
        }
        let task = Task { [repository, identity, database] in
            do {
                try await database.withLease(lease) {
                    _ = try await FitnessPendingFITInbox.adoptAll(
                        identity: identity, repository: repository
                    )
                    await self.flushFITImports()
                    await self.flushContextMutations()
                }
            } catch {
                // A stale lease means teardown won the race. The previous
                // owner's queued work remains in that owner's unopened store.
                fitnessActivityServiceLogger.error(
                    "Fitness activity background work stopped with its queue retained: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        flushTask = task
        await task.value
        flushTask = nil
    }

    // MARK: FIT imports

    @discardableResult
    func stageFIT(from url: URL) async throws -> FitnessPendingFITImport {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let value = try await repository.stageFIT(at: url)
        await flushBackgroundWork()
        return value
    }

    func pendingFITImports() async throws -> [FitnessPendingFITImport] {
        try await repository.pendingFITImports()
    }

    func unownedSharedFITImports() -> [SharedFitnessFITPayload] {
        FitnessPendingFITInbox.unownedEntries()
    }

    func sharedFITRecoveryItems() -> [SharedFitnessFITPayload] {
        guard let identity else { return [] }
        return FitnessPendingFITInbox.ownedRecoveryEntries(identity: identity)
    }

    /// Files shared while HausKlar was locked have no owner marker. They remain
    /// detached until the signed-in user explicitly chooses to adopt one.
    func adoptUnownedSharedFIT(_ id: String) async throws {
        guard let identity else { return }
        _ = try await FitnessPendingFITInbox.adoptUnowned(
            id: id, identity: identity, repository: repository
        )
        await flushBackgroundWork()
    }

    func refreshFITImports() async {
        await flushBackgroundWork()
    }

    func retryFITImport(_ localId: String) async throws {
        let imports = try await repository.pendingFITImports()
        let row = imports.first { $0.id == localId }
        guard let row else { throw FitnessActivityRepositoryError.missingLocalFIT }
        if let serverId = row.serverImportId {
            let result: FitnessFITImportResult = try await apiClient.post(
                "/fitness/imports/\(serverId)/retry",body: EmptyBody()
            )
            try await repository.applyFITResult(localId: localId, result: result)
        } else {
            try await repository.markFITQueued(localId)
        }
        await flushBackgroundWork()
    }

    func removeAcknowledgedFITImport(_ id: String) async throws {
        try await repository.removeAcknowledgedFITImport(id)
    }

    private func flushFITImports() async {
        guard identity != nil else { return }
        let uploads: [FitnessPendingFITImport]
        do {
            uploads = try await repository.uploadableFITImports()
        } catch {
            fitnessActivityServiceLogger.error(
                "Pending FIT uploads could not be read; no uploads were attempted: \(error.localizedDescription, privacy: .public)"
            )
            return
        }
        for pending in uploads {
            guard identity != nil,!Task.isCancelled else { return }
            do {
                let fileURL = try await repository.localFITURL(for: pending.id)
                try await repository.markFITUploading(pending.id)
                let result: FitnessFITImportResult = try await apiClient.uploadMultipart(
                    "/fitness/imports/fit",fileURL: fileURL,
                    filename: pending.originalFilename,mediaType: "application/vnd.ant.fit",
                    fields: ["client_import_id": pending.id]
                )
                try await repository.applyFITResult(localId: pending.id, result: result)
            } catch {
                let uploadError = error
                do {
                    if Self.isOffline(uploadError) {
                        try await repository.markFITTransientFailure(
                            pending.id,message:uploadError.localizedDescription
                        )
                    } else {
                        try await repository.markFITFailure(
                            pending.id,message:uploadError.localizedDescription
                        )
                    }
                } catch {
                    fitnessActivityServiceLogger.fault(
                        "FIT upload stopped because failure state could not be saved; source retained. Import: \(pending.id, privacy: .private). Persistence error: \(error.localizedDescription, privacy: .public)"
                    )
                    return
                }
                if Self.isOffline(uploadError) { return }
            }
        }
        let polls: [FitnessPendingFITImport]
        do {
            polls = try await repository.pollableFITImports()
        } catch {
            fitnessActivityServiceLogger.error(
                "Pending FIT status checks could not be read; polling stopped: \(error.localizedDescription, privacy: .public)"
            )
            return
        }
        for pending in polls {
            guard identity != nil,!Task.isCancelled,let serverId = pending.serverImportId else { return }
            do {
                let result: FitnessFITImportResult = try await apiClient.get(
                    "/fitness/imports/\(serverId)",bypassCache: true
                )
                try await repository.applyFITResult(localId: pending.id, result: result)
            } catch {
                let pollError = error
                if Self.isOffline(pollError) { return }
                do {
                    try await repository.markFITFailure(
                        pending.id,message:pollError.localizedDescription
                    )
                } catch {
                    fitnessActivityServiceLogger.fault(
                        "FIT polling stopped because failure state could not be saved; source retained. Import: \(pending.id, privacy: .private). Persistence error: \(error.localizedDescription, privacy: .public)"
                    )
                    return
                }
            }
        }
    }

    // MARK: Activity history and detail

    func activityRegistry(refresh: Bool = false) async throws -> FitnessLoadResult<FitnessActivityRegistry> {
        do {
            let value: FitnessActivityRegistry = try await apiClient.get(
                "/fitness/activity-registry",bypassCache: refresh
            )
            try await repository.cacheActivityRegistry(value)
            return FitnessLoadResult(value: value,isFromCache: false)
        } catch {
            guard Self.isOffline(error),let cached=try await repository.cachedActivityRegistry()
            else { throw error }
            return FitnessLoadResult(value: cached,isFromCache: true)
        }
    }

    func activities(
        filter: FitnessActivityFilter = .init(),
        offset: Int = 0,
        limit: Int = 100,
        refresh: Bool = false
    ) async throws -> FitnessLoadResult<[FitnessActivitySummary]> {
        var query = [
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "limit", value: String(min(200, max(1, limit)))),
        ]
        Self.add(filter.sportKey, name: "sport_key", to: &query)
        Self.add(filter.dateFrom, name: "date_from", to: &query)
        Self.add(filter.dateTo, name: "date_to", to: &query)
        Self.add(filter.phaseId, name: "phase_id", to: &query)
        Self.add(filter.workoutClassification, name: "workout_classification", to: &query)
        Self.add(filter.gearId, name: "gear_id", to: &query)
        Self.add(filter.status, name: "status", to: &query)
        do {
            let values: [FitnessActivitySummary] = try await apiClient.get(
                "/fitness/activities",queryItems: query,bypassCache: refresh
            )
            try await repository.cacheActivities(values)
            return FitnessLoadResult(value: values,isFromCache: false)
        } catch {
            guard Self.isOffline(error) else { throw error }
            return FitnessLoadResult(
                value: try await repository.cachedActivities(
                    filter: filter,offset: offset,limit: limit
                ),isFromCache: true
            )
        }
    }

    func manualActivityDefaults(
        refresh: Bool = false
    ) async throws -> FitnessLoadResult<FitnessManualActivityDefaults> {
        do {
            let value: FitnessManualActivityDefaults = try await apiClient.get(
                "/fitness/activities/manual-defaults",bypassCache: refresh
            )
            return FitnessLoadResult(value: value,isFromCache: false)
        } catch {
            let cached = try await repository.cachedManualActivityDefaults()
            return FitnessLoadResult(value: cached,isFromCache: true)
        }
    }

    func logManualActivity(
        payload: FitnessManualActivityPayload,
        optimistic: FitnessActivitySummary
    ) async throws -> FitnessActivitySummary {
        try await repository.queueManualActivity(payload: payload,optimistic: optimistic)
        do {
            try await FitnessSyncService.shared.syncNow()
        } catch {
            fitnessActivityServiceLogger.error(
                "Immediate Fitness sync after manual activity creation was deferred: \(error.localizedDescription, privacy: .public)"
            )
        }
        do {
            let detail: FitnessActivityDetail = try await apiClient.get(
                "/fitness/activities/\(payload.id)",bypassCache: true
            )
            try await repository.cacheDetail(detail)
            return detail.activity
        } catch {
            fitnessActivityServiceLogger.error(
                "Manual activity detail refresh was deferred; the durable optimistic record remains visible: \(error.localizedDescription, privacy: .public)"
            )
            return optimistic
        }
    }

    func activityDetail(_ id: String, refresh: Bool = false) async throws -> FitnessLoadResult<FitnessActivityDetail> {
        do {
            let value: FitnessActivityDetail = try await apiClient.get(
                "/fitness/activities/\(id)",bypassCache: refresh
            )
            try await repository.cacheDetail(value)
            return FitnessLoadResult(value: value,isFromCache: false)
        } catch {
            guard Self.isOffline(error),let cached = try await repository.cachedDetail(id) else { throw error }
            return FitnessLoadResult(value: cached,isFromCache: true)
        }
    }

    func stream(
        activityId: String,
        metrics: [String],
        clock: String,
        fromOffsetMs: Int? = nil,
        toOffsetMs: Int? = nil,
        maxPoints: Int = 600,
        refresh: Bool = false
    ) async throws -> FitnessLoadResult<FitnessActivityStream> {
        var query = [
            URLQueryItem(name: "metrics", value: metrics.sorted().joined(separator: ",")),
            URLQueryItem(name: "clock", value: clock),
            URLQueryItem(name: "max_points", value: String(min(20_000, max(50, maxPoints)))),
        ]
        Self.add(fromOffsetMs.map { String($0) }, name: "from_offset_ms", to: &query)
        Self.add(toOffsetMs.map { String($0) }, name: "to_offset_ms", to: &query)
        do {
            let value: FitnessActivityStream = try await apiClient.get(
                "/fitness/activities/\(activityId)/streams",queryItems: query,bypassCache: refresh
            )
            try await repository.cacheStream(
                value,metrics: metrics,fromOffsetMs: fromOffsetMs,
                toOffsetMs: toOffsetMs,maxPoints: maxPoints
            )
            return FitnessLoadResult(value: value,isFromCache: false)
        } catch {
            guard Self.isOffline(error),let cached = try await repository.cachedStream(
                activityId: activityId,clock: clock,metrics: metrics,
                fromOffsetMs: fromOffsetMs,toOffsetMs: toOffsetMs,maxPoints: maxPoints
            ) else { throw error }
            return FitnessLoadResult(value: cached,isFromCache: true)
        }
    }

    func analysis(_ activityId: String, refresh: Bool = false) async throws -> FitnessLoadResult<FitnessActivityAnalysisResponse> {
        do {
            let value: FitnessActivityAnalysisResponse = try await apiClient.get(
                "/fitness/activities/\(activityId)/analysis",bypassCache: refresh
            )
            try await repository.cacheAnalysis(value, activityId: activityId)
            return FitnessLoadResult(value: value,isFromCache: false)
        } catch {
            guard Self.isOffline(error),let cached = try await repository.cachedAnalysis(activityId) else { throw error }
            return FitnessLoadResult(value: cached,isFromCache: true)
        }
    }

    /// Queues deterministic regeneration from the retained FIT source. The
    /// endpoint deliberately returns before the worker has finished.
    func reanalyseActivity(_ activityId: String) async throws -> FitnessActivityReanalysisStatus {
        try await apiClient.post(
            "/fitness/activities/\(activityId)/reanalyse", body: EmptyBody()
        )
    }

    func comparisons(_ activityId: String, refresh: Bool = false) async throws -> FitnessLoadResult<[FitnessComparableRun]> {
        do {
            let value: [FitnessComparableRun] = try await apiClient.get(
                "/fitness/activities/\(activityId)/comparisons",bypassCache: refresh
            )
            try await repository.cacheComparisons(value, activityId: activityId)
            return FitnessLoadResult(value: value,isFromCache: false)
        } catch {
            guard Self.isOffline(error),let cached = try await repository.cachedComparisons(activityId) else { throw error }
            return FitnessLoadResult(value: cached,isFromCache: true)
        }
    }

    func comparisonOverlay(
        activityId: String,
        comparisonIds: [String],
        metrics: [String] = ["pace_s_per_km", "heart_rate_bpm"],
        points: Int = 160
    ) async throws -> FitnessActivityComparisonOverlay {
        let query = [
            URLQueryItem(name: "comparison_ids", value: comparisonIds.joined(separator: ",")),
            URLQueryItem(name: "metrics", value: metrics.joined(separator: ",")),
            URLQueryItem(name: "points", value: String(min(500, max(20, points)))),
        ]
        return try await apiClient.get(
            "/fitness/activities/\(activityId)/comparison-overlay",
            queryItems: query,
            bypassCache: true
        )
    }

    func replaceActivityGoalLinks(
        activityId: String,
        goalIds: Set<String>
    ) async throws -> [FitnessActivityGoalLinkDTO] {
        let value: [FitnessActivityGoalLinkDTO] = try await apiClient.put(
            "/fitness/activities/\(activityId)/goal-links",
            body: FitnessActivityGoalLinksUpdate(
                links: goalIds.sorted().map { FitnessActivityGoalLinkInput(goalId: $0) }
            )
        )
        if var detail=try await repository.cachedDetail(activityId) {
            detail.goalLinks=value
            try await repository.cacheDetail(detail)
        }
        return value
    }

    func activityAdherence(_ activityId: String, refresh: Bool = false) async throws -> FitnessLoadResult<FitnessPlanAdherence> {
        do {
            let value: FitnessPlanAdherence = try await apiClient.get(
                "/fitness/activities/\(activityId)/adherence",bypassCache: refresh
            )
            try await repository.cacheAdherence(value, ownerType: "activity", ownerId: activityId)
            return FitnessLoadResult(value: value,isFromCache: false)
        } catch {
            guard Self.isOffline(error),let cached = try await repository.cachedAdherence(
                ownerType: "activity",ownerId: activityId
            ) else { throw error }
            return FitnessLoadResult(value: cached,isFromCache: true)
        }
    }

    @discardableResult
    func updateActivityContext(
        activityId: String,
        update: FitnessActivityContextUpdate
    ) async throws -> FitnessActivityDetail? {
        try await repository.queueContextUpdate(activityId: activityId, update: update)
        await flushContextMutations()
        return try await repository.cachedDetail(activityId)
    }

    private func flushContextMutations() async {
        let mutations: [FitnessPendingContextMutation]
        do {
            mutations = try await repository.pendingContextMutations()
        } catch {
            fitnessActivityServiceLogger.error(
                "Activity-context outbox could not be read; no mutation was sent: \(error.localizedDescription, privacy: .public)"
            )
            return
        }
        for mutation in mutations {
            guard identity != nil,!Task.isCancelled else { return }
            do {
                let detail: FitnessActivityDetail = try await apiClient.patch(
                    "/fitness/activities/\(mutation.activityId)/context",body: mutation.update
                )
                try await repository.acknowledgeContextMutation(mutation.mutationId, detail: detail)
            } catch {
                let mutationError = error
                do {
                    try await repository.markContextFailure(
                        mutation.mutationId,message:mutationError.localizedDescription
                    )
                } catch {
                    fitnessActivityServiceLogger.fault(
                        "Activity-context flush stopped because attempt state could not be saved; outbox retained. Mutation: \(mutation.mutationId, privacy: .private). Persistence error: \(error.localizedDescription, privacy: .public)"
                    )
                    return
                }
                if Self.isOffline(mutationError) { return }
            }
        }
    }

    // MARK: Gear

    func gear(refresh: Bool = false) async throws -> FitnessLoadResult<[FitnessGearItem]> {
        do {
            let values: [FitnessGearItem] = try await apiClient.get(
                "/fitness/gear",bypassCache: refresh
            )
            try await repository.cacheGear(values)
            return FitnessLoadResult(value: values,isFromCache: false)
        } catch {
            guard Self.isOffline(error) else { throw error }
            return FitnessLoadResult(value: try await repository.cachedGear(),isFromCache: true)
        }
    }

    func createGear(
        name: String,
        type: String = "running_shoe",
        brand: String? = nil,
        model: String? = nil,
        startedAt: String? = nil
    ) async throws -> FitnessGearItem {
        let request = FitnessGearCreateRequest(
            id: UUID().uuidString,clientId: try apiClient.clientId,
            clientTimestamp: FitnessDatabase.dateString(Date()),gearTypeKey: type,
            name: name,brand: brand,model: model,variant: nil,startedAt: startedAt,
            initialUsageDistanceM: nil,notes: nil,active: true
        )
        let value: FitnessGearItem = try await apiClient.post("/fitness/gear",body: request)
        try await repository.cacheGear([value])
        return value
    }

    func setDefaultGear(_ id: String, sportKey: String = "running") async throws -> FitnessGearItem {
        let value: FitnessGearItem = try await apiClient.post(
            "/fitness/gear/\(id)/default",body: FitnessGearDefaultRequest(sportKey: sportKey)
        )
        let refreshed: [FitnessGearItem] = try await apiClient.get("/fitness/gear",bypassCache: true)
        try await repository.cacheGear(refreshed)
        return value
    }

    func retireGear(_ id: String) async throws -> FitnessGearItem {
        let value: FitnessGearItem = try await apiClient.post(
            "/fitness/gear/\(id)/retire",body: EmptyBody()
        )
        try await repository.cacheGear([value])
        return value
    }

    // MARK: Calendar and analysis registry

    func calendarLayer(
        start: String,
        end: String,
        includeCompleted: Bool,
        refresh: Bool = false
    ) async throws -> FitnessLoadResult<[FitnessCalendarLayerItem]> {
        do {
            let values: [FitnessCalendarLayerItem] = try await apiClient.get(
                "/fitness/calendar-layer",
                queryItems: [
                    URLQueryItem(name: "start",value: start),
                    URLQueryItem(name: "end",value: end),
                    URLQueryItem(name: "include_completed",value: includeCompleted ? "true" : "false"),
                ],
                bypassCache: refresh
            )
            try await repository.replaceCalendarLayer(values)
            return FitnessLoadResult(value: values,isFromCache: false)
        } catch {
            guard Self.isOffline(error) else { throw error }
            let cached = try await repository.cachedCalendarLayer().filter {
                includeCompleted || $0.layerKind != "completed"
            }
            return FitnessLoadResult(value: cached,isFromCache: true)
        }
    }

    func analysisRegistry(refresh: Bool = false) async throws -> FitnessLoadResult<FitnessAnalysisRegistry> {
        do {
            let value: FitnessAnalysisRegistry = try await apiClient.get(
                "/fitness/analysis/registry",bypassCache: refresh
            )
            try await repository.cacheAnalysisRegistry(value)
            return FitnessLoadResult(value: value,isFromCache: false)
        } catch {
            guard Self.isOffline(error),let cached = try await repository.cachedAnalysisRegistry() else { throw error }
            return FitnessLoadResult(value: cached,isFromCache: true)
        }
    }

    func analysisQuery(
        _ request: FitnessAnalysisQueryRequest,
        registry: FitnessAnalysisRegistry
    ) async throws -> FitnessLoadResult<FitnessAnalysisQueryResult> {
        if let problem = FitnessAnalysisQueryValidator.problem(with: request, registry: registry) {
            throw FitnessAnalysisServiceError.invalid(problem)
        }
        do {
            var value: FitnessAnalysisQueryResult = try await apiClient.post(
                "/fitness/analysis/query",body: request
            )
            var pollCount = 0
            while value.status.isPending,let jobId = value.jobId,pollCount < 120 {
                try Task.checkCancellation()
                let requestedDelay = value.pollAfterMs ?? registry.limits.heavyPollIntervalMs ?? 2_000
                let delay = min(10_000,max(500,requestedDelay))
                try await Task.sleep(for: .milliseconds(delay))
                value = try await apiClient.get(
                    "/fitness/analysis/jobs/\(jobId)",
                    bypassCache: true
                )
                pollCount += 1
            }
            if value.status.isPending { throw FitnessAnalysisServiceError.timedOut }
            if value.status == .error {
                throw FitnessAnalysisServiceError.failed(
                    value.summary ?? value.limitations.first ?? "The analysis could not be completed."
                )
            }
            try await repository.cacheAnalysisQuery(value, request: request)
            return FitnessLoadResult(value: value,isFromCache: false)
        } catch {
            if error is CancellationError || error is FitnessAnalysisServiceError { throw error }
            guard Self.isOffline(error),let cached = try await repository.cachedAnalysisQuery(request) else { throw error }
            return FitnessLoadResult(value: cached,isFromCache: true)
        }
    }

    func savedAnalysisCharts(refresh: Bool = false) async throws -> FitnessLoadResult<[FitnessSavedAnalysisChart]> {
        do {
            let values: [FitnessSavedAnalysisChart] = try await apiClient.get(
                "/fitness/analysis/charts",bypassCache: refresh
            )
            try await repository.replaceSavedAnalysisCharts(values)
            return FitnessLoadResult(value: values,isFromCache: false)
        } catch {
            guard Self.isOffline(error) else { throw error }
            return FitnessLoadResult(value: try await repository.cachedSavedAnalysisCharts(),isFromCache: true)
        }
    }

    func saveAnalysisChart(
        _ payload: FitnessSavedAnalysisChartPayload,
        registry: FitnessAnalysisRegistry
    ) async throws -> FitnessSavedAnalysisChart {
        guard !payload.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FitnessAnalysisServiceError.invalid("Name this saved chart.")
        }
        guard registry.measures.contains(where: { measure in
            measure.key == payload.measureKey
                && measure.supportedDimensions.contains(payload.dimensionKey)
                && measure.chartTypes.contains(payload.chartTypeKey)
                && Set(payload.filterKeys).isSubset(of: Set(measure.allowedFilterKeys))
                && (payload.comparisonKey.map {
                    measure.comparisonForms?.contains($0) == true
                } ?? true)
        }),registry.chartTypes.contains(where: { $0.key == payload.chartTypeKey }),
        payload.dateWindowDays <= registry.limits.maxWindowDays,
        payload.filterKeys.count <= registry.limits.maxFilters,
        Set(payload.filterKeys).count == payload.filterKeys.count else {
            throw FitnessAnalysisServiceError.invalid("That saved chart contains a key that is not registered.")
        }
        let value: FitnessSavedAnalysisChart = try await apiClient.post(
            "/fitness/analysis/charts",body: payload
        )
        try await repository.cacheSavedAnalysisChart(value)
        return value
    }

    func deleteAnalysisChart(_ id: String) async throws {
        try await apiClient.delete("/fitness/analysis/charts/\(id)")
        try await repository.removeCachedSavedAnalysisChart(id)
    }

    // MARK: Run plans and Garmin

    func runPlanDrafts() async throws -> [FitnessRunPlanDraft] { try await repository.runPlanDrafts() }
    func saveRunPlanDraft(_ draft: FitnessRunPlanDraft) async throws { try await repository.saveRunPlanDraft(draft) }
    func deleteRunPlanDraft(_ id: String) async throws { try await repository.deleteRunPlanDraft(id) }

    func workoutDefinitions(
        sportKey: String = "running",
        refresh: Bool = false
    ) async throws -> FitnessLoadResult<[FitnessWorkoutDefinitionDTO]> {
        do {
            let values: [FitnessWorkoutDefinitionDTO] = try await apiClient.get(
                "/fitness/workout-definitions",
                queryItems: [URLQueryItem(name: "sport_key",value: sportKey)],
                bypassCache: refresh
            )
            try await repository.cacheWorkoutDefinitions(values)
            return FitnessLoadResult(value: values,isFromCache: false)
        } catch {
            guard Self.isOffline(error) else { throw error }
            return FitnessLoadResult(
                value: try await repository.cachedWorkoutDefinitions(sportKey: sportKey),isFromCache: true
            )
        }
    }

    func trainingProgrammes(refresh: Bool = false) async throws -> FitnessLoadResult<[FitnessTrainingProgrammeDTO]> {
        do {
            let values: [FitnessTrainingProgrammeDTO] = try await apiClient.get(
                "/fitness/training-programmes",bypassCache: refresh
            )
            try await repository.cacheTrainingProgrammes(values)
            return FitnessLoadResult(value: values,isFromCache: false)
        } catch {
            guard Self.isOffline(error) else { throw error }
            return FitnessLoadResult(
                value: try await repository.cachedTrainingProgrammes(),isFromCache: true
            )
        }
    }

    func publishRunPlan(_ draft: FitnessRunPlanDraft) async throws -> FitnessWorkoutVersionDTO {
        let validation = FitnessRunPlanSemantics.validate(draft.steps,cues: draft.cues)
        guard validation.isValid else { throw FitnessRunPlanError.invalid(validation.errors) }
        let versionId = UUID().uuidString
        let timestamp = FitnessDatabase.dateString(Date())
        let version = FitnessWorkoutVersionCreateRequest(
            id: versionId,clientId: try apiClient.clientId,clientTimestamp: timestamp,
            title: draft.title,purpose: draft.purpose,
            estimatedDurationS: validation.totals.hasOpenDuration ? nil : validation.totals.durationS,
            estimatedDistanceM: validation.totals.distanceM > 0 ? validation.totals.distanceM : nil,
            structuredSummary: [
                "expected_difficulty": draft.expectedDifficulty.map(JSONValue.string) ?? .null,
                "goal_explanation": draft.goalExplanation.map(JSONValue.string) ?? .null,
                "terrain_assumption": draft.terrainAssumption.map(JSONValue.string) ?? .null,
            ],
            versionSource: "user",exerciseItems: [],runSteps: draft.steps,runCues: draft.cues
        )
        let published: FitnessWorkoutVersionDTO
        if let definitionId = draft.definitionId {
            published = try await apiClient.post(
                "/fitness/workout-definitions/\(definitionId)/versions",body: version
            )
        } else {
            let definitionId = UUID().uuidString
            let request = FitnessWorkoutDefinitionCreateRequest(
                id: definitionId,clientId: try apiClient.clientId,clientTimestamp: timestamp,
                sportKey: "running",name: draft.name,description: draft.description,
                active: true,version: version
            )
            let definition: FitnessWorkoutDefinitionDTO = try await apiClient.post(
                "/fitness/workout-definitions",body: request
            )
            guard let returnedVersion = definition.currentVersion ?? definition.version
                    ?? definition.versions?.first else {
                throw FitnessRunPlanError.missingPublishedVersion
            }
            published = returnedVersion
            try await repository.cacheWorkoutDefinitions([definition])
        }
        do {
            _ = try await workoutDefinitions(refresh: true)
        } catch {
            fitnessActivityServiceLogger.error(
                "Run-plan definitions refresh after publication was deferred: \(error.localizedDescription, privacy: .public)"
            )
        }
        return published
    }

    func acceptRunPlan(definitionId: String,versionId: String) async throws -> FitnessWorkoutVersionDTO {
        let value: FitnessWorkoutVersionDTO = try await apiClient.post(
            "/fitness/workout-definitions/\(definitionId)/versions/\(versionId)/accept",
            body: EmptyBody()
        )
        do {
            _ = try await workoutDefinitions(refresh: true)
        } catch {
            fitnessActivityServiceLogger.error(
                "Run-plan definitions refresh after acceptance was deferred: \(error.localizedDescription, privacy: .public)"
            )
        }
        return value
    }

    func scheduleRunPlan(
        version: FitnessWorkoutVersionDTO,
        placement: FitnessRunPlacementDraft
    ) async throws -> FitnessRemotePlannedSession {
        let timestamp = FitnessDatabase.dateString(Date())
        let schedule: (start: String?,date: String?,windowStart: String?,windowEnd: String?)
        switch placement.precision {
        case .exact:
            schedule=(
                FitnessDatabase.dateString(placement.scheduledStart),
                Self.localDate(placement.scheduledStart),nil,nil
            )
        case .window:
            schedule=(
                nil,Self.localDate(placement.scheduledStart),
                FitnessDatabase.dateString(placement.scheduledStart),
                FitnessDatabase.dateString(placement.windowEnd)
            )
        case .date:
            schedule=(nil,Self.localDate(placement.scheduledDate),nil,nil)
        }
        let goalLinks: [JSONValue]=placement.goalId.map {
            [.object(["goal_id": .string($0),"role": .string("primary")])]
        } ?? []
        let request = FitnessPlannedRunCreateRequest(
            id: UUID().uuidString,clientId: try apiClient.clientId,clientTimestamp: timestamp,
            sportKey: "running",title: placement.title,localTimezone: TimeZone.current.identifier,
            trainingProgrammeId: placement.programmeId,workoutVersionId: version.id,
            status: "scheduled",sessionSource: "user",
            scheduledStartUtc: schedule.start,scheduledDate: schedule.date,
            timeWindowStartUtc: schedule.windowStart,timeWindowEndUtc: schedule.windowEnd,
            expectedDurationS: version.estimatedDurationS,expectedDistanceM: version.estimatedDistanceM,
            priority: 0,movable: placement.movable,visibility: placement.visibility,
            sharedTitle: placement.visibility == "logistics_shared" ? placement.sharedTitle : nil,
            reasonForPlacement: placement.reasonForPlacement,goalLinks: goalLinks,exerciseItems: []
        )
        return try await apiClient.post("/fitness/planned-sessions",body: request)
    }

    private static func localDate(_ date: Date) -> String {
        ISODateParser.stringDateOnly(from: date)
    }

    func plannedSessionAdherence(_ id: String,refresh: Bool = false) async throws -> FitnessLoadResult<FitnessPlanAdherence> {
        do {
            let value: FitnessPlanAdherence = try await apiClient.get(
                "/fitness/planned-sessions/\(id)/adherence",bypassCache: refresh
            )
            try await repository.cacheAdherence(value,ownerType: "planned_session",ownerId: id)
            return FitnessLoadResult(value: value,isFromCache: false)
        } catch {
            guard Self.isOffline(error),let cached = try await repository.cachedAdherence(
                ownerType: "planned_session",ownerId: id
            ) else { throw error }
            return FitnessLoadResult(value: cached,isFromCache: true)
        }
    }

    func createGarminExport(workoutVersionId: String) async throws -> FitnessGarminExport {
        let value: FitnessGarminExport = try await apiClient.post(
            "/fitness/workout-versions/\(workoutVersionId)/garmin-exports",body: EmptyBody()
        )
        try await repository.cacheGarminExport(value)
        return value
    }

    func garminExportStatus(_ id: String,refresh: Bool = true) async throws -> FitnessGarminExport {
        let value: FitnessGarminExport = try await apiClient.get(
            "/fitness/garmin-exports/\(id)",bypassCache: refresh
        )
        try await repository.cacheGarminExport(value)
        return value
    }

    func downloadGarminExport(_ export: FitnessGarminExport) async throws -> URL {
        if let local = try await repository.garminDownloadURL(exportId: export.id) { return local }
        guard UUID(uuidString: export.id) != nil else {
            throw FitnessActivityRepositoryError.invalidFIT
        }
        let temporary = try await apiClient.downloadToTemporaryFile(
            "/fitness/garmin-exports/\(export.id)/download",
            filename: "\(export.id.lowercased()).fit",
            maximumBytes: 8 * 1_024 * 1_024,
            allowedMediaTypes: ["application/vnd.ant.fit"]
        )
        defer {
            do {
                try FileManager.default.removeItem(at: temporary.deletingLastPathComponent())
            } catch {
                fitnessActivityServiceLogger.error(
                    "Temporary Garmin export cleanup was deferred: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        return try await repository.adoptGarminDownload(at: temporary, export: export)
    }

    // MARK: Helpers

    private static func add(_ value: String?,name: String,to query: inout [URLQueryItem]) {
        guard let value,!value.isEmpty else { return }
        query.append(URLQueryItem(name: name,value: value))
    }

    private static func isOffline(_ error: Error) -> Bool {
        guard let api = error as? APIError else { return false }
        if case .networkError = api { return true }
        return false
    }
}

actor FitnessPlanningExperienceService {
    static let shared = FitnessPlanningExperienceService()

    private let apiClient: APIClient
    private let repository: FitnessNutritionRepository

    init(
        apiClient: APIClient = .shared,
        repository: FitnessNutritionRepository = .shared
    ) {
        self.apiClient = apiClient
        self.repository = repository
    }

    func goalTemplates(refresh: Bool = false) async throws -> FitnessLoadResult<[FitnessGoalTemplate]> {
        do {
            let value: [FitnessGoalTemplate] = try await apiClient.get(
                "/fitness/goal-templates",bypassCache: refresh
            )
            try await repository.cacheGoalTemplates(value)
            return FitnessLoadResult(value:value,isFromCache:false)
        } catch {
            let cached = try await repository.cachedGoalTemplates()
            guard !cached.isEmpty else { throw error }
            return FitnessLoadResult(value:cached,isFromCache:true)
        }
    }

    func createGoal(
        template: FitnessGoalTemplate,
        targetValue: Double,
        targetDate: Date?,
        title: String?
    ) async throws -> FitnessGoalFromTemplateResponse {
        let request = FitnessGoalFromTemplateRequest(
            id:UUID().uuidString,templateId:template.id,targetValue:targetValue,
            startsOn:Self.localDate(Date()),targetDate:targetDate.map(Self.localDate),
            title:title?.trimmingCharacters(in:.whitespacesAndNewlines).nilIfEmpty,
            priority:50,clientId:try apiClient.clientId,
            clientTimestamp:FitnessDatabase.dateString(Date())
        )
        let response: FitnessGoalFromTemplateResponse = try await apiClient.post(
            "/fitness/goals/from-template",body:request
        )
        do {
            try await FitnessSyncService.shared.syncNow()
        } catch {
            fitnessActivityServiceLogger.error(
                "Immediate Fitness sync after goal creation was deferred: \(error.localizedDescription, privacy: .public)"
            )
        }
        return response
    }

    func weeklyReview(
        weekStart: Date,
        refresh: Bool = false
    ) async throws -> FitnessLoadResult<FitnessWeeklyReview> {
        let day=Self.localDate(weekStart)
        do {
            let value:FitnessWeeklyReview=try await apiClient.get(
                "/fitness/weekly-review",
                queryItems:[URLQueryItem(name:"week_start",value:day)],
                bypassCache:refresh
            )
            try await repository.cacheWeeklyReview(value)
            return FitnessLoadResult(value:value,isFromCache:false)
        } catch {
            guard let cached=try await repository.cachedWeeklyReview(weekStart:day) else { throw error }
            return FitnessLoadResult(value:cached,isFromCache:true)
        }
    }

    func progressCharts(refresh: Bool = false) async throws -> FitnessLoadResult<FitnessProgressChartsDTO> {
        do {
            let value:FitnessProgressChartsDTO=try await apiClient.get(
                "/fitness/progress/charts",bypassCache:refresh
            )
            try await repository.cacheProgressCharts(value)
            return FitnessLoadResult(value:value,isFromCache:false)
        } catch {
            guard let cached=try await repository.cachedProgressCharts() else { throw error }
            return FitnessLoadResult(value:cached,isFromCache:true)
        }
    }

    private static func localDate(_ date:Date) -> String {
        ISODateParser.stringDateOnly(from: date)
    }
}

private extension String {
    var nilIfEmpty:String? { isEmpty ? nil : self }
}
