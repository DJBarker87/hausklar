import Foundation
import UniformTypeIdentifiers

@MainActor
final class FitnessActivityHistoryViewModel: FitnessViewModelBase {
    @Published var activities: [FitnessActivitySummary] = []
    @Published var pendingImports: [FitnessPendingFITImport] = []
    @Published var unownedSharedImports: [SharedFitnessFITPayload] = []
    @Published var sharedImportRecoveryItems: [SharedFitnessFITPayload] = []
    @Published var gear: [FitnessGearItem] = []
    @Published var registeredSports: [FitnessRegisteredSport] = []
    @Published var filter = FitnessActivityFilter()
    @Published var isFromCache = false
    @Published var manualActivityDefaults: FitnessManualActivityDefaults?
    @Published var isSavingManualActivity = false

    private let service: FitnessActivityService
    private let fitnessRepository: FitnessRepository

    init(
        service: FitnessActivityService = .shared,
        fitnessRepository: FitnessRepository = .shared
    ) {
        self.service = service
        self.fitnessRepository = fitnessRepository
        super.init()
    }

    func strengthWorkoutExportText(activityId: String) async -> String? {
        do {
            guard let session=try await fitnessRepository.strengthSession(id: activityId) else {
                errorMessage="This strength workout is not available offline yet."
                return nil
            }
            let exercises=try await fitnessRepository.workoutExercises(sessionId: activityId)
            return FitnessStrengthTextExport.text(session: session,exercises: exercises)
        } catch {
            errorMessage=error.localizedDescription
            return nil
        }
    }

    func load(refresh: Bool = false) async {
        await run {
            async let activitiesResult = service.activities(filter: filter, refresh: refresh)
            async let importsResult = service.pendingFITImports()
            async let unownedResult = service.unownedSharedFITImports()
            async let recoveryResult = service.sharedFITRecoveryItems()
            async let gearResult = recoverableValue(section:"Activity gear") {
                try await self.service.gear(refresh:refresh)
            }
            async let registryResult = recoverableValue(section:"Activity types") {
                try await self.service.activityRegistry(refresh:refresh)
            }
            let result = try await activitiesResult
            activities = result.value
            isFromCache = result.isFromCache
            pendingImports = try await importsResult
            unownedSharedImports = await unownedResult
            sharedImportRecoveryItems = await recoveryResult
            gear = (await gearResult)?.value ?? gear
            if let registry = (await registryResult)?.value {
                registeredSports = registry.sports
            }
            // An offline first launch may not have a registry cache yet. Keep
            // locally present sports filterable without inventing a fixed list.
            let known=Set(registeredSports.map(\.key))
            registeredSports += Set(activities.map(\.sportKey)).subtracting(known).sorted().map {
                FitnessRegisteredSport(
                    key: $0,
                    displayName: $0.replacingOccurrences(of: "_",with: " ").capitalized
                )
            }
        }
    }

    func importFIT(_ url: URL) async {
        await run {
            _ = try await service.stageFIT(from: url)
            pendingImports = try await service.pendingFITImports()
            HapticManager.success()
        }
    }

    func loadManualActivityDefaults() async {
        do {
            manualActivityDefaults = try await withFitnessStore {
                try await service.manualActivityDefaults().value
            }
        } catch {
            recordRecoverableFailure(
                section:"Manual activity defaults",
                userMessage:"Recent activity defaults could not be loaded; review the values before saving.",
                error:error
            )
            manualActivityDefaults = FitnessManualActivityDefaults(
                latestWeightKg: nil,
                latestWeightMeasuredAtUtc: nil,
                energyEstimationMethod: "adult_compendium_2024_met"
            )
        }
    }

    func logManualActivity(
        payload: FitnessManualActivityPayload,
        sportName: String
    ) async -> Bool {
        isSavingManualActivity = true
        errorMessage = nil
        defer { isSavingManualActivity = false }
        do {
            let optimistic = FitnessManualActivityCalculator.optimisticSummary(
                payload: payload,
                sportName: sportName,
                defaults: manualActivityDefaults
            )
            let saved = try await withFitnessStore {
                try await service.logManualActivity(
                    payload: payload,
                    optimistic: optimistic
                )
            }
            activities.removeAll { $0.id == saved.id }
            activities.insert(saved,at: 0)
            HapticManager.success()
            return true
        } catch {
            errorMessage = error.localizedDescription
            HapticManager.error()
            return false
        }
    }

