import Foundation

/// Empty request body for POST/PATCH endpoints that require a body but have no payload.
struct EmptyBody: Encodable {}

/// Raw authenticated response for protocols whose non-2xx bodies are part of the contract.
struct APIHTTPResponse: Sendable {
    let statusCode: Int
    let data: Data
}

/// Errors that can occur during API operations.
enum APIError: LocalizedError {
    case invalidURL
    case unauthorized
    case forbidden
    case notFound
    case conflict
    case serverError(statusCode: Int, message: String?)
    case decodingError(Error)
    case networkError(Error)
    case offlineQueued
    case offlineQueueFull
    case tokenRefreshFailed

    /// Returns true for errors that indicate the session is invalid and the user should be logged out.
    var isAuthError: Bool {
        switch self {
        case .unauthorized, .forbidden, .tokenRefreshFailed:
            return true
        default:
            return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid URL."
        case .unauthorized:
            return "You are not authorised. Please log in again."
        case .forbidden:
            return "You do not have permission to perform this action."
        case .notFound:
            return "The requested resource was not found."
        case .conflict:
            return "A conflict occurred. Please try again."
        case .serverError(let statusCode, let message):
            return message ?? "Server error (\(statusCode))."
        case .decodingError(let error):
            return "Failed to process response: \(error.localizedDescription)"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .offlineQueued:
            return "Saved offline. It will sync automatically."
        case .offlineQueueFull:
            return "Offline storage is full. Reconnect and sync before saving more changes."
        case .tokenRefreshFailed:
            return "Session expired. Please log in again."
        }
    }
}
