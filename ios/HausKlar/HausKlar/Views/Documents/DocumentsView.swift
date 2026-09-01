import PhotosUI
import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import VisionKit

struct DocumentsView: View {
    let startWithCapture: Bool
    let sharedFileURL: URL?
    let initialPersonId: String?
    let initialDocumentId: String?
    let onSharedCaptureCommitted: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var networkMonitor: NetworkMonitor
    @StateObject private var viewModel: DocumentsViewModel
    @Query(sort: \PendingDocumentUpload.createdAt) private var pendingUploads: [PendingDocumentUpload]

    @State private var showingScanner = false
    @State private var showingCaptureSources = false
    @State private var showingFileImporter = false
    @State private var showingTextCapture = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var captureAsset: CapturedDocumentAsset?
    @State private var suggestionReview: SuggestionReviewContext?
    @State private var previewItem: DocumentPreviewItem?
    @State private var captureError: String?
    @State private var launchedInitialCapture = false
    @State private var showingDocumentManagement = false
    @State private var acceptAllInProgress: String?
    @State private var acceptAllTitle = ""
    @State private var acceptAllSummary = ""
    @State private var showingAcceptAllSummary = false
    @State private var uploadIdentityLease: DocumentUploadService.IdentityLease?
    @State private var openedDocument: DocumentDTO?
    @State private var consumedInitialDocument = false
    @State private var capturePreparationTask: Task<Void, Never>?
    @State private var queueFlushTask: Task<Void, Never>?