    func refreshImports() async {
        do {
            pendingImports = try await withFitnessStore {
                await service.refreshFITImports()
                return try await service.pendingFITImports()
            }
        } catch is CancellationError {
            return
        } catch {
            recordRecoverableFailure(
                section:"FIT imports",
                userMessage:"Waiting FIT imports could not be refreshed. Try again.",
                error:error
            )
        }
        unownedSharedImports = await service.unownedSharedFITImports()
        sharedImportRecoveryItems = await service.sharedFITRecoveryItems()
    }

    func retry(_ item: FitnessPendingFITImport) async {
        await run {
            try await service.retryFITImport(item.id)
            pendingImports = try await service.pendingFITImports()
        }
    }

    func dismiss(_ item: FitnessPendingFITImport) async {
        await run {
            try await service.removeAcknowledgedFITImport(item.id)
            pendingImports = try await service.pendingFITImports()
        }
    }

    func adoptUnowned(_ item: SharedFitnessFITPayload) async {
        await run {
            try await service.adoptUnownedSharedFIT(item.id)
            pendingImports = try await service.pendingFITImports()
            unownedSharedImports = await service.unownedSharedFITImports()
            sharedImportRecoveryItems = await service.sharedFITRecoveryItems()
            HapticManager.success()
        }
    }
}

@MainActor
final class FitnessActivityDetailViewModel: FitnessViewModelBase {
    @Published var detail: FitnessActivityDetail?
    @Published var stream: FitnessActivityStream?
    @Published var routeStream: FitnessActivityStream?
    @Published var analysis: FitnessActivityAnalysisResponse?
    @Published var comparisons: [FitnessComparableRun] = []
    @Published var selectedComparisonIds: Set<String> = []
    @Published var comparisonOverlay: FitnessActivityComparisonOverlay?
    @Published var isLoadingComparisonOverlay = false
    @Published var adherence: FitnessPlanAdherence?
    @Published var availableGear: [FitnessGearItem] = []
    @Published var availableGoals: [FitnessGoal] = []
    @Published var selectedOffsetMs: Int?
    @Published var selectedClock = "elapsed"
    @Published var isFromCache = false
    @Published private(set) var isLoadingStream = false
    @Published private(set) var didAttemptStreamLoad = false
    @Published private(set) var isLoadingComparisons = false

    let activityId: String
    private let service: FitnessActivityService
    private let fitnessRepository: FitnessRepository

    init(
        activityId: String,
        service: FitnessActivityService = .shared,
        fitnessRepository: FitnessRepository = .shared
    ) {
        self.activityId = activityId
        self.service = service
        self.fitnessRepository = fitnessRepository
        super.init()
    }

    func load(refresh: Bool = false) async {
        await run {
            let loaded = try await service.activityDetail(activityId, refresh: refresh)
            detail = loaded.value
            isFromCache = loaded.isFromCache
        }
        guard detail != nil else { return }
        await loadSupportingData(refresh: refresh)
    }

