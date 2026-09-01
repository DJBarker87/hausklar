import Foundation

/// A relative HausKlar API route whose interpolated values are always treated
/// as one path segment. Static separators remain literals; dynamic values can
/// never introduce another route, query, or fragment component.
struct APIRequestPath: Hashable, Sendable, ExpressibleByStringLiteral,
    ExpressibleByStringInterpolation
{

    enum ValidationError: Error, Equatable, Sendable {
        case invalidStructure
        case invalidDynamicSegment
        case excessiveLength
    }

    static let maximumPathBytes = 4_096
    static let maximumDynamicSegmentBytes = 512

    private let storage: String
    private let interpolationError: ValidationError?

    init(stringLiteral value: String) {
        storage = value
        interpolationError = nil
    }

    init(stringInterpolation: StringInterpolation) {
        storage = stringInterpolation.storage
        interpolationError = stringInterpolation.error
    }

    struct StringInterpolation: StringInterpolationProtocol {
        fileprivate var storage: String
        fileprivate var error: ValidationError?

        init(literalCapacity: Int, interpolationCount: Int) {
            storage = ""
            storage.reserveCapacity(literalCapacity + (interpolationCount * 36))
        }

        mutating func appendLiteral(_ literal: String) {
            storage.append(literal)
        }

        mutating func appendInterpolation<T>(_ value: T) {
            guard error == nil else { return }
            guard let encoded = APIRequestPath.encodeDynamicSegment(String(describing: value)) else {
                error = .invalidDynamicSegment
                return
            }
            storage.append(encoded)
        }

        mutating func appendInterpolation<T>(_ value: T?) {
            guard let value else {
                error = .invalidDynamicSegment
                return
            }
            appendInterpolation(value)
        }
    }

    /// Returns the canonical percent-encoded relative path. Callers map any
    /// validation failure to their public invalid-URL error before credentials,
    /// operation IDs, request bodies, or transport are touched.
    func validatedValue() throws -> String {
        if let interpolationError { throw interpolationError }
        try Self.validateStoredValue(storage)
        return storage
    }

    /// Revalidates durable queue entries and any other path restored from disk.
    /// Stored values never bypass the same structural rules as newly built paths.
    static func validateStoredValue(_ value: String) throws {
        guard !value.isEmpty,
            value.utf8.count <= maximumPathBytes,
            value.hasPrefix("/"),
            !value.hasPrefix("//"),
            !value.contains("?"),
            !value.contains("#"),
            !value.contains("\\"),
            !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
            hasOnlyValidPercentEscapes(value)
        else {
            throw value.utf8.count > maximumPathBytes
                ? ValidationError.excessiveLength
                : ValidationError.invalidStructure
        }

        let segments = value.split(separator: "/", omittingEmptySubsequences: false)
        guard segments.first?.isEmpty == true else {
            throw ValidationError.invalidStructure
        }
        for encodedSubstring in segments.dropFirst() {
            let encoded = String(encodedSubstring)
            guard let decoded = encoded.removingPercentEncoding,
                decoded != ".",
                decoded != "..",
                !decoded.contains("/"),
                !decoded.contains("\\"),
                !decoded.contains("?"),
                !decoded.contains("#"),
                !decoded.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            else {
                throw ValidationError.invalidStructure
            }
        }

        var components = URLComponents()
        components.percentEncodedPath = value
        guard components.percentEncodedPath == value,
            components.query == nil,
            components.fragment == nil,
            components.url?.absoluteString == value
        else {
            throw ValidationError.invalidStructure
        }
    }

    private static func encodeDynamicSegment(_ value: String) -> String? {
        guard !value.isEmpty,
            value.utf8.count <= maximumDynamicSegmentBytes,
            value != ".",
            value != "..",
            !value.contains("/"),
            !value.contains("\\"),
            !value.contains("?"),
            !value.contains("#"),
            !value.contains("%"),
            !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { return nil }

        var result = ""
        result.reserveCapacity(value.utf8.count)
        for byte in value.utf8 {
            if isUnreserved(byte) {
                result.unicodeScalars.append(UnicodeScalar(byte))
            } else {
                result.append(String(format: "%%%02X", byte))
            }
        }
        return result
    }

    private static func isUnreserved(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x2D, 0x2E, 0x5F, 0x7E:
            return true
        default:
            return false
        }
    }

    private static func hasOnlyValidPercentEscapes(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        var index = 0
        while index < bytes.count {
            guard bytes[index] == 0x25 else {
                index += 1
                continue
            }
            guard index + 2 < bytes.count,
                isHexadecimal(bytes[index + 1]),
                isHexadecimal(bytes[index + 2])
            else { return false }
            index += 3
        }
        return true
    }

    private static func isHexadecimal(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte)
            || (0x41...0x46).contains(byte)
            || (0x61...0x66).contains(byte)
    }
}
