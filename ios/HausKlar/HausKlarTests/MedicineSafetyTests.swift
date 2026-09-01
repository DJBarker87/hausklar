import SwiftData
import SwiftUI
import XCTest
@testable import HausKlar

private enum MedicineRequestBodyCaptureError: LocalizedError {
    case missingBody
    case readFailed(String)
    case bodyTooLarge(maximumBytes: Int)

    var errorDescription: String? {
        switch self {
        case .missingBody:
            "The intercepted medicine request did not contain a body."
        case .readFailed(let detail):
            "The intercepted medicine request body could not be read: \(detail)"
        case .bodyTooLarge(let maximumBytes):
            "The intercepted medicine request body exceeded \(maximumBytes) bytes."
        }
    }
}

/// URLSession may bridge `httpBody` to `httpBodyStream` before a custom
/// URLProtocol sees the request. Read that transport representation once and
/// under a strict cap so payload assertions remain exact without unbounded test IO.
private func medicineRequestBodyData(
    _ request: URLRequest,
    maximumBytes: Int = 1_048_576
) throws -> Data {
    guard maximumBytes > 0 else {
        throw MedicineRequestBodyCaptureError.bodyTooLarge(maximumBytes: maximumBytes)
    }
    if let body = request.httpBody {
        guard body.count <= maximumBytes else {
            throw MedicineRequestBodyCaptureError.bodyTooLarge(maximumBytes: maximumBytes)
        }
        return body
    }
    guard let stream = request.httpBodyStream else {
        throw MedicineRequestBodyCaptureError.missingBody
    }

    stream.open()
    defer { stream.close() }
    var body = Data()
    var buffer = [UInt8](repeating: 0, count: 8_192)
    while true {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count < 0 {
            throw MedicineRequestBodyCaptureError.readFailed(
                stream.streamError?.localizedDescription ?? "Unknown stream error."
            )
        }
        if count == 0 { return body }
        guard count <= maximumBytes, body.count <= maximumBytes - count else {
            throw MedicineRequestBodyCaptureError.bodyTooLarge(maximumBytes: maximumBytes)
        }
        body.append(buffer, count: count)
    }
}

/// Tests for medicine safety logic in MedicineViewModel.
///
/// Medicine is safety-critical: min_hours_between_doses and max_doses_24h must
/// never be silently bypassed. These tests verify that the ViewModel correctly
/// computes safety colours, 24-hour dose counts, next-safe times, and ISO 8601
/// parsing / display helpers.
@MainActor
final class MedicineSafetyTests: XCTestCase {

    // MARK: - Helpers

    private var vm: MedicineViewModel!

    /// ISO 8601 formatter used to build test timestamps.
    private let iso = ISO8601DateFormatter()

    override func setUp() {
        super.setUp()
        vm = MedicineViewModel()
        iso.formatOptions = [.withInternetDateTime]
    }

    override func tearDown() {
        vm = nil
        super.tearDown()
    }

    /// Returns an ISO 8601 string for `Date()` offset by `hours` (negative = past).
    private func isoString(hoursAgo hours: Double) -> String {
        let date = Date().addingTimeInterval(-hours * 3600)
        return iso.string(from: date)
    }

    /// Convenience builder for a MedicineTypeDTO.
    private func makeType(
        id: String = "type-1",
        name: String = "Calpol",
        minHours: Double = 4.0,
        maxDoses: Int = 4,
        childId: String? = "child-1"
    ) -> MedicineTypeDTO {
        MedicineTypeDTO(
            id: id,
            name: name,
            minHoursBetweenDoses: minHours,
            maxDoses24h: maxDoses,
            notes: nil,
            color: nil,
            defaultDoseAmount: nil,
            childId: childId,
            createdAt: iso.string(from: Date())
        )
    }

    /// Convenience builder for a MedicineDoseDTO.
    private func makeDose(
        id: String = UUID().uuidString,
        typeId: String = "type-1",
        childId: String = "child-1",
        givenAt: String,
        givenBy: String? = "Alex"
    ) -> MedicineDoseDTO {
        MedicineDoseDTO(
            id: id,
            medicineTypeId: typeId,
            childId: childId,
            givenAt: givenAt,
            givenBy: givenBy,
            doseAmount: "5ml",
            medicineName: nil,
            notes: nil
        )
    }