    func loadSupportingData(refresh: Bool) async {
        guard let detail else { return }
        isLoadingComparisons = true
        let requestedMetrics = activityStreamMetrics(detail)
        isLoadingStream = !requestedMetrics.isEmpty
        didAttemptStreamLoad = requestedMetrics.isEmpty
        async let analysisResult = recoverableValue(section:"Activity analysis") {
            try await self.withFitnessStore {
                try await self.service.analysis(self.activityId,refresh:refresh)
            }
        }
        async let comparisonsResult = recoverableValue(section:"Activity comparisons") {
            try await self.withFitnessStore {
                try await self.service.comparisons(self.activityId,refresh:refresh)
            }
        }
        async let adherenceResult = recoverableValue(section:"Plan adherence") {
            try await self.withFitnessStore {
                try await self.service.activityAdherence(self.activityId,refresh:refresh)
            }
        }
        async let gearResult = recoverableValue(section:"Activity gear") {
            try await self.withFitnessStore { try await self.service.gear(refresh:refresh) }
        }
        async let goalsResult = recoverableValue(section:"Activity goals") {
            try await self.withFitnessStore { try await self.fitnessRepository.goals() }
        }
        async let routeResult = loadRouteStream(
            availableMetrics: Set(detail.availableStreamMetrics),
            refresh: refresh
        )
        if !requestedMetrics.isEmpty {
            do {
                let loaded = try await withFitnessStore {
                    try await service.stream(
                        activityId: activityId, metrics: requestedMetrics, clock: selectedClock,
                        maxPoints: 800, refresh: refresh
                    )
                }
                stream = loaded.value
                selectedOffsetMs = selectedOffsetMs ?? loaded.value.offsetMs.first
            } catch {
                stream = nil
                recordRecoverableFailure(
                    section:"Activity chart",
                    userMessage:"The activity chart could not be loaded. Try again.",
                    error:error
                )
            }
            isLoadingStream = false
            didAttemptStreamLoad = true
        }
        routeStream = await routeResult
        analysis = (await analysisResult)?.value
        let hadSelection = !selectedComparisonIds.isEmpty
        comparisons = (await comparisonsResult)?.value ?? []
        isLoadingComparisons = false
        selectedComparisonIds = selectedComparisonIds.intersection(Set(comparisons.map(\.id)))
        if !hadSelection {
            let suggested=comparisons.filter { $0.selected == true }
            selectedComparisonIds=Set((suggested.isEmpty ? comparisons : suggested).prefix(5).map(\.id))
        }
        adherence = (await adherenceResult)?.value ?? detail.adherence
        availableGear = (await gearResult)?.value ?? availableGear
        availableGoals = await goalsResult ?? availableGoals
    }

    private func loadRouteStream(
        availableMetrics: Set<String>,
        refresh: Bool
    ) async -> FitnessActivityStream? {
        guard availableMetrics.contains("latitude_deg"),
              availableMetrics.contains("longitude_deg") else { return nil }
        return await recoverableValue(section:"Activity route") {
            try await self.withFitnessStore {
                try await self.service.stream(
                    activityId:self.activityId,
                    metrics:["latitude_deg","longitude_deg"],
                    clock:self.selectedClock,
                    maxPoints:20_000,
                    refresh:refresh
                ).value
            }
        }
    }

    func toggleComparison(_ id: String) {
        if selectedComparisonIds.contains(id) {
            selectedComparisonIds.remove(id)
        } else if selectedComparisonIds.count < 5 {
            selectedComparisonIds.insert(id)
        }
        comparisonOverlay = nil
    }

    func loadComparisonOverlay() async {
        guard !selectedComparisonIds.isEmpty else {
            comparisonOverlay = nil
            return
        }
        isLoadingComparisonOverlay = true
        defer { isLoadingComparisonOverlay = false }
        do {
            let detailMetrics = Set(detail?.availableStreamMetrics ?? [])
            let metrics = ["pace_s_per_km", "heart_rate_bpm", "altitude_m"]
                .filter(detailMetrics.contains)
            comparisonOverlay = try await service.comparisonOverlay(
                activityId: activityId,
                comparisonIds: selectedComparisonIds.sorted(),
                metrics: metrics.isEmpty ? ["pace_s_per_km"] : metrics
            )
        } catch {
            errorMessage = error.localizedDescription
            HapticManager.error()
        }
    }

    func loadRange(fromOffsetMs: Int, toOffsetMs: Int) async {
        guard let detail else { return }
        let metrics = activityStreamMetrics(detail)
        guard !metrics.isEmpty else { return }
        await run {
            stream = try await service.stream(
                activityId: activityId, metrics: metrics, clock: selectedClock,
                fromOffsetMs: fromOffsetMs, toOffsetMs: toOffsetMs,
                maxPoints: 1_200, refresh: true
            ).value
        }
    }

    func loadOverview() async {
        guard let detail else { return }
        let metrics = activityStreamMetrics(detail)
        guard !metrics.isEmpty else { return }
        await run {
            stream = try await service.stream(
                activityId: activityId, metrics: metrics, clock: selectedClock,
                maxPoints: 800, refresh: true
            ).value
        }
    }

    func changeClock(_ clock: String) async {
        selectedClock = clock
        stream = nil
        routeStream = nil
        didAttemptStreamLoad = false
        await loadSupportingData(refresh: true)
    }

