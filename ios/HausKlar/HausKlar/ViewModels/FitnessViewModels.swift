import Foundation
import Combine
import CryptoKit
import GRDB
import AuthenticationServices
import UIKit
import os

enum FitnessWithingsAuthorizationError: LocalizedError {
    case couldNotStart
    case missingCallback
    case providerRejected

    var errorDescription: String? {
        switch self {
        case .couldNotStart: "Withings sign-in could not be opened.".localized
        case .missingCallback: "Withings sign-in did not return to HausKlar.".localized
        case .providerRejected: "Withings did not complete the connection. Try again.".localized
        }
    }
}

@MainActor
final class FitnessWithingsAuthorizationSession: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    func authenticate(at url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url,callbackURLScheme: "hausklar"
            ) { [weak self] callback,error in
                self?.session = nil
                if let error {
                    continuation.resume(throwing: error)
                } else if let callback {
                    continuation.resume(returning: callback)
                } else {
                    continuation.resume(throwing: FitnessWithingsAuthorizationError.missingCallback)
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            guard session.start() else {
                self.session = nil
                continuation.resume(throwing: FitnessWithingsAuthorizationError.couldNotStart)
                return
            }
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        return windows.first(where: \.isKeyWindow) ?? windows.first ?? ASPresentationAnchor()
    }
}

@MainActor
class FitnessViewModelBase: ObservableObject {
    @Published var isLoading = false
    @Published var errorMessage: String?
    private let database: FitnessDatabase
    private var storeLease: FitnessStoreLease?
    private static let logger = Logger(
        subsystem: "org.example.hausklar",
        category: "FitnessViewModel"
    )

    init(database: FitnessDatabase = .shared) {
        self.database = database
    }

    func withFitnessStore<T>(_ operation: () async throws -> T) async throws -> T {
        if storeLease == nil,
           let identity = database.activeIdentity {
            storeLease = try database.lease(for: identity)
        }
        guard let storeLease else { throw FitnessDatabaseError.notActive }
        return try await database.withLease(storeLease, operation: operation)
    }

    func run(_ operation: () async throws -> Void) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            try await withFitnessStore(operation)
        } catch {
            errorMessage = error.localizedDescription
            HapticManager.error()
        }
    }

    func recoverableValue<T>(
        section: String,
        userMessage: String? = nil,
        _ operation: () async throws -> T
    ) async -> T? {
        do {
            return try await operation()
        } catch is CancellationError {
            return nil
        } catch {
            Self.logger.error(
                "\(section, privacy: .public) failed: \(error.localizedDescription, privacy: .private)"
            )
            if errorMessage == nil {
                errorMessage = userMessage ?? "\(section) could not be loaded. Try again."
            }
            return nil
        }
    }

    func recordRecoverableFailure(
        section: String,userMessage: String,error: Error? = nil
    ) {
        if let error {
            Self.logger.error(
                "\(section, privacy: .public) failed: \(error.localizedDescription, privacy: .private)"
            )
        } else {
            Self.logger.error("\(section, privacy: .public) failed.")
        }
        if errorMessage == nil { errorMessage = userMessage }
    }

    func syncAfterDurableWrite(context: String) async {
        do {
            try await FitnessSyncService.shared.syncNow()
        } catch is CancellationError {
            return
        } catch {
            Self.logger.error(
                "Immediate Fitness sync after \(context, privacy: .public) failed: \(error.localizedDescription, privacy: .private)"
            )
            if errorMessage == nil {
                errorMessage = "Saved on this iPhone. Fitness will retry syncing automatically."
            }
        }
    }

    func scheduleFitnessSync(after context: String) {
        Task { [weak self] in await self?.syncAfterDurableWrite(context:context) }
    }
}

actor FitnessNextActionService {
    static let shared = FitnessNextActionService()
    private let apiClient: APIClient

    init(apiClient: APIClient = .shared) { self.apiClient = apiClient }

    func load() async throws -> FitnessNextAction {
        try await apiClient.get("/fitness/next-action",bypassCache: true)
    }
}

enum FitnessNextActionDismissalStoreError: LocalizedError, Equatable {
    case identityChanged

    var errorDescription: String? {
        switch self {
        case .identityChanged:
            "The active Fitness profile changed before that dismissal could be saved."
        }
    }
}

@MainActor
struct FitnessNextActionDismissalStore {
    private let database: FitnessDatabase
    private let metadataKey = "next_action_dismissals"

    init(database: FitnessDatabase = .shared) { self.database = database }

    func isDismissed(
        _ action: FitnessNextAction,identity: String,now: Date = Date()
    ) throws -> Bool {
        let key = try fingerprint(action)
        let values = try liveValues(identity: identity,now: now)
        return values[key] == action.expiresAt
    }

    func dismiss(_ action: FitnessNextAction,identity: String,now: Date = Date()) throws {
        guard database.activeIdentity == identity else {
            throw FitnessNextActionDismissalStoreError.identityChanged
        }
        let key = try fingerprint(action)
        var values = try liveValues(identity: identity,now: now)
        values[key] = action.expiresAt
        try save(values,identity:identity)
    }

    private func fingerprint(_ action:FitnessNextAction) throws -> String {
        let encoder=JSONEncoder()
        encoder.outputFormatting=[.sortedKeys]
        let data = try encoder.encode(action)
        return "v2:" + SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined()
    }

    private func liveValues(identity: String,now: Date) throws -> [String:String] {
        guard database.activeIdentity == identity else {
            throw FitnessNextActionDismissalStoreError.identityChanged
        }
        let stored: [String:String] = try database.readCurrent(identity:identity) { db in
            guard let value=try String.fetchOne(
                db,sql:"SELECT value FROM fitness_metadata WHERE key=?",arguments:[metadataKey]
            ) else { return [:] }
            return try JSONDecoder().decode([String:String].self,from:Data(value.utf8))
        }
        let live = stored.filter { _,expiry in
            guard let date=FitnessDatabase.date(expiry) else { return false }
            return date > now
        }
        if live.count != stored.count { try save(live,identity:identity) }
        return live
    }

    private func save(_ values:[String:String],identity:String) throws {
        guard database.activeIdentity == identity else {
            throw FitnessNextActionDismissalStoreError.identityChanged
        }
        let value=String(decoding:try JSONEncoder().encode(values),as:UTF8.self)
        try database.writeCurrent(identity:identity) { db in
            try db.execute(
                sql:"INSERT OR REPLACE INTO fitness_metadata(key,value) VALUES (?,?)",
                arguments:[metadataKey,value]
            )
        }
    }
}

@MainActor
final class FitnessNextActionViewModel: FitnessViewModelBase {
    @Published var nextAction: FitnessNextAction?
    private let service: FitnessNextActionService
    private let dismissalStore: FitnessNextActionDismissalStore

    init(
        service: FitnessNextActionService = .shared,
        dismissalStore: FitnessNextActionDismissalStore? = nil
    ) {
        self.service=service; self.dismissalStore=dismissalStore ?? .init()
    }

    func load() async {
        guard let identity=FitnessDatabase.shared.activeIdentity else {
            nextAction=nil; return
        }
        isLoading=true; errorMessage=nil
        defer { isLoading=false }
        do {
            let value=try await service.load()
            guard FitnessDatabase.shared.activeIdentity == identity else { return }
            nextAction=try dismissalStore.isDismissed(value,identity:identity) ? nil : value
        } catch {
            guard FitnessDatabase.shared.activeIdentity == identity else { return }
            nextAction=nil; errorMessage=error.localizedDescription
        }
    }

