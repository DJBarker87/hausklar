import CoreTransferable
import Foundation
import ImageIO
import os
import PDFKit
import UIKit
import UniformTypeIdentifiers
import Vision

private let documentCaptureLogger = Logger(
    subsystem: "org.example.hausklar",
    category: "DocumentCaptureService"
)

struct CapturedDocumentAsset: Identifiable, Sendable {
    let id: String
    let fileURL: URL
    let filename: String
    let mediaType: String
    let pageCount: Int
    let source: String
    /// A cleanup capability issued only when HausKlar created the enclosing
    /// staging directory. Plain value construction must never grant permission
    /// to recursively remove an arbitrary provider-owned directory.
    fileprivate let cleanupDirectoryURL: URL?

    init(
        id: String = UUID().uuidString,
        fileURL: URL,
        filename: String,
        mediaType: String,
        pageCount: Int,
        source: String
    ) {
        self.id = id
        self.fileURL = fileURL
        self.filename = filename
        self.mediaType = mediaType
        self.pageCount = pageCount
        self.source = source
        cleanupDirectoryURL = nil
    }

    fileprivate init(
        ownedFileURL fileURL: URL,
        filename: String,
        mediaType: String,
        pageCount: Int,
        source: String
    ) {
        id = UUID().uuidString
        self.fileURL = fileURL
        self.filename = filename
        self.mediaType = mediaType
        self.pageCount = pageCount
        self.source = source
        cleanupDirectoryURL = fileURL.deletingLastPathComponent().standardizedFileURL
    }
}

/// An import-only transfer that takes ownership of a protected copy while the
/// Photos provider URL is guaranteed to be readable. Provider URLs are
/// ephemeral and may be the user's original, so they must never escape this
/// closure or be removed by HausKlar. The lock serializes its one-time asset
/// handoff against deinit cleanup across provider callbacks.
final class StagedDocumentImageTransfer: Transferable, @unchecked Sendable {
    private let lock = NSLock()
    private var stagedAsset: CapturedDocumentAsset?

    private init(asset: CapturedDocumentAsset) {
        stagedAsset = asset
    }

    deinit {
        lock.lock()
        let asset = stagedAsset
        stagedAsset = nil
        lock.unlock()
        if let asset {
            DocumentCaptureService.removeTemporaryAsset(asset)
        }
    }

    /// Moves ownership to the caller. If a cancelled transfer never reaches
    /// this point, `deinit` removes the protected staging directory instead.
    func takeAsset() throws -> CapturedDocumentAsset {
        lock.lock()
        defer { lock.unlock() }
        guard let stagedAsset else { throw DocumentCaptureError.unreadableFile }
        self.stagedAsset = nil
        return stagedAsset
    }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            StagedDocumentImageTransfer(
                asset: try DocumentCaptureService.importTransferredImage(received.file)
            )
        }
    }
}

enum DocumentCaptureError: LocalizedError {
    case unsupportedFile
    case unreadableFile
    case noPages
    case fileTooLarge
    case tooManyPages
    case tooManySelectedPhotos
    case imageTooLarge
    case textTooLarge
    case encryptedPDF
    case accountUnavailable

    var errorDescription: String? {
        switch self {
        case .unsupportedFile: "Only PDF, image and text documents are supported."
        case .unreadableFile: "The document could not be read."
        case .noPages: "No pages were captured."
        case .fileTooLarge: "The document is larger than the 64 MB limit."
        case .tooManyPages: "A document can contain at most 60 pages."
        case .tooManySelectedPhotos: "Choose at most 20 photos at a time."
        case .imageTooLarge: "The image dimensions are too large to process safely."
        case .textTooLarge: "The text document is too large to process safely."
        case .encryptedPDF: "Password-protected PDF documents are not supported."
        case .accountUnavailable: "Please sign in again before saving this document."
        }
    }
}

enum DocumentCaptureService {
    static let maximumFileBytes = 64 * 1_024 * 1_024
    static let maximumPageCount = 60
    static let maximumPhotoSelectionCount = 20
    static let maximumTextBytes = 4 * 1_024 * 1_024
    static let maximumExtractedTextCharacters = 1_000_000
    static let maximumImagePixels: UInt64 = 50_000_000
    static let maximumImageDimension = 20_000
    static let allowedDocumentMediaTypes: Set<String> = [
        "application/pdf",
        "image/jpeg",
        "image/png",
        "image/heic",
        "image/heif",
        "image/tiff",
        "text/plain",
    ]

    private static let captureDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("HausKlarCapture", isDirectory: true)

    /// Page pixel bounds for images embedded in scan PDFs (~200 DPI on A4).
    private static let maxPDFPixelSize = CGSize(width: 1654, height: 2339)
    private static let pdfJPEGQuality: CGFloat = 0.8
    private static let maximumOCRPageCharacters = 100_000
    private static let maximumPDFPointDimension: CGFloat = 14_400

    private struct InspectedDocument {
        let mediaType: String
        let pageCount: Int
    }

    /// Vision requests support cancellation from another thread but have not
    /// adopted Swift's Sendable annotations. Keep the unchecked boundary tiny
    /// and never expose the request outside this OCR operation.
    private final class VisionTextRequestBox: @unchecked Sendable {
        let request = VNRecognizeTextRequest()
    }

