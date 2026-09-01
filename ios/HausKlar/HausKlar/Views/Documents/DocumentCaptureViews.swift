import PhotosUI
import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import VisionKit

enum DocumentCaptureSourceAction {
    case scan, file, text
}

@MainActor
enum DocumentPhotoCapturePreparer {
    static func prepare(
        _ items: [PhotosPickerItem],
        expectedIdentityLease: DocumentUploadService.IdentityLease
    ) async throws -> CapturedDocumentAsset {
        guard !items.isEmpty else { throw DocumentCaptureError.noPages }
        guard items.count <= DocumentCaptureService.maximumPhotoSelectionCount else {
            throw DocumentCaptureError.tooManySelectedPhotos
        }
        try validateIdentity(expectedIdentityLease)

        var stagedAssets: [CapturedDocumentAsset] = []
        var aggregateBytes = 0
        defer {
            stagedAssets.forEach(DocumentCaptureService.removeTemporaryAsset)
        }

        for item in items {
            try Task.checkCancellation()
            try validateIdentity(expectedIdentityLease)
            guard
                let transfer = try await item.loadTransferable(
                    type: StagedDocumentImageTransfer.self
                )
            else {
                throw DocumentCaptureError.unreadableFile
            }
            let stagedAsset = try transfer.takeAsset()
            stagedAssets.append(stagedAsset)
            try Task.checkCancellation()
            try validateIdentity(expectedIdentityLease)

            let byteCount =
                try await DocumentCaptureService
                .validatedStagedImageByteCountWithoutBlockingUI(stagedAsset)
            try Task.checkCancellation()
            try validateIdentity(expectedIdentityLease)
            let (newCount, overflow) = aggregateBytes.addingReportingOverflow(byteCount)
            guard !overflow, newCount <= DocumentCaptureService.maximumFileBytes else {
                throw DocumentCaptureError.fileTooLarge
            }
            aggregateBytes = newCount
        }

        if stagedAssets.count == 1 {
            let asset = stagedAssets.removeFirst()
            do {
                try Task.checkCancellation()
                try validateIdentity(expectedIdentityLease)
                return asset
            } catch {
                DocumentCaptureService.removeTemporaryAsset(asset)
                throw error
            }
        }

        let pdf = try await DocumentCaptureService.makePDF(
            fromStagedImageAssets: stagedAssets
        )
        do {
            try Task.checkCancellation()
            try validateIdentity(expectedIdentityLease)
            return pdf
        } catch {
            DocumentCaptureService.removeTemporaryAsset(pdf)
            throw error
        }
    }

    private static func validateIdentity(
        _ expectedIdentityLease: DocumentUploadService.IdentityLease
    ) throws {
        guard expectedIdentityLease == DocumentUploadService.shared.currentIdentityLease else {
            throw DocumentCaptureError.accountUnavailable
        }
    }
}