    func dismiss() {
        guard let nextAction,let identity=FitnessDatabase.shared.activeIdentity else { return }
        do {
            try dismissalStore.dismiss(nextAction,identity:identity)
            self.nextAction=nil
            HapticManager.selection()
        } catch {
            errorMessage=error.localizedDescription
            HapticManager.error()
        }
    }
}

@MainActor
final class FitnessHubViewModel: FitnessViewModelBase {
    @Published var activeWorkout: FitnessStrengthSession?
    @Published var diary = FitnessDiarySummary(entries: [], totalKcal: 0)
    @Published var weightTrend: Double?
    @Published var weightMeasurements: [FitnessBodyMeasurement] = []
    @Published var notices: [FitnessSyncNotice] = []
    @Published var plans: [FitnessPlannedSession] = []
    @Published var activeIssues: [FitnessBodyIssue] = []
    @Published var nutritionDay = FitnessNutritionDay(
        nutritionDate: "",entries: [],totals: .unknown,uncertainMetrics: [],measuredShare: nil,estimatedShare: nil
    )
    @Published var nutritionTargets: [FitnessNutritionTarget] = []
    @Published var recoverySummary: FitnessRecoverySummaryDTO?
    @Published var gear: [FitnessGearItem] = []
    @Published var pendingMutationCount = 0
    @Published var recordedReadiness: [String:Int] = [:]
    @Published var nextAction: FitnessNextAction?
    @Published var nextActionError: String?
    @Published var mainOutcome: FitnessOnboardingOutcome?
    @Published var recentActivities: [FitnessActivitySummary] = []

    private let repository: FitnessRepository
    private let nutritionRepository: FitnessNutritionRepository
    private let recoveryService: FitnessRecoveryService
    private let activityService: FitnessActivityService
    private let nextActionService: FitnessNextActionService
    private let dismissalStore: FitnessNextActionDismissalStore
    private let nutritionService: FitnessNutritionService
    init(
        repository: FitnessRepository = .shared,
        nutritionRepository: FitnessNutritionRepository = .shared,
        recoveryService: FitnessRecoveryService = .shared,
        activityService: FitnessActivityService = .shared,
        nextActionService: FitnessNextActionService = .shared,
        nutritionService: FitnessNutritionService = .shared,
        dismissalStore: FitnessNextActionDismissalStore? = nil
    ) {
        self.repository=repository; self.nutritionRepository=nutritionRepository
        self.recoveryService=recoveryService; self.activityService=activityService
        self.nextActionService=nextActionService; self.dismissalStore=dismissalStore ?? .init()
        self.nutritionService=nutritionService
    }

    func load() async {
        async let recoveryResult = recoverableValue(section:"Recovery summary") {
            try await self.withFitnessStore { try await self.recoveryService.recoverySummary() }
        }
        async let gearResult = recoverableValue(section:"Fitness gear") {
            try await self.withFitnessStore { try await self.activityService.gear() }
        }
        var calendar = Calendar.current
        calendar.firstWeekday = 2
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: Date())?.start ?? Date()
        let weekFilter = FitnessActivityFilter(
            dateFrom: String(FitnessDatabase.dateString(weekStart).prefix(10))
        )
        async let activitiesResult = recoverableValue(section:"Recent activities") {
            try await self.withFitnessStore {
                try await self.activityService.activities(filter:weekFilter,limit:100)
            }
        }
        async let onboardingResult = recoverableValue(section:"Fitness setup") {
            try await self.withFitnessStore { try await self.nutritionService.onboardingProfile() }
        }
        await run {
            async let workout = repository.activeWorkout()
            async let diary = repository.diary()
            async let weights = repository.bodyMeasurements(limit: 14)
            async let notices = repository.notices()
            async let plans = repository.plannedSessions()
            async let issues = repository.bodyIssues()
            async let nutrition = nutritionRepository.day(on: Date())
            async let targets = nutritionRepository.nutritionTargets()
            self.activeWorkout = try await workout
            self.diary = try await diary
            let loadedWeights = try await weights
            self.weightMeasurements = loadedWeights
            self.weightTrend = FitnessCalculations.sevenDayTrend(loadedWeights)
            self.notices = try await notices
            self.plans = try await plans
            self.activeIssues = try await issues.filter { $0.resolvedAt == nil && $0.status != "resolved" }
            self.nutritionDay = try await nutrition
            self.nutritionTargets = try await targets
            self.pendingMutationCount = try FitnessDatabase.shared.pendingLocalWorkCount()
        }
        recoverySummary = await recoveryResult
        gear = (await gearResult)?.value ?? gear
        recentActivities = (await activitiesResult)?.value ?? recentActivities
        mainOutcome = (await onboardingResult)?.mainOutcome
        await loadNextAction()
    }

    func sync() async {
        do { try await FitnessSyncService.shared.syncNow() } catch { errorMessage = error.localizedDescription }
        await load()
    }

    func dismiss(_ notice: FitnessSyncNotice) async {
        do {
            try await FitnessSyncService.shared.dismissNotice(notice)
            notices.removeAll { $0.id == notice.id }
            HapticManager.success()
        } catch {
            errorMessage = error.localizedDescription
            HapticManager.error()
        }
    }

    func retry(_ notice: FitnessSyncNotice) async {
        guard notice.rejectionDisposition == .retryable,
              let mutationId=notice.rejectedMutationId else { return }
        do {
            try await FitnessSyncService.shared.retryRejectedMutation(mutationId)
            await load()
            HapticManager.success()
        } catch {
            errorMessage=error.localizedDescription
            HapticManager.error()
        }
    }

    var todayPlan: FitnessPlannedSession? {
        todayPlans.first
    }

    var todayPlans: [FitnessPlannedSession] {
        plans.filter { !$0.isCompleted && $0.status != "completed" }.filter { plan in
            guard let date=plan.plannedFor else { return true }
            return Calendar.current.isDateInToday(date)
        }.sorted {
            ($0.scheduledStart ?? $0.timeWindowStart ?? $0.plannedFor ?? .distantPast)
                < ($1.scheduledStart ?? $1.timeWindowStart ?? $1.plannedFor ?? .distantPast)
        }
    }

    var calorieTarget: Double? { targetValue(.caloriesKcal) }
    var proteinTarget: Double? { targetValue(.proteinG) }

    func recordReadiness(_ value: Int,for plan: FitnessPlannedSession) async {
        await run {
            _=try await repository.recordPlannedReadiness(planId: plan.id,value: value)
            recordedReadiness[plan.id]=min(5,max(1,value))
            HapticManager.success()
        }
    }

    func start(_ plan: FitnessPlannedSession) async -> Bool {
        var succeeded=false
        await run {
            activeWorkout=try await repository.startWorkout(
                title: plan.title,planId: plan.id,readiness: recordedReadiness[plan.id],bodyweight: .unknown
            )
            succeeded=true; HapticManager.success()
        }
        return succeeded
    }

    func startBlankStrength() async -> Bool {
        var succeeded=false
        await run {
            let latestWeight=try await repository.latestCanonicalBodyweight()
            let bodyweight=latestWeight.map {
                FitnessBodyweightChoice(kilograms:$0.weightKg,source:.recentCanonical)
            } ?? .unknown
            activeWorkout=try await repository.startWorkout(
                title:"Strength workout",planId:nil,readiness:nil,bodyweight:bodyweight
            )
            succeeded=true; HapticManager.success()
        }
        return succeeded
    }

    func dismissNextAction() {
        guard let nextAction,let identity=FitnessDatabase.shared.activeIdentity else { return }
        do {
            try dismissalStore.dismiss(nextAction,identity:identity)
            self.nextAction=nil
            nextActionError=nil
            HapticManager.selection()
        } catch {
            nextActionError=error.localizedDescription
            HapticManager.error()
        }
    }

    private func loadNextAction() async {
        guard let identity=FitnessDatabase.shared.activeIdentity else {
            nextAction=nil; nextActionError=nil; return
        }
        do {
            let value=try await nextActionService.load()
            guard FitnessDatabase.shared.activeIdentity == identity else { return }
            nextAction=try dismissalStore.isDismissed(value,identity:identity) ? nil : value
            nextActionError=nil
        } catch {
            guard FitnessDatabase.shared.activeIdentity == identity else { return }
            nextAction=nil; nextActionError=error.localizedDescription
        }
    }

    private func targetValue(_ metric: FitnessNutritionMetric) -> Double? {
        guard let target=nutritionTargets.first(where: { $0.metric == metric && $0.active }) else { return nil }
        switch target.mode {
        case .fixed,.weeklyAverage,.phase: return target.targetValue
        case .range: return target.targetMax
        case .trainingRest: return todayPlan == nil ? target.restDayValue : target.trainingDayValue
        }
    }
}

