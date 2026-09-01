import Foundation
import os

private let fitnessRecoveryServiceLogger = Logger(
    subsystem: "org.example.hausklar",
    category: "FitnessRecoveryService"
)

private struct FitnessSourcePriorityRequest: Encodable {
    let id: String
    let clientId: String
    let clientTimestamp: String
    let metricKey: String
    let originProviderKey: String
    let transportKey: String
    let sourceNamespace: String
    let priority: Int
}

private struct FitnessWithingsConnectionStartRequest: Encodable {
    let returnSurface: String
}

enum FitnessRecoveryServiceError: LocalizedError {
    case identityChanged
    case stagedAssetNeedsConnection
    case invalidWithingsAuthorizationURL

    var errorDescription: String? {
        switch self {
        case .identityChanged: "The active Fitness profile changed. Try again in the current profile."
        case .stagedAssetNeedsConnection: "Reconnect before deleting this pending photo so its staged private file can be cancelled safely."
        case .invalidWithingsAuthorizationURL: "HausKlar received an invalid Withings sign-in address."
        }
    }
}

actor FitnessRecoveryService {
    static let shared = FitnessRecoveryService()

    private let repository: FitnessHealthRepository
    private let fitnessRepository: FitnessRepository
    private let apiClient: APIClient
    private let database: FitnessDatabase
    private var identity: FitnessServiceSession?
    private var flushTask: Task<Void,Never>?

    init(
        repository: FitnessHealthRepository = .shared,
        apiClient: APIClient = .shared,
        fitnessRepository: FitnessRepository = .shared,
        database: FitnessDatabase = .shared
    ) {
        self.repository = repository
        self.apiClient = apiClient
        self.fitnessRepository = fitnessRepository
        self.database = database
    }

    func activate(identity: String) async {
        if self.identity?.identity == identity, let session = self.identity {
            do {
                try database.validate(session.storeLease)
                return
            } catch {
                fitnessRecoveryServiceLogger.error(
                    "Active Fitness recovery lease became invalid: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        await suspend()
        do {
            let lease = try database.lease(for: identity)
            let repository = self.repository
            let database = self.database
            let recoveryTask = Task.detached(priority: .utility) {
                try Task.checkCancellation()
                _ = try await database.withLease(lease) {
                    try await repository.reconcileProgressPhotoFiles()
                }
                try Task.checkCancellation()
                FitnessProgressPhotoPreparation.reconcileArtifacts()
                try Task.checkCancellation()
            }
            try await withTaskCancellationHandler {
                try await recoveryTask.value
            } onCancel: {
                recoveryTask.cancel()
            }
            try Task.checkCancellation()
            try database.validate(lease)
            self.identity = FitnessServiceSession(identity: identity, storeLease: lease)
        } catch is CancellationError {
            // The parent activation owns and joins the detached filesystem work.
            // Cancellation is an expected lifecycle transition, not a failed recovery.
            return
        } catch {
            fitnessRecoveryServiceLogger.error(
                "Fitness recovery activation failed; protected photo state was left untouched: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func suspend() async {
        identity = nil
        let pendingFlush = flushTask
        flushTask = nil
        pendingFlush?.cancel()
        if let pendingFlush { await pendingFlush.value }
    }

    func sleepSessions(refresh: Bool = false) async throws -> FitnessLoadResult<[FitnessSleepSessionDTO]> {
        let expectedIdentity = try requireIdentity()
        do {
            let values: [FitnessSleepSessionDTO] = try await apiClient.get(
                "/fitness/sleep/sessions",bypassCache: refresh
            )
            guard identity == expectedIdentity else { throw FitnessRecoveryServiceError.identityChanged }
            try await database.withLease(expectedIdentity.storeLease) {
                try await repository.cacheSleepSessions(values)
            }
            return FitnessLoadResult(value: values,isFromCache: false)
        } catch {
            guard identity == expectedIdentity else { throw FitnessRecoveryServiceError.identityChanged }
            guard Self.isOffline(error) else { throw error }
            return FitnessLoadResult(
                value: try await database.withLease(expectedIdentity.storeLease) {
                    try await repository.localSleepSessions()
                },
                isFromCache: true
            )
        }
    }

    func recoveryObservations(refresh: Bool = false) async throws -> FitnessLoadResult<[FitnessRecoveryObservationDTO]> {
        let expectedIdentity = try requireIdentity()
        do {
            let values: [FitnessRecoveryObservationDTO] = try await apiClient.get(
                "/fitness/recovery/observations",bypassCache: refresh
            )
            guard identity == expectedIdentity else { throw FitnessRecoveryServiceError.identityChanged }
            try await database.withLease(expectedIdentity.storeLease) {
                try await repository.cacheRecoveryObservations(values)
            }
            return FitnessLoadResult(value: values,isFromCache: false)
        } catch {
            guard identity == expectedIdentity else { throw FitnessRecoveryServiceError.identityChanged }
            guard Self.isOffline(error) else { throw error }
            return FitnessLoadResult(
                value: try await database.withLease(expectedIdentity.storeLease) {
                    try await repository.localRecoveryObservations()
                },
                isFromCache: true
            )
        }
    }

    func recoverySummary(refresh: Bool = false) async throws -> FitnessRecoverySummaryDTO {
        let expectedIdentity = try requireIdentity()
        let toDate = Self.dayString(Date())
        let fromDate = Self.dayString(Calendar.current.date(byAdding: .day,value: -27,to: Date()) ?? Date())
        let value: FitnessRecoverySummaryDTO = try await apiClient.get(
            "/fitness/recovery/summary",
            queryItems: [
                URLQueryItem(name: "from_date", value: fromDate),
                URLQueryItem(name: "to_date", value: toDate),
            ],
            bypassCache: refresh
        )
        guard identity == expectedIdentity else { throw FitnessRecoveryServiceError.identityChanged }
        return value
    }

    func withingsStatus(refresh: Bool = false) async throws -> FitnessWithingsConnectionStatusDTO {
        let expectedIdentity = try requireIdentity()
        let value: FitnessWithingsConnectionStatusDTO = try await apiClient.get(
            "/fitness/integrations/withings/status",bypassCache: refresh
        )
        guard identity == expectedIdentity else { throw FitnessRecoveryServiceError.identityChanged }
        return value
    }

    func startWithingsAuthorization() async throws -> URL {
        let expectedIdentity = try requireIdentity()
        let value: FitnessWithingsConnectionStartResponseDTO = try await apiClient.post(
            "/fitness/integrations/withings/start",
            body: FitnessWithingsConnectionStartRequest(returnSurface: "app")
        )
        guard identity == expectedIdentity else { throw FitnessRecoveryServiceError.identityChanged }
        guard let url = ProviderAuthorizationURLPolicy.validatedURL(
            value.authorizationUrl,
            provider: .withings
        ) else {
            throw FitnessRecoveryServiceError.invalidWithingsAuthorizationURL
        }
        return url
    }

    func syncWithings() async throws -> FitnessWithingsSyncResponseDTO {
        let expectedIdentity = try requireIdentity()
        let value: FitnessWithingsSyncResponseDTO = try await apiClient.post(
            "/fitness/integrations/withings/sync"
        )
        guard identity == expectedIdentity else { throw FitnessRecoveryServiceError.identityChanged }
        return value
    }

    func disconnectWithings() async throws -> FitnessWithingsDisconnectResponseDTO {
        let expectedIdentity = try requireIdentity()
        let value: FitnessWithingsDisconnectResponseDTO = try await apiClient.deleteReturning(
            "/fitness/integrations/withings"
        )
        guard identity == expectedIdentity else { throw FitnessRecoveryServiceError.identityChanged }
        return value
    }

    func measurementHistory(
        metric: FitnessMeasurementMetric,refresh: Bool = false,
        startAt: Date? = nil,endAt: Date? = nil
    ) async throws -> FitnessLoadResult<FitnessMeasurementHistoryDTO> {
        let expectedIdentity = try requireIdentity()
        do {
            var queryItems=[URLQueryItem(name: "metric",value: metric.rawValue)]
            if let startAt { queryItems.append(URLQueryItem(name:"start_on",value:Self.dayString(startAt))) }
            if let endAt { queryItems.append(URLQueryItem(name:"end_on",value:Self.dayString(endAt))) }
            let value: FitnessMeasurementHistoryDTO = try await apiClient.get(
                "/fitness/measurements/history",
                queryItems: queryItems,
                bypassCache: refresh
            )
            guard identity == expectedIdentity else { throw FitnessRecoveryServiceError.identityChanged }
            return FitnessLoadResult(value: value,isFromCache: false)
        } catch {
            guard identity == expectedIdentity else { throw FitnessRecoveryServiceError.identityChanged }
            guard Self.isOffline(error) else { throw error }
            return try await database.withLease(expectedIdentity.storeLease) {
                let bodyMetricKeys:[String]
                let recoveryMetricKeys:[String]
                switch metric {
                case .weight:
                    bodyMetricKeys=["body.weight_kg"]
                    recoveryMetricKeys=[]
                case .bodyFat:
                    bodyMetricKeys=["body.body_fat_pct"]
                    recoveryMetricKeys=[]
                case .bloodPressure:
                    bodyMetricKeys=[]
                    recoveryMetricKeys=[
                        "vitals.blood_pressure_systolic_mmhg",
                        "vitals.blood_pressure_diastolic_mmhg",
                    ]
                }
                let body = try await fitnessRepository.bodyMeasurementsForHistory(
                    metricKeys:bodyMetricKeys,startAt:startAt,endAt:endAt
                )
                let observations = try await repository.recoveryObservationsForHistory(
                    metricKeys:recoveryMetricKeys,startAt:startAt,endAt:endAt
                )
                return FitnessLoadResult(
                    value: FitnessMeasurementHistoryBuilder.make(
                        metric: metric,bodyMeasurements: body,
                        recoveryObservations: observations,
                        startAt:startAt,endAt:endAt
                    ),
                    isFromCache: true
                )
            }
        }
    }

    func sourcePriorities(refresh: Bool = false) async throws -> FitnessLoadResult<[FitnessSourcePriorityDTO]> {
        let expectedIdentity=try requireIdentity()
        do {
            let values: [FitnessSourcePriorityDTO] = try await apiClient.get(
                "/fitness/source-priorities",bypassCache: refresh
            )
            guard identity == expectedIdentity else { throw FitnessRecoveryServiceError.identityChanged }
            try await database.withLease(expectedIdentity.storeLease) {
                for value in values { try await fitnessRepository.cacheSourcePriority(value) }
            }
            return FitnessLoadResult(value: values,isFromCache: false)
        } catch {
            guard identity == expectedIdentity else { throw FitnessRecoveryServiceError.identityChanged }
            guard Self.isOffline(error) else { throw error }
            return FitnessLoadResult(
                value: try await database.withLease(expectedIdentity.storeLease) {
                    try await fitnessRepository.sourcePriorities()
                },isFromCache: true
            )
        }
    }

    func setSourcePriority(
        existing: FitnessSourcePriorityDTO?,metricKey: String,
        source: FitnessExternalSourceDTO,priority: Int
    ) async throws -> FitnessSourcePriorityDTO {
        let expectedIdentity=try requireIdentity()
        let value: FitnessSourcePriorityDTO = try await apiClient.post(
            "/fitness/source-priorities",body: FitnessSourcePriorityRequest(
                id: existing?.id ?? UUID().uuidString,clientId: try apiClient.clientId,
                clientTimestamp: FitnessDatabase.dateString(Date()),metricKey: metricKey,
                originProviderKey: source.originProviderKey,transportKey: source.transportKey,
                sourceNamespace: source.sourceNamespace,priority: min(1_000,max(-1_000,priority))
            )
        )
        guard identity == expectedIdentity else { throw FitnessRecoveryServiceError.identityChanged }
        try await database.withLease(expectedIdentity.storeLease) {
            try await fitnessRepository.cacheSourcePriority(value)
        }
        return value
    }

    func selectCanonicalBodyMeasurement(
        _ measurementId: String
    ) async throws -> FitnessBodyMeasurementCanonicalOverrideResponse {
        let expectedIdentity=try requireIdentity()
        let value: FitnessBodyMeasurementCanonicalOverrideResponse = try await apiClient.post(
            "/fitness/body/measurements/\(measurementId)/canonical-override"
        )
        guard identity == expectedIdentity else { throw FitnessRecoveryServiceError.identityChanged }
        try await database.withLease(expectedIdentity.storeLease) {
            try await fitnessRepository.applyCanonicalOverride(value)
        }
        return value
    }

    func clearCanonicalBodyMeasurementOverride(
        _ measurementId: String
    ) async throws -> FitnessBodyMeasurementCanonicalOverrideResponse {
        let expectedIdentity=try requireIdentity()
        let value: FitnessBodyMeasurementCanonicalOverrideResponse = try await apiClient.deleteReturning(
            "/fitness/body/measurements/\(measurementId)/canonical-override"
        )
        guard identity == expectedIdentity else { throw FitnessRecoveryServiceError.identityChanged }
        try await database.withLease(expectedIdentity.storeLease) {
            try await fitnessRepository.applyCanonicalOverride(value)
        }
        return value
    }

    func progressPhotos(refresh: Bool = false) async throws -> FitnessLoadResult<[FitnessProgressPhotoDTO]> {
        let expectedIdentity = try requireIdentity()
        do {
            let values: [FitnessProgressPhotoDTO] = try await apiClient.get(
                "/fitness/progress-photos",bypassCache: refresh
            )
            guard identity == expectedIdentity else { throw FitnessRecoveryServiceError.identityChanged }
            return try await database.withLease(expectedIdentity.storeLease) {
                try await repository.cacheProgressPhotos(values)
                return FitnessLoadResult(
                    value: try await repository.progressPhotos(),isFromCache: false
                )
            }
        } catch {
            guard identity == expectedIdentity else { throw FitnessRecoveryServiceError.identityChanged }
            guard Self.isOffline(error) else { throw error }
            return FitnessLoadResult(
                value: try await database.withLease(expectedIdentity.storeLease) {
                    try await repository.progressPhotos()
                },isFromCache: true
            )
        }
    }

    func pendingProgressPhotos() async throws -> [FitnessPendingProgressPhoto] {
        let expectedIdentity = try requireIdentity()
        return try await database.withLease(expectedIdentity.storeLease) {
            try await repository.pendingProgressPhotos()
        }
    }

    @discardableResult
    func createProgressPhoto(
        artifact: FitnessProgressPhotoArtifact,capturedAt: Date,pose: FitnessProgressPhotoPose,
        bodyWeightKg: Double?,phaseId: String?,notes: String?
    ) async throws -> FitnessPendingProgressPhoto {
        let expectedIdentity = try requireIdentity()
        let pending = try await database.withLease(expectedIdentity.storeLease) {
            try await repository.createProgressPhoto(
                jpegFileURL: artifact.fileURL,capturedAt: capturedAt,pose: pose,
                bodyWeightKg: bodyWeightKg,phaseId: phaseId,notes: notes,
                clientId: try apiClient.clientId
            )
        }
        guard identity == expectedIdentity else { throw FitnessRecoveryServiceError.identityChanged }
        Task { [weak self] in await self?.flushProgressPhotos() }
        return pending
    }

    func retryProgressPhoto(_ assetId: String) async {
        await flushProgressPhotos()
    }

    func flushProgressPhotos() async {
        guard let expectedIdentity = identity else { return }
        if let flushTask { await flushTask.value; return }
        let task = Task<Void,Never> { [weak self,database] in
            guard let self else { return }
            do {
                try await database.withLease(expectedIdentity.storeLease) {
                    await self.performProgressPhotoFlush(expectedIdentity: expectedIdentity)
                }
            } catch {
                // Teardown invalidated the lease. The old owner's protected
                // original and retry metadata remain untouched in their store.
                fitnessRecoveryServiceLogger.error(
                    "Progress-photo flush stopped with its queue retained: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        flushTask = task
        await task.value
        flushTask = nil
    }

    private func performProgressPhotoFlush(expectedIdentity: FitnessServiceSession) async {
        do {
            try await repository.cleanupAcknowledgedProgressPhotoOriginals()
        } catch {
            fitnessRecoveryServiceLogger.error(
                "Acknowledged progress-photo cleanup was deferred: \(error.localizedDescription, privacy: .public)"
            )
        }
        let pending: [FitnessPendingProgressPhoto]
        do {
            pending = try await repository.pendingProgressPhotos()
        } catch {
            fitnessRecoveryServiceLogger.error(
                "Pending progress photos could not be read; no upload was attempted: \(error.localizedDescription, privacy: .public)"
            )
            return
        }
        for var item in pending {
            guard !Task.isCancelled,identity == expectedIdentity else { return }
            do {
                if !item.uploadAcknowledged {
                    let url = try await repository.localOriginalURL(assetId: item.id)
                    let result: FitnessPrivateAssetUploadResult = try await apiClient.uploadMultipart(
                        "/fitness/files/private",fileURL: url,
                        filename: item.originalFilename,mediaType: item.mediaType,
                        fields: ["asset_id": item.id,"asset_kind": "progress_photo"]
                    )
                    guard identity == expectedIdentity else { return }
                    guard result.assetId == item.id,result.uploadAcknowledged,result.state == "staged",
                          result.storageClass == "private_required" else {
                        throw FitnessHealthRepositoryError.invalidPhotoAcknowledgement
                    }
                    try await repository.markPhotoUploadAcknowledged(assetId: item.id,result: result)
                    item.uploadAcknowledged = true
                }
                guard item.uploadAcknowledged,!item.metadataAcknowledged,
                      identity == expectedIdentity else { continue }
                let photo = item.photo
                let request = FitnessProgressPhotoCreateRequest(
                    id: photo.id,clientId: try apiClient.clientId,
                    clientTimestamp: FitnessDatabase.dateString(Date()),
                    capturedAt: photo.capturedAt,pose: photo.pose,
                    bodyWeightKg: photo.bodyWeightKg,
                    measurementSnapshotJson: photo.measurementSnapshotJson,
                    phaseId: photo.phaseId,originalAssetId: photo.originalAssetId,
                    notes: photo.notes
                )
                let saved: FitnessProgressPhotoDTO = try await apiClient.post(
                    "/fitness/progress-photos",body: request
                )
                guard identity == expectedIdentity else { return }
                try await repository.acknowledgePhotoMetadata(assetId: item.id,photo: saved)
            } catch {
                guard identity == expectedIdentity else { return }
                let uploadError = error
                do {
                    try await repository.markPhotoFailure(
                        assetId:item.id,message:uploadError.localizedDescription
                    )
                } catch {
                    fitnessRecoveryServiceLogger.fault(
                        "Progress-photo flush stopped because failure state could not be saved; protected source retained. Asset: \(item.id, privacy: .private). Persistence error: \(error.localizedDescription, privacy: .public)"
                    )
                    return
                }
                if Self.isOffline(uploadError) { return }
            }
        }
    }

    func representationURL(
        photo: FitnessProgressPhotoDTO,representation: String
    ) async throws -> URL {
        let expectedIdentity = try requireIdentity()
        do {
            let local = try await database.withLease(expectedIdentity.storeLease,operation: {
                try await repository.localOriginalURL(assetId: photo.originalAssetId)
            })
            guard identity == expectedIdentity else { throw FitnessRecoveryServiceError.identityChanged }
            return local
        } catch FitnessHealthRepositoryError.missingPhoto {
            // A server-backed photo legitimately has no protected local original.
            // Database, lease, path, and corruption failures must still propagate.
        }
        if let cached = try await database.withLease(expectedIdentity.storeLease,operation: {
            try await repository.cachedRepresentation(
                photoId: photo.id,representation: representation
            )
        }) {
            guard identity == expectedIdentity else { throw FitnessRecoveryServiceError.identityChanged }
            return cached
        }
        let suffix = representation == "original" ? "original" : "thumbnail"
        if suffix == "original" {
            let temporary = try await apiClient.downloadToTemporaryFile(
                "/fitness/progress-photos/\(photo.id)/original",
                filename:"\(photo.id)-original.jpg",maximumBytes:25 * 1_024 * 1_024,
                allowedMediaTypes:["image/jpeg"]
            )
            defer {
                let temporaryDirectory = temporary.deletingLastPathComponent()
                for candidate in [temporary,temporaryDirectory]
                where FileManager.default.fileExists(atPath:candidate.path) {
                    do {
                        try FileManager.default.removeItem(at:candidate)
                    } catch {
                        fitnessRecoveryServiceLogger.error(
                            "Temporary progress-photo cleanup was deferred: \(error.localizedDescription, privacy: .public)"
                        )
                    }
                }
            }
            guard identity == expectedIdentity else {
                throw FitnessRecoveryServiceError.identityChanged
            }
            return try await database.withLease(expectedIdentity.storeLease) {
                guard identity == expectedIdentity else {
                    throw FitnessRecoveryServiceError.identityChanged
                }
                return try await repository.adoptRepresentationFile(
                    temporary,photoId:photo.id,representation:"original"
                )
            }
        }
        let data = try await apiClient.downloadData(
            "/fitness/progress-photos/\(photo.id)/\(suffix)",
            policy: .image(maximumBytes: 5 * 1_024 * 1_024)
        )
        guard identity == expectedIdentity else { throw FitnessRecoveryServiceError.identityChanged }
        return try await database.withLease(expectedIdentity.storeLease) {
            try await repository.storeRepresentation(
                data,photoId: photo.id,representation: representation
            )
        }
    }

    func regenerateThumbnail(_ photo: FitnessProgressPhotoDTO) async throws {
        let expectedIdentity = try requireIdentity()
        let _: FitnessProgressPhotoDTO = try await apiClient.post(
            "/fitness/progress-photos/\(photo.id)/thumbnail/regenerate",body: EmptyBody()
        )
        guard identity == expectedIdentity else { throw FitnessRecoveryServiceError.identityChanged }
    }

    func deleteProgressPhoto(_ photo: FitnessProgressPhotoDTO) async throws {
        guard let expectedIdentity = identity else { throw FitnessRecoveryServiceError.identityChanged }
        let pending = try await database.withLease(expectedIdentity.storeLease) {
            try await repository.pendingProgressPhoto(photoId: photo.id)
        }
        if let pending,pending.uploadAcknowledged,!pending.metadataAcknowledged {
            do {
                try await apiClient.delete("/fitness/files/private/\(pending.id)")
            } catch {
                if Self.isOffline(error) { throw FitnessRecoveryServiceError.stagedAssetNeedsConnection }
                throw error
            }
        } else if photo.metadataAcknowledged == true || photo.originalState == "ready" {
            try await apiClient.delete("/fitness/progress-photos/\(photo.id)")
        }
        guard identity == expectedIdentity else { throw FitnessRecoveryServiceError.identityChanged }
        try await database.withLease(expectedIdentity.storeLease) {
            try await repository.removeLocalProgressPhoto(photo)
        }
    }

    private static func isOffline(_ error: Error) -> Bool {
        guard let api = error as? APIError else { return false }
        if case .networkError = api { return true }
        return false
    }

    private func requireIdentity() throws -> FitnessServiceSession {
        guard let identity else { throw FitnessRecoveryServiceError.identityChanged }
        return identity
    }

    private static func dayString(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = calendar.dateComponents([.year,.month,.day],from: date)
        return String(format: "%04d-%02d-%02d",parts.year ?? 0,parts.month ?? 0,parts.day ?? 0)
    }
}
