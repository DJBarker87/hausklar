import Foundation
import HealthKit
import os

private let fitnessHealthKitLogger = Logger(
    subsystem: "org.example.hausklar",
    category: "FitnessHealthKitService"
)

private typealias FitnessHealthKitAnchoredPage = (
    samples: [HKSample],deleted: [HKDeletedObject],anchor: HKQueryAnchor?,hasMore: Bool
)

/// Bridges HealthKit's callback query to structured cancellation. Account
/// replacement must be able to stop and join an in-flight anchored query rather
/// than wait indefinitely for a callback owned by the previous profile.
///
/// `lock` guards `query`, `continuation`, and `finished`, making installation,
/// completion, and cancellation one mutually exclusive terminal transition.
/// HealthKit starts callback delivery only after `execute` returns; keeping
/// installation and `execute` under the recursive lock closes the cancellation
/// race. Completion and cancellation extract the continuation at most once and
/// resume it outside the lock. This is the invariant behind unchecked Sendable.
private final class FitnessHealthKitQueryBridge: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private let store: HKHealthStore
    private var continuation: CheckedContinuation<FitnessHealthKitAnchoredPage,Error>?
    private var query: HKAnchoredObjectQuery?
    private var finished = false

    init(store: HKHealthStore) { self.store = store }

    func install(
        query: HKAnchoredObjectQuery,
        continuation: CheckedContinuation<FitnessHealthKitAnchoredPage,Error>
    ) {
        lock.lock()
        if finished {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.query = query
        self.continuation = continuation
        // Keep installation and execute ordered with cancellation. HealthKit's
        // execute call returns before it delivers the asynchronous callback.
        store.execute(query)
        lock.unlock()
    }

    func complete(_ result: Result<FitnessHealthKitAnchoredPage,Error>) {
        let continuation = lock.withLock { () -> CheckedContinuation<FitnessHealthKitAnchoredPage,Error>? in
            guard !finished else { return nil }
            finished = true
            query = nil
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(with: result)
    }

    func cancel() {
        let values = lock.withLock { () -> (
            HKAnchoredObjectQuery?,CheckedContinuation<FitnessHealthKitAnchoredPage,Error>?
        ) in
            guard !finished else { return (nil,nil) }
            finished = true
            let values = (query,continuation)
            query = nil
            continuation = nil
            return values
        }
        if let query = values.0 { store.stop(query) }
        values.1?.resume(throwing: CancellationError())
    }
}

/// HealthKit's observer completion closure is not declared Sendable even though
/// the framework requires it to be retained and called after asynchronous work.
/// This one-shot box gives that ownership transfer a locked, auditable boundary.
private final class FitnessHealthKitObserverCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: (() -> Void)?

    init(_ completion: @escaping () -> Void) {
        self.completion = completion
    }

    func finish() {
        let completion = lock.withLock { () -> (() -> Void)? in
            defer { self.completion = nil }
            return self.completion
        }
        completion?()
    }
}

enum FitnessHealthKitPagingPolicy {
    static let anchoredPageSize=500

    static func hasMore(sampleCount:Int,deletionCount:Int) -> Bool {
        sampleCount+deletionCount>=anchoredPageSize
    }
}

/// Coalesces Health observer callbacks while an anchored query is suspended.
/// Keeping this state in one small value makes exact-page, concurrent-delivery,
/// failure and account-replacement transitions directly unit-testable.
struct FitnessHealthKitRunGate {
    private(set) var running=Set<FitnessHealthKitSampleKind>()
    private(set) var pending=Set<FitnessHealthKitSampleKind>()

    mutating func request(_ kind:FitnessHealthKitSampleKind) -> Bool {
        if running.contains(kind) {
            pending.insert(kind)
            return false
        }
        running.insert(kind)
        return true
    }

    mutating func beginIteration(_ kind:FitnessHealthKitSampleKind) {
        pending.remove(kind)
    }

    mutating func requestAnotherPage(_ kind:FitnessHealthKitSampleKind) {
        pending.insert(kind)
    }

    func shouldContinue(_ kind:FitnessHealthKitSampleKind) -> Bool {
        pending.contains(kind)
    }

    mutating func finish(_ kind:FitnessHealthKitSampleKind) {
        running.remove(kind)
        pending.remove(kind)
    }

    mutating func reset() {
        running.removeAll()
        pending.removeAll()
    }
}

