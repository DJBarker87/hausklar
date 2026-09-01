import Foundation
import SwiftUI

@MainActor
final class StockViewModel: ObservableObject {

    @Published var stockLevels: [StockLevelDTO] = []
    @Published var expiringItems: [ExpiringItemDTO] = []
    @Published var criticalLowItems: [CriticalLowStockDTO] = []
    @Published var freezerItems: [FreezerItemDTO] = []
    @Published var groceryItems: [GroceryItemListDTO] = []
    @Published var recentPurchaseLines: [PurchaseLineSummary] = []
    @Published var recentBatches: [PurchaseBatchDTO] = []
    @Published var grocerySuggestions: [GrocerySuggestionDTO] = []
    @Published var selectedSuggestionIds: Set<String> = []

    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var processingStockItemId: String?

    // Freezer form
    @Published var showingAddFreezerItem = false
    @Published var freezerFormName = ""
    @Published var freezerFormQty = ""

    // Stock form
    @Published var showingAddStock = false
    @Published var stockFormName = ""
    @Published var stockFormQty = ""
    @Published var stockFormUnit = "each"
    @Published var stockFormStorage = "fridge"
    @Published var stockFormUseByDate = Date()
    @Published var stockFormHasUseByDate = false
    @Published var stockFormTrackUseBy = false

    // Item editor
    @Published var selectedGroceryItemForEdit: GroceryItemListDTO?
    @Published var itemEditName = ""
    @Published var itemEditCategory = ""
    @Published var itemEditDefaultUnit = "each"
    @Published var itemEditUseByTracked = false
    @Published var itemEditDefaultQuantity = ""
    @Published var itemEditAliases = ""
    @Published var itemEditTescoHint = ""

    // Use-by editor
    @Published var editingUseByLine: PurchaseLineSummary?
    @Published var useByEditorDate = Date()

    // Batch detail
    @Published var selectedBatchDetail: PurchaseBatchDTO?

    // Tesco import
    @Published var showingTescoImport = false
    @Published var tescoImportText = ""
    @Published var tescoImportMatches: [TescoImportMatchDTO] = []
    @Published var tescoImportSelectedRawLines: Set<String> = []
    @Published var isProcessingTescoImport = false
    @Published var isImportSavingBatch = false

    // Tesco purchase history (separate from pantry stock)
    @Published var showingTescoHistory = false
    @Published private(set) var tescoHistorySummary = TescoHistorySummaryDTO.empty
    @Published private(set) var tescoHistoryPreview: TescoHistoryPreviewDTO?
    @Published private(set) var tescoHistoryBusy = false
    @Published var tescoHistoryError: String?
    @Published var tescoHistoryNotice: String?

    private let apiClient = APIClient.shared
    private var stagedTescoHistory: TescoHistoryStaging.StagedFile?

    deinit {
        guard let stagedTescoHistory else { return }
        Task { await TescoHistoryStaging.remove(stagedTescoHistory) }
    }

