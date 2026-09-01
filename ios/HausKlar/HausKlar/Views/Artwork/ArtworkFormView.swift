import PhotosUI
import SwiftUI

enum ArtworkFormMode: Identifiable {
    case new
    case edit(ArtworkDTO)

    var id: String {
        switch self {
        case .new: return "new"
        case .edit(let artwork): return artwork.id
        }
    }
}

private struct ArtworkFormImage: Identifiable {
    let id = UUID()
    let image: UIImage
    let budgetedByteCount: Int
}

/// Capture / edit form for a piece of artwork. The date is deliberately rough:
/// a year is always required, month and day stay optional ("Any time that year").
struct ArtworkFormView: View {
    @ObservedObject var viewModel: ArtworkViewModel
    let mode: ArtworkFormMode
    var onSaved: ((ArtworkDTO) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss

    @State private var images: [ArtworkFormImage] = []
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var photoPreparationTask: Task<Void, Never>?
    @State private var photoPreparationGeneration: UUID?
    @State private var isPreparingPhotos = false
    @State private var photoPreparationError: String?
    @State private var showingCamera = false
    @State private var showingScanner = false
    @State private var childId: String?
    @State private var year = Calendar.current.component(.year, from: Date())
    @State private var month = Calendar.current.component(.month, from: Date())
    @State private var day = Calendar.current.component(.day, from: Date())
    @State private var title = ""
    @State private var notes = ""
    @State private var medium = ""
    @State private var story = ""
    @State private var childQuote = ""
    @State private var schoolYear = ""
    @State private var favourite = false
    @State private var includeInYearbook = true
    @State private var showingDetails = false
    @State private var prepared = false

    private static let currentYear = Calendar.current.component(.year, from: Date())
    private static let years = Array((currentYear - 20...currentYear).reversed())
    private static let monthNames = DateFormatter().standaloneMonthSymbols ?? []
    private static let maximumImageCount = 30
    private static let maximumPhotoBudgetBytes = PhotoUploadPrep.maximumBatchFileBytes

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    private var approxDate: ApproxDate {
        ApproxDate(year: year, month: month == 0 ? nil : month, day: day == 0 ? nil : day)
    }

    private var canSave: Bool {
        childId != nil && (isEditing || !images.isEmpty) && !viewModel.isSaving
            && !isPreparingPhotos
    }

    private var remainingImageCount: Int {
        max(0, Self.maximumImageCount - images.count)
    }

    private var currentPhotoBudgetBytes: Int {
        images.reduce(0) { partial, image in
            let (total, overflow) = partial.addingReportingOverflow(image.budgetedByteCount)
            return overflow ? Int.max : total
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                if !isEditing {
                    Section("Photo") {
                        photoSection
                    }
                }

                Section("Whose masterpiece?") {
                    ChildSelectorChips(
                        children: viewModel.children,
                        selectedChildId: $childId,
                        nameKeyPath: \.name
                    )
                    if viewModel.children.count == 1, let only = viewModel.children.first {
                        Text(only.name)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("When was it made? (roughly)") {
                    Picker("Year", selection: $year) {
                        ForEach(Self.years, id: \.self) { value in
                            Text(String(value)).tag(value)
                        }
                    }
                    .pickerStyle(.wheel)
                    .frame(height: 100)

                    Picker("Month", selection: $month) {
                        Text("Any time that year").tag(0)
                        ForEach(1...12, id: \.self) { value in
                            Text(Self.monthNames.indices.contains(value - 1) ? Self.monthNames[value - 1] : String(value)).tag(value)
                        }
                    }

                    if month != 0 {
                        Picker("Day", selection: $day) {
                            Text("Any time that month").tag(0)
                            ForEach(1...daysInSelectedMonth, id: \.self) { value in
                                Text(String(value)).tag(value)
                            }
                        }
                    }
                }

                Section {
                    DisclosureGroup("Add details", isExpanded: $showingDetails) {
                        TextField(images.count > 1 ? "Title for this pile (optional)" : "Title (optional)", text: $title)
                            .textInputAutocapitalization(.sentences)
                        TextField("Medium (paint, collage, pencil…)", text: $medium)
                        TextField("School year (optional)", text: $schoolYear)
                        TextField("The story behind it (optional)", text: $story, axis: .vertical)
                            .lineLimit(2...5)
                        TextField("What they said about it (optional)", text: $childQuote, axis: .vertical)
                            .lineLimit(2...4)
                        TextField("Other notes (optional)", text: $notes, axis: .vertical)
                            .lineLimit(2...5)
                        Toggle("Include in Yearbook", isOn: $includeInYearbook)
                        if isEditing {
                            Toggle("Favourite", isOn: $favourite)
                        }
                    }
                }

                if let error = photoPreparationError ?? viewModel.errorMessage {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .accessibilityIdentifier("artworkPhotoPreparationError")
                    }
                }
            }
            .navigationTitle(isEditing ? "Edit Artwork" : "Add Artwork")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task { await save() }
                    }
                    .disabled(!canSave)
                }
            }
            .onChange(of: month) { _, newValue in
                if newValue == 0 || day > daysInSelectedMonth { day = 0 }
            }
            .onChange(of: year) { _, _ in
                if day > daysInSelectedMonth { day = 0 }
            }
            .onChange(of: photoItems) { _, items in
                beginLibraryPhotoPreparation(items)
            }
            .fullScreenCover(isPresented: $showingCamera) {
                ArtworkCameraPicker { captured in
                    beginCapturedPhotoPreparation([captured])
                }
                .ignoresSafeArea()
            }
            .fullScreenCover(isPresented: $showingScanner) {
                ArtworkPileScanner { captured in
                    beginCapturedPhotoPreparation(captured)
                }
                .ignoresSafeArea()
            }
            .overlay {
                if viewModel.isSaving || isPreparingPhotos {
                    ProgressView((viewModel.isSaving ? "Saving..." : "Preparing photos…").localized)
                        .padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                        .accessibilityIdentifier(
                            viewModel.isSaving ? "artworkSaving" : "artworkPhotosPreparing"
                        )
                }
            }
            .task {
                guard !prepared else { return }
                prepared = true
                viewModel.errorMessage = nil
                if viewModel.children.isEmpty {
                    await viewModel.loadChildren()
                }
                switch mode {
                case .new:
                    childId = viewModel.selectedChildId ?? viewModel.children.first?.id
                case .edit(let artwork):
                    childId = artwork.childId
                    title = artwork.title ?? ""
                    notes = artwork.notes ?? ""
                    medium = artwork.medium ?? ""
                    story = artwork.story ?? ""
                    childQuote = artwork.childQuote ?? ""
                    schoolYear = artwork.schoolYear ?? ""
                    favourite = artwork.favourite == true
                    includeInYearbook = artwork.includeInYearbook != false
                    showingDetails = [artwork.title, artwork.notes, artwork.medium, artwork.story, artwork.childQuote, artwork.schoolYear]
                        .contains { ($0 ?? "").isEmpty == false }
                    if let parsed = ApproxDate(string: artwork.approxDate) {
                        year = parsed.year
                        month = parsed.month ?? 0
                        day = parsed.day ?? 0
                    }
                }
            }
            .onDisappear { cancelPhotoPreparation() }
        }
    }

    @ViewBuilder
    private var photoSection: some View {
        let libraryButtonTitle = (
            images.isEmpty ? "Choose photos" : "Choose more photos"
        ).localized

        if !images.isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(Array(images.enumerated()), id: \.element.id) { index, selection in
                        ZStack(alignment: .topTrailing) {
                            Image(uiImage: selection.image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 118, height: 150)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                            Button {
                                images.remove(at: index)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, .black.opacity(0.65))
                                    .font(.title2)
                            }
                            .frame(minWidth: 44, minHeight: 44)
                            .accessibilityLabel("Remove photo \(index + 1)")
                        }
                    }
                }
            }
            if images.count > 1 {
                Text("\(images.count) pieces will keep the same child and date details.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        if ArtworkPileScanner.isSupported {
            Button {
                showingScanner = true
            } label: {
                Label(
                    (images.isEmpty ? "Photograph a pile" : "Photograph more").localized,
                    systemImage: "doc.viewfinder"
                )
            }
            .disabled(remainingImageCount == 0 || isPreparingPhotos)
        } else if UIImagePickerController.isSourceTypeAvailable(.camera) {
            Button {
                showingCamera = true
            } label: {
                Label(
                    (images.isEmpty ? "Take Photo" : "Take another").localized,
                    systemImage: "camera"
                )
            }
            .disabled(remainingImageCount == 0 || isPreparingPhotos)
        }

        if remainingImageCount > 0 {
            PhotosPicker(
                selection: $photoItems,
                maxSelectionCount: remainingImageCount,
                matching: .images
            ) {
                Label(
                    libraryButtonTitle,
                    systemImage: "photo.on.rectangle.angled"
                )
            }
            .disabled(isPreparingPhotos)
        } else {
            Label("Photo limit reached", systemImage: "photo.stack")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func beginLibraryPhotoPreparation(_ selectedItems: [PhotosPickerItem]) {
        guard !selectedItems.isEmpty else { return }
        photoPreparationTask?.cancel()
        let generation = UUID()
        photoPreparationGeneration = generation
        isPreparingPhotos = true
        photoPreparationError = nil
        let admittedCount = PhotoUploadPrep.permittedSelectionCount(
            existingCount: images.count,
            requestedCount: selectedItems.count,
            maximumCount: Self.maximumImageCount
        )
        let admittedItems = Array(selectedItems.prefix(admittedCount))
        let selectionWasLimited = admittedItems.count < selectedItems.count
        photoPreparationTask = Task {
            await prepareLibraryPhotos(
                admittedItems,
                generation: generation,
                selectionWasLimited: selectionWasLimited
            )
        }
    }

    private func prepareLibraryPhotos(
        _ selectedItems: [PhotosPickerItem],
        generation: UUID,
        selectionWasLimited: Bool
    ) async {
        defer { finishPhotoPreparation(generation: generation) }
        var preparedImages: [ArtworkFormImage] = []
        var aggregateBytes = currentPhotoBudgetBytes
        var skippedUnreadablePhoto = false
        var reachedAggregateLimit = false

        for item in selectedItems {
            do {
                try Task.checkCancellation()
                let prepared = try await prepareLibraryPhoto(item)
                do {
                    aggregateBytes = try PhotoUploadPrep.checkedAggregateByteCount(
                        currentBytes: aggregateBytes,
                        nextBytes: prepared.budgetedByteCount,
                        maximumBytes: Self.maximumPhotoBudgetBytes
                    )
                } catch {
                    reachedAggregateLimit = true
                    break
                }
                preparedImages.append(prepared)
            } catch is CancellationError {
                return
            } catch {
                skippedUnreadablePhoto = true
            }
        }

        guard !Task.isCancelled, photoPreparationGeneration == generation else { return }
        images.append(contentsOf: preparedImages)
        if reachedAggregateLimit {
            photoPreparationError =
                "Choose photos totalling no more than 74 MB. The photos already prepared are still here."
                .localized
        } else if skippedUnreadablePhoto {
            photoPreparationError =
                "One or more photos could not be prepared. The other photos are still here."
                .localized
        } else if selectionWasLimited {
            photoPreparationError = "You can add at most 30 photos to one artwork entry.".localized
        }
    }

    private func prepareLibraryPhoto(_ item: PhotosPickerItem) async throws -> ArtworkFormImage {
        let declaredTypes = item.supportedContentTypes.map(\.identifier)
        guard let transfer = try await item.loadTransferable(type: StagedPhotoTransfer.self) else {
            throw PhotoUploadPrepError.unreadableFile
        }
        let stagedFile = try transfer.takeStagedFile()
        defer { PhotoUploadPrep.removeStagedFile(stagedFile) }

        let preparation = Task.detached(priority: .userInitiated) {
            let byteCount = try PhotoUploadPrep.validatedStagedImageByteCount(
                stagedFile,
                declaredTypeIdentifiers: declaredTypes
            )
            try Task.checkCancellation()
            guard let image = PhotoUploadPrep.displayImage(
                at: stagedFile.fileURL,
                maxPixelSize: PhotoUploadPrep.maxUploadPixelSize
            ) else {
                throw PhotoUploadPrepError.unreadableFile
            }
            return ArtworkFormImage(image: image, budgetedByteCount: byteCount)
        }
        let prepared = try await withTaskCancellationHandler {
            try await preparation.value
        } onCancel: {
            preparation.cancel()
        }
        try Task.checkCancellation()
        return prepared
    }

    private func beginCapturedPhotoPreparation(_ capturedImages: [UIImage]) {
        guard !capturedImages.isEmpty else { return }
        photoPreparationTask?.cancel()
        let generation = UUID()
        photoPreparationGeneration = generation
        isPreparingPhotos = true
        photoPreparationError = nil
        let admittedCount = PhotoUploadPrep.permittedSelectionCount(
            existingCount: images.count,
            requestedCount: capturedImages.count,
            maximumCount: Self.maximumImageCount
        )
        let admittedImages = Array(capturedImages.prefix(admittedCount))
        let selectionWasLimited = admittedImages.count < capturedImages.count
        photoPreparationTask = Task {
            await prepareCapturedPhotos(
                admittedImages,
                generation: generation,
                selectionWasLimited: selectionWasLimited
            )
        }
    }

    private func prepareCapturedPhotos(
        _ capturedImages: [UIImage],
        generation: UUID,
        selectionWasLimited: Bool
    ) async {
        defer { finishPhotoPreparation(generation: generation) }
        var preparedImages: [ArtworkFormImage] = []
        var aggregateBytes = currentPhotoBudgetBytes
        var skippedUnsafePhoto = false
        var reachedAggregateLimit = false

        for image in capturedImages {
            do {
                try Task.checkCancellation()
                let prepared = try await prepareCapturedPhoto(image)
                do {
                    aggregateBytes = try PhotoUploadPrep.checkedAggregateByteCount(
                        currentBytes: aggregateBytes,
                        nextBytes: prepared.budgetedByteCount,
                        maximumBytes: Self.maximumPhotoBudgetBytes
                    )
                } catch {
                    reachedAggregateLimit = true
                    break
                }
                preparedImages.append(prepared)
            } catch is CancellationError {
                return
            } catch {
                skippedUnsafePhoto = true
            }
        }

        guard !Task.isCancelled, photoPreparationGeneration == generation else { return }
        images.append(contentsOf: preparedImages)
        if reachedAggregateLimit {
            photoPreparationError =
                "Choose photos totalling no more than 74 MB. The photos already prepared are still here."
                .localized
        } else if skippedUnsafePhoto {
            photoPreparationError =
                "One or more captured photos could not be prepared safely. The other photos are still here."
                .localized
        } else if selectionWasLimited {
            photoPreparationError = "You can add at most 30 photos to one artwork entry.".localized
        }
    }

    private func prepareCapturedPhoto(_ image: UIImage) async throws -> ArtworkFormImage {
        let preparation = Task.detached(priority: .userInitiated) {
            let pixelWidth = image.size.width * image.scale
            let pixelHeight = image.size.height * image.scale
            guard pixelWidth.isFinite, pixelHeight.isFinite,
                  pixelWidth > 0, pixelHeight > 0,
                  pixelWidth <= CGFloat(Int.max), pixelHeight <= CGFloat(Int.max) else {
                throw DocumentCaptureError.imageTooLarge
            }
            try DocumentCaptureService.validateImageDimensions(
                pixelWidth: Int(pixelWidth.rounded(.up)),
                pixelHeight: Int(pixelHeight.rounded(.up))
            )
            guard let data = ArtworkViewModel.downsampledJPEGData(from: image),
                  data.count <= PhotoUploadPrep.maximumOriginalBytes,
                  let boundedImage = PhotoUploadPrep.displayImage(
                      from: data,
                      maxPixelSize: PhotoUploadPrep.maxUploadPixelSize
                  ) else {
                throw PhotoUploadPrepError.unreadableFile
            }
            try Task.checkCancellation()
            return ArtworkFormImage(
                image: boundedImage,
                budgetedByteCount: data.count
            )
        }
        let prepared = try await withTaskCancellationHandler {
            try await preparation.value
        } onCancel: {
            preparation.cancel()
        }
        try Task.checkCancellation()
        return prepared
    }

    private func finishPhotoPreparation(generation: UUID) {
        if photoPreparationGeneration == generation {
            photoItems = []
            isPreparingPhotos = false
            photoPreparationTask = nil
            photoPreparationGeneration = nil
        }
    }

    private func cancelPhotoPreparation() {
        photoPreparationGeneration = nil
        photoPreparationTask?.cancel()
        photoPreparationTask = nil
        photoItems = []
        isPreparingPhotos = false
    }

    private var daysInSelectedMonth: Int {
        guard month != 0 else { return 31 }
        var components = DateComponents()
        components.year = year
        components.month = month
        let calendar = Calendar.current
        guard let date = calendar.date(from: components),
              let range = calendar.range(of: .day, in: .month, for: date) else { return 31 }
        return range.count
    }

    private func save() async {
        guard let childId else { return }
        photoPreparationError = nil
        switch mode {
        case .new:
            let uploadImages = images.map(\.image)
            let saved = await viewModel.upload(
                images: uploadImages,
                childId: childId,
                approxDate: approxDate,
                title: title,
                notes: notes,
                medium: medium,
                story: story,
                childQuote: childQuote,
                schoolYear: schoolYear,
                includeInYearbook: includeInYearbook
            )
            if saved == uploadImages.count {
                dismiss()
            } else if saved > 0 {
                images.removeFirst(min(saved, images.count))
            }
        case .edit(let artwork):
            if let updated = await viewModel.update(
                artwork,
                childId: childId,
                approxDate: approxDate,
                title: title,
                notes: notes,
                medium: medium,
                story: story,
                childQuote: childQuote,
                schoolYear: schoolYear,
                favourite: favourite,
                includeInYearbook: includeInYearbook
            ) {
                onSaved?(updated)
                dismiss()
            }
        }
    }
}
