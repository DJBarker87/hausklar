import SwiftUI

/// Shown when `must_change_password` is true — forces the user to pick a new password
/// before accessing the app.
struct ChangePasswordView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    var isRequired = true

    @State private var currentPassword = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var isLoading = false
    @State private var errorMessage: String?

    private let authService = AuthService()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(isRequired
                         ? "Please choose a new password to continue."
                         : "Use at least 12 characters and choose a password you do not use elsewhere.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Section("Current Password") {
                    SecureField("Current password", text: $currentPassword)
                        .textContentType(.password)
                }

                Section("New Password") {
                    SecureField("New password", text: $newPassword)
                        .textContentType(.newPassword)
                    SecureField("Confirm new password", text: $confirmPassword)
                        .textContentType(.newPassword)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }

                Section {
                    Button {
                        Task { await changePassword() }
                    } label: {
                        if isLoading {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else {
                            Text("Change Password")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(isLoading || newPassword.isEmpty || confirmPassword.isEmpty || currentPassword.isEmpty)
                }
            }
            .navigationTitle("Change Password")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if isRequired {
                        Button("Log Out") {
                            Task { await appState.logoutAndRevoke() }
                        }
                    } else {
                        Button("Cancel") {
                            dismiss()
                        }
                    }
                }
            }
        }
    }

    private func changePassword() async {
        guard !newPassword.isEmpty else {
            errorMessage = "Please enter a new password."
            return
        }
        guard newPassword == confirmPassword else {
            errorMessage = "Passwords do not match."
            return
        }
        guard newPassword.count >= 12 else {
            errorMessage = "New password must be at least 12 characters."
            return
        }
        guard newPassword != currentPassword else {
            errorMessage = "New password must be different from current password."
            return
        }

        isLoading = true
        errorMessage = nil

        do {
            let result = try await authService.changePassword(
                currentPassword: currentPassword,
                newPassword: newPassword
            )
            try await appState.passwordChanged(
                accessToken: result.accessToken,
                refreshToken: result.refreshToken,
                user: result.user
            )
            if !isRequired {
                dismiss()
            }
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "An unexpected error occurred. Please try again."
        }

        isLoading = false
    }
}
