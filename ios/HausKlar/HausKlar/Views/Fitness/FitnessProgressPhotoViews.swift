import PhotosUI
import SwiftUI
import UIKit

struct FitnessProgressPhotosView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @StateObject private var viewModel = FitnessProgressPhotoViewModel()
    @State private var showingCapture = false
    @State private var comparisonIds = Set<String>()
    @State private var showingComparison = false
    @State private var poseFilter = "all"
    @State private var phaseFilter = "all"
    @State private var dateFilter = 90

    private var columns: [GridItem] {
        if dynamicTypeSize.isAccessibilitySize {
            return [GridItem(.flexible(), spacing: 12)]
        }
        return [GridItem(.adaptive(minimum: 145), spacing: 12)]
    }

    private var filteredPhotos: [FitnessProgressPhotoDTO] {
        viewModel.photos.filter { photo in
            let poseMatches = poseFilter == "all" || photo.pose.rawValue == poseFilter
            let phaseMatches = phaseFilter == "all" || photo.phaseId == phaseFilter
            let dateMatches: Bool
            if dateFilter == 0 { dateMatches = true }
            else if let captured = FitnessDatabase.date(photo.capturedAt),
                    let threshold = Calendar.current.date(byAdding: .day,value: -dateFilter,to: Date()) {
                dateMatches = captured >= threshold
            } else { dateMatches = false }
            return poseMatches && phaseMatches && dateMatches
        }
    }

    private var comparisonPhotos: [FitnessProgressPhotoDTO] {
        viewModel.photos.filter { comparisonIds.contains($0.id) }
            .sorted { $0.capturedAt < $1.capturedAt }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading,spacing: 16) {
                Text("Private originals are encrypted for your account. Preview images are protected and can be recreated. Photo bytes are never sent to Coach.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .padding(12)
                    .background(.thinMaterial,in: RoundedRectangle(cornerRadius: 12))

                if let error = viewModel.errorMessage {
                    VStack(alignment: .leading,spacing: 8) {
                        Label(error,systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote).foregroundStyle(.primary)
                        Button("Try again",systemImage: "arrow.clockwise") {
                            Task { await viewModel.load(refresh: true) }
                        }
                        .disabled(viewModel.isLoading)
                    }
                    .frame(maxWidth: .infinity,alignment: .leading)
                    .accessibilityIdentifier(HausKlarAccessibilityID.FitnessPhotos.error)
                }

                filters

                if !viewModel.pending.isEmpty {
                    VStack(alignment: .leading,spacing: 8) {
                        Text("Pending private uploads").font(.headline)
                        ForEach(viewModel.pending) { item in
                            pendingRow(item)
                        }
                    }
                }

                if viewModel.isLoading && viewModel.photos.isEmpty {
                    ProgressView("Loading private photos…")
                        .frame(maxWidth: .infinity,minHeight: 180)
                        .accessibilityIdentifier(HausKlarAccessibilityID.FitnessPhotos.loading)
                } else if filteredPhotos.isEmpty {
                    ContentUnavailableView {
                        Label(
                            (viewModel.photos.isEmpty
                                ? "No progress photos yet"
                                : "No photos match these filters").localized,
                            systemImage: "person.example_35fbacff.rectangle"
                        )
                    } description: {
                        Text(
                            (viewModel.photos.isEmpty
                                ? "Capture a labelled photo when you are ready."
                                : "Broaden the date, pose or phase filters.").localized
                        )
                    } actions: {
                        if viewModel.photos.isEmpty {
                            Button("Capture first photo",systemImage: "camera.example_5f7f1d8c") { showingCapture=true }
                                .buttonStyle(.borderedProminent)
                        } else {
                            Button("Reset filters",systemImage: "arrow.counterclockwise") { resetFilters() }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                    .frame(maxWidth: .infinity,minHeight: 260)
                    .accessibilityIdentifier(HausKlarAccessibilityID.FitnessPhotos.empty)
                } else {
                    LazyVGrid(columns: columns,spacing: 12) {
                        ForEach(filteredPhotos) { photo in
                            photoCell(photo)
                        }
                    }
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Progress photos")
        .accessibilityIdentifier(HausKlarAccessibilityID.FitnessPhotos.screen)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if comparisonIds.count == 2 {
                    Button("Compare") { showingComparison = true }
                }
                Button { showingCapture = true } label: { Image(systemName: "camera.example_5f7f1d8c") }
                    .accessibilityLabel("Capture progress photo")
            }
        }
        .sheet(isPresented: $showingCapture) {
            FitnessProgressPhotoCaptureView(viewModel: viewModel)
        }
        .sheet(isPresented: $showingComparison) {
            NavigationStack {
                if comparisonPhotos.count == 2 {
                    FitnessProgressPhotoComparisonView(
                        viewModel: viewModel,
                        source: comparisonPhotos[0],
                        candidates: viewModel.photos,
                        initialOther: comparisonPhotos[1]
                    )
                } else {
                    ContentUnavailableView("Choose two photos",systemImage: "rectangle.split.2x1")
                }
            }
        }
        .task { await viewModel.load() }
        .refreshable { await viewModel.load(refresh: true) }
    }

    private var filters: some View {
        VStack(spacing: 10) {
            if dynamicTypeSize.isAccessibilitySize {
                datePicker
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                datePicker
                    .pickerStyle(.segmented)
            }
            ViewThatFits(in: .horizontal) {
                HStack { secondaryFilters }
                VStack { secondaryFilters }
            }
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground),in: RoundedRectangle(cornerRadius: 12))
    }

    private var datePicker: some View {
        Picker("Date", selection: $dateFilter) {
            Text("30 days").tag(30)
            Text("90 days").tag(90)
            Text("All dates").tag(0)
        }
    }

    @ViewBuilder private var secondaryFilters: some View {
        Picker("Pose",selection: $poseFilter) {
            Text("All poses").tag("all")
            ForEach(FitnessProgressPhotoPose.allCases) { Text($0.title).tag($0.rawValue) }
        }
        Picker("Phase",selection: $phaseFilter) {
            Text("All phases").tag("all")
            ForEach(viewModel.phases) { Text($0.name).tag($0.id) }
        }
    }

    private func resetFilters() {
        poseFilter="all"
        phaseFilter="all"
        dateFilter=0
        comparisonIds.removeAll()
    }

    private func pendingRow(_ item: FitnessPendingProgressPhoto) -> some View {
        HStack(alignment: .top,spacing: 10) {
            Image(systemName: item.lastError == nil ? "arrow.up.circle" : "exclamationmark.arrow.triangle.2.circlepath")
                .foregroundStyle(item.lastError == nil ? .blue : .orange)
            VStack(alignment: .leading,spacing: 3) {
                Text(item.photo.pose.title).font(.subheadline.weight(.semibold))
                Text(pendingLabel(item)).font(.caption).foregroundStyle(.secondary)
                if let error = item.lastError { Text(error).font(.caption).foregroundStyle(.primary) }
                if !item.hasLocalOriginal {
                    Text("Protected original is missing; upload cannot continue.")
                        .font(.caption).foregroundStyle(.primary)
                }
            }
            Spacer()
            if item.lastError != nil || item.state == "error" {
                Button("Retry") { Task { await viewModel.retry(assetId: item.id) } }
                    .buttonStyle(.bordered)
            }
        }
        .padding(10)
        .background(Color(.secondarySystemGroupedBackground),in: RoundedRectangle(cornerRadius: 10))
    }

    private func pendingLabel(_ item: FitnessPendingProgressPhoto) -> String {
        if item.uploadAcknowledged,!item.metadataAcknowledged { return "Private file staged · saving photo details".localized }
        if item.uploadAcknowledged,item.metadataAcknowledged { return "Acknowledged · finishing cleanup".localized }
        return "Protected on this device · waiting to upload".localized
    }

    private func photoCell(_ photo: FitnessProgressPhotoDTO) -> some View {
        VStack(alignment: .leading,spacing: 8) {
            NavigationLink {
                FitnessProgressPhotoDetailView(viewModel: viewModel,photo: photo)
            } label: {
                VStack(alignment: .leading,spacing: 7) {
                    ProtectedFitnessImage(
                        url: viewModel.thumbnailURLs[photo.id], maxPixelSize: 640
                    )
                        .frame(height: 180).clipped()
                        .overlay(alignment: .topTrailing) {
                            if viewModel.pendingItem(photoId: photo.id) != nil {
                                Image(systemName: "icloud.and.arrow.up")
                                    .padding(7).background(.ultraThinMaterial,in: Circle()).padding(6)
                            }
                        }
                    Text(photo.pose.title).font(.headline).foregroundStyle(.primary)
                    Text(photoDate(photo)).font(.caption).foregroundStyle(.secondary)
                    if let weight = photo.bodyWeightKg {
                        Text(String(format: "%.1f kg",weight)).font(.caption).foregroundStyle(.secondary)
                    }
                    if let phase = photo.phaseName ?? viewModel.phases.first(where: { $0.id == photo.phaseId })?.name {
                        Text(phase).font(.caption).foregroundStyle(.purple)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(photoAccessibilityLabel(photo))
            .accessibilityIdentifier(HausKlarAccessibilityID.FitnessPhotos.photo(photo.id))
            Button {
                if comparisonIds.contains(photo.id) { comparisonIds.remove(photo.id) }
                else {
                    if comparisonIds.count == 2, let oldest = comparisonIds.sorted().first {
                        comparisonIds.remove(oldest)
                    }
                    comparisonIds.insert(photo.id)
                }
            } label: {
                Label((comparisonIds.contains(photo.id) ? "Selected" : "Select to compare").localized,
                      systemImage: comparisonIds.contains(photo.id) ? "checkmark.circle.fill" : "circle")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity,minHeight: 44,alignment: .leading)
            .accessibilityValue(
                Text(
                    (comparisonIds.contains(photo.id) ? "Selected" : "Not selected").localized
                )
            )
            .accessibilityIdentifier(
                HausKlarAccessibilityID.FitnessPhotos.comparisonSelection(photo.id)
            )
        }
        .padding(10)
        .background(Color(.secondarySystemGroupedBackground),in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(comparisonIds.contains(photo.id) ? Color.accentColor : .clear,lineWidth: 2)
        }
    }

    private func photoDate(_ photo: FitnessProgressPhotoDTO) -> String {
        FitnessDatabase.date(photo.capturedAt)?.formatted(date: .abbreviated,time: .shortened)
            ?? photo.capturedAt
    }

    private func photoAccessibilityLabel(_ photo: FitnessProgressPhotoDTO) -> String {
        var values = [photo.pose.title, photoDate(photo)]
        if let weight = photo.bodyWeightKg {
            values.append(String(format: "%.1f kilograms", weight))
        }
        if let phase = photo.phaseName
            ?? viewModel.phases.first(where: { $0.id == photo.phaseId })?.name {
            values.append(phase)
        }
        return values.joined(separator: ", ")
    }
}

private struct FitnessProgressPhotoCaptureView: View {
    @ObservedObject var viewModel: FitnessProgressPhotoViewModel
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState
    @State private var pickedItem: PhotosPickerItem?
    @State private var artifact: FitnessProgressPhotoArtifact?
    @State private var previewImage: UIImage?
    @State private var capturedAt = Date()
    @State private var pose: FitnessProgressPhotoPose = .front
    @State private var weight = ""
    @State private var phaseId = ""
    @State private var notes = ""
    @State private var showingCamera = false
    @State private var showAlignment = true
    @State private var importError: String?
    @State private var preparationTask: Task<Void,Never>?
    @State private var preparationGeneration: UUID?
    @State private var saveTask: Task<Void,Never>?
    @State private var isPreparing = false

    private var activeAccountKey: String? {
        appState.currentUser.map { "\($0.familyId ?? ""):\($0.id)" }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Photo") {
                    if let image = previewImage {
                        ZStack {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                                .frame(maxHeight: 330)
                                .accessibilityLabel("Selected progress photo preview")
                            if showAlignment {
                                FitnessPhotoAlignmentGuide()
                                    .allowsHitTesting(false)
                                    .accessibilityHidden(true)
                            }
                        }
                        Toggle("Alignment guide",isOn: $showAlignment)
                    }
                    HStack {
                        PhotosPicker(selection: $pickedItem,matching: .images) {
                            Label("Photo library",systemImage: "photo")
                        }
                        .disabled(isPreparing || saveTask != nil)
                        .accessibilityIdentifier(HausKlarAccessibilityID.FitnessPhotos.library)
                        Spacer()
                        if UIImagePickerController.isSourceTypeAvailable(.camera) {
                            Button { showingCamera = true } label: {
                                Label("Camera",systemImage: "camera")
                            }
                            .disabled(isPreparing || saveTask != nil)
                            .accessibilityIdentifier(HausKlarAccessibilityID.FitnessPhotos.camera)
                        }
                    }
                    if isPreparing {
                        ProgressView("Preparing photo")
                            .accessibilityLabel("Preparing selected progress photo")
                    }
                    if let importError {
                        Label(importError, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.primary)
                            .accessibilityIdentifier(HausKlarAccessibilityID.FitnessPhotos.importError)
                    }
                }
                Section("Labels") {
                    Picker("Pose",selection: $pose) {
                        ForEach(FitnessProgressPhotoPose.allCases) { Text($0.title).tag($0) }
                    }
                    DatePicker("Taken",selection: $capturedAt)
                    TextField("Body weight kg (optional)",text: $weight).keyboardType(.decimalPad)
                    Picker("Training phase",selection: $phaseId) {
                        Text("No linked phase").tag("")
                        ForEach(viewModel.phases) { Text($0.name).tag($0.id) }
                    }
                    TextField("Notes (optional)",text: $notes,axis: .vertical)
                }
                Section {
                    Text("For useful comparisons, keep distance, lighting, clothing and time of day similar. HausKlar does not estimate body fat from photos.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("New progress photo")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        cancelAndDiscard()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        savePreparedPhoto()
                    }
                    .disabled(
                        artifact == nil || isPreparing || saveTask != nil || viewModel.isLoading
                    )
                    .accessibilityLabel(
                        Text(
                            saveTask != nil || viewModel.isLoading
                                ? "Saving photo".localized : "Save".localized
                        )
                    )
                    .accessibilityIdentifier(HausKlarAccessibilityID.FitnessPhotos.save)
                }
            }
            .sheet(isPresented: $showingCamera) {
                ArtworkCameraPicker { image in
                    beginCameraPreparation(image)
                }
                .ignoresSafeArea()
            }
            .onChange(of: pickedItem) { _,item in
                beginLibraryPreparation(item)
            }
        }
        .interactiveDismissDisabled(isPreparing || saveTask != nil)
        .onChange(of: activeAccountKey) { oldIdentity,newIdentity in
            guard oldIdentity != newIdentity else { return }
            cancelAndDiscard()
            dismiss()
        }
        .onDisappear { cancelAndDiscard() }
        .accessibilityIdentifier(HausKlarAccessibilityID.FitnessPhotos.capture)
    }

    private func beginLibraryPreparation(_ item: PhotosPickerItem?) {
        guard let item else { return }
        let generation = beginPreparation()
        preparationTask = Task {
            defer { finishPreparation(generation) }
            var preparedArtifact: FitnessProgressPhotoArtifact?
            do {
                let declaredTypes = item.supportedContentTypes.map(\.identifier)
                guard let transfer = try await item.loadTransferable(
                    type: StagedPhotoTransfer.self
                ) else {
                    throw PhotoUploadPrepError.unreadableFile
                }
                let stagedFile = try transfer.takeStagedFile()
                defer { PhotoUploadPrep.removeStagedFile(stagedFile) }
                let preparation = Task.detached(priority: .userInitiated) {
                    let artifact = try FitnessProgressPhotoPreparation.prepareTransferredFile(
                        stagedFile,
                        declaredTypeIdentifiers: declaredTypes
                    )
                    do {
                        guard let preview = PhotoUploadPrep.displayImage(
                            at: artifact.fileURL,
                            maxPixelSize: 1_600
                        ) else {
                            throw PhotoUploadPrepError.unreadableFile
                        }
                        return (artifact,preview)
                    } catch {
                        FitnessProgressPhotoPreparation.removeArtifact(artifact)
                        throw error
                    }
                }
                let result = try await withTaskCancellationHandler {
                    try await preparation.value
                } onCancel: {
                    preparation.cancel()
                }
                preparedArtifact = result.0
                try Task.checkCancellation()
                guard preparationGeneration == generation else {
                    FitnessProgressPhotoPreparation.removeArtifact(result.0)
                    preparedArtifact = nil
                    return
                }
                artifact = result.0
                preparedArtifact = nil
                previewImage = result.1
                capturedAt = result.0.capturedAt ?? Date()
                importError = nil
            } catch is CancellationError {
                if let preparedArtifact {
                    FitnessProgressPhotoPreparation.removeArtifact(preparedArtifact)
                }
            } catch {
                if let preparedArtifact {
                    FitnessProgressPhotoPreparation.removeArtifact(preparedArtifact)
                }
                guard preparationGeneration == generation else { return }
                importError = error.localizedDescription
            }
        }
    }

    private func beginCameraPreparation(_ image: UIImage) {
        let generation = beginPreparation()
        let takenAt = Date()
        preparationTask = Task {
            defer { finishPreparation(generation) }
            var preparedArtifact: FitnessProgressPhotoArtifact?
            do {
                let preparation = Task.detached(priority: .userInitiated) {
                    let artifact = try FitnessProgressPhotoPreparation.prepareCameraImage(
                        image,
                        capturedAt: takenAt
                    )
                    do {
                        guard let preview = PhotoUploadPrep.displayImage(
                            at: artifact.fileURL,
                            maxPixelSize: 1_600
                        ) else {
                            throw PhotoUploadPrepError.unreadableFile
                        }
                        return (artifact,preview)
                    } catch {
                        FitnessProgressPhotoPreparation.removeArtifact(artifact)
                        throw error
                    }
                }
                let result = try await withTaskCancellationHandler {
                    try await preparation.value
                } onCancel: {
                    preparation.cancel()
                }
                preparedArtifact = result.0
                try Task.checkCancellation()
                guard preparationGeneration == generation else {
                    FitnessProgressPhotoPreparation.removeArtifact(result.0)
                    preparedArtifact = nil
                    return
                }
                artifact = result.0
                preparedArtifact = nil
                previewImage = result.1
                capturedAt = takenAt
                importError = nil
            } catch is CancellationError {
                if let preparedArtifact {
                    FitnessProgressPhotoPreparation.removeArtifact(preparedArtifact)
                }
            } catch {
                if let preparedArtifact {
                    FitnessProgressPhotoPreparation.removeArtifact(preparedArtifact)
                }
                guard preparationGeneration == generation else { return }
                importError = error.localizedDescription
            }
        }
    }

    private func beginPreparation() -> UUID {
        preparationTask?.cancel()
        preparationGeneration = nil
        discardArtifact()
        previewImage = nil
        importError = nil
        let generation = UUID()
        preparationGeneration = generation
        isPreparing = true
        return generation
    }

    private func finishPreparation(_ generation: UUID) {
        guard preparationGeneration == generation else { return }
        pickedItem = nil
        preparationTask = nil
        preparationGeneration = nil
        isPreparing = false
    }

    private func savePreparedPhoto() {
        guard let artifact,saveTask == nil else { return }
        saveTask = Task {
            let succeeded = await viewModel.save(
                artifact: artifact,capturedAt: capturedAt,pose: pose,
                weightKg: Double(weight),phaseId: phaseId.isEmpty ? nil : phaseId,
                notes: notes.isEmpty ? nil : notes
            )
            guard !Task.isCancelled else { return }
            saveTask = nil
            if succeeded {
                self.artifact = nil
                dismiss()
            }
        }
    }

    private func discardArtifact() {
        guard let artifact else { return }
        self.artifact = nil
        FitnessProgressPhotoPreparation.removeArtifact(artifact)
    }

    private func cancelAndDiscard() {
        preparationGeneration = nil
        preparationTask?.cancel()
        preparationTask = nil
        saveTask?.cancel()
        saveTask = nil
        isPreparing = false
        discardArtifact()
    }
}