@MainActor
final class FitnessTrainingViewModel: FitnessViewModelBase {
    @Published var goals: [FitnessGoal] = []
    @Published var phases: [FitnessTrainingPhase] = []
    @Published var plans: [FitnessPlannedSession] = []
    @Published var exercises: [FitnessExercise] = []
    @Published var activities: [FitnessActivitySummary] = []
    @Published var gear: [FitnessGearItem] = []
    @Published var programmes: [FitnessTrainingProgrammeDTO] = []
    @Published var definitions: [FitnessWorkoutDefinitionDTO] = []
    @Published var issues: [FitnessBodyIssue] = []
    @Published var setups: [String:[FitnessExerciseSetup]] = [:]
    @Published var savedStrengthWorkouts: [FitnessSavedStrengthWorkout] = []
    @Published var goalTemplates: [FitnessGoalTemplate] = []
    @Published var registeredSports: [FitnessRegisteredSport] = []
    @Published var isSavingQuickSession = false
    private let repository: FitnessRepository
    private let activityService: FitnessActivityService
    private let experienceService: FitnessPlanningExperienceService

    init(
        repository: FitnessRepository = .shared,
        activityService: FitnessActivityService = .shared,
        experienceService: FitnessPlanningExperienceService = .shared
    ) {
        self.repository=repository; self.activityService=activityService
        self.experienceService=experienceService
    }

    /// The Plan landing page needs only the accepted schedule and programme
    /// names. Authoring libraries and setup data stay behind their destinations.
    func loadHome(refresh:Bool=false) async {
        await run { self.plans=try await repository.plannedSessions() }
        async let programmeResult = recoverableValue(section:"Training programmes") {
            try await self.withFitnessStore {
                try await self.activityService.trainingProgrammes(refresh:refresh)
            }
        }
        async let definitionResult = recoverableValue(section:"Workout library") {
            try await self.withFitnessStore {
                try await self.activityService.workoutDefinitions(refresh:refresh)
            }
        }
        if let loaded=await programmeResult { programmes=loaded.value }
        if let loaded=await definitionResult { definitions=loaded.value }
    }

    func loadCreateSupport() async {
        await run {
            async let exercises=repository.exercises()
            async let saved=repository.savedStrengthWorkouts()
            async let goals=repository.goals()
            self.exercises=try await exercises
            self.savedStrengthWorkouts=try await saved
            self.goals=try await goals
        }
    }

    func loadQuickDetails(includeGoals:Bool=true,includeSports:Bool=false) async {
        if includeGoals,goals.isEmpty {
            goals=await recoverableValue(section:"Fitness goals") {
                try await self.withFitnessStore { try await self.repository.goals() }
            } ?? goals
        }
        if includeSports,registeredSports.isEmpty {
            let registry = await recoverableValue(
                section:"Activity types",userMessage:nil,
                {
                    try await self.withFitnessStore {
                        try await self.activityService.activityRegistry().value
                    }
                }
            )
            if let registry {
                registeredSports=registry.sports
            }
        }
    }

    func createQuickSession(
        sportKey:String,
        title:String,
        scheduledStart:Date,
        expectedDurationSeconds:Int?,
        expectedDistanceMetres:Double?,
        expectedPaceSecondsPerKilometre:Double?,
        status:String,
        movable:Bool,
        programmeId:String?,
        primaryGoalId:String?
    ) async -> Bool {
        guard !isSavingQuickSession else { return false }
        isSavingQuickSession=true; errorMessage=nil
        defer { isSavingQuickSession=false }
        do {
            plans=try await withFitnessStore {
                _=try await repository.createQuickPlannedSession(
                    sportKey:sportKey,title:title,scheduledStart:scheduledStart,
                    expectedDurationSeconds:expectedDurationSeconds,
                    expectedDistanceMetres:expectedDistanceMetres,
                    expectedPaceSecondsPerKilometre:expectedPaceSecondsPerKilometre,
                    status:status,movable:movable,programmeId:programmeId,
                    primaryGoalId:primaryGoalId
                )
                return try await repository.plannedSessions()
            }
            HapticManager.success()
            scheduleFitnessSync(after:"planned-session readiness")
            return true
        } catch {
            errorMessage=error.localizedDescription
            HapticManager.error()
            return false
        }
    }

    func logQuickSession(
        payload:FitnessManualActivityPayload,
        sportName:String
    ) async -> Bool {
        guard !isSavingQuickSession else { return false }
        isSavingQuickSession=true; errorMessage=nil
        defer { isSavingQuickSession=false }
        do {
            try await withFitnessStore {
                let defaults=await recoverableValue(section:"Manual activity defaults") {
                    try await self.activityService.manualActivityDefaults().value
                }
                    ?? FitnessManualActivityDefaults(
                        latestWeightKg:nil,latestWeightMeasuredAtUtc:nil,
                        energyEstimationMethod:"adult_compendium_2024_met"
                    )
                let optimistic=FitnessManualActivityCalculator.optimisticSummary(
                    payload:payload,sportName:sportName,defaults:defaults
                )
                _=try await activityService.logManualActivity(payload:payload,optimistic:optimistic)
            }
            HapticManager.success()
            return true
        } catch {
            errorMessage=error.localizedDescription
            HapticManager.error()
            return false
        }
    }

