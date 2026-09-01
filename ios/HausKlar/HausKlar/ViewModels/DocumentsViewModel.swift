import Foundation
import SwiftData
import os

enum DocumentListMode: String, CaseIterable, Identifiable {
    case inbox = "Needs attention"
    case library = "Filed"

    var id: String { rawValue }
}

@MainActor
final class DocumentsViewModel: ObservableObject {
    private static let logger = Logger(
        subsystem:"org.example.hausklar",category:"DocumentsViewModel"
    )
    @Published var documents: [DocumentDTO] = []
    @Published var archivedDocuments: [DocumentDTO] = []
    @Published var familyMembers: [FamilyMemberDTO] = []
    @Published var stats: DocumentStatsDTO?
    @Published var inboxAddress: String?
    @Published var mode: DocumentListMode = .inbox
    @Published var selectedPersonId: String?
    @Published var selectedCategory: DocumentCategory?
    @Published var searchText = ""
    @Published var isLoading = false
    @Published var isLoadingMore = false
    @Published var isLoadingManagement = false
    @Published var isSaving = false
    @Published var canLoadMore = false
    @Published var canLoadMoreArchive = false
    @Published var errorMessage: String?

    private let apiClient = APIClient.shared
    private let uploadService = DocumentUploadService.shared
    private let pageSize = 30
    private var workGeneration = 0

    init(initialPersonId: String? = nil) {
        selectedPersonId = initialPersonId
    }

    func cancelInFlightDocumentWork() {
        workGeneration &+= 1
        isSaving = false
    }

    func load() async {
        isLoading = documents.isEmpty
        errorMessage = nil
        async let membersResult = fetchMembers()
        async let statsResult = fetchStats()
        async let documentsResult = fetchDocuments()
        let (members, loadedStats, loadedDocuments) = await (
            membersResult,
            statsResult,
            documentsResult
        )
        if !members.isEmpty { familyMembers = members }
        stats = loadedStats
        documents = loadedDocuments
        canLoadMore = loadedDocuments.count == pageSize
        isLoading = false
    }

    func refreshDocuments() async {
        let loaded = await fetchDocuments()
        documents = loaded
        canLoadMore = loaded.count == pageSize
        stats = await fetchStats()
    }

    func loadMoreDocuments() async {
        guard canLoadMore, !isLoadingMore else { return }
        isLoadingMore = true
        let loaded = await fetchDocuments(offset: documents.count)
        let existing = Set(documents.map(\.id))
        documents.append(contentsOf: loaded.filter { !existing.contains($0.id) })
        canLoadMore = loaded.count == pageSize
        isLoadingMore = false
    }

    func loadManagement() async {
        isLoadingManagement = true
        errorMessage = nil
        async let statsResult = fetchStats()
        async let addressResult = fetchInboxAddress()
        async let archiveResult = fetchDocuments(status: "archived")
        let (loadedStats, loadedAddress, archive) = await (
            statsResult,
            addressResult,
            archiveResult
        )
        stats = loadedStats
        inboxAddress = loadedAddress
        archivedDocuments = archive
        canLoadMoreArchive = archive.count == pageSize
        if loadedStats == nil, errorMessage == nil {
            errorMessage = "Document management could not be loaded."
        }
        isLoadingManagement = false
    }

    func loadMoreArchive() async {
        guard canLoadMoreArchive, !isLoadingMore else { return }
        isLoadingMore = true
        let loaded = await fetchDocuments(status: "archived", offset: archivedDocuments.count)
        let existing = Set(archivedDocuments.map(\.id))
        archivedDocuments.append(contentsOf: loaded.filter { !existing.contains($0.id) })
        canLoadMoreArchive = loaded.count == pageSize
        isLoadingMore = false
    }

