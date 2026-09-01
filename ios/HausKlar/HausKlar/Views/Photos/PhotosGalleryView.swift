import PhotosUI
import SwiftUI

/// A person-first archive of the family's deliberately kept moments. Picking an
/// image never writes immediately: the parent confirms who it belongs to and can
/// add the small amount of context that will make it meaningful years later.
struct PhotosGalleryView: View {
    @StateObject private var viewModel = PhotosViewModel()
    let initialChildId: String?
    let initialPhotoId: String?

    init(initialChildId: String? = nil, initialPhotoId: String? = nil) {
        self.initialChildId = initialChildId
        self.initialPhotoId = initialPhotoId
    }

    @State private var pickedItems: [PhotosPickerItem] = []
    @State private var pendingItems: [PhotosPickerItem] = []
    @State private var showingPhotoLibrary = false
    @State private var showingMomentReview = false
    @State private var selectedPhoto: ChildPhotoDTO?
    @State private var favouritesOnly = false
    @State private var pendingUpload: PendingPhotoUpload?

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 10)]
    private static let maxSelection = 30

    private var visiblePhotos: [ChildPhotoDTO] {
        favouritesOnly ? viewModel.photos.filter { $0.favourite == true } : viewModel.photos
    }

    private var uploadInFlight: Bool {
        viewModel.isUploading || pendingUpload != nil
    }

    var body: some View {
        presentedGallery
            .fullScreenCover(item: $selectedPhoto) { photo in
                PhotoDetailView(viewModel: viewModel, photo: photo)
            }
            .safeAreaInset(edge: .bottom) {
                if let removed = viewModel.recentlyDeleted { undoBar(removed) }
            }
            .task {
                if let initialChildId { viewModel.selectedChildId = initialChildId }
                await viewModel.loadChildren()
                await viewModel.loadPhotos()
                if let initialPhotoId {
                    if let loaded = viewModel.photos.first(where: { $0.id == initialPhotoId }) {
                        selectedPhoto = loaded
                    } else {
                        do {
                            let photo:ChildPhotoDTO=try await APIClient.shared.get(
                                "/child-photos/\(initialPhotoId)"
                            )
                            selectedPhoto=photo
                        } catch is CancellationError {
                            return
                        } catch {
                            viewModel.errorMessage="That photo could not be opened. Try again."
                        }
                    }
                }
            }
            // A view-scoped task is cancelled on navigation, logout or account
            // replacement. `addPhotos` owns and cleans every staged file in its
            // cancellation path before this state is cleared.
            .task(id: pendingUpload?.id) {
                guard let request = pendingUpload else { return }
                await viewModel.addPhotos(
                    from: request.items,
                    childId: request.childId,
                    details: request.details
                )
                if pendingUpload?.id == request.id { pendingUpload = nil }
            }
            .refreshable { await viewModel.loadPhotos() }
    }

    private var gallery: some View {
        ScrollView {
            galleryContent.padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Photos")
        .accessibilityIdentifier(HausKlarAccessibilityID.Photos.screen)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { openPhotoLibrary() } label: { Image(systemName: "plus") }
                    .disabled(uploadInFlight)
                    .accessibilityLabel("Add a moment")
            }
        }
    }

    private var presentedGallery: some View {
        gallery
        .photosPicker(
            isPresented: $showingPhotoLibrary,
            selection: $pickedItems,
            maxSelectionCount: Self.maxSelection,
            matching: .images,
            preferredItemEncoding: .current
        )
        .onChange(of: pickedItems) { _, items in handlePicked(items) }
        .sheet(isPresented: $showingMomentReview, onDismiss: {
            if !viewModel.isUploading { pendingItems = [] }
        }) {
            PhotoMomentReviewSheet(
                children: viewModel.children,
                initialChildId: viewModel.selectedChildId,
                itemCount: pendingItems.count,
                onSave: savePendingMoment
            )
        }
    }

    @ViewBuilder
    private var galleryContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            ChildSelectorChips(
                children: viewModel.children,
                selectedChildId: $viewModel.selectedChildId,
                nameKeyPath: \.name
            ) { _ in
                Task { await viewModel.loadPhotos() }
            }
            .disabled(uploadInFlight)

            addMomentButton
            if viewModel.isUploading { uploadProgress }
            if let info = viewModel.infoMessage { infoBanner(info) }
            if let error = viewModel.errorMessage { errorBanner(error) }
            if !viewModel.photos.isEmpty { filterRow }
            galleryResults
        }
    }

    @ViewBuilder
    private var galleryResults: some View {
        if visiblePhotos.isEmpty {
            if viewModel.isLoading {
                ProgressView("Loading moments…")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                    .accessibilityIdentifier(HausKlarAccessibilityID.Photos.loading)
            } else if !viewModel.isUploading {
                emptyState
            }
        } else {
            photoGrid
        }
    }

    private var photoGrid: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(visiblePhotos) { photo in photoButton(photo) }
        }
    }

    private func photoButton(_ photo: ChildPhotoDTO) -> some View {
        Button {
            selectedPhoto = photo
        } label: {
            gridItem(photo)
        }
        .buttonStyle(.plain)
        .contextMenu { photoMenu(photo) }
        .accessibilityLabel("Photo of \(photo.childDisplayName), \(photo.takenOnLabel)")
        .accessibilityHint(photo.caption.map { $0.isEmpty ? "" : $0 } ?? "")
        .accessibilityIdentifier(HausKlarAccessibilityID.Photos.photo(photo.id))
        .task(id: photo.id) {
            async let thumbnail: Void = viewModel.loadThumbnail(for: photo)
            async let pagination: Void = viewModel.loadMoreIfNeeded(after: photo)
            _ = await (thumbnail, pagination)
        }
        .onDisappear {
            viewModel.releaseThumbnail(for: photo.id)
        }
    }

    @ViewBuilder
    private func photoMenu(_ photo: ChildPhotoDTO) -> some View {
        Button {
            Task { _ = await viewModel.setFavourite(photo, favourite: photo.favourite != true) }
        } label: {
            Label(
                photo.favourite == true ? "Remove favourite" : "Favourite",
                systemImage: photo.favourite == true ? "heart.slash" : "heart"
            )
        }
        Button {
            Task {
                _ = await viewModel.setYearbookInclusion(
                    photo, included: photo.includeInYearbook == false
                )
            }
        } label: {
            Label(
                photo.includeInYearbook == false ? "Add to Yearbook" : "Remove from Yearbook",
                systemImage: "book.closed"
            )
        }
    }

    private var addMomentButton: some View {
        Button { openPhotoLibrary() } label: {
            Label("Add a moment", systemImage: "photo.badge.plus")
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(uploadInFlight)
        .accessibilityHint("Choose photos, then review the person and moment before saving")
        .accessibilityIdentifier(HausKlarAccessibilityID.Photos.openLibrary)
    }

    private var filterRow: some View {
        HStack {
            Text((favouritesOnly ? "Favourite moments" : "All moments").localized)
                .font(.headline)
            Spacer()
            Button {
                favouritesOnly.toggle()
            } label: {
                Label(
                    (favouritesOnly ? "Show all" : "Favourites").localized,
                    systemImage: favouritesOnly ? "photo.on.rectangle" : "heart"
                )
                .font(.subheadline.weight(.semibold))
                .frame(minHeight: 44)
            }
        }
    }

    private var uploadProgress: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ProgressView()
                Text(
                    viewModel.uploadTotal > 0 && viewModel.uploadPrepared < viewModel.uploadTotal
                        ? "Preparing \(min(viewModel.uploadPrepared + 1, viewModel.uploadTotal)) of \(viewModel.uploadTotal)…"
                        : "Saving originals…"
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            if viewModel.uploadTotal > 0 {
                ProgressView(
                    value: Double(viewModel.uploadPrepared),
                    total: Double(viewModel.uploadTotal)
                )
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(HausKlarAccessibilityID.Photos.uploadProgress)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(
                (favouritesOnly ? "No favourites yet" : "No moments yet").localized,
                systemImage: favouritesOnly ? "heart" : "photo.on.rectangle.angled"
            )
        } description: {
            Text(emptyDescription)
        } actions: {
            if favouritesOnly {
                Button("Show all moments") { favouritesOnly = false }
            } else {
                Button("Add a moment") { openPhotoLibrary() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .accessibilityIdentifier(HausKlarAccessibilityID.Photos.empty)
    }

    private var emptyDescription: String {
        if favouritesOnly {
            return "Mark the moments you return to most and they will gather here.".localized
        }
        return String(
            format: "Keep birthdays, first steps and ordinary afternoons for %@.".localized,
            viewModel.selectedChildName
        )
    }

    private func gridItem(_ photo: ChildPhotoDTO) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let image = viewModel.thumbnails[photo.id] {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        Image(systemName: "photo")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 110)
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 10))

                if photo.favourite == true {
                    Image(systemName: "heart.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(7)
                        .background(Color.pink.opacity(0.9), in: Circle())
                        .padding(6)
                        .accessibilityHidden(true)
                }
            }

            VStack(alignment: .leading, spacing: 1) {
                if let caption = photo.caption, !caption.isEmpty {
                    Text(caption)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                }
                Text(photo.takenOnLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private func infoBanner(_ message: String) -> some View {
        banner(
            message,
            symbol: "info.circle.fill",
            colour: .blue,
            identifier: HausKlarAccessibilityID.Photos.info
        ) {
            viewModel.infoMessage = nil
        }
    }

    private func errorBanner(_ message: String) -> some View {
        banner(
            message,
            symbol: "exclamationmark.triangle.fill",
            colour: .orange,
            identifier: HausKlarAccessibilityID.Photos.error
        ) {
            viewModel.errorMessage = nil
        }
    }

    private func banner(
        _ message: String,
        symbol: String,
        colour: Color,
        identifier: String,
        dismiss: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(colour)
            Text(message).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button(action: dismiss) {
                Image(systemName: "xmark").frame(width: 44, height: 44)
            }
            .accessibilityLabel("Dismiss")
        }
        .padding(.leading, 10)
        .background(colour.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }

    private func undoBar(_ photo: ChildPhotoDTO) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "trash.slash")
            Text("Moment removed")
                .font(.subheadline)
                .lineLimit(1)
            Spacer()
            Button("Undo") { Task { await viewModel.undoDelete() } }
                .fontWeight(.semibold)
                .frame(minHeight: 44)
                .accessibilityHint("Restore \(photo.caption ?? photo.takenOnLabel)")
        }
        .padding(.horizontal)
        .background(.regularMaterial)
    }

    private func handlePicked(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        guard !uploadInFlight else {
            pickedItems = []
            viewModel.infoMessage = "Your current photo upload is still in progress.".localized
            return
        }
        pendingItems = items
        pickedItems = []
        showingMomentReview = true
    }

    private func savePendingMoment(childId: String, details: PhotosViewModel.MomentDetails) {
        let items = pendingItems
        pendingItems = []
        showingMomentReview = false
        viewModel.selectedChildId = childId
        pendingUpload = PendingPhotoUpload(items: items, childId: childId, details: details)
    }

    private func openPhotoLibrary() {
        guard !uploadInFlight else {
            viewModel.infoMessage = "Your current photo upload is still in progress.".localized
            return
        }
        if !viewModel.children.isEmpty {
            showingPhotoLibrary = true
            return
        }
        Task {
            await viewModel.loadChildren()
            if !viewModel.children.isEmpty {
                showingPhotoLibrary = true
            } else {
                viewModel.errorMessage = "Add a child before keeping family photos."
            }
        }
    }
}