    func loadManage(refresh:Bool=false) async {
        await run {
            async let goals=repository.goals()
            async let phases=repository.trainingPhases()
            async let issues=repository.bodyIssues()
            self.goals=try await goals
            self.phases=try await phases
            self.issues=try await issues
        }
        async let gearResult = recoverableValue(section:"Fitness gear") {
            try await self.withFitnessStore {
                try await self.activityService.gear(refresh:refresh)
            }
        }
        async let templateResult = recoverableValue(section:"Goal templates") {
            try await self.withFitnessStore {
                try await self.experienceService.goalTemplates(refresh:refresh)
            }
        }
        if let loaded=await gearResult { gear=loaded.value }
        if let loaded=await templateResult { goalTemplates=loaded.value }
    }

    func load() async {
        await run {
            async let goals = repository.goals()
            async let phases = repository.trainingPhases()
            async let plans = repository.plannedSessions()
            async let exercises = repository.exercises()
            async let issues = repository.bodyIssues()
            async let saved = repository.savedStrengthWorkouts()
            self.goals = try await goals
            self.phases = try await phases
            self.plans = try await plans
            self.exercises = try await exercises
            self.issues = try await issues
            self.savedStrengthWorkouts = try await saved
        }
        async let activityResult = recoverableValue(section:"Recent activities") {
            try await self.withFitnessStore { try await self.activityService.activities(limit:40) }
        }
        async let gearResult = recoverableValue(section:"Fitness gear") {
            try await self.withFitnessStore { try await self.activityService.gear() }
        }
        async let programmeResult = recoverableValue(section:"Training programmes") {
            try await self.withFitnessStore { try await self.activityService.trainingProgrammes() }
        }
        async let definitionResult = recoverableValue(section:"Workout library") {
            try await self.withFitnessStore { try await self.activityService.workoutDefinitions() }
        }
        activities=(await activityResult)?.value ?? activities
        gear=(await gearResult)?.value ?? gear
        programmes=(await programmeResult)?.value ?? programmes
        definitions=(await definitionResult)?.value ?? definitions
    }

    func createGoal(
        from template:FitnessGoalTemplate,
        targetValue:Double,
        targetDate:Date?,
        title:String?
    ) async -> Bool {
        var succeeded=false
        await run {
            _=try await experienceService.createGoal(
                template:template,targetValue:targetValue,targetDate:targetDate,title:title
            )
            self.goals=try await repository.goals()
            succeeded=true
            HapticManager.success()
        }
        return succeeded
    }

    func createPhase(name: String, type: String, primaryGoalId: String?) async -> Bool {
        var succeeded = false
        await run {
            let links: [(goalId: String, role: FitnessGoalLinkRole)] = primaryGoalId.map {
                [(goalId: $0, role: .primary)]
            } ?? []
            _ = try await repository.createTrainingPhase(
                phaseType: type, name: name, startsOn: Date(), endsOn: nil, goalLinks: links
            )
            self.phases = try await repository.trainingPhases()
            succeeded = true
            HapticManager.success()
        }
        return succeeded
    }

    func createGear(name:String,type:String,brand:String,model:String) async -> Bool {
        var succeeded=false
        await run {
            let trimmedBrand=brand.trimmingCharacters(in:.whitespacesAndNewlines)
            let trimmedModel=model.trimmingCharacters(in:.whitespacesAndNewlines)
            _=try await activityService.createGear(
                name:name.trimmingCharacters(in:.whitespacesAndNewlines),type:type,
                brand:trimmedBrand.isEmpty ? nil : trimmedBrand,
                model:trimmedModel.isEmpty ? nil : trimmedModel
            )
            self.gear=try await activityService.gear(refresh:true).value
            succeeded=true
            HapticManager.success()
        }
        return succeeded
    }

    func setDefaultRunningGear(_ item:FitnessGearItem) async {
        await run {
            _=try await activityService.setDefaultGear(item.id)
            self.gear=try await activityService.gear(refresh:true).value
            HapticManager.success()
        }
    }

    func retireGear(_ item:FitnessGearItem) async {
        await run {
            _=try await activityService.retireGear(item.id)
            self.gear=try await activityService.gear(refresh:true).value
            HapticManager.success()
        }
    }

    func createPlan(
        title: String,
        date: Date?,
        exerciseIds: [String],
        workingSets: Int,
        targetReps: Int?
    ) async -> Bool {
        var succeeded = false
        await run {
            _ = try await repository.createPlannedSession(
                title: title, plannedFor: date, exerciseIds: exerciseIds,
                workingSets: workingSets, targetReps: targetReps
            )
            self.plans = try await repository.plannedSessions()
            succeeded = true
            HapticManager.success()
        }
        return succeeded
    }

    func loadSetups(for exerciseId: String) async {
        do {
            setups[exerciseId]=try await withFitnessStore {
                try await repository.setups(for: exerciseId)
            }
        }
        catch { errorMessage=error.localizedDescription }
    }

    func createStrengthPlan(_ draft: FitnessStrengthPlanDraft) async -> Bool {
        var succeeded=false
        await run {
            _=try await repository.createStrengthPlan(draft)
            self.plans=try await repository.plannedSessions()
            self.savedStrengthWorkouts=try await repository.savedStrengthWorkouts()
            succeeded=true
            HapticManager.success()
            scheduleFitnessSync(after:"saved-workout update")
        }
        return succeeded
    }

    func updatePlannedSession(_ draft: FitnessPlannedSessionEditDraft) async -> Bool {
        var succeeded=false
        await run {
            _=try await repository.updatePlannedSession(draft)
            plans=try await repository.plannedSessions()
            succeeded=true
            HapticManager.success()
            scheduleFitnessSync(after:"planned-session update")
        }
        return succeeded
    }
}

@MainActor
final class LegacyFitnessStrengthViewModel: FitnessViewModelBase {
    @Published var activeWorkout: FitnessStrengthSession?
    @Published var workoutExercises: [FitnessWorkoutExercise] = []
    @Published var exercises: [FitnessExercise] = []
    @Published var plans: [FitnessPlannedSession] = []
    private let repository: FitnessRepository

    init(repository: FitnessRepository = .shared) { self.repository = repository }

    func load() async {
        await run {
            async let active = repository.activeWorkout()
            async let library = repository.exercises()
            async let plans = repository.plannedSessions()
            self.activeWorkout = try await active
            self.exercises = try await library
            self.plans = try await plans
            if let activeWorkout {
                self.workoutExercises = try await repository.workoutExercises(sessionId: activeWorkout.id)
            } else {
                self.workoutExercises = []
            }
        }
    }

    func createExercise(name: String, category: String, mode: FitnessLoadMode) async -> Bool {
        var succeeded = false
        await run {
            _ = try await repository.createExercise(name: name, category: category, loadMode: mode)
            self.exercises = try await repository.exercises()
            succeeded = true
            HapticManager.success()
        }
        return succeeded
    }

    func start(title: String, plan: FitnessPlannedSession?, readiness: Int?) async {
        await run {
            let workout = try await repository.startWorkout(
                title: title, planId: plan?.id, readiness: readiness
            )
            self.activeWorkout = workout
            self.workoutExercises = try await repository.workoutExercises(sessionId: workout.id)
            HapticManager.success()
        }
    }

    func addExercise(_ exercise: FitnessExercise) async {
        guard let activeWorkout else { return }
        await run {
            _ = try await repository.addExercise(exercise.id, to: activeWorkout.id)
            self.workoutExercises = try await repository.workoutExercises(sessionId: activeWorkout.id)
            HapticManager.selection()
        }
    }

