import XCTest
import PDFKit
import SwiftData
import UIKit
@testable import HausKlar

private enum DocumentPersistenceProbeError: Error, Equatable {
    case save
    case fetch
}

@MainActor
private final class DocumentUploadProbe {
    private(set) var calls = 0
    let delay: Duration
    var response: DocumentDTO?

    init(delay: Duration = .zero) {
        self.delay = delay
    }

    func perform() async throws -> DocumentDTO {
        calls += 1
        if delay > .zero { try await Task.sleep(for: delay) }
        guard let response else {
            struct MissingResponse: Error {}
            throw MissingResponse()
        }
        return response
    }

    func callCount() -> Int { calls }
}

@MainActor
private final class DocumentSaveProbe {
    var saveCount = 0
    var failingSaveNumber: Int?
    var additionalFailingSaveNumbers: Set<Int> = []

    func save(_ context: ModelContext) throws {
        saveCount += 1
        if saveCount == failingSaveNumber || additionalFailingSaveNumbers.contains(saveCount) {
            throw DocumentPersistenceProbeError.save
        }
        try context.save()
    }
}

@MainActor
private final class DocumentFetchProbe {
    var shouldFail = true
    private(set) var fetchCount = 0

    func fetch(_ context: ModelContext) throws -> [PendingDocumentUpload] {
        fetchCount += 1
        if shouldFail { throw DocumentPersistenceProbeError.fetch }
        return try context.fetch(FetchDescriptor<PendingDocumentUpload>())
    }
}

@MainActor
private final class DocumentCleanupProbe {
    var shouldFail = false
    var calls = 0

    func remove(_ directory: URL) async throws {
        calls += 1
        if shouldFail {
            struct ExpectedCleanupFailure: Error {}
            throw ExpectedCleanupFailure()
        }
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }
}

@MainActor
private final class DocumentStageProbe {
    var started = false

    func stage(
        sourceURL: URL,
        filename: String,
        id: String,
        root: URL
    ) async throws -> DocumentUploadService.StagedUpload {
        started = true
        try await Task.sleep(for: .seconds(10))
        throw CancellationError()
    }
}

private final class DocumentCopyProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var previousTotal = 0
    private var largestChunk = 0

    func record(totalBytes: Int) {
        lock.lock()
        largestChunk = max(largestChunk, totalBytes - previousTotal)
        previousTotal = totalBytes
        lock.unlock()
    }

    func snapshot() -> (totalBytes: Int, largestChunk: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (previousTotal, largestChunk)
    }
}

@MainActor
final class DocumentCaptureServiceTests: XCTestCase {

    private func documentDTO(id: String) -> DocumentDTO {
        DocumentDTO(
            id: id,
            title: "Nursery letter",
            originalFilename: "letter.pdf",
            mediaType: "application/pdf",
            fileSize: 128,
            sha256: "abc",
            source: "file",
            category: .other,
            categoryConfidence: nil,
            status: "inbox",
            documentDate: nil,
            documentDateConfidence: nil,
            pageCount: 1,
            extractedText: nil,
            notes: nil,
            processor: "local",
            people: [],
            suggestions: [],
            pendingSuggestionCount: 0,
            readyForBatchFiling: false,
            downloadUrl: "/documents/\(id)/content",
            createdAt: "2026-08-10T10:00:00Z",
            updatedAt: "2026-08-10T10:00:00Z",
            createdBy: "test"
        )
    }

    private func uploadContext() throws -> ModelContext {
        let schema = Schema([PendingDocumentUpload.self])
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        return ModelContext(container)
    }

    private func enqueueTestUpload(
        service: DocumentUploadService,
        context: ModelContext,
        lease: DocumentUploadService.IdentityLease,
        title: String = "Nursery letter"
    ) async throws -> PendingDocumentUpload {
        let asset = try DocumentCaptureService.makeTextDocument("Private nursery letter")
        defer { DocumentCaptureService.removeTemporaryAsset(asset) }
        return try await service.enqueueWithoutBlockingUI(
            asset: asset,
            title: title,
            category: .other,
            documentDate: nil,
            extractedText: "",
            notes: "",
            personIds: [],
            suggestions: [],
            useHermes: false,
            modelContext: context,
            expectedIdentityLease: lease
        )
    }

    private func assertCompleteProtection(
        at url: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: url.path),
            file: file,
            line: line
        )
#if targetEnvironment(simulator)
        XCTAssertEqual(LocalFileProtection.sensitive, .complete, file: file, line: line)
#else
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual(
            attributes[.protectionKey] as? String,
            FileProtectionType.complete.rawValue,
            file: file,
            line: line
        )
