import Foundation
import ImageIO

/// Validates a URLSession download before any response body is copied into app memory.
///
/// Authenticated responses are still untrusted input. Download tasks keep chunked or
/// incorrectly labelled bodies off the app/widget heap while these limits are applied.
enum BoundedHTTPPayload {
    enum ValidationError: LocalizedError, Equatable {
        case invalidResponse
        case unexpectedMediaType(String?)
        case declaredSizeExceedsMaximum
        case actualSizeExceedsMaximum
        case emptyPayload
        case invalidImage
        case imageMediaTypeMismatch(declared: String, actual: String)

        var errorDescription: String? {
            switch self {
            case .invalidResponse:
                "The server returned an invalid response."
            case .unexpectedMediaType:
                "The server returned an unexpected file type."
            case .declaredSizeExceedsMaximum, .actualSizeExceedsMaximum:
                "The server response exceeds the allowed size."
            case .emptyPayload:
                "The server returned an empty file."
            case .invalidImage:
                "The server returned an invalid image."
            case .imageMediaTypeMismatch:
                "The image contents do not match the declared file type."
            }
        }
    }

    struct ImageLimits: Hashable, Sendable {
        let maximumWidth: Int
        let maximumHeight: Int
        let maximumPixels: Int64
    }

    /// Copies a completed download into memory only after both the declared and
    /// on-disk byte counts have passed a finite boundary. This is the common
    /// response primitive for JSON: unknown-length bodies stay file-backed while
    /// Foundation receives them and can never grow the app heap without bound.
    static func readResponseBody(
        at fileURL: URL,
        response: URLResponse,
        maximumBytes: Int,
        allowsEmpty: Bool = true
    ) throws -> Data {
        guard maximumBytes > 0, response is HTTPURLResponse else {
            throw ValidationError.invalidResponse
        }
        try validateDeclaredSize(response.expectedContentLength, maximumBytes: maximumBytes)
        let byteCount = try validatedFileSize(at: fileURL, maximumBytes: maximumBytes)
        guard allowsEmpty || byteCount > 0 else { throw ValidationError.emptyPayload }
        let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        guard data.count == byteCount else { throw ValidationError.invalidResponse }
        return data
    }

    static func readDownload(
        at fileURL: URL,
        response: URLResponse,
        allowedMediaTypes: Set<String>,
        maximumBytes: Int,
        imageLimits: ImageLimits? = nil
    ) throws -> Data {
        let data = try readResponseBody(
            at: fileURL,
            response: response,
            maximumBytes: maximumBytes,
            allowsEmpty: false
        )
        return try validateDownloadData(
            data,
            response: response,
            allowedMediaTypes: allowedMediaTypes,
            maximumBytes: maximumBytes,
            imageLimits: imageLimits
        )
    }

    /// Validates bytes that were already capped incrementally by
    /// `BoundedURLSessionTransportDelegate`. Rechecking the declared and actual
    /// limits here keeps cached/file-backed callers on the same contract.
    static func validateDownloadData(
        _ data: Data,
        response: URLResponse,
        allowedMediaTypes: Set<String>,
        maximumBytes: Int,
        imageLimits: ImageLimits? = nil
    ) throws -> Data {
        guard maximumBytes > 0,
            let http = response as? HTTPURLResponse,
            (200...299).contains(http.statusCode)
        else {
            throw ValidationError.invalidResponse
        }
        try validateDeclaredSize(response.expectedContentLength, maximumBytes: maximumBytes)
        guard !data.isEmpty else { throw ValidationError.emptyPayload }
        guard data.count <= maximumBytes else {
            throw ValidationError.actualSizeExceedsMaximum
        }

        let mediaType = normalizedMediaType(http.value(forHTTPHeaderField: "Content-Type"))
        guard let mediaType, allowedMediaTypes.contains(mediaType) else {
            throw ValidationError.unexpectedMediaType(mediaType)
        }
        if let imageLimits {
            let actualMediaType = try validateImage(data, limits: imageLimits)
            guard allowedMediaTypes.contains(actualMediaType) else {
                throw ValidationError.unexpectedMediaType(actualMediaType)
            }
            guard actualMediaType == mediaType else {
                throw ValidationError.imageMediaTypeMismatch(
                    declared: mediaType,
                    actual: actualMediaType
                )
            }
        }
        return data
    }

    static func validateCachedData(
        _ data: Data,
        allowedMediaTypes: Set<String>,
        maximumBytes: Int,
        imageLimits: ImageLimits? = nil
    ) throws {
        guard maximumBytes > 0, !data.isEmpty else { throw ValidationError.emptyPayload }
        guard data.count <= maximumBytes else {
            throw ValidationError.actualSizeExceedsMaximum
        }
        if let imageLimits {
            let actualMediaType = try validateImage(data, limits: imageLimits)
            guard allowedMediaTypes.contains(actualMediaType) else {
                throw ValidationError.unexpectedMediaType(actualMediaType)
            }
        }
    }

    static func isValidOpaqueIdentifier(_ value: String) -> Bool {
        guard (8...64).contains(value.utf8.count), value.unicodeScalars.count == value.utf8.count else {
            return false
        }
        return value.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 45, 48...57, 65...90, 97...122:
                true
            default:
                false
            }
        }
    }

    static func normalizedMediaType(_ value: String?) -> String? {
        guard let value else { return nil }
        let type = value.split(separator: ";", maxSplits: 1)[0]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return type.isEmpty ? nil : type
    }

    private static func validateDeclaredSize(
        _ expectedLength: Int64,
        maximumBytes: Int
    ) throws {
        guard expectedLength == NSURLSessionTransferSizeUnknown || expectedLength >= 0 else {
            throw ValidationError.invalidResponse
        }
        guard
            expectedLength == NSURLSessionTransferSizeUnknown
                || expectedLength <= Int64(maximumBytes)
        else {
            throw ValidationError.declaredSizeExceedsMaximum
        }
    }

    private static func validatedFileSize(at url: URL, maximumBytes: Int) throws -> Int {
        let values = try url.resourceValues(
            forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
        )
        guard values.isRegularFile == true,
            values.isSymbolicLink != true,
            let byteCount = values.fileSize
        else {
            throw ValidationError.invalidResponse
        }
        guard byteCount <= maximumBytes else {
            throw ValidationError.actualSizeExceedsMaximum
        }
        return byteCount
    }

    private static func validateImage(_ data: Data, limits: ImageLimits) throws -> String {
        guard limits.maximumWidth > 0,
            limits.maximumHeight > 0,
            limits.maximumPixels > 0,
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            CGImageSourceGetCount(source) == 1,
            let sourceType = CGImageSourceGetType(source) as String?,
            let mediaType = imageMediaType(for: sourceType),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
            let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.int64Value,
            let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.int64Value,
            width > 0,
            height > 0,
            width <= limits.maximumWidth,
            height <= limits.maximumHeight,
            width <= Int64.max / height,
            width * height <= limits.maximumPixels
        else {
            throw ValidationError.invalidImage
        }
        return mediaType
    }

    private static func imageMediaType(for sourceType: String) -> String? {
        switch sourceType.lowercased() {
        case "public.jpeg":
            "image/jpeg"
        case "public.jpeg-2000":
            "image/jp2"
        case "public.png":
            "image/png"
        case "org.webmproject.webp":
            "image/webp"
        case "com.compuserve.gif":
            "image/gif"
        case "public.heic":
            "image/heic"
        case "public.heif":
            "image/heif"
        default:
            nil
        }
    }
}
