import CoreImage
import Foundation
import ImageIO
import os
import UIKit
import UniformTypeIdentifiers

struct FitnessProgressPhotoArtifact: Equatable, Sendable {
    let directoryURL: URL
    let fileURL: URL
    let byteCount: Int
    let capturedAt: Date?

    fileprivate init(directoryURL: URL, fileURL: URL, byteCount: Int, capturedAt: Date?) {
        self.directoryURL = directoryURL
        self.fileURL = fileURL
        self.byteCount = byteCount
        self.capturedAt = capturedAt
    }
}

/// Produces the one bounded JPEG accepted by the progress-photo domain.
///
/// Photo-library provider files are first copied by `StagedPhotoTransfer`; this
/// type then reads that owned copy through ImageIO and writes another protected,
/// owned file. Neither the provider original nor its complete bytes are ever
/// materialised as `Data` or made eligible for deletion by HausKlar.
enum FitnessProgressPhotoPreparation {
    private static let logger = Logger(
        subsystem: "org.example.hausklar",
        category: "FitnessProgressPhotoPreparation"
    )

    static let maximumJPEGBytes = 10 * 1_024 * 1_024
    static let maximumOutputDimension = 2_048
    private static let maximumInputDimension: UInt64 = 20_000
    private static let maximumInputPixels: UInt64 = 50_000_000
    private static let jpegQuality: CGFloat = 0.8
    private static let artifactFilename = "progress.jpg"
    private static let defaultRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
        "HausKlarProgressPhotoImports", isDirectory: true
    )

    static func prepareTransferredFile(
        _ stagedFile: PhotoUploadPrep.StagedFile,
        declaredTypeIdentifiers: [String],
        root: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> FitnessProgressPhotoArtifact {
        try Task.checkCancellation()
        _ = try PhotoUploadPrep.validatedStagedImageByteCount(
            stagedFile,
            declaredTypeIdentifiers: declaredTypeIdentifiers
        )
        let capturedAt = PhotoUploadPrep.captureDate(at: stagedFile.fileURL)
        guard
            let source = CGImageSourceCreateWithURL(
                stagedFile.fileURL as CFURL,
                [kCGImageSourceShouldCache: false] as CFDictionary
            )
        else {
            throw PhotoUploadPrepError.unsupportedImage
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumOutputDimension,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard
            let image = CGImageSourceCreateThumbnailAtIndex(
                source, 0, options as CFDictionary
            )
        else {
            throw PhotoUploadPrepError.unreadableFile
        }
        try Task.checkCancellation()
        return try writeArtifact(
            image: image,
            capturedAt: capturedAt,
            root: root ?? defaultRoot,
            fileManager: fileManager
        )
    }

    /// The system camera supplies a `UIImage`. Render only a bounded Core Image
    /// result off-main and encode that result directly to the protected file.
    /// No additional full-resolution encoded buffer is created.
    static func prepareCameraImage(
        _ image: UIImage,
        capturedAt: Date = Date(),
        root: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> FitnessProgressPhotoArtifact {
        try Task.checkCancellation()
        guard let input = CIImage(image: image) else {
            throw PhotoUploadPrepError.unsupportedImage
        }
        let extent = input.extent.integral
        guard extent.width.isFinite, extent.height.isFinite,
            extent.width > 0, extent.height > 0,
            extent.width <= CGFloat(maximumInputDimension),
            extent.height <= CGFloat(maximumInputDimension)
        else {
            throw PhotoUploadPrepError.unsafeDimensions
        }
        let pixels = extent.width * extent.height
        guard pixels.isFinite, pixels <= CGFloat(maximumInputPixels) else {
            throw PhotoUploadPrepError.unsafeDimensions
        }
        let scale = min(1, CGFloat(maximumOutputDimension) / max(extent.width, extent.height))
        let output = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext(options: [.cacheIntermediates: false])
        guard let rendered = context.createCGImage(output, from: output.extent.integral) else {
            throw PhotoUploadPrepError.unreadableFile
        }
        try Task.checkCancellation()
        return try writeArtifact(
            image: rendered,
            capturedAt: capturedAt,
            root: root ?? defaultRoot,
            fileManager: fileManager
        )
    }

    static func verifiedJPEGByteCount(
        at url: URL,
        maximumBytes: Int = maximumJPEGBytes
    ) throws -> Int {
        try Task.checkCancellation()
        let keys: Set<URLResourceKey> = [
            .fileSizeKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ]
        let values = try url.resourceValues(forKeys: keys)
        guard values.isRegularFile == true,
            values.isSymbolicLink != true,
            let byteCount = values.fileSize,
            byteCount >= 4,
            byteCount <= maximumBytes,
            try hasJPEGMagic(at: url),
            let source = CGImageSourceCreateWithURL(
                url as CFURL,
                [kCGImageSourceShouldCache: false] as CFDictionary
            ),
            CGImageSourceGetType(source) as String? == UTType.jpeg.identifier,
            CGImageSourceGetCount(source) == 1,
            let properties = CGImageSourceCopyPropertiesAtIndex(
                source,
                0,
                [kCGImageSourceShouldCache: false] as CFDictionary
            ) as? [CFString: Any],
            let width = dimension(properties[kCGImagePropertyPixelWidth]),
            let height = dimension(properties[kCGImagePropertyPixelHeight]),
            width <= UInt64(maximumOutputDimension),
            height <= UInt64(maximumOutputDimension)
        else {
            throw PhotoUploadPrepError.unsupportedImage
        }
        let (pixelCount, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow,
            pixelCount <= UInt64(maximumOutputDimension * maximumOutputDimension)
        else {
            throw PhotoUploadPrepError.unsafeDimensions
        }
        try Task.checkCancellation()
        return byteCount
    }

    static func removeArtifact(
        _ artifact: FitnessProgressPhotoArtifact,
        fileManager: FileManager = .default
    ) {
        let directory = artifact.directoryURL.standardizedFileURL
        let file = artifact.fileURL.standardizedFileURL
        guard isOwnedArtifactDirectoryName(directory.lastPathComponent),
            file.deletingLastPathComponent() == directory,
            file.lastPathComponent == artifactFilename
        else { return }
        do {
            try fileManager.removeItem(at: directory)
        } catch {
            logger.error(
                "Could not remove a consumed progress-photo artifact: \(error.localizedDescription, privacy: .public). Reconciliation: the bounded artifact pass retries the exact UUID-owned directory."
            )
        }
    }

    /// Bounded startup reconciliation for artifacts abandoned by termination.
    @discardableResult
    static func reconcileArtifacts(
        at root: URL? = nil,
        fileManager: FileManager = .default,
        now: Date = Date(),
        minimumAge: TimeInterval = 24 * 60 * 60,
        maximumCandidates: Int = 128,
        maximumRemovals: Int = 32
    ) -> Int {
        guard maximumCandidates > 0, maximumRemovals > 0 else { return 0 }
        let root = (root ?? defaultRoot).standardizedFileURL
        let keys: Set<URLResourceKey> = [
            .contentModificationDateKey,
            .creationDateKey,
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ]
        // Reconciliation resource reads are fail-closed deletion probes.
        guard let rootValues = try? root.resourceValues(forKeys: keys),
            rootValues.isDirectory == true,
            rootValues.isSymbolicLink != true
        else { return 0 }
        guard
            let entries = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsSubdirectoryDescendants],
                errorHandler: { _, _ in false }
            )
        else { return 0 }
        let cutoff = now.addingTimeInterval(-max(0, minimumAge))
        var candidates = 0
        var removed = 0
        while let next = entries.nextObject() {
            guard !Task.isCancelled,
                candidates < maximumCandidates,
                removed < maximumRemovals
            else { break }
            guard let entry = next as? URL else { continue }
            let directory = entry.standardizedFileURL
            guard directory.deletingLastPathComponent() == root,
                isOwnedArtifactDirectoryName(directory.lastPathComponent),
                let directoryValues = try? directory.resourceValues(forKeys: keys),
                directoryValues.isDirectory == true,
                directoryValues.isSymbolicLink != true,
                let directoryDate = directoryValues.contentModificationDate
                    ?? directoryValues.creationDate,
                directoryDate <= cutoff,
                containsOnlyStaleOwnedArtifactFile(
                    in: directory,
                    keys: keys,
                    cutoff: cutoff,
                    fileManager: fileManager
                )
            else { continue }
            candidates += 1
            do {
                try fileManager.removeItem(at: directory)
                removed += 1
            } catch {
                logger.error(
                    "Could not remove an abandoned progress-photo artifact: \(error.localizedDescription, privacy: .public). Reconciliation: a later bounded pass retries the exact UUID-owned directory."
                )
                continue
            }
        }
        return removed
    }

    private static func isOwnedArtifactDirectoryName(_ name: String) -> Bool {
        guard let uuid = UUID(uuidString: name) else { return false }
        return uuid.uuidString == name
    }

    /// Looks at no more than two immediate children. A second entry proves the
    /// directory is not an exact HausKlar artifact without materialising it.
    private static func containsOnlyStaleOwnedArtifactFile(
        in directory: URL,
        keys: Set<URLResourceKey>,
        cutoff: Date,
        fileManager: FileManager
    ) -> Bool {
        var enumerationFailed = false
        guard
            let children = fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsSubdirectoryDescendants],
                errorHandler: { _, _ in
                    enumerationFailed = true
                    return false
                }
            )
        else { return false }
        var onlyChild: URL?
        var childCount = 0
        while let next = children.nextObject() {
            guard !Task.isCancelled, let child = next as? URL else { return false }
            childCount += 1
            guard childCount == 1 else { return false }
            onlyChild = child.standardizedFileURL
        }
        guard !enumerationFailed,
            childCount == 1,
            let file = onlyChild,
            file.deletingLastPathComponent() == directory,
            file.lastPathComponent == artifactFilename,
            let values = try? file.resourceValues(forKeys: keys),
            values.isRegularFile == true,
            values.isSymbolicLink != true,
            let fileDate = values.contentModificationDate ?? values.creationDate,
            fileDate <= cutoff
        else { return false }
        return true
    }

    private static func writeArtifact(
        image: CGImage,
        capturedAt: Date?,
        root: URL,
        fileManager: FileManager
    ) throws -> FitnessProgressPhotoArtifact {
        try Task.checkCancellation()
        try LocalFileProtection.prepareDirectory(root, fileManager: fileManager)
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        var keepDirectory = false
        defer {
            if !keepDirectory {
                removeInterruptedArtifact(directory, fileManager: fileManager)
            }
        }
        try LocalFileProtection.prepareDirectory(directory, fileManager: fileManager)
        let file = directory.appendingPathComponent(artifactFilename)
        guard
            fileManager.createFile(
                atPath: file.path,
                contents: nil,
                attributes: [.protectionKey: LocalFileProtection.sensitive]
            ),
            let destination = CGImageDestinationCreateWithURL(
                file as CFURL,
                UTType.jpeg.identifier as CFString,
                1,
                nil
            )
        else {
            throw PhotoUploadPrepError.unreadableFile
        }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: jpegQuality] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            throw PhotoUploadPrepError.unreadableFile
        }
        try Task.checkCancellation()
        try LocalFileProtection.protectItem(at: file, fileManager: fileManager)
        let byteCount = try verifiedJPEGByteCount(at: file)
        keepDirectory = true
        return FitnessProgressPhotoArtifact(
            directoryURL: directory,
            fileURL: file,
            byteCount: byteCount,
            capturedAt: capturedAt
        )
    }

    private static func hasJPEGMagic(at url: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: url)
        do {
            let prefix = try handle.read(upToCount: 3) ?? Data()
            let length = try handle.seekToEnd()
            guard prefix == Data([0xFF, 0xD8, 0xFF]), length >= 4 else {
                try handle.close()
                return false
            }
            try handle.seek(toOffset: length - 2)
            let hasSuffix = try handle.read(upToCount: 2) == Data([0xFF, 0xD9])
            try handle.close()
            return hasSuffix
        } catch {
            closeAfterFailure(handle)
            throw error
        }
    }

    private static func removeInterruptedArtifact(
        _ directory: URL,
        fileManager: FileManager
    ) {
        do {
            try fileManager.removeItem(at: directory)
        } catch {
            logger.error(
                "Could not remove an interrupted progress-photo artifact: \(error.localizedDescription, privacy: .public). Reconciliation: the bounded artifact pass retries the exact UUID-owned directory."
            )
        }
    }

    private static func closeAfterFailure(_ handle: FileHandle) {
        do {
            try handle.close()
        } catch {
            logger.error(
                "Could not close a progress-photo validation handle after failure: \(error.localizedDescription, privacy: .public). The handle remains process-owned and closes on deallocation."
            )
        }
    }

    private static func dimension(_ value: Any?) -> UInt64? {
        guard let number = value as? NSNumber else { return nil }
        let value = number.doubleValue
        guard value.isFinite,
            value > 0,
            value.rounded(.towardZero) == value,
            value <= Double(UInt64.max)
        else { return nil }
        return UInt64(value)
    }
}