    func addSet(
        to exercise: FitnessSessionExercise,
        role: FitnessSetRole,
        structure: FitnessSetStructure,
        isAMRAP: Bool,
        groupStatus: FitnessSetStatus,
        componentStatus: FitnessComponentStatus,
        loadKg: Double?,
        reps: Int?,
        rir: Double?,
        rpe: Double?,
        failure: FitnessFailureType
    ) async {
        guard let activeWorkout else { return }
        await run {
            _ = try await repository.addSet(
                to: exercise.id, sessionId: activeWorkout.id, role: role,
                structure: structure, isAMRAP: isAMRAP,
                groupStatus: groupStatus, componentStatus: componentStatus, loadKg: loadKg,
                reps: reps, rir: rir, rpe: rpe, failureState: failure
            )
            self.workoutExercises = try await repository.workoutExercises(sessionId: activeWorkout.id)
            HapticManager.success()
        }
    }

    func addDrop(to group: FitnessSetGroup, loadKg: Double?, reps: Int?) async {
        guard let activeWorkout else { return }
        await run {
            _ = try await repository.addDropComponent(
                to: group.id, loadKg: loadKg, reps: reps, rir: nil, rpe: nil
            )
            self.workoutExercises = try await repository.workoutExercises(sessionId: activeWorkout.id)
            HapticManager.selection()
        }
    }

    func addLateReadiness(_ value: Int) async {
        guard let activeWorkout else { return }
        await run {
            try await repository.addLateReadiness(value, sessionId: activeWorkout.id)
            self.activeWorkout = try await repository.activeWorkout()
        }
    }

    func finish(rpe: Double?, performance: Int?, note: String?, issue: NewBodyIssue?) async -> Bool {
        guard let activeWorkout else { return false }
        var succeeded = false
        await run {
            try await repository.finishWorkout(
                sessionId: activeWorkout.id, rpe: rpe,
                performance: performance, note: note, issue: issue
            )
            self.activeWorkout = nil
            self.workoutExercises = []
            succeeded = true
            HapticManager.success()
        }
        return succeeded
    }

    func abandon() async {
        guard let activeWorkout else { return }
        await run {
            try await repository.abandonWorkout(sessionId: activeWorkout.id)
            self.activeWorkout = nil
            self.workoutExercises = []
        }
    }
}

@MainActor
final class FitnessProgressViewModel: FitnessViewModelBase {
    @Published var strength: [FitnessStrengthSummary] = []
    @Published var weights: [FitnessBodyMeasurement] = []
    @Published var goals: [FitnessGoal] = []
    @Published var phases: [FitnessTrainingPhase] = []
    @Published var exerciseSeries: [FitnessStrengthProgressSeries] = []
    @Published var muscleExposure: [FitnessMuscleExposure] = []
    @Published var activities: [FitnessActivitySummary] = []
    @Published var recoverySummary: FitnessRecoverySummaryDTO?
    @Published var weeklyReview: FitnessWeeklyReview?
    @Published var progressCharts = FitnessProgressChartsDTO.empty
    @Published var progressChartsLoading = true
    @Published var progressChartsError: String?
    @Published private(set) var trendReferenceDate=Date()
    private let repository: FitnessRepository
    private let activityService: FitnessActivityService
    private let recoveryService: FitnessRecoveryService
    private let experienceService: FitnessPlanningExperienceService
    init(
        repository: FitnessRepository = .shared,
        activityService: FitnessActivityService = .shared,
        recoveryService: FitnessRecoveryService = .shared,
        experienceService: FitnessPlanningExperienceService = .shared
    ) {
        self.repository=repository; self.activityService=activityService
        self.recoveryService=recoveryService; self.experienceService=experienceService
    }

    func loadHome(refresh:Bool=false,now:Date=Date()) async {
        trendReferenceDate=now
        isLoading = weeklyReview == nil && activities.isEmpty
        errorMessage=nil
        progressChartsLoading=true
        progressChartsError=nil
        let monday=FitnessProgressLoadPolicy.currentMonday(for:now)
        let activityFilter=FitnessProgressLoadPolicy.fourWeekActivityFilter(for:now)
        async let reviewResult = recoverableValue(section:"Weekly review") {
            try await self.withFitnessStore {
                try await self.experienceService.weeklyReview(
                    weekStart:monday,refresh:refresh
                )
            }
        }
        async let activityResult = recoverableValue(section:"Progress activities") {
            try await self.withFitnessStore {
                try await self.activityService.activities(
                    filter:activityFilter,limit:200,refresh:refresh
                )
            }
        }
        async let localGoals = recoverableValue(section:"Progress goals") {
            try await self.withFitnessStore { try await self.repository.goals() }
        }
        async let localWeights = recoverableValue(section:"Weight trend") {
            try await self.withFitnessStore {
                try await self.repository.bodyMeasurements(limit:120)
            }
        }
        async let chartResult = withFitnessStore {
            try await experienceService.progressCharts(refresh:refresh)
        }
        if let loaded=await reviewResult { weeklyReview=loaded.value }
        if let loaded=await activityResult { activities=loaded.value }
        if let loaded=await localGoals { goals=loaded }
        if let loaded=await localWeights { weights=loaded }
        // Weekly context and activity history are enough to paint this screen.
        // Charts keep their own loading state and complete independently.
        isLoading=false
        do {
            progressCharts=(try await chartResult).value
        } catch {
            progressChartsError="Performance trends could not be loaded.".localized
        }
        progressChartsLoading=false
        if weeklyReview == nil && activities.isEmpty {
            errorMessage="Progress could not be loaded. Try again.".localized
        }
    }

    func loadProgressCharts(refresh:Bool=false) async {
        progressChartsLoading=true
        progressChartsError=nil
        defer { progressChartsLoading=false }
        do {
            progressCharts=try await withFitnessStore {
                try await experienceService.progressCharts(refresh:refresh).value
            }
        } catch {
            progressChartsError="Performance trends could not be loaded.".localized
        }
    }

    func loadStrengthDetails() async {
        await run {
            async let strength=repository.strengthProgress()
            async let series=repository.strengthExerciseProgress()
            async let muscles=repository.muscleExposure()
            self.strength=try await strength
            self.exerciseSeries=try await series
            self.muscleExposure=try await muscles
        }
    }

    func load() async {
        await run {
            async let strength = repository.strengthProgress()
            async let weights = repository.bodyMeasurements()
            async let goals = repository.goals()
            async let phases = repository.trainingPhases()
            async let series = repository.strengthExerciseProgress()
            async let muscles = repository.muscleExposure()
            self.strength = try await strength
            self.weights = try await weights
            self.goals = try await goals
            self.phases = try await phases
            self.exerciseSeries = try await series
            self.muscleExposure = try await muscles
        }
        async let activityResult = recoverableValue(section:"Recent activities") {
            try await self.activityService.activities(limit:30)
        }
        async let recoveryResult = recoverableValue(section:"Recovery summary") {
            try await self.recoveryService.recoverySummary()
        }
        activities=(await activityResult)?.value ?? activities
        recoverySummary=await recoveryResult
    }
}

