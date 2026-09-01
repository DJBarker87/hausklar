import SwiftData
import XCTest

@testable import HausKlar

/// Guards the production SwiftData container itself. These tests intentionally
/// use on-disk SQLite stores because duplicate schema fingerprints and staged
/// migration failures can occur before any view is presented.
@MainActor
final class ModelContainerMigrationTests: XCTestCase {
    func testSchemaFingerprintsRemainStable() {
        let expected = [
            1: "863910a819f43d26",
            2: "d11cdcdabce1aa29",
            3: "4f3829eaff73ac99",
            4: "7c7fd93ce8b105a3",
            5: "f54cd222362400c5",
        ]

        let versions: [any VersionedSchema.Type] = [
            HausKlarSchemaV1.self,
            HausKlarSchemaV2.self,
            HausKlarSchemaV3.self,
            HausKlarSchemaV4.self,
            HausKlarSchemaV5.self,
        ]

        for version in versions {
            XCTAssertEqual(
                HausKlarSchemaFingerprint.value(for: version),
                expected[version.versionIdentifier.major],
                "Persisted schema V\(version.versionIdentifier.major) changed. "
                    + "Compare the model against provenance commit before updating this checksum."
            )
        }
    }

    func testLegacyV1IsFaithfulButNotAdvertisedAsAutomaticMigration() throws {
        XCTAssertEqual(HausKlarSchemaV1.provenanceCommit, "a private pre-release revision")
        XCTAssertEqual(Schema(versionedSchema: HausKlarSchemaV1.self).entities.count, 16)
        XCTAssertEqual(
            HausKlarMigrationPlan.schemas.map { schema in
                schema.versionIdentifier.major
            },
            [2, 3, 4, 5]
        )
        XCTAssertFalse(HausKlarMigrationPlan.automaticallyMigratableVersions.contains(1))

        let legacySchema = Schema(versionedSchema: HausKlarSchemaV1.self)
        let startTime = try XCTUnwrap(
            legacySchema.entitiesByName["CalendarEvent"]?.attributesByName["startTime"]
        )
        let givenAt = try XCTUnwrap(
            legacySchema.entitiesByName["MedicineDose"]?.attributesByName["givenAt"]
        )
        let operation = try XCTUnwrap(
            legacySchema.entitiesByName["OfflineAction"]?.attributesByName["operation"]
        )
        XCTAssertEqual(String(reflecting: startTime.valueType), "Swift.String")
        XCTAssertEqual(String(reflecting: givenAt.valueType), "Swift.String")
        XCTAssertEqual(String(reflecting: operation.valueType), "Swift.String")

        // The exact pre-versioning shape remains usable for forensic recovery.
        // We do not ask SwiftData to guess how to convert these rows to Date or
        // enum attributes; production archives the complete store instead.
        let storeURL = try makeStoreURL(label: "V1Recognition")
        var container: ModelContainer? = try makeContainer(
            for: HausKlarSchemaV1.self,
            at: storeURL
        )
        var context: ModelContext? = container.map(ModelContext.init)
        let event = HausKlarSchemaV1.CalendarEvent()
        event.id = "v1-event"
        event.title = "Original LegacyHausKlar row"
        event.startTime = "2026-01-02T03:04:05Z"
        context?.insert(event)
        try context?.save()
        context = nil
        container = nil

        let reopened = try makeContainer(for: HausKlarSchemaV1.self, at: storeURL)
        let rows = try ModelContext(reopened).fetch(
            FetchDescriptor<HausKlarSchemaV1.CalendarEvent>()
        )
        XCTAssertEqual(rows.map(\.title), ["Original LegacyHausKlar row"])
        XCTAssertEqual(rows.map(\.startTime), ["2026-01-02T03:04:05Z"])
    }

