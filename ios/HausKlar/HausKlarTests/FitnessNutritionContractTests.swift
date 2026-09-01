import XCTest
import GRDB
import UIKit
@testable import HausKlar

private final class WeakObjectBox<Object: AnyObject> {
    weak var value: Object?

    init(_ value: Object?) {
        self.value = value
    }
}

final class FitnessNutritionContractTests: XCTestCase {
    private var directory: URL!
    private var database: FitnessDatabase!
    private var repository: FitnessNutritionRepository!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FitnessNutritionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        database = FitnessDatabase()
        try database.activateForTesting(storeURL: directory.appendingPathComponent("fitness.sqlite"))
        repository = FitnessNutritionRepository(
            database: database, deviceId: "nutrition-contract-test", fileManager: .default
        )
    }

    override func tearDownWithError() throws {
        database.suspend()
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    func testMalformedPlannedMealOutboxPayloadFailsClosedAndIsRetained() async throws {
        let owner = try XCTUnwrap(database.activeIdentity)
        let draftId = UUID().uuidString
        try database.write { db in
            try db.execute(
                sql:"""
                    INSERT INTO fitness_planned_meal_outbox
                    (id,owner_identity,meal_plan_id,payload_json,created_at)
                    VALUES (?,?,?,'{',?)
                    """,
                arguments:[
                    draftId,owner,UUID().uuidString,FitnessDatabase.dateString(Date()),
                ]
            )
        }

        do {
            _ = try await repository.pendingPlannedMealLogs()
            XCTFail("Malformed planned-meal work must fail the complete outbox read")
        } catch is DecodingError {
            // Expected: the outbox row is not converted into an empty queue.
        }
        XCTAssertEqual(
            try database.read { db in
                try Int.fetchOne(
                    db,sql:"SELECT COUNT(*) FROM fitness_planned_meal_outbox WHERE id=?",
                    arguments:[draftId]
                ) ?? 0
            },
            1
        )
    }

    func testMealKeysAndConfigurableDayBoundaryMatchWireContract() throws {
        XCTAssertEqual(
            FitnessMeal.allCases.map(\.rawValue),
            [
                "breakfast", "lunch", "dinner", "snack", "drink", "pre_workout",
                "during_workout", "post_workout", "other",
            ]
        )
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/London"))
        let formatter = ISO8601DateFormatter()
        let early = try XCTUnwrap(formatter.date(from: "2026-08-02T00:30:00Z"))
        XCTAssertEqual(
            FitnessCalculations.nutritionDate(for: early, dayStartMinutes: 240, calendar: calendar),
            "2026-08-01"
        )
        XCTAssertEqual(
            FitnessCalculations.nutritionDate(for: early, dayStartMinutes: 0, calendar: calendar),
            "2026-08-02"
        )
    }

    func testAddedFoodHighlightPrefersProteinThenFibreThenCalories() {
        let now = Date()
        var entry = FitnessFoodLogEntry(
            id: "entry-1", foodName: "Greek yoghurt", loggedAt: now,
            nutritionDate: "2026-08-20", meal: .breakfast, revision: 1, updatedAt: now
        )
        entry.kcal = 420
        entry.proteinG = 30
        entry.fibreG = 8
        XCTAssertEqual(FitnessNutritionViewFormatting.addedHighlight(for: entry), "30 g protein")

        entry.proteinG = 0
        entry.fibreG = 4.25
        XCTAssertEqual(FitnessNutritionViewFormatting.addedHighlight(for: entry), "4.3 g fibre")

        entry.fibreG = nil
        entry.kcal = 97
        XCTAssertEqual(FitnessNutritionViewFormatting.addedHighlight(for: entry), "97 kcal logged")
    }

    func testBarcodeLookupDecodesToReviewOnlyCopiedDraft() throws {
        let data=Data("""
        {
          "barcode":"5+000000000050","name":"Greek yoghurt","brand":"Example",
          "reference_amount":100,"reference_unit":"g",
          "nutrients":{"calories_kcal":120,"protein_g":9,"carbohydrate_g":4,
            "sugars_g":3.5,"fat_g":7,"saturated_fat_g":4,"fibre_g":0,
            "salt_g":0.12,"sodium_mg":48,"micronutrients":{}},
          "serving":{"name":"pot","amount":150,"unit":"g"},
          "source":"open_food_facts","source_url":"https://world.openfoodfacts.org/product/5+000000000050",
          "warnings":["Review the label"],"needs_review":true
        }
        """.utf8)
        let decoder=JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let value=try decoder.decode(FitnessFoodBarcodeLookup.self,from:data)
        let draft=value.reviewDraft
        XCTAssertEqual(draft.barcode,"5+000000000050")
        XCTAssertEqual(draft.brand,"Example")
        XCTAssertEqual(draft.version.sodiumMg,48)
        XCTAssertEqual(draft.version.sourceType,"open_food_facts")
        XCTAssertEqual(draft.version.sourceNote,value.sourceUrl)
        XCTAssertEqual(draft.version.confidence,"copied")
        XCTAssertTrue(value.needsReview)
    }

    func testPrivateLabelReconciliationIsReferencedFreshSymlinkSafeAndBounded() async throws {
        let labelDirectory = directory
            .appendingPathComponent("PrivateRequired/NutritionLabels",isDirectory: true)
        try FileManager.default.createDirectory(at: labelDirectory,withIntermediateDirectories: true)
        let now = Date()
        let old = now.addingTimeInterval(-7_200)
        let referencedID = UUID().uuidString.lowercased()
        let referenced = labelDirectory.appendingPathComponent("\(referencedID).jpg")
        try Data("referenced".utf8).write(to: referenced)
        try FileManager.default.setAttributes([.modificationDate: old],ofItemAtPath: referenced.path)
        try database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO fitness_private_file_uploads
                    (asset_id,domain_entity_id,asset_kind,storage_class,relative_path,
                     original_filename,media_type,byte_count,state,created_at)
                    VALUES (?,?,'nutrition_label','private_required',?,?,?,?,'pending_upload',?)
                    """,
                arguments: [
                    referencedID,"food-1","PrivateRequired/NutritionLabels/\(referencedID).jpg",
                    "label.jpg","image/jpeg",10,FitnessDatabase.dateString(now),
                ]
            )
        }

        let staleFiles = [
            labelDirectory.appendingPathComponent("\(UUID().uuidString.lowercased()).jpg"),
            labelDirectory.appendingPathComponent("\(UUID().uuidString.lowercased()).heic"),
            labelDirectory.appendingPathComponent(
                ".\(UUID().uuidString.lowercased()).staging"
            ),
        ]
        for file in staleFiles {
            try Data("orphan".utf8).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: old],ofItemAtPath: file.path)
        }
        let fresh = labelDirectory.appendingPathComponent(
            "\(UUID().uuidString.lowercased()).png"
        )
        try Data("fresh".utf8).write(to: fresh)
        let nearMiss = labelDirectory.appendingPathComponent("manual.jpg")
        try Data("manual".utf8).write(to: nearMiss)
        try FileManager.default.setAttributes([.modificationDate: old],ofItemAtPath: nearMiss.path)
        for index in 0..<300 {
            let unrelated=labelDirectory.appendingPathComponent("unrelated-\(index).txt")
            try Data("unrelated".utf8).write(to:unrelated)
        }
        let providerTarget = directory.appendingPathComponent("provider-label.jpg")
        try Data("provider".utf8).write(to: providerTarget)
        let symbolicLink = labelDirectory.appendingPathComponent(
            "\(UUID().uuidString.lowercased()).jpg"
        )
        try FileManager.default.createSymbolicLink(at: symbolicLink,withDestinationURL: providerTarget)

        let firstPass = try await repository.reconcilePrivateLabelFiles(
            now: now,minimumAge: 3_600,maximumCandidates: 1,maximumRemovals: 1
        )
        XCTAssertEqual(firstPass,1)
        XCTAssertEqual(
            staleFiles.filter { FileManager.default.fileExists(atPath: $0.path) }.count,
            2
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: referenced.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: nearMiss.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: symbolicLink.path))
        XCTAssertEqual(try Data(contentsOf: providerTarget),Data("provider".utf8))

        let secondPass = try await repository.reconcilePrivateLabelFiles(
            now: now,minimumAge: 3_600,maximumCandidates: 32,maximumRemovals: 32
        )
        XCTAssertEqual(secondPass,2)
        XCTAssertTrue(staleFiles.allSatisfy {
            !FileManager.default.fileExists(atPath: $0.path)
        })
        XCTAssertTrue(FileManager.default.fileExists(atPath: referenced.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: symbolicLink.path))
        XCTAssertEqual(try Data(contentsOf: providerTarget),Data("provider".utf8))
    }

    func testNutritionLabelPersistsVerifiedDestinationBytesAndPreservesProvider() async throws {
        let artifact=try makeLabelDraft()
        defer { PhotoUploadPrep.removeStagedFile(artifact.draft.stagedFile) }
        let originalBytes=try Data(contentsOf:artifact.provider)

        let food=try await repository.createFood(
            baseFoodDraft(name:"Verified label"),label:artifact.draft
        )
        let assetId=try XCTUnwrap(food.currentVersion?.labelAssetId)
        let row=try database.read { db in
            try XCTUnwrap(Row.fetchOne(
                db,
                sql:"SELECT * FROM fitness_private_file_uploads WHERE asset_id=?",
                arguments:[assetId]
            ))
        }
        let storedURL=try await repository.localLabelURL(assetId:assetId)
        let storedValues=try storedURL.resourceValues(forKeys:[
            .fileSizeKey,.isRegularFileKey,.isSymbolicLinkKey,
        ])

        XCTAssertEqual(row["byte_count"] as Int,storedValues.fileSize)
        XCTAssertEqual(row["media_type"] as String,"image/png")
        XCTAssertEqual(row["state"] as String,"pending_upload")
        XCTAssertNotNil(row["dependent_mutation_id"] as String?)
        XCTAssertEqual(try Data(contentsOf:storedURL),originalBytes)
        XCTAssertEqual(try Data(contentsOf:artifact.provider),originalBytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath:artifact.draft.fileURL.path))
    }

    func testNutritionLabelWaitsForUploadAndMutationAcknowledgementsBeforeCleanup() async throws {
        let artifact=try makeLabelDraft()
        defer { PhotoUploadPrep.removeStagedFile(artifact.draft.stagedFile) }
        let food=try await repository.createFood(
            baseFoodDraft(name:"Durable label"),label:artifact.draft
        )
        let assetId=try XCTUnwrap(food.currentVersion?.labelAssetId)
        let state=try database.read { db in
            try XCTUnwrap(Row.fetchOne(
                db,
                sql:"SELECT dependent_mutation_id,relative_path FROM fitness_private_file_uploads WHERE asset_id=?",
                arguments:[assetId]
            ))
        }
        let mutationId:String=state["dependent_mutation_id"]
        let storedURL=try await repository.localLabelURL(assetId:assetId)
        let syncRepository=FitnessRepository(
            database:database,deviceId:"nutrition-ack-test"
        )

        let mutationsBeforeUpload=try await syncRepository.pendingMutations()
        XCTAssertFalse(mutationsBeforeUpload.contains {
            $0.mutationId == mutationId
        })
        try await repository.markLabelUploadAcknowledged(
            assetId:assetId,
            result:FitnessPrivateAssetUploadResult(
                assetId:assetId,state:"staged",storageClass:"private_required",
                uploadAcknowledged:true
            )
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath:storedURL.path))
        let mutationsAfterUpload=try await syncRepository.pendingMutations()
        XCTAssertTrue(mutationsAfterUpload.contains {
            $0.mutationId == mutationId
        })

        try await syncRepository.applySync(
            FitnessSyncResponse(
                status:"ok",currentSyncProtocolVersion:1,currentClientSchemaVersion:1,
                minimumSupportedClientSchemaVersion:1,accepted:[],
                ackedMutationIds:[mutationId],rejectedMutations:[],changes:[],
                redirects:[],notices:[],nextCursor:0
            ),
            sentMutationIds:[mutationId]
        )
        let pendingAfterAcknowledgements=try await repository.pendingLabels()
        let acknowledged=try XCTUnwrap(
            pendingAfterAcknowledgements.first { $0.id == assetId }
        )
        XCTAssertTrue(acknowledged.uploadAcknowledged)
        XCTAssertTrue(acknowledged.referenceAcknowledged)
        XCTAssertTrue(FileManager.default.fileExists(atPath:storedURL.path))

        try await repository.cleanupAcknowledgedLabels()
        let pendingAfterCleanup=try await repository.pendingLabels()
        XCTAssertFalse(FileManager.default.fileExists(atPath:storedURL.path))
        XCTAssertFalse(pendingAfterCleanup.contains { $0.id == assetId })
    }

    func testNutritionLabelRejectsOversizedAndSymlinkSourcesWithoutTouchingProvider() async throws {
        let provider=try writePNG(named:"provider-label.png")
        let providerBytes=try Data(contentsOf:provider)
        let linkDirectory=directory.appendingPathComponent(
            UUID().uuidString,isDirectory:true
        )
        try FileManager.default.createDirectory(at:linkDirectory,withIntermediateDirectories:true)
        let link=linkDirectory.appendingPathComponent("original")
        try FileManager.default.createSymbolicLink(at:link,withDestinationURL:provider)
        let linkedDraft=FitnessNutritionLabelDraft(
            stagedFile:.init(directoryURL:linkDirectory,fileURL:link),
            originalFilename:"nutrition-label.png",mediaType:"image/png",
            byteCount:providerBytes.count,ownerIdentity:"test:test"
        )
        defer { PhotoUploadPrep.removeStagedFile(linkedDraft.stagedFile) }

        await assertThrowsAsync {
            _=try await self.repository.createFood(
                self.baseFoodDraft(name:"Linked label"),label:linkedDraft
            )
        }
        XCTAssertEqual(try Data(contentsOf:provider),providerBytes)

        let oversizedDirectory=directory.appendingPathComponent(
            UUID().uuidString,isDirectory:true
        )
        try FileManager.default.createDirectory(
            at:oversizedDirectory,withIntermediateDirectories:true
        )
        let oversized=oversizedDirectory.appendingPathComponent("original")
        XCTAssertTrue(FileManager.default.createFile(atPath:oversized.path,contents:nil))
        let handle=try FileHandle(forWritingTo:oversized)
        try handle.truncate(
            atOffset:UInt64(FitnessNutritionLabelDraft.maximumByteCount+1)
        )
        try handle.close()
        let oversizedDraft=FitnessNutritionLabelDraft(
            stagedFile:.init(directoryURL:oversizedDirectory,fileURL:oversized),
            originalFilename:"nutrition-label.jpg",mediaType:"image/jpeg",
            byteCount:FitnessNutritionLabelDraft.maximumByteCount,
            ownerIdentity:"test:test"
        )
        defer { PhotoUploadPrep.removeStagedFile(oversizedDraft.stagedFile) }
        await assertThrowsAsync {
            _=try await self.repository.createFood(
                self.baseFoodDraft(name:"Oversized label"),label:oversizedDraft
            )
        }
        XCTAssertEqual(try Data(contentsOf:provider),providerBytes)
    }

    func testPendingLabelRemovalRejectsCorruptSymlinkPathWithoutDeletingTarget() async throws {
        let provider=try writePNG(named:"removal-provider.png")
        let providerBytes=try Data(contentsOf:provider)
        let labelDirectory=directory.appendingPathComponent(
            "PrivateRequired/NutritionLabels",isDirectory:true
        )
        try FileManager.default.createDirectory(
            at:labelDirectory,withIntermediateDirectories:true
        )
        let assetId=UUID().uuidString.lowercased()
        let link=labelDirectory.appendingPathComponent("\(assetId).png")
        try FileManager.default.createSymbolicLink(at:link,withDestinationURL:provider)
        try database.write { db in
            try db.execute(
                sql:"""
                    INSERT INTO fitness_private_file_uploads
                    (asset_id,domain_entity_id,asset_kind,storage_class,relative_path,
                     original_filename,media_type,byte_count,state,created_at)
                    VALUES (?,?,'nutrition_label','private_required',?,?,?,?,'pending_upload',?)
                    """,
                arguments:[
                    assetId,"food-corrupt","PrivateRequired/NutritionLabels/\(assetId).png",
                    "nutrition-label.png","image/png",providerBytes.count,
                    FitnessDatabase.dateString(Date()),
                ]
            )
        }

        await assertThrowsAsync {
            try await self.repository.removePendingLabel(assetId:assetId)
        }

        XCTAssertEqual(try Data(contentsOf:provider),providerBytes)
        XCTAssertEqual(try database.read { db in
            try Int.fetchOne(
                db,
                sql:"SELECT COUNT(*) FROM fitness_private_file_uploads WHERE asset_id=?",
                arguments:[assetId]
            ) ?? 0
        },1)
    }

    @MainActor
    func testDatabaseFailureCleansPickerDraftButRetainsRestartRecoverableOrphan() async throws {
        enum InjectedFailure:Error { case beforeCommit }
        let artifact=try makeLabelDraft()
        let providerBytes=try Data(contentsOf:artifact.provider)
        let failingRepository=FitnessNutritionRepository(
            database:database,
            deviceId:"nutrition-failure-test",
            beforeLabelDatabaseCommit:{ throw InjectedFailure.beforeCommit }
        )
        let service=FitnessNutritionService(
            repository:failingRepository,apiClient:.shared,database:database
        )
        let viewModel=FitnessNutritionViewModel(
            repository:failingRepository,service:service,database:database
        )

        let createdFood = await viewModel.createFood(
            baseFoodDraft(name:"Failed label"),label:artifact.draft
        )
        XCTAssertFalse(createdFood)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath:artifact.draft.stagedFile.directoryURL.path
        ))
        XCTAssertEqual(try Data(contentsOf:artifact.provider),providerBytes)
        XCTAssertEqual(try database.read { db in
            try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM fitness_private_file_uploads") ?? -1
        },0)
        XCTAssertEqual(try database.read { db in
            try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM fitness_foods") ?? -1
        },0)

        let labelDirectory=directory.appendingPathComponent(
            "PrivateRequired/NutritionLabels",isDirectory:true
        )
        let orphan=try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at:labelDirectory,includingPropertiesForKeys:nil
            ).first { !$0.lastPathComponent.hasPrefix(".") }
        )
        let now=Date()
        try FileManager.default.setAttributes(
            [.modificationDate:now.addingTimeInterval(-7_200)],
            ofItemAtPath:orphan.path
        )
        let restarted=FitnessNutritionRepository(
            database:database,deviceId:"nutrition-restart-test"
        )
        let reconciledFiles = try await restarted.reconcilePrivateLabelFiles(
            now:now,minimumAge:3_600
        )
        XCTAssertEqual(reconciledFiles,1)
        XCTAssertFalse(FileManager.default.fileExists(atPath:orphan.path))
    }

    func testAccountSwitchDuringLabelStagingNeverPublishesIntoReplacementStore() async throws {
        let artifact=try makeLabelDraft()
        defer { PhotoUploadPrep.removeStagedFile(artifact.draft.stagedFile) }
        let originalRoot=try XCTUnwrap(database.activeStoreURL)
            .deletingLastPathComponent()
        let replacementDirectory=directory.appendingPathComponent(
            "replacement-owner",isDirectory:true
        )
        try FileManager.default.createDirectory(
            at:replacementDirectory,withIntermediateDirectories:true
        )
        let replacementStore=replacementDirectory.appendingPathComponent("fitness.sqlite")
        let switchingDatabase=try XCTUnwrap(database)
        let switchingRepository=FitnessNutritionRepository(
            database:database,
            deviceId:"nutrition-switch-test",
            beforeLabelFilePublication:{
                try switchingDatabase.activateForTesting(
                    identity:"family:kat",storeURL:replacementStore
                )
            }
        )

        await assertThrowsAsync {
            _=try await switchingRepository.createFood(
                self.baseFoodDraft(name:"Wrong owner"),label:artifact.draft
            )
        }
        XCTAssertEqual(database.activeIdentity,"family:kat")
        XCTAssertEqual(try database.read { db in
            try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM fitness_private_file_uploads") ?? -1
        },0)
        XCTAssertEqual(try database.read { db in
            try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM fitness_foods") ?? -1
        },0)
        let retained=originalRoot.appendingPathComponent(
            "PrivateRequired/NutritionLabels",isDirectory:true
        )
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath:retained.path).filter {
                !$0.hasPrefix(".")
            }.count,
            1
        )
        let replacementLabels=replacementDirectory.appendingPathComponent(
            "PrivateRequired/NutritionLabels",isDirectory:true
        )
        XCTAssertTrue(
            (try? FileManager.default.contentsOfDirectory(atPath:replacementLabels.path))?
                .isEmpty ?? true
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath:artifact.provider.path))
    }

    @MainActor
    func testPhotoDraftOwnerCleansReplacementLateCompletionAndDismissal() throws {
        let provider=try writePNG(named:"owner-provider.png")
        let root=directory.appendingPathComponent("owner-staging",isDirectory:true)
        let first=try PhotoUploadPrep.stageTransferredFile(at:provider,root:root)
        let second=try PhotoUploadPrep.stageTransferredFile(at:provider,root:root)
        let third=try PhotoUploadPrep.stageTransferredFile(at:provider,root:root)
        let preview=try XCTUnwrap(PhotoUploadPrep.displayImage(
            at:first.fileURL,maxPixelSize:128
        ))
        let owner=FitnessNutritionPhotoDraftOwner()
        let firstGeneration=owner.beginReplacement()
        XCTAssertTrue(owner.installMealPhoto(
            first,preview:preview,generation:firstGeneration
        ))

        let replacementGeneration=owner.beginReplacement()
        XCTAssertFalse(FileManager.default.fileExists(atPath:first.directoryURL.path))
        XCTAssertFalse(owner.installMealPhoto(
            second,preview:preview,generation:firstGeneration
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath:second.directoryURL.path))
        XCTAssertTrue(owner.installMealPhoto(
            third,preview:preview,generation:replacementGeneration
        ))
        owner.discard()
        XCTAssertFalse(FileManager.default.fileExists(atPath:third.directoryURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath:provider.path))
    }

    @MainActor
    func testPhotoDraftOwnerLifetimeEndCleansStagedPhoto() throws {
        let provider=try writePNG(named:"owner-lifetime-provider.png")
        let root=directory.appendingPathComponent("owner-lifetime-staging",isDirectory:true)
        let staged=try PhotoUploadPrep.stageTransferredFile(at:provider,root:root)
        let preview=try XCTUnwrap(PhotoUploadPrep.displayImage(
            at:staged.fileURL,maxPixelSize:128
        ))
        var owner:FitnessNutritionPhotoDraftOwner?=FitnessNutritionPhotoDraftOwner()
        let releasedOwner=WeakObjectBox(owner)
        let generation=try XCTUnwrap(owner?.beginReplacement())
        XCTAssertEqual(owner?.installMealPhoto(
            staged,preview:preview,generation:generation
        ),true)
        XCTAssertTrue(FileManager.default.fileExists(atPath:staged.fileURL.path))

        owner=nil

        XCTAssertNil(releasedOwner.value)
        XCTAssertFalse(FileManager.default.fileExists(atPath:staged.directoryURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath:provider.path))
    }

    @MainActor
    func testPhotoDraftOwnerTransfersSoleLabelCleanupToSaveOperation() throws {
        let artifact=try makeLabelDraft()
        defer { PhotoUploadPrep.removeStagedFile(artifact.draft.stagedFile) }
        let owner=FitnessNutritionPhotoDraftOwner()
        let generation=owner.beginReplacement()
        XCTAssertTrue(owner.installLabel(artifact.draft,generation:generation))

        let transferred=try XCTUnwrap(owner.takeLabelDraft())
        owner.discard()

        XCTAssertNil(owner.labelDraft)
        XCTAssertTrue(FileManager.default.fileExists(atPath:transferred.fileURL.path))
        PhotoUploadPrep.removeStagedFile(transferred.stagedFile)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath:transferred.stagedFile.directoryURL.path
        ))
        XCTAssertTrue(FileManager.default.fileExists(atPath:artifact.provider.path))
    }

    func testCurrentDiaryDayUsesDeviceTimezoneWhenSavedTimezoneIsStale() async throws {
        let berlin = try XCTUnwrap(TimeZone(identifier: "Europe/Berlin"))
        let travellingRepository = FitnessNutritionRepository(
            database: database,
            deviceId: "nutrition-travel-test",
            fileManager: .default,
            currentTimeZone: { berlin }
        )
        try await travellingRepository.applySettings(
            FitnessNutritionSettings(
                id: "nutrition-settings",
                timezone: "Asia/Tokyo",
                nutritionDayStartMinutes: 240,
                revision: 1
            )
        )
        let instant = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-08-03T01:30:00Z")
        )

        let day = try await travellingRepository.day(on: instant)

        XCTAssertEqual(day.nutritionDate, "2026-08-02")
        var calendar=Calendar(identifier:.gregorian)
        calendar.timeZone=berlin
        let next=try XCTUnwrap(
            FitnessCalculations.nutritionDayDate(
                day.nutritionDate,addingDays:1,calendar:calendar
            )
        )
        let formatter=DateFormatter()
        formatter.calendar=calendar
        formatter.locale=Locale(identifier:"en_US_POSIX")
        formatter.timeZone=berlin
        formatter.dateFormat="yyyy-MM-dd"
        XCTAssertEqual(formatter.string(from:next),"2026-08-03")
    }

    @MainActor
    func testDefaultAnalysisPeriodBuildsInclusiveFourteenDayRequestWindow() throws {
        XCTAssertEqual(FitnessNutritionViewModel.defaultAnalysisPeriodDays,14)
        var calendar=Calendar(identifier:.gregorian)
        calendar.timeZone=try XCTUnwrap(TimeZone(identifier:"Europe/Berlin"))

        let range=try XCTUnwrap(
            FitnessCalculations.nutritionAnalysisRange(
                endingOn:"2026-08-03",days:FitnessNutritionViewModel.defaultAnalysisPeriodDays,
                calendar:calendar
            )
        )

        XCTAssertEqual(range.start,"2026-07-21")
        XCTAssertEqual(range.end,"2026-08-03")
    }

    func testMultiDayContributorRecommendationDecodesFromWireContract() throws {
        let data = Data(#"""
        {
          "start":"2026-07-21","end":"2026-08-03","sample_days":13,"calendar_days":14,
          "completeness":0.9285714286,
          "contributors":[{
            "item_id":"food-pasta","item_kind":"food","label":"Synthetic public demo record 8",
            "meal_key":"dinner","nutrient_key":"calories_kcal","total":9360,"share":0.31,
            "entry_count":13,"sample_days":13,"typical_amount":1,"typical_unit":"serving"
          }],
          "recommendation":{
            "food_or_meal":"Synthetic public demo record 8","item_id":"food-pasta","item_kind":"food",
            "meal_key":"dinner",
            "observation_period":{"start":"2026-07-21","end":"2026-08-03","calendar_days":14,"logged_days":13},
            "calculation":{"observed_average_calories_kcal":2300,"target_average_calories_kcal":2100,"average_gap_calories_kcal":200,"minimum_material_gap_calories_kcal":25,"target_days":13},
            "frequency":{"entries":13,"days":13,"per_week":6.5},
            "typical_amount":{"value":1,"unit":"serving"},
            "proposed_change":{"kind":"reduce_portion","fraction":0.1,"amount":0.1,"unit":"serving","resulting_amount":0.9,"description":"Reduce the recorded portion by 10%."},
            "expected_effect":{"per_occurrence_calories_kcal":72,"period_calories_kcal":936,"weekly_calories_kcal":468},
            "uncertainty":{"nutrient_completeness":1,"diary_day_completeness":0.9285714286,"target_day_coverage":1,"estimated_entry_share":0,"estimated_calorie_share":0,"description":"Recorded portions can differ from what was eaten."},
            "why_practical":"It is a repeated modest change."
          }
        }
        """#.utf8)
        let decoder=JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let analysis=try decoder.decode(FitnessNutritionAnalysis.self,from:data)

        XCTAssertEqual(analysis.contributors.first?.nutrientKey,"calories_kcal")
        XCTAssertEqual(analysis.contributors.first?.typicalUnit,"serving")
        XCTAssertEqual(analysis.recommendation?.frequency.entries,13)
        XCTAssertEqual(analysis.recommendation?.calculation.averageGapCaloriesKcal,200)
        XCTAssertEqual(analysis.recommendation?.expectedEffect.perOccurrenceCaloriesKcal,72)
        XCTAssertEqual(analysis.recommendation?.proposedChange.fraction,0.1)
    }

    func testMissingNutrientsRemainUnknownAndTargetsRejectNonFiniteValues() {
        let complete = FitnessNutritionValues(
            caloriesKcal: 100, proteinG: 5, carbohydrateG: 10, sugarsG: 2,
            fatG: 3, saturatedFatG: 1, fibreG: 4, saltG: 0.2
        )
        var incomplete = complete
        incomplete.proteinG = nil
        let total = FitnessNutritionValues.exactTotal([complete, incomplete])
        XCTAssertEqual(total.caloriesKcal, 200)
        XCTAssertNil(total.proteinG, "An unknown contributor must not become a false zero")

        let now = Date()
        let invalid = FitnessNutritionTarget(
            id: "target", metric: .caloriesKcal, mode: .fixed,
            targetValue: .infinity, targetMin: nil, targetMax: nil,
            trainingDayValue: nil, restDayValue: nil, phaseId: nil,
            effectiveFrom: "2026-08-02", effectiveUntil: nil, active: true,
            revision: 0, updatedAt: now, deletedAt: nil
        )
        XCTAssertFalse(invalid.isValid)
    }

    func testNutritionTargetBalancePreservesOverTargetAmount() {
        let balance=FitnessCalculations.nutritionTargetBalance(target:2_000,consumed:2_112)

        XCTAssertEqual(balance,-112)
        XCTAssertEqual(
            FitnessCalculations.nutritionBalanceText(balance,unit:"kcal"),
            "112 kcal over"
        )
    }

    func testPersistedKcalIsSoleTruthAndKJConvertsOnlyWhenVersionIsCreated() async throws {
        let food = try await repository.createFood(
            FitnessFoodDraft(
                name: "Energy bar", brand: nil, categoryKey: nil, barcode: nil,
                notes: nil, householdShared: false, favourite: false,
                version: FitnessFoodVersionDraft(
                    referenceAmount: 100, referenceUnit: "g", caloriesKcal: nil,
                    sourceEnergyValue: 418.4, sourceEnergyUnit: "kj",
                    sourceType: "label", confidence: "measured"
                )
            )
        )
        let version = try XCTUnwrap(food.versions.first)
        XCTAssertEqual(try XCTUnwrap(version.caloriesKcal), 100, accuracy: 0.000_001)
        XCTAssertEqual(version.sourceEnergyValue, 418.4)
        XCTAssertEqual(version.sourceEnergyUnit, "kj")

        var provenanceOnly = version
        provenanceOnly.caloriesKcal = nil
        XCTAssertNil(
            provenanceOnly.authoritativeCalories,
            "Reading history must not reinterpret source kJ as analytical kcal"
        )
    }

    func testNutritionChildrenUseDistinctSyncTypesAndUnitMismatchIsRejected() async throws {
        let food = try await repository.createFood(baseFoodDraft(name: "Oats"))
        let version = try await repository.addFoodVersion(
            foodId: food.id,
            draft: FitnessFoodVersionDraft(
                referenceAmount: 100, referenceUnit: "g", caloriesKcal: 370,
                proteinG: 13, carbohydrateG: 60, fatG: 7,
                sourceType: "manual", confidence: "measured"
            )
        )
        _ = try await repository.addServing(
            foodId: food.id,
            draft: FitnessFoodServingDraft(
                name: "Bowl", amount: 1, unit: "serving", canonicalAmount: 50,
                canonicalUnit: "g", measurementQuality: .measured, isDefault: true
            )
        )
        let component = FitnessRecipeComponent(
            id: UUID().uuidString, foodVersionId: version.id, foodName: food.name,
            amount: 50, unit: "g", canonicalAmount: 50, canonicalUnit: "g", sequence: 0
        )
        let recipeDraft = FitnessRecipeDraft(
            name: "Porridge", notes: nil, householdShared: false, favourite: true,
            components: [component], finishedWeightG: 250, servings: 1, caloriesKcal: nil,
            lowerCaloriesKcal: nil, upperCaloriesKcal: nil, confidence: "calculated", sourceNote: nil
        )
        let recipe = try await repository.createRecipe(recipeDraft)
        _ = try await repository.addRecipeVersion(recipeId: recipe.id, draft: recipeDraft)
        let template = FitnessMealTemplate(
            id: UUID().uuidString, name: "Usual breakfast", meal: .breakfast,
            timeRelevance: "morning", favourite: true, active: true,
            items: [
                FitnessMealTemplateItem(
                    id: UUID().uuidString, foodVersionId: version.id, recipeVersionId: nil,
                    label: food.name, amount: 50, unit: "g", canonicalAmount: 50,
                    canonicalUnit: "g", measurementQuality: .weighed, sequence: 0
                ),
            ],
            revision: 0, updatedAt: Date(), deletedAt: nil
        )
        _ = try await repository.saveTemplate(template)
        _ = try await repository.saveTarget(
            FitnessNutritionTarget(
                id: UUID().uuidString, metric: .proteinG, mode: .range,
                targetValue: nil, targetMin: 100, targetMax: 140,
                trainingDayValue: nil, restDayValue: nil, phaseId: nil,
                effectiveFrom: "2026-08-02", effectiveUntil: nil, active: true,
                revision: 0, updatedAt: Date(), deletedAt: nil
            )
        )

        let types: Set<String> = try database.read { db in
            Set(try String.fetchAll(db, sql: "SELECT entity_type FROM fitness_outbox"))
        }
        XCTAssertTrue(
            Set([
                FitnessEntityType.foodVersion.rawValue,
                FitnessEntityType.foodServing.rawValue,
                FitnessEntityType.recipe.rawValue,
                FitnessEntityType.recipeVersion.rawValue,
                FitnessEntityType.mealTemplate.rawValue,
                FitnessEntityType.nutritionTarget.rawValue,
            ]).isSubset(of: types)
        )

        do {
            _ = try await repository.saveLog(
                FitnessFoodLogDraft(
                    foodVersionId: version.id, recipeVersionId: nil, label: food.name,
                    loggedAt: Date(), localTimezone: "Europe/London", meal: .breakfast,
                    enteredAmount: 100, enteredUnit: "ml", canonicalAmount: 100,
                    canonicalUnit: "ml", measurementQuality: .measured,
                    notes: nil, contextTags: []
                )
            )
            XCTFail("A food version measured in grams must reject a millilitre canonical amount")
        } catch let error as FitnessNutritionRepositoryError {
            XCTAssertEqual(error.errorDescription, FitnessNutritionRepositoryError.invalidLog.errorDescription)
        }
    }

    func testRepeatedSaveOfOneLoggingIntentUpdatesTheSameDiaryEntry() async throws {
        let food = try await repository.createFood(baseFoodDraft(name: "Porridge"))
        let version = try XCTUnwrap(food.currentVersion)
        let entryId = UUID().uuidString
        func draft(amount: Double) -> FitnessFoodLogDraft {
            FitnessFoodLogDraft(
                foodVersionId: version.id, recipeVersionId: nil, label: food.name,
                loggedAt: Date(timeIntervalSince1970: 1_800_000_000), localTimezone: "Europe/London",
                meal: .breakfast, enteredAmount: amount, enteredUnit: "g",
                canonicalAmount: amount, canonicalUnit: "g", measurementQuality: .measured,
                notes: nil, contextTags: []
            )
        }

        let first = try await repository.saveLog(draft(amount: 100), id: entryId)
        // The same intent saved again — a second tap, or a retry after an error.
        let second = try await repository.saveLog(draft(amount: 120), id: entryId)

        XCTAssertEqual(first.id, entryId)
        XCTAssertEqual(second.id, entryId)
        let day = try await repository.day(nutritionDate: first.nutritionDate)
        XCTAssertEqual(day.entries.map(\.id), [entryId])
        XCTAssertEqual(day.entries.first?.enteredAmount, 120)
    }

    func testRepeatedTemplateLoggingKeepsOneDiaryEntryPerTemplateItem() async throws {
        let food = try await repository.createFood(baseFoodDraft(name: "Oats"))
        let version = try XCTUnwrap(food.currentVersion)
        let template = FitnessMealTemplate(
            id: UUID().uuidString, name: "Two items", meal: .breakfast,
            timeRelevance: nil, favourite: false, active: true,
            items: [
                templateItem(versionId: version.id, sequence: 0),
                templateItem(versionId: version.id, sequence: 1),
            ],
            revision: 0, updatedAt: Date(), deletedAt: nil
        )
        _ = try await repository.saveTemplate(template)
        let entryIds = Dictionary(
            uniqueKeysWithValues: template.items.map { ($0.id, UUID().uuidString) }
        )
        let loggedAt = Date(timeIntervalSince1970: 1_800_000_000)

        let first = try await repository.logTemplate(
            template, amounts: [:], at: loggedAt, entryIds: entryIds
        )
        let second = try await repository.logTemplate(
            template, amounts: [:], at: loggedAt, entryIds: entryIds
        )

        XCTAssertEqual(Set(first.map(\.id)), Set(entryIds.values))
        XCTAssertEqual(Set(second.map(\.id)), Set(entryIds.values))
        let nutritionDate = try XCTUnwrap(first.first).nutritionDate
        let day = try await repository.day(nutritionDate: nutritionDate)
        XCTAssertEqual(day.entries.count, template.items.count)
        XCTAssertEqual(Set(day.entries.map(\.id)), Set(entryIds.values))
    }

    func testTemplateLoggingRollsBackEveryEntryWhenOneAmountIsInvalid() async throws {
        let food = try await repository.createFood(baseFoodDraft(name: "Milk"))
        let version = try XCTUnwrap(food.versions.first)
        let template = FitnessMealTemplate(
            id: UUID().uuidString, name: "Two items", meal: .breakfast,
            timeRelevance: nil, favourite: false, active: true,
            items: [
                templateItem(versionId: version.id, sequence: 0),
                templateItem(versionId: version.id, sequence: 1),
            ],
            revision: 0, updatedAt: Date(), deletedAt: nil
        )
        _ = try await repository.saveTemplate(template)
        let before = try counts()

        do {
            _ = try await repository.logTemplate(
                template, amounts: [template.items[1].id: .nan], at: Date()
            )
            XCTFail("Invalid amounts must abort the template transaction")
        } catch {
            let after = try counts()
            XCTAssertEqual(after.logs, before.logs)
            XCTAssertEqual(after.outbox, before.outbox)
        }
    }

    func testSharedDefinitionsExposeOnlyLogAndExplicitCopyActions() async throws {
        var food = try await repository.createFood(baseFoodDraft(name: "Shared oats"))
        food.editable = false
        let foodActions = FitnessNutritionActionAvailability.food(food)
        XCTAssertTrue(foodActions.canLog)
        XCTAssertTrue(foodActions.canCopy)
        XCTAssertFalse(foodActions.canEditIdentity)
        XCTAssertFalse(foodActions.canAddVersion)
        XCTAssertFalse(foodActions.canFavourite)
        XCTAssertFalse(foodActions.canArchive)
        XCTAssertFalse(foodActions.canMerge)

        let version = try XCTUnwrap(food.currentVersion)
        var recipe = try await repository.createRecipe(FitnessRecipeDraft(
            name: "Shared breakfast", notes: nil, householdShared: true, favourite: false,
            components: [FitnessRecipeComponent(
                id: UUID().uuidString, foodVersionId: version.id, foodName: food.name,
                amount: 100, unit: "g", canonicalAmount: 100, canonicalUnit: "g", sequence: 0
            )], finishedWeightG: nil, servings: 1, caloriesKcal: nil,
            lowerCaloriesKcal: nil, upperCaloriesKcal: nil,
            confidence: "calculated", sourceNote: nil
        ))
        recipe.editable = false
        let recipeActions = FitnessNutritionActionAvailability.recipe(recipe)
        XCTAssertTrue(recipeActions.canLog)
        XCTAssertTrue(recipeActions.canCopy)
        XCTAssertFalse(recipeActions.canEditIdentity)
        XCTAssertFalse(recipeActions.canAddVersion)
        XCTAssertFalse(recipeActions.canFavourite)
        XCTAssertFalse(recipeActions.canArchive)
    }

    func testConsumerFirstRunAndCapturePoliciesStayActionFirst() {
        XCTAssertEqual(FitnessOnboardingCommitPolicy.choiceStepCount,3)
        XCTAssertEqual(FitnessOnboardingCommitPolicy.totalSetupStepCount,4)
        XCTAssertFalse(
            FitnessOnboardingCommitPolicy.createsGoalOrSessions(at:.choiceDraft)
        )
        XCTAssertFalse(
            FitnessOnboardingCommitPolicy.createsGoalOrSessions(at:.preview)
        )
        XCTAssertTrue(
            FitnessOnboardingCommitPolicy.createsGoalOrSessions(at:.confirmation)
        )
        XCTAssertFalse(FitnessOnboardingCommitPolicy.canConfirm(preview:nil))
        let preview=FitnessOnboardingWeekPreview(
            previewId:"preview",weekStart:"2026-08-03",summary:"A realistic week.",
            sessions:[]
        )
        XCTAssertTrue(FitnessOnboardingCommitPolicy.canConfirm(preview:preview))
        XCTAssertFalse(FitnessOnboardingCommitPolicy.presentsAutomatically(status:.skipped))
        XCTAssertTrue(FitnessOnboardingCommitPolicy.offersFinishLater(status:.skipped))
        XCTAssertFalse(FitnessOnboardingCommitPolicy.offersFinishLater(status:.complete))
        XCTAssertEqual(
            FitnessOnboardingAccessibilityTarget.afterTransition(
                choiceStep:1,hasPreview:false
            ),
            .heading(step:2)
        )
        XCTAssertEqual(
            FitnessOnboardingAccessibilityTarget.afterTransition(
                choiceStep:4,hasPreview:true
            ),
            .heading(step:4)
        )

        XCTAssertTrue(FitnessCapturePolicy.requiresOnDeviceSpeechRecognition)
        XCTAssertTrue(FitnessCapturePolicy.photoRemainsLocalDraft)
        XCTAssertFalse(FitnessCapturePolicy.canSaveReviewedText("   "))
        XCTAssertTrue(FitnessCapturePolicy.canSaveReviewedText("Porridge and berries"))
        XCTAssertEqual(FitnessLogAccessibilityTarget.afterQuickLog(entryId:nil),.none)
        XCTAssertEqual(FitnessLogAccessibilityTarget.afterQuickLog(entryId:"entry"),.undo)

        XCTAssertTrue(
            FitnessPlannedMealShortcutPolicy.isVisible(
                plannedMealCount:1,useMealPlanForCoach:false
            ),
            "An explicit Log shortcut must not depend on Coach meal-plan context"
        )
        XCTAssertFalse(
            FitnessPlannedMealShortcutPolicy.isVisible(
                plannedMealCount:0,useMealPlanForCoach:true
            )
        )
    }

    func testOverviewFactFollowsExplicitOutcomeAndNeverDefaultsToWeight() {
        let snapshot=FitnessOverviewFactSnapshot(
            activeDays:3,strengthSessions:2,runningSessions:1,
            runningDistanceMetres:5_200,averageSleepSeconds:27_000,weightKilograms:81.4
        )

        XCTAssertEqual(
            FitnessOverviewFactPolicy.fact(outcome:.buildStrength,snapshot:snapshot).kind,
            .strength
        )
        XCTAssertEqual(
            FitnessOverviewFactPolicy.fact(outcome:.runFurther,snapshot:snapshot).kind,
            .running
        )
        XCTAssertEqual(
            FitnessOverviewFactPolicy.fact(outcome:.improveEnergy,snapshot:snapshot).kind,
            .energy
        )
        XCTAssertEqual(
            FitnessOverviewFactPolicy.fact(outcome:.supportWeight,snapshot:snapshot).kind,
            .weight
        )
        XCTAssertEqual(
            FitnessOverviewFactPolicy.fact(outcome:nil,snapshot:snapshot).kind,
            .movement
        )
    }

    func testConsumerCachePendingMealAndUndoAreOwnerIsolatedAndPersistent() async throws {
        let profile=FitnessOnboardingProfile(
            id:"profile-dom",status:.draft,mainOutcome:.feelFitter,
            availability:[],activities:[.walking],equipment:[],foodPreferences:[],
            sourceConnections:[],coachStyle:.balanced,useFamilyCalendar:false,
            useHouseholdMeals:false,useWeather:false,memoryEnabled:false,
            preview:nil,confirmation:nil
        )
        try await repository.cacheOnboarding(profile)
        let goalTemplates=[FitnessGoalTemplate(
            id:"move-consistently",title:"Move consistently",description:"Build a weekly habit.",
            targetPrompt:"How many sessions?",inputKind:.sessionsPerWeek,
            unitLabel:"sessions per week",minimumValue:1,maximumValue:14,step:1,
            suggestedValue:3,supportsTargetDate:true
        )]
        let weeklyReview=FitnessWeeklyReview(
            weekStart:"2026-08-03",weekEnd:"2026-08-09",
            totals:.init(
                completedSessions:2,activeDays:2,durationMinutes:90,
                distanceKm:nil,strengthVolumeKg:nil
            ),
            goal:nil,
            highlight:.init(title:"Two active days",detail:"A solid start."),
            opportunity:.init(
                title:"Plan one more session",detail:"Choose a day that fits.",
                destination:.plan,action:.planSession,actionLabel:"Plan session"
            )
        )
        try await repository.cacheGoalTemplates(goalTemplates)
        try await repository.cacheWeeklyReview(weeklyReview)

        let planned=FitnessPlannedHouseholdMeal(
            mealPlanId:"plan-1",date:"2026-08-03",mealType:.dinner,
            mealId:"meal-1",mealName:"Family dinner",linkId:"link-1",
            recipeId:"recipe-1",recipeVersionId:"recipe-version-1",
            recipeName:"Pasta",suggestedPortion:1,suggestedUnit:.serving
        )
        let plannedDraft=FitnessPlannedMealLogDraft(
            plannedMeal:planned,clientId:"nutrition-contract-test"
        )
        try await repository.enqueuePlannedMealLog(plannedDraft)

        let food=try await repository.createFood(baseFoodDraft(name:"Porridge"))
        let version=try XCTUnwrap(food.currentVersion)
        let entry=try await repository.saveLog(FitnessFoodLogDraft(
            foodVersionId:version.id,recipeVersionId:nil,label:food.name,
            loggedAt:Date(),localTimezone:"Europe/London",meal:.breakfast,
            enteredAmount:100,enteredUnit:"g",canonicalAmount:100,canonicalUnit:"g",
            measurementQuality:.measured,notes:nil,contextTags:[]
        ))
        try await repository.setQuickLogUndo(entry)
        let savedUndo=try await repository.quickLogUndo()
        let savedPendingMeals=try await repository.pendingPlannedMealLogs()
        XCTAssertEqual(savedUndo?.id,entry.id)
        XCTAssertEqual(savedPendingMeals.map(\.id),[plannedDraft.id])

        let storeURL=try XCTUnwrap(database.activeStoreURL)
        try database.activateForTesting(identity:"family:kat",storeURL:storeURL)
        let katRepository=FitnessNutritionRepository(
            database:database,deviceId:"kat-device",fileManager:.default
        )
        let katOnboarding=try await katRepository.cachedOnboarding()
        let katTemplates=try await katRepository.cachedGoalTemplates()
        let katReview=try await katRepository.cachedWeeklyReview(weekStart:"2026-08-03")
        let katUndo=try await katRepository.quickLogUndo()
        let katPendingMeals=try await katRepository.pendingPlannedMealLogs()
        XCTAssertNil(katOnboarding)
        XCTAssertTrue(katTemplates.isEmpty)
        XCTAssertNil(katReview)
        XCTAssertNil(katUndo)
        XCTAssertTrue(katPendingMeals.isEmpty)

        try database.activateForTesting(identity:"test:test",storeURL:storeURL)
        let restored=FitnessNutritionRepository(
            database:database,deviceId:"nutrition-contract-test",fileManager:.default
        )
        let restoredOnboarding=try await restored.cachedOnboarding()
        let restoredTemplates=try await restored.cachedGoalTemplates()
        let restoredReview=try await restored.cachedWeeklyReview(weekStart:"2026-08-03")
        let restoredUndo=try await restored.quickLogUndo()
        let restoredPendingMeals=try await restored.pendingPlannedMealLogs()
        XCTAssertEqual(restoredOnboarding,profile)
        XCTAssertEqual(restoredTemplates,goalTemplates)
        XCTAssertEqual(restoredReview,weeklyReview)
        XCTAssertEqual(restoredUndo?.id,entry.id)
        XCTAssertEqual(restoredPendingMeals.map(\.id),[plannedDraft.id])
    }

    func testBatchedFoodLibraryPreservesQuickUseAndChildRecords() async throws {
        let oats=try await repository.createFood(baseFoodDraft(name:"Oats"))
        let yoghurt=try await repository.createFood(baseFoodDraft(name:"Yoghurt"))
        _=try await repository.addServing(
            foodId:oats.id,
            draft:FitnessFoodServingDraft(
                name:"Bowl",amount:1,unit:"serving",canonicalAmount:60,
                canonicalUnit:"g",measurementQuality:.measured,isDefault:true
            )
        )
        let version=try XCTUnwrap(oats.currentVersion)
        for (offset,meal,amount) in [(0,FitnessMeal.breakfast,50.0),(60,.snack,65.0)] {
            _=try await repository.saveLog(FitnessFoodLogDraft(
                foodVersionId:version.id,recipeVersionId:nil,label:oats.name,
                loggedAt:Date(timeIntervalSince1970:1_800_000_000+Double(offset)),
                localTimezone:"Europe/London",meal:meal,
                enteredAmount:amount,enteredUnit:"g",canonicalAmount:amount,canonicalUnit:"g",
                measurementQuality:.measured,notes:nil,contextTags:[]
            ))
        }

        let foods=try await repository.foods()
        let loadedOats=try XCTUnwrap(foods.first { $0.id == oats.id })
        let loadedYoghurt=try XCTUnwrap(foods.first { $0.id == yoghurt.id })
        XCTAssertEqual(loadedOats.versions.map(\.id),[version.id])
        XCTAssertEqual(loadedOats.servings.first?.name,"Bowl")
        XCTAssertEqual(loadedOats.defaultServingGrams,60)
        XCTAssertEqual(loadedOats.quickUse?.lastAmount,65)
        XCTAssertEqual(loadedOats.quickUse?.usualAmount,65)
        XCTAssertEqual(loadedOats.quickUse?.frequencyCount,2)
        XCTAssertEqual(loadedOats.quickUse?.recentMealKeys,[.snack,.breakfast])
        XCTAssertNil(loadedYoghurt.quickUse)
    }

    private func baseFoodDraft(name: String) -> FitnessFoodDraft {
        FitnessFoodDraft(
            name: name, brand: nil, categoryKey: nil, barcode: nil, notes: nil,
            householdShared: false, favourite: false,
            version: FitnessFoodVersionDraft(
                referenceAmount: 100, referenceUnit: "g", caloriesKcal: 100,
                proteinG: 5, carbohydrateG: 10, fatG: 2,
                sourceType: "manual", confidence: "measured"
            )
        )
    }

    private func makeLabelDraft(
        ownerIdentity:String="test:test"
    ) throws -> (draft:FitnessNutritionLabelDraft,provider:URL) {
        let provider=try writePNG(named:"label-provider-\(UUID().uuidString).png")
        let stagingRoot=directory.appendingPathComponent(
            "PickerStaging",isDirectory:true
        )
        let staged=try PhotoUploadPrep.stageTransferredFile(
            at:provider,root:stagingRoot
        )
        do {
            let byteCount=try PhotoUploadPrep.validatedStagedImageByteCount(
                staged,declaredTypeIdentifiers:[]
            )
            let metadata=try XCTUnwrap(PhotoUploadPrep.fileMetadata(at:staged.fileURL))
            return (
                FitnessNutritionLabelDraft(
                    stagedFile:staged,
                    originalFilename:"nutrition-label.\(metadata.fileExtension)",
                    mediaType:metadata.mediaType,
                    byteCount:byteCount,
                    ownerIdentity:ownerIdentity
                ),
                provider
            )
        } catch {
            PhotoUploadPrep.removeStagedFile(staged)
            throw error
        }
    }

    private func writePNG(named name:String) throws -> URL {
        let renderer=UIGraphicsImageRenderer(size:CGSize(width:12,height:8))
        let data=renderer.pngData { context in
            UIColor.systemGreen.setFill()
            context.fill(CGRect(x:0,y:0,width:12,height:8))
        }
        let url=directory.appendingPathComponent(name)
        try data.write(to:url,options:.atomic)
        return url
    }

    private func assertThrowsAsync<T>(
        file:StaticString=#filePath,
        line:UInt=#line,
        _ operation:() async throws -> T
    ) async {
        do {
            _=try await operation()
            XCTFail("Expected operation to throw",file:file,line:line)
        } catch {
            // Expected.
        }
    }

    private func templateItem(versionId: String, sequence: Int) -> FitnessMealTemplateItem {
        FitnessMealTemplateItem(
            id: UUID().uuidString, foodVersionId: versionId, recipeVersionId: nil,
            label: "Saved item", amount: 100, unit: "g", canonicalAmount: 100,
            canonicalUnit: "g", measurementQuality: .measured, sequence: sequence
        )
    }

    private func counts() throws -> (logs: Int, outbox: Int) {
        try database.read { db in
            (
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM fitness_food_log_entries") ?? 0,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM fitness_outbox") ?? 0
            )
        }
    }
}