    func loadGroceryDashboard() async {
        isLoading = true
        errorMessage = nil

        async let stockResult: [StockLevelDTO] = apiClient.get("/grocery/stock")
        async let expiringResult: [ExpiringItemDTO] = apiClient.get("/grocery/expiring")
        async let criticalLowResult: [CriticalLowStockDTO] = apiClient.get("/grocery/critical-low")
        async let suggestionsResult: GrocerySuggestionsResponseDTO = apiClient.get("/grocery/suggestions")
        async let freezerResult: [FreezerItemDTO] = apiClient.get("/grocery/freezer")
        async let itemsResult: [GroceryItemListDTO] = apiClient.get("/grocery/items", queryItems: [
            URLQueryItem(name: "limit", value: "200")
        ])
        async let batchesResult: [PurchaseBatchDTO] = apiClient.get("/grocery/batches", queryItems: [
            URLQueryItem(name: "limit", value: "50")
        ])

        do {
            let (stock, expiring, criticalLow, suggestions, freezer, items, batches) = try await (
                stockResult,
                expiringResult,
                criticalLowResult,
                suggestionsResult,
                freezerResult,
                itemsResult,
                batchesResult
            )
            stockLevels = stock.sorted { $0.itemName < $1.itemName }
            expiringItems = expiring.sorted { $0.daysLeft < $1.daysLeft }
            criticalLowItems = criticalLow.sorted { $0.itemName < $1.itemName }
            grocerySuggestions = suggestions.suggestions
            if selectedSuggestionIds.isEmpty {
                selectedSuggestionIds = Set(grocerySuggestions.map(\.groceryItemId))
            } else {
                selectedSuggestionIds = selectedSuggestionIds.intersection(Set(grocerySuggestions.map(\.groceryItemId)))
            }
            freezerItems = freezer.sorted { $0.itemName < $1.itemName }
            groceryItems = items.sorted { $0.name < $1.name }
            recentBatches = batches
            recentPurchaseLines = batches
                .flatMap { batch in
                    batch.lines.map { line in
                        PurchaseLineSummary(
                            id: line.id,
                            purchaseId: line.id,
                            groceryItemId: line.groceryItemId,
                            itemName: line.groceryItemName ?? "Unknown item",
                            qty: line.qty,
                            unit: line.unit,
                            storage: line.storage ?? "fridge",
                            purchasedAt: batch.purchasedAt,
                            useByDate: line.useByDate
                        )
                    }
                }
                .sorted { $0.purchasedAt > $1.purchasedAt }
        } catch let error as APIError {
            errorMessage = error.errorDescription
            stockLevels = []
            expiringItems = []
            criticalLowItems = []
            grocerySuggestions = []
            freezerItems = []
            groceryItems = []
            recentBatches = []
            recentPurchaseLines = []
        } catch {
            errorMessage = "Failed to load grocery insights.".localized
            stockLevels = []
            expiringItems = []
            criticalLowItems = []
            grocerySuggestions = []
            freezerItems = []
            groceryItems = []
            recentBatches = []
            recentPurchaseLines = []
        }

        isLoading = false
    }

    func loadTescoHistorySummary() async {
        do {
            let summary: TescoHistorySummaryDTO = try await apiClient.get(
                "/grocery/tesco-history/summary",
                bypassCache: true
            )
            tescoHistorySummary = summary
        } catch {
            // Purchase history is optional context. Shopping remains usable
            // offline or while this endpoint is unavailable.
        }
    }

    func previewTescoHistory(at sourceURL: URL) async {
        guard !tescoHistoryBusy else { return }
        discardTescoHistoryPreview()
        tescoHistoryBusy = true
        tescoHistoryError = nil
        tescoHistoryNotice = nil
        defer { tescoHistoryBusy = false }

        var stagedFile: TescoHistoryStaging.StagedFile?
        do {
            let staged = try await TescoHistoryStaging.stageSecurityScopedFile(at: sourceURL)
            stagedFile = staged
            let preview: TescoHistoryPreviewDTO = try await apiClient.uploadMultipart(
                "/grocery/tesco-history/preview",
                fileURL: staged.url,
                filename: staged.originalFilename,
                mediaType: staged.mediaType,
                fields: [:]
            )
            stagedTescoHistory = staged
            stagedFile = nil
            tescoHistoryPreview = preview
            if preview.alreadyImported {
                tescoHistoryNotice = "This file is already included."
            }
        } catch let error as APIError {
            if let stagedFile { await TescoHistoryStaging.remove(stagedFile) }
            tescoHistoryError = error.errorDescription
                ?? "The Tesco file could not be read."
        } catch let error as TescoHistoryStagingError {
            if let stagedFile { await TescoHistoryStaging.remove(stagedFile) }
            tescoHistoryError = error.errorDescription
        } catch is CancellationError {
            if let stagedFile { await TescoHistoryStaging.remove(stagedFile) }
        } catch {
            if let stagedFile { await TescoHistoryStaging.remove(stagedFile) }
            tescoHistoryError = "The Tesco file could not be read."
        }
    }