    private func makeMedicineContainer() throws -> (ModelContainer, ModelContext) {
        let schema = Schema([
            MedicineType.self,
            MedicineDose.self,
            Child.self,
            OfflineAction.self,
        ])
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        return (container, ModelContext(container))
    }

    private func makeStubbedClient(
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> APIClient {
        APIClientStubURLProtocol.install(handler)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [APIClientStubURLProtocol.self]
        let client = APIClient(
            sessionConfiguration: configuration,
            resolveClientId: { "00000000-0000-4000-8000-000000000001" }
        )
        client.baseURL = "https://api.example.test/api"
        _ = client.installSession(
            identity: "medicine-tests:\(UUID().uuidString)",
            accessToken: "test-access",
            refreshToken: "test-refresh"
        )
        return client
    }

    private func makeSyncManager(
        client: APIClient,
        saveQueueContext: @escaping (ModelContext) throws -> Void = { try $0.save() }
    ) -> SyncManager {
        let suiteName = "MedicineSafetyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let manager = SyncManager(
            client: client,
            defaults: defaults,
            retryJitter: { 1 },
            saveQueueContext: saveQueueContext
        )
        manager.activate(identity: "medicine-tests:test-user")
        return manager
    }

    private func configuredDoseViewModel(
        client: APIClient,
        syncManager: SyncManager,
        context: ModelContext,
        givenAt: Date = Date(),
        medicineType: MedicineTypeDTO? = nil
    ) -> MedicineViewModel {
        let value = MedicineViewModel(apiClient: client, syncManager: syncManager)
        value.bindModelContext(context)
        let type = medicineType ?? makeType()
        value.medicineTypes = [type]
        value.selectedChildId = "child-1"
        value.selectedMedicineTypeId = type.id
        value.givenAt = givenAt
        value.doseAmount = "5ml"
        return value
    }

    private func exactDoseResponse(
        for request: URLRequest,
        statusCode: Int = 200,
        warnings: [[String: Any]] = []
    ) throws -> (HTTPURLResponse, Data) {
        let requestBody = try medicineRequestBodyData(request)
        var dose = try XCTUnwrap(
            JSONSerialization.jsonObject(with: requestBody) as? [String: Any]
        )
        dose["given_by"] = "Alex"
        dose["warnings"] = warnings
        let body = try JSONSerialization.data(
            withJSONObject: ["dose": dose, "warnings": warnings],
            options: [.sortedKeys]
        )
        let response = HTTPURLResponse(
            url: try XCTUnwrap(request.url),
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, body)
    }

    // MARK: - parseISO8601

    func testParseISO8601WithFractionalSeconds() {
        let input = "2025-06-15T14:30:00.123Z"
        let date = vm.parseISO8601(input)
        XCTAssertNotNil(date, "Should parse ISO 8601 with fractional seconds")
    }

    func testParseISO8601WithoutFractionalSeconds() {
        let input = "2025-06-15T14:30:00Z"
        let date = vm.parseISO8601(input)
        XCTAssertNotNil(date, "Should parse ISO 8601 without fractional seconds")
    }

    func testParseISO8601InvalidStringReturnsNil() {
        let invalid = "not-a-date"
        XCTAssertNil(vm.parseISO8601(invalid), "Invalid string should return nil")
    }

    // MARK: - formattedTime

    func testFormattedTimeProducesHHmm() {
        // Use a known timestamp; we only care about the format pattern.
        let input = "2025-06-15T09:05:00Z"
        let result = vm.formattedTime(input)

        // Result should contain a colon and be exactly 5 characters (HH:mm).
        let pattern = #"^\d{2}:\d{2}$"#
        XCTAssertTrue(
            result.range(of: pattern, options: .regularExpression) != nil,
            "formattedTime should produce HH:mm format, got '\(result)'"
        )
    }

    // MARK: - relativeTime

    func testRelativeTimeJustNow() {
        // A timestamp 10 seconds ago should be "just now".
        let recent = iso.string(from: Date().addingTimeInterval(-10))
        XCTAssertEqual(vm.relativeTime(recent), "just now")
    }

    func testRelativeTimeHoursAndMinutes() {
        // 2 hours 15 minutes ago.
        let past = isoString(hoursAgo: 2.25)
        let result = vm.relativeTime(past)
        XCTAssertTrue(
            result.contains("h") && result.contains("m ago"),
            "Expected 'Xh Ym ago' format, got '\(result)'"
        )
    }