    func saveCapture(
        asset: CapturedDocumentAsset,
        title: String,
        category: DocumentCategory,
        documentDate: Date?,
        extractedText: String,
        notes: String,
        personIds: [String],
        suggestions: [CaptureSuggestionDraft],
        useHermes: Bool,
        modelContext: ModelContext,
        identityLease: DocumentUploadService.IdentityLease
    ) async -> Bool {
        let generation = workGeneration
        isSaving = true
        defer {
            if generation == workGeneration { isSaving = false }
        }
        errorMessage = nil
        do {
            let pending = try await uploadService.enqueueWithoutBlockingUI(
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
                expectedIdentityLease: identityLease
            )
            guard generation == workGeneration,
                  uploadService.currentIdentityLease == identityLease else {
                isSaving = false
                return false
            }
            do {
                _ = try await uploadService.upload(
                    pending,
                    modelContext: modelContext,
                    expectedIdentityLease: identityLease
                )
                guard generation == workGeneration,
                      uploadService.currentIdentityLease == identityLease else { return false }
                HapticManager.success()
                await refreshDocuments()
            } catch let error as APIError {
                guard generation == workGeneration else { return false }
                if case .networkError = error {
                    errorMessage = "Saved on this iPhone. It will upload when you are back online."
                } else {
                    errorMessage = error.errorDescription
                }
            } catch is CancellationError {
                guard generation == workGeneration else { return false }
                errorMessage = "Saved securely. Upload will resume automatically."
            } catch {
                guard generation == workGeneration else { return false }
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            isSaving = false
            return true
        } catch {
            guard generation == workGeneration else { return false }
            errorMessage = error.localizedDescription
            isSaving = false
            return false
        }
    }

    func retry(
        _ pending: PendingDocumentUpload,
        modelContext: ModelContext,
        identityLease: DocumentUploadService.IdentityLease
    ) async {
        do {
            _ = try await uploadService.upload(
                pending,
                modelContext: modelContext,
                expectedIdentityLease: identityLease
            )
            await refreshDocuments()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func discard(
        _ pending: PendingDocumentUpload,
        modelContext: ModelContext,
        identityLease: DocumentUploadService.IdentityLease
    ) async {
        do {
            _ = try await uploadService.discard(
                pending,
                modelContext: modelContext,
                expectedIdentityLease: identityLease
            )
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }

    func accept(
        documentId: String,
        draft: CaptureSuggestionDraft
    ) async -> Bool {
        isSaving = true
        errorMessage = nil
        do {
            let _: SuggestionResolutionDTO = try await apiClient.post(
                "/documents/\(documentId)/suggestions/\(draft.id)/accept",
                body: SuggestionUpdateRequest(draft: draft)
            )
            HapticManager.success()
            await refreshDocuments()
            isSaving = false
            return true
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = error.localizedDescription
        }
        isSaving = false
        return false
    }

    func acceptAll(documentId: String) async -> SuggestionBulkAcceptResponseDTO? {
        isSaving = true
        errorMessage = nil
        do {
            let result: SuggestionBulkAcceptResponseDTO = try await apiClient.post(
                "/documents/\(documentId)/suggestions/accept-all",
                body: EmptyBody()
            )
            HapticManager.success()
            await refreshDocuments()
            isSaving = false
            return result
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = error.localizedDescription
        }
        isSaving = false
        return nil
    }

    func dismiss(documentId: String, suggestionId: String) async {
        do {
            let _: SuggestionResolutionDTO = try await apiClient.post(
                "/documents/\(documentId)/suggestions/\(suggestionId)/dismiss",
                body: EmptyBody()
            )
            await refreshDocuments()
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func addAction(documentId: String, draft: CaptureSuggestionDraft) async -> Bool {
        isSaving = true
        errorMessage = nil
        do {
            let suggestion: CaptureSuggestionDTO = try await apiClient.post(
                "/documents/\(documentId)/suggestions",
                body: SuggestionCreateRequest(draft: draft)
            )
            var acceptedDraft = draft
            acceptedDraft.id = suggestion.id
            let _: SuggestionResolutionDTO = try await apiClient.post(
                "/documents/\(documentId)/suggestions/\(suggestion.id)/accept",
                body: SuggestionUpdateRequest(draft: acceptedDraft)
            )
            HapticManager.success()
            await refreshDocuments()
            isSaving = false
            return true
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = error.localizedDescription
        }
        isSaving = false
        return false
    }

    func completeAction(_ suggestion: CaptureSuggestionDTO) async -> Bool {
        guard suggestion.kind == .task, let taskId = suggestion.resultId else { return false }
        do {
            let _: TaskDTO = try await apiClient.patch("/tasks/\(taskId)/complete", body: EmptyBody())
            HapticManager.success()
            await refreshDocuments()
            return true
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = error.localizedDescription
        }
        return false
    }

    func fileDocument(_ document: DocumentDTO) async -> Bool {
        await updateStatus(document, status: "filed")
    }

    func archiveDocument(_ document: DocumentDTO) async -> Bool {
        await updateStatus(document, status: "archived")
    }

    func restoreDocument(_ document: DocumentDTO) async -> Bool {
        if await updateStatus(document, status: "filed") {
            archivedDocuments.removeAll { $0.id == document.id }
            return true
        }
        return false
    }

    func fileReadyDocuments(_ documents: [DocumentDTO]) async -> DocumentBatchFileResponseDTO? {
        let ids = documents.filter { $0.readyForBatchFiling == true }.map(\.id)
        guard !ids.isEmpty else { return nil }
        isSaving = true
        errorMessage = nil
        do {
            let response: DocumentBatchFileResponseDTO = try await apiClient.post(
                "/documents/file-ready",
                body: DocumentBatchFileRequest(documentIds: ids)
            )
            HapticManager.success()
            await refreshDocuments()
            isSaving = false
            return response
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = error.localizedDescription
        }
        isSaving = false
        return nil
    }

    func updateMetadata(
        _ document: DocumentDTO,
        title: String,
        category: DocumentCategory,
        documentDate: Date?,
        notes: String,
        personIds: [String]
    ) async -> DocumentDTO? {
        isSaving = true
        errorMessage = nil
        do {
            let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
            let updated: DocumentDTO = try await apiClient.patch(
                "/documents/\(document.id)",
                body: DocumentMetadataUpdateRequest(
                    title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                    category: category.rawValue,
                    documentDate: documentDate.map(ISODateParser.dateOnly),
                    notes: trimmedNotes.isEmpty ? nil : trimmedNotes,
                    personIds: personIds
                )
            )
            HapticManager.success()
            await refreshDocuments()
            isSaving = false
            return updated
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = error.localizedDescription
        }
        isSaving = false
        return nil
    }

    func deleteDocument(_ document: DocumentDTO) async -> Bool {
        do {
            try await apiClient.delete("/documents/\(document.id)")
            documents.removeAll { $0.id == document.id }
            stats = await fetchStats()
            return true
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = error.localizedDescription
        }
        return false
    }

    func detail(for id: String) async throws -> DocumentDTO {
        try await apiClient.get("/documents/\(id)")
    }

    func previewURL(for document: DocumentDTO) async throws -> URL {
        try await DocumentPreviewStore.download(
            documentId: document.id,
            filename: document.originalFilename,
            mediaType: document.mediaType,
            expectedByteCount: document.fileSize
        )
    }

    func removePreview(at url: URL) {
        DocumentPreviewStore.remove(url)
    }

    func draft(from suggestion: CaptureSuggestionDTO) -> CaptureSuggestionDraft {
        CaptureSuggestionDraft(
            id: suggestion.id,
            kind: suggestion.kind,
            title: suggestion.title,
            details: suggestion.details,
            startTime: suggestion.startTime,
            endTime: suggestion.endTime,
            dueDate: suggestion.dueDate,
            allDay: suggestion.allDay,
            assignedTo: suggestion.assignedTo,
            confidence: suggestion.confidence,
            sourceText: suggestion.sourceText
        )
    }

    private func updateStatus(_ document: DocumentDTO, status: String) async -> Bool {
        do {
            let _: DocumentDTO = try await apiClient.patch(
                "/documents/\(document.id)",
                body: DocumentUpdateRequest(
                    title: nil,
                    category: nil,
                    status: status,
                    documentDate: nil,
                    notes: nil,
                    personIds: nil
                )
            )
            await refreshDocuments()
            return true
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = error.localizedDescription
        }
        return false
    }

    private func fetchDocuments(status: String? = nil, offset: Int = 0) async -> [DocumentDTO] {
        let requestedStatus = status ?? (mode == .inbox ? "inbox" : "filed")
        var items = [
            URLQueryItem(name: "status", value: requestedStatus),
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "limit", value: String(pageSize)),
        ]
        if let selectedPersonId {
            items.append(URLQueryItem(name: "person_id", value: selectedPersonId))
        }
        if let selectedCategory {
            items.append(URLQueryItem(name: "category", value: selectedCategory.rawValue))
        }
        let search = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !search.isEmpty {
            items.append(URLQueryItem(name: "search", value: search))
        }
        do {
            return try await apiClient.get("/documents/", queryItems: items)
        } catch let error as APIError {
            errorMessage = error.errorDescription
            return []
        } catch {
            errorMessage = error.localizedDescription
            return []
        }
    }

    private func fetchMembers() async -> [FamilyMemberDTO] {
        do {
            return try await apiClient.get("/family/members")
        } catch is CancellationError {
            return familyMembers
        } catch {
            recordSupplementalFailure(
                section:"Document people",
                message:"People could not be loaded for document filing.",
                error:error
            )
            return familyMembers
        }
    }

    private func fetchStats() async -> DocumentStatsDTO? {
        do {
            return try await apiClient.get("/documents/stats")
        } catch is CancellationError {
            return stats
        } catch {
            recordSupplementalFailure(
                section:"Document statistics",
                message:"Document totals could not be refreshed.",
                error:error
            )
            return stats
        }
    }

    private func fetchInboxAddress() async -> String? {
        do {
            let response:DocumentInboxAddressDTO=try await apiClient.get(
                "/documents/email-address"
            )
            return response.configured ? response.address : nil
        } catch is CancellationError {
            return inboxAddress
        } catch {
            recordSupplementalFailure(
                section:"Document inbox address",
                message:"The document email address could not be refreshed.",
                error:error
            )
            return inboxAddress
        }
    }

    private func recordSupplementalFailure(
        section:String,message:String,error:Error
    ) {
        Self.logger.error(
            "\(section, privacy:.public) failed: \(error.localizedDescription, privacy:.private)"
        )
        if errorMessage == nil { errorMessage=message }
    }
}