struct FitnessProgressPhotoDetailView: View {
    @ObservedObject var viewModel: FitnessProgressPhotoViewModel
    let photo: FitnessProgressPhotoDTO
    @Environment(\.dismiss) private var dismiss
    @State private var showingDelete = false
    @State private var showingComparison = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading,spacing: 14) {
                ProtectedFitnessImage(url: viewModel.comparisonURLs[photo.id] ?? viewModel.thumbnailURLs[photo.id])
                    .frame(maxWidth: .infinity,minHeight: 320).clipped()
                LabeledContent("Pose",value: photo.pose.title)
                LabeledContent("Taken",value: FitnessDatabase.date(photo.capturedAt)?.formatted(date: .long,time: .shortened) ?? photo.capturedAt)
                if let weight = photo.bodyWeightKg { LabeledContent("Linked weight",value: String(format: "%.1f kg",weight)) }
                if let phase = photo.phaseName ?? viewModel.phases.first(where: { $0.id == photo.phaseId })?.name {
                    LabeledContent("Training phase",value: phase)
                }
                if let notes = photo.notes { Text(notes) }
                if let pending = viewModel.pendingItem(photoId: photo.id) {
                    Label(
                        pending.lastError ?? "This photo is safely pending upload.".localized,
                        systemImage: "icloud.and.arrow.up"
                    )
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Button {
                    showingComparison = true
                } label: {
                    Label("Compare",systemImage: "rectangle.split.2x1")
                        .frame(minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .disabled(comparisonCandidates.isEmpty)
                if viewModel.pendingItem(photoId: photo.id) == nil {
                    Button("Regenerate thumbnail") {
                        Task { await viewModel.regenerateThumbnail(photo) }
                    }
                    .buttonStyle(.bordered)
                }
                Button("Delete photo",role: .destructive) { showingDelete = true }
                    .buttonStyle(.bordered)
            }
            .padding()
        }
        .navigationTitle(photo.pose.title)
        .task { await viewModel.loadOriginal(photo) }
        .sheet(isPresented: $showingComparison) {
            NavigationStack {
                FitnessProgressPhotoComparisonView(
                    viewModel: viewModel,
                    source: photo,
                    candidates: comparisonCandidates
                )
            }
        }
        .alert("Delete this private photo?",isPresented: $showingDelete) {
            Button("Delete",role: .destructive) {
                Task { if await viewModel.delete(photo) { dismiss() } }
            }
            Button("Cancel",role: .cancel) {}
        } message: {
            Text("The original and thumbnail will be removed. A staged upload is cancelled first; reconnect if HausKlar asks you to.")
        }
    }

    private var comparisonCandidates: [FitnessProgressPhotoDTO] {
        let sourceDate = FitnessDatabase.date(photo.capturedAt)
        return viewModel.photos
            .filter { candidate in
                guard candidate.id != photo.id else { return false }
                guard let sourceDate,let candidateDate = FitnessDatabase.date(candidate.capturedAt) else {
                    return candidate.capturedAt.prefix(10) != photo.capturedAt.prefix(10)
                }
                return !Calendar.current.isDate(candidateDate,inSameDayAs: sourceDate)
            }
            .sorted { $0.capturedAt < $1.capturedAt }
    }
}