    @discardableResult
    func confirmTescoHistory() async -> Bool {
        guard !tescoHistoryBusy,
              let preview = tescoHistoryPreview,
              preview.canConfirm,
              !preview.alreadyImported,
              let stagedFile = stagedTescoHistory else { return false }
        tescoHistoryBusy = true
        tescoHistoryError = nil
        defer { tescoHistoryBusy = false }

        do {
            let result: TescoHistoryImportResultDTO = try await apiClient.uploadMultipart(
                "/grocery/tesco-history/import",
                fileURL: stagedFile.url,
                filename: stagedFile.originalFilename,
                mediaType: stagedFile.mediaType,
                fields: ["expected_sha256": preview.sha256]
            )
            tescoHistoryNotice = result.importedOrders == 1
                ? "1 Tesco shop added."
                : "\(result.importedOrders) Tesco shops added."
            removeStagedTescoHistory()
            tescoHistoryPreview = nil
            await loadTescoHistorySummary()
            return true
        } catch let error as APIError {
            tescoHistoryError = error.errorDescription
                ?? "Tesco history could not be imported."
        } catch {
            tescoHistoryError = "Tesco history could not be imported."
        }
        return false
    }

    func discardTescoHistoryPreview() {
        guard !tescoHistoryBusy else { return }
        removeStagedTescoHistory()
        tescoHistoryPreview = nil
        tescoHistoryError = nil
    }

    func reportTescoHistoryPickerError(_ error: Error) {
        tescoHistoryError = "The Tesco file could not be opened: \(error.localizedDescription)"
    }

    private func removeStagedTescoHistory() {
        let stagedFile = stagedTescoHistory
        stagedTescoHistory = nil
        guard let stagedFile else { return }
        Task { await TescoHistoryStaging.remove(stagedFile) }
    }

    func logConsumption(for stock: StockLevelDTO, eventType: String) async {
        guard stock.remaining > 0 else {
            errorMessage = "No stock left to log for this item.".localized
            return
        }

        let amount = min(1.0, stock.remaining)
        processingStockItemId = stock.id
        defer { processingStockItemId = nil }

        do {
            let _: ConsumptionEventCreatedResponse = try await apiClient.post(
                "/grocery/consumption",
                body: CreateConsumptionRequest(
                    groceryItemId: stock.groceryItemId,
                    amount: amount,
                    unit: stock.unit,
                    eventType: eventType,
                    source: "app",
                    notes: eventType == "wasted" ? "Marked gone bad from app" : "Marked used from app"
                )
            )
            await loadGroceryDashboard()
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "Failed to log stock update.".localized
        }
    }

    func addFreezerItem() async {
        let name = freezerFormName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            errorMessage = "Please enter freezer item name.".localized
            return
        }
        guard let qty = Double(freezerFormQty), qty > 0 else {
            errorMessage = "Please enter a valid quantity.".localized
            return
        }

