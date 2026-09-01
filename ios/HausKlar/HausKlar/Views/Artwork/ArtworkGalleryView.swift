import SwiftUI

/// Per-child gallery of archived artwork, newest first.
struct ArtworkGalleryView: View {
    @StateObject private var viewModel = ArtworkViewModel()
    let initialChildId: String?
    let initialArtworkId: String?

    init(initialChildId: String? = nil, initialArtworkId: String? = nil) {
        self.initialChildId = initialChildId
        self.initialArtworkId = initialArtworkId
    }
    @State private var showingCapture = false
    @State private var selectedArtwork: ArtworkDTO?

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ChildSelectorChips(
                    children: viewModel.children,
                    selectedChildId: $viewModel.selectedChildId,
                    nameKeyPath: \.name
                ) { _ in
                    Task { await viewModel.loadArtworks() }
                }

                if let error = viewModel.errorMessage {
                    errorBanner(error)
                }
                if let info = viewModel.infoMessage {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text(info).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button { viewModel.infoMessage = nil } label: { Image(systemName: "xmark") }
                            .accessibilityLabel("Dismiss message")
                    }
                    .padding(10)
                    .background(Color.green.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                if viewModel.artworks.isEmpty {
                    if viewModel.isLoading {
                        ProgressView("Loading artwork...")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                    } else {
                        ContentUnavailableView {
                            Label("No artwork yet", systemImage: "paintpalette")
                        } description: {
                            Text("Photograph a drawing to start \(viewModel.selectedChildName)'s gallery.")
                        } actions: {
                            Button("Add artwork") { showingCapture = true }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                } else {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(viewModel.artworks) { artwork in
                            Button {
                                selectedArtwork = artwork
                            } label: {
                                gridItem(artwork)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button {
                                    Task { _ = await viewModel.setFavourite(artwork, favourite: artwork.favourite != true) }
                                } label: {
                                    Label(
                                        artwork.favourite == true ? "Remove Favourite" : "Favourite",
                                        systemImage: artwork.favourite == true ? "heart.slash" : "heart"
                                    )
                                }
                                Button {
                                    Task {
                                        _ = await viewModel.setYearbookInclusion(
                                            artwork,
                                            included: artwork.includeInYearbook == false
                                        )
                                    }
                                } label: {
                                    Label(
                                        artwork.includeInYearbook == false ? "Add to Yearbook" : "Remove from Yearbook",
                                        systemImage: "book.closed"
                                    )
                                }
                            }
                            .task(id: artwork.id) {
                                async let thumbnail: Void = viewModel.loadThumbnail(for: artwork)
                                async let pagination: Void = viewModel.loadMoreIfNeeded(
                                    after: artwork
                                )
                                _ = await (thumbnail, pagination)
                            }
                            .onDisappear {
                                viewModel.releaseThumbnail(for: artwork.id)
                            }
                        }
                    }
                    if viewModel.isLoadingMore {
                        ProgressView().frame(maxWidth: .infinity).padding()
                    }
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Artwork")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingCapture = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add artwork")
            }
        }
        .sheet(isPresented: $showingCapture) {
            ArtworkFormView(viewModel: viewModel, mode: .new)
        }
        .fullScreenCover(item: $selectedArtwork) { artwork in
            ArtworkDetailView(viewModel: viewModel, artwork: artwork)
        }
        .task {
            if let initialChildId { viewModel.selectedChildId = initialChildId }
            await viewModel.loadChildren()
            await viewModel.loadArtworks()
            if let initialArtworkId {
                if let loaded = viewModel.artworks.first(where: { $0.id == initialArtworkId }) {
                    selectedArtwork = loaded
                } else {
                    do {
                        let artwork:ArtworkDTO=try await APIClient.shared.get(
                            "/artworks/\(initialArtworkId)"
                        )
                        selectedArtwork=artwork
                    } catch is CancellationError {
                        return
                    } catch {
                        viewModel.errorMessage="That artwork could not be opened. Try again."
                    }
                }
            }
        }
        .refreshable {
            await viewModel.loadArtworks()
        }
        .safeAreaInset(edge: .bottom) {
            if let removed = viewModel.recentlyDeleted {
                HStack(spacing: 12) {
                    Text("Removed \(removed.title ?? "artwork")")
                        .font(.subheadline)
                        .lineLimit(1)
                    Spacer()
                    Button("Undo") { Task { await viewModel.undoDelete() } }
                        .fontWeight(.semibold)
                }
                .padding(.horizontal, 16)
                .frame(minHeight: 52)
                .background(.regularMaterial)
            }
        }
    }

    private func gridItem(_ artwork: ArtworkDTO) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Group {
                if let image = viewModel.thumbnails[artwork.id] {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "paintpalette")
                        .font(.title)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 150)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(alignment: .topTrailing) {
                if artwork.favourite == true {
                    Image(systemName: "heart.fill")
                        .foregroundStyle(.white)
                        .padding(7)
                        .background(.pink, in: Circle())
                        .padding(7)
                        .accessibilityHidden(true)
                }
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(artwork.title ?? artwork.dateLabel)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let ageLabel = artwork.ageLabel {
                    Text(ageLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                viewModel.errorMessage = nil
            } label: {
                Image(systemName: "xmark")
            }
            .accessibilityLabel("Dismiss error")
        }
        .padding(10)
        .background(Color.orange.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

#Preview {
    NavigationStack {
        ArtworkGalleryView()
    }
}
