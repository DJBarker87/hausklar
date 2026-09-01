import Foundation
import SwiftUI
import os

/// ViewModel for the login screen. Handles form state and authentication logic.
@MainActor
final class LoginViewModel: ObservableObject {

    private static let logger = Logger(
        subsystem: "org.example.hausklar",
        category: "LoginViewModel"
    )

    enum AuthMode: Int, CaseIterable, Identifiable {
        case login
        case registerFamily
        case joinFamily

        var id: Int { rawValue }
    }

    // MARK: - Form State

    @Published var authMode: AuthMode = .login
    @Published var email: String = ""
    @Published var password: String = ""
    @Published var userName: String = ""
    @Published var familyName: String = ""
    @Published var inviteCode: String = ""
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
    @Published var forgotPasswordEmail: String = ""
    @Published var forgotPasswordMessage: String?
    @Published var resetToken: String = ""
    @Published var newPassword: String = ""
    @Published var confirmNewPassword: String = ""
    @Published private(set) var allowsFamilyCreation = false

    // MARK: - Dependencies

    private let authService = AuthService()

    // MARK: - Actions

    func loadCapabilities() async {
        do {
            allowsFamilyCreation = try await authService.allowsPublicRegistration()
        } catch is CancellationError {
            return
        } catch {
            // Registration remains fail-closed when capability discovery is
            // unavailable; a later screen task retries the authoritative check.
            allowsFamilyCreation = false
            Self.logger.info(
                "Public-registration capability check failed closed."
            )
        }
    }

    @discardableResult
    func acceptInviteURL(_ url: URL) -> Bool {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var items = components?.queryItems ?? []
        if let fragment = components?.fragment {
            components = URLComponents(string: "?\(fragment)")
            items.append(contentsOf: components?.queryItems ?? [])
        }
        guard let value = items.first(where: { $0.name.lowercased() == "join" })?.value?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return false }
        inviteCode = value.uppercased()
        authMode = .joinFamily
        errorMessage = nil
        return true
    }

    /// Performs the selected auth action and logs in on success.
    func authenticate(appState: AppState) async {
        guard !email.trimmingCharacters(in: .whitespaces).isEmpty else {
            errorMessage = "Please enter your email address.".localized
            return
        }
        guard !password.isEmpty else {
            errorMessage = "Please enter your password.".localized
            return
        }
        if authMode != .login {
            guard !userName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                errorMessage = "Please enter your name.".localized
                return
            }
        }
        if authMode == .registerFamily {
            guard !familyName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                errorMessage = "Please enter your family name.".localized
                return
            }
        }
        if authMode == .joinFamily {
            guard !inviteCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                errorMessage = "Please enter an invite code.".localized
                return
            }
        }

        isLoading = true
        errorMessage = nil

        do {
            let result: (accessToken: String, refreshToken: String, user: UserProfile)
            switch authMode {
            case .login:
                result = try await authService.login(email: email, password: password)
            case .registerFamily:
                result = try await authService.registerFamily(
                    familyName: familyName.trimmingCharacters(in: .whitespacesAndNewlines),
                    userName: userName.trimmingCharacters(in: .whitespacesAndNewlines),
                    email: email,
                    password: password
                )
            case .joinFamily:
                result = try await authService.joinFamily(
                    inviteCode: inviteCode.trimmingCharacters(in: .whitespacesAndNewlines),
                    userName: userName.trimmingCharacters(in: .whitespacesAndNewlines),
                    email: email,
                    password: password
                )
            }
            try await appState.login(
                accessToken: result.accessToken,
                refreshToken: result.refreshToken,
                user: result.user
            )
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch let error as ClientIdentityError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "An unexpected error occurred. Please try again.".localized
        }

        isLoading = false
    }

    func requestPasswordReset() async {
        let candidate = forgotPasswordEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else {
            errorMessage = "Please enter your email address.".localized
            return
        }

        isLoading = true
        errorMessage = nil
        forgotPasswordMessage = nil

        do {
            let response = try await authService.forgotPassword(email: candidate)
            forgotPasswordMessage = response.message
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "An unexpected error occurred. Please try again.".localized
        }

        isLoading = false
    }

    func completePasswordReset() async {
        let token = resetToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            errorMessage = "Please enter your reset token.".localized
            return
        }
        guard !newPassword.isEmpty else {
            errorMessage = "Please enter a new password.".localized
            return
        }
        guard newPassword == confirmNewPassword else {
            errorMessage = "Passwords do not match.".localized
            return
        }

        isLoading = true
        errorMessage = nil

        do {
            try await authService.resetPassword(token: token, newPassword: newPassword)
            forgotPasswordMessage = "Password has been reset. You can now log in with your new password."
            password = ""
            resetToken = ""
            newPassword = ""
            confirmNewPassword = ""
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "An unexpected error occurred. Please try again.".localized
        }

        isLoading = false
    }
}