    private func activityStreamMetrics(_ detail: FitnessActivityDetail) -> [String] {
        let preferred = [
            "pace_s_per_km", "speed_mps", "heart_rate_bpm", "altitude_m", "cadence_spm",
            "power_w", "stride_length_m", "vertical_oscillation_mm", "vertical_ratio_pct",
            "ground_contact_time_ms", "ground_contact_balance_pct", "respiration_rate_bpm",
            "temperature_c", "stroke_rate_spm",
        ]
        let excluded = Set([
            "elapsed_ms", "timer_ms", "distance_m", "latitude_deg", "longitude_deg",
        ])
        let available = detail.availableStreamMetrics.filter { !excluded.contains($0) }
        return preferred.filter(available.contains) + available.filter { !preferred.contains($0) }
    }

    func updateContext(
        title: String?, notes: String?, sessionRPE: Double?,
        classification: String?, gearIds: [String]?
    ) async -> Bool {
        var succeeded = false
        await run {
            detail = try await service.updateActivityContext(
                activityId: activityId,
                update: FitnessActivityContextUpdate(
                    title: title, notes: notes, sessionRpe: sessionRPE,
                    workoutClassification: classification,
                    plannedSessionId: detail?.plannedSession?.id,
                    gearIds: gearIds
                )
            ) ?? detail
            succeeded = true
            HapticManager.success()
        }
        return succeeded
    }

    func reanalyse() async {
        guard detail?.sources.contains(where:\.hasRetainedFitFile) == true else {
            errorMessage = "This activity has no retained manual FIT file to reanalyse."
            return
        }
        await run {
            _ = try await service.reanalyseActivity(activityId)
            // The retained FIT source is rebuilt asynchronously. Refreshing here
            // immediately exposes the queued/regenerating state; pull-to-refresh
            // then picks up the replacement analysis when the worker finishes.
            let loaded = try await service.activityDetail(activityId, refresh: true)
            detail = loaded.value
            isFromCache = loaded.isFromCache
            await loadSupportingData(refresh: true)
            HapticManager.success()
        }
    }

    func saveGoalLinks(_ goalIds: Set<String>) async -> Bool {
        var succeeded=false
        await run {
            let links=try await service.replaceActivityGoalLinks(
                activityId: activityId,goalIds: goalIds
            )
            detail?.goalLinks=links
            succeeded=true
            HapticManager.success()
        }
        return succeeded
    }
}

@MainActor
final class FitnessRunPlansViewModel: FitnessViewModelBase {
    @Published var definitions: [FitnessWorkoutDefinitionDTO] = []
    @Published var programmes: [FitnessTrainingProgrammeDTO] = []
    @Published var goals: [FitnessGoal] = []
    @Published var drafts: [FitnessRunPlanDraft] = []
    @Published var editorDraft: FitnessRunPlanDraft?
    @Published var publishedVersion: FitnessWorkoutVersionDTO?
    @Published var garminExport: FitnessGarminExport?
    @Published var shareURL: URL?

    private let service: FitnessActivityService
    private let repository: FitnessRepository

    init(service: FitnessActivityService = .shared,repository: FitnessRepository = .shared) {
        self.service = service
        self.repository = repository
        super.init()
    }

    func load(refresh: Bool = false) async {
        await run {
            async let definitionResult = service.workoutDefinitions(refresh: refresh)
            async let programmeResult = recoverableValue(section:"Training programmes") {
                try await self.service.trainingProgrammes(refresh:refresh)
            }
            async let goalResult = recoverableValue(section:"Run-plan goals") {
                try await self.repository.goals()
            }
            async let draftResult = service.runPlanDrafts()
            definitions = try await definitionResult.value
            programmes = (await programmeResult)?.value ?? []
            goals = await goalResult ?? []
            drafts = try await draftResult
        }
    }

    func newDraft() {
        editorDraft = FitnessRunPlanDraft(
            id: UUID().uuidString, definitionId: nil, name: "New run",
            description: nil, title: "New run", purpose: nil,
            expectedDifficulty: "moderate", goalExplanation: nil,
            terrainAssumption: nil, steps: [], cues: [], updatedAt: Date()
        )
    }

    func edit(_ draft: FitnessRunPlanDraft) { editorDraft = draft }