private struct PendingPhotoUpload: Identifiable {
    let id = UUID()
    let items: [PhotosPickerItem]
    let childId: String
    let details: PhotosViewModel.MomentDetails
}

private struct PhotoMomentReviewSheet: View {
    let children: [ChildDTO]
    let itemCount: Int
    let onSave: (String, PhotosViewModel.MomentDetails) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var childId: String
    @State private var caption = ""
    @State private var location = ""
    @State private var story = ""
    @State private var includeInYearbook = true

    init(
        children: [ChildDTO],
        initialChildId: String?,
        itemCount: Int,
        onSave: @escaping (String, PhotosViewModel.MomentDetails) -> Void
    ) {
        self.children = children
        self.itemCount = itemCount
        self.onSave = onSave
        _childId = State(initialValue: initialChildId ?? children.first?.id ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Who is this about?") {
                    Picker("Person", selection: $childId) {
                        ForEach(children) { child in
                            Text(child.name).tag(child.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier(HausKlarAccessibilityID.Photos.reviewPerson)
                }

                Section("The moment") {
                    TextField("What happened? (optional)", text: $caption)
                    TextField("Place (optional)", text: $location)
                    TextField("A detail worth remembering (optional)", text: $story, axis: .vertical)
                        .lineLimit(2...5)
                    Toggle("Include in Yearbook", isOn: $includeInYearbook)
                }

                Section {
                    Label(
                        "\(itemCount) original file\(itemCount == 1 ? "" : "s") will be kept unchanged.",
                        systemImage: "checkmark.shield"
                    )
                    Text("Camera dates are retained automatically. HausKlar makes smaller copies only for fast browsing.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle((itemCount == 1 ? "Keep this moment" : "Keep these moments").localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(
                            childId,
                            PhotosViewModel.MomentDetails(
                                caption: caption,
                                location: location,
                                story: story,
                                includeInYearbook: includeInYearbook
                            )
                        )
                    }
                    .fontWeight(.semibold)
                    .disabled(childId.isEmpty)
                    .accessibilityIdentifier(HausKlarAccessibilityID.Photos.reviewSave)
                }
            }
        }
        .accessibilityIdentifier(HausKlarAccessibilityID.Photos.review)
        .presentationDetents([.large])
        .interactiveDismissDisabled(false)
    }
}

#Preview {
    NavigationStack { PhotosGalleryView() }
}
