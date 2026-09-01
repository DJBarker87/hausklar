import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

/// Parent-facing setup for a detailed handover and booking-scoped caregiver access.
/// Caregivers open the generated link in the read-only web view; the native app
/// never turns an authenticated family session into an unrestricted kiosk.
struct BabysitterModeView: View {
    @StateObject private var viewModel = BabysitterViewModel()
    @State private var showingEditor = false
    @State private var showingBooking = false
    @State private var bookingToRevoke: CaregiverBookingDTO?

    private var openBookings: [CaregiverBookingDTO] {
        viewModel.bookings.filter { $0.status == "active" || $0.status == "upcoming" }
    }

    private var pastBookings: [CaregiverBookingDTO] {
        viewModel.bookings.filter { $0.status != "active" && $0.status != "upcoming" }
    }

    var body: some View {
        Group {
            if viewModel.isLoading && viewModel.handover == nil {
                ProgressView("Loading handover…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let handover = viewModel.handover {
                List {
                    if let error = viewModel.errorMessage {
                        statusRow(error, icon: "exclamationmark.triangle.fill", color: .orange)
                    }
                    if let notice = viewModel.noticeMessage {
                        statusRow(notice, icon: "checkmark.circle.fill", color: .green)
                    }

                    readinessSection(handover)
                    bookingsSection
                    if !pastBookings.isEmpty { pastBookingsSection }

                    Section {
                        Label {
                            Text("A sitter sees only the selected children, only during the booking, and cannot change family data or record medicine.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } icon: {
                            Image(systemName: "lock.example_9ab66176")
                                .foregroundStyle(.blue)
                        }
                    }
                }
                .listStyle(.insetGrouped)
            } else {
                ContentUnavailableView {
                    Label("Handover unavailable", systemImage: "person.example_35fbacff.circle.badge.exclamationmark")
                } description: {
                    Text(viewModel.errorMessage ?? "Try loading the caregiver handover again.")
                } actions: {
                    Button("Try again") { Task { await viewModel.loadData() } }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .navigationTitle("Babysitter handover")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            if viewModel.handover != nil {
                ToolbarItem(placement: .primaryAction) {
                    Button("Edit") {
                        viewModel.errorMessage = nil
                        showingEditor = true
                    }
                }
            }
        }
        .refreshable { await viewModel.loadData() }
        .task { if viewModel.handover == nil { await viewModel.loadData() } }
        .sheet(isPresented: $showingEditor) {
            CaregiverHandoverEditor(viewModel: viewModel)
        }
        .sheet(isPresented: $showingBooking) {
            CaregiverBookingEditor(viewModel: viewModel)
        }
        .sheet(item: $viewModel.createdBooking) { booking in
            CaregiverShareSheet(booking: booking)
        }
        .alert("Revoke caregiver access?", isPresented: Binding(
            get: { bookingToRevoke != nil },
            set: { if !$0 { bookingToRevoke = nil } }
        )) {
            Button("Cancel", role: .cancel) { bookingToRevoke = nil }
            Button("Revoke", role: .destructive) {
                guard let booking = bookingToRevoke else { return }
                bookingToRevoke = nil
                Task { await viewModel.revoke(booking) }
            }
        } message: {
            Text("The sitter's open session will stop working immediately.")
        }
    }

    @ViewBuilder
    private func readinessSection(_ handover: CaregiverHandoverDTO) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Image(systemName: handover.readiness.ready ? "checkmark.shield.fill" : "checklist")
                        .font(.title)
                        .foregroundStyle(handover.readiness.ready ? .green : .orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(handover.readiness.ready ? "Ready to share" : "Handover readiness")
                            .font(.headline)
                        Text("\(handover.readiness.completeCount) of \(handover.readiness.totalCount) details ready")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                ProgressView(
                    value: Double(handover.readiness.completeCount),
                    total: Double(max(handover.readiness.totalCount, 1))
                )
                .tint(handover.readiness.ready ? .green : .orange)

                let missing = handover.readiness.items.filter { !$0.ready }
                if !missing.isEmpty {
                    DisclosureGroup("Still needed") {
                        ForEach(missing) { item in
                            Label(item.label, systemImage: "circle")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text("Care, food, comfort, bedtime, home and emergency details are present.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Button {
                    viewModel.errorMessage = nil
                    showingEditor = true
                } label: {
                    Label("Edit handover", systemImage: "square.and.pencil")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .padding(.vertical, 4)
        } header: {
            Text("Parent-owned details")
        } footer: {
            Text("Nothing is inferred. Write “None known” where a child has no allergies.")
        }
    }

    @ViewBuilder
    private var bookingsSection: some View {
        Section {
            if openBookings.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "person.example_4163b177.key")
                        .font(.title)
                        .foregroundStyle(.secondary)
                    Text("No open caregiver access")
                        .font(.headline)
                    Text("Create a private, time-limited link when a sitter is due.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            } else {
                ForEach(openBookings) { booking in
                    bookingRow(booking)
                }
            }

            Button {
                viewModel.errorMessage = nil
                showingBooking = true
            } label: {
                Label("Create sitter link", systemImage: "key.viewfinder")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        } header: {
            Text("Bookings")
        } footer: {
            Text("You choose the children and exact access window. A link opens once and can be revoked at any time.")
        }
    }

    @ViewBuilder
    private var pastBookingsSection: some View {
        Section("Past access") {
            ForEach(pastBookings.prefix(10)) { booking in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(booking.label)
                        Text(booking.childNames.joined(separator: " & "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(booking.status.capitalized)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func bookingRow(_ booking: CaregiverBookingDTO) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(booking.label)
                        .font(.headline)
                    Text(booking.childNames.joined(separator: " & "))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(bookingWindow(booking))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(booking.status == "active" ? "Active now" : "Upcoming")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(booking.status == "active" ? .green : .blue)
            }
            HStack {
                if let opened = booking.lastAccessedAt {
                    Label("Opened \(time(opened))", systemImage: "eye")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Label("Not opened", systemImage: "eye.slash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Revoke", role: .destructive) { bookingToRevoke = booking }
                    .disabled(viewModel.workingID == booking.id)
            }
        }
        .padding(.vertical, 4)
    }

    private func statusRow(_ text: String, icon: String, color: Color) -> some View {
        Label(text, systemImage: icon)
            .font(.subheadline)
            .foregroundStyle(color)
            .accessibilityElement(children: .combine)
    }

    private func bookingWindow(_ booking: CaregiverBookingDTO) -> String {
        guard let start = ISODateParser.parse(booking.startsAt),
              let end = ISODateParser.parse(booking.expiresAt) else { return "Time unavailable" }
        return start.formatted(date: .abbreviated, time: .shortened)
            + "–" + end.formatted(date: .omitted, time: .shortened)
    }

    private func time(_ value: String) -> String {
        ISODateParser.parse(value)?.formatted(date: .omitted, time: .shortened) ?? value
    }
}

private struct CaregiverHandoverEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: BabysitterViewModel

    var body: some View {
        NavigationStack {
            Form {
                if let error = viewModel.errorMessage {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                    }
                }
                Section {
                    ForEach($viewModel.childDrafts) { $child in
                        DisclosureGroup(child.childName) {
                            CaregiverMultilineField(title: "Care and routine", text: $child.careNotes)
                            CaregiverMultilineField(title: "Allergies (or “None known”)", text: $child.allergies)
                            CaregiverMultilineField(title: "Food and drinks", text: $child.food)
                            CaregiverMultilineField(title: "Comfort and calming", text: $child.comfort)
                            CaregiverMultilineField(title: "Toileting", text: $child.toileting)
                            CaregiverMultilineField(title: "Bedtime", text: $child.bedtime)
                        }
                    }
                } header: {
                    Text("Children")
                } footer: {
                    Text("Write practical instructions a sitter can follow without guessing.")
                }

                Section("Home") {
                    CaregiverMultilineField(title: "Home address", text: $viewModel.houseDraft.address)
                    TextField("Wi-Fi name (optional)", text: $viewModel.houseDraft.wifiName)
                    SecureField("Wi-Fi password", text: $viewModel.houseDraft.wifiPassword)
                        .textContentType(.password)
                    CaregiverMultilineField(title: "House instructions", text: $viewModel.houseDraft.houseInstructions)
                    CaregiverMultilineField(title: "Dog instructions (optional)", text: $viewModel.houseDraft.dogInstructions)
                }

                Section {
                    CaregiverMultilineField(title: "What to do and who to call", text: $viewModel.houseDraft.emergencyInstructions)
                    ForEach($viewModel.contactDrafts) { $contact in
                        VStack(alignment: .leading, spacing: 8) {
                            TextField("Name", text: $contact.name)
                                .textContentType(.name)
                            TextField("Phone", text: $contact.phone)
                                .keyboardType(.phonePad)
                                .textContentType(.telephoneNumber)
                            TextField("Relationship (optional)", text: $contact.relationship)
                        }
                        .padding(.vertical, 4)
                    }
                    .onDelete(perform: viewModel.removeContacts)
                    Button {
                        viewModel.addContact()
                    } label: {
                        Label("Add emergency contact", systemImage: "plus")
                    }
                } header: {
                    Text("Emergency")
                }
            }
            .navigationTitle("Edit handover")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(viewModel.workingID == "handover")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        viewModel.discardDraftChanges()
                        dismiss()
                    }
                    .disabled(viewModel.workingID == "handover")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(viewModel.workingID == "handover" ? "Saving…" : "Save") {
                        Task {
                            if await viewModel.saveHandover() { dismiss() }
                        }
                    }
                    .disabled(viewModel.workingID == "handover")
                }
            }
        }
    }
}

private struct CaregiverMultilineField: View {
    let title: String
    @Binding var text: String

    var body: some View {
        TextField(title, text: $text, axis: .vertical)
            .lineLimit(2...6)
    }
}

private struct CaregiverBookingEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: BabysitterViewModel
    @State private var label = "Babysitter"
    @State private var startsAt = Date()
    @State private var expiresAt = Date().addingTimeInterval(5 * 60 * 60)
    @State private var childIDs: Set<String>

    init(viewModel: BabysitterViewModel) {
        self.viewModel = viewModel
        _childIDs = State(initialValue: Set(viewModel.childDrafts.map(\.childId)))
    }

    private var missing: [String] { viewModel.missingReadiness(for: childIDs) }

    private var bookingWindowIsValid: Bool {
        expiresAt > startsAt
            && expiresAt > Date()
            && expiresAt.timeIntervalSince(startsAt) <= 7 * 24 * 60 * 60
    }

    var body: some View {
        NavigationStack {
            Form {
                if let error = viewModel.errorMessage {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                    }
                }
                Section("Booking") {
                    TextField("Booking name", text: $label)
                    DatePicker("Starts", selection: $startsAt)
                    DatePicker("Ends", selection: $expiresAt)
                    if !bookingWindowIsValid {
                        Label(
                            "Choose an end after the start, within seven days, and still in the future.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.footnote)
                        .foregroundStyle(.orange)
                    }
                }

                Section("Children in this handover") {
                    ForEach(viewModel.childDrafts) { child in
                        Toggle(child.childName, isOn: Binding(
                            get: { childIDs.contains(child.childId) },
                            set: { selected in
                                if selected { childIDs.insert(child.childId) }
                                else { childIDs.remove(child.childId) }
                            }
                        ))
                    }
                }

                if !missing.isEmpty {
                    Section("Finish before sharing") {
                        ForEach(missing, id: \.self) { item in
                            Label(item, systemImage: "circle")
                                .foregroundStyle(.secondary)
                        }
                        Button("Close to edit handover") {
                            dismiss()
                        }
                    }
                }

                Section {
                    Label(
                        "The link opens once, then works only on that browser until this booking ends or you revoke it.",
                        systemImage: "lock.example_9ab66176"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Create sitter access")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(viewModel.workingID == "booking")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(viewModel.workingID == "booking")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(viewModel.workingID == "booking" ? "Creating…" : "Create") {
                        Task {
                            await viewModel.createBooking(
                                label: label,
                                startsAt: startsAt,
                                expiresAt: expiresAt,
                                childIDs: childIDs
                            )
                            if viewModel.createdBooking != nil { dismiss() }
                        }
                    }
                    .disabled(
                        viewModel.workingID == "booking"
                            || childIDs.isEmpty
                            || !missing.isEmpty
                            || !bookingWindowIsValid
                    )
                }
            }
        }
    }
}

private struct CaregiverShareSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    let booking: CaregiverCreatedBookingDTO
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 42))
                        .foregroundStyle(.green)
                    VStack(spacing: 5) {
                        Text("Sitter link ready")
                            .font(.title2.bold())
                        Text(booking.childNames.joined(separator: " & "))
                            .foregroundStyle(.secondary)
                    }

                    Group {
                        if scenePhase == .active, let image = qrImage(booking.shareUrl) {
                            Image(uiImage: image)
                                .interpolation(.none)
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: 260)
                                .accessibilityLabel("QR code for private sitter access")
                        } else {
                            ContentUnavailableView(
                                "Private link hidden",
                                systemImage: "eye.slash",
                                description: Text("Return to HausKlar to show the QR code.")
                            )
                            .frame(height: 260)
                        }
                    }
                    .padding()
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
                    .privacySensitive()