    func duplicate(_ definition: FitnessWorkoutDefinitionDTO) {
        guard let version = definition.currentVersion ?? definition.version ?? definition.versions?.first else { return }
        editorDraft = FitnessRunPlanDraft(
            id: UUID().uuidString, definitionId: definition.id,
            name: definition.name, description: definition.description,
            title: version.title, purpose: version.purpose,
            expectedDifficulty: version.structuredSummary?["expected_difficulty"]?.stringValue,
            goalExplanation: version.structuredSummary?["goal_explanation"]?.stringValue,
            terrainAssumption: version.structuredSummary?["terrain_assumption"]?.stringValue,
            steps: version.runSteps ?? [], cues: version.runCues ?? [], updatedAt: Date()
        )
    }

    func saveDraft() async -> Bool {
        guard var draft = editorDraft else { return false }
        var succeeded = false
        await run {
            draft.updatedAt = Date()
            try await service.saveRunPlanDraft(draft)
            editorDraft = draft
            drafts = try await service.runPlanDrafts()
            succeeded = true
            HapticManager.success()
        }
        return succeeded
    }

    func publish() async -> Bool {
        guard let draft = editorDraft else { return false }
        var succeeded = false
        await run {
            publishedVersion = try await service.publishRunPlan(draft)
            definitions = try await service.workoutDefinitions(refresh: true).value
            succeeded = true
            HapticManager.success()
        }
        return succeeded
    }

    func accept(definitionId: String, version: FitnessWorkoutVersionDTO) async {
        await run {
            publishedVersion = try await service.acceptRunPlan(
                definitionId: definitionId, versionId: version.id
            )
            definitions = try await service.workoutDefinitions(refresh: true).value
            HapticManager.success()
        }
    }

    func schedule(version: FitnessWorkoutVersionDTO,placement: FitnessRunPlacementDraft) async -> Bool {
        var succeeded = false
        await run {
            _ = try await service.scheduleRunPlan(version: version,placement: placement)
            succeeded = true
            HapticManager.success()
        }
        return succeeded
    }

    func exportToGarmin(_ version: FitnessWorkoutVersionDTO) async {
        await run {
            garminExport = try await service.createGarminExport(workoutVersionId: version.id)
            if garminExport?.isDownloadReady == true, let value = garminExport {
                shareURL = try await service.downloadGarminExport(value)
            }
        }
    }

    func refreshGarminExport() async {
        guard let value = garminExport else { return }
        await run {
            garminExport = try await service.garminExportStatus(value.id)
            if garminExport?.isDownloadReady == true, let completed = garminExport {
                shareURL = try await service.downloadGarminExport(completed)
                HapticManager.success()
            }
        }
    }
}

@MainActor
final class FitnessAnalysisViewModel: FitnessViewModelBase {
    @Published var registry: FitnessAnalysisRegistry?
    @Published var result: FitnessAnalysisQueryResult?
    @Published var savedCharts: [FitnessSavedAnalysisChart] = []
    @Published var dimensionKey = ""
    @Published var measureKey = ""
    @Published var chartTypeKey: FitnessAnalysisChartType = .line
    @Published var filters: [FitnessAnalysisFilter] = []
    @Published var comparisonKey = ""
    @Published var startDate = Calendar.current.date(byAdding: .day,value: -83,to: Date()) ?? Date()
    @Published var endDate = Date()
    @Published var maxPoints = 100
    @Published var isQuerying = false
    @Published var isFromCache = false
    @Published var savedChartsFromCache = false
    @Published var saveName = ""
    @Published var savedChartError: String?

    private let service: FitnessActivityService
    private let preferredSurface: String
    private var queryTask: Task<Void,Never>?

    init(
        service: FitnessActivityService = .shared,
        preferredSurface: String = "explore"
    ) {
        self.service = service
        self.preferredSurface = preferredSurface
        super.init()
    }

    var selectedMeasure: FitnessAnalysisRegistry.Measure? {
        registry?.measures.first { $0.key == measureKey }
    }

    var availableDimensions: [FitnessAnalysisRegistry.Dimension] {
        guard let registry,let measure = selectedMeasure else { return [] }
        return registry.dimensions.filter { measure.supportedDimensions.contains($0.key) }
    }

    var availableCharts: [FitnessAnalysisRegistry.ChartTypeDefinition] {
        guard let registry,let measure = selectedMeasure else { return [] }
        return registry.chartTypes.filter { measure.chartTypes.contains($0.key) }
    }

    var availableFilterDefinitions: [FitnessAnalysisRegistry.FilterDefinition] {
        guard let registry,let measure = selectedMeasure else { return [] }
        return registry.filters.filter { measure.allowedFilterKeys.contains($0.key) }
    }

