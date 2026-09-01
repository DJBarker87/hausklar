import Foundation
import SwiftData

// MARK: - DTOs

/// Full nap data transfer object as returned by the API.
struct NapDTO: Codable, Identifiable {
    let id: String
    let childId: String
    let startedAt: String
    let endedAt: String?
    let location: String?
    let notes: String?
    let sleepType: String?
    let durationMinutes: Double?
    let createdAt: String
    let updatedAt: String
    let createdBy: String?

    /// Convenience: returns "nap" when the field is nil (backward compat).
    var resolvedSleepType: String { sleepType ?? "nap" }
}

/// Request body for starting a new nap or bedtime.
private struct StartNapBody: Encodable {
    let id: String
    let childId: String
    let startedAt: String
    let location: String?
    let notes: String?
    let sleepType: String
}

private struct EndNapBody: Encodable {
    let endedAt: String
}

/// Body for the update-nap PATCH request.
private struct UpdateNapBody: Encodable {
    let startedAt: String
    let endedAt: String?
    let clearEndedAt: Bool
    let location: String?
    let clearLocation: Bool
    let notes: String?
    let clearNotes: Bool
}

private enum DurableNapError: LocalizedError {
    case missingLocalRecord
    case duplicateLocalRecord
    case invalidServerRecord

    var errorDescription: String? {
        switch self {
        case .missingLocalRecord:
            "The sleep record is not available on this device."
        case .duplicateLocalRecord:
            "More than one local sleep record has the same identifier."
        case .invalidServerRecord:
            "The server returned an invalid sleep record."
        }
    }
}

/// Tab selector for naps vs bedtime.
enum SleepTab: String, CaseIterable {
    case naps
    case bedtime

    var sleepType: String { rawValue == "naps" ? "nap" : "bedtime" }
}

// MARK: - ViewModel

/// ViewModel for the Naps screen. Manages active nap tracking, starting naps, and ending naps.
@MainActor
final class NapsViewModel: ObservableObject {

    // MARK: - Published State

    @Published var selectedTab: SleepTab = .naps
    @Published var activeNaps: [NapDTO] = []
    @Published var recentNaps: [NapDTO] = []
    @Published var activeBedtimes: [NapDTO] = []
    @Published var recentBedtimes: [NapDTO] = []
    @Published var lastNightSleep: NapDTO?
    @Published var children: [ChildDTO] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var showingStartNap = false
    @Published var editingNap: NapDTO?
    @Published var recentlyDeletedNap: NapDTO?
    @Published var reminderMinutes = 0

    // MARK: - Start Nap Form Fields

    @Published var selectedChildId: String?
    @Published var selectedLocation: String = "cot"
    @Published var napNotes = ""

    // MARK: - Constants

    let locations = ["cot", "buggy", "car", "sofa", "other"]

    // MARK: - Private

    private let apiClient: APIClient
    private let syncManager: SyncManager
    private var modelContext: ModelContext?