    func testCurrentMigrationPlanCreatesCleanPersistentStore() throws {
        let storeURL = try makeStoreURL(label: "CleanV5")
        let schema = Schema(versionedSchema: HausKlarSchemaV5.self)
        let configuration = ModelConfiguration("CleanV5", schema: schema, url: storeURL)
        let container = try ModelContainer(
            for: schema,
            migrationPlan: HausKlarMigrationPlan.self,
            configurations: [configuration]
        )
        let context = ModelContext(container)
        context.insert(Nap(id: "clean-nap", childId: "child-1"))
        context.insert(
            OfflineAction(
                id: "clean-action",
                tableName: "tasks",
                recordId: "task-1",
                payload: #"{"title":"Clean"}"#
            )
        )
        try context.save()

        XCTAssertEqual(try context.fetch(FetchDescriptor<Nap>()).map(\.id), ["clean-nap"])
        let action = try XCTUnwrap(context.fetch(FetchDescriptor<OfflineAction>()).first)
        XCTAssertEqual(action.payloadByteCount, action.payload.utf8.count)
    }

    func testV2StoreMigratesThroughEveryReleasedStage() throws {
        try assertUpgradeToV5(from: HausKlarSchemaV2.self, seed: seedV2)
    }

    func testV3StoreMigratesThroughEveryReleasedStage() throws {
        try assertUpgradeToV5(from: HausKlarSchemaV3.self, seed: seedV3)
    }

    func testV4StoreMigratesToV5() throws {
        try assertUpgradeToV5(from: HausKlarSchemaV4.self, seed: seedV4)
    }

