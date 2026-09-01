import SwiftUI
import UIKit

/// Full-screen viewer for one piece of artwork with edit and delete actions.
struct ArtworkDetailView: View {
    @ObservedObject var viewModel: ArtworkViewModel
    @State var artwork: ArtworkDTO

    @Environment(\.dismiss) private var dismiss
    @State private var showingEdit = false
    @State private var showingDeleteConfirmation = false
    @State private var showingAdjustments = false
    @State private var shareItem: ShareExportItem?
    @State private var shareGeneration = UUID()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Group {
                        if let image = viewModel.fullImages[artwork.id] ?? viewModel.thumbnails[artwork.id] {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                        } else {
                            ProgressView()
                                .frame(height: 280)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                    VStack(alignment: .leading, spacing: 6) {
                        if let title = artwork.title, !title.isEmpty {
                            Text(title)
                                .font(.title2.weight(.semibold))
                        }
                        HStack(spacing: 8) {
                            Text(artwork.childDisplayName)
                            Text("·")
                            Text(artwork.dateLabel)
                            if let ageLabel = artwork.ageLabel {
                                Text("·")
                                Text(ageLabel)
                            }
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                        if let notes = artwork.notes, !notes.isEmpty {
                            Text(notes)
                                .font(.body)
                                .padding(.top, 6)
                        }
                        if let medium = artwork.medium, !medium.isEmpty {
                            Label(medium, systemImage: "paintbrush")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .padding(.top, 4)
                        }
                        if let schoolYear = artwork.schoolYear, !schoolYear.isEmpty {
                            Label(schoolYear, systemImage: "backpack")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        if let story = artwork.story, !story.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("The story").font(.headline)
                                Text(story)
                            }
                            .padding(.top, 8)
                        }
                        if let quote = artwork.childQuote, !quote.isEmpty {
                            Text("“\(quote)”")
                                .font(.body.italic())
                                .padding(.top, 4)
                        }
                    }

                    if let error = viewModel.errorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(artwork.childDisplayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        Task {
                            if let updated = await viewModel.setFavourite(
                                artwork,
                                favourite: artwork.favourite != true
                            ) { artwork = updated }
                        }
                    } label: {
                        Image(systemName: artwork.favourite == true ? "heart.fill" : "heart")
                    }
                    .accessibilityLabel(artwork.favourite == true ? "Remove favourite" : "Favourite")

                    Menu {
                        Button("Edit details") { showingEdit = true }
                        Button("Adjust photo") { showingAdjustments = true }
                        Button {
                            Task {
                                if let updated = await viewModel.setYearbookInclusion(
                                    artwork,
                                    included: artwork.includeInYearbook == false
                                ) { artwork = updated }
                            }
                        } label: {
                            Label(
                                artwork.includeInYearbook == false ? "Add to Yearbook" : "Remove from Yearbook",
                                systemImage: "book.closed"
                            )
                        }
                        if let shareItem {
                            ShareLink(item: shareItem.url) {
                                Label("Share", systemImage: "square.and.arrow.up")
                            }
                        }
                        Button {
                            printArtwork()
                        } label: {
                            Label("Print", systemImage: "printer")
                        }
                        Divider()
                        Button("Remove artwork", role: .destructive) {
                            showingDeleteConfirmation = true
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Artwork actions")
                }
            }
            .sheet(isPresented: $showingEdit) {
                ArtworkFormView(viewModel: viewModel, mode: .edit(artwork)) { updated in
                    artwork = updated
                    shareGeneration = UUID()
                }
            }
            .sheet(isPresented: $showingAdjustments) {
                ArtworkAdjustmentSheet(viewModel: viewModel, artwork: artwork) { updated in
                    artwork = updated
                    shareGeneration = UUID()
                }
            }
            .confirmationDialog(
                "Delete this artwork?",
                isPresented: $showingDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    Task {
                        if await viewModel.delete(artwork) {
                            dismiss()
                        }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("It will leave \(artwork.childDisplayName)'s gallery. You can undo this from the gallery.")
            }
            .task(id: shareGeneration) {
                if let previous = shareItem {
                    shareItem = nil
                    await ShareExportStore.shared.releaseAfterUse(previous)
                }
                await viewModel.loadFullImage(for: artwork)
                let prepared = await viewModel.shareFile(for: artwork)
                guard !Task.isCancelled else {
                    if let prepared {
                        await ShareExportStore.shared.releaseAfterUse(prepared)
                    }
                    return
                }
                shareItem = prepared
            }
            .onDisappear {
                releaseShareItem()
                viewModel.releaseThumbnail(for: artwork.id)
                viewModel.releaseFullImage(for: artwork.id)
            }
        }
    }

    private func releaseShareItem() {
        guard let shareItem else { return }
        self.shareItem = nil
        Task {
            await ShareExportStore.shared.releaseAfterUse(shareItem)
        }
    }

    private func printArtwork() {
        guard let image = viewModel.fullImages[artwork.id] ?? viewModel.thumbnails[artwork.id] else { return }
        let controller = UIPrintInteractionController.shared
        controller.printInfo = {
            let info = UIPrintInfo(dictionary: nil)
            info.outputType = .photo
            info.jobName = artwork.title ?? "Artwork"
            return info
        }()
        controller.printingItem = image
        controller.present(animated: true)
    }
}

private struct ArtworkAdjustmentSheet: View {
    @ObservedObject var viewModel: ArtworkViewModel
    let artwork: ArtworkDTO
    let onSaved: (ArtworkDTO) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var rotation: Int
    @State private var enhanced: Bool

    init(
        viewModel: ArtworkViewModel,
        artwork: ArtworkDTO,
        onSaved: @escaping (ArtworkDTO) -> Void
    ) {
        self.viewModel = viewModel
        self.artwork = artwork
        self.onSaved = onSaved
        _rotation = State(initialValue: artwork.rotationDegrees ?? 0)
        _enhanced = State(initialValue: artwork.enhanced == true)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Photo") {
                    HStack {
                        Button {
                            rotation = (rotation + 270) % 360
                        } label: {
                            Label("Turn left", systemImage: "rotate.left")
                        }
                        Spacer()
                        Button {
                            rotation = (rotation + 90) % 360
                        } label: {
                            Label("Turn right", systemImage: "rotate.right")
                        }
                    }
                    .buttonStyle(.borderless)
                    Toggle("Improve paper and lighting", isOn: $enhanced)
                }
                Section {
                    Button("Reset to original") {
                        rotation = 0
                        enhanced = false
                    }
                } footer: {
                    Text("The original photo stays untouched. New camera scans are also straightened and cropped before this screen.")
                }
                if let error = viewModel.errorMessage {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Adjust photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        Task {
                            if let updated = await viewModel.updateAppearance(
                                artwork,
                                rotationDegrees: rotation,
                                enhanced: enhanced
                            ) {
                                onSaved(updated)
                                dismiss()
                            }
                        }
                    }
                    .disabled(viewModel.isSaving)
                }
            }
        }
    }
}