    var availableComparisons: [FitnessAnalysisRegistry.Comparison] {
        guard let registry,let measure = selectedMeasure else { return [] }
        return registry.comparisons.filter { measure.comparisonForms?.contains($0.key) == true }
    }

    var presets: [FitnessAnalysisRegistry.DefaultQuery] {
        guard let registry else { return [] }
        return registry.defaultQueries.filter {
            if preferredSurface == "progress" { return $0.surface == "progress" || $0.surface == "both" }
            return $0.surface != "progress"
        }
    }

    var queryRequest: FitnessAnalysisQueryRequest? {
        guard let registry else { return nil }
        return FitnessAnalysisQueryRequest(
            measureKey: measureKey,
            dimensionKey: dimensionKey,
            chartTypeKey: chartTypeKey,
            dateRange: FitnessAnalysisDateRange(
                start: FitnessAnalysisQueryValidator.localDateString(startDate),
                end: FitnessAnalysisQueryValidator.localDateString(endDate)
            ),
            filters: filters,
            comparisonKey: comparisonKey.isEmpty ? nil : comparisonKey,
            maxPoints: min(maxPoints,registry.limits.maxOutputPoints)
        )
    }

    var queryProblem: String? {
        guard let registry,let queryRequest else { return "No analysis options are available." }
        return FitnessAnalysisQueryValidator.problem(with: queryRequest,registry: registry)
    }

    func load(runFirstPreset: Bool = false) async {
        let needsInitialSelection = measureKey.isEmpty
        var selectedInitialPreset = false
        await run {
            let loaded = try await service.analysisRegistry()
            registry = loaded.value
            isFromCache = loaded.isFromCache
            maxPoints = loaded.value.limits.maxOutputPoints
            if needsInitialSelection,
               let preset = presets.first(where: { isRegistered($0,in: loaded.value) }) {
                apply(preset)
                selectedInitialPreset = true
            } else if needsInitialSelection {
                measureKey = loaded.value.measures.first?.key ?? ""
                normalizeSelection()
            } else {
                normalizeSelection()
            }
            do {
                let saved = try await service.savedAnalysisCharts()
                savedCharts = saved.value
                savedChartsFromCache = saved.isFromCache
                savedChartError = nil
            } catch {
                savedChartError = error.localizedDescription
            }
        }
        if runFirstPreset,selectedInitialPreset,queryProblem == nil { await query() }
    }

    func query() async {
        guard let registry,let queryRequest else { return }
        if let problem = FitnessAnalysisQueryValidator.problem(with: queryRequest,registry: registry) {
            errorMessage = problem
            return
        }
        isQuerying = true
        errorMessage = nil
        defer { isQuerying = false }
        do {
            let loaded = try await withFitnessStore {
                try await service.analysisQuery(queryRequest,registry: registry)
            }
            result = loaded.value
            isFromCache = loaded.isFromCache
            HapticManager.success()
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
            HapticManager.error()
        }
    }

    func startQuery() {
        queryTask?.cancel()
        queryTask = Task { [weak self] in await self?.query() }
    }

    func cancelQuery() {
        queryTask?.cancel()
        queryTask = nil
        isQuerying = false
    }

    func selectMeasure(_ key: String) {
        measureKey = key
        normalizeSelection()
        result = nil
    }

    func normalizeSelection() {
        guard let registry,let measure = selectedMeasure ?? registry.measures.first else { return }
        measureKey = measure.key
        if !measure.supportedDimensions.contains(dimensionKey) {
            dimensionKey = measure.supportedDimensions.first ?? registry.dimensions.first?.key ?? ""
        }
        if !measure.chartTypes.contains(chartTypeKey) {
            chartTypeKey = measure.defaultChartType ?? measure.chartTypes.first ?? .table
        }
        filters = filters.filter { measure.allowedFilterKeys.contains($0.key) }
        if !comparisonKey.isEmpty,measure.comparisonForms?.contains(comparisonKey) != true {
            comparisonKey = ""
        }
    }