actor FitnessHealthKitService {
    static let shared = FitnessHealthKitService()

    private let healthStore: HKHealthStore
    private let repository: FitnessHealthRepository
    private let apiClient:APIClient
    private let database:FitnessDatabase
    private var identity: String?
    private var storeLease:FitnessStoreLease?
    private var activationGeneration:UInt64=0
    private var observerQueries: [HKObserverQuery] = []
    private var runGate=FitnessHealthKitRunGate()
    private var lastImportError: String?
    private var lastWorkoutReplayError: String?
    private struct QueryJob {
        let id: UUID
        let task: Task<Void,Never>
    }
    private struct FlushJob {
        let id: UUID
        let task: Task<Void,Never>
    }
    private var queryJobs: [FitnessHealthKitSampleKind:QueryJob] = [:]
    private var flushJob: FlushJob?
    private var pendingFlushTurns = 0
    private var workoutReplayNotBefore: Date?

    init(
        healthStore: HKHealthStore = HKHealthStore(),
        repository: FitnessHealthRepository = .shared,
        apiClient:APIClient = .shared,
        database:FitnessDatabase = .shared
    ) {
        self.healthStore = healthStore
        self.repository = repository
        self.apiClient=apiClient
        self.database=database
    }

    func activate(identity: String) async {
        if self.identity == identity,let storeLease {
            do {
                try database.validate(storeLease)
                return
            } catch {
                fitnessHealthKitLogger.notice(
                    "Replacing an expired HealthKit owner lease: \(error.localizedDescription, privacy: .private)"
                )
            }
        }
        await suspend()
        let lease: FitnessStoreLease
        do {
            lease = try database.lease(for: identity)
        } catch {
            lastImportError = "Health import could not open this Fitness profile: \(error.localizedDescription)"
            fitnessHealthKitLogger.error(
                "HealthKit activation failed closed at the owner boundary: \(error.localizedDescription, privacy: .private)"
            )
            return
        }
        activationGeneration &+= 1
        let generation=activationGeneration
        self.identity = identity
        storeLease=lease
        // Durable workout pages may predate this process. Replay is independent
        // of whether the user has since disabled new HealthKit reads.
        schedulePendingWorkoutImports(
            maximumTurns: FitnessHealthKitWorkoutOutboxPolicy.maximumReplayTurns
        )
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let importEnabled: Bool
        do {
            importEnabled = try await database.withLease(lease) {
                try await repository.healthKitImportEnabled()
            }
        } catch {
            recordImportError(error, expectedIdentity: identity, generation: generation)
            fitnessHealthKitLogger.error(
                "HealthKit activation could not read its durable preference: \(error.localizedDescription, privacy: .private)"
            )
            return
        }
        guard importEnabled else { return }
        guard isCurrent(identity,generation:generation) else { return }
        await startObserverDelivery()
        guard isCurrent(identity,generation:generation) else { return }
        await importAllChanges()
    }

    func suspend() async {
        activationGeneration &+= 1
        identity = nil
        storeLease=nil
        lastImportError = nil
        lastWorkoutReplayError = nil
        workoutReplayNotBefore = nil
        runGate.reset()
        let oldQueryJobs = queryJobs.values.map(\.task)
        queryJobs.removeAll()
        let oldFlushJob = flushJob?.task
        flushJob = nil
        pendingFlushTurns = 0
        for job in oldQueryJobs { job.cancel() }
        oldFlushJob?.cancel()
        for query in observerQueries { healthStore.stop(query) }
        observerQueries.removeAll()
        if HKHealthStore.isHealthDataAvailable() {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void,Never>) in
                healthStore.disableAllBackgroundDelivery { _, _ in continuation.resume(returning: ()) }
            }
        }
        // These awaits join every replay/query capability owned by this
        // activation. URLSession is allowed to report cancellation before an
        // uncooperative custom URLProtocol's synchronous `startLoading` frame
        // returns; generation and database/API leases independently reject any
        // callback that arrives after this logical join.
        if let oldFlushJob { await oldFlushJob.value }
        for job in oldQueryJobs { await job.value }
    }

    func accessState() async -> FitnessHealthKitAccessState {
        guard HKHealthStore.isHealthDataAvailable() else { return .unavailable }
        if let lastImportError { return .failed(lastImportError) }
        if let lastWorkoutReplayError { return .failed(lastWorkoutReplayError) }
        guard let accessIdentity = identity,let lease=storeLease else {
            return .failed(FitnessDatabaseError.notActive.localizedDescription)
        }
        let accessGeneration = activationGeneration
        do {
            return try await database.withLease(lease) {
                let enabled = try await repository.healthKitImportEnabled()
                guard isCurrent(accessIdentity,generation: accessGeneration) else {
                    throw FitnessDatabaseError.staleLease
                }
                let status = try await authorizationRequestStatus()
                guard isCurrent(accessIdentity,generation: accessGeneration) else {
                    throw FitnessDatabaseError.staleLease
                }
                if !enabled { return status == .shouldRequest ? .notRequested : .needsPermission }
                if status == .shouldRequest { return .needsPermission }
                let outbox = try await repository.workoutOutboxStatus()
                guard isCurrent(accessIdentity,generation: accessGeneration) else {
                    throw FitnessDatabaseError.staleLease
                }
                if outbox.permanentCount > 0 {
                    return .failed(
                        "\(outbox.permanentCount) Health workout import\(outbox.permanentCount == 1 ? "" : "s") need attention."
                    )
                }
                let latest = try await repository.latestHealthKitImport()
                guard isCurrent(accessIdentity,generation: accessGeneration) else {
                    throw FitnessDatabaseError.staleLease
                }
                return .enabled(lastImport: latest)
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    func requestAuthorizationAndImport() async throws {
        guard let requestIdentity=identity,let lease=storeLease,
              HKHealthStore.isHealthDataAvailable() else {
            throw FitnessHealthRepositoryError.invalidHealthKitSample
        }
        let requestGeneration=activationGeneration
        do {
            try await database.withLease(lease) {
                let types = readTypes()
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void,Error>) in
                    healthStore.requestAuthorization(toShare: [],read: types) { success,error in
                        if let error { continuation.resume(throwing: error) }
                        else if success { continuation.resume(returning: ()) }
                        else { continuation.resume(throwing: FitnessHealthRepositoryError.invalidHealthKitSample) }
                    }
                }
                guard isCurrent(requestIdentity,generation:requestGeneration) else { return }
                try await repository.setHealthKitImportEnabled(true)
                guard isCurrent(requestIdentity,generation:requestGeneration) else { return }
                await startObserverDelivery()
                guard isCurrent(requestIdentity,generation:requestGeneration) else { return }
                await importAllChanges()
            }
        } catch {
            recordImportError(error,expectedIdentity:requestIdentity,generation:requestGeneration)
            throw error
        }
    }

    func importAllChanges() async {
        guard let importIdentity=identity else { return }
        let importGeneration=activationGeneration
        schedulePendingWorkoutImports(
            maximumTurns: FitnessHealthKitWorkoutOutboxPolicy.maximumReplayTurns
        )
        for kind in FitnessHealthKitSampleKind.allCases {
            guard isCurrent(importIdentity,generation:importGeneration) else { return }
            await runAnchoredQuery(kind)
        }
        guard isCurrent(importIdentity,generation:importGeneration) else { return }
        schedulePendingWorkoutImports(
            maximumTurns: FitnessHealthKitWorkoutOutboxPolicy.maximumReplayTurns
        )
    }

    /// Observer delivery is intentionally only a trigger. The cursor-owning
    /// anchored query remains the single source of incremental truth.
    private func observerFired(
        _ kind: FitnessHealthKitSampleKind,expectedIdentity:String,generation:UInt64
    ) async {
        guard isCurrent(expectedIdentity,generation:generation) else { return }
        await runAnchoredQuery(kind)
    }

    private func startObserverDelivery() async {
        guard observerQueries.isEmpty,let observerIdentity=identity else { return }
        let observerGeneration=activationGeneration
        for kind in FitnessHealthKitSampleKind.allCases {
            guard isCurrent(observerIdentity,generation:observerGeneration) else { return }
            guard let type = objectType(kind) as? HKSampleType else { continue }
            let query = HKObserverQuery(sampleType: type,predicate: nil) { [weak self] _,completion,error in
                if let error {
                    Task {
                        await self?.recordImportError(
                            error,expectedIdentity:observerIdentity,generation:observerGeneration
                        )
                    }
                    completion()
                    return
                }
                let completionBox = FitnessHealthKitObserverCompletion(completion)
                Task {
                    await self?.observerFired(
                        kind,expectedIdentity:observerIdentity,generation:observerGeneration
                    )
                    completionBox.finish()
                }
            }
            observerQueries.append(query)
            healthStore.execute(query)
            let backgroundError: Error? = await withCheckedContinuation { (continuation: CheckedContinuation<Error?,Never>) in
                healthStore.enableBackgroundDelivery(for: type,frequency: .immediate) { success,error in
                    continuation.resume(returning: success ? nil : (error ?? NSError(
                        domain: "HausKlar.HealthKit",code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Health background delivery could not be enabled."]
                    )))
                }
            }
            guard isCurrent(observerIdentity,generation:observerGeneration) else { return }
            if let backgroundError {
                recordImportError(
                    backgroundError,expectedIdentity:observerIdentity,generation:observerGeneration
                )
            }
        }
    }

    private func runAnchoredQuery(_ kind: FitnessHealthKitSampleKind) async {
        if let existing = queryJobs[kind] {
            if runGate.request(kind) {
                // The task completed and released the gate before its original
                // waiter removed the handle. Undo this probe and start a fresh
                // run so a narrowly timed observer signal is not lost.
                runGate.finish(kind)
                if queryJobs[kind]?.id == existing.id {
                    queryJobs.removeValue(forKey: kind)
                }
            } else {
                await existing.task.value
                return
            }
        }
        guard let queryIdentity=identity,
              let lease=storeLease,
              let type = objectType(kind) as? HKSampleType else { return }
        let queryGeneration=activationGeneration
        guard runGate.request(kind) else { return }
        let jobId = UUID()
        let task = Task { [weak self,database] in
            guard let self else { return }
            do {
                try await database.withLease(lease) {
                    await self.performAnchoredQuery(
                        kind,type:type,queryIdentity:queryIdentity,
                        queryGeneration:queryGeneration
                    )
                }
            } catch {
                await self.recordImportError(
                    error,expectedIdentity:queryIdentity,generation:queryGeneration
                )
            }
        }
        queryJobs[kind] = QueryJob(id: jobId,task: task)
        await task.value
        if queryJobs[kind]?.id == jobId { queryJobs.removeValue(forKey: kind) }
    }

    private func performAnchoredQuery(
        _ kind:FitnessHealthKitSampleKind,type:HKSampleType,
        queryIdentity:String,queryGeneration:UInt64
    ) async {
        defer {
            if isCurrent(queryIdentity,generation:queryGeneration) {
                runGate.finish(kind)
            }
        }
        repeat {
          runGate.beginIteration(kind)
          do {
            try Task.checkCancellation()
            let state = try await repository.anchorState(kind: kind)
            guard isCurrent(queryIdentity,generation:queryGeneration) else { break }
            let anchor: HKQueryAnchor?
            if let anchorData = state.anchorData {
                guard let decoded = try NSKeyedUnarchiver.unarchivedObject(
                    ofClass: HKQueryAnchor.self,from: anchorData
                ) else { throw FitnessHealthRepositoryError.invalidHealthKitSample }
                anchor = decoded
            } else {
                anchor = nil
            }
            let result = try await anchoredObjects(type: type,anchor: anchor)
            guard isCurrent(queryIdentity,generation:queryGeneration) else { break }
            guard let newAnchor = result.anchor else {
                throw FitnessHealthRepositoryError.invalidHealthKitSample
            }
            let archived = try NSKeyedArchiver.archivedData(
                withRootObject: newAnchor,requiringSecureCoding: true
            )
            guard !result.hasMore || archived != state.anchorData else {
                // A full page must advance the cursor. Failing closed prevents a
                // corrupt Health response from spinning forever on one anchor.
                throw FitnessHealthRepositoryError.invalidHealthKitSample
            }
            if kind == .workout {
                let requests = try workoutRequests(result.samples)
                let deletedWorkoutUuids = result.deleted.map { $0.uuid.uuidString }
                guard isCurrent(queryIdentity,generation:queryGeneration) else { break }
                try await repository.stageWorkoutHealthKitPage(
                    requests: requests,deletedWorkoutUuids: deletedWorkoutUuids,
                    archivedAnchor: archived
                )
                guard isCurrent(queryIdentity,generation:queryGeneration) else { break }
                lastImportError = nil
                // Observer completion depends only on HealthKit conversion and
                // the local transaction. Replay is an owned background task;
                // network latency can never hold Health's completion handler.
                schedulePendingWorkoutImports(
                    maximumTurns: FitnessHealthKitWorkoutOutboxPolicy.maximumReplayTurns
                )
            } else {
                let converted = result.samples.map { makeSample($0,kind: kind) }
                guard !converted.contains(where: { $0 == nil }) else {
                    throw FitnessHealthRepositoryError.invalidHealthKitSample
                }
                let samples = converted.compactMap { $0 }
                let deletions = result.deleted.map {
                    FitnessHealthKitDeletedObject(kind: kind,sourceObjectId: $0.uuid.uuidString)
                }
                guard isCurrent(queryIdentity,generation:queryGeneration) else { break }
                try await repository.applyHealthKitBatch(
                    kind: kind,samples: samples,deletions: deletions,archivedAnchor: archived
                )
                guard isCurrent(queryIdentity,generation:queryGeneration) else { break }
                lastImportError = nil
            }
            if result.hasMore { runGate.requestAnotherPage(kind) }
          } catch {
              // No anchor is written on query, conversion, archive or local commit failure.
              guard isCurrent(queryIdentity,generation:queryGeneration) else { break }
              lastImportError = "Health import did not finish: \(error.localizedDescription)"
          }
        } while isCurrent(queryIdentity,generation:queryGeneration) && runGate.shouldContinue(kind)
    }

    private func anchoredObjects(
        type: HKSampleType,anchor: HKQueryAnchor?
    ) async throws -> FitnessHealthKitAnchoredPage {
        let bridge = FitnessHealthKitQueryBridge(store: healthStore)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let query = HKAnchoredObjectQuery(
                    type: type,predicate: nil,anchor: anchor,
                    limit: FitnessHealthKitPagingPolicy.anchoredPageSize
                ) { _,samples,deleted,newAnchor,error in
                    if let error {
                        bridge.complete(.failure(error))
                    } else {
                        let samples = samples ?? []
                        let deleted = deleted ?? []
                        bridge.complete(.success((
                            samples,deleted,newAnchor,
                            FitnessHealthKitPagingPolicy.hasMore(
                                sampleCount:samples.count,deletionCount:deleted.count
                            )
                        )))
                    }
                }
                bridge.install(query: query,continuation: continuation)
            }
        } onCancel: {
            bridge.cancel()
        }
    }

    private func makeSample(_ sample: HKSample,kind: FitnessHealthKitSampleKind) -> FitnessHealthKitSample? {
        let domainKind: FitnessHealthKitSample.DomainKind
        var value: Double?
        var unit: String?
        var sleepStage: String?
        switch kind {
        case .workout:
            // Workouts use their dedicated activity-import contract, not the
            // body/sleep/recovery sample path below.
            return nil
        case .bodyMass:
            guard let quantity = sample as? HKQuantitySample else { return nil }
            value = quantity.quantity.doubleValue(for: .gramUnit(with: .kilo))
            unit = "kg"
            domainKind = .bodyMeasurement
        case .restingHeartRate:
            guard let quantity = sample as? HKQuantitySample else { return nil }
            value = quantity.quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
            unit = "bpm"
            domainKind = .recoveryObservation
        case .heartRateVariabilitySDNN:
            guard let quantity = sample as? HKQuantitySample else { return nil }
            value = quantity.quantity.doubleValue(for: .secondUnit(with: .milli))
            unit = "ms"
            domainKind = .recoveryObservation
        case .sleepAnalysis:
            guard let category = sample as? HKCategorySample else { return nil }
            sleepStage = Self.sleepStage(category.value)
            domainKind = .sleepSession
        }
        return FitnessHealthKitSample(
            kind: kind,domainKind: domainKind,startDate: sample.startDate,endDate: sample.endDate,
            value: value,unitKey: unit,sleepStage: sleepStage,provenance: provenance(sample)
        )
    }

    private func provenance(_ sample: HKSample) -> FitnessHealthKitProvenance {
        let revision = sample.sourceRevision
        let bundle = revision.source.bundleIdentifier
        let device = sample.device
        let allowedDevice = [
            "name": device?.name,"manufacturer": device?.manufacturer,"model": device?.model,
            "hardware_version": device?.hardwareVersion,"firmware_version": device?.firmwareVersion,
            "software_version": device?.softwareVersion,"local_identifier": device?.localIdentifier,
            "udi_device_identifier": device?.udiDeviceIdentifier,
        ].compactMapValues { $0 }.mapValues { String($0.prefix(200)) }
        var metadata: [String: JSONValue] = [:]
        if let external = sample.metadata?[HKMetadataKeyExternalUUID] as? String {
            metadata["external_uuid"] = .string(String(external.prefix(300)))
        }
        if let userEntered = sample.metadata?[HKMetadataKeyWasUserEntered] as? Bool {
            metadata["was_user_entered"] = .bool(userEntered)
        }
        return FitnessHealthKitProvenance(
            sourceBundleIdentifier: String(bundle.prefix(300)),sourceObjectId: sample.uuid.uuidString,
            sourceName: String(revision.source.name.prefix(200)),
            productType: revision.productType.map { String($0.prefix(200)) },
            originProviderKey: String(Self.providerKey(bundle).prefix(80)),
            externalObjectId: (sample.metadata?[HKMetadataKeyExternalUUID] as? String).map { String($0.prefix(300)) },
            sourceDeviceIdentifier: (device?.localIdentifier ?? device?.udiDeviceIdentifier ?? device?.model)
                .map { String($0.prefix(300)) },
            device: allowedDevice,metadata: metadata
        )
    }

    private func readTypes() -> Set<HKObjectType> {
        Set(FitnessHealthKitSampleKind.allCases.compactMap(objectType))
    }

    private func objectType(_ kind: FitnessHealthKitSampleKind) -> HKObjectType? {
        switch kind {
        case .bodyMass: HKObjectType.quantityType(forIdentifier: .bodyMass)
        case .sleepAnalysis: HKObjectType.categoryType(forIdentifier: .sleepAnalysis)
        case .restingHeartRate: HKObjectType.quantityType(forIdentifier: .restingHeartRate)
        case .heartRateVariabilitySDNN: HKObjectType.quantityType(forIdentifier: .heartRateVariabilitySDNN)
        case .workout: HKObjectType.workoutType()
        }
    }

    private func workoutRequests(_ samples: [HKSample]) throws -> [FitnessHealthKitWorkoutImport] {
        var requests:[FitnessHealthKitWorkoutImport]=[]
        for sample in samples {
            guard let workout=sample as? HKWorkout,
                  let request=workoutRequest(workout) else {
                throw FitnessHealthRepositoryError.invalidHealthKitSample
            }
            requests.append(request)
        }
        return requests
    }

    /// Replays a bounded number of 25-item turns. Calls coalesce so observer
    /// delivery, manual import and activation cannot send the same row
    /// concurrently. Activation/import use the full default; ordinary Fitness
    /// sync should use `schedulePendingWorkoutImports(maximumTurns: 1)` so its
    /// interactive request never waits behind HealthKit network work.
    func flushPendingWorkoutImports(
        maximumTurns: Int = FitnessHealthKitWorkoutOutboxPolicy.maximumReplayTurns
    ) async {
        let turns = FitnessHealthKitWorkoutOutboxPolicy.clampedReplayTurns(maximumTurns)
        if flushJob != nil {
            // A page can commit after the running job observed an empty queue.
            // Record this request so that narrow completion window cannot strand
            // the newly durable page until an unrelated future sync.
            pendingFlushTurns = max(pendingFlushTurns,turns)
        } else {
            if let workoutReplayNotBefore,workoutReplayNotBefore > Date() { return }
            _ = startWorkoutOutboxFlush(maximumTurns: turns)
        }
        // A coalesced request may install one follow-up job as its predecessor
        // finishes. Explicit drains join that owned chain; observer/sync callers
        // use the non-awaiting schedule method below.
        while let job = flushJob { await job.task.value }
    }

    /// Starts one owned replay task and returns after the actor has durably
    /// associated it with this activation. Suspend/account replacement cancels
    /// and joins the same task, even though the sync caller does not await it.
    func schedulePendingWorkoutImports(maximumTurns: Int = 1) {
        let turns = FitnessHealthKitWorkoutOutboxPolicy.clampedReplayTurns(maximumTurns)
        if flushJob != nil {
            pendingFlushTurns = max(pendingFlushTurns,turns)
            return
        }
        if let workoutReplayNotBefore,workoutReplayNotBefore > Date() { return }
        _ = startWorkoutOutboxFlush(maximumTurns: turns)
    }

    private func startWorkoutOutboxFlush(maximumTurns: Int) -> FlushJob? {
        guard let flushIdentity = identity,let lease = storeLease else { return nil }
        let flushGeneration = activationGeneration
        let jobId = UUID()
        let turns = FitnessHealthKitWorkoutOutboxPolicy.clampedReplayTurns(maximumTurns)
        let task = Task { [weak self,database] in
            guard let self else { return }
            do {
                try await database.withLease(lease) {
                    await self.performWorkoutOutboxFlush(
                        expectedIdentity: flushIdentity,
                        expectedGeneration: flushGeneration,
                        maximumTurns: turns
                    )
                }
            } catch {
                await self.recordWorkoutReplayError(
                    error,expectedIdentity: flushIdentity,generation: flushGeneration
                )
            }
            await self.finishWorkoutOutboxFlush(jobId: jobId)
        }
        let job = FlushJob(id: jobId,task: task)
        flushJob = job
        return job
    }

    private func finishWorkoutOutboxFlush(jobId: UUID) {
        guard flushJob?.id == jobId else { return }
        flushJob = nil
        let followUpTurns = pendingFlushTurns
        pendingFlushTurns = 0
        guard followUpTurns > 0 else { return }
        if let workoutReplayNotBefore,workoutReplayNotBefore > Date() { return }
        _ = startWorkoutOutboxFlush(maximumTurns: followUpTurns)
    }

    private func performWorkoutOutboxFlush(
        expectedIdentity: String,expectedGeneration: UInt64,maximumTurns: Int
    ) async {
        for _ in 0..<maximumTurns {
            guard isCurrent(expectedIdentity,generation: expectedGeneration) else { return }
            do { try Task.checkCancellation() } catch { return }
            let items: [FitnessHealthKitWorkoutOutboxItem]
            do {
                items = try await repository.pendingWorkoutImports()
            } catch {
                recordWorkoutReplayError(
                    error,expectedIdentity: expectedIdentity,generation: expectedGeneration
                )
                return
            }
            guard isCurrent(expectedIdentity,generation: expectedGeneration),!items.isEmpty else {
                return
            }
            for item in items {
                guard isCurrent(expectedIdentity,generation: expectedGeneration) else { return }
                do {
                    try Task.checkCancellation()
                    switch item.kind {
                    case .resolveDelete:
                        let sources: [FitnessHealthKitWorkoutSource] = try await apiClient.get(
                            "/fitness/imports/healthkit-workout/\(item.workoutUuid)/sources",
                            cachePolicy: .networkOnly
                        )
                        guard isCurrent(expectedIdentity,generation: expectedGeneration) else { return }
                        try await repository.resolveWorkoutDeletion(
                            itemId: item.id,workoutUuid: item.workoutUuid,sources: sources
                        )
                    case .import:
                        guard let request = item.request else {
                            throw FitnessHealthRepositoryError.corruptHealthKitWorkoutOutbox
                        }
                        // The API's exact (workout UUID, source bundle) key is
                        // its idempotency identity. The local mutation ID is a
                        // deterministic digest of the same pair, so a crash or
                        // acknowledgement failure replays the same source.
                        let response: FitnessHealthKitWorkoutImportResponse = try await apiClient.post(
                            "/fitness/imports/healthkit-workout",body: request
                        )
                        guard isCurrent(expectedIdentity,generation: expectedGeneration) else { return }
                        try await repository.acknowledgeWorkoutImport(
                            itemId: item.id,request: request,response: response
                        )
                    }
                    guard isCurrent(expectedIdentity,generation: expectedGeneration) else { return }
                    workoutReplayNotBefore = nil
                    lastWorkoutReplayError = nil
                } catch {
                    if Self.isCancellation(error) || !isCurrent(
                        expectedIdentity,generation: expectedGeneration
                    ) { return }
                    let permanent = Self.isPermanentWorkoutRejection(error)
                    do {
                        try await repository.recordWorkoutImportFailure(
                            item: item,message: error.localizedDescription,permanent: permanent
                        )
                    } catch {
                        recordWorkoutReplayError(
                            error,expectedIdentity: expectedIdentity,generation: expectedGeneration
                        )
                        return
                    }
                    guard isCurrent(expectedIdentity,generation: expectedGeneration) else { return }
                    recordWorkoutReplayError(
                        error,expectedIdentity: expectedIdentity,generation: expectedGeneration
                    )
                    if !permanent {
                        // A failed first row otherwise gets retried after every
                        // subsequently staged 500-item Health page. Persisted
                        // attempt_count survives launch; this short in-process
                        // gate prevents a network/error storm while periodic sync
                        // remains the eventual replay trigger.
                        let exponent = min(item.attemptCount,6)
                        workoutReplayNotBefore = Date().addingTimeInterval(
                            min(300,5 * pow(2,Double(exponent)))
                        )
                        return
                    }
                }
            }
            await Task.yield()
            guard isCurrent(expectedIdentity,generation: expectedGeneration) else { return }
            if items.count < FitnessHealthKitWorkoutOutboxPolicy.replayBatchSize { return }
        }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError,urlError.code == .cancelled { return true }
        if let apiError = error as? APIError,
           case .networkError(let underlying) = apiError {
            return (underlying as? URLError)?.code == .cancelled
                || underlying is CancellationError
        }
        return false
    }

    static func isPermanentWorkoutRejection(_ error: Error) -> Bool {
        if let repositoryError = error as? FitnessHealthRepositoryError {
            switch repositoryError {
            case .invalidWorkoutAcknowledgement, .corruptHealthKitWorkoutOutbox:
                return true
            default:
                return false
            }
        }
        guard let apiError = error as? APIError else { return false }
        switch apiError {
        case .invalidURL, .forbidden, .notFound, .conflict, .decodingError:
            return true
        case .serverError(let statusCode,_):
            return (400...499).contains(statusCode) && ![408,425,429].contains(statusCode)
        case .unauthorized,.networkError,.offlineQueued,
             .offlineQueueFull,.tokenRefreshFailed:
            return false
        }
    }

    private func workoutRequest(_ workout:HKWorkout) -> FitnessHealthKitWorkoutImport? {
        let elapsed=workout.endDate.timeIntervalSince(workout.startDate)
        guard elapsed > 0,workout.duration > 0 else { return nil }
        let source=provenance(workout)
        let classification=Self.workoutClassification(workout.workoutActivityType)
        let distance=workout.totalDistance?.doubleValue(for:.meter())
        let energy=workout.totalEnergyBurned?.doubleValue(for:.kilocalorie())
        let timezone:String
        if let identifier=workout.metadata?[HKMetadataKeyTimeZone] as? String,
           TimeZone(identifier:identifier) != nil {
            timezone=identifier
        } else if let value=workout.metadata?[HKMetadataKeyTimeZone] as? TimeZone {
            timezone=value.identifier
        } else {
            timezone=TimeZone.current.identifier
        }
        return FitnessHealthKitWorkoutImport(
            sourceBundleIdentifier:source.sourceBundleIdentifier,
            workoutUuid:source.sourceObjectId,originProviderKey:source.originProviderKey,
            externalUuid:source.externalObjectId,sourceName:source.sourceName,
            sourceDeviceIdentifier:source.sourceDeviceIdentifier,productType:source.productType,
            sportKey:classification.sport,subSportKey:classification.subSport,
            title:classification.title,startedAtUtc:FitnessDatabase.dateString(workout.startDate),
            endedAtUtc:FitnessDatabase.dateString(workout.endDate),
            durationS:min(workout.duration,elapsed),
            distanceM:distance.map { max(0,$0) },energyKcal:energy.map { max(0,$0) },
            localTimezone:timezone,deleted:false
        )
    }

    private static func workoutClassification(
        _ type:HKWorkoutActivityType
    ) -> (sport:String,subSport:String?,title:String) {
        switch type {
        case .running:return("running",nil,"Run")
        case .walking:return("walking",nil,"Walk")
        case .hiking:return("hiking",nil,"Hike")
        case .cycling:return("cycling",nil,"Ride")
        case .swimming:return("swimming_pool",nil,"Swim")
        case .traditionalStrengthTraining:return("strength","traditional","Strength workout")
        case .functionalStrengthTraining:return("strength","functional","Functional strength")
        case .crossTraining:return("strength","cross_training","Cross training")
        case .coreTraining:return("strength","core","Core training")
        case .highIntensityIntervalTraining:return("other","hiit","HIIT")
        case .yoga:return("other","yoga","Yoga")
        case .pilates:return("other","pilates","Pilates")
        case .rowing:return("rowing_indoor",nil,"Row")
        case .elliptical:return("other","elliptical","Elliptical")
        case .stairClimbing:return("other","stairs","Stair climbing")
        case .soccer:return("other","soccer","Football")
        case .tennis:return("other","tennis","Tennis")
        case .dance:return("other","dance","Dance")
        case .mixedCardio:return("other","mixed_cardio","Cardio")
        default:return("other","healthkit_\(type.rawValue)","Workout")
        }
    }

    private func authorizationRequestStatus() async throws -> HKAuthorizationRequestStatus {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HKAuthorizationRequestStatus,Error>) in
            healthStore.getRequestStatusForAuthorization(toShare: [],read: readTypes()) { status,error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: status) }
            }
        }
    }

    private func recordImportError(
        _ error:Error,expectedIdentity:String,generation:UInt64
    ) {
        guard isCurrent(expectedIdentity,generation:generation) else { return }
        lastImportError = "Health import did not finish: \(error.localizedDescription)"
    }

    private func recordWorkoutReplayError(
        _ error: Error,expectedIdentity: String,generation: UInt64
    ) {
        guard isCurrent(expectedIdentity,generation: generation) else { return }
        lastWorkoutReplayError = "A saved Health workout did not sync: \(error.localizedDescription)"
    }

    private func isCurrent(_ expectedIdentity:String,generation:UInt64) -> Bool {
        guard identity == expectedIdentity,activationGeneration == generation,
              let storeLease else { return false }
        do {
            try database.validate(storeLease)
            return true
        } catch {
            // Stale/revoked leases are an expected predicate result during
            // account replacement, not a recoverable operation at this layer.
            return false
        }
    }

    private static func providerKey(_ bundle: String) -> String {
        let lower = bundle.lowercased()
        if lower.contains("withings") { return "withings" }
        if lower.contains("garmin") { return "garmin" }
        if lower.contains("apple") || lower == "com.apple.health" { return "apple" }
        return lower.split(separator: ".").last.map(String.init) ?? "other"
    }

    private static func sleepStage(_ value: Int) -> String {
        switch value {
        case HKCategoryValueSleepAnalysis.inBed.rawValue: "in_bed"
        case HKCategoryValueSleepAnalysis.awake.rawValue: "awake"
        case HKCategoryValueSleepAnalysis.asleepCore.rawValue: "core"
        case HKCategoryValueSleepAnalysis.asleepDeep.rawValue: "deep"
        case HKCategoryValueSleepAnalysis.asleepREM.rawValue: "rem"
        default: "asleep"
        }
    }
}
