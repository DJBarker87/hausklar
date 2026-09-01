import Foundation
import os

/// Builds protected, byte-bounded multipart request bodies without owning any
/// network or retry orchestration. Values are Sendable so APIClient can stage
/// bodies in a detached utility task while retaining cancellation semantics.
enum MultipartRequestBodyBuilder {
    private static let logger = Logger(
        subsystem: "org.example.hausklar",
        category: "APIClient"
    )
    private static let maximumFileBackedMultipartFieldsBytes = 1 * 1_024 * 1_024
    private static let maximumFileBackedMultipartFileCount = 100

    struct Field: Sendable {
        let name: String
        let value: String
    }

    enum Source: Sendable {
        case file(URL)
        case data(Data)
    }

    struct FilePart: Sendable {
        let fieldName: String
        let filename: String
        let mediaType: String
        let source: Source
    }

    struct TemporaryBody: Sendable {
        let directory: URL
        let file: URL
    }

    static func create(
        boundary: String,
        fields: [Field],
        files: [FilePart],
        root: URL,
        maximumSourceBytes: Int? = nil,
        fileManager: FileManager = .default
    ) throws -> TemporaryBody {
        try Task.checkCancellation()
        let expectedFileSizes = try files.map { part -> Int? in
            guard case .file(let sourceURL) = part.source else { return nil }
            return try validatedMultipartFileSize(at: sourceURL)
        }
        if let maximumSourceBytes {
            guard files.count <= maximumFileBackedMultipartFileCount else {
                throw APIClient.MultipartUploadSourceError.tooManyFiles(
                    maximum: maximumFileBackedMultipartFileCount
                )
            }
            let fieldsBytes = try fields.reduce(into: 0) { total, field in
                let bytes = field.name.utf8.count + field.value.utf8.count
                let (next, overflow) = total.addingReportingOverflow(bytes)
                guard !overflow else {
                    throw APIClient.MultipartUploadSourceError.fieldsTooLarge(
                        maximumBytes: maximumFileBackedMultipartFieldsBytes
                    )
                }
                total = next
            }
            guard fieldsBytes <= maximumFileBackedMultipartFieldsBytes else {
                throw APIClient.MultipartUploadSourceError.fieldsTooLarge(
                    maximumBytes: maximumFileBackedMultipartFieldsBytes
                )
            }
            let sourceBytes = try zip(files, expectedFileSizes).reduce(into: 0) {
                total, value in
                let (part, expectedFileSize) = value
                let bytes: Int
                switch part.source {
                case .data(let data):
                    bytes = data.count
                case .file:
                    guard let expectedFileSize else {
                        throw APIClient.MultipartUploadSourceError.invalidFile
                    }
                    bytes = expectedFileSize
                }
                let (next, overflow) = total.addingReportingOverflow(bytes)
                guard !overflow, next <= maximumSourceBytes else {
                    throw APIClient.MultipartUploadSourceError.requestTooLarge(
                        maximumBytes: maximumSourceBytes
                    )
                }
                total = next
            }
            guard sourceBytes <= maximumSourceBytes else {
                throw APIClient.MultipartUploadSourceError.requestTooLarge(
                    maximumBytes: maximumSourceBytes
                )
            }
        }
        try LocalFileProtection.prepareDirectory(root, fileManager: fileManager)
        let directory = root.appendingPathComponent(
            "multipart-\(UUID().uuidString)",
            isDirectory: true
        )
        do {
            try LocalFileProtection.prepareDirectory(directory, fileManager: fileManager)
            let bodyURL = directory.appendingPathComponent("request.body", isDirectory: false)
            guard
                fileManager.createFile(
                    atPath: bodyURL.path,
                    contents: nil,
                    attributes: [.protectionKey: LocalFileProtection.sensitive]
                )
            else {
                throw CocoaError(.fileWriteUnknown)
            }
            let output = try FileHandle(forWritingTo: bodyURL)
            var outputIsClosed = false
            defer {
                if !outputIsClosed {
                    closeFileHandleBestEffort(output, context: "multipart output")
                }
            }

            func append(_ string: String) throws {
                try Task.checkCancellation()
                try output.write(contentsOf: Data(string.utf8))
            }

            for field in fields {
                let name = multipartHeaderValue(field.name)
                try append("--\(boundary)\r\n")
                try append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
                try output.write(contentsOf: Data(field.value.utf8))
                try append("\r\n")
            }

            for (index, part) in files.enumerated() {
                let fieldName = multipartHeaderValue(part.fieldName)
                let filename = multipartHeaderValue(part.filename)
                let mediaType = multipartMediaType(part.mediaType)
                try append("--\(boundary)\r\n")
                try append(
                    "Content-Disposition: form-data; name=\"\(fieldName)\"; "
                        + "filename=\"\(filename)\"\r\n"
                )
                try append("Content-Type: \(mediaType)\r\n\r\n")
                switch part.source {
                case .data(let data):
                    try Task.checkCancellation()
                    try output.write(contentsOf: data)
                case .file(let sourceURL):
                    guard let expectedSize = expectedFileSizes[index],
                        try validatedMultipartFileSize(at: sourceURL) == expectedSize
                    else {
                        throw APIClient.MultipartUploadSourceError.fileChanged
                    }
                    try copyMultipartFile(
                        sourceURL,
                        expectedSize: expectedSize,
                        to: output
                    )
                }
                try append("\r\n")
            }
            try append("--\(boundary)--\r\n")
            try output.synchronize()
            try output.close()
            outputIsClosed = true
            try LocalFileProtection.protectItem(at: bodyURL, fileManager: fileManager)
            return TemporaryBody(directory: directory, file: bodyURL)
        } catch {
            removeTemporaryBodyBestEffort(
                directory,
                fileManager: fileManager,
                context: "failed multipart staging"
            )
            throw error
        }
    }