@MainActor
final class FitnessMeasurementTrendsViewModel: FitnessViewModelBase {
    @Published var metric: FitnessMeasurementMetric = .weight
    @Published var displayMode: FitnessMeasurementDisplayMode = .trend
    @Published var history: FitnessMeasurementHistoryDTO?
    @Published var withingsStatus: FitnessWithingsConnectionStatusDTO?
    @Published var isUsingCachedData = false
    @Published var isAuthorizing = false
    @Published var isSyncingWithings = false
    @Published var noticeMessage: String?

    private let recoveryService: FitnessRecoveryService
    private let authorizationSession: FitnessWithingsAuthorizationSession

    init(
        recoveryService: FitnessRecoveryService = .shared,
        authorizationSession: FitnessWithingsAuthorizationSession? = nil
    ) {
        self.recoveryService = recoveryService
        self.authorizationSession = authorizationSession ?? .init()
    }

    func load(refresh: Bool = false) async {
        isLoading = history == nil
        errorMessage = nil
        defer { isLoading = false }
        async let statusResult: Void = loadStatus(refresh: refresh)
        await loadHistory(refresh: refresh)
        await statusResult
    }

    func loadConnectionStatus(refresh:Bool=false) async {
        await loadStatus(refresh:refresh)
    }

    func selectMetric(_ value: FitnessMeasurementMetric) async {
        guard metric != value else { return }
        metric = value
        history = nil
        await loadHistory(refresh: false)
    }

    func loadHistory(refresh: Bool) async {
        let requestedMetric = metric
        if history == nil { isLoading = true }
        do {
            let result = try await recoveryService.measurementHistory(
                metric: requestedMetric,refresh: refresh
            )
            guard requestedMetric == metric else { return }
            history = result.value
            isUsingCachedData = result.isFromCache
            errorMessage = nil
        } catch {
            guard requestedMetric == metric else { return }
            errorMessage = error.localizedDescription
            HapticManager.error()
        }
        isLoading = false
    }

    func connectWithings() async {
        guard !isAuthorizing else { return }
        isAuthorizing = true
        errorMessage = nil
        noticeMessage = nil
        defer { isAuthorizing = false }
        do {
            let url = try await recoveryService.startWithingsAuthorization()
            let callback = try await authorizationSession.authenticate(at: url)
            guard HausKlarAuthorizationCallback(url: callback, provider: .withings) == .connected else {
                throw FitnessWithingsAuthorizationError.providerRejected
            }
            noticeMessage = "Withings connected. Importing your measurement history…"
            HapticManager.success()
            do {
                try await Task.sleep(for:.milliseconds(700))
            } catch is CancellationError {
                return
            } catch {
                recordRecoverableFailure(
                    section:"Withings import delay",
                    userMessage:"Withings connected. Pull to refresh imported measurements.",
                    error:error
                )
                return
            }
            await loadStatus(refresh: true)
            await importServerChanges()
            await loadHistory(refresh: true)
        } catch let error as ASWebAuthenticationSessionError
            where error.code == .canceledLogin {
            noticeMessage = "Withings connection cancelled."
        } catch {
            errorMessage = error.localizedDescription
            HapticManager.error()
        }
    }

    func syncWithingsNow() async {
        guard !isSyncingWithings else { return }
        isSyncingWithings = true
        errorMessage = nil
        defer { isSyncingWithings = false }
        do {
            let result = try await recoveryService.syncWithings()
            await importServerChanges()
            await loadStatus(refresh: true)
            await loadHistory(refresh: true)
            let changed = result.imported + result.updated
            noticeMessage = changed == 0
                ? "Withings is up to date."
                : "Updated (changed) measurement\(changed == 1 ? "" : "s") from Withings."
            HapticManager.success()
        } catch {
            errorMessage = error.localizedDescription
            HapticManager.error()
        }
    }

    func disconnectWithings() async {
        errorMessage = nil
        do {
            let result = try await recoveryService.disconnectWithings()
            await loadStatus(refresh: true)
            noticeMessage = "Withings disconnected. (result.retainedMeasurementCount) imported measurement\(result.retainedMeasurementCount == 1 ? "" : "s") kept."
            HapticManager.success()
        } catch {
            errorMessage = error.localizedDescription
            HapticManager.error()
        }
    }

    func refreshAfterFitnessSync() async {
        await loadStatus(refresh: true)
        await loadHistory(refresh: true)
    }

