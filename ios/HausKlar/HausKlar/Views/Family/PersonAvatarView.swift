import PhotosUI
import SwiftUI
import UIKit

struct AvatarCropSelection: Identifiable {
    let member: FamilyMemberDTO
    let image: UIImage

    var id: String { member.id }
}

struct PersonAvatarImageView: View {
    let member: FamilyMemberDTO
    var size: CGFloat = 44

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Circle()
                .fill(member.memberType == "child" ? Color.accentColor.opacity(0.14) : Color.blue.opacity(0.12))
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Text(initials)
                    .font(.system(size: max(13, size * 0.34), weight: .bold, design: .rounded))
                    .foregroundStyle(member.memberType == "child" ? Color.accentColor : Color.blue)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
        .task(id: member.avatarURL) {
            image = nil
            guard member.avatarURL != nil,
                  let data = try? await APIClient.shared.downloadData(
                      "/family/members/\(member.id)/avatar",
                      policy: .image(maximumBytes: 2 * 1_024 * 1_024)
                  ),
                  let downloaded = await Task.detached(priority: .userInitiated, operation: {
                      PhotoUploadPrep.displayImage(from: data, maxPixelSize: 512)
                  }).value else { return }
            image = downloaded
        }
    }

    private var initials: String {
        member.name
            .split(separator: " ")
            .prefix(2)
            .compactMap(\.first)
            .map(String.init)
            .joined()
            .uppercased()
    }
}

struct PersonAvatarPicker: View {
    let member: FamilyMemberDTO
    let isSaving: Bool
    let onPicked: (AvatarCropSelection) -> Void
    let onError: (String) -> Void

    @State private var item: PhotosPickerItem?
    @State private var importTask: Task<Void, Never>?
    @State private var importGeneration: UUID?
    @State private var isImporting = false

    var body: some View {
        let showsImportProgress = isImporting
        PhotosPicker(selection: $item, matching: .images) {
            ZStack(alignment: .bottomTrailing) {
                PersonAvatarImageView(member: member, size: 44)
                Image(systemName: "camera.example_5f7f1d8c")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color(.systemBackground))
                    .frame(width: 19, height: 19)
                    .background(Color.primary, in: Circle())
                    .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
                if showsImportProgress {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 44, height: 44)
                        .background(.regularMaterial, in: Circle())
                        .accessibilityLabel("Preparing selected photo")
                        .accessibilityIdentifier("avatarPhotoPreparing")
                }
            }
            .frame(width: 48, height: 48)
        }
        .buttonStyle(.plain)
        .disabled(isSaving)
        .accessibilityLabel("Change photo for \(member.name)")
        .accessibilityValue(isImporting ? "Preparing selected photo".localized : "")
        .onChange(of: item) { _, selected in
            beginImport(selected)
        }
        .onDisappear { cancelImport() }
    }

    private func beginImport(_ selected: PhotosPickerItem?) {
        guard let selected else { return }
        importTask?.cancel()
        let generation = UUID()
        importGeneration = generation
        isImporting = true
        importTask = Task {
            await importPhoto(selected, generation: generation)
        }
    }

    private func importPhoto(_ selected: PhotosPickerItem, generation: UUID) async {
        defer {
            if importGeneration == generation {
                item = nil
                isImporting = false
                importTask = nil
                importGeneration = nil
            }
        }

        do {
            let declaredTypes = selected.supportedContentTypes.map(\.identifier)
            guard let transfer = try await selected.loadTransferable(
                type: StagedPhotoTransfer.self
            ) else {
                throw PhotoUploadPrepError.unreadableFile
            }
            let stagedFile = try transfer.takeStagedFile()
            defer { PhotoUploadPrep.removeStagedFile(stagedFile) }

            let preparation = Task.detached(priority: .userInitiated) {
                _ = try PhotoUploadPrep.validatedStagedImageByteCount(
                    stagedFile,
                    declaredTypeIdentifiers: declaredTypes
                )
                try Task.checkCancellation()
                guard let image = PhotoUploadPrep.displayImage(
                    at: stagedFile.fileURL,
                    maxPixelSize: 2_048
                ) else {
                    throw PhotoUploadPrepError.unreadableFile
                }
                return image
            }
            let source = try await withTaskCancellationHandler {
                try await preparation.value
            } onCancel: {
                preparation.cancel()
            }
            try Task.checkCancellation()
            guard importGeneration == generation else { return }
            onPicked(AvatarCropSelection(member: member, image: source))
        } catch is CancellationError {
            return
        } catch {
            guard importGeneration == generation else { return }
            onError("That photo could not be opened. Please choose another one.".localized)
        }
    }

    private func cancelImport() {
        importGeneration = nil
        importTask?.cancel()
        importTask = nil
        isImporting = false
        item = nil
    }
}

struct PersonAvatarCropView: View {
    @Environment(\.dismiss) private var dismiss