    func testRelativeTimeMinutesOnly() {
        // 25 minutes ago (under 1 hour).
        let past = isoString(hoursAgo: 25.0 / 60.0)
        let result = vm.relativeTime(past)
        XCTAssertTrue(
            result.hasSuffix("m ago") && !result.contains("h"),
            "Expected 'Xm ago' format without hours, got '\(result)'"
        )
    }

    // MARK: - safetyColor

    func testSafetyColorGreenWhenNoDoses() {
        let type = makeType()
        vm.selectedChildId = "child-1"
        vm.recentDoses = []

        XCTAssertEqual(vm.safetyColor(for: type), .green, "No doses should be green (safe)")
    }

    func testSafetyColorRedWhenTooRecent() {
        // Dose given 1 hour ago, min interval 4 hours -> ratio 0.25 (< 0.75 => red).
        let type = makeType(minHours: 4.0)
        vm.selectedChildId = "child-1"
        vm.recentDoses = [makeDose(givenAt: isoString(hoursAgo: 1.0))]

        XCTAssertEqual(vm.safetyColor(for: type), .red, "Dose 1h ago with 4h interval should be red")
    }

    func testSafetyColorOrangeWhenApproaching() {
        // Dose given 3.5 hours ago, min interval 4 hours -> ratio 0.875 (0.75-1.0 => orange).
        let type = makeType(minHours: 4.0)
        vm.selectedChildId = "child-1"
        vm.recentDoses = [makeDose(givenAt: isoString(hoursAgo: 3.5))]

        XCTAssertEqual(vm.safetyColor(for: type), .orange, "Dose 3.5h ago with 4h interval should be orange")
    }

    func testSafetyColorGreenWhenPastInterval() {
        // Dose given 5 hours ago, min interval 4 hours -> ratio 1.25 (>= 1.0 => green).
        let type = makeType(minHours: 4.0)
        vm.selectedChildId = "child-1"
        vm.recentDoses = [makeDose(givenAt: isoString(hoursAgo: 5.0))]

        XCTAssertEqual(vm.safetyColor(for: type), .green, "Dose 5h ago with 4h interval should be green")
    }

    // MARK: - dosesIn24h

    func testDosesIn24hCountsCorrectly() {
        let type = makeType()
        vm.selectedChildId = "child-1"
        vm.recentDoses = [
            makeDose(id: "d1", givenAt: isoString(hoursAgo: 1)),
            makeDose(id: "d2", givenAt: isoString(hoursAgo: 6)),
            makeDose(id: "d3", givenAt: isoString(hoursAgo: 12)),
        ]

        XCTAssertEqual(vm.dosesIn24h(for: type), 3, "All 3 doses are within 24h")
    }

    func testDosesIn24hExcludesOlderThan24h() {
        let type = makeType()
        vm.selectedChildId = "child-1"
        vm.recentDoses = [
            makeDose(id: "d1", givenAt: isoString(hoursAgo: 2)),
            makeDose(id: "d2", givenAt: isoString(hoursAgo: 25)),  // older than 24h
            makeDose(id: "d3", givenAt: isoString(hoursAgo: 48)),  // older than 24h
        ]

        XCTAssertEqual(vm.dosesIn24h(for: type), 1, "Only 1 dose within 24h window")
    }

    func testDosesIn24hReturnsZeroForDifferentChild() {
        let type = makeType()  // childId = "child-1"
        vm.selectedChildId = "child-2"
        vm.recentDoses = [
            makeDose(id: "d1", childId: "child-1", givenAt: isoString(hoursAgo: 1)),
        ]

        XCTAssertEqual(vm.dosesIn24h(for: type), 0, "Doses for child-1 should not count for child-2")
    }

    // MARK: - nextSafeTime

    func testNextSafeTimeNilWhenNoDoses() {
        let type = makeType()
        vm.selectedChildId = "child-1"
        vm.recentDoses = []

        XCTAssertNil(vm.nextSafeTime(for: type), "No doses means already safe, should return nil")
    }