private struct FitnessProgressPhotoComparisonView: View {
    @ObservedObject var viewModel: FitnessProgressPhotoViewModel
    let source: FitnessProgressPhotoDTO
    let candidates: [FitnessProgressPhotoDTO]
    @Environment(\.dismiss) private var dismiss
    @State private var mode = 0
    @State private var reveal = 0.5
    @State private var showAlignment = false
    @State private var selectedPhotoId: String?

    init(
        viewModel: FitnessProgressPhotoViewModel,
        source: FitnessProgressPhotoDTO,
        candidates: [FitnessProgressPhotoDTO],
        initialOther: FitnessProgressPhotoDTO? = nil
    ) {
        self.viewModel = viewModel
        self.source = source
        let available = Self.availableCandidates(for: source,from: candidates)
        self.candidates = available
        let initial = initialOther.flatMap { other in
            available.first(where: { $0.id == other.id })
        } ?? Self.recommendedCandidate(for: source,from: available)
        _selectedPhotoId = State(initialValue: initial?.id)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Picker("Comparison",selection: $mode) {
                    Text("Side by side").tag(0)
                    Text("Slider").tag(1)
                }
                .pickerStyle(.segmented).padding(.horizontal)
                Toggle("Alignment guide",isOn: $showAlignment).padding(.horizontal)
                if selectedPhoto != nil {
                    if mode == 0 { sideBySide }
                    else { sliderComparison }
                    photoBrowser
                } else {
                    ContentUnavailableView(
                        "No other dated photos",
                        systemImage: "rectangle.split.2x1",
                        description: Text("Add a progress photo on another date to compare it here.")
                    )
                }
            }
            .padding(.vertical,8)
        }
        .navigationTitle("Compare")
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        .task {
            await viewModel.loadOriginal(source)
            if let selectedPhoto { await viewModel.loadOriginal(selectedPhoto) }
        }
        .onChange(of: selectedPhotoId) { _,_ in
            guard let selectedPhoto else { return }
            Task { await viewModel.loadOriginal(selectedPhoto) }
        }
    }

    private var sideBySide: some View {
        HStack(alignment: .top,spacing: 4) {
            ForEach(comparedPhotos) { photo in
                VStack(spacing: 6) {
                    ZStack {
                        ProtectedFitnessImage(url: viewModel.comparisonURLs[photo.id])
                        if showAlignment { FitnessPhotoAlignmentGuide() }
                    }
                    Text(FitnessDatabase.date(photo.capturedAt)?.formatted(date: .abbreviated,time: .omitted) ?? photo.capturedAt)
                        .font(.caption)
                }
            }
        }
        .padding(.horizontal)
    }

    private var sliderComparison: some View {
        VStack {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    ProtectedFitnessImage(url: viewModel.comparisonURLs[comparedPhotos[0].id])
                        .frame(width: proxy.size.width,height: proxy.size.height)
                    ProtectedFitnessImage(url: viewModel.comparisonURLs[comparedPhotos[1].id])
                        .frame(width: proxy.size.width,height: proxy.size.height)
                        .mask(alignment: .leading) {
                            Rectangle().frame(width: proxy.size.width * reveal)
                        }
                    Rectangle().fill(.white).frame(width: 2).offset(x: proxy.size.width * reveal)
                    if showAlignment { FitnessPhotoAlignmentGuide() }
                }
                .clipped()
            }
            .frame(height: 480)
            Slider(value: $reveal,in: 0...1).padding(.horizontal)
            HStack {
                Text("Before")
                Spacer()
                Text("After")
            }
            .font(.caption).foregroundStyle(.secondary).padding(.horizontal)
        }
    }

    private var photoBrowser: some View {
        VStack(alignment: .leading,spacing: 8) {
            HStack(alignment: .center) {
                VStack(alignment: .leading,spacing: 2) {
                    Text("Other photo").font(.subheadline.weight(.semibold))
                    Text("Swipe through the photos, then tap one.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 8) {
                    Button { moveSelection(by: -1) } label: {
                        Image(systemName: "chevron.left").frame(width: 44,height: 44)
                    }
                    .disabled(selectedIndex <= 0)
                    .accessibilityLabel("Previous progress photo")
                    Button { moveSelection(by: 1) } label: {
                        Image(systemName: "chevron.right").frame(width: 44,height: 44)
                    }
                    .disabled(selectedIndex < 0 || selectedIndex >= candidates.count - 1)
                    .accessibilityLabel("Next progress photo")
                }
                .buttonStyle(.bordered)
            }
            ScrollViewReader { proxy in
                ScrollView(.horizontal,showsIndicators: true) {
                    LazyHStack(spacing: 8) {
                        ForEach(candidates) { candidate in
                            Button {
                                selectedPhotoId = candidate.id
                                HapticManager.selection()
                            } label: {
                                VStack(alignment: .leading,spacing: 5) {
                                    ProtectedFitnessImage(
                                        url: viewModel.thumbnailURLs[candidate.id],maxPixelSize: 360
                                    )
                                    .frame(width: 96,height: 120)
                                    .clipped()
                                    Text(candidate.pose.title)
                                        .font(.caption.weight(.semibold))
                                        .lineLimit(1)
                                    Text(dateLabel(candidate))
                                        .font(.caption).foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                .frame(width: 96,alignment: .leading)
                                .padding(5)
                                .background(
                                    selectedPhotoId == candidate.id
                                        ? Color.accentColor.opacity(0.12)
                                        : Color(.tertiarySystemGroupedBackground),
                                    in: RoundedRectangle(cornerRadius: 11)
                                )
                                .overlay {
                                    RoundedRectangle(cornerRadius: 11)
                                        .stroke(
                                            selectedPhotoId == candidate.id
                                                ? Color.accentColor
                                                : Color.secondary.opacity(0.16),
                                            lineWidth: 1
                                        )
                                }
                            }
                            .buttonStyle(.plain)
                            .id(candidate.id)
                            .accessibilityLabel("Compare with \(candidate.pose.title.lowercased()) photo from \(dateLabel(candidate))")
                            .accessibilityAddTraits(selectedPhotoId == candidate.id ? .isSelected : [])
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom,4)
                }
                .onAppear {
                    if let selectedPhotoId { proxy.scrollTo(selectedPhotoId,anchor: .center) }
                }
                .onChange(of: selectedPhotoId) { _,newValue in
                    if let newValue { proxy.scrollTo(newValue,anchor: .center) }
                }
            }
        }
        .padding(.top,2)
    }

    private var selectedPhoto: FitnessProgressPhotoDTO? {
        candidates.first { $0.id == selectedPhotoId }
    }

    private var selectedIndex: Int {
        candidates.firstIndex { $0.id == selectedPhotoId } ?? -1
    }

    private var comparedPhotos: [FitnessProgressPhotoDTO] {
        guard let selectedPhoto else { return [] }
        return [source,selectedPhoto].sorted { $0.capturedAt < $1.capturedAt }
    }

    private func moveSelection(by offset: Int) {
        let nextIndex = selectedIndex + offset
        guard candidates.indices.contains(nextIndex) else { return }
        selectedPhotoId = candidates[nextIndex].id
        HapticManager.selection()
    }

    private func dateLabel(_ photo: FitnessProgressPhotoDTO) -> String {
        FitnessDatabase.date(photo.capturedAt)?.formatted(date: .abbreviated,time: .omitted)
            ?? String(photo.capturedAt.prefix(10))
    }

    private static func availableCandidates(
        for source: FitnessProgressPhotoDTO,
        from values: [FitnessProgressPhotoDTO]
    ) -> [FitnessProgressPhotoDTO] {
        let sourceDate = FitnessDatabase.date(source.capturedAt)
        return values
            .filter { candidate in
                guard candidate.id != source.id else { return false }
                guard let sourceDate,let candidateDate = FitnessDatabase.date(candidate.capturedAt) else {
                    return candidate.capturedAt.prefix(10) != source.capturedAt.prefix(10)
                }
                return !Calendar.current.isDate(candidateDate,inSameDayAs: sourceDate)
            }
            .sorted { $0.capturedAt < $1.capturedAt }
    }

    private static func recommendedCandidate(
        for source: FitnessProgressPhotoDTO,
        from values: [FitnessProgressPhotoDTO]
    ) -> FitnessProgressPhotoDTO? {
        let sourceDate = FitnessDatabase.date(source.capturedAt)
        return values.sorted { left,right in
            let leftPoseMatches = left.pose == source.pose
            let rightPoseMatches = right.pose == source.pose
            if leftPoseMatches != rightPoseMatches { return leftPoseMatches }
            guard let sourceDate,
                  let leftDate = FitnessDatabase.date(left.capturedAt),
                  let rightDate = FitnessDatabase.date(right.capturedAt) else {
                return left.capturedAt > right.capturedAt
            }
            return abs(leftDate.timeIntervalSince(sourceDate)) < abs(rightDate.timeIntervalSince(sourceDate))
        }.first
    }
}

struct ProtectedFitnessImage: View {
    let url: URL?
    var maxPixelSize = 2_400
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                ZStack {
                    Color(.tertiarySystemGroupedBackground)
                    ProgressView()
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .task(id: url) {
            image = nil
            guard let url else { return }
            let loaded = await Task.detached(priority: .userInitiated) {
                PhotoUploadPrep.displayImage(at: url, maxPixelSize: maxPixelSize)
            }.value
            guard !Task.isCancelled else { return }
            image = loaded
        }
    }
}

private struct FitnessPhotoAlignmentGuide: View {
    var body: some View {
        GeometryReader { proxy in
            Path { path in
                path.move(to: CGPoint(x: proxy.size.width / 2,y: 0))
                path.addLine(to: CGPoint(x: proxy.size.width / 2,y: proxy.size.height))
                path.move(to: CGPoint(x: 0,y: proxy.size.height / 2))
                path.addLine(to: CGPoint(x: proxy.size.width,y: proxy.size.height / 2))
                path.addRect(CGRect(
                    x: proxy.size.width * 0.2,y: proxy.size.height * 0.1,
                    width: proxy.size.width * 0.6,height: proxy.size.height * 0.8
                ))
            }
            .stroke(.white.opacity(0.8),style: StrokeStyle(lineWidth: 1,dash: [7,5]))
            .shadow(color: .black.opacity(0.5),radius: 1)
        }
        .allowsHitTesting(false)
    }
}
