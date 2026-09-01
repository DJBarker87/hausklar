import SwiftUI

/// Semantic photo search over the family archive ("Bismarck recall"). Type a
/// description and browse matching thumbnails.
struct PhotoSearchView: View {
    @StateObject private var viewModel = PhotoSearchViewModel()
    @Environment(\.dismiss) private var dismiss
    @FocusState private var searchFocused: Bool

    private let columns = [GridItem(.adaptive(minimum: 108), spacing: 8)]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchField

                if let error = viewModel.errorMessage {
                    HealthErrorBanner(message: error) { viewModel.errorMessage = nil }
                        .padding(.horizontal)
                        .padding(.bottom, 8)
                }

                content
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Photo search")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Close photo search")
                }
            }
            .onAppear { searchFocused = true }
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search photos, e.g. Child One on the beach", text: $viewModel.query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .onSubmit {
                    Task { await viewModel.search() }
                }
            if !viewModel.query.isEmpty {
                Button {
                    viewModel.clear()
                    searchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding()
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isSearching {
            Spacer()
            ProgressView("Searching...")
            Spacer()
        } else if !viewModel.hasSearched {
            promptState
        } else if viewModel.results.isEmpty {
            emptyState
        } else {
            grid
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(viewModel.results) { result in
                    thumbnail(result)
                        .task(id: result.assetId) {
                            await viewModel.loadThumbnail(for: result)
                        }
                        .onDisappear {
                            viewModel.releaseThumbnail(for: result.assetId)
                        }
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 20)
        }
    }

    private func thumbnail(_ result: PhotoSearchResultDTO) -> some View {
        Group {
            if let image = viewModel.thumbnails[result.assetId] {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle()
                    .fill(Color(.tertiarySystemFill))
                    .overlay {
                        Image(systemName: "photo")
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity)
        .aspectRatio(1, contentMode: .fill)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .bottomLeading) {
            if let taken = result.takenAtDisplay {
                Text(taken)
                    .font(.caption2)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.45), in: Capsule())
                    .padding(5)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(result.takenAtDisplay.map { "Photo from \($0)" } ?? "Photo")
    }

    private var promptState: some View {
        ContentUnavailableView {
            Label("Find a photo", systemImage: "photo.on.rectangle.angled")
        } description: {
            Text("Describe what you're after — a person, place, event or object — and Bismarck will search the family archive.")
        }
    }

    private var emptyState: some View {
        ContentUnavailableView.search(text: viewModel.query)
    }
}

#Preview {
    PhotoSearchView()
}
