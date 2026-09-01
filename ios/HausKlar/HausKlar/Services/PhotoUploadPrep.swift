import CoreTransferable
import CryptoKit
import Foundation
import ImageIO
import os
import UniformTypeIdentifiers
import UIKit

enum PhotoUploadPrepError: LocalizedError, Equatable {
    case emptyFile
    case fileTooLarge
    case notRegularFile
    case unsupportedImage
    case declaredTypeMismatch
    case unsafeDimensions
    case unreadableFile

    var errorDescription: String? {
        switch self {
        case .emptyFile:
            "The photo file was empty."
        case .fileTooLarge:
            "The photo is larger than the 25 MB limit."
        case .notRegularFile:
            "The selected photo was not a safe regular file."
        case .unsupportedImage:
            "The photo is not a supported JPEG, HEIC, PNG, WebP, GIF or TIFF image."
        case .declaredTypeMismatch:
            "The photo contents do not match its declared file type."
        case .unsafeDimensions:
            "The photo dimensions are too large to process safely."
        case .unreadableFile:
            "The selected photo could not be read."
        }
    }
}

/// An import-only representation that makes an owned copy while Photos still
/// guarantees access to its provider URL. `ReceivedTransferredFile.file` can be
/// ephemeral and can point at the user's original, so it must never escape the
/// importer or be removed by HausKlar. The lock makes the one-time ownership
/// handoff and deinit cleanup mutually exclusive across provider callbacks.
final class StagedPhotoTransfer: Transferable, @unchecked Sendable {
    private let lock = NSLock()
    private var stagedFile: PhotoUploadPrep.StagedFile?

    init(owning stagedFile: PhotoUploadPrep.StagedFile) {
        self.stagedFile = stagedFile
    }

    deinit {
        lock.lock()
        let stagedFile = stagedFile
        self.stagedFile = nil
        lock.unlock()
        if let stagedFile {
            PhotoUploadPrep.removeStagedFile(stagedFile)
        }
    }

    /// Moves cleanup responsibility to the caller. If a cancelled transfer is
    /// never delivered, `deinit` removes the protected owned directory instead.
    func takeStagedFile() throws -> PhotoUploadPrep.StagedFile {
        lock.lock()
        defer { lock.unlock() }
        guard let stagedFile else { throw PhotoUploadPrepError.unreadableFile }
        self.stagedFile = nil
        return stagedFile
    }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            StagedPhotoTransfer(
                owning: try PhotoUploadPrep.stageTransferredFile(at: received.file)
            )
        }
    }
}

/// File-backed validation and metadata helpers for family photo imports.
///
/// Original bytes are copied unchanged into a protected, uniquely-owned
/// directory. ImageIO is used only for metadata and bounded thumbnails; camera
/// originals are never decoded at full resolution by this pipeline.
enum PhotoUploadPrep {
    private static let logger = Logger(
        subsystem: "org.example.hausklar",
        category: "PhotoUploadPrep"
    )

    static let maximumOriginalBytes = 25 * 1_024 * 1_024
    static let maximumBatchFileBytes = 74 * 1_024 * 1_024
    static let maximumFilesPerBatch = 5
    static let maximumImageDimension: UInt64 = 20_000
    static let maximumImagePixels: UInt64 = 50_000_000
    static let maximumFrameCount = 300
    static let maximumTotalFramePixels: UInt64 = 100_000_000
    private static let maximumTIFFPreflightBytes = 64 * 1_024

    /// Long-edge cap and JPEG quality for derived uploads elsewhere in the app.
    static let maxUploadPixelSize = 2_048
    static let uploadJPEGQuality: CGFloat = 0.8

    static let acceptedUploadTypes: Set<String> = [
        "image/jpeg",
        "image/png",
        "image/heic",
        "image/heif",
        "image/webp",
        "image/gif",
        "image/tiff",
    ]

    struct StagedFile: Sendable, Equatable {
        let directoryURL: URL
        let fileURL: URL
        /// Issued only by `stageTransferredFile`; callers that wrap an existing
        /// file for validation do not gain recursive-deletion authority.
        fileprivate let cleanupDirectoryURL: URL?