    private func loadStatus(refresh: Bool) async {
        do {
            withingsStatus = try await recoveryService.withingsStatus(refresh: refresh)
        } catch {
            if withingsStatus == nil,errorMessage == nil {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func importServerChanges() async {
        do {
            try await FitnessSyncService.shared.syncNow()
        } catch {
            // The chart endpoint already reflects the provider import. The normal
            // 45-second Fitness loop will retry the encrypted local cache update.
        }
    }
}

@MainActor
final class FitnessBodyMeasurementsViewModel: FitnessViewModelBase {
    @Published var measurements: [FitnessBodyMeasurement] = []
    private let repository: FitnessRepository

    init(repository: FitnessRepository = .shared) {
        self.repository=repository
    }

    func load() async {
        await run {
            try await self.reloadLocal()
        }
    }

    func save(
        existing: FitnessBodyMeasurement?, metricKey: String, value: Double,
        unitKey: String, notes: String?, measuredAt: Date, quality: String
    ) async -> Bool {
        var succeeded = false
        await run {
            _ = try await self.repository.saveBodyMeasurement(
                id: existing?.id ?? UUID().uuidString,metricKey: metricKey,value: value,
                unitKey: unitKey,notes: notes,measuredAt: measuredAt,
                measurementQuality: quality
            )
            try await self.reloadLocal()
            succeeded = true
            HapticManager.success()
            scheduleFitnessSync(after:"body-measurement update")
        }
        return succeeded
    }

    private func reloadLocal() async throws {
        measurements=try await repository.bodyMeasurements(
            limit: 500,includeDuplicates: false,metricKey: nil
        )
    }
}

@MainActor
final class FitnessRecoveryViewModel: FitnessViewModelBase {
    @Published var issues: [FitnessBodyIssue] = []
    @Published var readiness: [FitnessReadinessHistoryItem] = []
    @Published var sleepSessions: [FitnessSleepSessionDTO] = []
    @Published var observations: [FitnessRecoveryObservationDTO] = []
    @Published var summary: FitnessRecoverySummaryDTO?
    @Published var healthAccess: FitnessHealthKitAccessState = .notRequested
    @Published var isUsingCachedHealthData = false
    @Published var bodyLocations: [FitnessBodyLocation] = FitnessBodyLocation.fallback
    private let repository: FitnessRepository
    private let recoveryService: FitnessRecoveryService
    private let healthKitService: FitnessHealthKitService
    private let strengthService: FitnessStrengthService
    init(
        repository: FitnessRepository = .shared,
        recoveryService: FitnessRecoveryService = .shared,
        healthKitService: FitnessHealthKitService = .shared,
        strengthService: FitnessStrengthService = .shared
    ) {
        self.repository = repository
        self.recoveryService = recoveryService
        self.healthKitService = healthKitService
        self.strengthService = strengthService
    }

    func load(refresh: Bool = false) async {
        isLoading = true
        errorMessage = nil
        healthAccess = await healthKitService.accessState()
        defer { isLoading = false }
        do {
            async let issueValues = withFitnessStore { try await repository.bodyIssues() }
            async let readinessValues = withFitnessStore { try await repository.readinessHistory() }
            async let sleepValues = recoveryService.sleepSessions(refresh: refresh)
            async let observationValues = recoveryService.recoveryObservations(refresh: refresh)
            async let locationValues = strengthService.bodyLocations()
            issues = try await issueValues
            readiness = try await readinessValues
            let loadedSleep = try await sleepValues
            let loadedObservations = try await observationValues
            sleepSessions = loadedSleep.value
            observations = loadedObservations.value
            bodyLocations = await locationValues
            isUsingCachedHealthData = loadedSleep.isFromCache || loadedObservations.isFromCache
        } catch {
            errorMessage = error.localizedDescription
        }
        do {
            summary = try await recoveryService.recoverySummary(refresh: refresh)
        } catch {
            if errorMessage == nil { errorMessage = error.localizedDescription }
        }
        healthAccess = await healthKitService.accessState()
    }

    func loadHealthAccess() async {
        healthAccess=await healthKitService.accessState()
    }

    func requestHealthAccess() async {
        await run { try await healthKitService.requestAuthorizationAndImport() }
        await load(refresh: true)
    }

    func importHealthNow() async {
        await healthKitService.importAllChanges()
        await load(refresh: true)
    }

    func saveManualSleep(
        existing: FitnessSleepSessionDTO?,start: Date,end: Date,
        awakeMinutes: Double?,notes: String?
    ) async -> Bool {
        var succeeded=false
        await run {
            _=try await repository.saveManualSleepSession(
                existing: existing,start: start,end: end,
                awakeMinutes: awakeMinutes,notes: notes
            )
            self.sleepSessions=try await FitnessHealthRepository.shared.localSleepSessions()
            succeeded=true
            HapticManager.success()
            scheduleFitnessSync(after:"sleep update")
        }
        return succeeded
    }

    func addIssue(_ issue: NewBodyIssue) async -> Bool {
        var succeeded = false
        await run {
            _ = try await repository.addBodyIssue(issue)
            self.issues = try await repository.bodyIssues()
            succeeded = true
            HapticManager.success()
        }
        return succeeded
    }
}

/// Shared by Fitness Recovery and Calendar's shortcut. All edits are written
/// optimistically to Fitness GRDB and queued in the Fitness outbox.
@MainActor
final class FitnessCycleTrackingViewModel: FitnessViewModelBase {
    @Published private(set) var profiles: [CycleProfileDTO] = []
    @Published var cycleLengthDays=28
    @Published var showPeriodStarts=true
    @Published var showPredictedPeriod=true
    @Published var showEstimatedOvulation=true
    @Published var sharePeriodStartsWithAdults=false
    @Published var sharePredictedPeriodWithAdults=false
    @Published var shareEstimatedOvulationWithAdults=false
    @Published var periodStartDate=Date()
    @Published private(set) var isWorking=false
    @Published private(set) var isUsingCachedData=false
    @Published var notice: String?

    private let repository: FitnessRepository
    private let apiClient: APIClient

    init(
        repository: FitnessRepository = .shared,
        apiClient: APIClient = .shared
    ) {
        self.repository=repository; self.apiClient=apiClient
    }

    var ownProfile: CycleProfileDTO? { profiles.first(where: \.isOwner) }
    var sharedProfiles: [CycleProfileDTO] { profiles.filter { !$0.isOwner } }

    func load(refresh: Bool = false) async {
        let hadProfiles = !profiles.isEmpty
        if !hadProfiles { isLoading=true }
        errorMessage=nil; notice=nil
        defer { isLoading=false }
        do {
            let local=try await withFitnessStore { try await repository.cycleProfiles() }
            profiles=local
            if let own=local.first(where: \.isOwner) { applySettings(own) }
        } catch {
            errorMessage=error.localizedDescription
            return
        }
        do {
            let remote: [CycleProfileDTO] = try await apiClient.get(
                "/fitness/cycles",bypassCache: refresh
            )
            profiles=try await withFitnessStore {
                try await repository.cacheCycleProfiles(remote)
                return try await repository.cycleProfiles()
            }
            if let own=ownProfile { applySettings(own) }
            isUsingCachedData=false
        } catch let primaryError {
            isUsingCachedData = !profiles.isEmpty
            if profiles.isEmpty {
                // One-time transition safety: an existing cached/remote legacy
                // profile can seed Fitness, but its broad consent never enables
                // any of the new category permissions.
                do {
                    let legacy: [CycleProfileDTO] = try await apiClient.get("/cycles/")
                    profiles=try await withFitnessStore {
                        try await repository.cacheCycleProfiles(legacy)
                        return try await repository.cycleProfiles()
                    }
                    if let own=ownProfile { applySettings(own) }
                    if !profiles.isEmpty {
                        notice="Your existing cycle record was moved into Fitness. Review the new sharing choices; each starts off."
                    }
                } catch {
                    errorMessage=primaryError.localizedDescription
                }
            }
        }
    }

    func saveSettings() async -> Bool {
        guard (10...365).contains(cycleLengthDays) else {
            errorMessage=FitnessRepositoryError.invalidCycleLength.localizedDescription
            return false
        }
        isWorking=true; errorMessage=nil; notice=nil
        defer { isWorking=false }
        do {
            profiles=try await withFitnessStore {
                _=try await repository.saveCycleSettings(
                    existing: ownProfile,cycleLengthDays: cycleLengthDays,
                    showPeriodStarts: showPeriodStarts,
                    showPredictedPeriod: showPredictedPeriod,
                    showEstimatedOvulation: showEstimatedOvulation,
                    sharePeriodStartsWithAdults: sharePeriodStartsWithAdults,
                    sharePredictedPeriodWithAdults: sharePredictedPeriodWithAdults,
                    shareEstimatedOvulationWithAdults: shareEstimatedOvulationWithAdults
                )
                return try await repository.cycleProfiles()
            }
            notice=ownProfile?.revision == 0
                ? "Cycle tracking is saved and will sync automatically."
                : "Cycle settings saved and queued for sync."
            HapticManager.success()
            scheduleFitnessSync(after:"cycle-settings update")
            return true
        } catch {
            errorMessage=error.localizedDescription; HapticManager.error(); return false
        }
    }

    func recordPeriodStart() async -> Bool {
        guard let profile=ownProfile else {
            errorMessage=FitnessRepositoryError.missingCycleSettings.localizedDescription
            return false
        }
        isWorking=true; errorMessage=nil; notice=nil
        defer { isWorking=false }
        do {
            profiles=try await withFitnessStore {
                _=try await repository.recordCyclePeriodStart(
                    profile: profile,startedOn: Self.dateOnlyFormatter.string(from: periodStartDate)
                )
                return try await repository.cycleProfiles()
            }
            notice="Period start saved and queued for sync."
            HapticManager.success()
            scheduleFitnessSync(after:"period-start update")
            return true
        } catch {
            errorMessage=error.localizedDescription; HapticManager.error(); return false
        }
    }

    func deletePeriodStart(_ period: CyclePeriodStartDTO) async -> Bool {
        isWorking=true; errorMessage=nil; notice=nil
        defer { isWorking=false }
        do {
            profiles=try await withFitnessStore {
                try await repository.deleteCyclePeriodStart(period)
                return try await repository.cycleProfiles()
            }
            notice="Period start removal queued for sync."
            HapticManager.success()
            scheduleFitnessSync(after:"period-start removal")
            return true
        } catch {
            errorMessage=error.localizedDescription; HapticManager.error(); return false
        }
    }

    static func displayDate(_ value: String?) -> String {
        guard let value,let date=dateOnlyFormatter.date(from: value) else {
            return "Waiting for a period start".localized
        }
        return displayFormatter.string(from: date)
    }

    private func applySettings(_ profile: CycleProfileDTO) {
        cycleLengthDays=profile.cycleLengthDays
        showPeriodStarts=profile.showPeriodStarts
        showPredictedPeriod=profile.showPredictedPeriod
        showEstimatedOvulation=profile.showEstimatedOvulation
        // Missing new permissions and legacy all-or-nothing consent both map
        // to false; sharing can only be enabled by an explicit new edit.
        sharePeriodStartsWithAdults=profile.sharePeriodStartsWithAdults
        sharePredictedPeriodWithAdults=profile.sharePredictedPeriodWithAdults
        shareEstimatedOvulationWithAdults=profile.shareEstimatedOvulationWithAdults
    }

    private static let dateOnlyFormatter: DateFormatter = {
        let formatter=DateFormatter()
        formatter.calendar=Calendar(identifier: .gregorian)
        formatter.locale=Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat="yyyy-MM-dd"
        return formatter
    }()
    private static let displayFormatter: DateFormatter = {
        let formatter=DateFormatter(); formatter.dateStyle = .medium; formatter.timeStyle = .none
        return formatter
    }()
}

@MainActor
final class FitnessProgressPhotoViewModel: FitnessViewModelBase {
    @Published var photos: [FitnessProgressPhotoDTO] = []
    @Published var pending: [FitnessPendingProgressPhoto] = []
    @Published var phases: [FitnessTrainingPhase] = []
    @Published var thumbnailURLs: [String: URL] = [:]
    @Published var comparisonURLs: [String: URL] = [:]

    private let service: FitnessRecoveryService
    private let repository: FitnessRepository

    init(service: FitnessRecoveryService = .shared,repository: FitnessRepository = .shared) {
        self.service = service
        self.repository = repository
    }

    func load(refresh: Bool = false) async {
        await run {
            async let gallery = service.progressPhotos(refresh: refresh)
            async let pending = service.pendingProgressPhotos()
            async let phases = repository.trainingPhases()
            self.photos = try await gallery.value
            self.pending = try await pending
            self.phases = try await phases
        }
        let expectedPhotoIDs=photos.map(\.id)
        let pending=photos.prefix(40).filter { thumbnailURLs[$0.id] == nil }
        let photoService=service
        let thumbnailResult=await withTaskGroup(
            of:(String,URL?,Bool).self,returning:([String:URL],Bool).self
        ) { group in
            var nextIndex=0
            func add(_ photo:FitnessProgressPhotoDTO) {
                group.addTask { [photoService] in
                    do {
                        let url=try await photoService.representationURL(
                            photo:photo,representation:"thumbnail"
                        )
                        return (photo.id,url,false)
                    } catch is CancellationError {
                        return (photo.id,nil,false)
                    } catch {
                        return (photo.id,nil,true)
                    }
                }
            }
            while nextIndex < min(6,pending.count) {
                add(pending[nextIndex]); nextIndex += 1
            }
            var result:[String:URL]=[:]
            var hadFailure=false
            while let (id,url,failed)=await group.next() {
                if let url { result[id]=url }
                hadFailure = hadFailure || failed
                if nextIndex < pending.count {
                    add(pending[nextIndex]); nextIndex += 1
                }
            }
            return (result,hadFailure)
        }
        guard photos.map(\.id) == expectedPhotoIDs else { return }
        thumbnailURLs.merge(thumbnailResult.0) { _,new in new }
        if thumbnailResult.1 {
            recordRecoverableFailure(
                section:"Progress-photo thumbnails",
                userMessage:"Some progress-photo previews could not be loaded. Pull to try again."
            )
        }
    }

    func save(
        artifact: FitnessProgressPhotoArtifact,capturedAt: Date,pose: FitnessProgressPhotoPose,
        weightKg: Double?,phaseId: String?,notes: String?
    ) async -> Bool {
        var succeeded = false
        await run {
            _ = try await service.createProgressPhoto(
                artifact: artifact,capturedAt: capturedAt,pose: pose,bodyWeightKg: weightKg,
                phaseId: phaseId,notes: notes
            )
            succeeded = true
            HapticManager.success()
        }
        if succeeded {
            FitnessProgressPhotoPreparation.removeArtifact(artifact)
            await load()
        }
        return succeeded
    }

    func retry(assetId: String) async {
        await service.retryProgressPhoto(assetId)
        await load(refresh: true)
    }

    func delete(_ photo: FitnessProgressPhotoDTO) async -> Bool {
        var succeeded = false
        await run {
            try await service.deleteProgressPhoto(photo)
            thumbnailURLs.removeValue(forKey: photo.id)
            comparisonURLs.removeValue(forKey: photo.id)
            succeeded = true
            HapticManager.success()
        }
        if succeeded { await load() }
        return succeeded
    }

    func loadOriginal(_ photo: FitnessProgressPhotoDTO) async {
        if comparisonURLs[photo.id] != nil { return }
        await run {
            comparisonURLs[photo.id] = try await service.representationURL(
                photo: photo,representation: "original"
            )
        }
    }

    func regenerateThumbnail(_ photo: FitnessProgressPhotoDTO) async {
        await run {
            try await service.regenerateThumbnail(photo)
            thumbnailURLs.removeValue(forKey: photo.id)
        }
        await load(refresh: true)
    }

    func pendingItem(photoId: String) -> FitnessPendingProgressPhoto? {
        pending.first { $0.photo.id == photoId }
    }
}

@MainActor
final class FitnessTodayHealthViewModel: FitnessViewModelBase {
    @Published var healthAccess: FitnessHealthKitAccessState = .notRequested
    @Published var latestSleep: FitnessSleepSessionDTO?
    @Published var latestRestingHeartRate: FitnessRecoveryObservationDTO?
    @Published var latestHRV: FitnessRecoveryObservationDTO?

    private let healthKitService: FitnessHealthKitService
    private let recoveryService: FitnessRecoveryService

    init(
        healthKitService: FitnessHealthKitService = .shared,
        recoveryService: FitnessRecoveryService = .shared
    ) {
        self.healthKitService = healthKitService
        self.recoveryService = recoveryService
    }

    func load(refresh: Bool = false) async {
        healthAccess = await healthKitService.accessState()
        await run {
            async let sleep = recoveryService.sleepSessions(refresh: refresh)
            async let observations = recoveryService.recoveryObservations(refresh: refresh)
            latestSleep = try await sleep.value.first
            let values = try await observations.value
            latestRestingHeartRate = values.first { $0.metricKey == "recovery.resting_heart_rate_bpm" }
            latestHRV = values.first { $0.metricKey == "recovery.hrv_sdnn_ms" }
        }
        healthAccess = await healthKitService.accessState()
    }

    func requestHealthAccess() async {
        await run { try await healthKitService.requestAuthorizationAndImport() }
        await load(refresh: true)
    }
}

@MainActor final class FitnessExploreViewModel: FitnessViewModelBase {}