        do {
            let _: FreezerItemDTO = try await apiClient.post(
                "/grocery/freezer/add",
                body: AddFreezerItemRequest(name: name, qty: qty, unit: "each")
            )
            freezerFormName = ""
            freezerFormQty = ""
            showingAddFreezerItem = false
            await loadGroceryDashboard()
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "Failed to add freezer item.".localized
        }
    }

    func beginAddStock() {
        stockFormName = ""
        stockFormQty = ""
        stockFormUnit = "each"
        stockFormStorage = "fridge"
        stockFormUseByDate = Date()
        stockFormHasUseByDate = false
        stockFormTrackUseBy = false
        showingAddStock = true
    }

    func addStockManually() async {
        let name = stockFormName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            errorMessage = "Please enter an item name.".localized
            return
        }
        guard let qty = Double(stockFormQty), qty > 0 else {
            errorMessage = "Please enter a valid quantity.".localized
            return
        }

        do {
            let existing = groceryItems.first { $0.name.compare(name, options: .caseInsensitive) == .orderedSame }
            let itemId: String
            if let existing {
                itemId = existing.id
            } else {
                let created: GroceryItemListDTO = try await apiClient.post(
                    "/grocery/items",
                    body: CreateGroceryItemRequest(
                        name: name,
                        category: stockFormStorage == "freezer" ? "frozen" : nil,
                        defaultUnit: stockFormUnit,
                        isUseByTracked: stockFormTrackUseBy
                    )
                )
                itemId = created.id
            }

            let useByDate = stockFormHasUseByDate
                ? MealFormatters.dateOnly.string(from: stockFormUseByDate)
                : nil
            let _: PurchaseBatchDTO = try await apiClient.post(
                "/grocery/batches",
                body: CreatePurchaseBatchRequest(
                    purchasedAt: MealFormatters.eventISO.string(from: Date()),
                    source: "other",
                    notes: "Manual stock add from app",
                    lines: [
                        CreatePurchaseLineRequest(
                            groceryItemId: itemId,
                            qty: qty,
                            unit: stockFormUnit,
                            useByDate: useByDate,
                            storage: stockFormStorage
                        )
                    ]
                )
            )

            showingAddStock = false
            await loadGroceryDashboard()
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "Failed to add stock.".localized
        }
    }

    func openBatchDetail(_ batchId: String) async {
        do {
            let detail: PurchaseBatchDTO = try await apiClient.get("/grocery/batches/\(batchId)")
            selectedBatchDetail = detail
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "Failed to load batch detail.".localized
        }
    }

    func openItemEditor(_ item: GroceryItemListDTO) {
        selectedGroceryItemForEdit = item
        itemEditName = item.name
        itemEditCategory = item.category ?? ""
        itemEditDefaultUnit = item.defaultUnit
        itemEditUseByTracked = item.isUseByTracked
        itemEditDefaultQuantity = item.defaultQuantity.map { String(format: "%.2f", $0) } ?? ""
        itemEditAliases = (item.aliases ?? []).joined(separator: ", ")
        itemEditTescoHint = item.tescoHint ?? ""
    }

    func saveEditedGroceryItem() async {
        guard let item = selectedGroceryItemForEdit else { return }
        let trimmedName = itemEditName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            errorMessage = "Item name is required.".localized
            return
        }
        let aliases = itemEditAliases
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let defaultQty = Double(itemEditDefaultQuantity.trimmingCharacters(in: .whitespacesAndNewlines))

        do {
            let _: GroceryItemListDTO = try await apiClient.put(
                "/grocery/items/\(item.id)",
                body: UpdateGroceryItemRequest(
                    name: trimmedName,
                    category: itemEditCategory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? nil
                        : itemEditCategory.trimmingCharacters(in: .whitespacesAndNewlines),
                    defaultUnit: itemEditDefaultUnit,
                    aliases: aliases.isEmpty ? nil : aliases,
                    isUseByTracked: itemEditUseByTracked,
                    tescoHint: itemEditTescoHint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? nil
                        : itemEditTescoHint.trimmingCharacters(in: .whitespacesAndNewlines),
                    defaultQuantity: defaultQty
                )
            )
            selectedGroceryItemForEdit = nil
            await loadGroceryDashboard()
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "Failed to update grocery item.".localized
        }
    }

    func deleteEditedGroceryItem() async {
        guard let item = selectedGroceryItemForEdit else { return }
        do {
            try await apiClient.delete("/grocery/items/\(item.id)")
            selectedGroceryItemForEdit = nil
            await loadGroceryDashboard()
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "Failed to delete grocery item.".localized
        }
    }

    func openUseByEditor(for line: PurchaseLineSummary) {
        editingUseByLine = line
        if let useBy = line.useByDate,
           let parsed = MealFormatters.dateOnly.date(from: useBy) {
            useByEditorDate = parsed
        } else {
            useByEditorDate = Date()
        }
    }

    func saveUseByDateForEditingLine() async {
        guard let line = editingUseByLine else { return }
        do {
            let _: PurchaseLineDTO = try await apiClient.patch(
                "/grocery/purchases/\(line.purchaseId)/use-by",
                body: UpdateUseByRequest(useByDate: MealFormatters.dateOnly.string(from: useByEditorDate))
            )
            editingUseByLine = nil
            await loadGroceryDashboard()
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "Failed to update use-by date.".localized
        }
    }

    func parseTescoImportText() async {
        let text = tescoImportText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            errorMessage = "Paste Tesco lines first.".localized
            return
        }
        isProcessingTescoImport = true
        defer { isProcessingTescoImport = false }

        do {
            let response: TescoImportResponseDTO = try await apiClient.post(
                "/grocery/import",
                body: TescoImportRequest(rawText: text)
            )
            tescoImportMatches = response.matches
            tescoImportSelectedRawLines = Set(response.matches.compactMap { $0.matchedItemId == nil ? nil : $0.rawLine })
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "Failed to parse Tesco text.".localized
        }
    }

    func toggleTescoImportLine(_ rawLine: String) {
        if tescoImportSelectedRawLines.contains(rawLine) {
            tescoImportSelectedRawLines.remove(rawLine)
        } else {
            tescoImportSelectedRawLines.insert(rawLine)
        }
    }

    func createBatchFromTescoImport() async {
        let selected = tescoImportMatches.filter {
            tescoImportSelectedRawLines.contains($0.rawLine) && $0.matchedItemId != nil
        }
        guard !selected.isEmpty else {
            errorMessage = "No matched lines selected.".localized
            return
        }
        isImportSavingBatch = true
        defer { isImportSavingBatch = false }

        do {
            let lines = selected.compactMap { match -> CreatePurchaseLineRequest? in
                guard let itemId = match.matchedItemId else { return nil }
                let unit = groceryItems.first(where: { $0.id == itemId })?.defaultUnit ?? "each"
                return CreatePurchaseLineRequest(
                    groceryItemId: itemId,
                    qty: 1.0,
                    unit: unit,
                    useByDate: nil,
                    storage: "fridge"
                )
            }
            let _: PurchaseBatchDTO = try await apiClient.post(
                "/grocery/batches",
                body: CreatePurchaseBatchRequest(
                    purchasedAt: MealFormatters.eventISO.string(from: Date()),
                    source: "tesco",
                    notes: "Imported from Tesco text",
                    lines: lines
                )
            )
            showingTescoImport = false
            tescoImportText = ""
            tescoImportMatches = []
            tescoImportSelectedRawLines = []
            await loadGroceryDashboard()
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "Failed to create batch from import.".localized
        }
    }
}