    private func assertUpgradeToV5(
        from sourceVersion: any VersionedSchema.Type,
        seed: (ModelContext, String) throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let major = sourceVersion.versionIdentifier.major
        let marker = "source-v\(major)"
        let storeURL = try makeStoreURL(label: "V\(major)ToV5")

        var sourceContainer: ModelContainer? = try makeContainer(
            for: sourceVersion,
            at: storeURL
        )
        var sourceContext: ModelContext? = sourceContainer.map(ModelContext.init)
        try seed(try XCTUnwrap(sourceContext), marker)
        try sourceContext?.save()
        sourceContext = nil
        sourceContainer = nil

        let currentSchema = Schema(versionedSchema: HausKlarSchemaV5.self)
        let currentConfiguration = ModelConfiguration(
            "CurrentV5",
            schema: currentSchema,
            url: storeURL
        )
        let currentContainer = try ModelContainer(
            for: currentSchema,
            migrationPlan: HausKlarMigrationPlan.self,
            configurations: [currentConfiguration]
        )
        let context = ModelContext(currentContainer)

        try assertEveryCurrentModelFamily(
            in: context,
            expectsPendingDocument: major >= 3,
            file: file,
            line: line
        )

        XCTAssertEqual(
            try context.fetch(FetchDescriptor<CalendarEvent>()).first?.title,
            marker,
            file: file,
            line: line
        )
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<FamilyTask>()).first?.title,
            marker,
            file: file,
            line: line
        )

        let nap = try XCTUnwrap(
            context.fetch(FetchDescriptor<Nap>()).first,
            file: file,
            line: line
        )
        XCTAssertEqual(nap.sleepType, major == 4 ? "night" : "nap", file: file, line: line)

        let dose = try XCTUnwrap(
            context.fetch(FetchDescriptor<MedicineDose>()).first,
            file: file,
            line: line
        )
        XCTAssertNil(dose.medicineName, file: file, line: line)

        let action = try XCTUnwrap(
            context.fetch(FetchDescriptor<OfflineAction>()).first,
            file: file,
            line: line
        )
        XCTAssertEqual(action.status, .pending, file: file, line: line)
        XCTAssertNil(action.nextAttemptAt, file: file, line: line)
        XCTAssertNil(action.lastAttemptAt, file: file, line: line)
        XCTAssertNil(action.lastError, file: file, line: line)
        XCTAssertNil(action.lastStatusCode, file: file, line: line)
        XCTAssertNil(action.payloadByteCount, file: file, line: line)

        if major >= 3 {
            let upload = try XCTUnwrap(
                context.fetch(FetchDescriptor<PendingDocumentUpload>()).first,
                file: file,
                line: line
            )
            XCTAssertEqual(upload.status, .pending, file: file, line: line)
            XCTAssertNil(upload.acknowledgedDocumentJSON, file: file, line: line)
            XCTAssertNil(upload.acknowledgedAt, file: file, line: line)
            XCTAssertNil(upload.lastAttemptAt, file: file, line: line)
            XCTAssertNil(upload.nextAttemptAt, file: file, line: line)
            XCTAssertNil(upload.retryCount, file: file, line: line)
            XCTAssertNil(upload.failureKind, file: file, line: line)
        }
    }

    private func seedV2(_ context: ModelContext, _ marker: String) throws {
        let calendar = HausKlarSchemaV2.CalendarEvent()
        calendar.title = marker
        let task = HausKlarSchemaV2.FamilyTask()
        task.title = marker
        let dose = HausKlarSchemaV2.MedicineDose()
        dose.notes = marker
        let nap = HausKlarSchemaV2.Nap()
        nap.notes = marker

        insert(
            [
                calendar,
                task,
                HausKlarSchemaV2.Child(),
                HausKlarSchemaV2.MedicineType(),
                dose,
                nap,
                HausKlarSchemaV2.DogActivity(),
                HausKlarSchemaV2.Birthday(),
                HausKlarSchemaV2.Meal(),
                HausKlarSchemaV2.MealPlan(),
                HausKlarSchemaV2.ShoppingItem(),
                HausKlarSchemaV2.HealthRecord(),
                HausKlarSchemaV2.ReadingLog(),
                HausKlarSchemaV2.SpellingEntry(),
                HausKlarSchemaV2.GrowthRecord(),
                HausKlarSchemaV2.OfflineAction(),
                HausKlarSchemaV2.RoutineItem(),
            ], into: context)
    }

    private func seedV3(_ context: ModelContext, _ marker: String) throws {
        let calendar = HausKlarSchemaV3.CalendarEvent()
        calendar.title = marker
        let task = HausKlarSchemaV3.FamilyTask()
        task.title = marker
        let dose = HausKlarSchemaV3.MedicineDose()
        dose.notes = marker
        let nap = HausKlarSchemaV3.Nap()
        nap.notes = marker
        let upload = HausKlarSchemaV3.PendingDocumentUpload()
        upload.filePath = "/protected/v3.pdf"
        upload.filename = "v3.pdf"
        upload.title = marker

        insert(
            [
                calendar,
                task,
                HausKlarSchemaV3.Child(),
                HausKlarSchemaV3.MedicineType(),
                dose,
                nap,
                HausKlarSchemaV3.DogActivity(),
                HausKlarSchemaV3.Birthday(),
                HausKlarSchemaV3.Meal(),
                HausKlarSchemaV3.MealPlan(),
                HausKlarSchemaV3.ShoppingItem(),
                HausKlarSchemaV3.HealthRecord(),
                HausKlarSchemaV3.ReadingLog(),
                HausKlarSchemaV3.SpellingEntry(),
                HausKlarSchemaV3.GrowthRecord(),
                HausKlarSchemaV3.OfflineAction(),
                HausKlarSchemaV3.RoutineItem(),
                upload,
            ], into: context)
    }

    private func seedV4(_ context: ModelContext, _ marker: String) throws {
        let calendar = HausKlarSchemaV4.CalendarEvent()
        calendar.title = marker
        let task = HausKlarSchemaV4.FamilyTask()
        task.title = marker
        let dose = HausKlarSchemaV4.MedicineDose()
        dose.notes = marker
        let nap = HausKlarSchemaV4.Nap()
        nap.notes = marker
        nap.sleepType = "night"
        let upload = HausKlarSchemaV4.PendingDocumentUpload()
        upload.filePath = "/protected/v4.pdf"
        upload.filename = "v4.pdf"
        upload.title = marker

        insert(
            [
                calendar,
                task,
                HausKlarSchemaV4.Child(),
                HausKlarSchemaV4.MedicineType(),
                dose,
                nap,
                HausKlarSchemaV4.DogActivity(),
                HausKlarSchemaV4.Birthday(),
                HausKlarSchemaV4.Meal(),
                HausKlarSchemaV4.MealPlan(),
                HausKlarSchemaV4.ShoppingItem(),
                HausKlarSchemaV4.HealthRecord(),
                HausKlarSchemaV4.ReadingLog(),
                HausKlarSchemaV4.SpellingEntry(),
                HausKlarSchemaV4.GrowthRecord(),
                HausKlarSchemaV4.OfflineAction(),
                HausKlarSchemaV4.RoutineItem(),
                upload,
            ], into: context)
    }

    private func insert(
        _ models: [any PersistentModel],
        into context: ModelContext
    ) {
        for model in models {
            context.insert(model)
        }
    }

    private func assertEveryCurrentModelFamily(
        in context: ModelContext,
        expectsPendingDocument: Bool,
        file: StaticString,
        line: UInt
    ) throws {
        XCTAssertEqual(try count(CalendarEvent.self, in: context), 1, file: file, line: line)
        XCTAssertEqual(try count(FamilyTask.self, in: context), 1, file: file, line: line)
        XCTAssertEqual(try count(Child.self, in: context), 1, file: file, line: line)
        XCTAssertEqual(try count(MedicineType.self, in: context), 1, file: file, line: line)
        XCTAssertEqual(try count(MedicineDose.self, in: context), 1, file: file, line: line)
        XCTAssertEqual(try count(Nap.self, in: context), 1, file: file, line: line)
        XCTAssertEqual(try count(DogActivity.self, in: context), 1, file: file, line: line)
        XCTAssertEqual(try count(Birthday.self, in: context), 1, file: file, line: line)
        XCTAssertEqual(try count(Meal.self, in: context), 1, file: file, line: line)
        XCTAssertEqual(try count(MealPlan.self, in: context), 1, file: file, line: line)
        XCTAssertEqual(try count(ShoppingItem.self, in: context), 1, file: file, line: line)
        XCTAssertEqual(try count(HealthRecord.self, in: context), 1, file: file, line: line)
        XCTAssertEqual(try count(ReadingLog.self, in: context), 1, file: file, line: line)
        XCTAssertEqual(try count(SpellingEntry.self, in: context), 1, file: file, line: line)
        XCTAssertEqual(try count(GrowthRecord.self, in: context), 1, file: file, line: line)
        XCTAssertEqual(try count(OfflineAction.self, in: context), 1, file: file, line: line)
        XCTAssertEqual(try count(RoutineItem.self, in: context), 1, file: file, line: line)
        XCTAssertEqual(
            try count(PendingDocumentUpload.self, in: context),
            expectsPendingDocument ? 1 : 0,
            file: file,
            line: line
        )
    }

    private func count<T: PersistentModel>(
        _ type: T.Type,
        in context: ModelContext
    ) throws -> Int {
        try context.fetchCount(FetchDescriptor<T>())
    }

    private func makeContainer(
        for version: any VersionedSchema.Type,
        at storeURL: URL
    ) throws -> ModelContainer {
        let schema = Schema(versionedSchema: version)
        return try ModelContainer(
            for: schema,
            configurations: [
                ModelConfiguration(
                    "FixtureV\(version.versionIdentifier.major)",
                    schema: schema,
                    url: storeURL
                )
            ]
        )
    }

    private func makeStoreURL(label: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "HausKlarMigrationTests-\(label)-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        // ModelContainer has no public close API and can keep SQLite file
        // descriptors alive briefly. The simulator clears its temp directory.
        return directory.appendingPathComponent("HausKlar.store")
    }
}