    static func makePDF(from images: [UIImage], source: String) async throws -> CapturedDocumentAsset {
        guard !images.isEmpty else { throw DocumentCaptureError.noPages }
        guard images.count <= maximumPageCount else { throw DocumentCaptureError.tooManyPages }
        let task = Task.detached(priority: .userInitiated) {
            try renderPDF(pageCount: images.count, source: source) { index in
                try validatedDownsampledPage(images[index])
            }
        }
        let asset = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        return try validatedAfterCancellation(asset)
    }

    static func makePDF(from imageData: [Data], source: String = "photo") async throws -> CapturedDocumentAsset {
        guard !imageData.isEmpty else { throw DocumentCaptureError.noPages }
        guard imageData.count <= maximumPageCount else { throw DocumentCaptureError.tooManyPages }
        var totalBytes = 0
        for data in imageData {
            let (sum, overflow) = totalBytes.addingReportingOverflow(data.count)
            guard !overflow, sum <= maximumFileBytes else {
                throw DocumentCaptureError.fileTooLarge
            }
            totalBytes = sum
        }
        let task = Task.detached(priority: .userInitiated) {
            try renderPDF(pageCount: imageData.count, source: source) { index in
                try downsampledPage(from: imageData[index])
            }
        }
        let asset = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        return try validatedAfterCancellation(asset)
    }

    /// Builds a PDF from protected, file-backed image captures. Image magic and
    /// metadata are revalidated before rendering, source bytes are bounded in
    /// aggregate, and only one bounded decoded page exists at a time.
    static func makePDF(
        fromStagedImageAssets assets: [CapturedDocumentAsset],
        source: String = "photo"
    ) async throws -> CapturedDocumentAsset {
        guard !assets.isEmpty else { throw DocumentCaptureError.noPages }
        guard assets.count <= maximumPageCount else {
            throw DocumentCaptureError.tooManyPages
        }
        let task = Task.detached(priority: .userInitiated) {
            var aggregateBytes = 0
            for asset in assets {
                try Task.checkCancellation()
                let byteCount = try validatedStagedImageByteCount(asset)
                let (newCount, overflow) = aggregateBytes.addingReportingOverflow(byteCount)
                guard !overflow, newCount <= maximumFileBytes else {
                    throw DocumentCaptureError.fileTooLarge
                }
                aggregateBytes = newCount
            }
            return try renderPDF(pageCount: assets.count, source: source) { index in
                try downsampledPage(at: assets[index].fileURL)
            }
        }
        let asset = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        return try validatedAfterCancellation(asset)
    }

    /// Stores a single library photo as the original image rather than flattening it
    /// into OCR text or wrapping it in a PDF. Unsupported image encodings are
    /// converted to JPEG because the document API deliberately accepts a small,
    /// auditable media allowlist.
    static func makeImageDocument(from data: Data) throws -> CapturedDocumentAsset {
        guard data.count <= maximumFileBytes else { throw DocumentCaptureError.fileTooLarge }
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(imageSource) > 0 else {
            throw DocumentCaptureError.unreadableFile
        }
        guard CGImageSourceGetCount(imageSource) <= maximumPageCount else {
            throw DocumentCaptureError.tooManyPages
        }
        try validateImageMetadata(in: imageSource)

        let detectedType = CGImageSourceGetType(imageSource)
            .flatMap { UTType($0 as String) }
        let allowedTypes: [UTType] = [.jpeg, .png, .heic, .heif, .tiff]
        let storedType: UTType
        let storedData: Data
        if let detectedType, allowedTypes.contains(detectedType) {
            storedType = detectedType
            storedData = data
        } else if let detectedType, detectedType.conforms(to: .image),
                  let thumbnail = safeThumbnail(from: imageSource, maximumPixelSize: 4_096),
                  let jpeg = UIImage(cgImage: thumbnail).jpegData(compressionQuality: 0.9) {
            storedType = .jpeg
            storedData = jpeg
        } else {
            throw DocumentCaptureError.unreadableFile
        }

        let filename = "Photo-\(timestamp()).\(storedType.preferredFilenameExtension ?? "jpg")"
        let url = try uniqueTemporaryURL(filename: filename)
        var shouldKeepFile = false
        defer {
            if !shouldKeepFile {
                removeTemporaryDirectoryBestEffort(
                    url.deletingLastPathComponent(),
                    reason: "image capture rollback"
                )
            }
        }
        try storedData.write(to: url, options: [.atomic, .completeFileProtection])
        try LocalFileProtection.protectItem(at: url)
        shouldKeepFile = true
        return CapturedDocumentAsset(
            ownedFileURL: url,
            filename: filename,
            mediaType: storedType.preferredMIMEType ?? "image/jpeg",
            pageCount: 1,
            source: "photo"
        )
    }