private enum TescoHistoryStagingError: LocalizedError {
    case invalidSource
    case unsupportedType
    case fileTooLarge
    case malformedFile
    case sourceChanged

    var errorDescription: String? {
        switch self {
        case .invalidSource: "The selected Tesco file is not readable."
        case .unsupportedType: "Choose Tesco’s JSON or ZIP file."
        case .fileTooLarge: "The Tesco file must be 25 MB or smaller."
        case .malformedFile: "That does not look like a Tesco JSON or ZIP file."
        case .sourceChanged: "The selected file changed while HausKlar was preparing it."
        }
    }
}

/// Keeps the picker grant open only long enough to copy a bounded report into
/// HausKlar's protected temporary area. The original report is never retained
/// after preview/import is dismissed.
private enum TescoHistoryStaging {
    struct StagedFile: Sendable {
        let url: URL
        let originalFilename: String
        let mediaType: String

        fileprivate var directory: URL { url.deletingLastPathComponent() }
    }

    private static let maximumByteCount = 25 * 1_024 * 1_024
    private static let directoryName = "HausKlarTescoHistory"

    static func stageSecurityScopedFile(at sourceURL: URL) async throws -> StagedFile {
        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessed { sourceURL.stopAccessingSecurityScopedResource() }
        }
        let task = Task.detached(priority: .userInitiated) {
            try stageOnDisk(sourceURL)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    static func remove(_ stagedFile: StagedFile) async {
        await Task.detached(priority: .utility) {
            let manager = FileManager.default
            let root = defaultRoot(fileManager: manager).standardizedFileURL
            let directory = stagedFile.directory.standardizedFileURL
            guard directory.deletingLastPathComponent() == root,
                  UUID(uuidString: directory.lastPathComponent) != nil,
                  stagedFile.url.standardizedFileURL.deletingLastPathComponent() == directory,
                  ["tesco-history.json", "tesco-history.zip"].contains(stagedFile.url.lastPathComponent),
                  let values = try? directory.resourceValues(forKeys: [
                    .isDirectoryKey,
                    .isSymbolicLinkKey,
                  ]),
                  values.isDirectory == true,
                  values.isSymbolicLink != true else { return }
            try? manager.removeItem(at: directory)
        }.value
    }

    nonisolated private static func stageOnDisk(_ sourceURL: URL) throws -> StagedFile {
        try Task.checkCancellation()
        let manager = FileManager.default
        let source = sourceURL.standardizedFileURL
        let fileExtension = source.pathExtension.lowercased()
        guard source.isFileURL, ["json", "zip"].contains(fileExtension) else {
            throw TescoHistoryStagingError.unsupportedType
        }
        let keys: Set<URLResourceKey> = [
            .contentModificationDateKey,
            .fileSizeKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ]
        let initial = try source.resourceValues(forKeys: keys)
        guard initial.isRegularFile == true,
              initial.isSymbolicLink != true,
              let byteCount = initial.fileSize,
              byteCount > 0 else {
            throw TescoHistoryStagingError.invalidSource
        }
        guard byteCount <= maximumByteCount else {
            throw TescoHistoryStagingError.fileTooLarge
        }

        let handle = try FileHandle(forReadingFrom: source)
        let prefix: Data
        do {
            prefix = try handle.read(upToCount: 4_096) ?? Data()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        if fileExtension == "zip" {
            guard prefix.starts(with: [0x50, 0x4B]) else {
                throw TescoHistoryStagingError.malformedFile
            }
        } else {
            let first = prefix.first { ![9, 10, 13, 32].contains($0) }
            guard first == 0x7B || first == 0x5B else {
                throw TescoHistoryStagingError.malformedFile
            }
        }

        let root = defaultRoot(fileManager: manager)
        try LocalFileProtection.prepareDirectory(root, fileManager: manager)
        let directory = root.appendingPathComponent(
            UUID().uuidString.lowercased(),
            isDirectory: true
        )
        try LocalFileProtection.prepareDirectory(directory, fileManager: manager)
        let destination = directory.appendingPathComponent("tesco-history.\(fileExtension)")
        var keepDirectory = false
        defer {
            if !keepDirectory { try? manager.removeItem(at: directory) }
        }
        try manager.copyItem(at: source, to: destination)
        try Task.checkCancellation()
        let finalSource = try source.resourceValues(forKeys: keys)
        let copied = try destination.resourceValues(forKeys: [
            .fileSizeKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ])
        guard finalSource.isRegularFile == true,
              finalSource.isSymbolicLink != true,
              finalSource.fileSize == byteCount,
              finalSource.contentModificationDate == initial.contentModificationDate,
              copied.isRegularFile == true,
              copied.isSymbolicLink != true,
              copied.fileSize == byteCount else {
            throw TescoHistoryStagingError.sourceChanged
        }
        try LocalFileProtection.protectItem(at: destination, fileManager: manager)
        keepDirectory = true
        return StagedFile(
            url: destination,
            originalFilename: safeFilename(source.lastPathComponent, extension: fileExtension),
            mediaType: fileExtension == "zip" ? "application/zip" : "application/json"
        )
    }

    nonisolated private static func safeFilename(_ value: String, extension fileExtension: String) -> String {
        let candidate = (value as NSString).lastPathComponent
        let invalid = CharacterSet.controlCharacters
            .union(.newlines)
            .union(CharacterSet(charactersIn: "/\\:"))
        guard !candidate.isEmpty,
              candidate.utf8.count <= 180,
              candidate.rangeOfCharacter(from: invalid) == nil else {
            return "Tesco history.\(fileExtension)"
        }
        return candidate
    }

    nonisolated private static func defaultRoot(fileManager: FileManager) -> URL {
        fileManager.temporaryDirectory.appendingPathComponent(
            directoryName,
            isDirectory: true
        )
    }
}