    private static let dateOnlyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        return formatter
    }()

    init(
        apiClient: APIClient = .shared,
        syncManager: SyncManager? = nil
    ) {
        self.apiClient = apiClient
        self.syncManager = syncManager ?? .shared
    }

    // MARK: - Actions

    func bindModelContext(_ context: ModelContext) {
        modelContext = context
        loadLocalData()
    }

    /// Loads children, active naps/bedtimes, and today's history from the API in parallel.
    func loadNaps() async {
        loadLocalData()
        isLoading = true
        errorMessage = nil

        let todayString = Self.dateOnlyFormatter.string(from: Date())

        async let activeResult = fetchAllActiveNaps()
        async let recentResult = fetchTodaysNaps(date: todayString)
        async let childrenResult = fetchChildren()

        let (fetchedActive, fetchedRecent, fetchedChildren) = await (activeResult, recentResult, childrenResult)

        if let allActive = fetchedActive {
            activeNaps = allActive.filter { $0.resolvedSleepType == "nap" }
            activeBedtimes = allActive.filter { $0.resolvedSleepType == "bedtime" }
            do {
                try persistNaps(allActive)
            } catch {
                modelContext?.rollback()
                errorMessage = "Sleep records loaded, but couldn't be saved on this device. Try again."
                    .localized
            }
        }
        if let allRecent = fetchedRecent {
            recentNaps = allRecent.filter { $0.endedAt != nil && $0.resolvedSleepType == "nap" }
            recentBedtimes = allRecent.filter { $0.endedAt != nil && $0.resolvedSleepType == "bedtime" }
            lastNightSleep = allRecent
                .filter { $0.endedAt != nil && $0.resolvedSleepType == "bedtime" }
                .sorted(by: { $0.startedAt > $1.startedAt })
                .first
            do {
                try persistNaps(allRecent)
            } catch {
                modelContext?.rollback()
                errorMessage = "Sleep records loaded, but couldn't be saved on this device. Try again."
                    .localized
            }
        }

        if let fetchedChildren, !fetchedChildren.isEmpty {
            children = fetchedChildren
            do {
                try persistChildren(fetchedChildren)
            } catch {
                modelContext?.rollback()
                errorMessage = "Family details loaded, but couldn't be saved on this device. Try again."
                    .localized
            }
        }
        applyRememberedDefaults()
        if (fetchedActive == nil || fetchedRecent == nil)
            && activeNaps.isEmpty && recentNaps.isEmpty
            && activeBedtimes.isEmpty && recentBedtimes.isEmpty {
            errorMessage = "Sleep records couldn't be loaded. Try again."
        }
        await refreshNapReminders()

        isLoading = false
    }

    /// Starts a new nap or bedtime for the selected child.
    func startNap() async {
        guard let childId = selectedChildId, !childId.isEmpty else {
            errorMessage = "Please select a child.".localized
            return
        }

        isLoading = true
        errorMessage = nil

        let isBedtime = selectedTab == .bedtime
        await startSleep(
            childId: childId,
            location: isBedtime ? nil : selectedLocation,
            notes: napNotes.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            sleepType: selectedTab.sleepType,
            closeSheet: true
        )

        isLoading = false
    }

    /// Ends the nap with the given ID.
    func endNap(_ id: String) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        let endedAt = Date()
        let body = EndNapBody(endedAt: ISODateParser.stringNoFractional(from: endedAt))
        guard let modelContext,
              let identityLease = syncManager.currentIdentityLease,
              let original = allDisplayedNaps.first(where: { $0.id == id }) else {
            errorMessage = DurableNapError.missingLocalRecord.localizedDescription
            return
        }
        let optimistic = replacing(
            original,
            endedAt: body.endedAt,
            updatedAt: body.endedAt
        )
        let outcome = await syncManager.performDurableMutation(
            modelContext: modelContext,
            actionID: UUID().uuidString,
            operation: .update,
            tableName: "naps",
            recordId: id,
            payload: ["ended_at": body.endedAt],
            expectedIdentityLease: identityLease
        ) {
            try Self.upsertNap(optimistic, in: modelContext)
        } onStaged: { [weak self] in
            self?.loadLocalData()
            NapActivityManager.shared.end(napId: id)
            NotificationService.shared.cancelNapReminder(napId: id)
        } transport: { [apiClient] in
            let value: NapDTO = try await apiClient.patch("/naps/\(id)/end", body: body)
            return value
        } validateAcknowledgement: { value in
            value.id == id ? nil : "The server acknowledged a different sleep record."
        } applyAcknowledgedResult: { value in
            try Self.upsertNap(value, in: modelContext)
        }

        switch outcome {
        case .acknowledged:
            loadLocalData()
            await loadNaps()
        case .queued, .transportFailed(status: .pending, error: _):
            errorMessage = nil
        case .transportFailed(status: .retryable, error: _):
            errorMessage = "Sleep was saved on this device and will retry automatically.".localized
        case .transportFailed(status: .permanent, error: _):
            errorMessage = "Sleep was saved locally, but the server rejected the change. Review the offline queue.".localized
        case .acknowledgementPending:
            errorMessage = "Sleep was saved. Its server receipt will replay safely.".localized
        case .stagingFailed:
            errorMessage = "This change was not saved, so nothing was sent. Please try again.".localized
        case .transportFailed(status: nil, error: _),
             .transportFailed(status: .directAttempt, error: _),
             .transportFailed(status: .inFlight, error: _),
             .transportFailed(status: .syncing, error: _),
             .transportFailed(status: .synced, error: _),
             .transportFailed(status: .failed, error: _):
            errorMessage = "Sleep was saved locally. Its exact replay state will recover automatically.".localized
        }
    }

    /// Corrects the complete sleep record.
    func editNap(
        id: String,
        startedAt: Date,
        endedAt: Date?,
        location: String?,
        notes: String?
    ) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        let startedAtString = ISODateParser.stringNoFractional(from: startedAt)
        let endedAtString = endedAt.map(ISODateParser.stringNoFractional)
        let cleanNotes = notes?.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = UpdateNapBody(
            startedAt: startedAtString,
            endedAt: endedAtString,
            clearEndedAt: endedAt == nil,
            location: location,
            clearLocation: location == nil,
            notes: cleanNotes?.nilIfEmpty,
            clearNotes: cleanNotes?.nilIfEmpty == nil
        )

        guard let modelContext,
              let identityLease = syncManager.currentIdentityLease,
              let original = allDisplayedNaps.first(where: { $0.id == id }) else {
            errorMessage = DurableNapError.missingLocalRecord.localizedDescription
            return
        }
        let optimistic = replacing(
            original,
            startedAt: startedAtString,
            endedAt: endedAtString,
            location: location,
            notes: cleanNotes?.nilIfEmpty,
            updatedAt: ISODateParser.stringNoFractional(from: Date())
        )
        let payload: [String: Any] = [
            "started_at": startedAtString,
            "ended_at": endedAtString ?? NSNull(),
            "clear_ended_at": endedAt == nil,
            "location": location ?? NSNull(),
            "clear_location": location == nil,
            "notes": cleanNotes?.nilIfEmpty ?? NSNull(),
            "clear_notes": cleanNotes?.nilIfEmpty == nil,
        ]
        let outcome = await syncManager.performDurableMutation(
            modelContext: modelContext,
            actionID: UUID().uuidString,
            operation: .update,
            tableName: "naps",
            recordId: id,
            payload: payload,
            expectedIdentityLease: identityLease
        ) {
            try Self.upsertNap(optimistic, in: modelContext)
        } onStaged: { [weak self] in
            guard let self else { return }
            self.loadLocalData()
            await self.syncAmbientState(for: optimistic)
            self.editingNap = nil
        } transport: { [apiClient] in
            let value: NapDTO = try await apiClient.patch("/naps/\(id)", body: body)
            return value
        } validateAcknowledgement: { value in
            value.id == id ? nil : "The server acknowledged a different sleep record."
        } applyAcknowledgedResult: { value in
            try Self.upsertNap(value, in: modelContext)
        }

        switch outcome {
        case .acknowledged(let value):
            loadLocalData()
            await syncAmbientState(for: value)
            await loadNaps()
        case .queued, .transportFailed(status: .pending, error: _):
            errorMessage = nil
        case .transportFailed(status: .retryable, error: _):
            errorMessage = "Sleep was saved on this device and will retry automatically.".localized
        case .transportFailed(status: .permanent, error: _):
            errorMessage = "Sleep was saved locally, but the server rejected the change. Review the offline queue.".localized
        case .acknowledgementPending:
            errorMessage = "Sleep was saved. Its server receipt will replay safely.".localized
        case .stagingFailed:
            errorMessage = "This change was not saved, so nothing was sent. Please try again.".localized
        case .transportFailed(status: nil, error: _),
             .transportFailed(status: .directAttempt, error: _),
             .transportFailed(status: .inFlight, error: _),
             .transportFailed(status: .syncing, error: _),
             .transportFailed(status: .synced, error: _),
             .transportFailed(status: .failed, error: _):
            errorMessage = "Sleep was saved locally. Its exact replay state will recover automatically.".localized
        }
    }

    /// Quick-starts a nap for one child (no form, no sheet).
    func quickStartNap(for child: ChildDTO) async {
        isLoading = true
        errorMessage = nil

        await startSleep(
            childId: child.id,
            location: selectedLocation,
            notes: nil,
            sleepType: "nap",
            closeSheet: false
        )

        isLoading = false
    }

    var quickStartChildren: [ChildDTO] {
        children
            .filter { child in !activeNaps.contains { $0.childId == child.id } }
            .sorted { left, right in
                if left.id == selectedChildId { return true }
                if right.id == selectedChildId { return false }
                return left.dateOfBirth > right.dateOfBirth
            }
    }

    /// The youngest child by date of birth, or the first child if DOB parsing fails.
    var youngestChild: ChildDTO? {
        guard !children.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        return children.max(by: { a, b in
            let dateA = formatter.date(from: a.dateOfBirth) ?? .distantPast
            let dateB = formatter.date(from: b.dateOfBirth) ?? .distantPast
            return dateA < dateB  // max = most recent DOB = youngest
        })
    }

    /// Resets the start-nap form fields to their defaults.
    func resetForm() {
        napNotes = ""
        applyRememberedDefaults()
    }

    func deleteNap(_ nap: NapDTO) async {
        errorMessage = nil
        do {
            try await apiClient.delete("/naps/\(nap.id)")
            recentlyDeletedNap = nap
            editingNap = nil
            NapActivityManager.shared.end(napId: nap.id)
            NotificationService.shared.cancelNapReminder(napId: nap.id)
            do {
                try markLocalNapDeleted(id: nap.id, deleted: true)
            } catch {
                modelContext?.rollback()
                await loadNaps()
                errorMessage = "Sleep was removed online, but this device couldn't save the update. Refreshing now."
                    .localized
                return
            }
            await loadNaps()
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "Failed to remove sleep record. Please try again.".localized
        }
    }

    func undoDelete() async {
        guard let nap = recentlyDeletedNap else { return }
        do {
            let restored: NapDTO = try await apiClient.post("/naps/\(nap.id)/restore")
            do {
                try persistNaps([restored])
            } catch {
                modelContext?.rollback()
                await loadNaps()
                errorMessage = "Sleep was restored online, but this device couldn't save the update. Refreshing now."
                    .localized
                return
            }
            await syncAmbientState(for: restored)
            recentlyDeletedNap = nil
            await loadNaps()
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "Failed to restore sleep record. Please try again.".localized
        }
    }

    private func startSleep(
        childId: String,
        location: String?,
        notes: String?,
        sleepType: String,
        closeSheet: Bool
    ) async {
        let id = UUID().uuidString
        let startedAt = Date()
        let startedAtString = ISODateParser.stringNoFractional(from: startedAt)
        let body = StartNapBody(
            id: id,
            childId: childId,
            startedAt: startedAtString,
            location: location,
            notes: notes,
            sleepType: sleepType
        )
        guard let modelContext,
              let identityLease = syncManager.currentIdentityLease else {
            errorMessage = "Sleep could not be saved securely on this device. Please try again.".localized
            return
        }
        let optimistic = NapDTO(
            id: id,
            childId: childId,
            startedAt: startedAtString,
            endedAt: nil,
            location: location,
            notes: notes,
            sleepType: sleepType,
            durationMinutes: nil,
            createdAt: startedAtString,
            updatedAt: startedAtString,
            createdBy: nil
        )
        let outcome = await syncManager.performDurableMutation(
            modelContext: modelContext,
            actionID: id,
            operation: .create,
            tableName: "naps",
            recordId: id,
            payload: [
                "child_id": childId,
                "started_at": startedAtString,
                "location": location ?? NSNull(),
                "notes": notes ?? NSNull(),
                "sleep_type": sleepType,
            ],
            expectedIdentityLease: identityLease
        ) {
            try Self.insertNap(optimistic, in: modelContext)
        } onStaged: { [weak self] in
            guard let self else { return }
            self.loadLocalData()
            await self.syncAmbientState(for: optimistic)
            self.rememberDefaults(childId: childId, location: location)
            if closeSheet { self.showingStartNap = false }
            self.resetForm()
        } transport: { [apiClient] in
            let value: NapDTO = try await apiClient.post("/naps/start", body: body)
            return value
        } validateAcknowledgement: { value in
            value.id == id ? nil : "The server acknowledged a different sleep record."
        } applyAcknowledgedResult: { value in
            try Self.upsertNap(value, in: modelContext)
        }

        switch outcome {
        case .acknowledged(let value):
            loadLocalData()
            await syncAmbientState(for: value)
            await loadNaps()
        case .queued, .transportFailed(status: .pending, error: _):
            errorMessage = nil
        case .transportFailed(status: .retryable, error: _):
            errorMessage = "Sleep was saved on this device and will retry automatically.".localized
        case .transportFailed(status: .permanent, error: _):
            errorMessage = "Sleep was saved locally, but the server rejected it. Review the offline queue.".localized
        case .acknowledgementPending:
            errorMessage = "Sleep was saved. Its server receipt will replay safely.".localized
        case .stagingFailed:
            errorMessage = "This sleep record was not saved, so nothing was sent. Please try again.".localized
        case .transportFailed(status: nil, error: _),
             .transportFailed(status: .directAttempt, error: _),
             .transportFailed(status: .inFlight, error: _),
             .transportFailed(status: .syncing, error: _),
             .transportFailed(status: .synced, error: _),
             .transportFailed(status: .failed, error: _):
            errorMessage = "Sleep was saved locally. Its exact replay state will recover automatically.".localized
        }
    }

    private func replacing(
        _ original: NapDTO,
        endedAt: String,
        updatedAt: String
    ) -> NapDTO {
        let duration = ISODateParser.parse(endedAt).flatMap { end in
            ISODateParser.parse(original.startedAt).map {
                end.timeIntervalSince($0) / 60
            }
        }
        return NapDTO(
            id: original.id,
            childId: original.childId,
            startedAt: original.startedAt,
            endedAt: endedAt,
            location: original.location,
            notes: original.notes,
            sleepType: original.sleepType,
            durationMinutes: duration,
            createdAt: original.createdAt,
            updatedAt: updatedAt,
            createdBy: original.createdBy
        )
    }

    private func replacing(
        _ original: NapDTO,
        startedAt: String,
        endedAt: String?,
        location: String?,
        notes: String?,
        updatedAt: String
    ) -> NapDTO {
        let duration = endedAt.flatMap(ISODateParser.parse).flatMap { end in
            ISODateParser.parse(startedAt).map { end.timeIntervalSince($0) / 60 }
        }
        return NapDTO(
            id: original.id,
            childId: original.childId,
            startedAt: startedAt,
            endedAt: endedAt,
            location: location,
            notes: notes,
            sleepType: original.sleepType,
            durationMinutes: duration,
            createdAt: original.createdAt,
            updatedAt: updatedAt,
            createdBy: original.createdBy
        )
    }

    private static func insertNap(_ dto: NapDTO, in modelContext: ModelContext) throws {
        let requestedID = dto.id
        let matches = try modelContext.fetch(FetchDescriptor<Nap>(
            predicate: #Predicate { $0.id == requestedID }
        ))
        guard matches.isEmpty else { throw DurableNapError.duplicateLocalRecord }
        try upsertNap(dto, in: modelContext)
    }

    private static func upsertNap(_ dto: NapDTO, in modelContext: ModelContext) throws {
        guard !dto.id.isEmpty,
              !dto.childId.isEmpty,
              let startedAt = ISODateParser.parse(dto.startedAt),
              let createdAt = ISODateParser.parse(dto.createdAt),
              let updatedAt = ISODateParser.parse(dto.updatedAt),
              dto.endedAt == nil || dto.endedAt.flatMap(ISODateParser.parse) != nil else {
            throw DurableNapError.invalidServerRecord
        }
        let requestedID = dto.id
        let matches = try modelContext.fetch(FetchDescriptor<Nap>(
            predicate: #Predicate { $0.id == requestedID }
        ))
        guard matches.count <= 1 else { throw DurableNapError.duplicateLocalRecord }
        let item: Nap
        if let existing = matches.first {
            item = existing
        } else {
            item = Nap(id: dto.id)
            modelContext.insert(item)
        }
        item.childId = dto.childId
        item.startedAt = startedAt
        item.endedAt = dto.endedAt.flatMap(ISODateParser.parse)
        item.location = dto.location
        item.notes = dto.notes
        item.sleepType = dto.resolvedSleepType
        item.createdAt = createdAt
        item.updatedAt = updatedAt
        item.createdBy = dto.createdBy
        item.deletedAt = nil
    }

    private func loadLocalData() {
        guard let modelContext else { return }
        let activeRows: [Nap]
        let completedRows: [Nap]
        let localChildren: [Child]
        do {
            activeRows = try modelContext.fetch(FetchDescriptor<Nap>(
                predicate:#Predicate { $0.deletedAt == nil && $0.endedAt == nil },
                sortBy:[SortDescriptor(\.startedAt,order:.reverse)]
            ))
            var completedDescriptor=FetchDescriptor<Nap>(
                predicate:#Predicate { $0.deletedAt == nil && $0.endedAt != nil },
                sortBy:[SortDescriptor(\.startedAt,order:.reverse)]
            )
            completedDescriptor.fetchLimit=200
            completedRows = try modelContext.fetch(completedDescriptor)
            localChildren = try modelContext.fetch(FetchDescriptor<Child>(
                predicate:#Predicate { $0.deletedAt == nil }
            ))
        } catch {
            errorMessage = "Sleep records couldn't be read from this device. Try again."
                .localized
            return
        }
        let active = activeRows
            .map(napDTO)
        let startOfToday = Calendar.current.startOfDay(for: Date())
        let endOfToday = Calendar.current.date(byAdding: .day, value: 1, to: startOfToday) ?? Date()
        let recent = completedRows
            .filter {
                $0.startedAt < endOfToday
                    && ($0.endedAt ?? .distantPast) > startOfToday
            }
            .map(napDTO)
        activeNaps = active.filter { $0.resolvedSleepType == "nap" }
        activeBedtimes = active.filter { $0.resolvedSleepType == "bedtime" }
        recentNaps = recent.filter { $0.resolvedSleepType == "nap" }
        recentBedtimes = recent.filter { $0.resolvedSleepType == "bedtime" }
        lastNightSleep = recentBedtimes.first

        let childDTOs = localChildren
            .map {
                ChildDTO(
                    id: $0.id,
                    name: $0.name,
                    dateOfBirth: Self.dateOnlyFormatter.string(from: $0.dateOfBirth)
                )
            }
            .sorted { $0.dateOfBirth > $1.dateOfBirth }
        if !childDTOs.isEmpty { children = childDTOs }
    }

    private func napDTO(_ nap: Nap) -> NapDTO {
        let duration = nap.endedAt.map { $0.timeIntervalSince(nap.startedAt) / 60 }
        return NapDTO(
            id: nap.id,
            childId: nap.childId,
            startedAt: ISODateParser.stringNoFractional(from: nap.startedAt),
            endedAt: nap.endedAt.map(ISODateParser.stringNoFractional),
            location: nap.location,
            notes: nap.notes,
            sleepType: nap.sleepType,
            durationMinutes: duration,
            createdAt: ISODateParser.stringNoFractional(from: nap.createdAt),
            updatedAt: ISODateParser.stringNoFractional(from: nap.updatedAt),
            createdBy: nap.createdBy
        )
    }

    private func persistNaps(_ naps: [NapDTO]) throws {
        guard let modelContext,!naps.isEmpty else { return }
        let ids=naps.map(\.id)
        let existing = try modelContext.fetch(FetchDescriptor<Nap>(
            predicate:#Predicate { ids.contains($0.id) }
        ))
        var byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        let tableName="naps"
        let synced=OfflineStatus.synced
        let pendingIDs = Set(
            (try modelContext.fetch(FetchDescriptor<OfflineAction>(
                predicate:#Predicate { $0.tableName == tableName && $0.status != synced }
            )))
                .map(\.recordId)
        )
        for dto in naps {
            if pendingIDs.contains(dto.id), byID[dto.id] != nil { continue }
            let startedAt = ISODateParser.parse(dto.startedAt) ?? Date()
            let createdAt = ISODateParser.parse(dto.createdAt) ?? startedAt
            let updatedAt = ISODateParser.parse(dto.updatedAt) ?? createdAt
            let item = byID[dto.id] ?? Nap(id: dto.id)
            if byID[dto.id] == nil {
                modelContext.insert(item)
                byID[dto.id] = item
            }
            item.childId = dto.childId
            item.startedAt = startedAt
            item.endedAt = dto.endedAt.flatMap(ISODateParser.parse)
            item.location = dto.location
            item.notes = dto.notes
            item.sleepType = dto.resolvedSleepType
            item.createdAt = createdAt
            item.updatedAt = updatedAt
            item.createdBy = dto.createdBy
            item.deletedAt = nil
        }
        try modelContext.save()
        loadLocalData()
    }

    private func persistChildren(_ remoteChildren: [ChildDTO]) throws {
        guard let modelContext,!remoteChildren.isEmpty else { return }
        let ids=remoteChildren.map(\.id)
        let existing = try modelContext.fetch(FetchDescriptor<Child>(
            predicate:#Predicate { ids.contains($0.id) }
        ))
        var byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        for dto in remoteChildren {
            let item = byID[dto.id] ?? Child(id: dto.id)
            if byID[dto.id] == nil {
                modelContext.insert(item)
                byID[dto.id] = item
            }
            item.name = dto.name
            item.dateOfBirth = Self.dateOnlyFormatter.date(from: dto.dateOfBirth) ?? item.dateOfBirth
            item.deletedAt = nil
        }
        try modelContext.save()
    }

    private func markLocalNapDeleted(id: String, deleted: Bool) throws {
        let requestedId=id
        guard let modelContext else { throw DurableNapError.missingLocalRecord }
        guard let item = try modelContext.fetch(FetchDescriptor<Nap>(
                predicate:#Predicate { $0.id == requestedId }
              )).first else { throw DurableNapError.missingLocalRecord }
        item.deletedAt = deleted ? Date() : nil
        item.updatedAt = Date()
        try modelContext.save()
        loadLocalData()
    }

    // MARK: - Private Fetch Methods

    private func fetchAllActiveNaps() async -> [NapDTO]? {
        do {
            let naps: [NapDTO] = try await apiClient.get("/naps/active")
            return naps
        } catch {
            return nil
        }
    }

    private func fetchTodaysNaps(date: String) async -> [NapDTO]? {
        do {
            let naps: [NapDTO] = try await apiClient.get(
                "/naps/",
                queryItems: [URLQueryItem(name: "date", value: date)]
            )
            return naps.sorted { $0.startedAt > $1.startedAt }
        } catch {
            return nil
        }
    }

    // MARK: - Helpers

    /// Returns the child name for a given ID.
    func childName(for childId: String) -> String {
        children.first { $0.id == childId }?.name ?? "Child"
    }

    private func fetchChildren() async -> [ChildDTO]? {
        do {
            let result: [ChildDTO] = try await apiClient.get("/children/")
            return result
        } catch {
            return nil
        }
    }

    private func applyRememberedDefaults() {
        let defaults = UserDefaults.standard
        guard let identity = apiClient.cacheIdentity else {
            selectedChildId = selectedChildId ?? youngestChild?.id
            reminderMinutes = 0
            return
        }
        if selectedChildId == nil {
            let remembered = defaults.string(
                forKey: OwnerScopedPreferences.napLastChild(identity: identity)
            )
            selectedChildId = children.first(where: { $0.id == remembered })?.id ?? youngestChild?.id
        }
        if let rememberedLocation = defaults.string(
            forKey: OwnerScopedPreferences.napLastLocation(identity: identity)
        ), locations.contains(rememberedLocation) {
            selectedLocation = rememberedLocation
        }
        reminderMinutes = defaults.integer(
            forKey: OwnerScopedPreferences.napReminderMinutes(identity: identity)
        )
    }

    private func rememberDefaults(childId: String, location: String?) {
        selectedChildId = childId
        guard let identity = apiClient.cacheIdentity else { return }
        let defaults = UserDefaults.standard
        defaults.set(
            childId,
            forKey: OwnerScopedPreferences.napLastChild(identity: identity)
        )
        if let location, locations.contains(location) {
            selectedLocation = location
            defaults.set(
                location,
                forKey: OwnerScopedPreferences.napLastLocation(identity: identity)
            )
        }
    }

    func setForgottenReminder(minutes: Int) async {
        reminderMinutes = max(0, minutes)
        if let identity = apiClient.cacheIdentity {
            UserDefaults.standard.set(
                reminderMinutes,
                forKey: OwnerScopedPreferences.napReminderMinutes(identity: identity)
            )
        }
        if reminderMinutes > 0 {
            _ = await NotificationService.shared.requestPermission()
        }
        await refreshNapReminders()
    }

    private var allDisplayedNaps: [NapDTO] {
        activeNaps + recentNaps + activeBedtimes + recentBedtimes
    }

    private func syncAmbientState(for nap: NapDTO) async {
        if nap.endedAt != nil {
            NapActivityManager.shared.end(napId: nap.id)
            NotificationService.shared.cancelNapReminder(napId: nap.id)
            return
        }
        guard let startedAt = ISODateParser.parse(nap.startedAt) else { return }
        NapActivityManager.shared.start(
            napId: nap.id,
            childId: nap.childId,
            childName: childName(for: nap.childId),
            startedAt: startedAt,
            isBedtime: nap.resolvedSleepType == "bedtime"
        )
        if nap.resolvedSleepType == "nap" {
            await NotificationService.shared.scheduleForgottenNap(
                napId: nap.id,
                childId: nap.childId,
                childName: childName(for: nap.childId),
                startedAt: startedAt,
                afterMinutes: reminderMinutes
            )
        }
    }

    private func refreshNapReminders() async {
        await NotificationService.shared.cancelAllNapReminders()
        guard reminderMinutes > 0 else { return }
        for nap in activeNaps {
            guard let startedAt = ISODateParser.parse(nap.startedAt) else { continue }
            await NotificationService.shared.scheduleForgottenNap(
                napId: nap.id,
                childId: nap.childId,
                childName: childName(for: nap.childId),
                startedAt: startedAt,
                afterMinutes: reminderMinutes
            )
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
