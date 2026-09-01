import SwiftUI

/// The login screen shown when the user is not authenticated.
struct LoginView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var viewModel = LoginViewModel()
    @State private var showingForgotPassword = false
    @State private var showingRegistrationSheet = false
    @ScaledMetric(relativeTo: .largeTitle) private var logoSize = 120

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ScrollView {
                    VStack(spacing: 32) {
                        Spacer(minLength: 24)

                        // App branding
                        VStack(spacing: 12) {
                            Image("HausKlarLogo")
                                .resizable()
                                .scaledToFit()
                                .frame(
                                    width: min(logoSize, 160),
                                    height: min(logoSize, 160)
                                )
                                .accessibilityHidden(true)

                            Text("HausKlar")
                                .font(.largeTitle)
                                .fontWeight(.bold)

                            Text("Know what’s happening today.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }

                        // Biometric unlock for stored sessions
                        if appState.hasStoredSession {
                            biometricUnlockSection
                        }

                        // Email/password login form
                        VStack(spacing: 16) {
                            TextField("Email", text: $viewModel.email)
                                .textContentType(.emailAddress)
                                .keyboardType(.emailAddress)
                                .autocapitalization(.none)
                                .disableAutocorrection(true)
                                .submitLabel(.next)
                                .padding()
                                .background(Color(.systemGray6))
                                .cornerRadius(12)
                                .accessibilityIdentifier(HausKlarAccessibilityID.Login.email)

                            SecureField("Password", text: $viewModel.password)
                                .textContentType(.password)
                                .submitLabel(.go)
                                .padding()
                                .background(Color(.systemGray6))
                                .cornerRadius(12)
                                .accessibilityIdentifier(HausKlarAccessibilityID.Login.password)
                        }
                        .padding(.horizontal)

                        // Forgot password link
                        Button("Forgot Password?") {
                            viewModel.forgotPasswordEmail = viewModel.email
                            showingForgotPassword = true
                        }
                        .font(.footnote)

                        // Error messages
                        if let error = viewModel.errorMessage {
                            loginError(
                                error,
                                accessibilityLabel: "Sign-in error",
                                identifier: HausKlarAccessibilityID.Login.error
                            )
                        }
                        if let biometricError = appState.biometricErrorMessage {
                            loginError(
                                biometricError,
                                accessibilityLabel: "Unlock error",
                                identifier: HausKlarAccessibilityID.Login.biometricError
                            )
                        }
                        if !appState.localFitnessRecoveryURLs.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Label("Fitness data preserved", systemImage: "externaldrive.badge.checkmark")
                                    .font(.headline)
                                Text(
                                    "A local Fitness upgrade could not finish. HausKlar did not reset or delete the database or its pending outbox. Share these protected copies for recovery."
                                )
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                ForEach(appState.localFitnessRecoveryURLs, id: \.self) { url in
                                    ShareLink(item: url) {
                                        Label("Share \(url.lastPathComponent)", systemImage: "square.and.arrow.up")
                                    }
                                }
                            }
                            .padding()
                            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                            .padding(.horizontal)
                            .accessibilityElement(children: .contain)
                            .accessibilityIdentifier(HausKlarAccessibilityID.Login.recoveryCopies)
                        }

                        // Log In button
                        Button {
                            viewModel.authMode = .login
                            Task {
                                await viewModel.authenticate(appState: appState)
                            }
                        } label: {
                            if viewModel.isLoading {
                                ProgressView()
                                    .frame(maxWidth: .infinity)
                                    .padding()
                            } else {
                                Text("Log In")
                                    .fontWeight(.semibold)
                                    .frame(maxWidth: .infinity)
                                    .padding()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(viewModel.isLoading)
                        .padding(.horizontal)
                        .accessibilityLabel(
                            Text(viewModel.isLoading ? "Signing in".localized : "Log In".localized)
                        )
                        .accessibilityIdentifier(HausKlarAccessibilityID.Login.submit)

                        // Registration link
                        Button {
                            showingRegistrationSheet = true
                        } label: {
                            Text(
                                viewModel.allowsFamilyCreation
                                    ? "New here? Create or join a family".localized
                                    : "Have an invite? Join a family".localized
                            )
                            .font(.footnote)
                            .foregroundStyle(.blue)
                        }

                        Spacer(minLength: 24)
                    }
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height)
                }
                .scrollDismissesKeyboard(.interactively)
                .accessibilityIdentifier(HausKlarAccessibilityID.Login.screen)
            }
            .navigationBarHidden(true)
            .sheet(isPresented: $showingForgotPassword) {
                forgotPasswordSheet
            }
            .sheet(isPresented: $showingRegistrationSheet) {
                registrationSheet
            }
            .task {
                await viewModel.loadCapabilities()
            }
            .onOpenURL { url in
                if viewModel.acceptInviteURL(url) {
                    showingRegistrationSheet = true
                }
            }
        }
    }

    // MARK: - Biometric Unlock

    private var biometricUnlockSection: some View {
        VStack(spacing: 10) {
            Text("Stored session found".localized)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Button {
                Task {
                    await appState.unlockStoredSessionWithBiometrics()
                }
            } label: {
                Label(appState.biometricButtonTitle, systemImage: appState.biometricIconName)
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding()
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier(HausKlarAccessibilityID.Login.biometricUnlock)
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
        .padding(.horizontal)
    }

    // MARK: - Registration Sheet

    private var registrationSheet: some View {
        NavigationStack {
            List {
                Section {
                    Text("Choose how you want to get started:")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if viewModel.allowsFamilyCreation {
                    // Create a Family
                    Section("Create a Family") {
                        TextField("Your Name", text: $viewModel.userName)
                            .textContentType(.name)

                        TextField("Family Name", text: $viewModel.familyName)
                            .textContentType(.organizationName)

                        TextField("Email", text: $viewModel.email)
                            .textContentType(.emailAddress)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .disableAutocorrection(true)

                        SecureField("Password", text: $viewModel.password)
                            .textContentType(.newPassword)

                        Button {
                            viewModel.authMode = .registerFamily
                            Task {
                                await viewModel.authenticate(appState: appState)
                            }
                        } label: {
                            HStack {
                                if viewModel.isLoading && viewModel.authMode == .registerFamily {
                                    ProgressView()
                                }
                                Text("Create Family Account")
                                    .fontWeight(.semibold)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .disabled(viewModel.isLoading)
                    }
                }

                // Join a Family
                Section("Join a Family") {
                    TextField("Your Name", text: $viewModel.userName)
                        .textContentType(.name)

                    TextField("Invite Code", text: $viewModel.inviteCode)
                        .textInputAutocapitalization(.characters)
                        .disableAutocorrection(true)

                    TextField("Email", text: $viewModel.email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)

                    SecureField("Password", text: $viewModel.password)
                        .textContentType(.newPassword)

                    Button {
                        viewModel.authMode = .joinFamily
                        Task {
                            await viewModel.authenticate(appState: appState)
                        }
                    } label: {
                        HStack {
                            if viewModel.isLoading && viewModel.authMode == .joinFamily {
                                ProgressView()
                            }
                            Text("Join Family")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .disabled(viewModel.isLoading)
                }

                if let error = viewModel.errorMessage {
                    Section {
                        loginError(
                            error,
                            accessibilityLabel: "Account setup error",
                            identifier: HausKlarAccessibilityID.Login.error
                        )
                    }
                }
            }
            .navigationTitle("Get Started")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { showingRegistrationSheet = false }
                }
            }
        }
    }

    // MARK: - Forgot Password Sheet

    private var forgotPasswordSheet: some View {
        NavigationStack {
            Form {
                Section("Request Reset Link") {
                    Text(
                        "Enter your account email, then open the secure link in the email. The link opens HausKlar in your browser so you can choose a new password."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                    TextField("Email", text: $viewModel.forgotPasswordEmail)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)

                    Button {
                        Task {
                            await viewModel.requestPasswordReset()
                        }
                    } label: {
                        if viewModel.isLoading {
                            ProgressView()
                        } else {
                            Text("Email Reset Link")
                        }
                    }
                }

                if let message = viewModel.forgotPasswordMessage {
                    Section {
                        Label(message, systemImage: "checkmark.circle.fill")
                            .font(.footnote)
                            .foregroundStyle(.primary)
                    }
                }

                if let error = viewModel.errorMessage {
                    Section {
                        loginError(
                            error,
                            accessibilityLabel: "Password reset error",
                            identifier: HausKlarAccessibilityID.Login.error
                        )
                    }
                }
            }
            .navigationTitle("Forgot Password")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showingForgotPassword = false }
                }
            }
        }
    }

    private func loginError(
        _ message: String,
        accessibilityLabel: LocalizedStringKey,
        identifier: String
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .accessibilityHidden(true)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .multilineTextAlignment(.leading)
        .padding(.horizontal)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(message)
        .accessibilityIdentifier(identifier)
    }
}

#Preview {
    LoginView()
        .environmentObject(AppState())
}
