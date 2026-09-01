import SwiftUI

/// One kept moment, including the quiet context that makes a photo useful later.
/// Sharing always uses the preserved original rather than the gallery rendition.
struct PhotoDetailView: View {
    @ObservedObject var viewModel: PhotosViewModel
    @State var photo: ChildPhotoDTO

    @Environment(\.dismiss) private var dismiss

    @State private var caption = ""
    @State private var location = ""
    @State private var story = ""
    @State private var takenOn = Date()
    @State private var childId = ""
    @State private var favourite = false
    @State private var includeInYearbook = true
    @State private var shareItem: ShareExportItem?
    @State private var preparingShare = false
    @State private var showingDeleteConfirmation = false
    @State private var prepared = false

    private var displayImage: UIImage? {
        viewModel.fullImages[photo.id] ?? viewModel.thumbnails[photo.id]
    }

    private var hasChanges: Bool {
        caption.trimmed != (photo.caption ?? "").trimmed
            || location.trimmed != (photo.location ?? "").trimmed
            || story.trimmed != (photo.story ?? "").trimmed
            || ChildPhotoDTO.takenOnValue(from: takenOn) != photo.takenOn
            || childId != photo.childId
            || favourite != (photo.favourite == true)
            || includeInYearbook != (photo.includeInYearbook != false)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    imageView
                    contextSection
                    archiveSection

                    if let error = viewModel.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .accessibilityIdentifier(HausKlarAccessibilityID.Photos.detailError)
                    }
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(photo.caption?.trimmed.nilIfEmpty ?? photo.takenOnLabel)
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier(HausKlarAccessibilityID.Photos.detail)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        favourite.toggle()
                        Task { await save() }
                    } label: {
                        Image(systemName: favourite ? "heart.fill" : "heart")
                    }
                    .tint(favourite ? .pink : .accentColor)
                    .disabled(!prepared || viewModel.isSaving)
                    .accessibilityLabel(
                        Text(
                            favourite
                                ? "Remove favourite".localized
                                : "Mark as favourite".localized
                        )
                    )

                    if let shareItem {
                        ShareLink(
                            item: shareItem.url,
                            preview: SharePreview(sharePreviewTitle)
                        ) {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .accessibilityLabel("Share original photo")
                    } else if preparingShare {
                        ProgressView().controlSize(.small)
                    }

                    Button(role: .destructive) {
                        showingDeleteConfirmation = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .accessibilityLabel("Remove photo")
                }
            }
            .safeAreaInset(edge: .bottom) {
                if hasChanges { saveBar }
            }
            .confirmationDialog(
                "Remove this moment?",
                isPresented: $showingDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Remove", role: .destructive) {
                    Task {
                        if await viewModel.delete(photo) { dismiss() }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("It leaves \(photo.childDisplayName)'s gallery now. You can undo this from Photos after the viewer closes.")
            }
            .task {
                guard !prepared else { return }
                prepared = true
                viewModel.errorMessage = nil
                caption = photo.caption ?? ""
                location = photo.location ?? ""
                story = photo.story ?? ""
                takenOn = photo.takenOnDate ?? Date()
                childId = photo.childId
                favourite = photo.favourite == true
                includeInYearbook = photo.includeInYearbook != false
                await viewModel.loadFullImage(for: photo)
                preparingShare = true
                let prepared = await viewModel.shareFile(for: photo)
                if Task.isCancelled {
                    if let prepared {
                        await ShareExportStore.shared.releaseAfterUse(prepared)
                    }
                } else {
                    shareItem = prepared
                }
                preparingShare = false
            }
            .onDisappear {
                releaseShareItem()
                viewModel.releaseThumbnail(for: photo.id)
                viewModel.releaseFullImage(for: photo.id)
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

    @ViewBuilder
    private var imageView: some View {
        Group {
            if let image = displayImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .accessibilityLabel("Photo of \(photo.childDisplayName), \(photo.takenOnLabel)")
            } else {
                ProgressView()
                    .frame(height: 280)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("Loading photo")
            }
        }
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier(HausKlarAccessibilityID.Photos.detailImage)
    }

    private var contextSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("The moment")
                .font(.headline)
            labelledField("What happened?", placeholder: "Add a short caption", text: $caption)
            labelledField("Place", placeholder: "Where was this?", text: $location)
            labelledField(
                "Story",
                placeholder: "A detail worth remembering",
                text: $story,
                lineLimit: 2...6
            )

            DatePicker("Date taken", selection: $takenOn, in: ...Date(), displayedComponents: .date)
                .frame(minHeight: 44)

            if viewModel.children.count > 1 {
                Picker("Person", selection: $childId) {
                    ForEach(viewModel.children) { child in
                        Text(child.name).tag(child.id)
                    }
                }
                .pickerStyle(.menu)
                .frame(minHeight: 44)
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var archiveSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Keep & revisit")
                .font(.headline)
            Toggle(isOn: $favourite) {
                Label("Favourite", systemImage: favourite ? "heart.fill" : "heart")
            }
            .tint(.pink)
            Toggle(isOn: $includeInYearbook) {
                Label("Include in Yearbook", systemImage: "book.closed")
            }
            Divider()
            Label(
                photo.originalAvailable == false
                    ? "This older item uses its best available copy"
                    : "Original file preserved",
                systemImage: photo.originalAvailable == false ? "photo" : "checkmark.shield"
            )
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            Text("Sharing sends the original file; the smaller copy above keeps browsing fast.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func labelledField(
        _ label: String,
        placeholder: String,
        text: Binding<String>,
        lineLimit: ClosedRange<Int> = 1...4
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            TextField(placeholder, text: text, axis: .vertical)
                .lineLimit(lineLimit)
                .textInputAutocapitalization(.sentences)
                .padding(12)
                .background(Color(.tertiarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    private var saveBar: some View {
        Button { Task { await save() } } label: {
            if viewModel.isSaving {
                ProgressView().frame(maxWidth: .infinity, minHeight: 28)
            } else {
                Text("Save changes").frame(maxWidth: .infinity, minHeight: 28)
            }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(viewModel.isSaving || childId.isEmpty)
        .padding()
        .background(.thinMaterial)
        .accessibilityLabel(
            Text(viewModel.isSaving ? "Saving changes".localized : "Save changes".localized)
        )
        .accessibilityIdentifier(HausKlarAccessibilityID.Photos.detailSave)
    }

    private var sharePreviewTitle: String {
        photo.caption?.trimmed.nilIfEmpty ?? "\(photo.childDisplayName) — \(photo.takenOnLabel)"
    }

    private func save() async {
        let updated = await viewModel.update(
            photo,
            caption: caption,
            takenOn: ChildPhotoDTO.takenOnValue(from: takenOn),
            childId: childId,
            location: location,
            story: story,
            favourite: favourite,
            includeInYearbook: includeInYearbook
        )
        guard let updated else { return }
        if updated.childId == photo.childId {
            photo = updated
        } else {
            dismiss()
        }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
