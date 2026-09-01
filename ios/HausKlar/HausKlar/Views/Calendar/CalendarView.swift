import SwiftUI
import UniformTypeIdentifiers

private enum RecurringEventAction {
    case edit
    case delete
}

private struct CoordinationDaySelection: Identifiable {
    let date: Date
    var id: Date { Calendar.current.startOfDay(for: date) }
}

private struct CoordinationWindowModel: Identifiable {
    let start: Int
    let end: Int
    let label: String
    let conflict: Bool
    var id: String { "\(start)-\(end)-\(conflict)-\(label)" }
}

private struct CoordinationMarkerModel: Identifiable {
    let at: Int
    var label: String
    let kind: HandoffKindDTO
    var id: String { "\(kind.rawValue)-\(at)-\(label)" }
}

private struct CoordinationLaneModel: Identifiable {
    let id: String
    let name: String
    let color: Color
    var windows: [CoordinationWindowModel]
    var markers: [CoordinationMarkerModel]
}

/// The main calendar view showing a week-based date selector and a daily event list.
struct CalendarView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var viewModel = CalendarViewModel()
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.modelContext) private var modelContext
    @Environment(\.locale) private var locale

    @State private var showDeleteConfirmation = false
    @State private var eventToDelete: CalendarEventDTO?
    @State private var selectedEvent: CalendarEventDTO?
    @State private var eventPendingEdit: CalendarEventDTO?
    @State private var eventPendingDelete: CalendarEventDTO?
    @State private var recurrenceScopeEvent: CalendarEventDTO?
    @State private var recurrenceScopeAction: RecurringEventAction?
    @State private var showRecurrenceScopeDialog = false
    @State private var showingDocumentPicker = false
    @State private var showingEventMore = false
    @State private var showingCycleTracking = false
    @State private var showingFacilityFileImporter = false
    @State private var showingFacilityImportReview = false
    @State private var facilityImportNotice: String?
    @State private var showingHandoffSchedule = false
    @State private var editingHandoff: HandoffOccurrenceDTO?
    @State private var coordinationDay: CoordinationDaySelection?
    @State private var showingClubManager = false
    @State private var showingToastManager = false

    // Cached formatter for week content headers
    private static let dayHeaderFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE, d MMM"
        return f
    }()

    private var displayCalendar: Calendar {
        var calendar = Calendar.current
        let firstWeekday = calendar.firstWeekday
        let minimumDaysInFirstWeek = calendar.minimumDaysInFirstWeek
        calendar.locale = locale
        calendar.firstWeekday = firstWeekday
        calendar.minimumDaysInFirstWeek = minimumDaysInFirstWeek
        return calendar
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if viewModel.viewMode == .day || viewModel.viewMode == .week {
                    weekSelectorView
                        .padding(.vertical, 8)
                }

                if viewModel.viewMode != .year {
                    familyFilterBar
                    if viewModel.isKidsSelected {
                        kidsSubSelectorView
                            .padding(.bottom, 6)
                    }
                }

                Divider()

                // Content
                if viewModel.viewMode == .year {
                    YearlyOverviewView(viewModel: viewModel)
                } else if viewModel.isLoading && !viewModel.hasLoadedCurrentEventRange {
                    loadingView
                } else if let errorMessage = viewModel.errorMessage,
                          !viewModel.hasLoadedCurrentEventRange {
                    errorView(message: errorMessage)
                } else {
                    switch viewModel.viewMode {
                    case .day:
                        dayContentView
                    case .week:
                        weekContentView
                    case .month:
                        monthContentView
                    case .year:
                        EmptyView() // handled above
                    }
                }
            }
            .navigationTitle("Calendar")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        viewModel.goToToday()
                        if viewModel.viewMode == .year {
                            viewModel.viewMode = .day
                        }
                    } label: {
                        Text("Today")
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Menu {
                        Picker("Calendar view", selection: $viewModel.viewMode) {
                            ForEach(CalendarViewMode.allCases, id: \.rawValue) { mode in
                                Label(mode.rawValue, systemImage: mode.icon).tag(mode)
                            }
                        }
                        if let preference = viewModel.financeProjectionPreference {
                            Divider()
                            Toggle(
                                "Money",
                                isOn: Binding(
                                    get: { preference.showMoney },
                                    set: { value in
                                        Task {
                                            await viewModel.setFinanceProjectionVisibility(
                                                showMoney: value
                                            )
                                        }
                                    }
                                )
                            )
                            .disabled(viewModel.isUpdatingFinanceProjectionPreference)
                            Toggle(
                                "Deliveries",
                                isOn: Binding(
                                    get: { preference.showDeliveries },
                                    set: { value in
                                        Task {
                                            await viewModel.setFinanceProjectionVisibility(
                                                showDeliveries: value
                                            )
                                        }
                                    }
                                )
                            )
                            .disabled(viewModel.isUpdatingFinanceProjectionPreference)
                        }
                        Divider()
                        Toggle(
                            "Fitness plans",
                            isOn: Binding(
                                get: { viewModel.showFitnessPlans },
                                set: { value in Task { await viewModel.setFitnessCalendarVisibility(plans: value) } }
                            )
                        )
                        Toggle(
                            "Completed workouts",
                            isOn: Binding(
                                get: { viewModel.showCompletedFitness },
                                set: { value in Task { await viewModel.setFitnessCalendarVisibility(completed: value) } }
                            )
                        )
                        if let preference = viewModel.facilityCalendarPreference {
                            Divider()
                            Toggle(
                                "Family swimming",
                                isOn: Binding(
                                    get: { preference.showFamilySwimming },
                                    set: { value in
                                        Task {
                                            await viewModel.setFacilityCalendarVisibility(
                                                showFamilySwimming: value
                                            )
                                        }
                                    }
                                )
                            )
                            .disabled(viewModel.isUpdatingFacilityCalendarPreference)
                            Toggle(
                                "My lane swim & weights",
                                isOn: Binding(
                                    get: { preference.showPersonalFacilities },
                                    set: { value in
                                        Task {
                                            await viewModel.setFacilityCalendarVisibility(
                                                showPersonalFacilities: value
                                            )
                                        }
                                    }
                                )
                            )
                            .disabled(viewModel.isUpdatingFacilityCalendarPreference)
                        }
                        Divider()
                        Button {
                            showingHandoffSchedule = true
                        } label: {
                            Label("Handoffs", systemImage: "arrow.left.arrow.right")
                        }
                        Button {
                            showingClubManager = true
                        } label: {
                            Label("Clubs", systemImage: "figure.run.circle")
                        }
                        Button {
                            showingToastManager = true
                        } label: {
                            Label("Toast Club", systemImage: "clock.arrow.2.circlepath")
                        }
                        Button {
                            showingFacilityFileImporter = true
                        } label: {
                            Label("Update Example School timetable", systemImage: "doc.badge.arrow.up")
                        }
                    } label: {
                        Image(systemName: viewModel.viewMode.icon)
                    }
                    .accessibilityLabel("Calendar view: \(viewModel.viewMode.rawValue)")

                    Button("New event", systemImage: "plus") {
                        viewModel.prepareNewEvent(on: viewModel.selectedDate)
                        viewModel.showingAddEvent = true
                    }
                    .accessibilityLabel("New calendar event")

                    Button("Cycle tracking", systemImage: "calendar.badge.clock") {
                        showingCycleTracking = true
                    }
                    .accessibilityLabel("Cycle tracking")
                }
            }
            .sheet(
                isPresented: $viewModel.showingAddEvent,
                onDismiss: { viewModel.resetForm() }
            ) {
                addEventSheet
            }
            .sheet(isPresented: $showingCycleTracking) {
                NavigationStack {
                    FitnessCycleTrackingView(showsDoneButton: true) {
                        Task { await viewModel.loadEvents() }
                    }
                }
            }
            .sheet(isPresented: $showingHandoffSchedule) {
                HandoffScheduleSheet(
                    viewModel: viewModel,
                    currentUserId: appState.currentUser?.id
                )
            }
            .sheet(item: $editingHandoff) { handoff in
                HandoffDayEditSheet(handoff: handoff, viewModel: viewModel)
            }
            .sheet(item: $coordinationDay) { selection in
                CoordinationDetailSheet(date: selection.date, viewModel: viewModel)
            }
            .sheet(isPresented: $showingClubManager) {
                SchoolClubManagerSheet(viewModel: viewModel)
            }
            .sheet(
                isPresented: $showingToastManager,
                onDismiss: { viewModel.discardToastImport() }
            ) {
                ToastClubManagerSheet(viewModel: viewModel)
            }
            .sheet(
                isPresented: $showingFacilityImportReview,
                onDismiss: { viewModel.discardFacilityImport() }
            ) {
                FacilityTimetableImportSheet(viewModel: viewModel) { notice in
                    facilityImportNotice = notice
                }
            }
            .sheet(item: $selectedEvent, onDismiss: presentPendingEventAction) { event in
                EventDetailSheet(
                    event: event,
                    viewModel: viewModel,
                    onEdit: {
                        eventPendingEdit = event
                        selectedEvent = nil
                    },
                    onDelete: {
                        eventPendingDelete = event
                        selectedEvent = nil
                    },
                    onManageClubs: {
                        selectedEvent = nil
                        Task { @MainActor in
                            await Task.yield()
                            showingClubManager = true
                        }
                    },
                    onManageToast: {
                        selectedEvent = nil
                        Task { @MainActor in
                            await Task.yield()
                            showingToastManager = true
                        }
                    }
                )
            }
            .confirmationDialog(
                deleteConfirmationTitle,
                isPresented: $showDeleteConfirmation,
                presenting: eventToDelete
            ) { event in
                Button(
                    event.isFitnessProjection
                        ? "Delete planned exercise"
                        : event.overriddenEventId == nil ? "Delete" : "Restore imported event",
                    role: .destructive
                ) {
                    Task { await viewModel.deleteEvent(event) }
                }
                Button("Cancel", role: .cancel) { }
            } message: { event in
                if event.overriddenEventId != nil {
                    Text("This removes your HausKlar override and shows the unchanged imported event again.")
                } else if event.isFitnessProjection {
                    Text("This removes \"\(event.title)\" from your training plan and calendar.")
                } else if event.recurrenceRule == nil {
                    Text("Are you sure you want to delete \"\(event.title)\"?")
                } else {
                    Text("This deletes every occurrence of \"\(event.title)\".")
                }
            }
            .confirmationDialog(
                recurrenceScopeTitle,
                isPresented: $showRecurrenceScopeDialog,
                presenting: recurrenceScopeEvent
            ) { event in
                ForEach(CalendarRecurrenceMutationScope.allCases) { scope in
                    Button(
                        scope.label,
                        role: recurrenceScopeAction == .delete ? .destructive : nil
                    ) {
                        performRecurringAction(event, scope: scope)
                    }
                }
                Button("Cancel", role: .cancel) {
                    recurrenceScopeEvent = nil
                    recurrenceScopeAction = nil
                }
            } message: { event in
                Text(
                    recurrenceScopeAction == .delete
                        ? "Choose how much of \"\(event.title)\" to delete."
                        : "Choose how much of \"\(event.title)\" to edit."
                )
            }
            .fileImporter(
                isPresented: $showingFacilityFileImporter,
                allowedContentTypes: [UTType(filenameExtension: "docx") ?? .data]
            ) { result in
                switch result {
                case .success(let url):
                    showingFacilityImportReview = true
                    Task { await viewModel.previewSchoolTimetable(at: url) }
                case .failure(let error):
                    if (error as? CocoaError)?.code != .userCancelled {
                        viewModel.reportFacilityPickerError(error)
                        showingFacilityImportReview = true
                    }
                }
            }
            .alert(
                "Example School timetable",
                isPresented: Binding(
                    get: { facilityImportNotice != nil },
                    set: { visible in
                        if !visible { facilityImportNotice = nil }
                    }
                )
            ) {
                Button("OK") { facilityImportNotice = nil }
            } message: {
                Text(facilityImportNotice ?? "")
            }
            .task {
                applyResultFocusIfNeeded()
                viewModel.bindModelContext(modelContext)
                viewModel.configureFitnessCalendar(ownerUserId: appState.currentUser?.id)
                await viewModel.loadFitnessCalendarPreference()
                await viewModel.loadFamilyMembers()
                await viewModel.loadFinanceProjectionPreference()
                await viewModel.loadFacilityCalendarPreference()
                await viewModel.loadEvents()
                presentHighlightedEventIfAvailable()
                if viewModel.viewMode == .year {
                    await viewModel.loadYearData()
                }
            }
            .onChange(of: viewModel.selectedDate) {
                Task {
                    await viewModel.loadEventsIfNeeded()
                }
            }
            .onChange(of: viewModel.viewMode) { oldMode, newMode in
                if newMode == .year {
                    viewModel.selectedYear = displayCalendar.component(
                        .year,
                        from: viewModel.selectedDate
                    )
                    Task {
                        await viewModel.loadYearData()
                    }
                } else if oldMode == .year || newMode == .month {
                    Task {
                        await viewModel.loadEventsIfNeeded()
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .calendarDataChanged)) { _ in
                Task { await viewModel.loadEvents() }
            }
            .onChange(of: appState.preferredCalendarDate) { _, date in
                guard date != nil else { return }
                applyResultFocusIfNeeded()
                Task {
                    await viewModel.loadEventsIfNeeded()
                    presentHighlightedEventIfAvailable()
                }
            }
            .onChange(of: appState.highlightedCalendarResultId) { _, eventId in
                guard eventId != nil else { return }
                applyResultFocusIfNeeded()
                Task {
                    await viewModel.loadEventsIfNeeded()
                    presentHighlightedEventIfAvailable()
                }
            }
        }
    }

    private func applyResultFocusIfNeeded() {
        guard let date = appState.preferredCalendarDate else { return }
        viewModel.selectedDate = date
        viewModel.selectedColumnId = "__all__"
        viewModel.viewMode = .day
        appState.preferredCalendarDate = nil
    }

    private func presentHighlightedEventIfAvailable() {
        guard selectedEvent == nil,
              let eventId = appState.highlightedCalendarResultId,
              let event = viewModel.events.first(where: { $0.id == eventId }) else { return }
        appState.highlightedCalendarResultId = nil
        selectedEvent = event
    }

    private func openEvent(_ event: CalendarEventDTO) {
        HapticManager.selection()
        if event.isFitnessProjection,
           let intent = viewModel.fitnessDeepLink(for: event),
           intent.destination == .activities {
            appState.openFitness(
                destination: intent.destination,
                targetId: intent.targetId,
                actionKind: intent.actionKind
            )
            return
        }
        selectedEvent = event
    }

    private var deleteConfirmationTitle: String {
        if eventToDelete?.isFitnessProjection == true { return "Delete planned exercise?" }
        if eventToDelete?.overriddenEventId != nil { return "Restore imported event?" }
        return eventToDelete?.recurrenceRule == nil
            ? "Delete this event?" : "Delete this repeating series?"
    }

    private var recurrenceScopeTitle: String {
        recurrenceScopeAction == .delete
            ? "Delete repeating event?" : "Edit repeating event?"
    }

    private func needsRecurrenceScope(_ event: CalendarEventDTO) -> Bool {
        event.isGeneratedOccurrence == true && event.seriesId != nil
    }

    private func presentRecurrenceScope(
        for event: CalendarEventDTO,
        action: RecurringEventAction
    ) {
        recurrenceScopeEvent = event
        recurrenceScopeAction = action
        showRecurrenceScopeDialog = true
    }

    private func performRecurringAction(
        _ event: CalendarEventDTO,
        scope: CalendarRecurrenceMutationScope
    ) {
        let action = recurrenceScopeAction
        recurrenceScopeEvent = nil
        recurrenceScopeAction = nil
        switch action {
        case .edit:
            DispatchQueue.main.async {
                viewModel.beginEditing(
                    event,
                    recurrenceScope: scope,
                    calendar: displayCalendar
                )
                viewModel.showingAddEvent = true
            }
        case .delete:
            Task { await viewModel.deleteEvent(event, recurrenceScope: scope) }
        case nil:
            break
        }
    }

    private func presentPendingEventAction() {
        if let event = eventPendingEdit {
            eventPendingEdit = nil
            DispatchQueue.main.async {
                if needsRecurrenceScope(event) {
                    presentRecurrenceScope(for: event, action: .edit)
                } else {
                    viewModel.beginEditing(event, calendar: displayCalendar)
                    viewModel.showingAddEvent = true
                }
            }
            return
        }
        if let event = eventPendingDelete {
            eventPendingDelete = nil
            DispatchQueue.main.async {
                if needsRecurrenceScope(event) {
                    presentRecurrenceScope(for: event, action: .delete)
                } else {
                    eventToDelete = event
                    showDeleteConfirmation = true
                }
            }
        }
    }

    // MARK: - Week Selector

    private var weekSelectorView: some View {
        HStack(spacing: 4) {
                Button {
                    if let newDate = Calendar.current.date(byAdding: .weekOfYear, value: -1, to: viewModel.selectedDate) {
                        viewModel.selectedDate = newDate
                    }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                }

                ForEach(viewModel.weekDays, id: \.self) { date in
                    let isSelected = Calendar.current.isDate(date, inSameDayAs: viewModel.selectedDate)
                    let isToday = Calendar.current.isDateInToday(date)

                    Button {
                        viewModel.selectedDate = date
                    } label: {
                        VStack(spacing: 4) {
                            Text(date, format: .dateTime.weekday(.abbreviated))
                                .font(.caption)
                            Text(date, format: .dateTime.day())
                                .font(.body)
                                .fontWeight(isSelected ? .bold : .regular)
                            // Today indicator dot
                            if isToday && !isSelected {
                                Circle()
                                    .fill(Color.accentColor)
                                    .frame(width: 5, height: 5)
                            } else {
                                Circle()
                                    .fill(Color.clear)
                                    .frame(width: 5, height: 5)
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(isSelected ? Color.accentColor : Color.clear)
                        .foregroundStyle(isSelected ? .white : .primary)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Select \(date, format: .dateTime.weekday(.wide)), \(date, format: .dateTime.day())")
                }

                // Next week button
                Button {
                    if let newDate = Calendar.current.date(byAdding: .weekOfYear, value: 1, to: viewModel.selectedDate) {
                        viewModel.selectedDate = newDate
                    }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                }
            }
            .padding(.horizontal)
    }

    private var familyFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(viewModel.columns) { column in
                    Button {
                        viewModel.selectedColumnId = column.id
                    } label: {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(column.color)
                                .frame(width: 7, height: 7)
                            Text(column.label)
                                .font(.subheadline)
                                .fontWeight(viewModel.selectedColumnId == column.id ? .semibold : .regular)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .frame(minHeight: 44)
                        .background(
                            viewModel.selectedColumnId == column.id
                                ? Color.accentColor.opacity(0.14)
                                : Color(.secondarySystemGroupedBackground)
                        )
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(viewModel.selectedColumnId == column.id ? .isSelected : [])
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
    }

    // MARK: - Kids Sub-Selector

    private var kidsSubSelectorView: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                kidsChipButton(label: "All Kids", childId: nil)
                ForEach(viewModel.childMembers) { child in
                    kidsChipButton(label: child.name, childId: child.id)
                }
            }
            .padding(.horizontal)
        }
    }

    private func kidsChipButton(label: String, childId: String?) -> some View {
        let isActive = viewModel.selectedChildFilterId == childId
        return Button {
            viewModel.selectedChildFilterId = childId
        } label: {
            Text(label)
                .font(.caption)
                .fontWeight(.medium)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(minHeight: 44)
                .background(isActive ? Color.accentColor : Color(.systemGray5))
                .foregroundStyle(isActive ? .white : .primary)
                .cornerRadius(16)
        }
    }

    // MARK: - Day Content

    private var dayContentView: some View {
        let items = viewModel.dayPlanItems(on: viewModel.selectedDate)

        return List {
            Section("Day plan") {
                ForEach(items) { item in
                    plannerDayRow(item)
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable {
            await viewModel.loadEvents()
        }
    }

    @ViewBuilder
    private func plannerDayRow(_ item: PlannerDayItem) -> some View {
        switch item.kind {
        case .event(let event):
            Button { openEvent(event) } label: {
                plannerDayLabel(
                    item,
                    icon: event.allDay ? "calendar" : "clock.example_c6e20e62",
                    color: event.sourceColor.map(Color.init(hex:))
                        ?? viewModel.colorForEvent(event)
                )
                .padding(event.isSchoolMilestone ? 10 : 0)
                .background {
                    if event.isSchoolMilestone {
                        SchoolMilestoneBackground()
                    }
                }
            }
            .buttonStyle(.plain)
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                if event.readOnly != true {
                    Button(role: .destructive) {
                        eventToDelete = event
                        showDeleteConfirmation = true
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }

        case .coordination(let handoffs, let toast):
            Button {
                HapticManager.selection()
                coordinationDay = CoordinationDaySelection(date: viewModel.selectedDate)
            } label: {
                coordinationTimeline(handoffs: handoffs, toast: toast)
            }
            .buttonStyle(.plain)

        case .routine:
            Button { appState.openLists(.routines) } label: {
                plannerDayLabel(item, icon: "repeat", color: .teal)
            }
            .buttonStyle(.plain)

        case .task(let task):
            HStack(spacing: 0) {
                plannerDayLabel(item, icon: "checklist", color: .indigo)
                Button {
                    Task { await viewModel.completePlannerTask(task.id) }
                } label: {
                    Image(systemName: "circle")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Complete \(task.title)")
            }

        case .prep:
            Button { appState.openLists(.prepPacks) } label: {
                plannerDayLabel(item, icon: "backpack.fill", color: .teal)
            }
            .buttonStyle(.plain)
        }
    }

    private func plannerDayLabel(
        _ item: PlannerDayItem,
        icon: String,
        color: Color
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(item.timeLabel)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = item.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func coordinationTimeline(
        handoffs: [HandoffOccurrenceDTO],
        toast: [CalendarEventDTO]
    ) -> some View {
        let lanes = coordinationLanes(handoffs: handoffs, toast: toast)
        let rangeStart = 14 * 60 + 30
        let rangeEnd = 18 * 60 + 30
        let range = CGFloat(rangeEnd - rangeStart)

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Leave & pickup")
                    .font(.caption.weight(.bold))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            HStack(spacing: 0) {
                Color.clear.frame(width: 64)
                HStack {
                    Text("3pm")
                    Spacer()
                    Text("4pm")
                    Spacer()
                    Text("5pm")
                    Spacer()
                    Text("6pm")
                }
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            }
            ForEach(lanes) { lane in
                HStack(spacing: 8) {
                    Text(lane.name)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(lane.color)
                        .lineLimit(1)
                        .frame(width: 56, alignment: .leading)
                    GeometryReader { proxy in
                        let width = proxy.size.width
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(lane.color.opacity(0.55))
                                .frame(height: 2)
                                .offset(y: 20)
                            ForEach(lane.windows) { window in
                                let start = CGFloat(max(rangeStart, window.start) - rangeStart) / range
                                let end = CGFloat(min(rangeEnd, window.end) - rangeStart) / range
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(lane.color.opacity(0.14))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 5)
                                            .stroke(
                                                window.conflict ? Color.red : lane.color.opacity(0.45),
                                                style: StrokeStyle(lineWidth: 1, dash: window.conflict ? [3] : [])
                                            )
                                    }
                                    .frame(width: max(10, (end - start) * width), height: 24)
                                    .overlay {
                                        Text(window.label)
                                            .font(.system(size: 9, weight: .semibold))
                                            .foregroundStyle(lane.color)
                                            .lineLimit(1)
                                            .padding(.horizontal, 3)
                                    }
                                    .offset(x: max(0, start * width), y: 8)
                            }
                            ForEach(lane.markers) { marker in
                                let point = CGFloat(marker.at - rangeStart) / range
                                Rectangle()
                                    .fill(lane.color)
                                    .frame(width: 2, height: 38)
                                    .overlay(alignment: marker.kind == .pickup ? .bottomLeading : .topLeading) {
                                        Text(marker.label)
                                            .font(.system(size: 8, weight: .medium))
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                            .fixedSize()
                                            .offset(x: 4)
                                    }
                                    .offset(x: max(0, min(width - 2, point * width)), y: 1)
                            }
                        }
                    }
                    .frame(height: 42)
                }
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(.separator).opacity(0.45)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(coordinationAccessibilityLabel(lanes))
        .accessibilityHint("Shows details and lets you change one day")
    }

    private func coordinationLanes(
        handoffs: [HandoffOccurrenceDTO],
        toast: [CalendarEventDTO]
    ) -> [CoordinationLaneModel] {
        var lanes: [String: CoordinationLaneModel] = [:]

        for event in toast {
            let childId = viewModel.childMembers.first {
                viewModel.participantIDs(for: event).contains($0.id)
            }?.id
            let childName = childId.flatMap(viewModel.nameForMember) ?? toastChildName(event)
            let laneId = childId ?? "toast:\(childName)"
            let color = childId.map(viewModel.colorForMember) ?? .accentColor
            let startDate = viewModel.parseISO8601(event.startTime)
            let endDate = event.endTime.flatMap(viewModel.parseISO8601)
            let calendar = Calendar.current
            let start = startDate.map { calendar.component(.hour, from: $0) * 60 + calendar.component(.minute, from: $0) } ?? 930
            let end = endDate.map { calendar.component(.hour, from: $0) * 60 + calendar.component(.minute, from: $0) } ?? start
            var lane = lanes[laneId] ?? CoordinationLaneModel(
                id: laneId,
                name: childName,
                color: color,
                windows: [],
                markers: []
            )
            if !lane.windows.contains(where: {
                $0.start == start && $0.end == end && $0.conflict == (event.eventType == "toast_club_conflict")
            }) {
                lane.windows.append(
                    CoordinationWindowModel(
                        start: start,
                        end: end,
                        label: "Toast",
                        conflict: event.eventType == "toast_club_conflict"
                    )
                )
            }
            lanes[laneId] = lane
        }

        for handoff in handoffs {
            let personId = handoff.kind == .pickup
                ? handoff.termPersonId
                : handoff.ownerUserId
            let personName = handoff.kind == .pickup
                ? (handoff.termPersonName
                    ?? viewModel.nameForMember(handoff.termPersonId)
                    ?? "Child")
                : handoff.ownerName
            let label = handoff.kind == .pickup ? "pickup" : "leaves work"
            var lane = lanes[personId] ?? CoordinationLaneModel(
                id: personId,
                name: personName,
                color: viewModel.colorForMember(personId),
                windows: [],
                markers: []
            )
            let at = timeMinutes(handoff.timeOfDay)
            lane.markers.append(CoordinationMarkerModel(at: at, label: label, kind: handoff.kind))
            lanes[personId] = lane
        }

        return lanes.values.sorted {
            let left = ($0.markers.map(\.at) + $0.windows.map(\.start)).min() ?? 0
            let right = ($1.markers.map(\.at) + $1.windows.map(\.start)).min() ?? 0
            return left == right ? $0.name < $1.name : left < right
        }
    }

    private func timeMinutes(_ value: String) -> Int {
        let parts = value.split(separator: ":").compactMap { Int($0) }
        return parts.count >= 2 ? parts[0] * 60 + parts[1] : 0
    }

    private func coordinationAccessibilityLabel(_ lanes: [CoordinationLaneModel]) -> String {
        let parts = lanes.flatMap { lane in
            lane.markers.map { "\(lane.name) \($0.label) at \(String(format: "%02d:%02d", $0.at / 60, $0.at % 60))" }
                + lane.windows.map { "\(lane.name) \($0.label) window" }
        }
        return (["Leave and pickup"] + parts).joined(separator: ", ")
    }

    private func toastChildName(_ event: CalendarEventDTO) -> String {
        event.title.components(separatedBy: "·").last?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? event.title
    }

    // MARK: - Week Content

    private var weekContentView: some View {
        List {
            ForEach(viewModel.weekDayEvents, id: \.date) { dayEntry in
                let dayRoutines = viewModel.routinesForSelectedColumn(on: dayEntry.date)
                let dayTasks = viewModel.tasksForSelectedColumn(on: dayEntry.date)
                let dayHandoffs = viewModel.handoffsForDate(dayEntry.date)
                let toastEvents = dayEntry.events.filter(\.isToastProjection)
                let standardEvents = dayEntry.events.filter { !$0.isToastProjection }
                Section {
                    if !dayHandoffs.isEmpty || !toastEvents.isEmpty {
                        Button {
                            HapticManager.selection()
                            coordinationDay = CoordinationDaySelection(date: dayEntry.date)
                        } label: {
                            coordinationTimeline(handoffs: dayHandoffs, toast: toastEvents)
                        }
                        .buttonStyle(.plain)
                    }

                    ForEach(standardEvents) { event in
                        EventCardView(
                            event: event,
                            displayDate: dayEntry.date,
                            viewModel: viewModel,
                            onSelect: { openEvent(event) }
                        )
                    }

                    ForEach(routineMembers(for: dayRoutines)) { member in
                        calendarRoutineGroupRow(
                            member: member,
                            routines: dayRoutines.filter { $0.personId == member.id }
                        )
                    }

                    ForEach(dayTasks.prefix(3)) { task in
                        calendarTaskRow(task)
                    }

                } header: {
                    Text(Self.dayHeaderFormatter.string(from: dayEntry.date))
                        .font(.subheadline.weight(.semibold))
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable {
            await viewModel.loadEvents()
        }
    }

    // MARK: - Month Content

    private var monthContentView: some View {
        let dates = viewModel.monthGridDates(calendar: displayCalendar)
        let eventsByDate = viewModel.eventsByDay(
            for: dates,
            columnId: viewModel.selectedColumnId,
            calendar: displayCalendar
        )
        let selectedEvents = viewModel.eventsForColumn(
            viewModel.selectedColumnId,
            on: viewModel.selectedDate,
            calendar: displayCalendar
        )
        let selectedHandoffs = viewModel.handoffsForDate(viewModel.selectedDate)

        return ScrollView {
            VStack(spacing: 16) {
                MonthCalendarGrid(
                    viewModel: viewModel,
                    dates: dates,
                    eventsByDate: eventsByDate,
                    calendar: displayCalendar,
                    onEventSelect: openEvent,
                    onCoordinationSelect: { coordinationDay = CoordinationDaySelection(date: $0) }
                )
                .padding(.horizontal, 8)

                monthSelectedDayPreview(
                    events: selectedEvents,
                    handoffs: selectedHandoffs
                )
                    .padding(.horizontal)
            }
            .padding(.vertical, 12)
        }
        .background(Color(.systemGroupedBackground))
        .accessibilityIdentifier("calendarMonthView")
        .refreshable {
            await viewModel.loadEvents()
        }
    }

    private func monthSelectedDayPreview(
        events: [CalendarEventDTO],
        handoffs: [HandoffOccurrenceDTO]
    ) -> some View {
        let toastEvents = events.filter(\.isToastProjection)
        let standardEvents = events.filter { !$0.isToastProjection }
        return VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 12) {
                    monthSelectedDateLabel
                    Spacer()
                    openFullDayButton
                }

                VStack(alignment: .leading, spacing: 8) {
                    monthSelectedDateLabel
                    openFullDayButton
                }
            }

            Divider()

            if events.isEmpty && handoffs.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Label("No calendar events", systemImage: "calendar")
                        .font(.subheadline.weight(.semibold))
                    Text("Add an event here or open the full day for routines, tasks and meals.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Button {
                        prepareNewEvent(on: viewModel.selectedDate)
                    } label: {
                        Label("Add event", systemImage: "calendar.badge.plus")
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(spacing: 0) {
                    if !handoffs.isEmpty || !toastEvents.isEmpty {
                        Button {
                            HapticManager.selection()
                            coordinationDay = CoordinationDaySelection(date: viewModel.selectedDate)
                        } label: {
                            coordinationTimeline(handoffs: handoffs, toast: toastEvents)
                        }
                        .buttonStyle(.plain)
                        Divider()
                    }
                    ForEach(Array(standardEvents.enumerated()), id: \.element.id) { index, event in
                        EventCardView(
                            event: event,
                            displayDate: viewModel.selectedDate,
                            viewModel: viewModel,
                            onSelect: { openEvent(event) }
                        )
                        .padding(.vertical, 4)

                        if index < standardEvents.count - 1 {
                            Divider()
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(
            Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 16)
        )
        .accessibilityElement(children: .contain)
    }

    private var monthSelectedDateLabel: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(viewModel.selectedDate, format: .dateTime.weekday(.wide))
                .font(.headline)
            Text(viewModel.selectedDate, format: .dateTime.day().month(.wide))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var openFullDayButton: some View {
        Button {
            HapticManager.selection()
            viewModel.openSelectedDateInDayView()
        } label: {
            Label("Open full day", systemImage: "arrow.right")
                .labelStyle(.titleAndIcon)
                .frame(minHeight: 44)
        }
        .buttonStyle(.bordered)
        .accessibilityHint("Shows routines, tasks and meals for this date")
    }

    private func calendarRoutineGroupRow(
        member: FamilyMemberDTO,
        routines: [ActiveRoutineDTO]
    ) -> some View {
        Button {
            appState.openLists(.routines)
        } label: {
            HStack(spacing: 12) {
                Circle()
                    .fill(routines.first.map { Color(hex: $0.color) } ?? Color.accentColor)
                    .frame(width: 9, height: 9)
                VStack(alignment: .leading, spacing: 2) {
                    Text(member.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(routines.map(\.name).joined(separator: ", "))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Image(systemName: "repeat")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
    }

    private func routineMembers(for routines: [ActiveRoutineDTO]) -> [FamilyMemberDTO] {
        let ids = Set(routines.map(\.personId))
        return viewModel.familyMembers.filter { ids.contains($0.id) }
    }

    private func calendarTaskRow(_ task: TaskDTO) -> some View {
        HStack(spacing: 12) {
            Button {
                Task { await viewModel.completePlannerTask(task.id) }
            } label: {
                Image(systemName: "circle")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Complete \(task.title)")

            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                if let managedCategory = task.managedCategoryLabel {
                    Label(
                        managedCategory,
                        systemImage: task.isLibraryManaged ? "books.vertical" : "wallet.bifold"
                    )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !task.assignees.isEmpty {
                    Text(task.assignees.compactMap(\.assigneeName).joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Image(systemName: "checklist")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private func prepareNewEvent(on date: Date) {
        viewModel.prepareNewEvent(on: date)
        viewModel.showingAddEvent = true
    }

    // MARK: - Columns Content (All fitted to screen)

    private var columnsContentView: some View {
        // Build column entries dynamically from family members
        let isLandscape = verticalSizeClass == .compact

        // personId: nil = grouped kids, "" = unassigned/everyone, else = specific person
        var entries: [(label: String, color: Color, personId: String?)] = []
        for adult in viewModel.adults {
            entries.append((adult.name, viewModel.colorForMember(adult.id), adult.id))
        }
        if isLandscape {
            for child in viewModel.childMembers {
                entries.append((child.name, viewModel.colorForMember(child.id), child.id))
            }
        } else if !viewModel.childMembers.isEmpty {
            entries.append(("Kids", .green, nil))  // nil = all kids grouped
        }
        entries.append(("All", .purple, ""))  // empty string = unassigned

        return ScrollView {
            HStack(alignment: .top, spacing: 1) {
                ForEach(entries, id: \.label) { entry in
                    let events: [CalendarEventDTO] = {
                        if entry.personId == nil {
                            // All kids grouped
                            return viewModel.eventsForColumn("__kids__", on: viewModel.selectedDate)
                        } else if entry.personId == "" {
                            // Unassigned / Everyone
                            return viewModel.eventsForColumn("__everyone__", on: viewModel.selectedDate)
                        } else if let personId = entry.personId {
                            return viewModel.eventsForPerson(personId, on: viewModel.selectedDate)
                        } else {
                            return []
                        }
                    }()

                    let allDayEvents = events.filter { $0.allDay }
                    let timedEvents = events.filter { !$0.allDay }

                    VStack(spacing: 0) {
                        // Header
                        HStack(spacing: 3) {
                            Text(entry.label)
                                .font(.caption)
                                .fontWeight(.bold)
                                .foregroundStyle(entry.color)
                            if let bubble = viewModel.termBubble(forPersonId: entry.personId) {
                                Text(bubble)
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.white)
                                    .frame(width: 14, height: 14)
                                    .background(bubble == "H" ? Color.orange : Color.green)
                                    .clipShape(Circle())
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(entry.color.opacity(0.1))

                        Divider()

                        // Routine pills + all-day event pills
                        let colRoutines: [ActiveRoutineDTO] = {
                            if entry.personId == nil {
                                return viewModel.routinesForKids(on: viewModel.selectedDate)
                            } else if entry.personId == "" {
                                return []
                            } else if let personId = entry.personId {
                                return viewModel.routinesForPerson(personId, on: viewModel.selectedDate)
                            } else {
                                return []
                            }
                        }()
                        if !colRoutines.isEmpty || !allDayEvents.isEmpty {
                            VStack(spacing: 2) {
                                ForEach(colRoutines) { routine in
                                    routinePill(routine)
                                }
                                ForEach(allDayEvents) { event in
                                    allDayEventPill(
                                        event,
                                        color: viewModel.colorForEvent(event),
                                        displayDate: viewModel.selectedDate,
                                        viewModel: viewModel,
                                        onSelect: { openEvent(event) }
                                    )
                                }
                            }
                            .padding(.vertical, 2)
                        }

                        // Timed events
                        if timedEvents.isEmpty && colRoutines.isEmpty && allDayEvents.isEmpty {
                            Text("--")
                                .font(.caption2)
                                .foregroundStyle(.quaternary)
                                .padding(.vertical, 20)
                        } else {
                            VStack(spacing: 0) {
                                ForEach(timedEvents) { event in
                                    compactEventCard(
                                        event,
                                        color: entry.color,
                                        displayDate: viewModel.selectedDate,
                                        onSelect: { openEvent(event) }
                                    )
                                    if event.id != timedEvents.last?.id {
                                        Divider()
                                    }
                                }
                            }
                        }

                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity)
                    .background(Color(.secondarySystemGroupedBackground))
                }
            }
            .background(Color(.separator).opacity(0.3))
            .cornerRadius(12)
            .padding(.horizontal)
            .padding(.top, 8)
        }
        .refreshable {
            await viewModel.loadEvents()
        }
    }

    private func compactEventCard(
        _ event: CalendarEventDTO,
        color: Color,
        displayDate: Date,
        onSelect: @escaping () -> Void
    ) -> some View {
        let timeLabel = viewModel.occurrenceTimeLabel(for: event, on: displayDate)

        return Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 1) {
                if !event.allDay {
                    Text(timeLabel)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                Text(event.title)
                    .font(.system(size: 11))
                    .fontWeight(.medium)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.horizontal, 4)
            .padding(.vertical, 5)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(event.title), \(timeLabel)")
        .accessibilityHint("Opens event details")
    }

    // MARK: - Kids Columns Content (children side by side)

    private var kidsColumnsContentView: some View {
        let children = viewModel.childMembers

        return ScrollView {
            if children.isEmpty {
                VStack(spacing: 16) {
                    Spacer()
                    Text("No children in this family")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(alignment: .top, spacing: 1) {
                    ForEach(children) { child in
                        let childColor = viewModel.colorForMember(child.id)
                        let events = viewModel.eventsForPerson(child.id, on: viewModel.selectedDate)
                        let allDayEvents = events.filter { $0.allDay }
                        let timedEvents = events.filter { !$0.allDay }

                        VStack(spacing: 0) {
                            // Header
                            HStack(spacing: 3) {
                                Text(child.name)
                                    .font(.caption)
                                    .fontWeight(.bold)
                                    .foregroundStyle(childColor)
                                if let bubble = viewModel.termBubble(forPersonId: child.id) {
                                    Text(bubble)
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(.white)
                                        .frame(width: 14, height: 14)
                                        .background(bubble == "H" ? Color.orange : Color.green)
                                        .clipShape(Circle())
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(childColor.opacity(0.1))

                            Divider()

                            // Routine pills + all-day event pills
                            let kidRoutines = viewModel.routinesForPerson(child.id, on: viewModel.selectedDate)
                            if !kidRoutines.isEmpty || !allDayEvents.isEmpty {
                                VStack(spacing: 2) {
                                    ForEach(kidRoutines) { routine in
                                        routinePill(routine)
                                    }
                                    ForEach(allDayEvents) { event in
                                        allDayEventPill(
                                            event,
                                            color: viewModel.colorForEvent(event),
                                            displayDate: viewModel.selectedDate,
                                            viewModel: viewModel,
                                            onSelect: { openEvent(event) }
                                        )
                                    }
                                }
                                .padding(.vertical, 2)
                            }

                            // Timed events
                            if timedEvents.isEmpty && kidRoutines.isEmpty && allDayEvents.isEmpty {
                                Text("--")
                                    .font(.caption2)
                                    .foregroundStyle(.quaternary)
                                    .padding(.vertical, 20)
                            } else {
                                VStack(spacing: 0) {
                                    ForEach(timedEvents) { event in
                                        compactEventCard(
                                            event,
                                            color: childColor,
                                            displayDate: viewModel.selectedDate,
                                            onSelect: { openEvent(event) }
                                        )
                                        if event.id != timedEvents.last?.id {
                                            Divider()
                                        }
                                    }
                                }
                            }

                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity)
                        .background(Color(.secondarySystemGroupedBackground))
                    }
                }
                .background(Color(.separator).opacity(0.3))
                .cornerRadius(12)
                .padding(.horizontal)
                .padding(.top, 8)
            }
        }
        .refreshable {
            await viewModel.loadEvents()
        }
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "calendar.badge.plus")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No events on this day")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Tap + to add an event")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Loading State

    private var loadingView: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView()
                .controlSize(.large)
            Text("Loading events...")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("calendarLoadingState")
    }

    // MARK: - Error State

    private func errorView(message: String) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Retry") {
                Task {
                    await viewModel.loadEvents()
                }
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("calendarRetry")
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("calendarErrorState")
    }

    // MARK: - Add Event Sheet

    private var addEventSheet: some View {
        NavigationStack {
            Form {
                Section("Title") {
                    TextField("Title", text: $viewModel.formTitle)
                        .textInputAutocapitalization(.sentences)
                }

                Section("When") {
                    Toggle("All Day", isOn: Binding(
                        get: { viewModel.formAllDay },
                        set: { viewModel.setFormAllDay($0) }
                    ))

                    if viewModel.formAllDay {
                        DatePicker(
                            "Date",
                            selection: Binding(
                                get: { viewModel.formStartTime },
                                set: { viewModel.setFormStartTime($0) }
                            ),
                            displayedComponents: .date
                        )
                        Toggle("Multi-day", isOn: Binding(
                            get: { viewModel.formAllDayIsMultiDay },
                            set: { viewModel.setFormAllDayMultiDay($0) }
                        ))
                        if viewModel.formAllDayIsMultiDay {
                            DatePicker(
                                "Last day",
                                selection: Binding(
                                    get: { viewModel.formAllDayEndDate },
                                    set: { viewModel.setFormAllDayEndDate($0) }
                                ),
                                in: viewModel.formStartTime...,
                                displayedComponents: .date
                            )
                        }
                    } else {
                        DatePicker(
                            "Start",
                            selection: Binding(
                                get: { viewModel.formStartTime },
                                set: { viewModel.setFormStartTime($0) }
                            )
                        )
                        Picker(
                            "Duration",
                            selection: Binding(
                                get: { viewModel.formDurationOption },
                                set: { viewModel.setFormDuration($0) }
                            )
                        ) {
                            ForEach(CalendarEventDurationOption.allCases) { option in
                                Text(option.label.localized).tag(option)
                            }
                        }
                        if viewModel.formDurationOption == .custom {
                            DatePicker(
                                "End",
                                selection: Binding(
                                    get: { viewModel.formEndTime },
                                    set: { viewModel.setFormEndTime($0) }
                                ),
                                in: viewModel.formStartTime.addingTimeInterval(60)...
                            )
                        }
                    }

                }

                if viewModel.eventPeopleEditingUnavailable {
                    Section("Who is going?") {
                        Label(
                            "Family members could not be loaded. Existing people will be kept.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .foregroundStyle(.secondary)
                        Button("Retry") {
                            Task { await viewModel.loadFamilyMembers() }
                        }
                        .frame(minHeight: 44)
                    }
                } else {
                    Section("Who is going?") {
                        Toggle("Everyone", isOn: Binding(
                            get: { viewModel.formEveryoneSelected },
                            set: { viewModel.setFormEveryone($0) }
                        ))
                        ForEach(viewModel.familyMembers) { member in
                            Toggle(member.name, isOn: Binding(
                                get: { viewModel.formParticipantIDs.contains(member.id) },
                                set: { viewModel.setFormParticipant(member.id, selected: $0) }
                            ))
                        }
                    }
                }

                Section {
                    DisclosureGroup("More", isExpanded: $showingEventMore) {
                        if viewModel.editingRecurrenceScope == .onlyThis {
                            LabeledContent("Repeat") {
                                Text("Only this event")
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            Picker("Repeat", selection: Binding(
                                get: { viewModel.formRecurrence },
                                set: { viewModel.setFormRecurrence($0) }
                            )) {
                                Text("Never").tag("never")
                                Text("Daily").tag("daily")
                                Text("Weekly").tag("weekly")
                                Text("Monthly").tag("monthly")
                                Text("Yearly").tag("yearly")
                            }
                        }

                        if !viewModel.formOtherAdults.isEmpty {
                            ForEach(viewModel.formOtherAdults) { adult in
                                Toggle("Affects \(adult.name) too", isOn: Binding(
                                    get: { viewModel.formAffectedMemberIDs.contains(adult.id) },
                                    set: { viewModel.setFormAffectedAdult(adult.id, selected: $0) }
                                ))
                            }
                            Text("Add someone whose plan changes because they need to cover the rest of the family.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        TextField("Location", text: $viewModel.formLocation)
                        TextField("Notes", text: $viewModel.formDescription, axis: .vertical)
                            .lineLimit(3...6)

                        ForEach(viewModel.formAttachments) { attachment in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 10) {
                                    Image(systemName: "doc.fill")
                                        .foregroundStyle(Color.accentColor)
                                    Text(
                                        viewModel.documentForFormAttachment(attachment)?.title
                                            ?? "Attached document"
                                    )
                                    .lineLimit(1)
                                    Spacer()
                                    Button(role: .destructive) {
                                        viewModel.removeFormAttachment(
                                            documentId: attachment.documentId
                                        )
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .frame(width: 32, height: 32)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Remove document")
                                }

                                Picker("Document type", selection: Binding(
                                    get: { attachment.role },
                                    set: {
                                        viewModel.setFormAttachmentRole(
                                            documentId: attachment.documentId,
                                            role: $0
                                        )
                                    }
                                )) {
                                    ForEach(CalendarEventAttachmentRole.allCases) { role in
                                        Text(role.label).tag(role)
                                    }
                                }
                                .pickerStyle(.menu)
                            }
                            .padding(.vertical, 4)
                        }

                        Button {
                            showingDocumentPicker = true
                        } label: {
                            Label(
                                viewModel.formAttachments.isEmpty
                                    ? "Attach a document" : "Add another document",
                                systemImage: "paperclip"
                            )
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        }

                        if viewModel.editingEvent?.readOnly == true {
                            DisclosureGroup("Imported source") {
                                Text("Saving makes an editable HausKlar copy. The imported source stays unchanged.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                if let scope = viewModel.editingRecurrenceScope {
                    Section("Repeating event") {
                        Label(scope.label, systemImage: "repeat")
                        Text(recurrenceScopeExplanation(scope))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                if let errorMessage = viewModel.errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }
            }
            .navigationTitle(viewModel.editingEvent == nil ? "New Event" : "Edit Event")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        viewModel.showingAddEvent = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            await viewModel.saveEvent()
                        }
                    }
                    .disabled(
                        viewModel.formTitle.trimmingCharacters(in: .whitespaces).isEmpty
                            || (!viewModel.formWholeFamily
                                && viewModel.familyMembersAvailable
                                && viewModel.formParticipantIDs.isEmpty)
                            || viewModel.isLoading
                    )
                }
            }
            .sheet(isPresented: $showingDocumentPicker) {
                DocumentAttachmentPicker(selectedDocument: nil) { document in
                    if let document {
                        viewModel.addFormAttachment(document)
                    }
                }
            }
        }
    }

    private func recurrenceScopeExplanation(
        _ scope: CalendarRecurrenceMutationScope
    ) -> String {
        switch scope {
        case .onlyThis:
            "Other events in the series stay unchanged."
        case .thisAndLater:
            "Earlier events stay unchanged. This event starts a new series."
        case .entireSeries:
            "Your changes apply to every event in the series."
        }
    }
}

// MARK: - All-Day Event Pill

/// A compact pill for an all-day calendar event, colored by assignment.
@MainActor
private func allDayEventPill(
    _ event: CalendarEventDTO,
    color: Color,
    displayDate: Date,
    viewModel: CalendarViewModel,
    onSelect: @escaping () -> Void
) -> some View {
    let timeLabel = viewModel.occurrenceTimeLabel(for: event, on: displayDate)

    return Button(action: onSelect) {
        Text("\(timeLabel) · \(event.title)")
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 6)
            .frame(minHeight: 44)
            .background(color.opacity(0.2))
            .foregroundStyle(color)
            .cornerRadius(8)
    }
        .buttonStyle(.plain)
        .accessibilityLabel("\(event.title), \(timeLabel)")
        .accessibilityHint("Opens event details")
}

// MARK: - Routine Pill

/// A compact pill for a routine item.
private func routinePill(_ routine: ActiveRoutineDTO) -> some View {
    Text(routine.name)
        .font(.system(size: 10, weight: .medium))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color(hex: routine.color).opacity(0.2))
        .foregroundStyle(Color(hex: routine.color))
        .cornerRadius(8)
}

/// A horizontal flow of routine pills.
private struct SchoolClubManagerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: CalendarViewModel
    @State private var editingClub: SchoolClubDTO?
    @State private var showingEditor = false
    @State private var clubToDelete: SchoolClubDTO?

    private static let weekdays = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday"]

    var body: some View {
        NavigationStack {
            List {
                if viewModel.schoolClubs.isEmpty && !viewModel.schoolClubBusy {
                    ContentUnavailableView(
                        "No clubs yet",
                        systemImage: "figure.run.circle"
                    )
                } else {
                    ForEach(viewModel.schoolClubs) { club in
                        Button {
                            editingClub = club
                            showingEditor = true
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "figure.run.circle.fill")
                                    .font(.title3)
                                    .foregroundStyle(Color(hex: club.color))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(club.name)
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(.primary)
                                    Text(
                                        "\(club.childName) · \(dayLabel(club.weekday))s · \(club.startTime)–\(club.endTime)"
                                    )
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            .frame(minHeight: 48)
                        }
                        .buttonStyle(.plain)
                        .swipeActions {
                            Button(role: .destructive) {
                                clubToDelete = club
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                    }
                }

                if let error = viewModel.schoolClubError {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .overlay {
                if viewModel.schoolClubBusy && viewModel.schoolClubs.isEmpty {
                    ProgressView()
                }
            }
            .navigationTitle("Clubs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add", systemImage: "plus") {
                        editingClub = nil
                        showingEditor = true
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Text("Term time only · sessions appear in Calendar")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(10)
                    .background(.bar)
            }
            .task { await viewModel.loadSchoolClubs() }
            .sheet(isPresented: $showingEditor) {
                SchoolClubEditorSheet(
                    viewModel: viewModel,
                    club: editingClub
                )
            }
            .confirmationDialog(
                "Remove \(clubToDelete?.name ?? "club")?",
                isPresented: Binding(
                    get: { clubToDelete != nil },
                    set: { if !$0 { clubToDelete = nil } }
                )
            ) {
                Button("Remove", role: .destructive) {
                    guard let club = clubToDelete else { return }
                    Task {
                        if await viewModel.deleteSchoolClub(club) {
                            HapticManager.success()
                            clubToDelete = nil
                        }
                    }
                }
                Button("Cancel", role: .cancel) { clubToDelete = nil }
            } message: {
                Text("Future sessions will disappear from Calendar.")
            }
        }
    }

    private func dayLabel(_ weekday: Int) -> String {
        guard Self.weekdays.indices.contains(weekday) else { return "Club" }
        return Self.weekdays[weekday]
    }
}

private struct SchoolClubEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: CalendarViewModel
    let club: SchoolClubDTO?

    @State private var name: String
    @State private var childId: String
    @State private var weekday: Int
    @State private var start: Date
    @State private var end: Date

    private static let weekdays = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday"]
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    init(viewModel: CalendarViewModel, club: SchoolClubDTO?) {
        self.viewModel = viewModel
        self.club = club
        _name = State(initialValue: club?.name ?? "")
        _childId = State(initialValue: club?.childId ?? viewModel.childMembers.first?.id ?? "")
        _weekday = State(initialValue: club?.weekday ?? 0)
        _start = State(initialValue: Self.timeFormatter.date(from: club?.startTime ?? "15:30") ?? Date())
        _end = State(initialValue: Self.timeFormatter.date(from: club?.endTime ?? "16:30") ?? Date())
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Club", text: $name)
                    .textInputAutocapitalization(.words)
                Picker("Child", selection: $childId) {
                    ForEach(viewModel.childMembers) { child in
                        Text(child.name).tag(child.id)
                    }
                }
                Picker("Day", selection: $weekday) {
                    ForEach(Array(Self.weekdays.enumerated()), id: \.offset) { index, day in
                        Text(day).tag(index)
                    }
                }
                DatePicker("Starts", selection: $start, displayedComponents: .hourAndMinute)
                DatePicker("Ends", selection: $end, displayedComponents: .hourAndMinute)
                if let error = viewModel.schoolClubError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .navigationTitle(club == nil ? "Add club" : "Edit club")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            if await viewModel.saveSchoolClub(
                                existing: club,
                                name: name,
                                childId: childId,
                                weekday: weekday,
                                startTime: Self.timeFormatter.string(from: start),
                                endTime: Self.timeFormatter.string(from: end)
                            ) {
                                HapticManager.success()
                                dismiss()
                            }
                        }
                    }
                    .disabled(
                        viewModel.schoolClubBusy
                            || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || childId.isEmpty || end <= start
                    )
                }
            }
        }
    }
}

private struct ToastClubManagerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: CalendarViewModel
    @State private var showingFileImporter = false

    private static let inputDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
    private static let displayDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateFormat = "d MMM"
        return formatter
    }()

    var body: some View {
        NavigationStack {
            List {
                if let preview = viewModel.toastImportPreview {
                    Section {
                        LabeledContent("Child", value: preview.childName)
                        LabeledContent("Dates", value: dateRange(preview.validFrom, preview.validTo))
                        LabeledContent("Booked", value: "\(preview.bookedDays) days")
                        LabeledContent(
                            "Pickup by",
                            value: "\(preview.until1630) × 4:30 · \(preview.until1730) × 5:30"
                        )
                    }
                    if !preview.alreadyImported {
                        Section {
                            Text(
                                "\(preview.changes.added) new · \(preview.changes.changed) changed · \(preview.changes.removed) removed"
                            )
                            .foregroundStyle(.secondary)
                            Button {
                                Task {
                                    if await viewModel.confirmToastBooking() {
                                        HapticManager.success()
                                    }
                                }
                            } label: {
                                if viewModel.toastImportBusy {
                                    ProgressView()
                                } else {
                                    Label("Use these dates", systemImage: "checkmark")
                                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                }
                            }
                            .disabled(viewModel.toastImportBusy)
                        }
                    }
                } else if viewModel.toastImportStatus.isEmpty && !viewModel.toastImportBusy {
                    ContentUnavailableView(
                        "No booking forms yet",
                        systemImage: "clock.arrow.2.circlepath"
                    )
                } else {
                    ForEach(viewModel.toastImportStatus) { status in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(status.childName)
                                    .font(.body.weight(.semibold))
                                Text(dateRange(status.validFrom, status.validTo))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(status.bookedDays) days")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        .frame(minHeight: 48)
                    }
                }

                if let notice = viewModel.toastImportNotice {
                    Section {
                        Label(notice, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
                if let error = viewModel.toastImportError {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .overlay {
                if viewModel.toastImportBusy && viewModel.toastImportPreview == nil {
                    ProgressView("Reading…")
                }
            }
            .navigationTitle("Toast Club")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add form", systemImage: "doc.badge.plus") {
                        showingFileImporter = true
                    }
                    .disabled(viewModel.toastImportBusy)
                }
            }
            .task { await viewModel.loadToastImportStatus() }
            .fileImporter(
                isPresented: $showingFileImporter,
                allowedContentTypes: [UTType(filenameExtension: "docx") ?? .data]
            ) { result in
                switch result {
                case .success(let url):
                    Task { await viewModel.previewToastBooking(at: url) }
                case .failure(let error):
                    if (error as? CocoaError)?.code != .userCancelled {
                        viewModel.reportToastPickerError(error)
                    }
                }
            }
        }
    }

    private func dateRange(_ start: String, _ end: String) -> String {
        guard let startDate = Self.inputDateFormatter.date(from: start),
              let endDate = Self.inputDateFormatter.date(from: end) else {
            return "\(start) – \(end)"
        }
        return "\(Self.displayDateFormatter.string(from: startDate)) – \(Self.displayDateFormatter.string(from: endDate))"
    }
}

private struct HandoffDayDraft: Identifiable {
    var id: Int { weekday }
    let weekday: Int
    var time = ""
}

private struct HandoffPersonDraft: Identifiable {
    var id: String { "\(kind.rawValue):\(personId)" }
    let kind: HandoffKindDTO
    let personId: String
    let personName: String
    var days: [HandoffDayDraft]
}

private struct HandoffScheduleSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: CalendarViewModel
    let currentUserId: String?

    @State private var people: [HandoffPersonDraft] = []
    @State private var pickupPerson = ""
    @State private var workPerson = ""
    @State private var didLoad = false

    private static let weekdays = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday"]
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private var adults: [FamilyMemberDTO] {
        viewModel.familyMembers.filter { $0.memberType == "user" }
    }

    private var children: [FamilyMemberDTO] {
        viewModel.familyMembers.filter { $0.memberType == "child" }
    }

    var body: some View {
        NavigationStack {
            Form {
                if viewModel.handoffBusy && !didLoad {
                    Section {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                    }
                } else {
                    if let pickupIndex = people.firstIndex(where: {
                        $0.kind == .pickup && $0.personId == pickupPerson
                    }) {
                        Section {
                            Picker("Child", selection: $pickupPerson) {
                                ForEach(children) { child in
                                    Text(child.name).tag(child.id)
                                }
                            }
                            ForEach($people[pickupIndex].days) { $day in
                                scheduleRow(
                                    title: Self.weekdays[day.weekday],
                                    defaultTime: "16:00",
                                    time: $day.time
                                )
                            }
                        } header: {
                            Text("Pickup")
                        } footer: {
                            Text("Uses \(people[pickupIndex].personName)’s term dates.")
                        }
                    }

                    if let workIndex = people.firstIndex(where: {
                        $0.kind == .workDeparture && $0.personId == workPerson
                    }) {
                        Section {
                            Picker("Person", selection: $workPerson) {
                                ForEach(adults) { adult in
                                    Text(adult.name).tag(adult.id)
                                }
                            }
                            ForEach($people[workIndex].days) { $day in
                                scheduleRow(
                                    title: Self.weekdays[day.weekday],
                                    defaultTime: "17:00",
                                    time: $day.time
                                )
                            }
                        } header: {
                            Text("Leaves work")
                        } footer: {
                            Text("Uses \(people[workIndex].personName)’s term dates.")
                        }
                    }
                }

                if let error = viewModel.handoffError {
                    Section {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Leave & pickup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task { await save() }
                    }
                    .disabled(viewModel.handoffBusy)
                }
            }
            .task {
                await viewModel.loadHandoffSchedule()
                applyLoadedSchedule()
                didLoad = true
            }
        }
    }

    @ViewBuilder
    private func scheduleRow(
        title: String,
        defaultTime: String,
        time: Binding<String>
    ) -> some View {
        HStack(spacing: 8) {
            Text(title)
            Spacer(minLength: 8)
            if time.wrappedValue.isEmpty {
                Button("Add") {
                    time.wrappedValue = defaultTime
                }
                .frame(minHeight: 44)
            } else {
                DatePicker(
                    title,
                    selection: timeBinding(time),
                    displayedComponents: .hourAndMinute
                )
                .labelsHidden()
                .accessibilityLabel("\(title) time")

                Button {
                    time.wrappedValue = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                        .frame(width: 32, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(title.lowercased())")
            }
        }
    }

    private func timeBinding(_ value: Binding<String>) -> Binding<Date> {
        Binding(
            get: {
                Self.timeFormatter.date(from: value.wrappedValue)
                    ?? Self.timeFormatter.date(from: "16:00")!
            },
            set: { value.wrappedValue = Self.timeFormatter.string(from: $0) }
        )
    }

    private func applyLoadedSchedule() {
        let schedule = viewModel.handoffSchedule
        let fallbackWorkOwner = adults.first(where: { $0.id == currentUserId })?.id
            ?? adults.first?.id
            ?? ""
        pickupPerson = children.first?.id ?? ""
        workPerson = fallbackWorkOwner
        people = children.map { child in
            let items = schedule.filter {
                $0.kind == .pickup && $0.termPersonId == child.id
            }
            return HandoffPersonDraft(
                kind: .pickup,
                personId: child.id,
                personName: child.name,
                days: (0..<5).map { weekday in
                    let item = items.first { $0.weekday == weekday }
                    return HandoffDayDraft(
                        weekday: weekday,
                        time: item?.timeOfDay ?? ""
                    )
                }
            )
        } + adults.map { adult in
            HandoffPersonDraft(
                kind: .workDeparture,
                personId: adult.id,
                personName: adult.name,
                days: (0..<5).map { weekday in
                    let item = schedule.first {
                        $0.kind == .workDeparture
                            && $0.termPersonId == adult.id
                            && $0.weekday == weekday
                    }
                    return HandoffDayDraft(
                        weekday: weekday,
                        time: item?.timeOfDay ?? ""
                    )
                }
            )
        }
    }

    private func save() async {
        var items: [HandoffScheduleItemRequest] = []
        for person in people {
            for day in person.days where !day.time.isEmpty {
                items.append(
                    HandoffScheduleItemRequest(
                        kind: person.kind,
                        weekday: day.weekday,
                        timeOfDay: day.time,
                        termPersonId: person.personId,
                        ownerUserId: person.kind == .workDeparture
                            ? person.personId
                            : nil
                    )
                )
            }
        }
        if await viewModel.saveHandoffSchedule(items) {
            HapticManager.success()
            dismiss()
        }
    }
}

private struct CoordinationDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    let date: Date
    @ObservedObject var viewModel: CalendarViewModel

    @State private var editingHandoff: HandoffOccurrenceDTO?
    @State private var showingSchedule = false

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateFormat = "EEE d MMM"
        return formatter
    }()

    private var handoffs: [HandoffOccurrenceDTO] {
        viewModel.handoffsForDate(date)
    }

    private var toast: [CalendarEventDTO] {
        viewModel.eventsForColumn(viewModel.selectedColumnId, on: date)
            .filter(\.isToastProjection)
    }

    var body: some View {
        NavigationStack {
            List {
                if !handoffs.isEmpty {
                    Section {
                        ForEach(handoffs) { handoff in
                            Button {
                                editingHandoff = handoff
                            } label: {
                                HStack(spacing: 10) {
                                    Circle()
                                        .fill(
                                            viewModel.colorForMember(
                                                handoff.kind == .pickup
                                                    ? handoff.termPersonId
                                                    : handoff.ownerUserId
                                            )
                                        )
                                        .frame(width: 8, height: 8)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(
                                            handoff.kind == .pickup
                                                ? "\(handoff.termPersonName ?? viewModel.nameForMember(handoff.termPersonId) ?? "Child") pickup"
                                                : "\(handoff.ownerName) leaves work"
                                        )
                                        .foregroundStyle(.primary)
                                        if handoff.isOverride {
                                            Text("Changed today")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    Text(handoff.timeOfDay)
                                        .font(.subheadline.monospacedDigit().weight(.semibold))
                                        .foregroundStyle(.secondary)
                                    Image(systemName: "pencil")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                                .frame(minHeight: 44)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if !toast.isEmpty {
                    Section("Toast") {
                        ForEach(toast) { event in
                            HStack(spacing: 10) {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color.accentColor.opacity(0.16))
                                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.accentColor.opacity(0.4)))
                                    .frame(width: 12, height: 26)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(event.title.components(separatedBy: "·").last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? event.title)
                                    Text("Pickup window")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(viewModel.formattedTimeRange(start: event.startTime, end: event.endTime))
                                    .font(.caption.monospacedDigit().weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                            .frame(minHeight: 44)
                        }
                    }
                }
            }
            .navigationTitle("Leave & pickup · \(Self.dateFormatter.string(from: date))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Edit week") { showingSchedule = true }
                }
            }
            .sheet(item: $editingHandoff) { handoff in
                HandoffDayEditSheet(handoff: handoff, viewModel: viewModel)
            }
            .sheet(isPresented: $showingSchedule) {
                HandoffScheduleSheet(viewModel: viewModel, currentUserId: nil)
            }
        }
    }
}

private struct HandoffDayEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    let handoff: HandoffOccurrenceDTO
    @ObservedObject var viewModel: CalendarViewModel

    @State private var time: Date

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateFormat = "EEE d MMM"
        return formatter
    }()

    init(handoff: HandoffOccurrenceDTO, viewModel: CalendarViewModel) {
        self.handoff = handoff
        self.viewModel = viewModel
        _time = State(
            initialValue: Self.timeFormatter.date(from: handoff.timeOfDay)
                ?? Date()
        )
    }

    private var dayLabel: String {
        guard let date = MealFormatters.dateOnly.date(from: handoff.date) else {
            return handoff.date
        }
        return Self.dateFormatter.string(from: date)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Day", value: dayLabel)
                    DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                }

                Section {
                    Button("Not this day", role: .destructive) {
                        Task { await change(cancelled: true) }
                    }
                    .disabled(viewModel.handoffBusy)
                    if handoff.isOverride {
                        Button("Use weekly time") {
                            Task {
                                if await viewModel.restoreWeeklyHandoff(handoff) {
                                    HapticManager.success()
                                    dismiss()
                                }
                            }
                        }
                        .disabled(viewModel.handoffBusy)
                    }
                }

                if let error = viewModel.handoffError {
                    Section {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(
                handoff.kind == .pickup
                    ? "\(handoff.termPersonName ?? viewModel.nameForMember(handoff.termPersonId) ?? "Child") pickup"
                    : "\(handoff.ownerName) leaves work"
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task { await change(cancelled: false) }
                    }
                    .disabled(viewModel.handoffBusy)
                }
            }
        }
    }

    private func change(cancelled: Bool) async {
        if await viewModel.changeHandoff(
            handoff,
            timeOfDay: Self.timeFormatter.string(from: time),
            cancelled: cancelled
        ) {
            HapticManager.success()
            dismiss()
        }
    }
}

struct RoutinePillsRow: View {
    let routines: [ActiveRoutineDTO]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(routines) { routine in
                    Text(routine.name)
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color(hex: routine.color).opacity(0.2))
                        .foregroundStyle(Color(hex: routine.color))
                        .cornerRadius(8)
                }
            }
        }
    }
}

// MARK: - Preview

#Preview {
    CalendarView()
}