    private static func validatedMultipartFileSize(at sourceURL: URL) throws -> Int {
        guard sourceURL.isFileURL else {
            throw APIClient.MultipartUploadSourceError.invalidFile
        }
        let values: URLResourceValues
        do {
            values = try sourceURL.resourceValues(
                forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
            )
        } catch {
            throw APIClient.MultipartUploadSourceError.invalidFile
        }
        guard values.isRegularFile == true,
            values.isSymbolicLink != true,
            let size = values.fileSize,
            size >= 0
        else {
            throw APIClient.MultipartUploadSourceError.invalidFile
        }
        return size
    }

    private static func multipartHeaderValue(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r", with: "_")
            .replacingOccurrences(of: "\n", with: "_")
            .replacingOccurrences(of: "\"", with: "_")
    }

    private static func multipartMediaType(_ value: String) -> String {
        let sanitized =
            value
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty ? "application/octet-stream" : sanitized
    }

    private static func copyMultipartFile(
        _ sourceURL: URL,
        expectedSize: Int,
        to output: FileHandle
    ) throws {
        let input = try FileHandle(forReadingFrom: sourceURL)
        var inputIsClosed = false
        defer {
            if !inputIsClosed {
                closeFileHandleBestEffort(input, context: "multipart input")
            }
        }
        var copiedBytes = 0
        while copiedBytes < expectedSize {
            try Task.checkCancellation()
            let remaining = expectedSize - copiedBytes
            guard let chunk = try input.read(upToCount: min(1_024 * 1_024, remaining)),
                !chunk.isEmpty
            else {
                throw APIClient.MultipartUploadSourceError.fileChanged
            }
            try output.write(contentsOf: chunk)
            copiedBytes += chunk.count
        }
        if let trailingByte = try input.read(upToCount: 1), !trailingByte.isEmpty {
            throw APIClient.MultipartUploadSourceError.fileChanged
        }
        try input.close()
        inputIsClosed = true
    }

    private static func closeFileHandleBestEffort(
        _ handle: FileHandle,
        context: String
    ) {
        do {
            try handle.close()
        } catch {
            logger.error(
                "\(context, privacy: .public) handle cleanup failed: \(error.localizedDescription, privacy: .public). Reconciliation: FileHandle deallocation closes the descriptor and the next transfer opens a fresh handle."
            )
        }
    }

    private static func removeTemporaryBodyBestEffort(
        _ directory: URL,
        fileManager: FileManager,
        context: String
    ) {
        guard fileManager.fileExists(atPath: directory.path) else { return }
        do {
            try fileManager.removeItem(at: directory)
        } catch {
            logger.error(
                "\(context, privacy: .public) cleanup failed: \(error.localizedDescription, privacy: .public). Reconciliation: the next API client initialization retries aged HausKlar transfer cleanup."
            )
        }
    }
}