#endif
    }

    private func temporaryDirectory() throws -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func writePDF(pageCount: Int, to url: URL) throws {
        let renderer = UIGraphicsPDFRenderer(
            bounds: CGRect(x: 0, y: 0, width: 200, height: 300)
        )
        try renderer.writePDF(to: url) { context in
            for _ in 0..<pageCount {
                context.beginPage()
            }
        }
    }

    private func writeTestImage(
        color: UIColor,
        size: CGSize = CGSize(width: 32, height: 24),
        to url: URL
    ) throws {
        let image = UIGraphicsImageRenderer(size: size).image { context in
            context.cgContext.setFillColor(color.cgColor)
            context.cgContext.fill(CGRect(origin: .zero, size: size))
        }
        try XCTUnwrap(image.pngData()).write(to: url)
    }

    func testInferredTitleUsesFirstMeaningfulLine() {
        let title = DocumentCaptureService.inferredTitle(
            from: "\n  \nExample Town Primary School\nDear parent",
            fallback: "letter.pdf"
        )

        XCTAssertEqual(title, "Example Town Primary School")
    }

    func testInferredTitleFallsBackToFilenameWithoutExtension() {
        let title = DocumentCaptureService.inferredTitle(from: "\n", fallback: "school-letter.pdf")

        XCTAssertEqual(title, "school-letter")
    }

    func testEmptyTextProducesNoSuggestions() {
        XCTAssertTrue(DocumentCaptureService.suggestions(from: "  \n", assignedTo: nil).isEmpty)
    }

    func testActionableLineProducesAssignedTask() {
        let suggestions = DocumentCaptureService.suggestions(
            from: "Class update\nPlease return the signed consent form.",
            assignedTo: "child-1"
        )

        let task = suggestions.first(where: { $0.kind == .task })
        XCTAssertEqual(task?.title, "Return the signed consent form")
        XCTAssertEqual(task?.assignedTo, "child-1")
        XCTAssertEqual(task?.sourceText, "Please return the signed consent form.")
        XCTAssertTrue(task?.isIncluded == true)
    }

    func testDraftUploadJSONOmitsLocalSelectionState() throws {
        let draft = CaptureSuggestionDraft(
            kind: .task,
            title: "Return consent form",
            assignedTo: "child-1",
            isIncluded: false
        )
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase

        let data = try encoder.encode(draft)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["kind"] as? String, "task")
        XCTAssertEqual(object["assigned_to"] as? String, "child-1")
        XCTAssertNil(object["is_included"])
    }

    func testLinkedActionCompletionStateDecodes() throws {
        let json = """
        {
          "id": "suggestion-1",
          "document_id": "document-1",
          "kind": "task",
          "title": "Pay nursery invoice",
          "details": null,
          "start_time": null,
          "end_time": null,
          "due_date": "2026-07-20T17:00:00Z",
          "all_day": true,
          "assigned_to": "user-1",
          "assigned_to_name": "Alex",
          "confidence": 1,
          "source_text": null,
          "status": "accepted",
          "result_id": "task-1",
          "result_status": "completed",
          "result_completed_at": "2026-07-18T12:00:00Z",
          "created_at": "2026-07-10T10:00:00Z",
          "updated_at": "2026-07-18T12:00:00Z"
        }
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let action = try decoder.decode(CaptureSuggestionDTO.self, from: Data(json.utf8))

        XCTAssertEqual(action.resultStatus, "completed")
        XCTAssertEqual(action.resultId, "task-1")
        XCTAssertNotNil(action.resultCompletedAt)
    }

    func testEmailCaptureAddressDecodes() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let value = try decoder.decode(
            DocumentInboxAddressDTO.self,
            from: Data(#"{"configured":true,"address":"family-token@example.invalid"}"#.utf8)
        )

        XCTAssertTrue(value.configured)
        XCTAssertEqual(value.address, "family-token@example.invalid")
    }

    func testTextCaptureUsesCompleteFileProtection() throws {
        let asset = try DocumentCaptureService.makeTextDocument("Private nursery letter")
        defer { DocumentCaptureService.removeTemporaryAsset(asset) }

        try assertCompleteProtection(at: asset.fileURL)
        try assertCompleteProtection(at: asset.fileURL.deletingLastPathComponent())
    }

    func testSinglePhotoCaptureKeepsOriginalImageBytes() throws {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20))
        let image = renderer.image { context in
            UIColor.systemBlue.setFill()
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        }
        let original = try XCTUnwrap(image.pngData())

        let asset = try DocumentCaptureService.makeImageDocument(from: original)
        defer { DocumentCaptureService.removeTemporaryAsset(asset) }

        XCTAssertEqual(asset.mediaType, "image/png")
        XCTAssertEqual(asset.source, "photo")
        XCTAssertEqual(asset.pageCount, 1)
        XCTAssertEqual(try Data(contentsOf: asset.fileURL), original)
        try assertCompleteProtection(at: asset.fileURL)
    }

    func testTransferredPhotoCopiesWithoutMutatingProviderOriginal() throws {
        let root = try temporaryDirectory()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("provider-original.png")
        try writeTestImage(color: .systemTeal, to: source)
        let original = try Data(contentsOf: source)

        let asset = try DocumentCaptureService.importTransferredImage(source)
        defer { DocumentCaptureService.removeTemporaryAsset(asset) }

        XCTAssertNotEqual(asset.fileURL.standardizedFileURL, source.standardizedFileURL)
        XCTAssertEqual(asset.source, "photo")
        XCTAssertEqual(asset.mediaType, "image/png")
        XCTAssertEqual(try Data(contentsOf: asset.fileURL), original)
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        try assertCompleteProtection(at: asset.fileURL)
    }

    func testMultiplePhotosAreCombinedIntoOnePDF() async throws {
        let red = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 18)).image { context in
            context.cgContext.setFillColor(UIColor.systemRed.cgColor)
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 24, height: 18))
        }
        let blue = UIGraphicsImageRenderer(size: CGSize(width: 18, height: 24)).image { context in
            context.cgContext.setFillColor(UIColor.systemBlue.cgColor)
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 18, height: 24))
        }

        let asset = try await DocumentCaptureService.makePDF(
            from: [try XCTUnwrap(red.pngData()), try XCTUnwrap(blue.pngData())]
        )
        defer { DocumentCaptureService.removeTemporaryAsset(asset) }

        XCTAssertEqual(asset.mediaType, "application/pdf")
        XCTAssertEqual(asset.source, "photo")
        XCTAssertEqual(asset.pageCount, 2)
        XCTAssertEqual(PDFDocument(url: asset.fileURL)?.pageCount, 2)
        try assertCompleteProtection(at: asset.fileURL)
    }

    func testStagedPhotosRenderIncrementallyIntoMultiPagePDF() async throws {
        let providerRoot = try temporaryDirectory()
        try FileManager.default.createDirectory(
            at: providerRoot,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: providerRoot) }

        var stagedAssets: [CapturedDocumentAsset] = []
        defer { stagedAssets.forEach(DocumentCaptureService.removeTemporaryAsset) }
        for (index, color) in [UIColor.systemRed, .systemGreen, .systemBlue].enumerated() {
            let source = providerRoot.appendingPathComponent("provider-\(index).png")
            try writeTestImage(color: color, to: source)
            stagedAssets.append(try DocumentCaptureService.importTransferredImage(source))
        }

        let pdf = try await DocumentCaptureService.makePDF(
            fromStagedImageAssets: stagedAssets
        )
        defer { DocumentCaptureService.removeTemporaryAsset(pdf) }

        XCTAssertEqual(pdf.mediaType, "application/pdf")
        XCTAssertEqual(pdf.pageCount, 3)
        XCTAssertEqual(PDFDocument(url: pdf.fileURL)?.pageCount, 3)
        XCTAssertTrue(stagedAssets.allSatisfy {
            FileManager.default.fileExists(atPath: $0.fileURL.path)
        })
        try assertCompleteProtection(at: pdf.fileURL)
    }

    func testStagedPhotoPDFAggregateCapIsEnforcedBeforeRendering() async throws {
        let root = try temporaryDirectory()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let individualSize = (DocumentCaptureService.maximumFileBytes / 2) + 1
        var assets: [CapturedDocumentAsset] = []
        for index in 0..<2 {
            let source = root.appendingPathComponent("large-\(index).png")
            try writeTestImage(color: index == 0 ? .systemOrange : .systemPurple, to: source)
            let handle = try FileHandle(forWritingTo: source)
            try handle.truncate(atOffset: UInt64(individualSize))
            try handle.close()
            assets.append(CapturedDocumentAsset(
                fileURL: source,
                filename: source.lastPathComponent,
                mediaType: "image/png",
                pageCount: 1,
                source: "photo"
            ))
        }

        do {
            _ = try await DocumentCaptureService.makePDF(fromStagedImageAssets: assets)
            XCTFail("Expected aggregate source bytes to be rejected")
        } catch let error as DocumentCaptureError {
            guard case .fileTooLarge = error else {
                return XCTFail("Expected fileTooLarge, got \(error)")
            }
        }
    }

    func testCancelledTransferredPhotoCopyCleansOwnedStagingOnly() async throws {
        let root = try temporaryDirectory()
        let providerRoot = root.appendingPathComponent("provider", isDirectory: true)
        let stagingRoot = root.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(
            at: providerRoot,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let source = providerRoot.appendingPathComponent("original.png")
        try writeTestImage(color: .systemIndigo, to: source)
        let original = try Data(contentsOf: source)

        let task = Task.detached {
            try DocumentCaptureService.importTransferredImage(
                source,
                destinationRoot: stagingRoot,
                copyChunkSize: 1
            ) { _ in
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let stagedChildren = try FileManager.default.contentsOfDirectory(
            at: stagingRoot,
            includingPropertiesForKeys: nil
        )
        XCTAssertTrue(stagedChildren.isEmpty)
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testPDFCaptureRejectsMoreThanSixtyImagesBeforeRendering() async throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { context in
            context.cgContext.setFillColor(UIColor.black.cgColor)
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        let data = try XCTUnwrap(image.pngData())

        do {
            _ = try await DocumentCaptureService.makePDF(
                from: Array(repeating: data, count: DocumentCaptureService.maximumPageCount + 1)
            )
            XCTFail("Expected the page limit to be enforced")
        } catch let error as DocumentCaptureError {
            guard case .tooManyPages = error else {
                return XCTFail("Expected tooManyPages, got \(error)")
            }
        }
    }

    func testImportRejectsSparseFileAboveMaximumBeforeCopying() throws {
        let root = try temporaryDirectory()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("oversized.txt")
        XCTAssertTrue(FileManager.default.createFile(atPath: source.path, contents: nil))
        let handle = try FileHandle(forWritingTo: source)
        try handle.truncate(atOffset: UInt64(DocumentCaptureService.maximumFileBytes + 1))
        try handle.close()

        XCTAssertThrowsError(try DocumentCaptureService.importFile(source)) { error in
            guard let captureError = error as? DocumentCaptureError,
                  case .fileTooLarge = captureError else {
                return XCTFail("Expected fileTooLarge, got \(error)")
            }
        }
    }

    func testFiftyMiBPhotoImportUsesBoundedStreamingMemory() throws {
        let root = try temporaryDirectory()
        let stagingRoot = root.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("large-photo.jpg")
        let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
            context.cgContext.setFillColor(UIColor.systemBlue.cgColor)
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        try XCTUnwrap(image.jpegData(compressionQuality: 0.8)).write(to: source)
        let targetBytes = 50 * 1_024 * 1_024
        let handle = try FileHandle(forWritingTo: source)
        try handle.truncate(atOffset: UInt64(targetBytes))
        try handle.close()
        let probe = DocumentCopyProbe()
        let options = XCTMeasureOptions()
        options.iterationCount = 1
        var importedAsset: CapturedDocumentAsset?
        var importError: Error?

        measure(metrics: [XCTMemoryMetric(), XCTClockMetric()], options: options) {
            autoreleasepool {
                do {
                    importedAsset = try DocumentCaptureService.importTransferredImage(
                        source,
                        destinationRoot: stagingRoot,
                        copyChunkSize: 1_024 * 1_024,
                        onChunkCopied: { totalBytes in
                            probe.record(totalBytes: totalBytes)
                        }
                    )
                } catch {
                    importError = error
                }
            }
        }

        XCTAssertNil(importError)
        let asset = try XCTUnwrap(importedAsset)
        defer { DocumentCaptureService.removeTemporaryAsset(asset) }
        let snapshot = probe.snapshot()
        XCTAssertEqual(snapshot.totalBytes, targetBytes)
        XCTAssertLessThanOrEqual(snapshot.largestChunk, 1_024 * 1_024)
        XCTAssertEqual(
            try asset.fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
            targetBytes
        )
    }

    func testImportRejectsMalformedPDFWithPDFMagic() throws {
        let root = try temporaryDirectory()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("malformed.pdf")
        try Data("%PDF-1.7\nthis is not a valid PDF".utf8).write(to: source)

        XCTAssertThrowsError(try DocumentCaptureService.importFile(source)) { error in
            guard let captureError = error as? DocumentCaptureError,
                  case .unreadableFile = captureError else {
                return XCTFail("Expected unreadableFile, got \(error)")
            }
        }
    }

    func testImportRejectsEncryptedPDFBeforeExtraction() throws {
        let root = try temporaryDirectory()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let plain = root.appendingPathComponent("plain.pdf")
        let encrypted = root.appendingPathComponent("encrypted.pdf")
        try writePDF(pageCount: 1, to: plain)
        let document = try XCTUnwrap(PDFDocument(url: plain))
        XCTAssertTrue(document.write(
            to: encrypted,
            withOptions: [
                .ownerPasswordOption: "owner-secret",
                .userPasswordOption: "user-secret",
            ]
        ))

        XCTAssertThrowsError(try DocumentCaptureService.importFile(encrypted)) { error in
            guard let captureError = error as? DocumentCaptureError,
                  case .encryptedPDF = captureError else {
                return XCTFail("Expected encryptedPDF, got \(error)")
            }
        }
    }

    func testImportRejectsPDFAbovePageLimitBeforeOCR() throws {
        let root = try temporaryDirectory()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("too-many-pages.pdf")
        try writePDF(
            pageCount: DocumentCaptureService.maximumPageCount + 1,
            to: source
        )

        XCTAssertThrowsError(try DocumentCaptureService.importFile(source)) { error in
            guard let captureError = error as? DocumentCaptureError,
                  case .tooManyPages = captureError else {
                return XCTFail("Expected tooManyPages, got \(error)")
            }
        }
    }

    func testImageMetadataLimitsRejectDecompressionHeavyDimensions() throws {
        XCTAssertNoThrow(try DocumentCaptureService.validateImageDimensions(
            pixelWidth: 8_000,
            pixelHeight: 6_000
        ))
        XCTAssertThrowsError(try DocumentCaptureService.validateImageDimensions(
            pixelWidth: 20_000,
            pixelHeight: 20_000
        )) { error in
            guard let captureError = error as? DocumentCaptureError,
                  case .imageTooLarge = captureError else {
                return XCTFail("Expected imageTooLarge, got \(error)")
            }
        }
        XCTAssertThrowsError(try DocumentCaptureService.validateImageDimensions(
            pixelWidth: Int.max,
            pixelHeight: Int.max
        ))
    }

    func testPlainTextCaptureAndImportAreBounded() throws {
        let oversizedText = String(
            repeating: "a",
            count: DocumentCaptureService.maximumTextBytes + 1
        )
        XCTAssertThrowsError(try DocumentCaptureService.makeTextDocument(oversizedText)) { error in
            guard let captureError = error as? DocumentCaptureError,
                  case .textTooLarge = captureError else {
                return XCTFail("Expected textTooLarge, got \(error)")
            }
        }

        let root = try temporaryDirectory()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("large.txt")
        try Data(oversizedText.utf8).write(to: source)
        XCTAssertThrowsError(try DocumentCaptureService.importFile(source)) { error in
            guard let captureError = error as? DocumentCaptureError,
                  case .textTooLarge = captureError else {
                return XCTFail("Expected textTooLarge, got \(error)")
            }
        }
    }

    func testImportUsesImageMagicInsteadOfMisleadingExtension() throws {
        let root = try temporaryDirectory()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
            context.cgContext.setFillColor(UIColor.systemGreen.cgColor)
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        let source = root.appendingPathComponent("misleading.txt")
        try XCTUnwrap(image.pngData()).write(to: source)

        let asset = try DocumentCaptureService.importFile(source)
        defer { DocumentCaptureService.removeTemporaryAsset(asset) }

        XCTAssertEqual(asset.mediaType, "image/png")
        XCTAssertEqual((asset.filename as NSString).pathExtension, "png")
    }

    func testCancelledPDFRenderDoesNotReturnPartialAsset() async throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 1_000, height: 1_000)).image {
            context in
            context.cgContext.setFillColor(UIColor.systemPurple.cgColor)
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 1_000, height: 1_000))
        }
        let data = try XCTUnwrap(image.pngData())
        let task = Task {
            try await DocumentCaptureService.makePDF(
                from: Array(repeating: data, count: DocumentCaptureService.maximumPageCount)
            )
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testUnlinkRequestEncodesExplicitNull() throws {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(SourceDocumentLinkUpdateRequest(sourceDocumentId: nil))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertTrue(object["source_document_id"] is NSNull)

        let linkedData = try encoder.encode(
            SourceDocumentLinkUpdateRequest(sourceDocumentId: "document-1")
        )
        let linkedObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: linkedData) as? [String: Any]
        )
        XCTAssertEqual(linkedObject["source_document_id"] as? String, "document-1")
        XCTAssertEqual(Set(linkedObject.keys), Set(["source_document_id"]))
    }

    func testMetadataUpdateCanClearDateAndNotes() throws {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(
            DocumentMetadataUpdateRequest(
                title: "Child One passport",
                category: "identity",
                documentDate: nil,
                notes: nil,
                personIds: ["max"]
            )
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["title"] as? String, "Child One passport")
        XCTAssertEqual(object["category"] as? String, "identity")
        XCTAssertTrue(object["document_date"] is NSNull)
        XCTAssertTrue(object["notes"] is NSNull)
        XCTAssertEqual(object["person_ids"] as? [String], ["max"])
    }

    func testExistingRecordPickerDeduplicatesSeriesAndKeepsCompletedTasks() async {
        func event(id: String, title: String, start: String) -> CalendarEventDTO {
            CalendarEventDTO(
                id: id,
                title: title,
                description: nil,
                startTime: start,
                endTime: nil,
                allDay: true,
                recurrenceRule: nil,
                location: nil,
                familyMemberIds: nil,
                createdAt: "2026-07-18T08:00:00Z",
                updatedAt: "2026-07-18T08:00:00Z",
                createdBy: "dom",
                assignedTo: nil
            )
        }
        func task(id: String, completed: Bool = false, createdBy: String = "dom") -> TaskDTO {
            TaskDTO(
                id: id,
                title: id,
                description: nil,
                assignedTo: nil,
                dueDate: nil,
                completedAt: completed ? "2026-07-18T09:00:00Z" : nil,
                category: "other",
                recurrenceRule: nil,
                priority: 2,
                createdAt: "2026-07-18T08:00:00Z",
                updatedAt: "2026-07-18T08:00:00Z",
                createdBy: createdBy,
                actionableFrom: nil,
                assignees: []
            )
        }

        var firstOccurrence = event(
            id: "series-1::2026-07-20",
            title: "Swimming",
            start: "2026-07-20"
        )
        firstOccurrence.seriesId = "series-1"
        firstOccurrence.isGeneratedOccurrence = true
        var secondOccurrence = event(
            id: "series-1::2026-07-27",
            title: "Swimming",
            start: "2026-07-27"
        )
        secondOccurrence.seriesId = "series-1"
        secondOccurrence.isGeneratedOccurrence = true
        let eventFixtures = [firstOccurrence, secondOccurrence]
        let taskFixtures = [
            task(id: "ordinary-task"),
            task(id: "completed-task", completed: true),
            task(id: "managed-task", createdBy: "bin-scraper"),
        ]

        let viewModel = ExistingDocumentRecordPickerViewModel(
            documentId: "document-1",
            eventLoader: { eventFixtures },
            taskLoader: { taskFixtures },
            eventLinker: { _, _ in },
            taskLinker: { _, _ in }
        )

        await viewModel.load()

        let events = viewModel.filteredChoices(kind: .event, searchText: "")
        let tasks = viewModel.filteredChoices(kind: .task, searchText: "")
        XCTAssertEqual(events.map(\.recordId), ["series-1"])
        XCTAssertEqual(tasks.map(\.recordId), ["ordinary-task", "completed-task"])
        XCTAssertEqual(tasks.last?.subtitle, "Completed")
        XCTAssertEqual(
            viewModel.filteredChoices(kind: .event, searchText: "swim").map(\.recordId),
            ["series-1"]
        )
    }

    func testExistingRecordPickerLinksOnlySelectedRecordAndDocument() async {
        var eventLink: [String] = []
        var taskLink: [String] = []
        let viewModel = ExistingDocumentRecordPickerViewModel(
            documentId: "document-9",
            eventLoader: { [] },
            taskLoader: { [] },
            eventLinker: { recordId, documentId in
                eventLink = [recordId, documentId]
            },
            taskLinker: { recordId, documentId in
                taskLink = [recordId, documentId]
            }
        )
        let event = ExistingDocumentRecordChoice(
            kind: .event,
            recordId: "event-4",
            title: "Parents evening",
            subtitle: "20 Jul 2026",
            sourceDocumentId: nil
        )
        let task = ExistingDocumentRecordChoice(
            kind: .task,
            recordId: "task-5",
            title: "Return form",
            subtitle: "No due date",
            sourceDocumentId: nil
        )

        let eventAttached = await viewModel.attach(to: event)
        XCTAssertTrue(eventAttached)
        XCTAssertEqual(eventLink, ["event-4", "document-9"])
        XCTAssertTrue(taskLink.isEmpty)

        let taskAttached = await viewModel.attach(to: task)
        XCTAssertTrue(taskAttached)
        XCTAssertEqual(taskLink, ["task-5", "document-9"])
    }

    func testDocumentDecodesReverseLinkedEventsAndTasks() throws {
        let json = """
        {
          "id":"doc-1","title":"School letter","original_filename":"letter.pdf",
          "media_type":"application/pdf","file_size":123,"sha256":"abc","source":"file",
          "category":"school","status":"filed","document_date":null,"page_count":1,
          "extracted_text":null,"notes":null,"processor":"local","people":[],"suggestions":[],
          "pending_suggestion_count":0,"download_url":"/api/documents/doc-1/content",
          "created_at":"2026-07-18T08:00:00Z","updated_at":"2026-07-18T08:00:00Z","created_by":"dom",
          "linked_events":[{"id":"event-1","title":"Sports day","start_time":"2026-07-20","end_time":null,"all_day":true}],
          "linked_tasks":[{"id":"task-1","title":"Return form","due_date":"2026-07-19T17:00:00Z","completed_at":null}]
        }
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let document = try decoder.decode(DocumentDTO.self, from: Data(json.utf8))

        XCTAssertEqual(document.linkedEvents?.first?.title, "Sports day")
        XCTAssertEqual(document.linkedTasks?.first?.title, "Return form")
    }

    func testPreviewStoreProtectsAndRemovesPreview() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let preview = try DocumentPreviewStore.write(
            Data("private preview".utf8),
            filename: "letter.pdf",
            rootDirectory: root
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: preview.path))
        try assertCompleteProtection(at: preview)
        try assertCompleteProtection(at: preview.deletingLastPathComponent())

        DocumentPreviewStore.remove(preview, rootDirectory: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: preview.path))
    }

    func testCleanupValuesCannotDeleteProviderOwnedDirectories() throws {
        let providerRoot = try temporaryDirectory()
        let providerCaptureDirectory = providerRoot.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: providerCaptureDirectory,
            withIntermediateDirectories: true
        )
        let providerCapture = providerCaptureDirectory.appendingPathComponent("private.pdf")
        try Data("provider capture".utf8).write(to: providerCapture)
        let forgedAsset = CapturedDocumentAsset(
            fileURL: providerCapture,
            filename: "private.pdf",
            mediaType: "application/pdf",
            pageCount: 1,
            source: "provider"
        )

        DocumentCaptureService.removeTemporaryAsset(forgedAsset)
        XCTAssertTrue(FileManager.default.fileExists(atPath: providerCapture.path))

        let generationDirectory = providerRoot.appendingPathComponent(
            "generation-\(DocumentPreviewStore.generation)",
            isDirectory: true
        )
        let providerPreviewDirectory = generationDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: providerPreviewDirectory,
            withIntermediateDirectories: true
        )
        let providerPreview = providerPreviewDirectory.appendingPathComponent("private.pdf")
        try Data("provider preview".utf8).write(to: providerPreview)

        DocumentPreviewStore.remove(providerPreview, rootDirectory: providerRoot)
        XCTAssertTrue(FileManager.default.fileExists(atPath: providerPreview.path))
    }

    func testPreviewStorePurgesStaleFiles() throws {
        let root = try temporaryDirectory()
        let preview = try DocumentPreviewStore.write(
            Data("stale preview".utf8),
            filename: "letter.pdf",
            rootDirectory: root
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: preview.path))

        DocumentPreviewStore.purgeAll(rootDirectory: root)

        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testPreviewPurgeInvalidatesAnInFlightDownload() throws {
        let root = try temporaryDirectory()
        let generation = DocumentPreviewStore.generation

        DocumentPreviewStore.purgeAll(rootDirectory: root)

        XCTAssertThrowsError(
            try DocumentPreviewStore.write(
                Data("late preview".utf8),
                filename: "letter.pdf",
                expectedGeneration: generation,
                rootDirectory: root
            )
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testPreviewAdoptsStreamedFileInsideGenerationDirectory() throws {
        let root = try temporaryDirectory()
        let transferRoot = try temporaryDirectory()
        try FileManager.default.createDirectory(at: transferRoot, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: transferRoot)
        }
        let source = transferRoot.appendingPathComponent("download")
        let contents = Data("private streamed preview".utf8)
        try contents.write(to: source)
        let generation = DocumentPreviewStore.generation

        let preview = try DocumentPreviewStore.adoptDownloadedFile(
            source,
            filename: "../../letter.pdf",
            expectedByteCount: contents.count,
            expectedGeneration: generation,
            rootDirectory: root
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try Data(contentsOf: preview), contents)
        XCTAssertEqual(preview.lastPathComponent, "letter.pdf")
        XCTAssertTrue(preview.path.hasPrefix(root.standardizedFileURL.path + "/"))
        XCTAssertTrue(preview.path.contains("/generation-\(generation)/"))
        try assertCompleteProtection(at: preview)
        DocumentPreviewStore.remove(preview, rootDirectory: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: preview.path))
    }

    func testPreviewAdoptionRejectsMismatchedLengthWithoutMovingSource() throws {
        let root = try temporaryDirectory()
        let transferRoot = try temporaryDirectory()
        try FileManager.default.createDirectory(at: transferRoot, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: transferRoot)
        }
        let source = transferRoot.appendingPathComponent("download.pdf")
        try Data("preview".utf8).write(to: source)

        XCTAssertThrowsError(try DocumentPreviewStore.adoptDownloadedFile(
            source,
            filename: "letter.pdf",
            expectedByteCount: 999,
            expectedGeneration: DocumentPreviewStore.generation,
            rootDirectory: root
        )) { error in
            guard let captureError = error as? DocumentCaptureError,
                  case .unreadableFile = captureError else {
                return XCTFail("Expected unreadableFile, got \(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testPendingUploadUsesCompleteFileProtection() async throws {
        DocumentUploadService.shared.activate(identity: "test-family:test-user")
        defer { DocumentUploadService.shared.suspend() }
        let identityLease = try XCTUnwrap(DocumentUploadService.shared.currentIdentityLease)
        let schema = Schema([PendingDocumentUpload.self])
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        let asset = try DocumentCaptureService.makeTextDocument("Private nursery bill")
        defer { DocumentCaptureService.removeTemporaryAsset(asset) }

        let pending = try await DocumentUploadService.shared.enqueueWithoutBlockingUI(
            asset: asset,
            title: "Nursery bill",
            category: .finance,
            documentDate: nil,
            extractedText: "",
            notes: "",
            personIds: [],
            suggestions: [],
            useHermes: false,
            modelContext: context,
            expectedIdentityLease: identityLease
        )

        let fileURL = URL(fileURLWithPath: pending.filePath)
        try assertCompleteProtection(at: fileURL)
        try assertCompleteProtection(at: fileURL.deletingLastPathComponent())
        _ = try await DocumentUploadService.shared.discard(
            pending,
            modelContext: context,
            expectedIdentityLease: identityLease
        )
    }

    func testInterruptedUploadRecoversWithStableServerDocumentID() throws {
        DocumentUploadService.shared.activate(identity: "test-family:test-user")
        defer { DocumentUploadService.shared.suspend() }
        let identityLease = try XCTUnwrap(DocumentUploadService.shared.currentIdentityLease)
        let schema = Schema([PendingDocumentUpload.self])
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        let documentID = "e5913b80-071d-48aa-baa7-cee60771a217"
        let pending = PendingDocumentUpload(
            id: documentID,
            filePath: "/tmp/interrupted.pdf",
            filename: "letter.pdf",
            mediaType: "application/pdf",
            title: "Letter",
            source: "file",
            category: "school",
            status: .uploading
        )
        context.insert(pending)
        try context.save()

        try DocumentUploadService.shared.recoverInterruptedUploads(
            modelContext: context,
            expectedIdentityLease: identityLease
        )

        XCTAssertEqual(pending.status, .pending)
        XCTAssertEqual(pending.id, documentID)
        XCTAssertEqual(
            DocumentUploadService.shared.multipartFields(for: pending)["document_id"],
            documentID
        )
    }

    func testStaleIdentityLeaseCannotEnqueueCaptureForReplacementAccount() throws {
        let service = DocumentUploadService.shared
        service.activate(identity: "family-a:user-a")
        let accountALease = try XCTUnwrap(service.currentIdentityLease)
        service.suspend()
        service.activate(identity: "family-b:user-b")
        defer { service.suspend() }

        let schema = Schema([PendingDocumentUpload.self])
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        let asset = try DocumentCaptureService.makeTextDocument("Account A private letter")
        defer { DocumentCaptureService.removeTemporaryAsset(asset) }

        XCTAssertThrowsError(
            try service.enqueue(
                asset: asset,
                title: "Account A letter",
                category: .other,
                documentDate: nil,
                extractedText: "",
                notes: "",
                personIds: [],
                suggestions: [],
                useHermes: false,
                modelContext: context,
                expectedIdentityLease: accountALease
            )
        ) { error in
            guard let captureError = error as? DocumentCaptureError else {
                XCTFail("Expected DocumentCaptureError, got \(error)")
                return
            }
            guard case .accountUnavailable = captureError else {
                XCTFail("Expected accountUnavailable, got \(captureError)")
                return
            }
        }
        XCTAssertTrue(try context.fetch(FetchDescriptor<PendingDocumentUpload>()).isEmpty)
    }

    func testConcurrentFlushesJoinOneUpload() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = DocumentUploadProbe(delay: .milliseconds(100))
        let service = DocumentUploadService(
            uploadsRoot: root,
            uploadOperation: { _, _, _, _ in try await probe.perform() }
        )
        service.activate(identity: "family:user")
        defer { service.suspend() }
        let lease = try XCTUnwrap(service.currentIdentityLease)
        let context = try uploadContext()
        let pending = try await enqueueTestUpload(service: service,context: context,lease: lease)
        probe.response = documentDTO(id: pending.id)

        let first = Task { @MainActor in await service.flush(modelContext: context) }
        await Task.yield()
        let second = Task { @MainActor in await service.flush(modelContext: context) }
        await first.value
        await second.value

        XCTAssertEqual(probe.callCount(),1)
        XCTAssertTrue(try context.fetch(FetchDescriptor<PendingDocumentUpload>()).isEmpty)
    }

    func testEnqueuePersistenceFailureRemovesStagedFileAndInsertedRow() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let saves = DocumentSaveProbe()
        saves.failingSaveNumber = 1
        let service = DocumentUploadService(
            uploadsRoot: root,
            saveOperation: saves.save
        )
        service.activate(identity: "family:user")
        defer { service.suspend() }
        let lease = try XCTUnwrap(service.currentIdentityLease)
        let context = try uploadContext()

        do {
            _ = try await enqueueTestUpload(service: service, context: context, lease: lease)
            XCTFail("Expected queue persistence to fail")
        } catch {
            // The injected persistence error must surface to the caller.
        }

        XCTAssertTrue(try context.fetch(FetchDescriptor<PendingDocumentUpload>()).isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    func testServerSuccessAndReceiptSaveFailureKeepsFileForStableReplay() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = DocumentUploadProbe()
        let saves = DocumentSaveProbe()
        saves.failingSaveNumber = 3 // enqueue, uploading marker, then receipt
        let service = DocumentUploadService(
            uploadsRoot: root,
            uploadOperation: { _, _, _, _ in try await probe.perform() },
            saveOperation: saves.save
        )
        service.activate(identity: "family:user")
        defer { service.suspend() }
        let lease = try XCTUnwrap(service.currentIdentityLease)
        let context = try uploadContext()
        let pending = try await enqueueTestUpload(service: service,context: context,lease: lease)
        probe.response = documentDTO(id: pending.id)

        do {
            _ = try await service.upload(pending,modelContext: context,expectedIdentityLease: lease)
            XCTFail("Expected receipt persistence to fail")
        } catch {
            XCTAssertTrue(error is DocumentUploadService.QueueError)
        }

        XCTAssertEqual(probe.callCount(),1)
        XCTAssertNil(pending.acknowledgedDocumentJSON)
        XCTAssertEqual(pending.status, .pending)
        XCTAssertEqual(pending.failureKind, "ack_persistence")
        XCTAssertTrue(FileManager.default.fileExists(atPath: pending.filePath))
        XCTAssertEqual(
            service.multipartFields(for: pending)["document_id"],
            pending.id
        )
    }

    func testReceiptAndRollbackSaveFailuresSurfaceFailClosedQueueError() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = DocumentUploadProbe()
        let saves = DocumentSaveProbe()
        saves.failingSaveNumber = 3
        saves.additionalFailingSaveNumbers = [4]
        let service = DocumentUploadService(
            uploadsRoot: root,
            uploadOperation: { _, _, _, _ in try await probe.perform() },
            saveOperation: saves.save
        )
        service.activate(identity: "family:user")
        defer { service.suspend() }
        let lease = try XCTUnwrap(service.currentIdentityLease)
        let context = try uploadContext()
        let pending = try await enqueueTestUpload(
            service: service,
            context: context,
            lease: lease
        )
        probe.response = documentDTO(id: pending.id)

        do {
            _ = try await service.upload(
                pending,
                modelContext: context,
                expectedIdentityLease: lease
            )
            XCTFail("Expected both receipt-state saves to fail")
        } catch let error as DocumentUploadService.QueueError {
            guard case .queueStateCouldNotBeSaved = error else {
                return XCTFail("Expected queueStateCouldNotBeSaved, got \(error)")
            }
        }

        XCTAssertEqual(saves.saveCount, 4)
        XCTAssertEqual(pending.status, .pending)
        XCTAssertEqual(pending.failureKind, "ack_persistence")
        XCTAssertNil(pending.acknowledgedDocumentJSON)
        XCTAssertTrue(FileManager.default.fileExists(atPath: pending.filePath))
    }

    func testUploadFailureStateSaveFailureSurfacesAndKeepsReplaySource() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = DocumentUploadProbe()
        let saves = DocumentSaveProbe()
        saves.failingSaveNumber = 3 // enqueue, uploading marker, then failure state
        let service = DocumentUploadService(
            uploadsRoot: root,
            uploadOperation: { _, _, _, _ in try await probe.perform() },
            saveOperation: saves.save
        )
        service.activate(identity: "family:user")
        defer { service.suspend() }
        let lease = try XCTUnwrap(service.currentIdentityLease)
        let context = try uploadContext()
        let pending = try await enqueueTestUpload(
            service: service,
            context: context,
            lease: lease
        )

        do {
            _ = try await service.upload(
                pending,
                modelContext: context,
                expectedIdentityLease: lease
            )
            XCTFail("Expected failure-state persistence to fail")
        } catch {
            XCTAssertEqual(error as? DocumentPersistenceProbeError, .save)
        }

        XCTAssertEqual(saves.saveCount, 3)
        XCTAssertEqual(pending.status, .retryableFailure)
        XCTAssertTrue(FileManager.default.fileExists(atPath: pending.filePath))
    }

    func testUploadStorageInspectionFailurePreservesQueueStateAndStagedBytes() async throws {
        let root = try temporaryDirectory()
        let parent = root.deletingLastPathComponent()
        let preservedRoot = parent.appendingPathComponent(
            "DocumentUploadPreserved-\(UUID().uuidString)",
            isDirectory: true
        )
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: preservedRoot)
        }
        let service = DocumentUploadService(uploadsRoot: root)
        service.activate(identity: "family:user")
        defer { service.suspend() }
        let lease = try XCTUnwrap(service.currentIdentityLease)
        let context = try uploadContext()
        let pending = try await enqueueTestUpload(
            service: service,
            context: context,
            lease: lease
        )
        let preservedFile = preservedRoot
            .appendingPathComponent(pending.id, isDirectory: true)
            .appendingPathComponent(pending.filename)

        try FileManager.default.moveItem(at: root, to: preservedRoot)
        try Data("storage unavailable".utf8).write(to: root)

        do {
            _ = try await service.upload(
                pending,
                modelContext: context,
                expectedIdentityLease: lease
            )
            XCTFail("Expected protected storage inspection to fail")
        } catch {
            // The filesystem error must cross the queue boundary without
            // reclassifying the durable upload as a missing-file failure.
        }
        XCTAssertEqual(pending.status, .pending)
        XCTAssertNil(pending.failureKind)
        XCTAssertTrue(FileManager.default.fileExists(atPath: preservedFile.path))
    }

    func testInterruptedRecoveryFetchFailureSurfacesWithoutMutation() throws {
        let fetches = DocumentFetchProbe()
        let service = DocumentUploadService(fetchOperation: fetches.fetch)
        service.activate(identity: "family:user")
        defer { service.suspend() }
        let lease = try XCTUnwrap(service.currentIdentityLease)
        let context = try uploadContext()
        let pending = PendingDocumentUpload(
            id: UUID().uuidString,
            filePath: "/tmp/interrupted.pdf",
            filename: "letter.pdf",
            mediaType: "application/pdf",
            title: "Letter",
            source: "file",
            category: "school",
            status: .uploading
        )
        context.insert(pending)
        try context.save()

        XCTAssertThrowsError(try service.recoverInterruptedUploads(
            modelContext: context,
            expectedIdentityLease: lease
        )) { error in
            XCTAssertEqual(error as? DocumentPersistenceProbeError, .fetch)
        }
        XCTAssertEqual(fetches.fetchCount, 1)
        XCTAssertEqual(pending.status, .uploading)
    }

    func testInterruptedRecoverySaveFailureSurfaces() throws {
        let saves = DocumentSaveProbe()
        saves.failingSaveNumber = 1
        let service = DocumentUploadService(saveOperation: saves.save)
        service.activate(identity: "family:user")
        defer { service.suspend() }
        let lease = try XCTUnwrap(service.currentIdentityLease)
        let context = try uploadContext()
        let pending = PendingDocumentUpload(
            id: UUID().uuidString,
            filePath: "/tmp/interrupted.pdf",
            filename: "letter.pdf",
            mediaType: "application/pdf",
            title: "Letter",
            source: "file",
            category: "school",
            status: .uploading
        )
        context.insert(pending)
        try context.save()

        XCTAssertThrowsError(try service.recoverInterruptedUploads(
            modelContext: context,
            expectedIdentityLease: lease
        )) { error in
            XCTAssertEqual(error as? DocumentPersistenceProbeError, .save)
        }
        XCTAssertEqual(saves.saveCount, 1)
        XCTAssertEqual(pending.status, .pending)
    }

    func testCleanupFailureRetainsAcknowledgementAndNeverReuploads() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let uploadProbe = DocumentUploadProbe()
        let cleanupProbe = DocumentCleanupProbe()
        cleanupProbe.shouldFail = true
        let service = DocumentUploadService(
            uploadsRoot: root,
            uploadOperation: { _, _, _, _ in try await uploadProbe.perform() },
            removeDirectoryOperation: cleanupProbe.remove
        )
        service.activate(identity: "family:user")
        defer { service.suspend() }
        let lease = try XCTUnwrap(service.currentIdentityLease)
        let context = try uploadContext()
        let pending = try await enqueueTestUpload(service: service,context: context,lease: lease)
        uploadProbe.response = documentDTO(id: pending.id)

        _ = try await service.upload(pending,modelContext: context,expectedIdentityLease: lease)
        XCTAssertEqual(pending.status,.acknowledgedPendingCleanup)
        XCTAssertNotNil(pending.acknowledgedDocumentJSON)
        XCTAssertTrue(FileManager.default.fileExists(atPath: pending.filePath))

        cleanupProbe.shouldFail = false
        await service.flush(modelContext: context)

        XCTAssertEqual(uploadProbe.callCount(),1)
        XCTAssertTrue(try context.fetch(FetchDescriptor<PendingDocumentUpload>()).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pending.filePath))
    }

    func testCleanupFailureStateSaveFailureSurfacesWithDurableReceipt() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let uploadProbe = DocumentUploadProbe()
        let cleanupProbe = DocumentCleanupProbe()
        let saves = DocumentSaveProbe()
        cleanupProbe.shouldFail = true
        saves.failingSaveNumber = 4
        let service = DocumentUploadService(
            uploadsRoot: root,
            uploadOperation: { _, _, _, _ in try await uploadProbe.perform() },
            removeDirectoryOperation: cleanupProbe.remove,
            saveOperation: saves.save
        )
        service.activate(identity: "family:user")
        defer { service.suspend() }
        let lease = try XCTUnwrap(service.currentIdentityLease)
        let context = try uploadContext()
        let pending = try await enqueueTestUpload(
            service: service,
            context: context,
            lease: lease
        )
        uploadProbe.response = documentDTO(id: pending.id)

        do {
            _ = try await service.upload(
                pending,
                modelContext: context,
                expectedIdentityLease: lease
            )
            XCTFail("Expected cleanup-state persistence to fail")
        } catch {
            XCTAssertEqual(error as? DocumentPersistenceProbeError, .save)
        }

        XCTAssertEqual(saves.saveCount, 4)
        XCTAssertEqual(pending.status, .acknowledgedPendingCleanup)
        XCTAssertNotNil(pending.acknowledgedDocumentJSON)
        XCTAssertTrue(FileManager.default.fileExists(atPath: pending.filePath))
    }

    func testCompletedRowDeletionSaveFailureSurfacesForDurableRetry() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let uploadProbe = DocumentUploadProbe()
        let saves = DocumentSaveProbe()
        saves.failingSaveNumber = 5
        let service = DocumentUploadService(
            uploadsRoot: root,
            uploadOperation: { _, _, _, _ in try await uploadProbe.perform() },
            saveOperation: saves.save
        )
        service.activate(identity: "family:user")
        defer { service.suspend() }
        let lease = try XCTUnwrap(service.currentIdentityLease)
        let context = try uploadContext()
        let pending = try await enqueueTestUpload(
            service: service,
            context: context,
            lease: lease
        )
        let stagedFile = pending.filePath
        uploadProbe.response = documentDTO(id: pending.id)

        do {
            _ = try await service.upload(
                pending,
                modelContext: context,
                expectedIdentityLease: lease
            )
            XCTFail("Expected completed-row deletion persistence to fail")
        } catch {
            XCTAssertEqual(error as? DocumentPersistenceProbeError, .save)
        }

        XCTAssertEqual(saves.saveCount, 5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedFile))
    }

    func testAccountSwitchCancelsStagingWithoutPublishingQueueEntry() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let stageProbe = DocumentStageProbe()
        let service = DocumentUploadService(
            uploadsRoot: root,
            stageOperation: { sourceURL, filename, id, root in
                try await stageProbe.stage(
                    sourceURL: sourceURL,
                    filename: filename,
                    id: id,
                    root: root
                )
            }
        )
        service.activate(identity: "family-a:user-a")
        let lease = try XCTUnwrap(service.currentIdentityLease)
        let context = try uploadContext()
        let asset = try DocumentCaptureService.makeTextDocument("Account A letter")
        defer { DocumentCaptureService.removeTemporaryAsset(asset) }
        let staging = Task { @MainActor in
            _ = try await service.enqueueWithoutBlockingUI(
                asset: asset,
                title: "Account A",
                category: .other,
                documentDate: nil,
                extractedText: "",
                notes: "",
                personIds: [],
                suggestions: [],
                useHermes: false,
                modelContext: context,
                expectedIdentityLease: lease
            )
        }
        while !stageProbe.started { await Task.yield() }

        service.activate(identity: "family-b:user-b")
        do {
            _ = try await staging.value
            XCTFail("Expected staging cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError || error is DocumentCaptureError)
        }
        XCTAssertTrue(try context.fetch(FetchDescriptor<PendingDocumentUpload>()).isEmpty)
        service.suspend()
    }

    func testAccountSwitchCancelsUploadAndKeepsStablePendingFile() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = DocumentUploadProbe(delay: .seconds(10))
        let service = DocumentUploadService(
            uploadsRoot: root,
            uploadOperation: { _, _, _, _ in try await probe.perform() }
        )
        service.activate(identity: "family-a:user-a")
        let lease = try XCTUnwrap(service.currentIdentityLease)
        let context = try uploadContext()
        let pending = try await enqueueTestUpload(service: service,context: context,lease: lease)
        probe.response = documentDTO(id: pending.id)
        let upload = Task { @MainActor in
            try await service.upload(pending,modelContext: context,expectedIdentityLease: lease)
        }
        while probe.callCount() == 0 { await Task.yield() }

        service.activate(identity: "family-b:user-b")
        do {
            _ = try await upload.value
            XCTFail("Expected upload cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError || error is DocumentCaptureError)
        }

        XCTAssertEqual(pending.status,.pending)
        XCTAssertNil(pending.acknowledgedDocumentJSON)
        XCTAssertTrue(FileManager.default.fileExists(atPath: pending.filePath))
        service.suspend()
    }

    func testReconcileRemovesOnlyValidatedOrphanUploadDirectories() async throws {
        let root = try temporaryDirectory()
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        let old = now.addingTimeInterval(-7_200)
        let orphans = (0..<2).map { _ in
            root.appendingPathComponent(UUID().uuidString,isDirectory: true)
        }
        let fresh = root.appendingPathComponent(UUID().uuidString,isDirectory: true)
        let nearMiss = root.appendingPathComponent("manual-folder",isDirectory: true)
        let externalTarget = root.appendingPathComponent("provider-owned",isDirectory: true)
        let symbolicLink = root.appendingPathComponent(UUID().uuidString,isDirectory: true)
        for directory in orphans + [fresh,nearMiss,externalTarget] {
            try FileManager.default.createDirectory(at: directory,withIntermediateDirectories: true)
        }
        for orphan in orphans {
            try FileManager.default.setAttributes(
                [.modificationDate: old],ofItemAtPath: orphan.path
            )
        }
        try FileManager.default.createSymbolicLink(
            at: symbolicLink,withDestinationURL: externalTarget
        )
        let service = DocumentUploadService(
            uploadsRoot: root,
            now: { now },
            orphanMinimumAge: 3_600,
            orphanMaximumCandidates: 32,
            orphanMaximumRemovals: 1
        )
        service.activate(identity: "family:user")
        defer { service.suspend() }
        let lease = try XCTUnwrap(service.currentIdentityLease)

        try await service.reconcile(
            modelContext: try uploadContext(),
            expectedIdentityLease: lease
        )

        XCTAssertEqual(
            orphans.filter { FileManager.default.fileExists(atPath: $0.path) }.count,
            1
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: nearMiss.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: symbolicLink.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: externalTarget.path))

        try await service.reconcile(
            modelContext: try uploadContext(),
            expectedIdentityLease: lease
        )
        XCTAssertTrue(orphans.allSatisfy {
            !FileManager.default.fileExists(atPath: $0.path)
        })
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: symbolicLink.path))
    }

    func testRetiredSweepDeletesOnlyExactValidatedNames() throws {
        let parent = try temporaryDirectory()
        try FileManager.default.createDirectory(at: parent,withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let capture = parent.appendingPathComponent(
            "HausKlarCapture-retired-\(UUID().uuidString)",isDirectory: true
        )
        let preview = parent.appendingPathComponent(
            "HausKlarPreviews-retired-\(UUID().uuidString)",isDirectory: true
        )
        let nearMiss = parent.appendingPathComponent(
            "HausKlarCapture-retired-not-a-uuid",isDirectory: true
        )
        let externalTarget = parent.appendingPathComponent("provider-owned",isDirectory: true)
        let captureLink = parent.appendingPathComponent(
            "HausKlarCapture-retired-\(UUID().uuidString)",isDirectory: true
        )
        let previewLink = parent.appendingPathComponent(
            "HausKlarPreviews-retired-\(UUID().uuidString)",isDirectory: true
        )
        for directory in [capture,preview,nearMiss,externalTarget] {
            try FileManager.default.createDirectory(at: directory,withIntermediateDirectories: true)
        }
        try FileManager.default.createSymbolicLink(
            at: captureLink,withDestinationURL: externalTarget
        )
        try FileManager.default.createSymbolicLink(
            at: previewLink,withDestinationURL: externalTarget
        )

        DocumentCaptureService.sweepRetiredTemporaryCaptures(in: parent)
        DocumentPreviewStore.sweepRetiredPreviewDirectories(in: parent)

        XCTAssertFalse(FileManager.default.fileExists(atPath: capture.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: preview.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: nearMiss.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: captureLink.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: previewLink.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: externalTarget.path))
    }

    func testRetiredSweepsBoundDirectoryCandidates() throws {
        let parent = try temporaryDirectory()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let captures = (0..<3).map { _ in
            parent.appendingPathComponent(
                "HausKlarCapture-retired-\(UUID().uuidString)", isDirectory: true
            )
        }
        let previews = (0..<3).map { _ in
            parent.appendingPathComponent(
                "HausKlarPreviews-retired-\(UUID().uuidString)", isDirectory: true
            )
        }
        for directory in captures + previews {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        DocumentCaptureService.sweepRetiredTemporaryCaptures(
            in: parent,
            maximumCandidates: 2,
            maximumRemovals: 32
        )
        DocumentPreviewStore.sweepRetiredPreviewDirectories(
            in: parent,
            maximumCandidates: 2,
            maximumRemovals: 32
        )

        XCTAssertEqual(captures.filter { FileManager.default.fileExists(atPath: $0.path) }.count, 1)
        XCTAssertEqual(previews.filter { FileManager.default.fileExists(atPath: $0.path) }.count, 1)

        DocumentCaptureService.sweepRetiredTemporaryCaptures(
            in: parent,
            maximumCandidates: 2,
            maximumRemovals: 32
        )
        DocumentPreviewStore.sweepRetiredPreviewDirectories(
            in: parent,
            maximumCandidates: 2,
            maximumRemovals: 32
        )
        XCTAssertTrue(captures.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        XCTAssertTrue(previews.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }

    func testRetiredSweepCandidateBudgetIgnoresExactNamedSymlinks() throws {
        let parent = try temporaryDirectory()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let providerTarget = parent.appendingPathComponent("provider-owned", isDirectory: true)
        try FileManager.default.createDirectory(at: providerTarget, withIntermediateDirectories: true)
        let capture = parent.appendingPathComponent(
            "HausKlarCapture-retired-\(UUID().uuidString)",
            isDirectory: true
        )
        let preview = parent.appendingPathComponent(
            "HausKlarPreviews-retired-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: capture, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: preview, withIntermediateDirectories: true)
        var links: [URL] = []
        for _ in 0..<12 {
            let captureLink = parent.appendingPathComponent(
                "HausKlarCapture-retired-\(UUID().uuidString)",
                isDirectory: true
            )
            let previewLink = parent.appendingPathComponent(
                "HausKlarPreviews-retired-\(UUID().uuidString)",
                isDirectory: true
            )
            try FileManager.default.createSymbolicLink(at: captureLink, withDestinationURL: providerTarget)
            try FileManager.default.createSymbolicLink(at: previewLink, withDestinationURL: providerTarget)
            links.append(contentsOf: [captureLink, previewLink])
        }

        DocumentCaptureService.sweepRetiredTemporaryCaptures(
            in: parent,
            maximumCandidates: 1,
            maximumRemovals: 1
        )
        DocumentPreviewStore.sweepRetiredPreviewDirectories(
            in: parent,
            maximumCandidates: 1,
            maximumRemovals: 1
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: capture.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: preview.path))
        XCTAssertTrue(links.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        XCTAssertTrue(FileManager.default.fileExists(atPath: providerTarget.path))
    }
}