    static func makeImageDocumentWithoutBlockingUI(from data: Data) async throws -> CapturedDocumentAsset {
        try Task.checkCancellation()
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try makeImageDocument(from: data)
        }
        let asset = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        return try validatedAfterCancellation(asset)
    }

    private static func renderPDF(
        pageCount: Int,
        source: String,
        pageProvider: (Int) throws -> UIImage
    ) throws -> CapturedDocumentAsset {
        guard pageCount > 0 else { throw DocumentCaptureError.noPages }
        guard pageCount <= maximumPageCount else { throw DocumentCaptureError.tooManyPages }
        try Task.checkCancellation()
        let filename = "Scan-\(timestamp()).pdf"
        let url = try uniqueTemporaryURL(filename: filename)
        var shouldKeepFile = false
        defer {
            if !shouldKeepFile {
                removeTemporaryDirectoryBestEffort(
                    url.deletingLastPathComponent(),
                    reason: "PDF render rollback"
                )
            }
        }
        let pageBounds = CGRect(x: 0, y: 0, width: 595, height: 842)
        let renderer = UIGraphicsPDFRenderer(bounds: pageBounds)
        var renderingError: Error?
        try renderer.writePDF(to: url) { context in
            for index in 0..<pageCount {
                guard renderingError == nil else { break }
                if Task.isCancelled {
                    renderingError = CancellationError()
                    break
                }
                autoreleasepool {
                    do {
                        let image = try pageProvider(index)
                        guard image.size.width > 0, image.size.height > 0 else {
                            throw DocumentCaptureError.unreadableFile
                        }
                        context.beginPage()
                        let inset = pageBounds.insetBy(dx: 18, dy: 18)
                        let scale = min(inset.width / image.size.width, inset.height / image.size.height)
                        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                        let rect = CGRect(
                            x: pageBounds.midX - size.width / 2,
                            y: pageBounds.midY - size.height / 2,
                            width: size.width,
                            height: size.height
                        )
                        image.draw(in: rect)
                    } catch {
                        renderingError = error
                    }
                }
            }
        }
        if let renderingError { throw renderingError }
        try Task.checkCancellation()
        let fileSize = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard fileSize <= maximumFileBytes else { throw DocumentCaptureError.fileTooLarge }
        try LocalFileProtection.protectItem(at: url)
        shouldKeepFile = true
        return CapturedDocumentAsset(
            ownedFileURL: url,
            filename: filename,
            mediaType: "application/pdf",
            pageCount: pageCount,
            source: source
        )
    }

    /// Downsamples a scanned page to document resolution and re-wraps it as JPEG
    /// so the PDF embeds compressed data instead of a full-resolution bitmap.
    private static func validatedDownsampledPage(_ image: UIImage) throws -> UIImage {
        let pixelSize = CGSize(
            width: image.size.width * image.scale,
            height: image.size.height * image.scale
        )
        guard pixelSize.width.isFinite, pixelSize.height.isFinite,
              pixelSize.width > 0, pixelSize.height > 0,
              pixelSize.width <= CGFloat(Int.max), pixelSize.height <= CGFloat(Int.max) else {
            throw DocumentCaptureError.imageTooLarge
        }
        try validateImageDimensions(
            pixelWidth: Int(pixelSize.width.rounded(.up)),
            pixelHeight: Int(pixelSize.height.rounded(.up))
        )
        let scale = pageScale(for: pixelSize)
        var page = image
        if scale < 1 {
            let target = CGSize(
                width: (pixelSize.width * scale).rounded(),
                height: (pixelSize.height * scale).rounded()
            )
            page = image.preparingThumbnail(of: target) ?? image
        }
        return jpegBacked(page)
    }

    private static func downsampledPage(from data: Data) throws -> UIImage {
        guard data.count <= maximumFileBytes else { throw DocumentCaptureError.fileTooLarge }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw DocumentCaptureError.unreadableFile
        }
        try validateImageMetadata(in: source)
        guard let thumbnail = safeThumbnail(
            from: source,
            maximumPixelSize: Int(max(maxPDFPixelSize.width, maxPDFPixelSize.height))
        ) else {
            throw DocumentCaptureError.unreadableFile
        }
        return jpegBacked(UIImage(cgImage: thumbnail))
    }

    private static func downsampledPage(at url: URL) throws -> UIImage {
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithURL(
            url as CFURL,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ) else {
            throw DocumentCaptureError.unreadableFile
        }
        try validateImageMetadata(in: source)
        guard let thumbnail = safeThumbnail(
            from: source,
            maximumPixelSize: Int(max(maxPDFPixelSize.width, maxPDFPixelSize.height))
        ) else {
            throw DocumentCaptureError.unreadableFile
        }
        try Task.checkCancellation()
        return jpegBacked(UIImage(cgImage: thumbnail))
    }

    private static func pageScale(for pixelSize: CGSize) -> CGFloat {
        let longEdge = max(pixelSize.width, pixelSize.height)
        let shortEdge = min(pixelSize.width, pixelSize.height)
        guard longEdge > 0, shortEdge > 0 else { return 1 }
        return min(
            1,
            max(maxPDFPixelSize.width, maxPDFPixelSize.height) / longEdge,
            min(maxPDFPixelSize.width, maxPDFPixelSize.height) / shortEdge
        )
    }

    private static func jpegBacked(_ image: UIImage) -> UIImage {
        guard let data = image.jpegData(compressionQuality: pdfJPEGQuality),
              let compressed = UIImage(data: data) else { return image }
        return compressed
    }

    static func importFile(_ sourceURL: URL) throws -> CapturedDocumentAsset {
        try importOwnedFile(sourceURL, requiredImage: false, source: "file")
    }

    /// Copies and validates an image while a transfer provider still owns its
    /// source URL. The provider file is read-only from HausKlar's perspective;
    /// only the uniquely-owned destination is ever returned or removed.
    static func importTransferredImage(
        _ sourceURL: URL,
        destinationRoot: URL? = nil,
        fileManager: FileManager = .default,
        copyChunkSize: Int = 1_024 * 1_024,
        onChunkCopied: (@Sendable (Int) -> Void)? = nil
    ) throws -> CapturedDocumentAsset {
        try importOwnedFile(
            sourceURL,
            requiredImage: true,
            source: "photo",
            destinationRoot: destinationRoot,
            fileManager: fileManager,
            copyChunkSize: copyChunkSize,
            onChunkCopied: onChunkCopied
        )
    }

    static func validatedStagedImageByteCount(_ asset: CapturedDocumentAsset) throws -> Int {
        let normalizedMediaType = asset.mediaType.lowercased()
        guard normalizedMediaType.hasPrefix("image/"),
              allowedDocumentMediaTypes.contains(normalizedMediaType) else {
            throw DocumentCaptureError.unsupportedFile
        }
        let inspection = try inspectFile(
            at: asset.fileURL,
            declaredType: UTType(mimeType: normalizedMediaType)
        )
        guard inspection.mediaType == normalizedMediaType,
              inspection.pageCount == 1 else {
            throw DocumentCaptureError.unreadableFile
        }
        let values = try asset.fileURL.resourceValues(forKeys: [
            .fileSizeKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let byteCount = values.fileSize,
              byteCount > 0,
              byteCount <= maximumFileBytes else {
            throw DocumentCaptureError.unreadableFile
        }
        return byteCount
    }

    static func validatedStagedImageByteCountWithoutBlockingUI(
        _ asset: CapturedDocumentAsset
    ) async throws -> Int {
        let task = Task.detached(priority: .userInitiated) {
            try validatedStagedImageByteCount(asset)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private static func importOwnedFile(
        _ sourceURL: URL,
        requiredImage: Bool,
        source: String,
        destinationRoot: URL? = nil,
        fileManager: FileManager = .default,
        copyChunkSize: Int = 1_024 * 1_024,
        onChunkCopied: (@Sendable (Int) -> Void)? = nil
    ) throws -> CapturedDocumentAsset {
        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer { if accessed { sourceURL.stopAccessingSecurityScopedResource() } }

        try Task.checkCancellation()
        let resourceValues = try sourceURL.resourceValues(forKeys: [
            .contentTypeKey,
            .fileSizeKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .nameKey,
        ])
        guard resourceValues.isRegularFile == true,
              resourceValues.isSymbolicLink != true,
              let declaredSize = resourceValues.fileSize,
              declaredSize >= 0 else {
            throw DocumentCaptureError.unreadableFile
        }
        guard declaredSize <= maximumFileBytes else { throw DocumentCaptureError.fileTooLarge }
        let sourceInspection = try inspectFile(
            at: sourceURL,
            declaredType: resourceValues.contentType
        )
        if requiredImage, !sourceInspection.mediaType.hasPrefix("image/") {
            throw DocumentCaptureError.unsupportedFile
        }
        let filename = sanitizedFilename(
            resourceValues.name ?? sourceURL.lastPathComponent,
            mediaType: sourceInspection.mediaType
        )
        let destination = try uniqueTemporaryURL(
            filename: filename,
            root: destinationRoot ?? captureDirectory,
            fileManager: fileManager
        )
        var shouldKeepFile = false
        defer {
            if !shouldKeepFile {
                removeTemporaryDirectoryBestEffort(
                    destination.deletingLastPathComponent(),
                    fileManager: fileManager,
                    reason: "file import rollback"
                )
            }
        }
        try copyValidatedFile(
            from: sourceURL,
            to: destination,
            expectedBytes: declaredSize,
            fileManager: fileManager,
            copyChunkSize: copyChunkSize,
            onChunkCopied: onChunkCopied
        )
        try LocalFileProtection.protectItem(at: destination, fileManager: fileManager)
        let copiedSize = try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard copiedSize == declaredSize else { throw DocumentCaptureError.unreadableFile }
        let destinationInspection = try inspectFile(at: destination, declaredType: nil)
        guard destinationInspection.mediaType == sourceInspection.mediaType,
              destinationInspection.pageCount == sourceInspection.pageCount else {
            throw DocumentCaptureError.unreadableFile
        }
        try Task.checkCancellation()
        shouldKeepFile = true
        return CapturedDocumentAsset(
            ownedFileURL: destination,
            filename: filename,
            mediaType: destinationInspection.mediaType,
            pageCount: destinationInspection.pageCount,
            source: source
        )
    }

    static func importFileWithoutBlockingUI(_ sourceURL: URL) async throws -> CapturedDocumentAsset {
        try Task.checkCancellation()
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try importFile(sourceURL)
        }
        let asset = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        return try validatedAfterCancellation(asset)
    }

    static func makeTextDocument(_ text: String) throws -> CapturedDocumentAsset {
        guard text.utf8.count <= maximumTextBytes else {
            throw DocumentCaptureError.textTooLarge
        }
        let filename = "Pasted-\(timestamp()).txt"
        let url = try uniqueTemporaryURL(filename: filename)
        var shouldKeepFile = false
        defer {
            if !shouldKeepFile {
                removeTemporaryDirectoryBestEffort(
                    url.deletingLastPathComponent(),
                    reason: "text capture rollback"
                )
            }
        }
        guard let data = text.data(using: .utf8) else {
            throw DocumentCaptureError.unreadableFile
        }
        guard data.count <= maximumTextBytes else { throw DocumentCaptureError.textTooLarge }
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        try LocalFileProtection.protectItem(at: url)
        shouldKeepFile = true
        return CapturedDocumentAsset(
            ownedFileURL: url,
            filename: filename,
            mediaType: "text/plain",
            pageCount: 1,
            source: "text"
        )
    }

    static func extractText(from asset: CapturedDocumentAsset) async throws -> String {
        let fileURL = asset.fileURL
        let mediaType = asset.mediaType
        let task = Task.detached(priority: .userInitiated) {
            try await extractText(at: fileURL, mediaType: mediaType)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private static func extractText(at fileURL: URL, mediaType: String) async throws -> String {
        try Task.checkCancellation()
        let declaredType = UTType(mimeType: mediaType)
        let inspection = try inspectFile(at: fileURL, declaredType: declaredType)
        guard inspection.mediaType == mediaType.lowercased() else {
            throw DocumentCaptureError.unreadableFile
        }
        switch inspection.mediaType {
        case "text/plain":
            return try readBoundedText(at: fileURL)
        case "application/pdf":
            guard let document = PDFDocument(url: fileURL) else {
                throw DocumentCaptureError.unreadableFile
            }
            return try await extractText(from: document)
        default:
            guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else {
                throw DocumentCaptureError.unreadableFile
            }
            try validateImageMetadata(in: source)
            guard let cgImage = safeThumbnail(from: source, maximumPixelSize: 2_400) else {
                throw DocumentCaptureError.unreadableFile
            }
            let text = try await recognizeText(in: cgImage)
            return String(text.prefix(maximumExtractedTextCharacters))
        }
    }

    static func inferredTitle(from text: String, fallback: String) -> String {
        let candidate = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { line in
                line.count >= 4 && line.count <= 100 && line.rangeOfCharacter(from: .letters) != nil
            }
        return candidate ?? (fallback as NSString).deletingPathExtension
    }

    static func suggestions(
        from text: String,
        assignedTo: String?
    ) -> [CaptureSuggestionDraft] {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        let dateMatches = detector?.matches(in: text, options: [], range: fullRange) ?? []
        let calendar = Calendar.current
        let cutoff = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: Date())) ?? Date()
        var drafts: [CaptureSuggestionDraft] = []
        var seen: Set<String> = []

        for match in dateMatches.prefix(20) {
            guard let date = match.date, date >= cutoff else { continue }
            let sourceText = nsText.substring(with: nsText.lineRange(for: match.range))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let matchedDate = nsText.substring(with: match.range)
            var title = sourceText.replacingOccurrences(of: matchedDate, with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: " -–—:,."))
            if title.count < 4 {
                title = precedingMeaningfulLine(in: nsText, before: match.range.location) ?? "Calendar event"
            }
            title = String(title.prefix(120))
            let key = "\(title.lowercased())|\(calendar.startOfDay(for: date))"
            guard seen.insert(key).inserted else { continue }

            let lowerMatch = matchedDate.lowercased()
            let hasTime = lowerMatch.contains(":")
                || lowerMatch.contains("am")
                || lowerMatch.contains("pm")
            drafts.append(
                CaptureSuggestionDraft(
                    kind: .event,
                    title: sentenceCase(title),
                    startTime: hasTime
                        ? ISODateParser.stringNoFractional(from: date)
                        : ISODateParser.dateOnly(from: date),
                    allDay: !hasTime,
                    assignedTo: assignedTo,
                    confidence: 0.72,
                    sourceText: String(sourceText.prefix(500))
                )
            )
        }

        let taskWords = ["please", "bring", "return", "complete", "deadline", "due", "remember", "must"]
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = line.lowercased()
            guard line.count >= 5,
                  line.count <= 240,
                  taskWords.contains(where: lower.contains) else { continue }
            var title = line
                .replacingOccurrences(of: "Please ", with: "", options: [.caseInsensitive, .anchored])
                .trimmingCharacters(in: CharacterSet(charactersIn: " -–—•.,"))
            title = String(title.prefix(140))
            let key = "task|\(title.lowercased())"
            guard seen.insert(key).inserted else { continue }
            let lineRange = nsText.range(of: rawLine)
            let nearbyDate = dateMatches.first { match in
                NSIntersectionRange(match.range, lineRange).length > 0
            }?.date
            drafts.append(
                CaptureSuggestionDraft(
                    kind: .task,
                    title: sentenceCase(title),
                    dueDate: nearbyDate.map(ISODateParser.stringNoFractional),
                    assignedTo: assignedTo,
                    confidence: 0.58,
                    sourceText: String(line.prefix(500))
                )
            )
        }
        return Array(drafts.prefix(30))
    }

    private static func extractText(from document: PDFDocument) async throws -> String {
        guard document.pageCount > 0 else { throw DocumentCaptureError.noPages }
        guard document.pageCount <= maximumPageCount else {
            throw DocumentCaptureError.tooManyPages
        }
        var output = ""
        var remainingCharacters = maximumExtractedTextCharacters
        for index in 0..<document.pageCount where remainingCharacters > 0 {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else {
                throw DocumentCaptureError.unreadableFile
            }
            let embedded = page.string.map {
                String($0.prefix(maximumOCRPageCharacters))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } ?? ""
            let pageText: String
            if embedded.count >= 20 {
                pageText = embedded
            } else {
                let cgImage: CGImage? = autoreleasepool {
                    page.thumbnail(
                        of: CGSize(width: 1_800, height: 2_400),
                        for: .mediaBox
                    ).cgImage
                }
                guard let cgImage else { continue }
                pageText = try await recognizeText(in: cgImage)
            }
            let bounded = String(pageText.prefix(min(
                maximumOCRPageCharacters,
                remainingCharacters
            )))
            guard !bounded.isEmpty else { continue }
            let separator = output.isEmpty ? "" : "\n\n"
            guard remainingCharacters > separator.count else { break }
            output.append(separator)
            remainingCharacters -= separator.count
            let finalSegment = String(bounded.prefix(remainingCharacters))
            output.append(finalSegment)
            remainingCharacters -= finalSegment.count
        }
        try Task.checkCancellation()
        return output
    }

    private static func recognizeText(in image: CGImage) async throws -> String {
        try Task.checkCancellation()
        let requestBox = VisionTextRequestBox()
        let request = requestBox.request
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["en-GB", "en-US"]
        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        try VNImageRequestHandler(cgImage: image).perform([requestBox.request])
                        var output = ""
                        var remaining = maximumOCRPageCharacters
                        for observation in requestBox.request.results ?? [] where remaining > 0 {
                            guard let line = observation.topCandidates(1).first?.string else {
                                continue
                            }
                            let separator = output.isEmpty ? "" : "\n"
                            guard remaining > separator.count else { break }
                            output.append(separator)
                            remaining -= separator.count
                            let bounded = String(line.prefix(remaining))
                            output.append(bounded)
                            remaining -= bounded.count
                        }
                        continuation.resume(returning: output)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            requestBox.request.cancel()
        }
        try Task.checkCancellation()
        return result
    }

    private static func inspectFile(
        at url: URL,
        declaredType: UTType?
    ) throws -> InspectedDocument {
        try Task.checkCancellation()
        let values = try url.resourceValues(forKeys: [
            .fileSizeKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let fileSize = values.fileSize,
              fileSize >= 0 else {
            throw DocumentCaptureError.unreadableFile
        }
        guard fileSize <= maximumFileBytes else { throw DocumentCaptureError.fileTooLarge }

        let prefix = try readPrefix(at: url, maximumBytes: min(fileSize, 1_024))
        if prefix.range(of: Data("%PDF-".utf8)) != nil {
            return try inspectPDF(at: url)
        }

        if let source = CGImageSourceCreateWithURL(url as CFURL, [
            kCGImageSourceShouldCache: false,
        ] as CFDictionary),
           CGImageSourceGetCount(source) > 0,
           let typeIdentifier = CGImageSourceGetType(source),
           let type = UTType(typeIdentifier as String),
           type.conforms(to: .image) {
            let allowedTypes: [UTType] = [.jpeg, .png, .heic, .heif, .tiff]
            guard allowedTypes.contains(type) else { throw DocumentCaptureError.unsupportedFile }
            guard CGImageSourceGetCount(source) <= maximumPageCount else {
                throw DocumentCaptureError.tooManyPages
            }
            try validateImageMetadata(in: source)
            guard let mediaType = type.preferredMIMEType?.lowercased(),
                  allowedDocumentMediaTypes.contains(mediaType) else {
                throw DocumentCaptureError.unsupportedFile
            }
            return InspectedDocument(mediaType: mediaType, pageCount: 1)
        }

        if declaredType?.conforms(to: .pdf) == true
            || declaredType?.conforms(to: .image) == true {
            throw DocumentCaptureError.unreadableFile
        }
        _ = try readBoundedText(at: url)
        return InspectedDocument(mediaType: "text/plain", pageCount: 1)
    }

    private static func inspectPDF(at url: URL) throws -> InspectedDocument {
        guard let document = PDFDocument(url: url) else {
            throw DocumentCaptureError.unreadableFile
        }
        guard !document.isEncrypted, !document.isLocked else {
            throw DocumentCaptureError.encryptedPDF
        }
        guard document.pageCount > 0 else { throw DocumentCaptureError.noPages }
        guard document.pageCount <= maximumPageCount else {
            throw DocumentCaptureError.tooManyPages
        }
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else {
                throw DocumentCaptureError.unreadableFile
            }
            let bounds = page.bounds(for: .mediaBox)
            guard bounds.width.isFinite, bounds.height.isFinite,
                  bounds.width > 0, bounds.height > 0,
                  bounds.width <= maximumPDFPointDimension,
                  bounds.height <= maximumPDFPointDimension else {
                throw DocumentCaptureError.unreadableFile
            }
        }
        return InspectedDocument(mediaType: "application/pdf", pageCount: document.pageCount)
    }

    private static func validateImageMetadata(in source: CGImageSource) throws {
        guard CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(
                source,
                0,
                [kCGImageSourceShouldCache: false] as CFDictionary
              ) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else {
            throw DocumentCaptureError.unreadableFile
        }
        try validateImageDimensions(pixelWidth: width, pixelHeight: height)
    }

    static func validateImageDimensions(pixelWidth: Int, pixelHeight: Int) throws {
        guard pixelWidth > 0, pixelHeight > 0,
              pixelWidth <= maximumImageDimension,
              pixelHeight <= maximumImageDimension else {
            throw DocumentCaptureError.imageTooLarge
        }
        let width = UInt64(pixelWidth)
        let height = UInt64(pixelHeight)
        guard width <= maximumImagePixels / height else {
            throw DocumentCaptureError.imageTooLarge
        }
    }

    static func validateStoredFile(at url: URL, expectedMediaType: String) throws {
        let normalizedMediaType = expectedMediaType
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        guard allowedDocumentMediaTypes.contains(normalizedMediaType) else {
            throw DocumentCaptureError.unsupportedFile
        }
        let inspection = try inspectFile(
            at: url,
            declaredType: UTType(mimeType: normalizedMediaType)
        )
        guard inspection.mediaType == normalizedMediaType else {
            throw DocumentCaptureError.unreadableFile
        }
    }

    private static func safeThumbnail(
        from source: CGImageSource,
        maximumPixelSize: Int
    ) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func readBoundedText(at url: URL) throws -> String {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard let fileSize = values.fileSize, fileSize >= 0 else {
            throw DocumentCaptureError.unreadableFile
        }
        guard fileSize <= maximumTextBytes else { throw DocumentCaptureError.textTooLarge }
        let data = try readPrefix(at: url, maximumBytes: maximumTextBytes + 1)
        guard data.count <= maximumTextBytes,
              !data.contains(0),
              let text = String(data: data, encoding: .utf8) else {
            throw DocumentCaptureError.unreadableFile
        }
        return String(text.prefix(maximumExtractedTextCharacters))
    }

    private static func readPrefix(at url: URL, maximumBytes: Int) throws -> Data {
        try Task.checkCancellation()
        let handle = try FileHandle(forReadingFrom: url)
        defer { closeFileHandleBestEffort(handle, purpose: "bounded text read") }
        let data = try handle.read(upToCount: max(0, maximumBytes)) ?? Data()
        try Task.checkCancellation()
        return data
    }

    private static func copyValidatedFile(
        from source: URL,
        to destination: URL,
        expectedBytes: Int,
        fileManager: FileManager = .default,
        copyChunkSize: Int = 1_024 * 1_024,
        onChunkCopied: (@Sendable (Int) -> Void)? = nil
    ) throws {
        guard fileManager.createFile(
            atPath: destination.path,
            contents: nil,
            attributes: [.protectionKey: LocalFileProtection.sensitive]
        ) else {
            throw DocumentCaptureError.unreadableFile
        }
        let input = try FileHandle(forReadingFrom: source)
        let output = try FileHandle(forWritingTo: destination)
        defer {
            closeFileHandleBestEffort(input, purpose: "document import input")
            closeFileHandleBestEffort(output, purpose: "document import output")
        }
        var copiedBytes = 0
        while true {
            try Task.checkCancellation()
            let chunk = try input.read(upToCount: max(1, copyChunkSize)) ?? Data()
            guard !chunk.isEmpty else { break }
            let (newCount, overflow) = copiedBytes.addingReportingOverflow(chunk.count)
            guard !overflow, newCount <= maximumFileBytes else {
                throw DocumentCaptureError.fileTooLarge
            }
            try output.write(contentsOf: chunk)
            copiedBytes = newCount
            onChunkCopied?(copiedBytes)
        }
        try output.synchronize()
        guard copiedBytes == expectedBytes else { throw DocumentCaptureError.unreadableFile }
    }

    private static func sanitizedFilename(_ filename: String, mediaType: String) -> String {
        let invalid = CharacterSet.controlCharacters
            .union(.newlines)
            .union(CharacterSet(charactersIn: "/\\:"))
        var candidate = (filename as NSString).lastPathComponent
        if candidate.isEmpty || candidate == "." || candidate == ".."
            || candidate.hasPrefix(".") || candidate.utf8.count > 180
            || candidate.rangeOfCharacter(from: invalid) != nil {
            candidate = "document"
        }
        guard let expectedType = UTType(mimeType: mediaType),
              let preferredExtension = expectedType.preferredFilenameExtension else {
            return candidate
        }
        let candidateExtension = (candidate as NSString).pathExtension
        if let candidateType = UTType(filenameExtension: candidateExtension),
           candidateType.conforms(to: expectedType) {
            return candidate
        }
        let base = (candidate as NSString).deletingPathExtension
        let safeBase = base.isEmpty ? "document" : String(base.prefix(140))
        return "\(safeBase).\(preferredExtension)"
    }

    private static func precedingMeaningfulLine(in text: NSString, before location: Int) -> String? {
        guard location > 0 else { return nil }
        let prefix = text.substring(to: location)
        return prefix.components(separatedBy: .newlines)
            .reversed()
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { $0.count >= 4 && $0.rangeOfCharacter(from: .letters) != nil }
    }

    private static func sentenceCase(_ value: String) -> String {
        guard let first = value.first else { return value }
        return first.uppercased() + value.dropFirst()
    }

    static func removeTemporaryAsset(_ asset: CapturedDocumentAsset) {
        let directory = asset.fileURL.deletingLastPathComponent().standardizedFileURL
        guard asset.cleanupDirectoryURL?.standardizedFileURL == directory,
              UUID(uuidString: directory.lastPathComponent) != nil,
              asset.fileURL.standardizedFileURL.deletingLastPathComponent() == directory,
              let values = try? directory.resourceValues(forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
              ]),
              values.isDirectory == true,
              values.isSymbolicLink != true else { return }
        removeTemporaryDirectoryBestEffort(
            directory,
            reason: "owned capture release"
        )
    }

    private static func closeFileHandleBestEffort(
        _ handle: FileHandle,
        purpose: String
    ) {
        do {
            try handle.close()
        } catch {
            // Reads and copied output are validated/synchronised before this
            // cleanup point, so a close error must be reported but must not mask
            // the primary operation result.
            documentCaptureLogger.error(
                "Best-effort \(purpose, privacy: .public) close failed: \(error.localizedDescription, privacy: .private)"
            )
        }
    }

    private static func removeTemporaryDirectoryBestEffort(
        _ directory: URL,
        fileManager: FileManager = .default,
        reason: String
    ) {
        do {
            try fileManager.removeItem(at: directory)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            // Cleanup is deliberately idempotent.
        } catch {
            documentCaptureLogger.error(
                "Best-effort \(reason, privacy: .public) cleanup failed for \(directory.lastPathComponent, privacy: .private): \(error.localizedDescription, privacy: .private)"
            )
        }
    }

    private static func validatedAfterCancellation(
        _ asset: CapturedDocumentAsset
    ) throws -> CapturedDocumentAsset {
        do {
            try Task.checkCancellation()
            return asset
        } catch {
            removeTemporaryAsset(asset)
            throw error
        }
    }

    static func purgeTemporaryCaptures() {
        removeTemporaryDirectoryBestEffort(
            captureDirectory,
            reason: "capture purge"
        )
    }

    static func purgeTemporaryCapturesInBackground(fileManager: FileManager = .default) {
        let root = captureDirectory
        let parent = root.deletingLastPathComponent()
        Task.detached(priority: .utility) {
            sweepRetiredTemporaryCaptures(in: parent, fileManager: FileManager())
        }
        guard fileManager.fileExists(atPath: root.path) else { return }
        let retired = root.deletingLastPathComponent().appendingPathComponent(
            "HausKlarCapture-retired-\(UUID().uuidString)",isDirectory: true
        )
        do {
            try fileManager.moveItem(at: root,to: retired)
            Task.detached(priority: .utility) {
                removeTemporaryDirectoryBestEffort(
                    retired,
                    fileManager: FileManager(),
                    reason: "retired capture purge"
                )
            }
        } catch {
            // A failed rename does not authorize a recursive fallback: a new
            // import may have appeared at this path while the move was failing.
            // The protected root remains available for the next purge attempt.
            documentCaptureLogger.error(
                "Capture purge retirement failed closed: \(error.localizedDescription, privacy: .private)"
            )
        }
    }

    nonisolated static func sweepRetiredTemporaryCaptures(
        in parentDirectory: URL? = nil,
        fileManager: FileManager = .default,
        maximumCandidates: Int = 256,
        maximumRemovals: Int = 32
    ) {
        // Stream the shared temporary directory instead of materializing it.
        // Only UUID-shaped HausKlar entries consume the candidate budget, so
        // unrelated provider files cannot permanently starve private cleanup.
        guard maximumCandidates > 0, maximumRemovals > 0 else { return }
        let parent = (parentDirectory ?? fileManager.temporaryDirectory).standardizedFileURL
        guard let enumerator = fileManager.enumerator(
            at: parent,
            includingPropertiesForKeys: [.isDirectoryKey,.isSymbolicLinkKey],
            options: [.skipsHiddenFiles,.skipsSubdirectoryDescendants],
            errorHandler: { _, _ in false }
        ) else { return }
        let prefix = "HausKlarCapture-retired-"
        var inspectedCandidates = 0
        var removed = 0
        while removed < maximumRemovals,
              let child = enumerator.nextObject() as? URL {
            let candidate = child.standardizedFileURL
            guard candidate.deletingLastPathComponent() == parent,
                  candidate.lastPathComponent.hasPrefix(prefix) else { continue }
            let suffix = String(candidate.lastPathComponent.dropFirst(prefix.count))
            guard UUID(uuidString: suffix) != nil else { continue }
            guard isValidatedRetiredDirectory(
                candidate,
                prefix: prefix,
                parent: parent
            ) else { continue }
            guard inspectedCandidates < maximumCandidates else { break }
            inspectedCandidates += 1
            do {
                try fileManager.removeItem(at: candidate)
                removed += 1
            } catch {
                continue
            }
        }
    }

    nonisolated private static func isValidatedRetiredDirectory(
        _ url: URL,
        prefix: String,
        parent: URL
    ) -> Bool {
        let standardized = url.standardizedFileURL
        guard standardized.deletingLastPathComponent() == parent,
              standardized.lastPathComponent.hasPrefix(prefix) else { return false }
        let suffix = String(standardized.lastPathComponent.dropFirst(prefix.count))
        guard UUID(uuidString: suffix) != nil,
              let values = try? standardized.resourceValues(forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
              ]) else { return false }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    static func purgePendingUploads() {
        do {
            try purgePendingUploadsSecurely()
        } catch {
            documentCaptureLogger.error(
                "Pending document upload purge failed: \(error.localizedDescription, privacy: .private)"
            )
        }
    }

    static func purgePendingUploadsSecurely(fileManager: FileManager = .default) throws {
        let root = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ).appendingPathComponent("DocumentUploads", isDirectory: true)
        if fileManager.fileExists(atPath: root.path) {
            try fileManager.removeItem(at: root)
        }
    }

    private static func uniqueTemporaryURL(
        filename: String,
        root: URL = captureDirectory,
        fileManager: FileManager = .default
    ) throws -> URL {
        try LocalFileProtection.prepareDirectory(root, fileManager: fileManager)
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try LocalFileProtection.prepareDirectory(directory, fileManager: fileManager)
        let candidate = (filename as NSString).lastPathComponent
        let safeFilename = candidate.isEmpty ? "document" : candidate
        return directory.appendingPathComponent(safeFilename)
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}
