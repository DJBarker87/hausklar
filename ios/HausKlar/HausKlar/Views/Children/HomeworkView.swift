import SwiftUI

struct HomeworkView: View {
    @StateObject private var viewModel: HomeworkViewModel
    @State private var showingSpellingDetails = false

    init(initialChildId: String? = nil, initialSpellingsId: String? = nil, initialReadingId: String? = nil) {
        _viewModel = StateObject(
            wrappedValue: HomeworkViewModel(
                initialChildId: initialChildId,
                initialSpellingsId: initialSpellingsId,
                initialReadingId: initialReadingId
            )
        )
    }

    var body: some View {
        List {
            childSection

            if let error = viewModel.errorMessage,
               viewModel.readingLogs.isEmpty,
               viewModel.spellings.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label("Homework is unavailable", systemImage: "book.closed")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Try again") { Task { await viewModel.load() } }
                    }
                }
            } else if viewModel.isLoading && viewModel.children.isEmpty {
                Section {
                    HStack {
                        Spacer()
                        ProgressView("Loading homework…")
                        Spacer()
                    }
                    .padding(.vertical, 24)
                }
            } else if viewModel.selectedChildId != nil {
                readingNowSection
                spellingWorkSection
                practiceHistorySection
                completedSection
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Homework")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        viewModel.prepareReadingEditor()
                    } label: {
                        Label("Log reading", systemImage: "book.fill")
                    }
                    Button {
                        viewModel.prepareSpellingsEditor()
                    } label: {
                        Label("Add spelling list", systemImage: "textformat.abc")
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .disabled(viewModel.selectedChildId == nil)
                .accessibilityLabel("Add homework")
            }
        }
        .refreshable { await viewModel.loadSelectedChild() }
        .task { await viewModel.load() }
        .sheet(isPresented: $viewModel.showingReadingEditor) {
            readingEditor
        }
        .sheet(isPresented: $viewModel.showingSpellingsEditor) {
            spellingEditor
        }
        .sheet(item: $viewModel.focusedSpellings) { entry in
            SpellingListDetailView(viewModel: viewModel, entry: entry)
        }
        .fullScreenCover(item: $viewModel.practiceSpellings) { _ in
            SpellingPracticeView(viewModel: viewModel)
        }
        .sheet(item: $viewModel.completingSpellings) { _ in
            spellingCompletionSheet
        }
        .safeAreaInset(edge: .bottom) {
            if let undo = viewModel.undoNotice {
                HStack(spacing: 12) {
                    Text(undo.message)
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Button("Undo") { Task { await viewModel.undoLastRemoval() } }
                        .fontWeight(.semibold)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(.regularMaterial, in: Capsule())
                .padding(.horizontal)
                .padding(.bottom, 6)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    private var childSection: some View {
        Section {
            if viewModel.children.isEmpty && !viewModel.isLoading {
                Text("Add a child to start using Homework.")
                    .foregroundStyle(.secondary)
            } else {
                Picker("Child", selection: Binding(
                    get: { viewModel.selectedChildId ?? "" },
                    set: { childId in Task { await viewModel.selectChild(childId) } }
                )) {
                    ForEach(viewModel.children) { child in
                        Text(child.name).tag(child.id)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityHint("Homework stays filtered to this child")
            }
        }
    }

    private var readingNowSection: some View {
        Section {
            if let latest = viewModel.latestReading {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "book.fill")
                            .font(.title2)
                            .foregroundStyle(.blue)
                            .frame(width: 34)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(latest.bookTitle)
                                .font(.headline)
                            Text("Usual session · \(latest.minutes) minutes")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Button {
                        Task { await viewModel.quickLogUsualReading() }
                    } label: {
                        Label("Log \(latest.minutes) minutes", systemImage: "checkmark.circle.fill")
                            .frame(maxWidth: .infinity, minHeight: 34)
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Change book, time or add a note") {
                        viewModel.prepareReadingEditor()
                    }
                    .font(.subheadline.weight(.medium))
                }
                .padding(.vertical, 4)
            } else {
                ContentUnavailableView {
                    Label("What are you reading?", systemImage: "book.closed.fill")
                } description: {
                    Text("Save the current book once; the usual session becomes one tap next time.")
                } actions: {
                    Button("Log first reading") { viewModel.prepareReadingEditor() }
                        .buttonStyle(.borderedProminent)
                }
            }
        } header: {
            Text("Read now")
        } footer: {
            if viewModel.weeklyReadingMinutes > 0 {
                Text("\(viewModel.weeklyReadingMinutes) minutes read this week")
            }
        }
    }

    private var spellingWorkSection: some View {
        Section("Due next") {
            if viewModel.upcomingSpellings.isEmpty {
                ContentUnavailableView {
                    Label("No spelling work due", systemImage: "checkmark.circle")
                } description: {
                    Text("Paste the next teacher list when it arrives.")
                } actions: {
                    Button("Add spelling list") { viewModel.prepareSpellingsEditor() }
                }
            } else {
                ForEach(viewModel.upcomingSpellings) { entry in
                    spellingRow(entry)
                }
            }
        }
    }

    private func spellingRow(_ entry: SpellingsDTO) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                viewModel.focusedSpellings = entry
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "textformat.abc")
                        .font(.title3)
                        .foregroundStyle(dueColor(entry))
                        .frame(width: 32)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(viewModel.dueLabel(entry))
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text("\(entry.wordList.count) words · \(entry.practiceCount) \(entry.practiceCount == 1 ? "practice" : "practices")")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        if let needs = wordsNeedingPractice(entry), !needs.isEmpty {
                            Text("Next: \(needs)")
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                viewModel.beginPractice(entry)
            } label: {
                Label("Start practice", systemImage: "play.fill")
                    .frame(maxWidth: .infinity, minHeight: 32)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.vertical, 3)
        .id(entry.id)
    }

    private var practiceHistorySection: some View {
        Section("What we practised") {
            if viewModel.recentReading.isEmpty
                && viewModel.spellings.allSatisfy({ $0.sessions.isEmpty }) {
                Text("Reading and spelling practice will appear here.")
                    .foregroundStyle(.secondary)
            }

            ForEach(viewModel.recentReading.prefix(6)) { log in
                Button {
                    viewModel.prepareReadingEditor(log)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "book")
                            .foregroundStyle(.blue)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(log.bookTitle)
                                .foregroundStyle(.primary)
                            Text("\(log.minutes) min · \(viewModel.formatDate(log.date))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "pencil")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
                .swipeActions {
                    Button(role: .destructive) {
                        Task { await viewModel.deleteReading(log) }
                    } label: {
                        Label("Remove", systemImage: "trash")
                    }
                }
            }

            ForEach(recentSpellingSessions, id: \.session.id) { item in
                Button {
                    viewModel.focusedSpellings = item.entry
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "pencil.and.list.clipboard")
                            .foregroundStyle(.purple)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Spelling practice")
                                .foregroundStyle(.primary)
                            Text("\(item.session.correctCount) of \(item.session.totalCount) · \(viewModel.formatDateTime(item.session.practisedAt))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var completedSection: some View {
        if !viewModel.completedSpellings.isEmpty {
            Section("Completed tests") {
                ForEach(viewModel.completedSpellings.prefix(8)) { entry in
                    Button {
                        viewModel.focusedSpellings = entry
                    } label: {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(viewModel.dueLabel(entry))
                                    .foregroundStyle(.primary)
                                Text(entry.score.map { "Score \($0) of \(entry.wordList.count)" } ?? "Marked done")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var recentSpellingSessions: [(entry: SpellingsDTO, session: SpellingPracticeDTO)] {
        viewModel.spellings
            .flatMap { entry in entry.sessions.map { (entry: entry, session: $0) } }
            .sorted { $0.session.practisedAt > $1.session.practisedAt }
            .prefix(6)
            .map { $0 }
    }

    private var readingEditor: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Child", value: viewModel.selectedChild?.name ?? "Child")
                    TextField("Book title", text: $viewModel.readingBookTitle)
                        .textInputAutocapitalization(.words)
                    Stepper(value: $viewModel.readingMinutes, in: 1...120, step: 5) {
                        LabeledContent("Time", value: "\(viewModel.readingMinutes) minutes")
                    }
                }

                Section("More details") {
                    DatePicker("Date", selection: $viewModel.readingDate, displayedComponents: .date)
                    TextField("How did it go? (optional)", text: $viewModel.readingNotes, axis: .vertical)
                        .lineLimit(2...5)
                }

                if let error = viewModel.actionError {
                    Section { Text(error).foregroundStyle(.red) }
                }

                if let editing = viewModel.editingReading {
                    Section {
                        Button("Remove session", role: .destructive) {
                            viewModel.showingReadingEditor = false
                            Task { await viewModel.deleteReading(editing) }
                        }
                    }
                }
            }
            .navigationTitle(viewModel.editingReading == nil ? "Log reading" : "Correct reading")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { viewModel.showingReadingEditor = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await viewModel.saveReading() } }
                        .fontWeight(.semibold)
                        .disabled(viewModel.readingBookTitle.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var spellingEditor: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Child", value: viewModel.selectedChild?.name ?? "Child")
                    TextField(
                        "Paste words — one per line or comma-separated",
                        text: $viewModel.spellingsWords,
                        axis: .vertical
                    )
                    .lineLimit(5...12)
                    Text("\(viewModel.parsedSpellingWords.count) words")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    DatePicker(
                        "Test date",
                        selection: $viewModel.spellingsTestDate,
                        displayedComponents: .date
                    )
                } header: {
                    Text("Teacher list")
                } footer: {
                    Text("Paste directly from an email or message. Review the list before saving.")
                }

                Section {
                    DisclosureGroup("More school details", isExpanded: $showingSpellingDetails) {
                        TextField(
                            "Teacher note (optional)",
                            text: $viewModel.spellingsNotes,
                            axis: .vertical
                        )
                        .lineLimit(2...5)
                        TextField("School link (optional)", text: $viewModel.spellingsLink)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                            .autocorrectionDisabled()
                        HomeworkDocumentPickerButton(document: $viewModel.spellingsDocument)
                    }
                }

                if let error = viewModel.actionError {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle(viewModel.editingSpellings == nil ? "Add spellings" : "Correct spellings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { viewModel.showingSpellingsEditor = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await viewModel.saveSpellings() } }
                        .fontWeight(.semibold)
                        .disabled(viewModel.parsedSpellingWords.isEmpty)
                }
            }
        }
        .presentationDetents([.large])
    }

    private var spellingCompletionSheet: some View {
        NavigationStack {
            Form {
                if let entry = viewModel.completingSpellings {
                    Section {
                        TextField("Score (optional)", text: $viewModel.completionScore)
                            .keyboardType(.numberPad)
                        Text("Out of \(entry.wordList.count) words")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } header: {
                        Text("Test result")
                    } footer: {
                        Text("Leave the score blank if you only need to mark the test done.")
                    }
                }
                if let error = viewModel.actionError {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Mark test done")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { viewModel.completingSpellings = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { Task { await viewModel.completeSpellings() } }
                        .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func wordsNeedingPractice(_ entry: SpellingsDTO) -> String? {
        let words = entry.wordMastery.filter(\.needsPractice).map(\.word)
        guard !words.isEmpty, entry.practiceCount > 0 else { return nil }
        let shown = words.prefix(3).joined(separator: ", ")
        return words.count > 3 ? "\(shown) +\(words.count - 3)" : shown
    }

    private func dueColor(_ entry: SpellingsDTO) -> Color {
        switch entry.status {
        case "overdue": .red
        case "due": .orange
        default: .purple
        }
    }
}

private struct HomeworkDocumentPickerButton: View {
    @Binding var document: SourceDocumentDTO?
    @State private var showingPicker = false

    var body: some View {
        Button {
            showingPicker = true
        } label: {
            HStack {
                Image(systemName: document?.mediaType.hasPrefix("image/") == true ? "photo" : "doc")
                VStack(alignment: .leading, spacing: 2) {
                    Text(document?.title ?? "Choose teacher sheet")
                    if let filename = document?.originalFilename {
                        Text(filename)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .sheet(isPresented: $showingPicker) {
            DocumentAttachmentPicker(selectedDocument: document) { selected in
                document = selected
            }
        }

        if document != nil {
            Button("Remove teacher sheet", role: .destructive) { document = nil }
        }
    }
}

private struct SpellingListDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: HomeworkViewModel
    let entry: SpellingsDTO
    @State private var confirmingDelete = false
    @State private var previewItem: DocumentPreviewItem?
    @State private var isOpeningDocument = false
    @State private var previewError: String?

    private var current: SpellingsDTO {
        viewModel.spellings.first { $0.id == entry.id } ?? entry
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Status", value: viewModel.dueLabel(current))
                    LabeledContent("Words", value: String(current.wordList.count))
                    LabeledContent("Practice", value: String(current.practiceCount))
                    if let score = current.score {
                        LabeledContent("Result", value: "\(score) of \(current.wordList.count)")
                    }
                }

                Section("Words") {
                    ForEach(current.wordList, id: \.self) { word in
                        let mastery = current.wordMastery.first { $0.word == word }
                        HStack {
                            Text(word)
                            Spacer()
                            if mastery?.mastered == true {
                                Label("Mastered", systemImage: "checkmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.green)
                            } else if (mastery?.attempts ?? 0) > 0 {
                                Text("Keep practising")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                }

                if let notes = current.notes, !notes.isEmpty {
                    Section("Teacher note") { Text(notes) }
                }

                if current.linkUrl != nil || current.sourceDocument != nil {
                    Section("School details") {
                        if let url = SafeExternalURL.web(current.linkUrl) {
                            Link(destination: url) {
                                Label("Open school link", systemImage: "link")
                            }
                        }
                        if let document = current.sourceDocument {
                            Button {
                                openDocument(document)
                            } label: {
                                HStack {
                                    Label(document.title, systemImage: "paperclip")
                                    Spacer()
                                    if isOpeningDocument { ProgressView() }
                                }
                            }
                            .disabled(isOpeningDocument)
                            if let previewError {
                                Text(previewError)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                        }
                    }
                }

                if !current.sessions.isEmpty {
                    Section("Practice history") {
                        ForEach(current.sessions) { session in
                            Button {
                                transition { viewModel.beginPractice(current, correcting: session) }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("\(session.correctCount) of \(session.totalCount) correct")
                                            .foregroundStyle(.primary)
                                        Text(viewModel.formatDateTime(session.practisedAt))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text("Correct")
                                        .font(.caption.weight(.medium))
                                }
                            }
                        }
                    }
                }

                Section {
                    if current.isCompleted {
                        Button {
                            Task { await viewModel.reopenSpellings(current) }
                        } label: {
                            Label("Undo completion", systemImage: "arrow.uturn.backward")
                        }
                    } else {
                        Button {
                            transition { viewModel.beginPractice(current) }
                        } label: {
                            Label("Start practice", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)

                        Button {
                            transition { viewModel.prepareCompletion(current) }
                        } label: {
                            Label("Mark test done", systemImage: "checkmark.circle")
                        }
                    }
                }
            }
            .navigationTitle("Spellings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            transition { viewModel.prepareSpellingsEditor(current) }
                        } label: {
                            Label("Correct details", systemImage: "pencil")
                        }
                        Button(role: .destructive) {
                            confirmingDelete = true
                        } label: {
                            Label("Remove list", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .alert("Remove this spelling list?", isPresented: $confirmingDelete) {
                Button("Cancel", role: .cancel) {}
                Button("Remove", role: .destructive) {
                    Task { await viewModel.deleteSpellings(current) }
                }
            } message: {
                Text("You can undo this immediately from the Homework screen.")
            }
            .sheet(item: $previewItem) { item in
                DocumentPreviewSheet(item: item)
                    .onDisappear { DocumentPreviewStore.remove(item.url) }
            }
        }
    }

    private func transition(
        _ action: @escaping @MainActor @Sendable () -> Void
    ) {
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            MainActor.assumeIsolated {
                action()
            }
        }
    }

    private func openDocument(_ document: SourceDocumentDTO) {
        guard !isOpeningDocument else { return }
        isOpeningDocument = true
        previewError = nil
        Task {
            defer { isOpeningDocument = false }
            do {
                let url = try await DocumentPreviewStore.download(document)
                previewItem = DocumentPreviewItem(url: url, title: document.title)
            } catch {
                previewError = "The teacher sheet could not be opened."
            }
        }
    }
}

private enum PracticeCardPhase {
    case prompt
    case hidden
    case result
}

private struct SpellingPracticeView: View {
    @ObservedObject var viewModel: HomeworkViewModel
    @State private var phase: PracticeCardPhase = .prompt

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                if let entry = viewModel.practiceSpellings,
                   let word = viewModel.practiceWord {
                    ProgressView(
                        value: Double(viewModel.practiceIndex + 1),
                        total: Double(max(entry.wordList.count, 1))
                    )
                    Text("Word \(viewModel.practiceIndex + 1) of \(entry.wordList.count)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Spacer()

                    switch phase {
                    case .prompt:
                        Text("Say this word aloud")
                            .font(.headline)
                        Text(word)
                            .font(.system(size: 42, weight: .bold, design: .rounded))
                            .minimumScaleFactor(0.6)
                        Button("Hide word and ask") { phase = .hidden }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                    case .hidden:
                        Image(systemName: "eye.slash.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(.secondary)
                        Text("Ask them to spell it aloud or write it down.")
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                        Button("Reveal spelling") { phase = .result }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                    case .result:
                        Text(word)
                            .font(.system(size: 42, weight: .bold, design: .rounded))
                            .minimumScaleFactor(0.6)
                        HStack(spacing: 14) {
                            Button {
                                answer(false)
                            } label: {
                                Label("Try again", systemImage: "arrow.counterclockwise")
                                    .frame(maxWidth: .infinity, minHeight: 42)
                            }
                            .buttonStyle(.bordered)

                            Button {
                                answer(true)
                            } label: {
                                Label("Got it", systemImage: "checkmark")
                                    .frame(maxWidth: .infinity, minHeight: 42)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }

                    Spacer()

                    if viewModel.practiceIndex > 0 {
                        Button("Previous word") {
                            viewModel.previousPracticeWord()
                            phase = .prompt
                        }
                    }
                }

                if let error = viewModel.actionError {
                    Text(error)
                        .font(.subheadline)
                        .foregroundStyle(.red)
                }
            }
            .padding(24)
            .navigationTitle(viewModel.correctingPracticeId == nil ? "Spelling practice" : "Correct practice")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { viewModel.practiceSpellings = nil }
                }
            }
        }
        .interactiveDismissDisabled()
    }

    private func answer(_ correct: Bool) {
        Task {
            let priorIndex = viewModel.practiceIndex
            await viewModel.recordPracticeAnswer(correct)
            if viewModel.practiceSpellings != nil && viewModel.practiceIndex != priorIndex {
                phase = .prompt
            }
        }
    }
}

#Preview {
    NavigationStack { HomeworkView() }
}
