import SwiftUI

private struct EventDocumentItem: Identifiable {
    let id: String
    let role: CalendarEventAttachmentRole
    let document: SourceDocumentDTO?
}

struct EventDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState
    let event: CalendarEventDTO
    @ObservedObject var viewModel: CalendarViewModel
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onManageClubs: () -> Void
    let onManageToast: () -> Void

    @State private var previewItem: DocumentPreviewItem?
    @State private var openingAttachmentId: String?
    @State private var attachmentError: String?
    @State private var swimmingBooking: FacilitySwimmingBookingSelection?
    @State private var swimmingBookingNotice: String?
    @State private var weightsBooking: FacilityWeightsBookingSelection?
    @State private var weightsBookingNotice: String?
    @State private var isChangingRugbyVenue = false
    @State private var rugbyVenueError: String?
    @State private var managedEventBusy = false
    @State private var managedEventError: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .top, spacing: 10) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(
                                    event.sourceColor.map(Color.init(hex:))
                                        ?? viewModel.colorForEvent(event)
                                )
                                .frame(width: 5, height: 44)
                            Text(event.title)
                                .font(.title3.weight(.semibold))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Label(timingLabel, systemImage: "clock")
                        Label(
                            viewModel.participantLabel(for: event),
                            systemImage: "person.example_f47e224f"
                        )
                        if let affected = viewModel.affectedLabel(for: event) {
                            Label("Coverage: \(affected)", systemImage: "arrow.triangle.branch")
                        }
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, event.isSchoolMilestone ? 12 : 0)
                    .background {
                        if event.isSchoolMilestone {
                            SchoolMilestoneBackground()
                        }
                    }
                }

                if event.isSchoolClubProjection {
                    Section(event.isCancelledSchoolClub ? "Cancelled this date" : "Term-time club") {
                        Text(
                            event.isCancelledSchoolClub
                                ? "It stays visible so nobody expects it to run."
                                : "If Toast is booked, pickup starts when this club ends."
                        )
                        .foregroundStyle(.secondary)
                        if let managedEventError {
                            Label(managedEventError, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                        Button {
                            Task {
                                managedEventBusy = true
                                managedEventError = nil
                                defer { managedEventBusy = false }
                                if await viewModel.changeSchoolClubOccurrence(event) {
                                    HapticManager.success()
                                    dismiss()
                                } else {
                                    managedEventError = viewModel.schoolClubError
                                        ?? "That club date could not be changed."
                                }
                            }
                        } label: {
                            Label(
                                event.isCancelledSchoolClub
                                    ? "Restore this date" : "Cancel this date",
                                systemImage: event.isCancelledSchoolClub
                                    ? "arrow.uturn.backward" : "calendar.badge.minus"
                            )
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        }
                        .disabled(managedEventBusy)
                        Button {
                            dismiss()
                            onManageClubs()
                        } label: {
                            Label("Manage clubs", systemImage: "figure.run.circle")
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        }
                    }
                }

                if event.isToastProjection {
                    Section("Pickup window") {
                        Text(
                            event.eventType == "toast_club_conflict"
                                ? event.description ?? "Check this pickup window."
                                : "Pickup any time in this window."
                        )
                        .foregroundStyle(.secondary)
                        Button {
                            dismiss()
                            onManageToast()
                        } label: {
                            Label("Toast bookings", systemImage: "clock.arrow.2.circlepath")
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        }
                    }
                }

                if let rugbyVenue = event.rugbyVenue {
                    Section("Fixture venue") {
                        HStack(alignment: .top, spacing: 12) {
                            Text(rugbyVenue.uppercased())
                                .font(.caption.weight(.heavy))
                                .tracking(1)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(
                                    rugbyVenue == "away" ? Color.red : Color.blue,
                                    in: RoundedRectangle(cornerRadius: 7)
                                )
                            VStack(alignment: .leading, spacing: 3) {
                                Text(
                                    rugbyVenue == "away"
                                        ? "Away fixture — travel blocked out"
                                        : "Home fixture"
                                )
                                .fontWeight(.semibold)
                                Text("Reserved in the planner from 1:00 to 7:00 pm.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if event.rugbyVenueOverridden == true {
                                    Text("This venue was changed in HausKlar.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }

                        if let rugbyVenueError {
                            Label(rugbyVenueError, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }

                        Button {
                            Task {
                                isChangingRugbyVenue = true
                                rugbyVenueError = nil
                                defer { isChangingRugbyVenue = false }
                                if await viewModel.changeRugbyVenue(event) != nil {
                                    dismiss()
                                } else {
                                    rugbyVenueError = viewModel.errorMessage
                                        ?? "The fixture venue could not be changed."
                                }
                            }
                        } label: {
                            HStack(spacing: 8) {
                                if isChangingRugbyVenue {
                                    ProgressView().controlSize(.small)
                                }
                                Label(
                                    "Mark as \(rugbyVenue == "home" ? "AWAY" : "HOME")",
                                    systemImage: "arrow.left.arrow.right"
                                )
                            }
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        }
                        .disabled(isChangingRugbyVenue)
                        .tint(rugbyVenue == "home" ? .red : .blue)
                    }
                }

                if event.rugbyVenue == nil,
                   let location = event.location,
                   !location.isEmpty {
                    Section("Location") {
                        Label(location, systemImage: "location.fill")
                        if let directionsURL {
                            Link(destination: directionsURL) {
                                Label("Directions", systemImage: "arrow.triangle.turn.up.right.diamond")
                                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            }
                        }
                    }
                }

                if !event.isFinanceManaged,
                    let description = event.description,
                    !description.isEmpty
                {
                    Section("Notes") {
                        Text(description)
                            .textSelection(.enabled)
                    }
                }

                if let bookingSelection = FacilitySwimmingBookingSelection(event: event) {
                    Section("Booked a swim?") {
                        Text("Add the exact slot so it appears in the family calendar.")
                            .foregroundStyle(.secondary)
                        Button {
                            UsageMonitor.control(.openSwimmingBooking(.calendarEvent))
                            swimmingBooking = bookingSelection
                        } label: {
                            Label("Booked", systemImage: "calendar.badge.plus")
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        }
                        .accessibilityHint("Choose the swimming times you booked")
                    }
                }

                if let swimmingBookingNotice {
                    Section {
                        Label(swimmingBookingNotice, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }

                if let bookingSelection = FacilityWeightsBookingSelection(event: event) {
                    Section("Strength session") {
                        Button {
                            weightsBooking = bookingSelection
                        } label: {
                            Label("Plan strength", systemImage: "calendar.badge.plus")
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        }
                        .accessibilityHint("Choose a time inside this weights-room window")
                    }
                }

                if let weightsBookingNotice {
                    Section {
                        Label(weightsBookingNotice, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }

                Section("Clashes") {
                    if clashes.isEmpty {
                        Label("No family clashes", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(clashes) { clash in
                            Button {
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundStyle(.orange)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(clash.title)
                                            .foregroundStyle(.primary)
                                        Text(
                                            viewModel.formattedTimeRange(
                                                start: clash.startTime,
                                                end: clash.endTime
                                            )
                                        )
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(true)
                        }
                    }
                }

                Section("Related tasks") {
                    if relatedTasks.isEmpty {
                        Text("No tasks linked to this event.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(relatedTasks) { task in
                            HStack(spacing: 12) {
                                Button {
                                    Task { await viewModel.completePlannerTask(task.id) }
                                } label: {
                                    Image(systemName: "circle")
                                        .frame(width: 32, height: 32)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Complete \(task.title)")
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(task.title)
                                    if let dueDate = task.dueDate {
                                        Text("Due \(dueDate.prefix(10))")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                            }
                        }
                    }
                }

                Section("Preparation") {
                    if !preparationTasks.isEmpty {
                        HStack {
                            Label("Packing checklist", systemImage: "backpack.fill")
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Text("\(preparationTasks.count) remaining")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        ForEach(preparationTasks) { task in
                            let ownerNames = task.assignees.compactMap(\.assigneeName).joined(separator: " & ")
                            HStack(spacing: 12) {
                                Button {
                                    Task { await viewModel.completePlannerTask(task.id) }
                                } label: {
                                    Image(systemName: "circle")
                                        .frame(width: 32, height: 32)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Pack \(task.title)")
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(task.title)
                                    Text(ownerNames.isEmpty ? "Family" : ownerNames)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                        }
                        Button("Edit reusable packing list") {
                            dismiss()
                            appState.openLists(.prepPacks)
                        }
                        .font(.subheadline)
                        .frame(minHeight: 44)
                    } else if prepSuggestions.isEmpty {
                        Text("No packing checklist is suggested for this event.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(prepSuggestions) { suggestion in
                            VStack(alignment: .leading, spacing: 8) {
                                Label(suggestion.templateName, systemImage: "backpack.fill")
                                    .font(.subheadline.weight(.semibold))
                                ForEach(suggestion.items, id: \.self) { item in
                                    Label(item, systemImage: "circle")
                                        .font(.subheadline)
                                }
                                if let assignedTo = suggestion.assignedTo {
                                    Text(
                                        "For \(viewModel.familyMembers.first { $0.id == assignedTo }?.name ?? "Assigned family member")"
                                    )
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                } else {
                                    Text("For the family")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Button {
                                    Task { await viewModel.applyPrepSuggestion(suggestion) }
                                } label: {
                                    if viewModel.prepBusyId == suggestion.id {
                                        ProgressView()
                                    } else {
                                        Text("Use checklist")
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(viewModel.prepBusyId != nil)
                                Button("Edit reusable packing list") {
                                    dismiss()
                                    appState.openLists(.prepPacks)
                                }
                                .font(.subheadline)
                                .frame(minHeight: 44)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }

                Section("Documents") {
                    if documentItems.isEmpty {
                        Text("No tickets or documents attached.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(documentItems) { item in
                            Button {
                                openAttachment(item)
                            } label: {
                                HStack(spacing: 12) {
                                    Image(
                                        systemName: item.document?.mediaType.hasPrefix("image/") == true
                                            ? "photo.fill" : "doc.fill"
                                    )
                                    .foregroundStyle(Color.accentColor)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.document?.title ?? "Original document")
                                            .foregroundStyle(.primary)
                                        Text(item.role.label)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        if let filename = item.document?.originalFilename {
                                            Text(filename)
                                                .font(.caption2)
                                                .foregroundStyle(.tertiary)
                                                .lineLimit(1)
                                        }
                                    }
                                    Spacer()
                                    if openingAttachmentId == item.id {
                                        ProgressView()
                                    } else {
                                        Image(systemName: "arrow.up.right.square")
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .frame(minHeight: 48)
                            }
                            .disabled(openingAttachmentId != nil)
                        }

                        if let attachmentError {
                            Label(attachmentError, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                }

                if event.isFitnessProjection {
                    Section("Fitness") {
                        if let intent = viewModel.fitnessDeepLink(for: event) {
                            Button {
                                dismiss()
                                appState.openFitness(
                                    destination: intent.destination,
                                    targetId: intent.targetId,
                                    actionKind: intent.actionKind
                                )
                            } label: {
                                Label(
                                    intent.destination == .activities
                                        ? "Open workout" : "Open training",
                                    systemImage: intent.destination == .activities
                                        ? "figure.run" : "dumbbell.fill"
                                )
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            }
                            .accessibilityHint("Opens this fitness item")
                            .accessibilityIdentifier("calendarOpenFitnessButton")
                        }
                    }
                } else if event.isCycleProjection {
                    Section("Calculated date") {
                        Label("Cycle tracking", systemImage: "calendar.badge.clock")
                        Text("Update the recorded period start or cycle length to recalculate this date.")
                            .foregroundStyle(.secondary)
                    }
                } else if event.isFinanceManaged {
                    Section("Managed in Finance") {
                        Label(
                            event.financeCategoryLabel ?? "Money",
                            systemImage: event.eventType == "finance_delivery"
                                ? "truck.box" : "wallet.bifold"
                        )
                        Text("Calendar only shows the date. Update the payment details in Finance.")
                            .foregroundStyle(.secondary)
                        if let financeURL = event.managedSource?.financeWebURL {
                            FinanceWebHandoffButton(destination: financeURL) {
                                Label("Open Finance", systemImage: "arrow.up.right.square")
                                    .frame(
                                        maxWidth: .infinity,
                                        minHeight: 44,
                                        alignment: .leading
                                    )
                            }
                            .accessibilityHint("Open this item in the HausKlar web app")
                            .accessibilityIdentifier("calendarOpenFinanceLink")
                        }
                    }
                }

                if hasAdvancedContext {
                    Section {
                        DisclosureGroup("More about this event") {
                            if event.isGeneratedOccurrence == true {
                                Label(
                                    "Editing or deleting asks which events in the series to change.",
                                    systemImage: "repeat"
                                )
                            } else if event.recurrenceRule != nil {
                                Label("Part of a repeating series", systemImage: "repeat")
                            }
                            if event.isFacilityProjection {
                                Label("Example School facilities timetable", systemImage: "building.columns.fill")
                            } else if event.rugbyVenue != nil {
                                Label(
                                    event.sourceName ?? "Example School College Sports",
                                    systemImage: "arrow.down.circle"
                                )
                                Text("HausKlar keeps this fixture up to date from Example School. HOME or AWAY can be changed here without changing Example School’s calendar.")
                                    .foregroundStyle(.secondary)
                            } else if event.readOnly == true {
                                Label(
                                    event.sourceName ?? "Imported calendar",
                                    systemImage: "arrow.down.circle"
                                )
                                Text("Editing creates a HausKlar copy and leaves the imported source unchanged.")
                                    .foregroundStyle(.secondary)
                            } else if event.overriddenEventId != nil {
                                Text("This HausKlar copy replaces an imported event.")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                if event.readOnly != true
                    && !event.isSchoolClubProjection && !event.isToastProjection {
                    Section {
                        Button(role: .destructive, action: onDelete) {
                            Label(
                                event.isFitnessProjection
                                    ? "Delete planned exercise"
                                    : event.overriddenEventId == nil
                                        ? "Delete event" : "Restore imported event",
                                systemImage: event.overriddenEventId == nil
                                    ? "trash" : "arrow.uturn.backward"
                            )
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        }
                        .accessibilityHint(
                            event.overriddenEventId == nil
                                ? "Asks for confirmation before deleting"
                                : "Asks for confirmation before removing this override"
                        )
                    }
                }
            }
            .navigationTitle("Event")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                if event.rugbyVenue == nil && !event.isFitnessProjection
                    && !event.isSchoolClubProjection && !event.isToastProjection {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Edit") { onEdit() }
                            .accessibilityHint(
                                event.readOnly == true
                                    ? "Creates an editable HausKlar copy"
                                    : "Opens this event for editing"
                            )
                    }
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .sheet(item: $previewItem) { item in
            DocumentPreviewSheet(item: item)
                .onDisappear { DocumentPreviewStore.remove(item.url) }
        }
        .sheet(item: $swimmingBooking) { selection in
            FacilitySwimmingBookingSheet(selection: selection) { notice in
                swimmingBookingNotice = notice
            }
        }
        .sheet(item: $weightsBooking) { selection in
            FacilityWeightsBookingSheet(selection: selection) { notice in
                weightsBookingNotice = notice
            }
        }
    }

    private func openAttachment(_ item: EventDocumentItem) {
        guard openingAttachmentId == nil else { return }
        openingAttachmentId = item.id
        attachmentError = nil
        Task {
            defer { openingAttachmentId = nil }
            do {
                let document: SourceDocumentDTO
                if let embedded = item.document {
                    document = embedded
                } else {
                    let detail: DocumentDTO = try await APIClient.shared.get("/documents/\(item.id)")
                    document = SourceDocumentDTO(document: detail)
                }
                let url = try await DocumentPreviewStore.download(document)
                previewItem = DocumentPreviewItem(url: url, title: document.title)
            } catch let error as APIError {
                attachmentError = error.errorDescription
            } catch {
                attachmentError = "The original document could not be opened. Try again."
            }
        }
    }

    private var directionsURL: URL? {
        guard let location = event.location?.trimmingCharacters(in: .whitespacesAndNewlines),
            !location.isEmpty
        else { return nil }
        var components = URLComponents(string: "https://maps.apple.com/")
        components?.queryItems = [URLQueryItem(name: "q", value: location)]
        return components?.url
    }

    private var documentItems: [EventDocumentItem] {
        if !event.attachments.isEmpty {
            return event.attachments.sorted { $0.position < $1.position }.map {
                EventDocumentItem(id: $0.id, role: $0.role, document: $0.document)
            }
        }
        guard let id = event.sourceDocumentId ?? event.sourceDocument?.id else { return [] }
        return [EventDocumentItem(id: id, role: .other, document: event.sourceDocument)]
    }

    private var clashes: [CalendarEventDTO] {
        viewModel.clashes(for: event)
    }

    private var relatedTasks: [TaskDTO] {
        viewModel.relatedTasks(for: event)
    }

    private var prepSuggestions: [PrepPackSuggestionDTO] {
        viewModel.prepSuggestions(for: event)
    }

    private var preparationTasks: [TaskDTO] {
        viewModel.preparationTasks(for: event)
    }

    private var hasAdvancedContext: Bool {
        event.isGeneratedOccurrence == true || event.recurrenceRule != nil
            || event.isFacilityProjection || event.readOnly == true
            || event.overriddenEventId != nil
    }

    private var timingLabel: String {
        guard let start = ISODateParser.parse(event.startTime) else {
            return event.startTime
        }
        if event.allDay {
            if let rawEnd = event.endTime,
                let exclusiveEnd = ISODateParser.parse(rawEnd),
                let lastDay = Calendar.current.date(byAdding: .day, value: -1, to: exclusiveEnd),
                !Calendar.current.isDate(lastDay, inSameDayAs: start)
            {
                return "\(ISODateParser.dateOnly(from: start)) – \(ISODateParser.dateOnly(from: lastDay))"
            }
            return "\(ISODateParser.dateOnly(from: start)), \("All day".localized.lowercased())"
        }
        guard let rawEnd = event.endTime,
            let end = ISODateParser.parse(rawEnd)
        else {
            return ISODateParser.dateTime(from: start)
        }
        if Calendar.current.isDate(start, inSameDayAs: end) {
            return "\(ISODateParser.dateTime(from: start)) – \(ISODateParser.timeOnly(from: end))"
        }
        return "\(ISODateParser.dateTime(from: start)) – \(ISODateParser.dateTime(from: end))"
    }
}