    init(
        startWithCapture: Bool = false,
        sharedFileURL: URL? = nil,
        initialPersonId: String? = nil,
        initialDocumentId: String? = nil,
        onSharedCaptureCommitted: @escaping () -> Void = {}
    ) {
        self.startWithCapture = startWithCapture
        self.sharedFileURL = sharedFileURL
        self.initialPersonId = initialPersonId
        self.initialDocumentId = initialDocumentId
        self.onSharedCaptureCommitted = onSharedCaptureCommitted
        _viewModel = StateObject(
            wrappedValue: DocumentsViewModel(initialPersonId: initialPersonId)
        )
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                modePicker
                personFilter

                if let message = viewModel.errorMessage ?? captureError {
                    errorBanner(message)
                }

                documentContent
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Documents")
            .accessibilityIdentifier(HausKlarAccessibilityID.Documents.screen)
            .searchable(
                text: $viewModel.searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search letters and extracted text"
            )
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        showingDocumentManagement = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Manage documents")
                    captureMenu
                }
            }
            .task {
                if uploadIdentityLease == nil {
                    uploadIdentityLease = DocumentUploadService.shared.currentIdentityLease
                }
                await viewModel.load()
                await DocumentUploadService.shared.flush(modelContext: modelContext)
                await viewModel.refreshDocuments()
                if !consumedInitialDocument, let initialDocumentId {
                    consumedInitialDocument = true
                    do {
                        let document: DocumentDTO = try await APIClient.shared.get("/documents/\(initialDocumentId)")
                        openedDocument = document
                    } catch {
                        captureError = "That document could not be opened."
                    }
                }
                if let sharedFileURL, captureAsset == nil {
                    do {
                        let asset = try await DocumentCaptureService.importFileWithoutBlockingUI(sharedFileURL)
                        try Task.checkCancellation()
                        guard uploadIdentityLease == DocumentUploadService.shared.currentIdentityLease else {
                            DocumentCaptureService.removeTemporaryAsset(asset)
                            return
                        }
                        captureAsset = asset
                    } catch {
                        captureError = error.localizedDescription
                    }
                    return
                }
                guard startWithCapture, !launchedInitialCapture else { return }
                launchedInitialCapture = true
                showingCaptureSources = true
            }
            .navigationDestination(isPresented: Binding(
                get: { openedDocument != nil },
                set: { if !$0 { openedDocument = nil } }
            )) {
                if let document = openedDocument {
                    DocumentDetailView(document: document, viewModel: viewModel) { url in
                        previewItem = DocumentPreviewItem(url: url, title: document.title)
                    }
                }
            }
            .task(id: viewModel.mode) {
                await viewModel.refreshDocuments()
            }
            .task(id: viewModel.selectedPersonId) {
                await viewModel.refreshDocuments()
            }
            .task(id: viewModel.selectedCategory) {
                await viewModel.refreshDocuments()
            }
            .task(id: viewModel.searchText) {
                do {
                    try await Task.sleep(for: .milliseconds(300))
                } catch is CancellationError {
                    return
                } catch {
                    viewModel.errorMessage = "Search could not be refreshed. Try again."
                    return
                }
                await viewModel.refreshDocuments()
            }
            .onChange(of: networkMonitor.isConnected) { _, connected in
                guard connected else { return }
                startQueueFlush(reloadAll: false)
            }
            .onChange(of: photoItems) { _, items in
                guard !items.isEmpty else { return }
                showingCaptureSources = false
                startCapturePreparation { await importPhotos(items) }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    let currentLease = DocumentUploadService.shared.currentIdentityLease
                    if uploadIdentityLease != nil, uploadIdentityLease != currentLease {
                        discardCaptureAfterIdentityChange()
                    }
                    uploadIdentityLease = currentLease
                    startQueueFlush(reloadAll: true)
                } else if phase == .background {
                    if let item = previewItem {
                        viewModel.removePreview(at: item.url)
                        previewItem = nil
                    }
                    DocumentPreviewStore.purgeAll()
                }
            }
            .sheet(isPresented: $showingCaptureSources) {
                DocumentCaptureSourceSheet(
                    photoItems: $photoItems,
                    scannerSupported: VNDocumentCameraViewController.isSupported,
                    onChoose: presentCaptureSource
                )
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showingScanner) {
                DocumentScannerView { result in
                    showingScanner = false
                    switch result {
                    case .success(let images):
                        guard !images.isEmpty else { return }
                        startCapturePreparation {
                            do {
                                let asset = try await DocumentCaptureService.makePDF(
                                    from: images,
                                    source: "scan"
                                )
                                try Task.checkCancellation()
                                guard uploadIdentityLease == DocumentUploadService.shared.currentIdentityLease else {
                                    DocumentCaptureService.removeTemporaryAsset(asset)
                                    return
                                }
                                captureAsset = asset
                            } catch is CancellationError {
                                return
                            } catch {
                                captureError = error.localizedDescription
                            }
                        }
                    case .failure(let error):
                        captureError = error.localizedDescription
                    }
                }
                .ignoresSafeArea()
            }
            .sheet(item: $captureAsset) { asset in
                DocumentCaptureReviewView(
                    asset: asset,
                    familyMembers: viewModel.familyMembers
                ) { title, category, documentDate, text, notes, people, suggestions, useHermes in
                    guard let uploadIdentityLease else {
                        captureError = "Your account changed before this document could be saved. Please try again."
                        return false
                    }
                    let saved = await viewModel.saveCapture(
                        asset: asset,
                        title: title,
                        category: category,
                        documentDate: documentDate,
                        extractedText: text,
                        notes: notes,
                        personIds: people,
                        suggestions: suggestions,
                        useHermes: useHermes,
                        modelContext: modelContext,
                        identityLease: uploadIdentityLease
                    )
                    if saved, sharedFileURL != nil { onSharedCaptureCommitted() }
                    return saved
                }
            }
            .sheet(isPresented: $showingTextCapture) {
                TextDocumentCaptureView { text in
                    do {
                        captureAsset = try DocumentCaptureService.makeTextDocument(text)
                    } catch {
                        captureError = error.localizedDescription
                    }
                }
            }
            .sheet(item: $suggestionReview) { context in
                SuggestionReviewView(
                    draft: context.draft,
                    familyMembers: viewModel.familyMembers
                ) { draft in
                    await viewModel.accept(documentId: context.documentId, draft: draft)
                }
            }
            .sheet(item: $previewItem) { item in
                DocumentPreviewSheet(item: item)
                    .onDisappear {
                        viewModel.removePreview(at: item.url)
                    }
            }
            .sheet(isPresented: $showingDocumentManagement) {
                DocumentManagementView(viewModel: viewModel)
            }
            .alert(acceptAllTitle, isPresented: $showingAcceptAllSummary) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(acceptAllSummary)
            }
            .fileImporter(
                isPresented: $showingFileImporter,
                allowedContentTypes: [.pdf, .image, .plainText]
            ) { result in
                do {
                    let url = try result.get()
                    startCapturePreparation {
                        do {
                            let asset = try await DocumentCaptureService.importFileWithoutBlockingUI(url)
                            try Task.checkCancellation()
                            guard uploadIdentityLease == DocumentUploadService.shared.currentIdentityLease else {
                                DocumentCaptureService.removeTemporaryAsset(asset)
                                return
                            }
                            captureAsset = asset
                        } catch is CancellationError {
                            return
                        } catch {
                            captureError = error.localizedDescription
                        }
                    }
                } catch {
                    captureError = error.localizedDescription
                }
            }
            .onDisappear {
                capturePreparationTask?.cancel()
                queueFlushTask?.cancel()
                viewModel.cancelInFlightDocumentWork()
                if let captureAsset {
                    DocumentCaptureService.removeTemporaryAsset(captureAsset)
                    self.captureAsset = nil
                }
            }
        }
    }

    private var modePicker: some View {
        Picker("Document view", selection: $viewModel.mode) {
            ForEach(DocumentListMode.allCases) { mode in
                Text(modeTitle(mode)).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    private var personFilter: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Menu {
                    Button("All categories") {
                        viewModel.selectedCategory = nil
                    }
                    ForEach(DocumentCategory.allCases) { category in
                        Button {
                            viewModel.selectedCategory = category
                        } label: {
                            Label(category.title, systemImage: category.icon)
                        }
                    }
                } label: {
                    Label(
                        viewModel.selectedCategory?.title ?? "All categories",
                        systemImage: "line.3.horizontal.decrease"
                    )
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 12)
                    .frame(height: 44)
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(Capsule())
                }
                filterChip("Everyone", id: nil, count: viewModel.stats?.totalDocuments)
                ForEach(viewModel.familyMembers) { member in
                    filterChip(
                        member.name,
                        id: member.id,
                        count: viewModel.stats?.byPerson[member.id]
                    )
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 10)
        }
    }

    private func filterChip(_ title: String, id: String?, count: Int?) -> some View {
        Button {
            viewModel.selectedPersonId = id
        } label: {
            HStack(spacing: 5) {
                Text(title)
                if let count, count > 0 {
                    Text("\(count)")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.15))
                        .clipShape(Capsule())
                }
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(viewModel.selectedPersonId == id ? Color.white : Color.primary)
            .padding(.horizontal, 12)
            .frame(height: 44)
            .background(viewModel.selectedPersonId == id ? Color.accentColor : Color(.secondarySystemGroupedBackground))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(viewModel.selectedPersonId == id ? .isSelected : [])
    }

    @ViewBuilder
    private var documentContent: some View {
        if viewModel.isLoading && viewModel.documents.isEmpty {
            Spacer()
            ProgressView("Loading documents...")
                .accessibilityIdentifier(HausKlarAccessibilityID.Documents.loading)
            Spacer()
        } else {
            ScrollView {
                LazyVStack(spacing: 12) {
                    if !pendingUploads.isEmpty {
                        pendingSection
                    }

                    if viewModel.documents.isEmpty {
                        ContentUnavailableView {
                            Label(
                                emptyTitle,
                                systemImage: viewModel.mode == .inbox ? "tray" : "doc.text"
                            )
                        } description: {
                            Text(emptyDetail)
                        } actions: {
                            if hasActiveFilters {
                                Button("Clear filters") {
                                    viewModel.selectedPersonId = nil
                                    viewModel.selectedCategory = nil
                                    viewModel.searchText = ""
                                }
                                .buttonStyle(.borderedProminent)
                            } else {
                                Button("Add a document") {
                                    showingCaptureSources = true
                                }
                                .buttonStyle(.borderedProminent)
                                .accessibilityIdentifier("documentsEmptyAdd")
                            }
                        }
                        .padding(.top, 60)
                        .accessibilityIdentifier(HausKlarAccessibilityID.Documents.empty)
                    } else if viewModel.mode == .inbox {
                        if !attentionDocuments.isEmpty {
                            queueHeader(
                                eyebrow: "First",
                                title: "Needs your attention",
                                count: attentionDocuments.count
                            )
                            ForEach(attentionDocuments) { document in
                                documentCard(document)
                            }
                        }
                        if !readyDocuments.isEmpty {
                            readyHeader
                            ForEach(readyDocuments) { document in
                                documentCard(document)
                            }
                        }
                    } else {
                        ForEach(viewModel.documents) { document in
                            documentCard(document)
                        }
                    }

                    if viewModel.canLoadMore {
                        Button {
                            Task { await viewModel.loadMoreDocuments() }
                        } label: {
                            if viewModel.isLoadingMore {
                                ProgressView()
                                    .frame(maxWidth: .infinity)
                            } else {
                                Text("Load more")
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(viewModel.isLoadingMore)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 30)
            }
            .refreshable {
                await viewModel.load()
            }
        }
    }

    private var attentionDocuments: [DocumentDTO] {
        viewModel.documents.filter { $0.readyForBatchFiling != true }
    }

    private var readyDocuments: [DocumentDTO] {
        viewModel.documents.filter { $0.readyForBatchFiling == true }
    }

    private var hasActiveFilters: Bool {
        viewModel.selectedPersonId != nil
            || viewModel.selectedCategory != nil
            || !viewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var emptyTitle: String {
        if hasActiveFilters { return "No matching documents" }
        return viewModel.mode == .inbox ? "Nothing needs your attention" : "No filed documents"
    }

    private var emptyDetail: String {
        if hasActiveFilters { return "Change or clear a filter." }
        return viewModel.mode == .inbox
            ? "New scans and forwarded letters stay here only until they are sorted."
            : "Documents you file will be kept here."
    }

    private func queueHeader(eyebrow: String, title: String, count: Int) -> some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                Text(eyebrow.uppercased())
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.title3.weight(.bold))
            }
            Spacer()
            Text("\(count)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(.secondarySystemGroupedBackground), in: Capsule())
        }
        .padding(.top, 10)
    }

    private var readyHeader: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                Text("CHECKED")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                Text("Ready to file")
                    .font(.title3.weight(.bold))
            }
            Spacer()
            Button {
                Task { await fileReadyDocuments() }
            } label: {
                if viewModel.isSaving {
                    ProgressView()
                } else {
                    Label("File \(readyDocuments.count)", systemImage: "checkmark")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.isSaving)
        }
        .padding(.top, attentionDocuments.isEmpty ? 10 : 18)
    }

    private func fileReadyDocuments() async {
        guard let result = await viewModel.fileReadyDocuments(readyDocuments) else { return }
        acceptAllTitle = result.skippedIds.isEmpty ? "Documents filed" : "Some still need review"
        acceptAllSummary = result.skippedIds.isEmpty
            ? "Filed \(result.filedIds.count) document\(result.filedIds.count == 1 ? "" : "s")."
            : "Filed \(result.filedIds.count). \(result.skippedIds.count) still need review."
        showingAcceptAllSummary = true
    }

    private var pendingSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label("Waiting to upload", systemImage: "icloud.and.arrow.up")
                .font(.headline)
                .padding(.bottom, 8)

            VStack(spacing: 0) {
                ForEach(Array(pendingUploads.enumerated()), id: \.element.id) { index, pending in
                    HStack(spacing: 12) {
                        ProgressView()
                            .opacity(pending.status == .uploading ? 1 : 0)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(pending.title)
                                .font(.subheadline.weight(.medium))
                            Text(pending.errorMessage ?? pendingStatusText(pending.status))
                                .font(.caption)
                                .foregroundStyle(pending.status.isFailure ? Color.primary : Color.secondary)
                                .lineLimit(2)
                        }
                        Spacer()
                        Button {
                            Task {
                                guard let uploadIdentityLease else {
                                    captureError = "Your account changed before this upload could be retried."
                                    return
                                }
                                await viewModel.retry(
                                    pending,
                                    modelContext: modelContext,
                                    identityLease: uploadIdentityLease
                                )
                            }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .accessibilityLabel("Retry upload")
                        .disabled(!pending.status.mayUploadAutomatically)
                        Menu {
                            Button("Discard upload", role: .destructive) {
                                Task {
                                    guard let uploadIdentityLease else {
                                        captureError = "Your account changed before this upload could be discarded."
                                        return
                                    }
                                    await viewModel.discard(
                                        pending,
                                        modelContext: modelContext,
                                        identityLease: uploadIdentityLease
                                    )
                                }
                            }
                            .disabled(pending.status == .uploading || pending.status == .acknowledgedPendingCleanup)
                        } label: {
                            Image(systemName: "ellipsis")
                        }
                    }
                    .padding(12)
                    if index < pendingUploads.count - 1 { Divider().padding(.leading, 48) }
                }
            }
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .accessibilityIdentifier(HausKlarAccessibilityID.Documents.pendingUploads)
    }

    private func pendingStatusText(_ status: DocumentUploadStatus) -> String {
        switch status {
        case .pending:
            "Saved securely on this iPhone".localized
        case .uploading:
            "Uploading…".localized
        case .acknowledgedPendingCleanup, .complete:
            "Uploaded; finishing secure local cleanup".localized
        case .retryableFailure:
            "Upload will retry automatically".localized
        case .permanentFailure, .failed:
            "This upload needs attention".localized
        }
    }

    private func documentCard(_ document: DocumentDTO) -> some View {
        let visibleSuggestions = viewModel.mode == .inbox
            ? document.suggestions.filter { $0.status == "pending" }
            : []
        return VStack(spacing: 0) {
            NavigationLink {
                DocumentDetailView(document: document, viewModel: viewModel) { url in
                    guard scenePhase == .active else {
                        viewModel.removePreview(at: url)
                        return
                    }
                    previewItem = DocumentPreviewItem(url: url, title: document.title)
                }
            } label: {
                HStack(spacing: 13) {
                    Image(systemName: document.category.icon)
                        .font(.title3)
                        .foregroundStyle(categoryColor(document.category))
                        .frame(width: 38, height: 38)
                        .background(categoryColor(document.category).opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(document.title)
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                        HStack(spacing: 6) {
                            Text(
                                document.people.map(\.personName).joined(separator: ", ").nilIfEmpty
                                    ?? "Family".localized
                            )
                            Text("·")
                            Text(documentDateLabel(document))
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(14)
            }
            .buttonStyle(.plain)

            if !visibleSuggestions.isEmpty {
                Divider().padding(.leading, 65)
                ForEach(Array(visibleSuggestions.enumerated()), id: \.element.id) { index, suggestion in
                    suggestionRow(document: document, suggestion: suggestion)
                    if index < visibleSuggestions.count - 1 { Divider().padding(.leading, 65) }
                }
                let pendingCount = visibleSuggestions.filter { $0.status == "pending" }.count
                if pendingCount >= 2 {
                    acceptAllButton(document: document, count: pendingCount)
                }
            } else if viewModel.mode == .inbox && document.readyForBatchFiling != true {
                Divider().padding(.leading, 65)
                Label(reviewLabel(document), systemImage: "exclamationmark.circle")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            }
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func reviewLabel(_ document: DocumentDTO) -> String {
        var fields: [String] = []
        if let confidence = document.categoryConfidence, confidence < 0.8 {
            fields.append("filing")
        }
        if let confidence = document.documentDateConfidence, confidence < 0.8 {
            fields.append("date")
        }
        return fields.isEmpty ? "Check filing details" : "Check \(fields.joined(separator: " and "))"
    }

    private func acceptAllButton(document: DocumentDTO, count: Int) -> some View {
        Button {
            Task { await acceptAllSuggestions(document) }
        } label: {
            HStack(spacing: 8) {
                if acceptAllInProgress == document.id {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "checkmark.circle.fill")
                }
                Text("Add all \(count)")
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
        .buttonStyle(.borderedProminent)
        .disabled(acceptAllInProgress != nil)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .accessibilityLabel("Accept all \(count) suggestions")
    }

    private func acceptAllSuggestions(_ document: DocumentDTO) async {
        acceptAllInProgress = document.id
        var titles: [String: String] = [:]
        for suggestion in document.suggestions {
            titles[suggestion.id] = suggestion.title
        }
        let result = await viewModel.acceptAll(documentId: document.id)
        acceptAllInProgress = nil
        guard let result else { return }
        var lines = result.accepted.map { "✓ \(titles[$0.suggestionId] ?? "Added")" }
        lines += result.skipped.map { "✗ \(titles[$0.suggestionId] ?? "Skipped") — \($0.reason)" }
        acceptAllTitle = "Added \(result.accepted.count) of \(result.accepted.count + result.skipped.count)"
        acceptAllSummary = lines.joined(separator: "\n")
        showingAcceptAllSummary = true
    }

    private func suggestionRow(document: DocumentDTO, suggestion: CaptureSuggestionDTO) -> some View {
        HStack(spacing: 12) {
            Image(systemName: actionIcon(suggestion))
                .foregroundStyle(actionColor(suggestion))
                .frame(width: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(suggestion.title)
                    .font(.subheadline.weight(.medium))
                Text(suggestionSubtitle(suggestion))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if suggestion.status == "pending" {
                Button {
                    Task {
                        await viewModel.dismiss(documentId: document.id, suggestionId: suggestion.id)
                    }
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Dismiss suggestion")

                Button {
                    suggestionReview = SuggestionReviewContext(
                        documentId: document.id,
                        draft: viewModel.draft(from: suggestion)
                    )
                } label: {
                    Image(systemName: "checkmark")
                        .frame(width: 32, height: 32)
                        .background(Color.accentColor)
                        .foregroundStyle(.white)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Review and accept suggestion")
            } else if suggestion.kind == .task && suggestion.resultStatus == "open" {
                Button {
                    Task { _ = await viewModel.completeAction(suggestion) }
                } label: {
                    Image(systemName: "circle")
                        .font(.title3)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .accessibilityLabel("Complete action")
            } else if suggestion.kind == .event {
                Image(systemName: "calendar.badge.checkmark")
                    .foregroundStyle(.blue)
                    .frame(width: 36, height: 36)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var captureMenu: some View {
        Button {
            showingCaptureSources = true
        } label: {
            Image(systemName: "plus")
        }
        .accessibilityLabel("Add document")
    }

    private func importPhotos(_ items: [PhotosPickerItem]) async {
        defer { photoItems = [] }
        do {
            guard let expectedIdentityLease = uploadIdentityLease else {
                throw DocumentCaptureError.accountUnavailable
            }
            let asset = try await DocumentPhotoCapturePreparer.prepare(
                items,
                expectedIdentityLease: expectedIdentityLease
            )
            try Task.checkCancellation()
            guard expectedIdentityLease == DocumentUploadService.shared.currentIdentityLease else {
                DocumentCaptureService.removeTemporaryAsset(asset)
                return
            }
            captureAsset = asset
        } catch is CancellationError {
            return
        } catch {
            captureError = error.localizedDescription
        }
    }

    private func startCapturePreparation(_ operation: @escaping @MainActor () async -> Void) {
        capturePreparationTask?.cancel()
        capturePreparationTask = Task { @MainActor in
            await operation()
        }
    }

    private func discardCaptureAfterIdentityChange() {
        capturePreparationTask?.cancel()
        photoItems = []
        if let captureAsset {
            DocumentCaptureService.removeTemporaryAsset(captureAsset)
            self.captureAsset = nil
        }
        captureError = DocumentCaptureError.accountUnavailable.localizedDescription
    }

    private func startQueueFlush(reloadAll: Bool) {
        queueFlushTask?.cancel()
        let expectedLease = DocumentUploadService.shared.currentIdentityLease
        uploadIdentityLease = expectedLease
        queueFlushTask = Task { @MainActor in
            await DocumentUploadService.shared.flush(modelContext: modelContext)
            guard !Task.isCancelled,
                  expectedLease == DocumentUploadService.shared.currentIdentityLease else { return }
            if reloadAll { await viewModel.load() }
            else { await viewModel.refreshDocuments() }
        }
    }

    private func modeTitle(_ mode: DocumentListMode) -> String {
        switch mode {
        case .inbox:
            return "Needs attention \(viewModel.stats?.inboxDocuments ?? 0)"
        case .library:
            return "Filed"
        }
    }

    private func presentCaptureSource(_ action: DocumentCaptureSourceAction) {
        showingCaptureSources = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            switch action {
            case .scan:
                if VNDocumentCameraViewController.isSupported {
                    showingScanner = true
                } else {
                    captureError = "Document scanning requires a device with a camera."
                }
            case .file:
                showingFileImporter = true
            case .text:
                showingTextCapture = true
            }
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
            Spacer()
            if viewModel.errorMessage != nil {
                Button("Retry") {
                    Task { await viewModel.load() }
                }
                .font(.caption.weight(.semibold))
                .frame(minHeight: 44)
            }
            Button {
                viewModel.errorMessage = nil
                captureError = nil
            } label: {
                Image(systemName: "xmark")
            }
            .accessibilityLabel("Dismiss error")
            .frame(width: 44, height: 44)
        }
        .padding(10)
        .background(Color.orange.opacity(0.12))
        .padding(.horizontal)
        .padding(.bottom, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(HausKlarAccessibilityID.Documents.error)
    }

    private func categoryColor(_ category: DocumentCategory) -> Color {
        switch category {
        case .school: .blue
        case .medical: .red
        case .childcare: .purple
        case .identity: .teal
        case .finance: .green
        case .activities: .orange
        case .household: .indigo
        case .other: .gray
        }
    }

    private func documentDateLabel(_ document: DocumentDTO) -> String {
        let value = document.documentDate ?? document.createdAt
        guard let date = ISODateParser.parse(value) else { return String(value.prefix(10)) }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    private func suggestionSubtitle(_ suggestion: CaptureSuggestionDTO) -> String {
        let value = suggestion.kind == .event ? suggestion.startTime : suggestion.dueDate
        let dateLabel: String
        if let value, let date = ISODateParser.parse(value) {
            dateLabel = date.formatted(date: .abbreviated, time: suggestion.allDay ? .omitted : .shortened)
        } else {
            dateLabel = suggestion.kind == .task ? "No deadline" : "Date required"
        }
        let state = switch suggestion.resultStatus {
        case "completed": "Completed"
        case "open": "To do"
        case "scheduled": "On calendar"
        case "pending": "Needs review"
        default: suggestion.status.capitalized
        }
        return [state, dateLabel, suggestion.assignedToName]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    private func actionIcon(_ suggestion: CaptureSuggestionDTO) -> String {
        if suggestion.resultStatus == "completed" { return "checkmark.circle.fill" }
        return suggestion.kind.icon
    }

    private func actionColor(_ suggestion: CaptureSuggestionDTO) -> Color {
        if suggestion.resultStatus == "completed" { return .green }
        return suggestion.kind == .event ? .blue : .orange
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