    func testNextSafeTimeNilWhenAlreadySafe() {
        // Dose 5 hours ago, min interval 4 hours — already past the safe window.
        let type = makeType(minHours: 4.0)
        vm.selectedChildId = "child-1"
        vm.recentDoses = [makeDose(givenAt: isoString(hoursAgo: 5.0))]

        XCTAssertNil(vm.nextSafeTime(for: type), "Past the interval, should return nil")
    }

    func testNextSafeTimeReturnsFormattedTimeWhenNotYetSafe() {
        // Dose 1 hour ago, min interval 4 hours — next safe is 3 hours from now.
        let type = makeType(minHours: 4.0)
        vm.selectedChildId = "child-1"
        vm.recentDoses = [makeDose(givenAt: isoString(hoursAgo: 1.0))]

        let result = vm.nextSafeTime(for: type)
        XCTAssertNotNil(result, "Should return a formatted time string")

        // Verify it matches HH:mm format.
        let pattern = #"^\d{2}:\d{2}$"#
        XCTAssertTrue(
            result!.range(of: pattern, options: .regularExpression) != nil,
            "nextSafeTime should return HH:mm format, got '\(result!)'"
        )
    }

    // MARK: - Edge cases

    func testSafetyColorReturnsGreenWhenNoChildSelected() {
        let type = makeType()
        vm.selectedChildId = nil  // no child selected
        vm.recentDoses = [makeDose(givenAt: isoString(hoursAgo: 0.5))]

        XCTAssertEqual(
            vm.safetyColor(for: type), .green,
            "With no child selected, safetyColor should default to green"
        )
    }

    func testRelativeTimeInvalidStringReturnsEmpty() {
        XCTAssertEqual(vm.relativeTime("garbage"), "", "Invalid ISO string should return empty string")
    }

    // MARK: - Complete offline history

    func testOfflineSafetyFindsBackdatedDoseOutsideBoundedPresentationCache() throws {
        let (_, context) = try makeMedicineContainer()
        let candidate = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2024-01-10T12:00:00Z")
        )
        let relevantDose = MedicineDose(
            id: "relevant-old-dose",
            medicineTypeId: "type-1",
            childId: "child-1",
            givenAt: candidate.addingTimeInterval(-3_600)
        )
        context.insert(relevantDose)

        // These deliberately fill the newest-200 presentation window while
        // remaining irrelevant to the candidate's historical safety window.
        for index in 0..<205 {
            context.insert(
                MedicineDose(
                    id: "newer-\(index)",
                    medicineTypeId: "type-1",
                    childId: "child-1",
                    givenAt: candidate.addingTimeInterval(
                        TimeInterval((index + 30) * 86_400)
                    )
                )
            )
        }
        try context.save()

        vm.bindModelContext(context)
        XCTAssertEqual(vm.cachedDoses.count, 200)
        XCTAssertFalse(vm.cachedDoses.contains { $0.id == relevantDose.id })

        let warnings = vm.offlineSafetyWarnings(
            medicineType: makeType(minHours: 4),
            childId: "child-1",
            givenAt: candidate
        )