    let selection: AvatarCropSelection
    let onSave: (Data) async throws -> Void

    @State private var zoom: CGFloat = 1
    @State private var committedZoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var committedOffset: CGSize = .zero
    @State private var stageSize: CGFloat = 300
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    Text("Move and zoom the photo until the circle looks right. Nothing changes until you save.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    GeometryReader { proxy in
                        let size = min(proxy.size.width, 360)
                        cropPreview(size: size)
                            .frame(maxWidth: .infinity)
                            .onAppear { stageSize = size }
                            .onChange(of: size) { _, newSize in
                                stageSize = newSize
                                offset = constrained(offset, zoom: zoom, stage: newSize)
                                committedOffset = offset
                            }
                    }
                    .frame(height: min(UIScreen.main.bounds.width - 40, 360))

                    VStack(spacing: 8) {
                        HStack {
                            Image(systemName: "minus.magnifyingglass")
                            Slider(value: $zoom, in: 1...3) { editing in
                                if !editing {
                                    committedZoom = zoom
                                    committedOffset = offset
                                }
                            }
                                .onChange(of: zoom) { _, value in
                                    offset = constrained(offset, zoom: value, stage: stageSize)
                                }
                            Image(systemName: "plus.magnifyingglass")
                        }
                        Text("Zoom")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .contain)

                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("avatarCropError")
                    }
                }
                .padding()
            }
            .navigationTitle("Photo for \(selection.member.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving…" : "Save photo") { save() }
                        .disabled(isSaving)
                }
            }
            .interactiveDismissDisabled(isSaving)
        }
    }

    private func cropPreview(size: CGFloat) -> some View {
        let displayed = displayedSize(stage: size, zoom: zoom)
        return Image(uiImage: selection.image)
            .resizable()
            .frame(width: displayed.width, height: displayed.height)
            .offset(offset)
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay(Circle().stroke(Color.accentColor, lineWidth: 3))
            .contentShape(Circle())
            .gesture(
                DragGesture()
                    .onChanged { value in
                        offset = constrained(
                            CGSize(
                                width: committedOffset.width + value.translation.width,
                                height: committedOffset.height + value.translation.height
                            ),
                            zoom: zoom,
                            stage: size
                        )
                    }
                    .onEnded { _ in committedOffset = offset }
                    .simultaneously(with:
                        MagnificationGesture()
                            .onChanged { value in
                                zoom = min(3, max(1, committedZoom * value))
                                offset = constrained(offset, zoom: zoom, stage: size)
                            }
                            .onEnded { _ in
                                committedZoom = zoom
                                committedOffset = offset
                            }
                    )
            )
            .accessibilityLabel("Circular crop preview for \(selection.member.name)")
            .accessibilityHint("Drag to reposition the photo. Use the zoom slider to resize it.")
    }

    private func displayedSize(stage: CGFloat, zoom: CGFloat) -> CGSize {
        let scale = max(stage / selection.image.size.width, stage / selection.image.size.height) * zoom
        return CGSize(width: selection.image.size.width * scale, height: selection.image.size.height * scale)
    }

    private func constrained(_ proposed: CGSize, zoom: CGFloat, stage: CGFloat) -> CGSize {
        let displayed = displayedSize(stage: stage, zoom: zoom)
        let maxX = max(0, (displayed.width - stage) / 2)
        let maxY = max(0, (displayed.height - stage) / 2)
        return CGSize(
            width: maxX == 0 ? 0 : min(maxX, max(-maxX, proposed.width)),
            height: maxY == 0 ? 0 : min(maxY, max(-maxY, proposed.height))
        )
    }

    private func save() {
        guard let data = renderedCrop()?.jpegData(compressionQuality: 0.88) else {
            errorMessage = "The crop could not be prepared. Please choose another photo."
            HapticManager.error()
            return
        }
        isSaving = true
        errorMessage = nil
        Task {
            do {
                try await onSave(data)
                HapticManager.success()
                dismiss()
            } catch let error as APIError {
                errorMessage = error.errorDescription
                HapticManager.error()
            } catch {
                errorMessage = "The profile photo could not be saved. Please try again."
                HapticManager.error()
            }
            isSaving = false
        }
    }

    private func renderedCrop() -> UIImage? {
        guard stageSize > 0 else { return nil }
        let outputSize = CGSize(width: 512, height: 512)
        let displayed = displayedSize(stage: stageSize, zoom: zoom)
        let multiplier = outputSize.width / stageSize
        let rect = CGRect(
            x: ((stageSize - displayed.width) / 2 + offset.width) * multiplier,
            y: ((stageSize - displayed.height) / 2 + offset.height) * multiplier,
            width: displayed.width * multiplier,
            height: displayed.height * multiplier
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: outputSize, format: format).image { context in
            UIColor.systemBackground.setFill()
            context.cgContext.fill(CGRect(origin: .zero, size: outputSize))
            selection.image.draw(in: rect)
        }
    }
}
