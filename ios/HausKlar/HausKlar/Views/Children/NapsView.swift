import SwiftUI
import SwiftData

/// Full naps management view showing active naps with live timers, quick-start controls,
/// and today's completed nap history. Supports both naps and bedtime via a segmented picker.
struct NapsView: View {
    @StateObject private var viewModel = NapsViewModel()
    @State private var showingOptions = false
    @Environment(\.modelContext) private var modelContext
    let initialChildId: String?
    let initialNapId: String?
    let startWithNap: Bool

    init(
        initialChildId: String? = nil,
        initialNapId: String? = nil,
        startWithNap: Bool = false
    ) {
        self.initialChildId = initialChildId
        self.initialNapId = initialNapId
        self.startWithNap = startWithNap
    }

    /// Accent colour for the current tab.
    private var accentColor: Color {
        viewModel.selectedTab == .naps ? .purple : .indigo
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Tab selector
                Picker("Sleep Type", selection: $viewModel.selectedTab) {
                    Text("Naps").tag(SleepTab.naps)
                    Text("Bedtime").tag(SleepTab.bedtime)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)

                if viewModel.selectedTab == .naps {
                    napsContent
                } else {
                    bedtimeContent
                }
            }
            .padding(.vertical)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Naps")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    showingOptions = true
                } label: {
                    Image(systemName: "bell")
                }
                .accessibilityLabel("Nap reminder settings")

                Button(
                    viewModel.selectedTab == .naps ? "Start nap" : "Start bedtime",
                    systemImage: "plus"
                ) {
                    viewModel.resetForm()
                    viewModel.showingStartNap = true
                }
            }
        }
        .sheet(isPresented: $viewModel.showingStartNap) {
            if viewModel.selectedTab == .naps {
                startNapSheet
            } else {
                startBedtimeSheet
            }
        }
        .sheet(item: $viewModel.editingNap) { nap in
            editNapSheet(nap)
        }
        .sheet(isPresented: $showingOptions) {
            napOptionsSheet
        }
        .task {
            if let initialChildId { viewModel.selectedChildId = initialChildId }
            viewModel.bindModelContext(modelContext)
            await viewModel.loadNaps()
            if startWithNap {
                viewModel.selectedTab = .naps
                viewModel.resetForm()
                viewModel.showingStartNap = true
            }
        }
        .refreshable {
            await viewModel.loadNaps()
        }
        .overlay {
            if viewModel.isLoading && viewModel.activeNaps.isEmpty && viewModel.recentNaps.isEmpty
                && viewModel.activeBedtimes.isEmpty && viewModel.recentBedtimes.isEmpty {
                loadingView
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let deleted = viewModel.recentlyDeletedNap {
                HStack(spacing: 12) {
                    Text("\(viewModel.childName(for: deleted.childId))'s sleep record removed")
                        .font(.subheadline)
                    Spacer()
                    Button("Undo") {
                        Task { await viewModel.undoDelete() }
                    }
                    .fontWeight(.semibold)
                    Button {
                        viewModel.recentlyDeletedNap = nil
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Dismiss")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .shadow(radius: 6, y: 2)
                .padding(.horizontal)
            }
        }
    }

    // MARK: - Naps Content (unchanged layout)

    private var napsContent: some View {
        VStack(spacing: 20) {
            quickStartSection
            activeNapsSection
            recentNapsSection
        }
    }

    // MARK: - Bedtime Content

    private var bedtimeContent: some View {
        VStack(spacing: 20) {
            // Last Night card
            lastNightSection

            // Active bedtimes
            activeBedtimesSection

            // Today's completed bedtimes
            recentBedtimesSection
        }
    }

    // MARK: - Last Night Section

    private var lastNightSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title: "Last Night", icon: "moon.fill")

            if let sleep = viewModel.lastNightSleep {
                HStack(spacing: 12) {
                    Image(systemName: "moon.zzz.fill")
                        .font(.title2)
                        .foregroundStyle(.indigo)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(viewModel.childName(for: sleep.childId))
                            .font(.subheadline)
                            .fontWeight(.semibold)

                        HStack(spacing: 4) {
                            Text(formatTime(sleep.startedAt))
                            Image(systemName: "arrow.right")
                                .font(.caption2)
                            Text(formatTime(sleep.endedAt ?? ""))
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Text(formatCompletedDuration(sleep.durationMinutes))
                        .font(.title3)
                        .fontWeight(.semibold)
                        .foregroundStyle(.indigo)
                }
                .padding()
                .background(Color(.secondarySystemGroupedBackground))
                .cornerRadius(12)
            } else {
                emptyCard(message: "No bedtime recorded", icon: "moon.zzz")
            }
        }
        .padding(.horizontal)
    }

    // MARK: - Active Bedtimes Section

    private var activeBedtimesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title: "Active Bedtime", icon: "moon.zzz")

            if viewModel.activeBedtimes.isEmpty {
                emptyCard(message: "No active bedtime", icon: "moon")
            } else {
                ForEach(viewModel.activeBedtimes) { nap in
                    activeSleepCard(nap, isBedtime: true)
                }
            }

            if let errorMessage = viewModel.errorMessage {
                errorBanner(errorMessage)
            }
        }
        .padding(.horizontal)
    }

    // MARK: - Recent Bedtimes Section

    private var recentBedtimesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title: "Today's Bedtimes", icon: "clock")

            if viewModel.recentBedtimes.isEmpty {
                emptyCard(message: "No bedtimes recorded today.", icon: "moon")
            } else {
                ForEach(viewModel.recentBedtimes) { nap in
                    completedNapCard(nap, isBedtime: true)
                }
            }
        }
        .padding(.horizontal)
    }

    // MARK: - Quick Start Button

    @ViewBuilder
    private var quickStartSection: some View {
        if let child = viewModel.quickStartChildren.first {
            Button {
                Task {
                    await viewModel.quickStartNap(for: child)
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "moon.zzz.fill")
                        .font(.title3)
                    Text("Start \(child.name) Nap")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .tint(.purple)
            .padding(.horizontal)

            let otherChildren = Array(viewModel.quickStartChildren.dropFirst())
            if !otherChildren.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(otherChildren) { other in
                            Button("Start \(other.name)") {
                                Task { await viewModel.quickStartNap(for: other) }
                            }
                            .buttonStyle(.bordered)
                            .tint(.purple)
                            .frame(minHeight: 44)
                        }
                    }
                    .padding(.horizontal)
                }
            }
        }
    }

    // MARK: - Active Naps Section

    private var activeNapsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title: "Active Naps", icon: "zzz")

            if viewModel.activeNaps.isEmpty {
                emptyCard(message: "No active naps", icon: "moon.zzz")
            } else {
                ForEach(orderedActiveNaps) { nap in
                    activeSleepCard(nap, isBedtime: false)
                        .id(nap.id)
                }
            }

            if let errorMessage = viewModel.errorMessage {
                errorBanner(errorMessage)
            }
        }
        .padding(.horizontal)
    }

    private var orderedActiveNaps: [NapDTO] {
        guard let initialNapId else { return viewModel.activeNaps }
        return viewModel.activeNaps.sorted { lhs, rhs in
            if lhs.id == initialNapId { return true }
            if rhs.id == initialNapId { return false }
            return lhs.startedAt < rhs.startedAt
        }
    }

    private func activeSleepCard(_ nap: NapDTO, isBedtime: Bool) -> some View {
        let color: Color = isBedtime ? .indigo : .purple

        return VStack(spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                // Pulsing active indicator
                Circle()
                    .fill(color)
                    .frame(width: 10, height: 10)
                    .modifier(PulseModifier())
                    .padding(.top, 5)

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(viewModel.childName(for: nap.childId))
                            .font(.headline)
                        Spacer()
                        Button {
                            viewModel.editingNap = nap
                        } label: {
                            Image(systemName: "pencil.circle")
                                .font(.title3)
                                .foregroundStyle(color)
                                .frame(width: 44, height: 44)
                        }
                        .accessibilityLabel("Correct sleep record")
                    }

                    if !isBedtime, let location = nap.location, !location.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: iconForLocation(location))
                                .font(.caption)
                            Text(location.capitalized)
                                .font(.subheadline)
                        }
                        .foregroundStyle(.secondary)
                    }

                    if let notes = nap.notes, !notes.isEmpty {
                        Text(notes)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                    }
                }

                Spacer()

                if let startDate = parseISO8601(nap.startedAt) {
                    TimelineView(.periodic(from: .now, by: 1.0)) { context in
                        let elapsed = context.date.timeIntervalSince(startDate)
                        Text(formatDuration(elapsed))
                            .font(.system(.title, design: .monospaced))
                            .monospacedDigit()
                            .foregroundStyle(color)
                    }
                } else {
                    Text("In progress")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Button {
                Task {
                    await viewModel.endNap(nap.id)
                }
            } label: {
                HStack {
                    Image(systemName: isBedtime ? "sun.horizon.fill" : "stop.circle.fill")
                    Text(isBedtime ? "Wake Up" : "End Nap")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .tint(color)
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(16)
        .shadow(color: color.opacity(0.1), radius: 8, y: 2)
    }

    // MARK: - Recent Naps Section

    private var recentNapsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title: "Today's Naps", icon: "clock")

            if viewModel.recentNaps.isEmpty {
                emptyCard(message: "No naps today", icon: "moon")
            } else {
                ForEach(viewModel.recentNaps) { nap in
                    completedNapCard(nap, isBedtime: false)
                }
            }
        }
        .padding(.horizontal)
    }

    private func completedNapCard(_ nap: NapDTO, isBedtime: Bool) -> some View {
        let color: Color = isBedtime ? .indigo : .purple

        return HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 3)
                .fill(color.opacity(0.6))
                .frame(width: 4)

            VStack(alignment: .leading, spacing: 4) {
                Text(viewModel.childName(for: nap.childId))
                    .font(.subheadline)
                    .fontWeight(.semibold)

                HStack(spacing: 4) {
                    Text(formatTime(nap.startedAt))
                    Image(systemName: "arrow.right")
                        .font(.caption2)
                    Text(formatTime(nap.endedAt ?? ""))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text(formatCompletedDuration(nap.durationMinutes))
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(color)

                if !isBedtime, let location = nap.location, !location.isEmpty {
                    HStack(spacing: 3) {
                        Image(systemName: iconForLocation(location))
                            .font(.caption2)
                        Text(location.capitalized)
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                }
            }

            Button {
                viewModel.editingNap = nap
            } label: {
                Image(systemName: "pencil.circle")
                    .font(.body)
                    .foregroundStyle(color.opacity(0.6))
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Correct sleep record")
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(12)
    }

    // MARK: - Start Nap Sheet

    private var startNapSheet: some View {
        NavigationStack {
            Form {
                Section("Child") {
                    if viewModel.children.isEmpty {
                        Label("Children aren't available yet", systemImage: "person.example_f47e224f")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Child", selection: Binding(
                            get: { viewModel.selectedChildId ?? "" },
                            set: { viewModel.selectedChildId = $0.isEmpty ? nil : $0 }
                        )) {
                            Text("Select a child").tag("")
                            ForEach(viewModel.children) { child in
                                Text(child.name).tag(child.id)
                            }
                        }
                    }
                }

                Section("Location") {
                    Picker("Location", selection: $viewModel.selectedLocation) {
                        ForEach(viewModel.locations, id: \.self) { location in
                            HStack(spacing: 6) {
                                Image(systemName: iconForLocation(location))
                                Text(location.capitalized)
                            }
                            .tag(location)
                        }
                    }
                    .pickerStyle(.menu)
                }

                Section("Notes (Optional)") {
                    TextField("Any notes about this nap...", text: $viewModel.napNotes, axis: .vertical)
                        .lineLimit(2...4)
                }

                if let errorMessage = viewModel.errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }
            }
            .navigationTitle("Start Nap")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        viewModel.showingStartNap = false
                        viewModel.resetForm()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task {
                            await viewModel.startNap()
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "moon.fill")
                            Text("Start")
                        }
                    }
                    .disabled(
                        viewModel.selectedChildId == nil
                        || (viewModel.selectedChildId?.trimmingCharacters(in: .whitespaces).isEmpty ?? true)
                        || viewModel.isLoading
                    )
                }
            }
        }
    }

    // MARK: - Start Bedtime Sheet

    private var startBedtimeSheet: some View {
        NavigationStack {
            Form {
                Section("Child") {
                    if viewModel.children.isEmpty {
                        Label("Children aren't available yet", systemImage: "person.example_f47e224f")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Child", selection: Binding(
                            get: { viewModel.selectedChildId ?? "" },
                            set: { viewModel.selectedChildId = $0.isEmpty ? nil : $0 }
                        )) {
                            Text("Select a child").tag("")
                            ForEach(viewModel.children) { child in
                                Text(child.name).tag(child.id)
                            }
                        }
                    }
                }

                Section("Notes (Optional)") {
                    TextField("Any notes about bedtime...", text: $viewModel.napNotes, axis: .vertical)
                        .lineLimit(2...4)
                }

                if let errorMessage = viewModel.errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }
            }
            .navigationTitle("Start Bedtime")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        viewModel.showingStartNap = false
                        viewModel.resetForm()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task {
                            await viewModel.startNap()
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "moon.zzz.fill")
                            Text("Start")
                        }
                    }
                    .disabled(
                        viewModel.selectedChildId == nil
                        || (viewModel.selectedChildId?.trimmingCharacters(in: .whitespaces).isEmpty ?? true)
                        || viewModel.isLoading
                    )
                }
            }
        }
    }

    // MARK: - Edit Nap Sheet

    private func editNapSheet(_ nap: NapDTO) -> some View {
        EditNapStartTimeSheet(nap: nap, viewModel: viewModel)
    }

    private var napOptionsSheet: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("If a nap is still running", selection: $viewModel.reminderMinutes) {
                        Text("Off").tag(0)
                        Text("After 1 hour").tag(60)
                        Text("After 90 minutes").tag(90)
                        Text("After 2 hours").tag(120)
                        Text("After 3 hours").tag(180)
                    }
                    .onChange(of: viewModel.reminderMinutes) {
                        Task {
                            await viewModel.setForgottenReminder(
                                minutes: viewModel.reminderMinutes
                            )
                        }
                    }
                } footer: {
                    Text("A single gentle reminder appears only while the nap is still running.")
                }
            }
            .navigationTitle("Nap Reminder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showingOptions = false }
                }
            }
        }
    }

    // MARK: - Loading View

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text("Loading naps...")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }

    // MARK: - Shared Components

    private func sectionHeader(title: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.subheadline)
                .foregroundStyle(accentColor)
            Text(title)
                .font(.headline)
        }
    }

    private func emptyCard(message: String, icon: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(12)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Retry") {
                Task {
                    await viewModel.loadNaps()
                }
            }
            .font(.subheadline)
            .fontWeight(.medium)
        }
        .padding()
        .background(Color.orange.opacity(0.1))
        .cornerRadius(12)
    }

    // MARK: - Helpers

    /// Formats a live elapsed duration as a counting timer: "M:SS" or "H:MM:SS".
    private func formatDuration(_ interval: TimeInterval) -> String {
        let totalSeconds = max(0, Int(interval))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    /// Formats a completed nap duration from minutes into a readable string like "1h 23m".
    private func formatCompletedDuration(_ durationMinutes: Double?) -> String {
        guard let minutes = durationMinutes else { return "--" }
        let totalMinutes = max(0, Int(minutes))
        let hours = totalMinutes / 60
        let remainingMinutes = totalMinutes % 60
        if hours > 0 {
            return "\(hours)h \(remainingMinutes)m"
        }
        return "\(remainingMinutes)m"
    }

    /// Formats an ISO 8601 datetime string to a short time string (e.g., "14:30").
    private func formatTime(_ isoString: String) -> String {
        guard !isoString.isEmpty, let date = ISODateParser.parse(isoString) else { return "--" }
        return ISODateParser.timeOnly(from: date)
    }

    /// Parses an ISO 8601 date string using the shared ISODateParser.
    private func parseISO8601(_ isoString: String) -> Date? {
        ISODateParser.parse(isoString)
    }

    /// Returns an SF Symbol name appropriate for a nap location.
    private func iconForLocation(_ location: String) -> String {
        switch location.lowercased() {
        case "cot":
            return "bed.double.fill"
        case "buggy":
            return "stroller.fill"
        case "car":
            return "car.fill"
        case "sofa":
            return "sofa.fill"
        default:
            return "mappin.circle.fill"
        }
    }
}