        XCTAssertTrue(warnings.contains { $0.type == "too_soon" })
        XCTAssertFalse(warnings.contains { $0.type == "history_unavailable" })
    }

    func testPerTypeSummaryIsCompleteWhenOtherTypeCrowdsPresentationCache() throws {
        let (_, context) = try makeMedicineContainer()
        let now = Date()
        context.insert(
            MedicineType(
                id: "target-type",
                name: "Target medicine",
                minHoursBetweenDoses: 4,
                maxDoses24h: 4,
                childId: "child-1"
            )
        )
        context.insert(
            MedicineType(
                id: "crowding-type",
                name: "Crowding medicine",
                minHoursBetweenDoses: 4,
                maxDoses24h: 4,
                childId: "child-1"
            )
        )
        context.insert(
            MedicineDose(
                id: "target-dose",
                medicineTypeId: "target-type",
                childId: "child-1",
                givenAt: now.addingTimeInterval(-3_600),
                givenBy: "Alex"
            )
        )
        for index in 0..<205 {
            context.insert(
                MedicineDose(
                    id: "crowding-dose-\(index)",
                    medicineTypeId: "crowding-type",
                    childId: "child-1",
                    givenAt: now.addingTimeInterval(TimeInterval(-index))
                )
            )
        }
        try context.save()

        vm.bindModelContext(context)
        vm.selectedChildId = "child-1"
        let targetType = try XCTUnwrap(vm.medicineTypes.first { $0.id == "target-type" })

        XCTAssertFalse(vm.cachedDoses.contains { $0.id == "target-dose" })
        XCTAssertTrue(vm.hasCompleteSafetySummary(for: targetType))
        XCTAssertEqual(vm.safetyColor(for: targetType), .red)
        XCTAssertEqual(vm.dosesIn24h(for: targetType), 1)
        XCTAssertNotNil(vm.lastDoseInfo(for: targetType))
        XCTAssertNotNil(vm.nextSafeTime(for: targetType))
    }

    func testOfflineSafetyFetchFailureIsWarningNotSafeResult() throws {
        enum ExpectedFailure: Error { case failed }
        let (_, context) = try makeMedicineContainer()
        vm = MedicineViewModel(
            offlineSafetyHistoryLoader: { _, _, _, _ in
                throw ExpectedFailure.failed
            }
        )
        vm.bindModelContext(context)

        let warnings = vm.offlineSafetyWarnings(
            medicineType: makeType(),
            childId: "child-1",
            givenAt: Date()
        )
        let eligibility = vm.canLogDoseOffline(
            medicineType: makeType(),
            childId: "child-1"
        )

        XCTAssertEqual(warnings.map(\.type), ["history_unavailable"])
        XCTAssertFalse(eligibility.safe)
        XCTAssertNotNil(eligibility.reason)
    }

    func testOfflineRollingWindowIncludesBothExact24HourBoundaries() throws {
        let (_, context) = try makeMedicineContainer()
        let candidate = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-01-10T12:00:00Z")
        )
        context.insert(
            MedicineDose(
                id: "lower-boundary",
                medicineTypeId: "lower-type",
                childId: "child-1",
                givenAt: candidate.addingTimeInterval(-86_400)
            )
        )
        context.insert(
            MedicineDose(
                id: "upper-boundary",
                medicineTypeId: "upper-type",
                childId: "child-1",
                givenAt: candidate.addingTimeInterval(86_400)
            )
        )
        try context.save()
        vm.bindModelContext(context)

        let lowerWarnings = vm.offlineSafetyWarnings(
            medicineType: makeType(id: "lower-type", minHours: 4, maxDoses: 1),
            childId: "child-1",
            givenAt: candidate
        )
        let upperWarnings = vm.offlineSafetyWarnings(
            medicineType: makeType(id: "upper-type", minHours: 4, maxDoses: 1),
            childId: "child-1",
            givenAt: candidate
        )

        XCTAssertTrue(lowerWarnings.contains { $0.type == "max_reached" })
        XCTAssertTrue(upperWarnings.contains { $0.type == "max_reached" })
    }

    // MARK: - Mutation ordering and safety-request races

    func testOnlineBackdatedDoseKeepsCanonicalGivenAtOrdering() async throws {
        let backdated = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-01-01T08:00:00Z")
        )
        let newer = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-01-02T08:00:00Z")
        )
        let backdatedString = ISODateParser.stringNoFractional(from: backdated)
        let client = makeStubbedClient { request in
            let requestBody = try medicineRequestBodyData(request)
            let submitted = try XCTUnwrap(
                JSONSerialization.jsonObject(with: requestBody) as? [String: Any]
            )
            let submittedID = try XCTUnwrap(submitted["id"] as? String)
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let body = #"{"dose":{"id":"\#(submittedID)","medicine_type_id":"type-1","child_id":"child-1","given_at":"\#(backdatedString)","given_by":"Alex","dose_amount":null,"medicine_name":null,"notes":null,"warnings":[]},"warnings":[]}"#
            return (response, Data(body.utf8))
        }
        defer { client.clearSession() }
        let (_, context) = try makeMedicineContainer()
        let manager = makeSyncManager(client: client)
        vm = MedicineViewModel(apiClient: client, syncManager: manager)
        vm.bindModelContext(context)
        vm.recentDoses = [
            makeDose(id: "newer", givenAt: ISODateParser.stringNoFractional(from: newer))
        ]
        vm.cachedDoses = vm.recentDoses
        vm.selectedChildId = "child-1"
        vm.selectedMedicineTypeId = "type-1"
        vm.givenAt = backdated

        await vm.logDose()

        XCTAssertEqual(vm.recentDoses.first?.givenAt, ISODateParser.stringNoFractional(from: newer))
        XCTAssertEqual(vm.recentDoses.last?.givenAt, backdatedString)
        XCTAssertEqual(vm.cachedDoses.map(\.id), vm.recentDoses.map(\.id))
        XCTAssertTrue(try context.fetch(FetchDescriptor<OfflineAction>()).isEmpty)
        let acknowledged = try XCTUnwrap(
            try context.fetch(FetchDescriptor<MedicineDose>()).first
        )
        XCTAssertEqual(acknowledged.givenBy, "Alex")
        XCTAssertEqual(acknowledged.givenAt, backdated)
    }

    func testDoseTransportNeverStartsWhenDurableTransactionFails() async throws {
        enum InjectedFailure: Error { case save }
        let lock = NSLock()
        var transportCount = 0
        let client = makeStubbedClient { [self] request in
            lock.withLock { transportCount += 1 }
            return try exactDoseResponse(for: request)
        }
        defer { client.clearSession() }
        let (_, context) = try makeMedicineContainer()
        let manager = makeSyncManager(
            client: client,
            saveQueueContext: { _ in throw InjectedFailure.save }
        )
        let value = configuredDoseViewModel(
            client: client,
            syncManager: manager,
            context: context
        )

        await value.logDose()

        XCTAssertEqual(lock.withLock { transportCount }, 0)
        XCTAssertTrue(try context.fetch(FetchDescriptor<MedicineDose>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<OfflineAction>()).isEmpty)
        XCTAssertEqual(
            value.errorMessage,
            "This dose was not saved, so nothing was sent. Please try again."
        )
    }

    func testAcknowledgementSaveFailureKeepsDoseAndStableReplayOperation() async throws {
        enum InjectedFailure: Error { case acknowledgementSave }
        let lock = NSLock()
        var saveCount = 0
        let client = makeStubbedClient { [self] request in
            try exactDoseResponse(for: request)
        }
        defer { client.clearSession() }
        let (_, context) = try makeMedicineContainer()
        let manager = makeSyncManager(
            client: client,
            saveQueueContext: { modelContext in
                let attempt = lock.withLock { () -> Int in
                    saveCount += 1
                    return saveCount
                }
                if attempt == 2 { throw InjectedFailure.acknowledgementSave }
                try modelContext.save()
            }
        )
        let value = configuredDoseViewModel(
            client: client,
            syncManager: manager,
            context: context
        )

        await value.logDose()

        let dose = try XCTUnwrap(try context.fetch(FetchDescriptor<MedicineDose>()).first)
        let action = try XCTUnwrap(try context.fetch(FetchDescriptor<OfflineAction>()).first)
        XCTAssertEqual(action.id, dose.id)
        XCTAssertEqual(action.recordId, dose.id)
        XCTAssertEqual(action.status, .pending)
        XCTAssertEqual(action.retryCount, 0)
        XCTAssertNil(dose.givenBy, "Rollback must retain the optimistic record, not half-apply the receipt")
        XCTAssertEqual(lock.withLock { saveCount }, 3)
        XCTAssertTrue(value.errorMessage?.contains("exact operation will replay safely") == true)
    }

    func testPermanentDirectRejectionRetainsActualDoseAsActionableDeadLetter() async throws {
        let client = makeStubbedClient { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 400,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(#"{"detail":"invalid medicine dose"}"#.utf8))
        }
        defer { client.clearSession() }
        let (_, context) = try makeMedicineContainer()
        let manager = makeSyncManager(client: client)
        let value = configuredDoseViewModel(
            client: client,
            syncManager: manager,
            context: context
        )

        await value.logDose()

        let dose = try XCTUnwrap(try context.fetch(FetchDescriptor<MedicineDose>()).first)
        let action = try XCTUnwrap(try context.fetch(FetchDescriptor<OfflineAction>()).first)
        XCTAssertEqual(action.id, dose.id)
        XCTAssertEqual(action.recordId, dose.id)
        XCTAssertEqual(action.status, .permanent)
        XCTAssertEqual(action.retryCount, 1)
        XCTAssertEqual(action.lastStatusCode, 400)
        XCTAssertTrue(action.lastError?.contains("invalid medicine dose") == true)
        XCTAssertTrue(value.errorMessage?.contains("server rejected it") == true)
    }

    func testMismatchedSuccessResponseCannotRetireTheActualDoseOperation() async throws {
        let client = makeStubbedClient { request in
            let body = try medicineRequestBodyData(request)
            var mismatchedDose = try XCTUnwrap(
                JSONSerialization.jsonObject(with: body) as? [String: Any]
            )
            mismatchedDose["id"] = "different-dose"
            mismatchedDose["given_by"] = "Alex"
            mismatchedDose["warnings"] = []
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let responseBody = try JSONSerialization.data(withJSONObject: [
                "dose": mismatchedDose,
                "warnings": [],
            ])
            return (response, responseBody)
        }
        defer { client.clearSession() }
        let (_, context) = try makeMedicineContainer()
        let manager = makeSyncManager(client: client)
        let value = configuredDoseViewModel(
            client: client,
            syncManager: manager,
            context: context
        )

        await value.logDose()

        let dose = try XCTUnwrap(try context.fetch(FetchDescriptor<MedicineDose>()).first)
        let action = try XCTUnwrap(try context.fetch(FetchDescriptor<OfflineAction>()).first)
        XCTAssertNotEqual(dose.id, "different-dose")
        XCTAssertEqual(action.id, dose.id)
        XCTAssertEqual(action.recordId, dose.id)
        XCTAssertEqual(action.status, .permanent)
        XCTAssertTrue(action.lastError?.contains("different medicine dose payload") == true)
        XCTAssertTrue(value.errorMessage?.contains("server response needs review") == true)
    }

    func testDirectFailureAndSyncReplayUseTheSameDoseIdentityAndPayload() async throws {
        let lock = NSLock()
        var directPayload: [String: Any]?
        var replayItem: [String: Any]?
        let client = makeStubbedClient { request in
            let path = try XCTUnwrap(request.url?.path)
            if path.hasSuffix("/medicine/doses") {
                let body = try medicineRequestBodyData(request)
                let payload = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: body) as? [String: Any]
                )
                lock.withLock { directPayload = payload }
                throw URLError(.notConnectedToInternet)
            }
            if path.hasSuffix("/sync/push") {
                let body = try medicineRequestBodyData(request)
                let root = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: body) as? [String: Any]
                )
                let item = try XCTUnwrap((root["items"] as? [[String: Any]])?.first)
                lock.withLock { replayItem = item }
                let operationID = try XCTUnwrap(item["operation_id"] as? String)
                let recordID = try XCTUnwrap(item["record_id"] as? String)
                let response = HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!
                let data = try JSONSerialization.data(withJSONObject: [
                    "results": [[
                        "operation_id": operationID,
                        "record_id": recordID,
                        "status": "accepted",
                    ]],
                ])
                return (response, data)
            }
            guard path.hasSuffix("/sync/pull") else {
                throw URLError(.unsupportedURL)
            }
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (
                response,
                Data(#"{"records":[],"server_timestamp":"2026-08-10T12:00:00Z","next_cursor":null,"has_more":false}"#.utf8)
            )
        }
        defer { client.clearSession() }
        let (_, context) = try makeMedicineContainer()
        let manager = makeSyncManager(client: client)
        let value = configuredDoseViewModel(
            client: client,
            syncManager: manager,
            context: context
        )

        await value.logDose()
        let pending = try XCTUnwrap(try context.fetch(FetchDescriptor<OfflineAction>()).first)
        XCTAssertEqual(pending.status, .pending)
        await manager.syncNow(modelContext: context)

        let captured = try lock.withLock { () throws -> ([String: Any], [String: Any]) in
            (try XCTUnwrap(directPayload), try XCTUnwrap(replayItem))
        }
        var directReplayPayload = captured.0
        let directID = try XCTUnwrap(directReplayPayload.removeValue(forKey: "id") as? String)
        let replayPayload = try XCTUnwrap(captured.1["payload"] as? [String: Any])
        XCTAssertEqual(captured.1["operation_id"] as? String, directID)
        XCTAssertEqual(captured.1["record_id"] as? String, directID)
        XCTAssertEqual(directReplayPayload as NSDictionary, replayPayload as NSDictionary)
        XCTAssertTrue(try context.fetch(FetchDescriptor<OfflineAction>()).isEmpty)
        XCTAssertEqual(try context.fetch(FetchDescriptor<MedicineDose>()).map(\.id), [directID])
    }

    func testRelaunchSafetyUsesOneDurableDoseForForwardAndBackdatedWarnings() async throws {
        let firstDoseTime = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-01-10T12:00:00Z")
        )
        let client = makeStubbedClient { _ in
            throw URLError(.notConnectedToInternet)
        }
        defer { client.clearSession() }
        let (container, context) = try makeMedicineContainer()
        context.insert(
            MedicineType(
                id: "type-1",
                name: "Calpol",
                minHoursBetweenDoses: 4,
                maxDoses24h: 1,
                childId: "child-1"
            )
        )
        try context.save()
        let firstManager = makeSyncManager(client: client)
        let firstViewModel = configuredDoseViewModel(
            client: client,
            syncManager: firstManager,
            context: context,
            givenAt: firstDoseTime,
            medicineType: makeType(minHours: 4, maxDoses: 1)
        )

        await firstViewModel.logDose()
        XCTAssertEqual(try context.fetch(FetchDescriptor<MedicineDose>()).count, 1)

        let relaunchedContext = ModelContext(container)
        let relaunchedManager = makeSyncManager(client: client)
        let relaunchedViewModel = MedicineViewModel(
            apiClient: client,
            syncManager: relaunchedManager
        )
        relaunchedViewModel.bindModelContext(relaunchedContext)
        let medicineType = try XCTUnwrap(relaunchedViewModel.medicineTypes.first)

        let forwardWarnings = relaunchedViewModel.offlineSafetyWarnings(
            medicineType: medicineType,
            childId: "child-1",
            givenAt: firstDoseTime.addingTimeInterval(3_600)
        )
        let backdatedWarnings = relaunchedViewModel.offlineSafetyWarnings(
            medicineType: medicineType,
            childId: "child-1",
            givenAt: firstDoseTime.addingTimeInterval(-3_600)
        )

        XCTAssertTrue(forwardWarnings.contains { $0.type == "too_soon" })
        XCTAssertTrue(backdatedWarnings.contains {
            $0.type == "too_soon" && $0.message.contains("later recorded dose")
        })
        let forwardMaximum = try XCTUnwrap(
            forwardWarnings.first { $0.type == "max_reached" }
        )
        let backdatedMaximum = try XCTUnwrap(
            backdatedWarnings.first { $0.type == "max_reached" }
        )
        XCTAssertTrue(forwardMaximum.message.contains("This makes 2 doses"))
        XCTAssertTrue(backdatedMaximum.message.contains("This makes 2 doses"))
        XCTAssertFalse(forwardMaximum.message.contains("3 doses"))
        XCTAssertFalse(backdatedMaximum.message.contains("3 doses"))
        XCTAssertEqual(try relaunchedContext.fetch(FetchDescriptor<MedicineDose>()).count, 1)
    }

    func testDelayedOlderSafetyResponseCannotOverwriteLatestSelection() async throws {
        let firstDate = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-01-01T08:00:00Z")
        )
        let secondDate = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-01-02T08:00:00Z")
        )
        let firstValue = ISODateParser.stringNoFractional(from: firstDate)
        let client = makeStubbedClient { request in
            let givenAt = URLComponents(
                url: try XCTUnwrap(request.url),
                resolvingAgainstBaseURL: false
            )?.queryItems?.first(where: { $0.name == "given_at" })?.value
            let isFirst = givenAt == firstValue
            Thread.sleep(forTimeInterval: isFirst ? 0.20 : 0.01)
            let label = isFirst ? "older response" : "latest response"
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let body = #"{"safe":false,"warnings":[{"type":"too_soon","message":"\#(label)","next_safe_at":null}],"next_safe_at":null}"#
            return (response, Data(body.utf8))
        }
        defer { client.clearSession() }
        vm = MedicineViewModel(apiClient: client)

        let firstTask = vm.requestSafetyCheck(
            typeId: "type-1",
            childId: "child-1",
            givenAt: firstDate
        )
        try await Task.sleep(for: .milliseconds(20))
        let secondTask = vm.requestSafetyCheck(
            typeId: "type-1",
            childId: "child-1",
            givenAt: secondDate
        )
        _ = await (firstTask.value, secondTask.value)

        XCTAssertEqual(
            vm.preSubmitSafetyCheck?.warnings.first?.message,
            "latest response"
        )
        XCTAssertFalse(vm.isCheckingSafety)
    }
}