        init(directoryURL: URL, fileURL: URL) {
            self.directoryURL = directoryURL
            self.fileURL = fileURL
            cleanupDirectoryURL = nil
        }

        fileprivate init(ownedDirectoryURL: URL, fileURL: URL) {
            directoryURL = ownedDirectoryURL
            self.fileURL = fileURL
            cleanupDirectoryURL = ownedDirectoryURL.standardizedFileURL
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.directoryURL == rhs.directoryURL && lhs.fileURL == rhs.fileURL
        }
    }

    struct PreparedFile: Sendable, Equatable {
        let stagedFile: StagedFile
        let clientId: String
        let filename: String
        let mediaType: String
        let takenOn: String
        let byteCount: Int
        let sha256: String

        var fileURL: URL { stagedFile.fileURL }
    }

    struct FileMetadata: Sendable, Equatable {
        let mediaType: String
        let fileExtension: String
    }

    private struct InspectedImage {
        let source: CGImageSource
        let metadata: FileMetadata
    }

    private static let stagingRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("HausKlarPhotoUploads", isDirectory: true)

    /// Removes only old, structurally valid directories created by this type.
    /// A grace period protects a transfer that is still being copied by another
    /// task/process, while the filename and resource checks keep provider-owned
    /// files, symlinks, and unrelated temporary content outside the deletion set.
    @discardableResult
    static func reconcileStagedFiles(
        at root: URL = stagingRoot,
        fileManager: FileManager = .default,
        now: Date = Date(),
        minimumAge: TimeInterval = 24 * 60 * 60,
        maximumCandidates: Int = 256,
        maximumRemovals: Int = 32
    ) -> Int {
        guard maximumCandidates > 0, maximumRemovals > 0 else { return 0 }
        let standardizedRoot = root.standardizedFileURL
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .contentModificationDateKey,
            .creationDateKey,
        ]
        // Reconciliation validation probes fail closed: an unreadable or
        // ambiguous path is never granted deletion authority.
        guard let rootValues = try? standardizedRoot.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ]),
              rootValues.isDirectory == true,
              rootValues.isSymbolicLink != true,
              let enumerator = fileManager.enumerator(
                at: standardizedRoot,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsSubdirectoryDescendants],
                errorHandler: { _, _ in false }
              ) else { return 0 }

        let cutoff = now.addingTimeInterval(-max(0, minimumAge))
        var removed = 0
        var inspectedCandidates = 0
        while removed < maximumRemovals,
              let entry = enumerator.nextObject() as? URL {
            let candidate = entry.standardizedFileURL
            guard candidate.deletingLastPathComponent() == standardizedRoot,
                  UUID(uuidString: candidate.lastPathComponent) != nil,
                  let directoryValues = try? candidate.resourceValues(forKeys: keys),
                  directoryValues.isDirectory == true,
                  directoryValues.isSymbolicLink != true,
                  let directoryDate = directoryValues.contentModificationDate
                    ?? directoryValues.creationDate,
                  directoryDate <= cutoff else { continue }
            guard hasSingleOwnedPayload(
                in: candidate,
                fileManager: fileManager,
                keys: keys,
                cutoff: cutoff
            ) else { continue }
            guard inspectedCandidates < maximumCandidates else { break }
            inspectedCandidates += 1

            do {
                try fileManager.removeItem(at: candidate)
                removed += 1
            } catch {
                logger.error(
                    "Could not remove an abandoned photo stage: \(error.localizedDescription, privacy: .public). Reconciliation: a later bounded pass retries the exact UUID-owned directory."
                )
                continue
            }
        }
        return removed
    }

    /// Copies a provider-owned file into a unique protected directory. The copy
    /// is bounded while streaming, so a file that changes after preflight cannot
    /// silently grow beyond the upload limit.
    static func stageTransferredFile(
        at sourceURL: URL,
        root: URL = stagingRoot,
        fileManager: FileManager = .default,
        copyChunkSize: Int = 1_024 * 1_024,
        onChunkCopied: (@Sendable (Int) -> Void)? = nil
    ) throws -> StagedFile {
        try Task.checkCancellation()
        let sourceValues = try regularFileValues(at: sourceURL)
        guard let expectedBytes = sourceValues.fileSize, expectedBytes > 0 else {
            throw PhotoUploadPrepError.emptyFile
        }
        guard expectedBytes <= maximumOriginalBytes else {
            throw PhotoUploadPrepError.fileTooLarge
        }

        try LocalFileProtection.prepareDirectory(root, fileManager: fileManager)
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        var keepDirectory = false
        defer {
            if !keepDirectory {
                removeInterruptedStage(directory, fileManager: fileManager)
            }
        }
        try LocalFileProtection.prepareDirectory(directory, fileManager: fileManager)
        let destination = directory.appendingPathComponent("original", isDirectory: false)
        guard fileManager.createFile(
            atPath: destination.path,
            contents: nil,
            attributes: [.protectionKey: LocalFileProtection.sensitive]
        ) else {
            throw PhotoUploadPrepError.unreadableFile
        }

        let input = try FileHandle(forReadingFrom: sourceURL)
        let output = try FileHandle(forWritingTo: destination)
        var inputNeedsClose = true
        var outputNeedsClose = true
        defer {
            if inputNeedsClose { closeAfterFailure(input, role: "input") }
            if outputNeedsClose { closeAfterFailure(output, role: "output") }
        }
        var copiedBytes = 0
        while true {
            try Task.checkCancellation()
            let chunk = try input.read(upToCount: max(1, copyChunkSize)) ?? Data()
            guard !chunk.isEmpty else { break }
            let (newCount, overflow) = copiedBytes.addingReportingOverflow(chunk.count)
            guard !overflow, newCount <= maximumOriginalBytes else {
                throw PhotoUploadPrepError.fileTooLarge
            }
            try output.write(contentsOf: chunk)
            copiedBytes = newCount
            onChunkCopied?(copiedBytes)
        }
        try Task.checkCancellation()
        try output.synchronize()
        try input.close()
        inputNeedsClose = false
        try output.close()
        outputNeedsClose = false
        guard copiedBytes == expectedBytes else { throw PhotoUploadPrepError.unreadableFile }
        try LocalFileProtection.protectItem(at: destination, fileManager: fileManager)
        _ = try regularFileValues(at: destination)
        keepDirectory = true
        return StagedFile(ownedDirectoryURL: directory, fileURL: destination)
    }

    /// Publishes an app-generated JPEG into the same protected, reconciled
    /// staging root as picker imports. This avoids a second ad-hoc temporary
    /// namespace whose interrupted directories would have no launch cleanup.
    static func stageGeneratedJPEG(
        _ data: Data,
        root: URL = stagingRoot,
        fileManager: FileManager = .default
    ) throws -> StagedFile {
        try Task.checkCancellation()
        guard !data.isEmpty else { throw PhotoUploadPrepError.emptyFile }
        guard data.count <= maximumOriginalBytes else {
            throw PhotoUploadPrepError.fileTooLarge
        }
        guard data.starts(with: [0xFF, 0xD8, 0xFF]) else {
            throw PhotoUploadPrepError.unsupportedImage
        }

        try LocalFileProtection.prepareDirectory(root, fileManager: fileManager)
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        var keepDirectory = false
        defer {
            if !keepDirectory {
                removeInterruptedStage(directory, fileManager: fileManager)
            }
        }
        try LocalFileProtection.prepareDirectory(directory, fileManager: fileManager)
        let destination = directory.appendingPathComponent("original", isDirectory: false)
        try data.write(
            to: destination,
            options: [.atomic, .completeFileProtection]
        )
        try LocalFileProtection.protectItem(at: destination, fileManager: fileManager)
        let values = try regularFileValues(at: destination)
        guard values.fileSize == data.count else {
            throw PhotoUploadPrepError.unreadableFile
        }
        try Task.checkCancellation()
        keepDirectory = true
        return StagedFile(ownedDirectoryURL: directory, fileURL: destination)
    }

    static func removeStagedFile(
        _ stagedFile: StagedFile,
        fileManager: FileManager = .default
    ) {
        let directory = stagedFile.directoryURL.standardizedFileURL
        let file = stagedFile.fileURL.standardizedFileURL
        // Ownership/resource inspection is a fail-closed deletion probe.
        guard stagedFile.cleanupDirectoryURL?.standardizedFileURL == directory,
              UUID(uuidString: directory.lastPathComponent) != nil,
              file.deletingLastPathComponent() == directory,
              file.lastPathComponent == "original",
              let values = try? directory.resourceValues(forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
              ]),
              values.isDirectory == true,
              values.isSymbolicLink != true else { return }
        do {
            try fileManager.removeItem(at: directory)
        } catch {
            logger.error(
                "Could not remove a consumed photo stage: \(error.localizedDescription, privacy: .public). Reconciliation: the bounded staging pass retries the exact UUID-owned directory."
            )
        }
    }

    /// Validates type, magic, size and decompression bounds before hashing. The
    /// declared identifiers come from `PhotosPickerItem.supportedContentTypes`.
    static func validatedStagedImageByteCount(
        _ stagedFile: StagedFile,
        declaredTypeIdentifiers: [String]
    ) throws -> Int {
        let (byteCount, _) = try inspectStagedFile(
            stagedFile,
            declaredTypeIdentifiers: declaredTypeIdentifiers
        )
        return byteCount
    }

    static func prepareStagedFile(
        _ stagedFile: StagedFile,
        declaredTypeIdentifiers: [String],
        childId: String,
        now: Date = Date()
    ) throws -> PreparedFile {
        let (byteCount, inspected) = try inspectStagedFile(
            stagedFile,
            declaredTypeIdentifiers: declaredTypeIdentifiers
        )
        let digest = try sha256(of: stagedFile.fileURL)
        try Task.checkCancellation()
        let idDigest = SHA256.hash(data: Data("\(childId):\(digest)".utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return PreparedFile(
            stagedFile: stagedFile,
            clientId: "ios-photo-\(idDigest.prefix(40))",
            filename: "photo.\(inspected.metadata.fileExtension)",
            mediaType: inspected.metadata.mediaType,
            takenOn: dayString(from: captureDate(from: inspected.source) ?? now),
            byteCount: byteCount,
            sha256: digest
        )
    }

    /// Returns how many newly requested items can fit without exceeding a
    /// session-level selection count. Keeping this arithmetic centralized
    /// avoids repeated picker changes bypassing a per-presentation limit.
    static func permittedSelectionCount(
        existingCount: Int,
        requestedCount: Int,
        maximumCount: Int
    ) -> Int {
        guard requestedCount > 0, maximumCount > 0 else { return 0 }
        let remaining = max(0, maximumCount - max(0, existingCount))
        return min(requestedCount, remaining)
    }

    /// Adds a retained source/derived byte count while rejecting integer
    /// overflow and aggregate growth beyond the form's explicit budget.
    static func checkedAggregateByteCount(
        currentBytes: Int,
        nextBytes: Int,
        maximumBytes: Int = maximumBatchFileBytes
    ) throws -> Int {
        guard currentBytes >= 0, nextBytes > 0, maximumBytes > 0 else {
            throw PhotoUploadPrepError.emptyFile
        }
        let (total, overflow) = currentBytes.addingReportingOverflow(nextBytes)
        guard !overflow, total <= maximumBytes else {
            throw PhotoUploadPrepError.fileTooLarge
        }
        return total
    }

    /// Pure batching helper used by both the streaming upload loop and tests.
    /// Every returned index group obeys the file-count and source-byte caps.
    static func batchIndices(
        forByteCounts byteCounts: [Int],
        maximumFiles: Int = maximumFilesPerBatch,
        maximumBytes: Int = maximumBatchFileBytes
    ) throws -> [[Int]] {
        guard maximumFiles > 0, maximumBytes > 0 else {
            throw PhotoUploadPrepError.fileTooLarge
        }
        var batches: [[Int]] = []
        var current: [Int] = []
        var currentBytes = 0
        for (index, byteCount) in byteCounts.enumerated() {
            guard byteCount > 0 else { throw PhotoUploadPrepError.emptyFile }
            guard byteCount <= maximumBytes else { throw PhotoUploadPrepError.fileTooLarge }
            let (nextBytes, overflow) = currentBytes.addingReportingOverflow(byteCount)
            if !current.isEmpty,
               current.count == maximumFiles || overflow || nextBytes > maximumBytes {
                batches.append(current)
                current = []
                currentBytes = 0
            }
            current.append(index)
            currentBytes += byteCount
        }
        if !current.isEmpty { batches.append(current) }
        return batches
    }

    static func shouldStartNewBatch(
        currentFileCount: Int,
        currentBytes: Int,
        nextFileBytes: Int
    ) -> Bool {
        guard currentFileCount > 0 else { return false }
        guard currentFileCount < maximumFilesPerBatch else { return true }
        let (total, overflow) = currentBytes.addingReportingOverflow(nextFileBytes)
        return overflow || total > maximumBatchFileBytes
    }

    // MARK: - Bounded display decoding

    static func displayImage(from data: Data, maxPixelSize: Int) -> UIImage? {
        // Image validation is an optional, fail-closed display probe.
        guard !data.isEmpty, data.count <= maximumOriginalBytes,
              let source = CGImageSourceCreateWithData(
                  data as CFData,
                  [kCGImageSourceShouldCache: false] as CFDictionary
              ),
              (try? validateImageSource(source)) != nil else { return nil }
        return displayImage(from: source, maxPixelSize: maxPixelSize)
    }

    static func displayImage(at url: URL, maxPixelSize: Int) -> UIImage? {
        guard let values = try? regularFileValues(at: url),
              let byteCount = values.fileSize,
              byteCount > 0,
              byteCount <= maximumOriginalBytes,
              let source = CGImageSourceCreateWithURL(
                  url as CFURL,
                  [kCGImageSourceShouldCache: false] as CFDictionary
              ),
              (try? validateImageSource(source)) != nil else { return nil }
        return displayImage(from: source, maxPixelSize: maxPixelSize)
    }

    private static func displayImage(
        from source: CGImageSource,
        maxPixelSize: Int
    ) -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(
            source, 0, options as CFDictionary
        ) else { return nil }
        return UIImage(cgImage: image)
    }

    // MARK: - Metadata

    static func captureDate(from data: Data) -> Date? {
        guard !data.isEmpty, data.count <= maximumOriginalBytes,
              let source = CGImageSourceCreateWithData(
                  data as CFData,
                  [kCGImageSourceShouldCache: false] as CFDictionary
              ) else { return nil }
        return captureDate(from: source)
    }

    static func captureDate(at url: URL) -> Date? {
        guard let source = boundedValidatedImageSource(at: url) else { return nil }
        return captureDate(from: source)
    }

    static func takenOnString(from data: Data, now: Date = Date()) -> String {
        dayString(from: captureDate(from: data) ?? now)
    }

    static func takenOnString(at url: URL, now: Date = Date()) -> String {
        dayString(from: captureDate(at: url) ?? now)
    }

    static func fileMetadata(at url: URL) -> FileMetadata? {
        guard let source = boundedValidatedImageSource(at: url) else { return nil }
        return imageMetadata(for: source)
    }

    /// Downsamples without the old `UIImage(data:)` fallback, which could fully
    /// decode an attacker-controlled camera-sized bitmap when ImageIO rejected
    /// bounded thumbnail creation.
    static func downsampledJPEG(from data: Data) -> Data? {
        guard !data.isEmpty, data.count <= maximumOriginalBytes,
              let source = CGImageSourceCreateWithData(
                  data as CFData,
                  [kCGImageSourceShouldCache: false] as CFDictionary
              ),
              (try? validateImageSource(source)) != nil else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxUploadPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
            source, 0, options as CFDictionary
        ) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(
            destination,
            thumbnail,
            [kCGImageDestinationLossyCompressionQuality: uploadJPEGQuality] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    // MARK: - Validation internals

    private static func inspectImage(
        at url: URL,
        byteCount: Int,
        declaredTypeIdentifiers: [String]
    ) throws -> InspectedImage {
        let prefix = try readPrefix(of: url, maximumBytes: 32)
        try preflightTIFFDimensionsIfPresent(at: url, prefix: prefix)
        guard let source = CGImageSourceCreateWithURL(
            url as CFURL,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ), let metadata = imageMetadata(for: source),
           acceptedUploadTypes.contains(metadata.mediaType) else {
            throw PhotoUploadPrepError.unsupportedImage
        }
        guard byteCount > 0, magicMatches(prefix, mediaType: metadata.mediaType) else {
            throw PhotoUploadPrepError.declaredTypeMismatch
        }
        let declaredTypes = declaredTypeIdentifiers.compactMap(UTType.init)
        if !declaredTypes.isEmpty,
           let actualType = UTType(mimeType: metadata.mediaType),
           !declaredTypes.contains(where: {
               $0 == .image || actualType.conforms(to: $0) || $0.conforms(to: actualType)
           }) {
            throw PhotoUploadPrepError.declaredTypeMismatch
        }
        try validateImageSource(source)
        return InspectedImage(source: source, metadata: metadata)
    }

    private static func boundedValidatedImageSource(at url: URL) -> CGImageSource? {
        // Metadata/display callers intentionally collapse validation failure to
        // “no image”; no state transition depends on this optional probe.
        guard let values = try? regularFileValues(at: url),
              let byteCount = values.fileSize,
              byteCount > 0,
              byteCount <= maximumOriginalBytes,
              let source = CGImageSourceCreateWithURL(
                  url as CFURL,
                  [kCGImageSourceShouldCache: false] as CFDictionary
              ),
              (try? validateImageSource(source)) != nil else { return nil }
        return source
    }

    private static func hasSingleOwnedPayload(
        in directory: URL,
        fileManager: FileManager,
        keys: Set<URLResourceKey>,
        cutoff: Date
    ) -> Bool {
        var didEncounterError = false
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsSubdirectoryDescendants],
            errorHandler: { _, _ in
                didEncounterError = true
                return false
            }
        ) else { return false }
        guard let first = enumerator.nextObject() as? URL else { return false }
        let second = enumerator.nextObject()
        guard second == nil, !didEncounterError else { return false }
        let payload = first.standardizedFileURL
        guard payload.deletingLastPathComponent() == directory,
              payload.lastPathComponent == "original",
              let values = try? payload.resourceValues(forKeys: keys),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              let date = values.contentModificationDate ?? values.creationDate else { return false }
        return date <= cutoff
    }

    private static func inspectStagedFile(
        _ stagedFile: StagedFile,
        declaredTypeIdentifiers: [String]
    ) throws -> (byteCount: Int, inspected: InspectedImage) {
        try Task.checkCancellation()
        let values = try regularFileValues(at: stagedFile.fileURL)
        guard let byteCount = values.fileSize, byteCount > 0 else {
            throw PhotoUploadPrepError.emptyFile
        }
        guard byteCount <= maximumOriginalBytes else {
            throw PhotoUploadPrepError.fileTooLarge
        }
        let inspected = try inspectImage(
            at: stagedFile.fileURL,
            byteCount: byteCount,
            declaredTypeIdentifiers: declaredTypeIdentifiers
        )
        try Task.checkCancellation()
        return (byteCount, inspected)
    }

    private static func validateImageSource(_ source: CGImageSource) throws {
        let frameCount = CGImageSourceGetCount(source)
        guard frameCount > 0, frameCount <= maximumFrameCount else {
            throw PhotoUploadPrepError.unsafeDimensions
        }
        var totalPixels: UInt64 = 0
        for index in 0..<frameCount {
            try Task.checkCancellation()
            guard let properties = CGImageSourceCopyPropertiesAtIndex(
                source, index, [kCGImageSourceShouldCache: false] as CFDictionary
            ) as? [CFString: Any],
                  let width = dimension(properties[kCGImagePropertyPixelWidth]),
                  let height = dimension(properties[kCGImagePropertyPixelHeight]) else {
                throw PhotoUploadPrepError.unsafeDimensions
            }
            let pixels = try validatedPixelCount(width: width, height: height)
            let (newTotal, totalOverflow) = totalPixels.addingReportingOverflow(pixels)
            guard !totalOverflow, newTotal <= maximumTotalFramePixels else {
                throw PhotoUploadPrepError.unsafeDimensions
            }
            totalPixels = newTotal
        }
    }

    /// ImageIO 26 can reject a metadata-only TIFF before exposing its pixel
    /// properties. Inspect only the bounded first IFD so hostile dimensions are
    /// still classified and rejected without allocating or decoding pixels.
    private static func preflightTIFFDimensionsIfPresent(
        at url: URL,
        prefix: Data
    ) throws {
        guard magicMatches(prefix, mediaType: "image/tiff") else { return }
        let header = try readPrefix(of: url, maximumBytes: maximumTIFFPreflightBytes)
        guard let dimensions = tiffDimensions(in: header) else { return }
        _ = try validatedPixelCount(width: dimensions.width, height: dimensions.height)
    }

    private static func validatedPixelCount(width: UInt64, height: UInt64) throws -> UInt64 {
        guard width > 0,
              height > 0,
              width <= maximumImageDimension,
              height <= maximumImageDimension else {
            throw PhotoUploadPrepError.unsafeDimensions
        }
        let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow, pixels <= maximumImagePixels else {
            throw PhotoUploadPrepError.unsafeDimensions
        }
        return pixels
    }

    private static func tiffDimensions(in data: Data) -> (width: UInt64, height: UInt64)? {
        let bytes = [UInt8](data)
        guard bytes.count >= 10 else { return nil }
        let littleEndian: Bool
        if bytes[0] == 0x49, bytes[1] == 0x49 {
            littleEndian = true
        } else if bytes[0] == 0x4D, bytes[1] == 0x4D {
            littleEndian = false
        } else {
            return nil
        }

        func uint16(at offset: Int) -> UInt16? {
            guard offset >= 0, offset <= bytes.count - 2 else { return nil }
            if littleEndian {
                return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
            }
            return (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
        }

        func uint32(at offset: Int) -> UInt32? {
            guard offset >= 0, offset <= bytes.count - 4 else { return nil }
            if littleEndian {
                return UInt32(bytes[offset])
                    | (UInt32(bytes[offset + 1]) << 8)
                    | (UInt32(bytes[offset + 2]) << 16)
                    | (UInt32(bytes[offset + 3]) << 24)
            }
            return (UInt32(bytes[offset]) << 24)
                | (UInt32(bytes[offset + 1]) << 16)
                | (UInt32(bytes[offset + 2]) << 8)
                | UInt32(bytes[offset + 3])
        }

        guard uint16(at: 2) == 42,
              let firstIFD = uint32(at: 4),
              Int(firstIFD) <= bytes.count - 2,
              let entryCount = uint16(at: Int(firstIFD)) else { return nil }
        let entriesStart = Int(firstIFD) + 2
        guard Int(entryCount) <= (bytes.count - entriesStart) / 12 else { return nil }

        var width: UInt64?
        var height: UInt64?
        for index in 0..<Int(entryCount) {
            let entry = entriesStart + index * 12
            guard let tag = uint16(at: entry),
                  tag == 256 || tag == 257,
                  let fieldType = uint16(at: entry + 2),
                  let valueCount = uint32(at: entry + 4),
                  valueCount == 1 else { continue }
            let value: UInt64?
            switch fieldType {
            case 3:
                value = uint16(at: entry + 8).map(UInt64.init)
            case 4:
                value = uint32(at: entry + 8).map(UInt64.init)
            default:
                value = nil
            }
            if tag == 256 { width = value }
            if tag == 257 { height = value }
            if let width, let height { return (width, height) }
        }
        return nil
    }

    private static func dimension(_ value: Any?) -> UInt64? {
        guard let number = value as? NSNumber else { return nil }
        let value = number.doubleValue
        guard value.isFinite, value > 0, value.rounded(.towardZero) == value,
              value <= Double(UInt64.max) else { return nil }
        return UInt64(value)
    }

    private static func imageMetadata(for source: CGImageSource) -> FileMetadata? {
        guard let identifier = CGImageSourceGetType(source) as String?,
              let type = UTType(identifier),
              let mediaType = type.preferredMIMEType,
              let fileExtension = type.preferredFilenameExtension else { return nil }
        return FileMetadata(mediaType: mediaType.lowercased(), fileExtension: fileExtension)
    }

    private static func magicMatches(_ data: Data, mediaType: String) -> Bool {
        let bytes = [UInt8](data)
        switch mediaType {
        case "image/jpeg":
            return bytes.starts(with: [0xFF, 0xD8, 0xFF])
        case "image/png":
            return bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        case "image/gif":
            return bytes.starts(with: Array("GIF87a".utf8))
                || bytes.starts(with: Array("GIF89a".utf8))
        case "image/tiff":
            return bytes.starts(with: [0x49, 0x49, 0x2A, 0x00])
                || bytes.starts(with: [0x4D, 0x4D, 0x00, 0x2A])
        case "image/webp":
            return bytes.count >= 12
                && Array(bytes[0..<4]) == Array("RIFF".utf8)
                && Array(bytes[8..<12]) == Array("WEBP".utf8)
        case "image/heic", "image/heif":
            return bytes.count >= 12 && Array(bytes[4..<8]) == Array("ftyp".utf8)
        default:
            return false
        }
    }

    private static func regularFileValues(at url: URL) throws -> URLResourceValues {
        let values = try url.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        )
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw PhotoUploadPrepError.notRegularFile
        }
        return values
    }

    private static func readPrefix(of url: URL, maximumBytes: Int) throws -> Data {
        try Task.checkCancellation()
        let handle = try FileHandle(forReadingFrom: url)
        do {
            let data = try handle.read(upToCount: max(1, maximumBytes)) ?? Data()
            try Task.checkCancellation()
            try handle.close()
            return data
        } catch {
            closeAfterFailure(handle, role: "prefix reader")
            throw error
        }
    }

    private static func sha256(of url: URL) throws -> String {
        try Task.checkCancellation()
        let handle = try FileHandle(forReadingFrom: url)
        do {
            var digest = SHA256()
            while true {
                try Task.checkCancellation()
                let chunk = try handle.read(upToCount: 1_024 * 1_024) ?? Data()
                guard !chunk.isEmpty else { break }
                digest.update(data: chunk)
            }
            try handle.close()
            return digest.finalize().map { String(format: "%02x", $0) }.joined()
        } catch {
            closeAfterFailure(handle, role: "digest reader")
            throw error
        }
    }

    private static func removeInterruptedStage(
        _ directory: URL,
        fileManager: FileManager
    ) {
        do {
            try fileManager.removeItem(at: directory)
        } catch {
            logger.error(
                "Could not remove an interrupted photo stage: \(error.localizedDescription, privacy: .public). Reconciliation: the bounded staging pass retries the exact UUID-owned directory."
            )
        }
    }

    private static func closeAfterFailure(_ handle: FileHandle, role: String) {
        do {
            try handle.close()
        } catch {
            logger.error(
                "Could not close photo \(role, privacy: .public) after failure: \(error.localizedDescription, privacy: .public). The handle remains process-owned and closes on deallocation."
            )
        }
    }

    private static func captureDate(from source: CGImageSource) -> Date? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
            as? [CFString: Any] else { return nil }
        if let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let original = exif[kCGImagePropertyExifDateTimeOriginal] as? String,
           let date = exifDateFormatter().date(from: original) {
            return date
        }
        if let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
           let dateTime = tiff[kCGImagePropertyTIFFDateTime] as? String,
           let date = exifDateFormatter().date(from: dateTime) {
            return date
        }
        return nil
    }

    private static func exifDateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.timeZone = .current
        return formatter
    }

    private static func dayString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        return formatter.string(from: date)
    }
}