// MARK: - Pulse Animation Modifier

/// A view modifier that applies a repeating pulse (scale + opacity) animation.
private struct PulseModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPulsing = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(!reduceMotion && isPulsing ? 1.6 : 1.0)
            .opacity(!reduceMotion && isPulsing ? 0.4 : 1.0)
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 1.0).repeatForever(autoreverses: true),
                value: isPulsing
            )
            .onAppear {
                isPulsing = !reduceMotion
            }
    }
}

// MARK: - Correct Sleep Record Sheet

private struct EditNapStartTimeSheet: View {
    let nap: NapDTO
    @ObservedObject var viewModel: NapsViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var startedAt: Date
    @State private var endedAt: Date
    @State private var hasEndTime: Bool
    @State private var location: String
    @State private var notes: String
    @State private var confirmingDelete = false

    init(nap: NapDTO, viewModel: NapsViewModel) {
        self.nap = nap
        self.viewModel = viewModel
        let parsedStart = ISODateParser.parse(nap.startedAt) ?? Date()
        let parsedEnd = nap.endedAt.flatMap(ISODateParser.parse) ?? Date()
        _startedAt = State(initialValue: parsedStart)
        _endedAt = State(initialValue: max(parsedStart, parsedEnd))
        _hasEndTime = State(initialValue: nap.endedAt != nil)
        _location = State(initialValue: nap.location ?? "cot")
        _notes = State(initialValue: nap.notes ?? "")
    }