                    if let url = booking.url {
                        ShareLink(item: url, subject: Text("HausKlar sitter handover")) {
                            Label("Share private link", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)

                        Button {
                            copyToPasteboard(booking.shareUrl)
                            copied = true
                        } label: {
                            Label(copied ? "Copied" : "Copy private link", systemImage: copied ? "checkmark" : "doc.on.doc")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }

                    VStack(alignment: .leading, spacing: 9) {
                        Label("Works from \(startTime)", systemImage: "clock")
                        Label("Opens once", systemImage: "1.circle")
                        Label("Selected children only", systemImage: "person.example_f47e224f")
                        Label("Read-only — no medicine recording", systemImage: "hand.raised")
                        Label("Ends automatically at \(endTime)", systemImage: "clock.badge.checkmark")
                    }
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))

                    Label(
                        "Share this before closing. For safety, HausKlar cannot show this exact link again.",
                        systemImage: "exclamationmark.shield"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(booking.label)
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(false)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var endTime: String {
        ISODateParser.parse(booking.expiresAt)?.formatted(date: .abbreviated, time: .shortened)
            ?? booking.expiresAt
    }

    private var startTime: String {
        ISODateParser.parse(booking.startsAt)?.formatted(date: .abbreviated, time: .shortened)
            ?? booking.startsAt
    }

    private func qrImage(_ value: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 9, y: 9)),
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    private func copyToPasteboard(_ value: String) {
        let expiration = ISODateParser.parse(booking.expiresAt) ?? Date().addingTimeInterval(6 * 60 * 60)
        SensitiveClipboard.copy(
            value,
            expiresAt: expiration,
            maximumLifetime: 6 * 60 * 60
        )
    }
}

#Preview {
    NavigationStack { BabysitterModeView() }
}