    func apply(_ preset: FitnessAnalysisRegistry.DefaultQuery) {
        guard let registry,isRegistered(preset,in: registry) else { return }
        let query = FitnessAnalysisQueryValidator.query(from: preset,registry: registry)
        measureKey = query.measureKey
        dimensionKey = query.dimensionKey
        chartTypeKey = query.chartTypeKey
        filters = query.filters
        comparisonKey = query.comparisonKey ?? ""
        maxPoints = query.maxPoints
        startDate = analysisDate(query.dateRange.start) ?? startDate
        endDate = analysisDate(query.dateRange.end) ?? endDate
        result = nil
        errorMessage = nil
    }

    func apply(_ saved: FitnessSavedAnalysisChart) {
        guard let registry,
              let measure = registry.measures.first(where: { $0.key == saved.measureKey }),
              measure.supportedDimensions.contains(saved.dimensionKey),
              measure.chartTypes.contains(saved.chartTypeKey) else {
            savedChartError = "That saved chart uses an option that is no longer available."
            return
        }
        measureKey = saved.measureKey
        dimensionKey = saved.dimensionKey
        chartTypeKey = saved.chartTypeKey
        comparisonKey = saved.comparisonKey.flatMap {
            measure.comparisonForms?.contains($0) == true ? $0 : nil
        } ?? ""
        endDate = Date()
        startDate = Calendar.current.date(
            byAdding: .day,value: -(min(saved.dateWindowDays,registry.limits.maxWindowDays) - 1),to: endDate
        ) ?? startDate
        filters = saved.filterKeys.compactMap { key in
            guard measure.allowedFilterKeys.contains(key),
                  let definition = registry.filters.first(where: { $0.key == key }) else { return nil }
            return FitnessAnalysisFilter(
                key: key,operator: definition.operators.first ?? .equal,
                value: defaultValue(for: definition)
            )
        }
        result = nil
        savedChartError = nil
    }

    func addFilter(_ definition: FitnessAnalysisRegistry.FilterDefinition) {
        guard let registry,filters.count < registry.limits.maxFilters,
              !filters.contains(where: { $0.key == definition.key }) else { return }
        filters.append(
            FitnessAnalysisFilter(
                key: definition.key,operator: definition.operators.first ?? .equal,
                value: defaultValue(for: definition)
            )
        )
    }

    func removeFilter(_ key: String) { filters.removeAll { $0.key == key } }

    func saveCurrentChart() async {
        guard let registry,let queryRequest,
              let payload = FitnessAnalysisQueryValidator.savedPayload(
                name: saveName.isEmpty ? (selectedMeasure?.label ?? "Saved analysis") : saveName,
                query: queryRequest,registry: registry
              ) else {
            savedChartError = queryProblem ?? "That chart cannot be saved."
            return
        }
        do {
            let value = try await withFitnessStore {
                try await service.saveAnalysisChart(payload,registry: registry)
            }
            savedCharts.removeAll { $0.id == value.id }
            savedCharts.insert(value,at: 0)
            saveName = ""
            savedChartError = nil
            HapticManager.success()
        } catch {
            savedChartError = error.localizedDescription
            HapticManager.error()
        }
    }

    func deleteSavedChart(_ value: FitnessSavedAnalysisChart) async {
        do {
            try await withFitnessStore { try await service.deleteAnalysisChart(value.id) }
            savedCharts.removeAll { $0.id == value.id }
            HapticManager.success()
        } catch {
            savedChartError = error.localizedDescription
            HapticManager.error()
        }
    }

    private func isRegistered(
        _ preset: FitnessAnalysisRegistry.DefaultQuery,
        in registry: FitnessAnalysisRegistry
    ) -> Bool {
        guard let measure = registry.measures.first(where: { $0.key == preset.measureKey }) else { return false }
        return measure.supportedDimensions.contains(preset.dimensionKey)
            && measure.chartTypes.contains(preset.chartTypeKey)
            && registry.chartTypes.contains(where: { $0.key == preset.chartTypeKey })
    }

    private func defaultValue(for definition: FitnessAnalysisRegistry.FilterDefinition) -> JSONValue {
        if let first = definition.values?.first { return .string(first.key) }
        switch definition.valueType {
        case "number": return .double(0)
        case "boolean": return .bool(false)
        default: return .string("")
        }
    }

    private func analysisDate(_ value: String) -> Date? {
        var components = DateComponents()
        let parts = value.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        components.year = parts[0]
        components.month = parts[1]
        components.day = parts[2]
        return Calendar.current.date(from: components)
    }
}