    private var isBedtime: Bool { nap.resolvedSleepType == "bedtime" }

    private var datesAreValid: Bool {
        !hasEndTime || endedAt >= startedAt
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Time") {
                    DatePicker(
                        "Started at",
                        selection: $startedAt,
                        in: ...Date(),
                        displayedComponents: [.date, .hourAndMinute]
                    )

                    Toggle("Finished", isOn: $hasEndTime)

                    if hasEndTime {
                        DatePicker(
                            "Ended at",
                            selection: $endedAt,
                            in: ...Date(),
                            displayedComponents: [.date, .hourAndMinute]
                        )

                        if datesAreValid {
                            LabeledContent(
                                "Duration",
                                value: formatDuration(endedAt.timeIntervalSince(startedAt) / 60)
                            )
                        } else {
                            Text("End time must be after start time.")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                }

                if !isBedtime {
                    Section("Location") {
                        Picker("Location", selection: $location) {
                            ForEach(viewModel.locations, id: \.self) { option in
                                Text(option.capitalized).tag(option)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                }

                Section("Notes") {
                    TextField("Optional note", text: $notes, axis: .vertical)
                        .lineLimit(2...4)
                }

                Section {
                    LabeledContent("Child", value: viewModel.childName(for: nap.childId))
                    Button("Remove sleep record", role: .destructive) {
                        confirmingDelete = true
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
            .navigationTitle(isBedtime ? "Correct Bedtime" : "Correct Nap")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            await viewModel.editNap(
                                id: nap.id,
                                startedAt: startedAt,
                                endedAt: hasEndTime ? endedAt : nil,
                                location: isBedtime ? nil : location,
                                notes: notes
                            )
                        }
                    }
                    .disabled(viewModel.isLoading || !datesAreValid)
                }
            }
            .confirmationDialog(
                "Remove this sleep record?",
                isPresented: $confirmingDelete,
                titleVisibility: .visible
            ) {
                Button("Remove", role: .destructive) {
                    Task {
                        await viewModel.deleteNap(nap)
                        dismiss()
                    }
                }
            } message: {
                Text("You can undo this from the Naps screen.")
            }
        }
    }

    private func formatDuration(_ minutes: Double) -> String {
        let totalMinutes = max(0, Int(minutes))
        let hours = totalMinutes / 60
        let remainingMinutes = totalMinutes % 60
        if hours > 0 {
            return "\(hours)h \(remainingMinutes)m"
        }
        return "\(remainingMinutes)m"
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        NapsView()
    }
}