struct DocumentCaptureSourceSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var photoItems: [PhotosPickerItem]
    let scannerSupported: Bool
    let onChoose: (DocumentCaptureSourceAction) -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        onChoose(.scan)
                    } label: {
                        sourceLabel(
                            "Scan document",
                            detail: scannerSupported
                                ? "Use the camera to scan one or more pages"
                                : "Scanning needs an iPhone or iPad camera",
                            systemImage: "doc.viewfinder"
                        )
                    }
                    .disabled(!scannerSupported)
                    .accessibilityIdentifier(HausKlarAccessibilityID.Documents.scan)

                    PhotosPicker(
                        selection: $photoItems,
                        maxSelectionCount: DocumentCaptureService.maximumPhotoSelectionCount,
                        matching: .images,
                        preferredItemEncoding: .current
                    ) {
                        sourceLabel(
                            "Choose photos",
                            detail: "Keep one original photo, or combine several into a PDF",
                            systemImage: "photo.on.rectangle.angled"
                        )
                    }
                    .accessibilityIdentifier("documentChoosePhotos")

                    Button {
                        onChoose(.file)
                    } label: {
                        sourceLabel(
                            "Upload document",
                            detail: "Choose a PDF, image or text file from Files",
                            systemImage: "folder"
                        )
                    }
                    .accessibilityIdentifier("documentUploadFile")
                } header: {
                    Text("Add original file")
                } footer: {
                    Text("HausKlar stores the original document or photo as well as any text it recognises.")
                }

                Section {
                    Button {
                        onChoose(.text)
                    } label: {
                        sourceLabel(
                            "Paste text only",
                            detail: "Create a text document when there is no original file",
                            systemImage: "doc.on.clipboard"
                        )
                    }
                }
            }
            .buttonStyle(.plain)
            .navigationTitle("Add Document")
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier(HausKlarAccessibilityID.Documents.sourceSheet)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    nonisolated private func sourceLabel(
        _ title: String,
        detail: String,
        systemImage: String
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// Reusable picker used by calendar events and tasks to attach, replace or
/// remove a document already stored in the family library.
struct DocumentAttachmentPicker: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    let selectedDocument: SourceDocumentDTO?
    let onSelect: (SourceDocumentDTO?) -> Void

    @State private var documents: [DocumentDTO] = []
    @State private var familyMembers: [FamilyMemberDTO] = []
    @State private var searchText = ""
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var captureError: String?
    @State private var showingScanner = false
    @State private var showingFileImporter = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var captureAsset: CapturedDocumentAsset?
    @State private var isPreparingCapture = false
    @State private var dismissAfterCapture = false
    @State private var uploadIdentityLease: DocumentUploadService.IdentityLease?
    @State private var capturePreparationTask: Task<Void, Never>?

    private var filteredDocuments: [DocumentDTO] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return documents }
        return documents.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.originalFilename.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        guard VNDocumentCameraViewController.isSupported else {
                            captureError = "Document scanning requires an iPhone or iPad camera."
                            return
                        }
                        showingScanner = true
                    } label: {
                        captureSourceLabel(
                            "Scan document",
                            detail: VNDocumentCameraViewController.isSupported
                                ? "Scan one or more pages with the camera"
                                : "Scanning needs an iPhone or iPad camera",
                            systemImage: "doc.viewfinder"
                        )
                    }
                    .disabled(!VNDocumentCameraViewController.isSupported || isPreparingCapture)
                    .accessibilityIdentifier("attachmentScanDocument")

                    PhotosPicker(
                        selection: $photoItems,
                        maxSelectionCount: DocumentCaptureService.maximumPhotoSelectionCount,
                        matching: .images,
                        preferredItemEncoding: .current
                    ) {
                        captureSourceLabel(
                            "Choose photos",
                            detail: "Keep one original photo, or combine several into a PDF",
                            systemImage: "photo.on.rectangle.angled"
                        )
                    }
                    .disabled(isPreparingCapture)
                    .accessibilityIdentifier("attachmentChoosePhotos")

                    Button {
                        showingFileImporter = true
                    } label: {
                        captureSourceLabel(
                            "Upload document",
                            detail: "Choose a PDF, image or text file from Files",
                            systemImage: "folder"
                        )
                    }
                    .disabled(isPreparingCapture)
                    .accessibilityIdentifier("attachmentUploadDocument")

                    if isPreparingCapture {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Preparing document…")
                                .foregroundStyle(.secondary)
                        }
                        .frame(minHeight: 44)
                        .accessibilityIdentifier(HausKlarAccessibilityID.Documents.preparing)
                    }
                } header: {
                    Text("Add a new document")
                } footer: {
                    Text("The original file is stored securely with the document, then attached here.")
                }

                if let captureError {
                    Section {
                        VStack(alignment: .leading, spacing: 10) {
                            Label(captureError, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                            Button("Dismiss") { self.captureError = nil }
                                .buttonStyle(.bordered)
                        }
                        .padding(.vertical, 6)
                    }
                }

                if let selectedDocument {
                    Section("Currently attached") {
                        attachmentRow(selectedDocument, selected: true) {
                            dismiss()
                        }
                        Button(role: .destructive) {
                            onSelect(nil)
                            dismiss()
                        } label: {
                            Label("Remove attachment", systemImage: "paperclip.badge.ellipsis")
                                .frame(minHeight: 44)
                        }
                    }
                }

                Section("Documents") {
                    if isLoading {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Loading documents…")
                                .foregroundStyle(.secondary)
                        }
                        .frame(minHeight: 52)
                    } else if let errorMessage {
                        VStack(alignment: .leading, spacing: 10) {
                            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                            Button("Try again") { Task { await loadDocuments() } }
                                .buttonStyle(.bordered)
                        }
                        .padding(.vertical, 6)
                    } else if filteredDocuments.isEmpty {
                        ContentUnavailableView(
                            searchText.isEmpty ? "No documents yet" : "No matching documents",
                            systemImage: "doc.text.magnifyingglass",
                            description: Text(
                                searchText.isEmpty
                                    ? "Scan, choose a photo or upload a file above."
                                    : "Try a different title or filename."
                            )
                        )
                    } else {
                        ForEach(filteredDocuments) { document in
                            attachmentRow(
                                SourceDocumentDTO(document: document),
                                selected: document.id == selectedDocument?.id
                            ) {
                                onSelect(SourceDocumentDTO(document: document))
                                dismiss()
                            }
                        }
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Search documents")
            .navigationTitle(
                (selectedDocument == nil ? "Attach Document" : "Change Document").localized
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        capturePreparationTask?.cancel()
                        dismiss()
                    }
                }
            }
            .task {
                if uploadIdentityLease == nil {
                    uploadIdentityLease = DocumentUploadService.shared.currentIdentityLease
                }
                await loadDocuments()
            }
            .task { await loadFamilyMembers() }
            .refreshable { await loadDocuments() }
            .onChange(of: photoItems) { _, items in
                guard !items.isEmpty else { return }
                startCapturePreparation { await importPhotos(items) }
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                let currentLease = DocumentUploadService.shared.currentIdentityLease
                if uploadIdentityLease != nil, uploadIdentityLease != currentLease {
                    discardCaptureAfterIdentityChange()
                }
                uploadIdentityLease = currentLease
            }
            .sheet(isPresented: $showingScanner) {
                DocumentScannerView { result in
                    showingScanner = false
                    switch result {
                    case .success(let images):
                        guard !images.isEmpty else { return }
                        isPreparingCapture = true
                        startCapturePreparation {
                            defer { isPreparingCapture = false }
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
            .sheet(
                item: $captureAsset,
                onDismiss: {
                    if dismissAfterCapture {
                        dismissAfterCapture = false
                        dismiss()
                    }
                }
            ) { asset in
                DocumentCaptureReviewView(
                    asset: asset,
                    familyMembers: familyMembers,
                    saveButtonTitle: "Save & Attach",
                    saveError: { captureError }
                ) { title, category, documentDate, text, notes, people, suggestions, useHermes in
                    await saveAndSelectCapture(
                        asset: asset,
                        title: title,
                        category: category,
                        documentDate: documentDate,
                        extractedText: text,
                        notes: notes,
                        personIds: people,
                        suggestions: suggestions,
                        useHermes: useHermes
                    )
                }
            }
            .fileImporter(
                isPresented: $showingFileImporter,
                allowedContentTypes: [.pdf, .image, .plainText]
            ) { result in
                do {
                    let url = try result.get()
                    startCapturePreparation {
                        isPreparingCapture = true
                        defer { isPreparingCapture = false }
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
                if let captureAsset {
                    DocumentCaptureService.removeTemporaryAsset(captureAsset)
                    self.captureAsset = nil
                }
            }
        }
    }

    private func attachmentRow(
        _ document: SourceDocumentDTO,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: document.mediaType.hasPrefix("image/") ? "photo.fill" : "doc.fill")
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 28, height: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(document.title)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Text(document.originalFilename)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                        .accessibilityLabel("Selected")
                }
            }
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    nonisolated private func captureSourceLabel(
        _ title: String,
        detail: String,
        systemImage: String
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func importPhotos(_ items: [PhotosPickerItem]) async {
        isPreparingCapture = true
        captureError = nil
        defer {
            photoItems = []
            isPreparingCapture = false
        }
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
        isPreparingCapture = false
    }

    private func saveAndSelectCapture(
        asset: CapturedDocumentAsset,
        title: String,
        category: DocumentCategory,
        documentDate: Date?,
        extractedText: String,
        notes: String,
        personIds: [String],
        suggestions: [CaptureSuggestionDraft],
        useHermes: Bool
    ) async -> Bool {
        captureError = nil
        guard let uploadIdentityLease else {
            captureError = "Your account changed before this document could be saved. Please try again."
            HapticManager.error()
            return false
        }
        let pending: PendingDocumentUpload
        do {
            pending = try await DocumentUploadService.shared.enqueueWithoutBlockingUI(
                asset: asset,
                title: title,
                category: category,
                documentDate: documentDate,
                extractedText: extractedText,
                notes: notes,
                personIds: personIds,
                suggestions: suggestions,
                useHermes: useHermes,
                modelContext: modelContext,
                expectedIdentityLease: uploadIdentityLease
            )
        } catch {
            captureError = error.localizedDescription
            HapticManager.error()
            return false
        }

        do {
            let document = try await DocumentUploadService.shared.upload(
                pending,
                modelContext: modelContext,
                expectedIdentityLease: uploadIdentityLease
            )
            documents.removeAll { $0.id == document.id }
            documents.insert(document, at: 0)
            onSelect(SourceDocumentDTO(document: document))
            dismissAfterCapture = true
            HapticManager.success()
            return true
        } catch let error as APIError {
            if case .networkError = error {
                captureError =
                    "The original is saved securely on this iPhone and will upload when you are back online. Attach it after it appears in Documents."
                return true
            }
            captureError = error.errorDescription
        } catch {
            if pending.status == .pending || pending.status == .retryableFailure {
                captureError =
                    "The original is saved securely on this iPhone and will upload automatically. Attach it after it appears in Documents."
                return true
            }
            captureError = error.localizedDescription
        }
        HapticManager.error()
        return false
    }

    private func loadFamilyMembers() async {
        do {
            familyMembers = try await APIClient.shared.get("/family/members")
        } catch is CancellationError {
            return
        } catch {
            errorMessage = "People could not be loaded for document filing."
        }
    }

    private func loadDocuments() async {
        isLoading = true
        errorMessage = nil
        do {
            documents = try await APIClient.shared.get(
                "/documents/",
                queryItems: [URLQueryItem(name: "limit", value: "200")],
                bypassCache: true
            )
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "Documents could not be loaded."
        }
        isLoading = false
    }
}

struct DocumentCaptureReviewView: View {
    let asset: CapturedDocumentAsset
    let familyMembers: [FamilyMemberDTO]
    let saveButtonTitle: String
    let saveError: () -> String?
    let onSave:
        (
            String,
            DocumentCategory,
            Date?,
            String,
            String,
            [String],
            [CaptureSuggestionDraft],
            Bool
        ) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var category: DocumentCategory
    @State private var hasDocumentDate = false
    @State private var documentDate = Date()
    @State private var extractedText = ""
    @State private var notes = ""
    @State private var selectedPeople: Set<String> = []
    @State private var suggestions: [CaptureSuggestionDraft] = []
    @State private var useHermes = false
    @State private var isProcessing = true
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var showingText = false
    @State private var processingTask: Task<Void, Never>?
    @State private var saveTask: Task<Void, Never>?

    init(
        asset: CapturedDocumentAsset,
        familyMembers: [FamilyMemberDTO],
        saveButtonTitle: String = "Add to Inbox",
        saveError: @escaping () -> String? = { nil },
        onSave:
            @escaping (
                String,
                DocumentCategory,
                Date?,
                String,
                String,
                [String],
                [CaptureSuggestionDraft],
                Bool
            ) async -> Bool
    ) {
        self.asset = asset
        self.familyMembers = familyMembers
        self.saveButtonTitle = saveButtonTitle
        self.saveError = saveError
        self.onSave = onSave
        _title = State(initialValue: asset.filename)
        _category = State(initialValue: .other)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Document") {
                    LabeledContent {
                        Text("\(asset.pageCount) page\(asset.pageCount == 1 ? "" : "s")")
                    } label: {
                        Label(asset.filename, systemImage: "doc.fill")
                    }
                    TextField("Title", text: $title)
                    Picker("Category", selection: $category) {
                        ForEach(DocumentCategory.allCases) { category in
                            Label(category.title, systemImage: category.icon).tag(category)
                        }
                    }
                    Toggle("Document has a date", isOn: $hasDocumentDate)
                    if hasDocumentDate {
                        DatePicker("Document date", selection: $documentDate, displayedComponents: .date)
                    }
                }

                Section("File for") {
                    if familyMembers.isEmpty {
                        Text("Family members could not be loaded. The document will be filed for everyone.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(familyMembers) { member in
                            Toggle(member.name, isOn: personBinding(member.id))
                        }
                    }
                }

                Section {
                    if isProcessing {
                        HStack {
                            ProgressView()
                            Text("Reading document on this iPhone...")
                                .foregroundStyle(.secondary)
                        }
                    } else if suggestions.isEmpty {
                        Label("No concrete dates or actions detected", systemImage: "checkmark.circle")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach($suggestions) { $suggestion in
                            VStack(alignment: .leading, spacing: 8) {
                                Toggle(isOn: $suggestion.isIncluded) {
                                    TextField("Suggested action", text: $suggestion.title)
                                        .font(.subheadline.weight(.medium))
                                }
                                Picker("Type", selection: $suggestion.kind) {
                                    ForEach(CaptureSuggestionKind.allCases) { kind in
                                        Text(kind.title).tag(kind)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .disabled(!suggestion.isIncluded)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                } header: {
                    Text("Detected actions")
                } footer: {
                    Text("These remain drafts until you review them in the inbox.")
                }

                Section {
                    Toggle("Improve drafts with Bismarck (OpenAI)", isOn: $useHermes)
                } footer: {
                    Text(
                        "When enabled, extracted text may be sent to OpenAI after you grant AI permission. The original document is never sent to OpenAI. Review or withdraw permission in Settings → AI & Family Data."
                    )
                }

                Section {
                    DisclosureGroup("Extracted text", isExpanded: $showingText) {
                        TextEditor(text: $extractedText)
                            .frame(minHeight: 180)
                    }
                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(2...6)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Review Capture")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        processingTask?.cancel()
                        removeTemporaryAsset()
                        dismiss()
                    }
                    .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        save()
                    } label: {
                        if isSaving {
                            ProgressView()
                                .accessibilityLabel("Saving document")
                        } else {
                            Text(saveButtonTitle)
                        }
                    }
                    .disabled(
                        isProcessing
                            || isSaving
                            || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                }
            }
            .interactiveDismissDisabled(isSaving)
            .onAppear { startProcessing() }
            .onChange(of: selectedPeople) { _, people in
                let assignment = people.count == 1 ? people.first : nil
                for index in suggestions.indices where suggestions[index].assignedTo == nil {
                    suggestions[index].assignedTo = assignment
                }
            }
            .onDisappear {
                processingTask?.cancel()
                saveTask?.cancel()
                removeTemporaryAsset()
            }
        }
    }

    private func personBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { selectedPeople.contains(id) },
            set: { selected in
                if selected { selectedPeople.insert(id) } else { selectedPeople.remove(id) }
            }
        )
    }

    private func save() {
        isSaving = true
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            let saved = await onSave(
                title.trimmingCharacters(in: .whitespacesAndNewlines),
                category,
                hasDocumentDate ? documentDate : nil,
                extractedText,
                notes,
                Array(selectedPeople),
                suggestions,
                useHermes
            )
            guard !Task.isCancelled else { return }
            isSaving = false
            if saved {
                removeTemporaryAsset()
                dismiss()
            } else {
                errorMessage = saveError() ?? "The document could not be saved. Try again."
            }
        }
    }

    private func startProcessing() {
        guard processingTask == nil else { return }
        processingTask = Task { @MainActor in
            do {
                let text = try await DocumentCaptureService.extractText(from: asset)
                try Task.checkCancellation()
                extractedText = text
                title = DocumentCaptureService.inferredTitle(from: text, fallback: asset.filename)
                suggestions = DocumentCaptureService.suggestions(from: text, assignedTo: nil)
            } catch is CancellationError {
                return
            } catch {
                errorMessage = "Text recognition failed, but you can still store the original document."
            }
            isProcessing = false
        }
    }

    private func removeTemporaryAsset() {
        DocumentCaptureService.removeTemporaryAsset(asset)
    }
}

struct TextDocumentCaptureView: View {
    let onCapture: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .padding()
                .navigationTitle("Paste Letter Text")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Review") {
                            onCapture(text)
                            dismiss()
                        }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
        }
    }
}

struct DocumentScannerView: UIViewControllerRepresentable {
    let completion: (Result<[UIImage], Error>) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: VNDocumentCameraViewController, context: Context) {}

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let completion: (Result<[UIImage], Error>) -> Void

        init(completion: @escaping (Result<[UIImage], Error>) -> Void) {
            self.completion = completion
        }

        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFinishWith scan: VNDocumentCameraScan
        ) {
            completion(.success((0..<scan.pageCount).map(scan.imageOfPage)))
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            completion(.success([]))
        }

        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFailWithError error: Error
        ) {
            completion(.failure(error))
        }
    }
}
