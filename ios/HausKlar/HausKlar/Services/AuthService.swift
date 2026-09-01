import Foundation
import os

/// Handles all authentication-related API calls.
struct AuthService: Sendable {

    private let client = APIClient.shared

    private static let logger = Logger(subsystem: "org.example.hausklar", category: "AuthService")

    // MARK: - Request / Response Types

    struct LoginRequest: Encodable {
        let email: String
        let password: String
    }

    struct AppleLoginRequest: Encodable {
        let identityToken: String
        let fullName: String?
    }

    struct LoginResponse: Decodable {
        let accessToken: String
        let refreshToken: String
        let user: UserResponse
    }

    struct UserResponse: Decodable {
        let id: String
        let name: String
        let email: String
        let role: String
        let priority: Int
        let familyId: String?
        let mustChangePassword: Bool?
    }

    struct RefreshRequest: Encodable {
        let refreshToken: String
    }

    struct RefreshResponse: Decodable {
        let accessToken: String
        let refreshToken: String
    }

    struct ForgotPasswordRequest: Encodable {
        let email: String
    }
    struct ForgotPasswordResponse: Decodable {
        let message: String
    }

    struct RegisterFamilyRequest: Encodable {
        let familyName: String
        let userName: String
        let email: String
        let password: String
    }

    struct JoinFamilyRequest: Encodable {
        let inviteCode: String
        let userName: String
        let email: String
        let password: String
    }

    struct ResetPasswordRequest: Encodable {
        let token: String
        let newPassword: String
    }

    struct EmptyResponse: Decodable {}
    struct CapabilitiesResponse: Decodable {
        let publicRegistration: Bool
    }
    struct InviteCodeResponse: Decodable {
        let inviteCode: String
        let expiresAt: String
        let joinUrl: String
    }

    // MARK: - Public Methods

    func allowsPublicRegistration() async throws -> Bool {
        let response: CapabilitiesResponse = try await client.get("/auth/capabilities")
        return response.publicRegistration
    }

    /// Authenticates the user and returns tokens plus the user profile.
    func login(email: String, password: String) async throws -> (accessToken: String, refreshToken: String, user: UserProfile) {
        let body = LoginRequest(email: email, password: password)
        let response: LoginResponse = try await client.post("/auth/login", body: body)

        let user = UserProfile(
            id: response.user.id,
            name: response.user.name,
            email: response.user.email,
            role: response.user.role,
            priority: response.user.priority,
            familyId: response.user.familyId,
            mustChangePassword: response.user.mustChangePassword
        )

        return (response.accessToken, response.refreshToken, user)
    }

    /// Authenticates via Sign in with Apple and returns tokens plus the user profile.
    func loginWithApple(identityToken: String, fullName: PersonNameComponents?) async throws -> (accessToken: String, refreshToken: String, user: UserProfile) {
        var nameString: String?
        if let fullName {
            let formatter = PersonNameComponentsFormatter()
            let formatted = formatter.string(from: fullName).trimmingCharacters(in: .whitespacesAndNewlines)
            if !formatted.isEmpty {
                nameString = formatted
            }
        }
        let body = AppleLoginRequest(identityToken: identityToken, fullName: nameString)
        let response: LoginResponse = try await client.post("/auth/apple", body: body)

        let user = UserProfile(
            id: response.user.id,
            name: response.user.name,
            email: response.user.email,
            role: response.user.role,
            priority: response.user.priority,
            familyId: response.user.familyId,
            mustChangePassword: response.user.mustChangePassword
        )

        return (response.accessToken, response.refreshToken, user)
    }

    /// Refreshes the access token using the current refresh token.
    func refreshToken() async throws -> String {
        guard let expectedSession = client.currentSessionSnapshot() else {
            throw APIError.tokenRefreshFailed
        }
        let body = RefreshRequest(refreshToken: expectedSession.refreshToken)
        let response: RefreshResponse = try await client.post("/auth/refresh", body: body)
        guard client.installRefreshedTokens(
            accessToken: response.accessToken,
            refreshToken: response.refreshToken,
            expectedSession: expectedSession
        ) else {
            throw APIError.unauthorized
        }
        return response.accessToken
    }

    struct LogoutRequest: Encodable {
        let refreshToken: String
    }

    /// Logs out the current user, invalidating the refresh token on the server.
    func logout() async throws {
        guard let currentRefresh = client.refreshToken else { return }
        let body = LogoutRequest(refreshToken: currentRefresh)
        try await client.postNoResponse("/auth/logout", body: body)
    }

    /// Requests a password reset token for the given address.
    func forgotPassword(email: String) async throws -> ForgotPasswordResponse {
        let body = ForgotPasswordRequest(email: email)
        let response: ForgotPasswordResponse = try await client.post("/auth/forgot-password", body: body)
        return response
    }

    /// Creates a new family account and returns tokens plus profile.
    func registerFamily(
        familyName: String,
        userName: String,
        email: String,
        password: String
    ) async throws -> (accessToken: String, refreshToken: String, user: UserProfile) {
        let body = RegisterFamilyRequest(
            familyName: familyName,
            userName: userName,
            email: email,
            password: password
        )
        let response: LoginResponse = try await client.post("/auth/register-family", body: body)
        let user = UserProfile(
            id: response.user.id,
            name: response.user.name,
            email: response.user.email,
            role: response.user.role,
            priority: response.user.priority,
            familyId: response.user.familyId,
            mustChangePassword: response.user.mustChangePassword
        )
        return (response.accessToken, response.refreshToken, user)
    }

    /// Joins an existing family via invite code and returns tokens plus profile.
    func joinFamily(
        inviteCode: String,
        userName: String,
        email: String,
        password: String
    ) async throws -> (accessToken: String, refreshToken: String, user: UserProfile) {
        let body = JoinFamilyRequest(
            inviteCode: inviteCode,
            userName: userName,
            email: email,
            password: password
        )
        let response: LoginResponse = try await client.post("/auth/join-family", body: body)
        let user = UserProfile(
            id: response.user.id,
            name: response.user.name,
            email: response.user.email,
            role: response.user.role,
            priority: response.user.priority,
            familyId: response.user.familyId,
            mustChangePassword: response.user.mustChangePassword
        )
        return (response.accessToken, response.refreshToken, user)
    }

    /// Completes a password reset using the token from the reset email.
    func resetPassword(token: String, newPassword: String) async throws {
        let body = ResetPasswordRequest(token: token, newPassword: newPassword)
        let _: EmptyResponse = try await client.post("/auth/reset-password", body: body)
    }

    struct ChangePasswordRequest: Encodable {
        let currentPassword: String
        let newPassword: String
    }

    /// Changes the current user's password and returns the server-rotated session.
    func changePassword(
        currentPassword: String,
        newPassword: String
    ) async throws -> (accessToken: String, refreshToken: String, user: UserProfile) {
        let body = ChangePasswordRequest(currentPassword: currentPassword, newPassword: newPassword)
        let response: LoginResponse = try await client.post("/auth/change-password", body: body)
        let user = UserProfile(
            id: response.user.id,
            name: response.user.name,
            email: response.user.email,
            role: response.user.role,
            priority: response.user.priority,
            familyId: response.user.familyId,
            mustChangePassword: response.user.mustChangePassword
        )
        return (response.accessToken, response.refreshToken, user)
    }

    /// Soft-deletes the authenticated user account server-side.
    func deleteMyAccount() async throws {
        try await client.delete("/auth/me")
    }

    /// Generates a new family invite code (admin only).
    func generateInviteCode() async throws -> InviteCodeResponse {
        try await client.post("/auth/invite", body: EmptyBody())
    }
}
