import SwiftUI

struct CommitmentCreateView: View {
    let kind: CommitmentKind
    @ObservedObject var viewModel: CommitmentsViewModel
    let onBack: () -> Void
    let onQueued: () -> Void

    var body: some View {
        Group {
            switch kind {
            case .outing:
                CommitmentOutingCreateView(
                    viewModel: viewModel,
                    onBack: onBack,
                    onQueued: onQueued
                )
            case .childcare:
                CommitmentChildcareCreateView(
                    viewModel: viewModel,
                    onBack: onBack,
                    onQueued: onQueued
                )
            case .school, .invitation, .appointment, .travel:
                CommitmentSourceCreateView(
                    kind: kind,
                    viewModel: viewModel,
                    onBack: onBack
                )
            }
        }
    }
}

private struct CommitmentSourceCreateView: View {
    let kind: CommitmentKind
    @ObservedObject var viewModel: CommitmentsViewModel
    let onBack: () -> Void

    @EnvironmentObject private var networkMonitor: NetworkMonitor
    @State private var title = ""
    @State private var reviewedText = ""
    @State private var documentId = ""
    @State private var sourceLabel = ""
    @State private var providerReference = ""
    @State private var visibility = CommitmentVisibility.family
    @State private var supersedesId = ""
    @State private var useHermes = false

    var body: some View {
        Form {
            backSection

            Section {
                if !networkMonitor.isConnected {
                    Label(
                        "Reconnect before interpreting a message or document. Nothing will be queued.",
                        systemImage: "wifi.slash"
                    )
                    .foregroundStyle(.orange)
                }

                TextField("Plan title (optional)", text: $title, axis: .vertical)
                    .textInputAutocapitalization(.sentences)
                    .accessibilityIdentifier("commitmentSourceTitle")

                Picker("Source document (optional)", selection: $documentId) {
                    Text("No attached document").tag("")
                    ForEach(viewModel.documents) { document in
                        Text(document.title).tag(document.id)
                    }
                }
                .accessibilityIdentifier("commitmentSourceDocument")
                .onChange(of: documentId) { _, value in
                    chooseDocument(value)
                }

                TextField("Source name (optional)", text: $sourceLabel)
                    .accessibilityIdentifier("commitmentSourceLabel")

                TextField(referenceTitle, text: $providerReference)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("commitmentSourceReference")

                Picker("Who can see this draft?", selection: $visibility) {
                    ForEach(CommitmentVisibility.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .accessibilityIdentifier("commitmentSourceVisibility")
            } header: {
                Label(kind.title, systemImage: kind.symbol)
            } footer: {
                Text("HausKlar creates an editable draft. Nothing reaches Calendar or Tasks yet.")
            }

            if !supersessionCandidates.isEmpty {
                Section {
                    Picker("This updates…", selection: $supersedesId) {
                        Text("This is a new plan").tag("")
                        ForEach(supersessionCandidates) { commitment in
                            Text(commitment.title).tag(commitment.id)
                        }
                    }
                    .accessibilityIdentifier("commitmentSupersedes")
                } header: {
                    Text("Update an existing plan")
                } footer: {
                    Text("Choose an earlier open plan when this message changes its dates, actions or booking details.")
                }
            }

            Section("Reviewed text") {
                TextEditor(text: $reviewedText)
                    .frame(minHeight: 190)
                    .accessibilityIdentifier("commitmentReviewedText")
                    .onChange(of: reviewedText) { _, value in
                        if value.count > 100_000 {
                            reviewedText = String(value.prefix(100_000))
                        }
                    }
                Text("Paste the message, then correct anything copied badly before creating the draft.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle(isOn: $useHermes) {
                    Label("Ask Bismarck to interpret this text", systemImage: "sparkles")
                }
                .disabled(!networkMonitor.isConnected || !viewModel.hasAIConsent)
                .accessibilityIdentifier("commitmentUseHermes")

                Text(
                    viewModel.hasAIConsent
                        ? "Off by default. Bismarck runs only for this reviewed message when you turn it on."
                        : "Off. External AI permission has not been granted in Privacy & AI settings."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            errorSection

            Section {
                Button {
                    Task {
                        _ = await viewModel.createFromSource(
                            kind: kind,
                            visibility: visibility,
                            title: title,
                            reviewedText: reviewedText,
                            documentId: documentId.isEmpty ? nil : documentId,
                            sourceLabel: sourceLabel,
                            providerReference: providerReference,
                            supersedesId: supersedesId.isEmpty ? nil : supersedesId,
                            useHermes: useHermes,
                            online: networkMonitor.isConnected
                        )
                    }
                } label: {
                    HStack {
                        Spacer()
                        if viewModel.busyAction == "create-source" {
                            ProgressView()
                        } else {
                            Label("Create plan to review", systemImage: "doc.badge.plus")
                        }
                        Spacer()
                    }
                    .frame(minHeight: 44)
                }
                .disabled(
                    viewModel.busyAction != nil
                        || !networkMonitor.isConnected
                        || reviewedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
                .accessibilityIdentifier("commitmentCreateFromSource")
            }
        }
        .onChange(of: visibility) { _, _ in
            clearInvalidSupersession()
        }
        .onChange(of: supersessionCandidates.map(\.id)) { _, _ in
            clearInvalidSupersession()
        }
        .accessibilityIdentifier("commitmentSourceCreate")
    }

    private var backSection: some View {
        Section {
            Button(action: onBack) {
                Label("Choose another", systemImage: "chevron.left")
                    .frame(minHeight: 44)
            }
            .buttonStyle(.plain)
            .disabled(viewModel.busyAction != nil)
        }
    }

    @ViewBuilder
    private var errorSection: some View {
        if let error = viewModel.errorMessage {
            Section {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("commitmentCreateError")
            }
        }
    }

    private var referenceTitle: String {
        kind == .travel
            ? "Booking or trip reference (optional)".localized
            : "Message reference (optional)".localized
    }

    private var supersessionCandidates: [Commitment] {
        viewModel.supersessionCandidates(
            for: kind,
            visibility: visibility,
            excluding: viewModel.draft?.id
        )
    }

    private func clearInvalidSupersession() {
        guard !supersedesId.isEmpty,
              !supersessionCandidates.contains(where: { $0.id == supersedesId }) else {
            return
        }
        supersedesId = ""
    }

    private func chooseDocument(_ id: String) {
        guard let document = viewModel.documents.first(where: { $0.id == id }) else { return }
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            title = document.title
        }
        if reviewedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let text = document.extractedText {
            reviewedText = text
        }
    }
}

private struct CommitmentOutingCreateView: View {
    @ObservedObject var viewModel: CommitmentsViewModel
    let onBack: () -> Void
    let onQueued: () -> Void

    @EnvironmentObject private var networkMonitor: NetworkMonitor
    @State private var personIds: Set<String> = []
    @State private var searchStart = CommitmentCreateDefaults.tomorrow(hour: 9)
    @State private var searchEnd = CommitmentCreateDefaults.tomorrow(hour: 18)
    @State private var minimumMinutes = 60
    @State private var name = ""
    @State private var availableStart = CommitmentCreateDefaults.tomorrow(hour: 9)
    @State private var availableEnd = CommitmentCreateDefaults.tomorrow(hour: 18)
    @State private var durationMinutes = 120
    @State private var location = ""
    @State private var bookingURL = ""
    @State private var candidateId = UUID().uuidString.lowercased()
    @State private var visibility = CommitmentVisibility.family

    var body: some View {
        Form {
            Section {
                Button(action: onBack) {
                    Label("Choose another", systemImage: "chevron.left")
                        .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                .disabled(viewModel.busyAction != nil)
            }

            if !networkMonitor.isConnected {
                Section {
                    Label(
                        "Reconnect to search family calendars. A search cannot be queued.",
                        systemImage: "wifi.slash"
                    )
                    .foregroundStyle(.orange)
                }
            }

            Section("Who needs to be free?") {
                ForEach(viewModel.members) { member in
                    Toggle(
                        member.name,
                        isOn: Binding(
                            get: { personIds.contains(member.id) },
                            set: { selected in
                                if selected { personIds.insert(member.id) }
                                else { personIds.remove(member.id) }
                            }
                        )
                    )
                    .frame(minHeight: 44)
                }
            }

            Section("Privacy") {
                Picker("Who can see this draft?", selection: $visibility) {
                    ForEach(CommitmentVisibility.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .accessibilityIdentifier("commitmentOutingVisibility")
            }

            Section("Search window") {
                DatePicker("From", selection: $searchStart)
                DatePicker("Until", selection: $searchEnd)
                Picker("Minimum free time", selection: $minimumMinutes) {
                    Text("30 minutes").tag(30)
                    Text("1 hour").tag(60)
                    Text("2 hours").tag(120)
                    Text("3 hours").tag(180)
                }
            }

            Section("Place or activity to try") {
                TextField("Name", text: $name)
                    .accessibilityIdentifier("commitmentOutingName")
                DatePicker("Available from", selection: $availableStart)
                DatePicker("Available until", selection: $availableEnd)
                Picker("Visit length", selection: $durationMinutes) {
                    Text("1 hour").tag(60)
                    Text("1½ hours").tag(90)
                    Text("2 hours").tag(120)
                    Text("3 hours").tag(180)
                    Text("4 hours").tag(240)
                }
                TextField("Location (optional)", text: $location)
                TextField("Booking page (optional)", text: $bookingURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            if let error = viewModel.errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }

            Section {
                Button {
                    Task {
                        _ = await viewModel.searchOutings(
                            personIds: Array(personIds).sorted(),
                            searchStart: searchStart,
                            searchEnd: searchEnd,
                            minimumMinutes: minimumMinutes,
                            name: name,
                            availableStart: availableStart,
                            availableEnd: availableEnd,
                            durationMinutes: durationMinutes,
                            location: location,
                            bookingURL: bookingURL,
                            candidateId: candidateId,
                            online: networkMonitor.isConnected
                        )
                    }
                } label: {
                    HStack {
                        Spacer()
                        if viewModel.busyAction == "outing-search" { ProgressView() }
                        else { Label("Find a time", systemImage: "calendar.badge.clock") }
                        Spacer()
                    }
                    .frame(minHeight: 44)
                }
                .disabled(viewModel.busyAction != nil || !networkMonitor.isConnected)
                .accessibilityIdentifier("commitmentOutingSearch")
            }

            if let results = viewModel.outingResults {
                Section("Times that work") {
                    if results.viableOutings.isEmpty {
                        ContentUnavailableView(
                            "No fitting time",
                            systemImage: "calendar.badge.exclamationmark",
                            description: Text("Adjust the search window or the activity’s availability and try again.")
                        )
                    } else {
                        ForEach(results.viableOutings) { result in
                            VStack(alignment: .leading, spacing: 10) {
                                Label(result.title, systemImage: "calendar.badge.checkmark")
                                    .font(.headline)
                                Text(resultSubtitle(result))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Button {
                                    Task {
                                        let succeeded = await viewModel.createOuting(
                                            result,
                                            personIds: Array(personIds).sorted(),
                                            visibility: visibility
                                        )
                                        if succeeded, viewModel.draft == nil { onQueued() }
                                    }
                                } label: {
                                    if viewModel.busyAction == "outing-create:\(result.id)" {
                                        ProgressView().frame(maxWidth: .infinity, minHeight: 44)
                                    } else {
                                        Label("Use this time", systemImage: "checkmark")
                                            .frame(maxWidth: .infinity, minHeight: 44)
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(viewModel.busyAction != nil)
                                .accessibilityIdentifier("commitmentUseOuting-\(result.id)")
                            }
                            .padding(.vertical, 6)
                        }
                    }
                }
            }
        }
        .accessibilityIdentifier("commitmentOutingCreate")
    }

    private func resultSubtitle(_ result: CommitmentViableOuting) -> String {
        let start = ISODateParser.parse(result.proposedStart)
            .map { ISODateParser.dateTime(from: $0) } ?? result.proposedStart
        let minutes: Int
        if let from = ISODateParser.parse(result.proposedStart),
           let to = ISODateParser.parse(result.proposedEnd) {
            minutes = max(0, Int(to.timeIntervalSince(from) / 60))
        } else {
            minutes = 0
        }
        return [start, String(format: "%lld min".localized, Int64(minutes)), result.location]
            .compactMap { $0 }
            .joined(separator: " · ")
    }
}

private struct CommitmentChildcareCreateView: View {
    @ObservedObject var viewModel: CommitmentsViewModel
    let onBack: () -> Void
    let onQueued: () -> Void

    @EnvironmentObject private var networkMonitor: NetworkMonitor
    @State private var childId = ""
    @State private var fromDate = Date()
    @State private var toDate = CommitmentCreateDefaults.daysFromNow(90)
    @State private var visibility = CommitmentVisibility.family

    var body: some View {
        Form {
            Section {
                Button(action: onBack) {
                    Label("Choose another", systemImage: "chevron.left")
                        .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                .disabled(viewModel.busyAction != nil)
            }

            if !networkMonitor.isConnected {
                Section {
                    Label(
                        "Reconnect to compare term dates with calendar coverage. A search cannot be queued.",
                        systemImage: "wifi.slash"
                    )
                    .foregroundStyle(.orange)
                }
            }

            if viewModel.children.isEmpty {
                Section {
                    ContentUnavailableView(
                        "No child profile",
                        systemImage: "figure.and.child.holdinghands",
                        description: Text("Add a child profile before checking childcare gaps.")
                    )
                }
            } else {
                Section("Gap search") {
                    Picker("Child", selection: $childId) {
                        ForEach(viewModel.children) { child in
                            Text(child.name).tag(child.id)
                        }
                    }
                    DatePicker("From", selection: $fromDate, displayedComponents: .date)
                    DatePicker("To", selection: $toDate, displayedComponents: .date)
                }

                Section("Privacy") {
                    Picker("Who can see this draft?", selection: $visibility) {
                        ForEach(CommitmentVisibility.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .accessibilityIdentifier("commitmentChildcareVisibility")
                }

                Section {
                    Button {
                        Task {
                            _ = await viewModel.findChildcareGaps(
                                childId: childId,
                                from: fromDate,
                                to: toDate,
                                online: networkMonitor.isConnected
                            )
                        }
                    } label: {
                        HStack {
                            Spacer()
                            if viewModel.busyAction == "childcare-search" { ProgressView() }
                            else { Label("Find uncovered days", systemImage: "calendar.badge.exclamationmark") }
                            Spacer()
                        }
                        .frame(minHeight: 44)
                    }
                    .disabled(
                        viewModel.busyAction != nil
                            || !networkMonitor.isConnected
                            || childId.isEmpty
                    )
                    .accessibilityIdentifier("commitmentChildcareSearch")
                }
            }

            if let error = viewModel.errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }

            if let gaps = viewModel.childcareGaps {
                Section(gapTitle(gaps.count)) {
                    if gaps.isEmpty {
                        ContentUnavailableView(
                            "No gaps found",
                            systemImage: "calendar.badge.checkmark",
                            description: Text("These dates already have explicit cover, or no term information covers the range.")
                        )
                    } else {
                        ForEach(gaps) { gap in
                            VStack(alignment: .leading, spacing: 9) {
                                Text(dateText(gap.date))
                                    .font(.headline)
                                Text(gap.label)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Button {
                                    Task {
                                        let succeeded = await viewModel.createChildcareGap(
                                            gap,
                                            childId: childId,
                                            visibility: visibility
                                        )
                                        if succeeded, viewModel.draft == nil { onQueued() }
                                    }
                                } label: {
                                    if viewModel.busyAction == "childcare-create:\(gap.date)" {
                                        ProgressView().frame(maxWidth: .infinity, minHeight: 44)
                                    } else {
                                        Label("Plan childcare", systemImage: "checkmark")
                                            .frame(maxWidth: .infinity, minHeight: 44)
                                    }
                                }
                                .buttonStyle(.bordered)
                                .disabled(viewModel.busyAction != nil)
                                .accessibilityIdentifier("commitmentPlanChildcare-\(gap.date)")
                            }
                            .padding(.vertical, 5)
                        }
                    }
                }
            }
        }
        .task {
            if childId.isEmpty { childId = viewModel.children.first?.id ?? "" }
        }
        .onChange(of: viewModel.children.map(\.id)) { _, _ in
            if !viewModel.children.contains(where: { $0.id == childId }) {
                childId = viewModel.children.first?.id ?? ""
            }
        }
        .accessibilityIdentifier("commitmentChildcareCreate")
    }

    private func gapTitle(_ count: Int) -> String {
        count == 1
            ? "1 uncovered day".localized
            : String(format: "%lld uncovered days".localized, Int64(count))
    }

    private func dateText(_ value: String) -> String {
        ISODateParser.parseDateOnly(value)?.formatted(
            .dateTime.weekday(.wide).day().month(.wide).locale(.hausKlarSelected)
        ) ?? value
    }
}

private enum CommitmentCreateDefaults {
    static func tomorrow(hour: Int) -> Date {
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        return Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: tomorrow)
            ?? tomorrow
    }

    static func daysFromNow(_ days: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: days, to: Date()) ?? Date()
    }
}
