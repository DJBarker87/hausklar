import SwiftUI
import UIKit

/// A warm, keepsake per-child, per-year view — the emotional centrepiece of HausKlar.
/// Reads like a parent flipping through a scrapbook, not an analytics dashboard.
struct YearbookView: View {
    @StateObject private var viewModel: YearbookViewModel
    @State private var shareItem: ShareExportItem?
    @State private var isExporting = false
    @State private var exportError: String?
    @State private var exportGeneration: UUID?
    @State private var showingBuilder = false

    init(initialChildId: String? = nil) {
        _viewModel = StateObject(wrappedValue: YearbookViewModel(initialChildId: initialChildId))
    }

    // Fixed display sizes that still scale with Dynamic Type, tied to a text style.
    // (`Font.system(size:)` has no `relativeTo:`, so scale via @ScaledMetric.)
    @ScaledMetric(relativeTo: .largeTitle) private var coverNameSize: CGFloat = 44
    @ScaledMetric(relativeTo: .title) private var statNumberSize: CGFloat = 32
    @ScaledMetric(relativeTo: .title2) private var statNumberMutedSize: CGFloat = 26
    @ScaledMetric(relativeTo: .subheadline) private var statUnitSize: CGFloat = 15

    private static let dayMonth: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM"
        return formatter
    }()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                controls

                if let error = viewModel.errorMessage {
                    errorBanner(error)
                }

                if isExporting {
                    ProgressView("Preparing the Yearbook PDF…")
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if let exportError {
                    Label(exportError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.primary)
                }

                if viewModel.isLoading && viewModel.yearbook == nil {
                    ProgressView("Opening the yearbook…")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 48)
                } else if let book = viewModel.yearbook {
                    keepsake(book)
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Yearbook")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let shareItem {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(
                        item: shareItem.url,
                        preview: SharePreview("\(viewModel.selectedChildName)'s Yearbook")
                    ) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Export this Yearbook as a PDF")
                }
            }
        }
        .sheet(isPresented: $showingBuilder) {
            YearbookBuilderSheet(viewModel: viewModel, exportItem: $shareItem)
        }
        .task {
            await viewModel.loadChildren()
            await viewModel.loadYears()
            await viewModel.loadYearbook()
        }
        .task(id: shareToken) {
            await generatePDF()
        }
        .refreshable {
            await viewModel.loadYearbook()
        }
        .onDisappear {
            exportGeneration = nil
            isExporting = false
            releaseShareItem()
            viewModel.releaseAllImages()
        }
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            ChildSelectorChips(
                children: viewModel.children,
                selectedChildId: $viewModel.selectedChildId,
                nameKeyPath: \.name
            ) { _ in
                Task { await viewModel.childChanged() }
            }

            if !viewModel.years.isEmpty {
                HStack(spacing: 10) {
                    Menu {
                        ForEach(viewModel.years, id: \.self) { year in
                            Button(String(year)) {
                                guard year != viewModel.selectedYear else { return }
                                viewModel.selectedYear = year
                                Task { await viewModel.loadYearbook() }
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text(String(viewModel.selectedYear))
                                .fontWeight(.semibold)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption2)
                        }
                        .padding(.horizontal, 14)
                        .frame(minHeight: 44)
                        .background(Color(.secondarySystemGroupedBackground), in: Capsule())
                    }
                    .accessibilityLabel("Choose year")

                    Button {
                        showingBuilder = true
                    } label: {
                        Label("Choose & arrange", systemImage: "rectangle.3.group")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .disabled(viewModel.yearbook == nil)
                }
            }
        }
    }

    // MARK: - Keepsake

    @ViewBuilder
    private func keepsake(_ book: YearbookDTO) -> some View {
        cover(book)
        narrativeCard(book)

        if book.isQuiet {
            quietYear(book)
        }

        if let growth = book.sections.growth {
            growthCard(growth)
        }
        if !book.sections.artwork.items.isEmpty {
            artworkCard(book.sections.artwork)
        }
        if !book.sections.adventures.items.isEmpty {
            adventuresCard(book.sections.adventures)
        }
        if book.sections.starCharts.completed > 0 {
            starChartsCard(book.sections.starCharts)
        }
        if showLearning(book.sections.learning) {
            learningCard(book.sections.learning)
        }
        if !book.sections.favouriteMeals.isEmpty {
            mealsCard(book.sections.favouriteMeals)
        }
        if !book.sections.photos.highlights.isEmpty {
            photosCard(book.sections.photos)
        }
        if book.sections.illnesses.count > 0 {
            illnessCard(book.sections.illnesses)
        }

        footer(book)
    }

    private func cover(_ book: YearbookDTO) -> some View {
        VStack(spacing: 8) {
            Text("THE YEARBOOK")
                .font(.caption2.weight(.bold))
                .tracking(2.5)
                .foregroundStyle(.teal)
            Text(book.child.name)
                .font(.system(size: coverNameSize, weight: .semibold, design: .serif))
                .multilineTextAlignment(.center)
                .foregroundStyle(.primary)
            Text("\(String(book.year)) · \(ageLabel(book.child.age))")
                .font(.headline.weight(.regular))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private func narrativeCard(_ book: YearbookDTO) -> some View {
        HStack(alignment: .top, spacing: 0) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.teal)
                .frame(width: 3)
                .padding(.trailing, 14)
            VStack(alignment: .leading, spacing: 12) {
                if let narrative = book.narrative {
                    Text(narrative)
                        .font(.system(.body, design: .serif))
                        .italic()
                        .lineSpacing(5)
                        .foregroundStyle(.primary)
                } else {
                    Text("A whole year of little moments. Write the story of \(book.child.name)'s year whenever you're ready.")
                        .font(.system(.body, design: .serif))
                        .italic()
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    Button {
                        Task { await viewModel.refreshNarrative() }
                    } label: {
                        Label(narrativeButtonTitle(hasNarrative: book.narrative != nil),
                              systemImage: viewModel.isRefreshing ? "arrow.triangle.2.circlepath" : "sparkles")
                            .font(.footnote.weight(.semibold))
                    }
                    .disabled(viewModel.isRefreshing)
                    .tint(.teal)
                    if viewModel.isRefreshing {
                        ProgressView().controlSize(.small)
                    }
                }
                if let note = viewModel.refreshNote {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func quietYear(_ book: YearbookDTO) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.title)
                .foregroundStyle(.teal)
            Text("A gentle year, so far")
                .font(.headline)
            Text("Add artwork, adventures, photos and measurements through the year and \(book.child.name)'s \(String(book.year)) keepsake will fill these pages.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func growthCard(_ growth: YearbookDTO.Growth) -> some View {
        sectionCard("How they grew", systemImage: "ruler") {
            HStack(alignment: .bottom, spacing: 22) {
                if let cm = growth.grewCm, cm > 0 {
                    statTile(number: yearbookTrim(cm), unit: "cm", label: "taller")
                }
                if let kg = growth.gainedKg, kg > 0 {
                    statTile(number: yearbookTrim(kg), unit: "kg", label: "heavier")
                }
                statTile(
                    number: "\(growth.measurements)",
                    unit: "",
                    label: growth.measurements == 1 ? "measurement" : "measurements",
                    muted: true
                )
            }
            if let start = growth.start.heightCm, let end = growth.end.heightCm {
                Text("From \(yearbookTrim(start)) cm to \(yearbookTrim(end)) cm across the year.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func artworkCard(_ artwork: YearbookDTO.Artwork) -> some View {
        sectionCard("Masterpieces", systemImage: "paintpalette", count: artwork.count) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(artwork.items) { item in
                        VStack(spacing: 6) {
                            Group {
                                if let image = viewModel.images[item.id] {
                                    Image(uiImage: image).resizable().scaledToFill()
                                } else {
                                    Image(systemName: "paintpalette")
                                        .font(.title)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(width: 128, height: 128)
                            .background(Color(.tertiarySystemGroupedBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            Text(item.title ?? item.dateLabel)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .frame(width: 128)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(item.title ?? item.dateLabel)
                        .task(id: item.id) {
                            await viewModel.loadArtworkImage(id: item.id)
                        }
                        .onDisappear {
                            viewModel.releaseImage(id: item.id)
                        }
                    }
                }
                .padding(.horizontal, 2)
            }
        }
    }

    private func adventuresCard(_ adventures: YearbookDTO.Adventures) -> some View {
        sectionCard("Adventures", systemImage: "map", count: adventures.count) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(adventures.items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(shortDate(item.startTime))
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.teal)
                            .frame(width: 50, alignment: .leading)
                        Text(item.title)
                            .font(.subheadline)
                        Spacer(minLength: 6)
                        if let location = item.location {
                            Text(location)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 8)
                    if index < adventures.items.count - 1 {
                        Divider()
                    }
                }
            }
        }
    }

    private func starChartsCard(_ stars: YearbookDTO.StarCharts) -> some View {
        sectionCard("Star charts", systemImage: "star.fill") {
            Text(starsLine(stars))
                .font(.subheadline)
            if !stars.titles.isEmpty {
                pills(stars.titles)
            }
        }
    }

    private func learningCard(_ learning: YearbookDTO.Learning) -> some View {
        sectionCard("Books & learning", systemImage: "book") {
            if let line = readingLine(learning) {
                Text(line)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if !learning.books.isEmpty {
                pills(learning.books)
            }
            if learning.bookCount > learning.books.count {
                Text("…and \(learning.bookCount - learning.books.count) more.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func mealsCard(_ meals: [String]) -> some View {
        sectionCard("Favourite dinners", systemImage: "fork.knife") {
            pills(meals, warm: true)
        }
    }

    private func photosCard(_ photos: YearbookDTO.Photos) -> some View {
        sectionCard("Snapshots", systemImage: "photo.on.rectangle", count: photos.count) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: 8)], spacing: 8) {
                ForEach(photos.highlights) { photo in
                    Group {
                        if let image = viewModel.images[photo.assetId] {
                            Image(uiImage: image).resizable().scaledToFill()
                        } else {
                            Color(.tertiarySystemGroupedBackground)
                        }
                    }
                    .frame(height: 88)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    // Decorative thumbnails with no caption/date — the "Snapshots"
                    // header and count already convey the meaning.
                    .accessibilityHidden(true)
                    .task(id: photo.assetId) {
                        await viewModel.loadPhotoImage(id: photo.assetId)
                    }
                    .onDisappear {
                        viewModel.releaseImage(id: photo.assetId)
                    }
                }
            }
        }
    }

    private func illnessCard(_ illnesses: YearbookDTO.Illnesses) -> some View {
        sectionCard("Poorly days", systemImage: "thermometer.medium") {
            Text("\(illnesses.count) \(illnesses.count == 1 ? "spell" : "spells") of being under the weather — and always better again.")
                .font(.caption)
                .foregroundStyle(.secondary)
            let noted = illnesses.items.filter { $0.notes != nil }
            if !noted.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(noted.enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(shortDate(item.startedAt))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text(item.notes ?? "")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func footer(_ book: YearbookDTO) -> some View {
        HStack {
            Text("\(book.child.name) · \(String(book.year))")
            Spacer()
            Text("Made with HausKlar")
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .textCase(.uppercase)
        .padding(.top, 4)
    }

    // MARK: - Building blocks

    private func sectionCard<Content: View>(
        _ title: String,
        systemImage: String,
        count: Int? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .foregroundStyle(.teal)
                Text(title)
                    .font(.system(.title3, design: .serif).weight(.semibold))
                Spacer()
                if let count {
                    Text("\(count)")
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color.teal.opacity(0.14), in: Capsule())
                        .foregroundStyle(.teal)
                }
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func statTile(number: String, unit: String, label: String, muted: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            (
                Text(number)
                    .font(.system(size: muted ? statNumberMutedSize : statNumberSize, weight: .semibold, design: .serif))
                + Text(unit.isEmpty ? "" : " \(unit)")
                    .font(.system(size: statUnitSize, weight: .medium))
            )
            .foregroundStyle(muted ? Color.secondary : Color.primary)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func pills(_ items: [String], warm: Bool = false) -> some View {
        FlowLayout(spacing: 8) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Text(item)
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        warm ? Color.orange.opacity(0.14) : Color(.tertiarySystemGroupedBackground),
                        in: Capsule()
                    )
                    .foregroundStyle(warm ? Color.orange : Color.primary)
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
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Dismiss error")
        }
        .padding(.vertical, 2)
        .padding(.leading, 10)
        .background(Color.orange.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Text helpers

    private func narrativeButtonTitle(hasNarrative: Bool) -> String {
        if hasNarrative {
            return viewModel.isRefreshing ? "Rewriting…" : "Rewrite the story"
        }
        return viewModel.isRefreshing ? "Writing…" : "Write the story"
    }

    private func ageLabel(_ age: Int) -> String {
        age == 1 ? "aged 1" : "aged \(age)"
    }

    private func starsLine(_ stars: YearbookDTO.StarCharts) -> String {
        var line = "\(stars.completed) \(stars.completed == 1 ? "chart" : "charts") completed"
        if stars.earnedPence > 0 {
            line += " · \(stars.earnedDisplay) earned"
        }
        return line
    }

    private func readingLine(_ learning: YearbookDTO.Learning) -> String? {
        var bits: [String] = []
        if learning.readingSessions > 0 {
            bits.append("\(learning.readingSessions) reading \(learning.readingSessions == 1 ? "session" : "sessions")")
        }
        if learning.minutesRead > 0 {
            bits.append("\(learning.minutesRead) minutes of stories")
        }
        if learning.spellingTests > 0 {
            bits.append("\(learning.spellingTests) spelling \(learning.spellingTests == 1 ? "test" : "tests")")
        }
        return bits.isEmpty ? nil : bits.joined(separator: " · ")
    }

    private func showLearning(_ learning: YearbookDTO.Learning) -> Bool {
        learning.readingSessions > 0 || learning.bookCount > 0 || learning.spellingTests > 0
    }

    private func shortDate(_ iso: String) -> String {
        guard let date = ISODateParser.parse(iso) else { return "" }
        return Self.dayMonth.string(from: date)
    }

    // MARK: - Share

    private var shareToken: String {
        guard let book = viewModel.yearbook else { return "none" }
        let artwork = book.sections.artwork.items.map(\.id).joined(separator: ",")
        let photos = book.sections.photos.highlights.map(\.assetId).joined(separator: ",")
        let busy = viewModel.isLoading || viewModel.isRefreshing || viewModel.isBuilderSaving
        return "\(busy)|\(book.child.id)|\(book.year)|\(book.narrative ?? "")|\(artwork)|\(photos)"
    }

    @MainActor
    private func generatePDF() async {
        let generation = UUID()
        exportGeneration = generation
        if let previous = shareItem {
            shareItem = nil
            await ShareExportStore.shared.releaseAfterUse(previous)
        }
        guard let book = viewModel.yearbook,
              !viewModel.isLoading,
              !viewModel.isRefreshing,
              !viewModel.isBuilderSaving else {
            exportError = nil
            if exportGeneration == generation { isExporting = false }
            return
        }
        isExporting = true
        exportError = nil
        defer {
            if exportGeneration == generation { isExporting = false }
        }
        do {
            let images = await viewModel.exportImages(for: book)
            try Task.checkCancellation()
            let item = try await YearbookPDFExporter.export(
                book: book,
                images: images
            )
            guard !Task.isCancelled, exportGeneration == generation else {
                await ShareExportStore.shared.releaseAfterUse(item)
                return
            }
            shareItem = item
        } catch is CancellationError {
            return
        } catch {
            if exportGeneration == generation {
                exportError = "The Yearbook PDF could not be prepared. Please try again."
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
}

// MARK: - Builder

private struct YearbookBuilderSheet: View {
    enum Stage: Int {
        case choose
        case arrange
        case preview
    }

    @ObservedObject var viewModel: YearbookViewModel
    @Binding var exportItem: ShareExportItem?
    @Environment(\.dismiss) private var dismiss
    @State private var stage: Stage = .choose

    private let columns = [GridItem(.adaptive(minimum: 128), spacing: 12)]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                progress
                    .padding(.horizontal)
                    .padding(.bottom, 10)

                if let error = viewModel.builderError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(.horizontal)
                        .padding(.bottom, 8)
                }

                Group {
                    if viewModel.isBuilderLoading && viewModel.options == nil {
                        ProgressView("Opening this year's moments…")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if viewModel.options == nil {
                        ContentUnavailableView(
                            "Yearbook choices unavailable",
                            systemImage: "book.closed",
                            description: Text("Close this sheet and try again when you are connected.")
                        )
                    } else {
                        stageContent
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if viewModel.options != nil { bottomBar }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Build \(viewModel.selectedYear) Yearbook")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .task { await viewModel.loadOptions() }
        }
    }

    private var progress: some View {
        HStack(spacing: 8) {
            progressStep(1, "Choose", active: stage.rawValue >= Stage.choose.rawValue)
            Divider().frame(width: 18)
            progressStep(2, "Arrange", active: stage.rawValue >= Stage.arrange.rawValue)
            Divider().frame(width: 18)
            progressStep(3, "Preview", active: stage.rawValue >= Stage.preview.rawValue)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(stage.rawValue + 1) of 3")
    }

    private func progressStep(_ number: Int, _ title: String, active: Bool) -> some View {
        HStack(spacing: 5) {
            Text("\(number)")
                .font(.caption2.weight(.bold))
                .frame(width: 22, height: 22)
                .background(active ? Color.teal : Color(.tertiarySystemFill), in: Circle())
                .foregroundStyle(active ? .white : .secondary)
            Text(title)
                .font(.caption.weight(active ? .semibold : .regular))
                .foregroundStyle(active ? .primary : .secondary)
        }
    }

    @ViewBuilder
    private var stageContent: some View {
        switch stage {
        case .choose:
            chooseView
        case .arrange:
            arrangeView
        case .preview:
            previewView
        }
    }

    private var chooseView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Choose the moments that belong in the keepsake. Nothing is deleted from Photos or Artwork.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                candidateSection(
                    "Photos",
                    detail: "\(viewModel.photoOrder.count) selected",
                    isEmpty: viewModel.options?.photos.isEmpty != false
                ) {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(viewModel.options?.photos ?? []) { item in
                            photoTile(item)
                        }
                    }
                }

                candidateSection(
                    "Artwork",
                    detail: "\(viewModel.artworkOrder.count) selected",
                    isEmpty: viewModel.options?.artwork.isEmpty != false
                ) {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(viewModel.options?.artwork ?? []) { item in
                            artworkTile(item)
                        }
                    }
                }
            }
            .padding()
        }
    }

    private func candidateSection<Content: View>(
        _ title: String,
        detail: String,
        isEmpty: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.title3.weight(.semibold))
                Spacer()
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            if isEmpty {
                Text("Nothing from this year yet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 12)
            } else {
                content()
            }
        }
    }

    private func photoTile(_ item: YearbookOptionsDTO.PhotoCandidate) -> some View {
        let selected = viewModel.photoOrder.contains(item.id)
        return Button { viewModel.togglePhoto(item.id) } label: {
            candidateTile(
                id: item.id,
                isPhoto: true,
                title: item.caption?.trimmed.nilIfEmpty ?? item.takenOn,
                selected: selected,
                fallbackSymbol: "photo"
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(item.caption?.trimmed.nilIfEmpty ?? "Photo from \(item.takenOn)"), \(selected ? "selected" : "not selected")")
    }

    private func artworkTile(_ item: YearbookOptionsDTO.ArtworkCandidate) -> some View {
        let selected = viewModel.artworkOrder.contains(item.id)
        return Button { viewModel.toggleArtwork(item.id) } label: {
            candidateTile(
                id: item.id,
                isPhoto: false,
                title: item.title?.trimmed.nilIfEmpty ?? item.approxDate,
                selected: selected,
                fallbackSymbol: "paintpalette"
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(item.title?.trimmed.nilIfEmpty ?? "Artwork from \(item.approxDate)"), \(selected ? "selected" : "not selected")")
    }

    private func candidateTile(
        id: String,
        isPhoto: Bool,
        title: String,
        selected: Bool,
        fallbackSymbol: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let image = viewModel.images[id] {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        Image(systemName: fallbackSymbol)
                            .font(.title)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 124)
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 10))

                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(selected ? .white : .white, selected ? Color.teal : Color.black.opacity(0.35))
                    .padding(7)
            }
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(2)
        }
        .task(id: id) {
            if isPhoto {
                await viewModel.loadPhotoImage(id: id)
            } else {
                await viewModel.loadArtworkImage(id: id)
            }
        }
        .onDisappear {
            viewModel.releaseImage(id: id)
        }
    }

    private var arrangeView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Put the strongest moments first. The first twelve photos become the Yearbook highlights.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                orderSection("Photos", ids: viewModel.photoOrder, isPhoto: true)
                orderSection("Artwork", ids: viewModel.artworkOrder, isPhoto: false)

                Text("Growth, adventures, books, star charts and favourite meals are added automatically from HausKlar's detailed records.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(14)
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .padding()
        }
    }

    private func orderSection(_ title: String, ids: [String], isPhoto: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.title3.weight(.semibold))
            if ids.isEmpty {
                Text("No \(title.lowercased()) selected.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(ids.enumerated()), id: \.element) { index, id in
                orderRow(id: id, index: index, count: ids.count, isPhoto: isPhoto)
            }
        }
    }

    private func orderRow(id: String, index: Int, count: Int, isPhoto: Bool) -> some View {
        let title: String = if isPhoto {
            viewModel.photoCandidate(id)?.caption?.trimmed.nilIfEmpty
                ?? viewModel.photoCandidate(id)?.takenOn
                ?? "Photo"
        } else {
            viewModel.artworkCandidate(id)?.title?.trimmed.nilIfEmpty
                ?? viewModel.artworkCandidate(id)?.approxDate
                ?? "Artwork"
        }
        return HStack(spacing: 12) {
            if let image = viewModel.images[id] {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 54, height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Image(systemName: isPhoto ? "photo" : "paintpalette")
                    .frame(width: 54, height: 54)
                    .background(Color(.tertiarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("\(index + 1)").font(.caption.weight(.bold)).foregroundStyle(.teal)
                Text(title).font(.subheadline.weight(.medium)).lineLimit(2)
            }
            Spacer()
            Button {
                isPhoto ? viewModel.movePhoto(id, by: -1) : viewModel.moveArtwork(id, by: -1)
            } label: {
                Image(systemName: "arrow.up").frame(width: 44, height: 44)
            }
            .disabled(index == 0)
            .accessibilityLabel("Move \(title) earlier")
            Button {
                isPhoto ? viewModel.movePhoto(id, by: 1) : viewModel.moveArtwork(id, by: 1)
            } label: {
                Image(systemName: "arrow.down").frame(width: 44, height: 44)
            }
            .disabled(index == count - 1)
            .accessibilityLabel("Move \(title) later")
        }
        .padding(.leading, 10)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .task(id: id) {
            if isPhoto {
                await viewModel.loadPhotoImage(id: id)
            } else {
                await viewModel.loadArtworkImage(id: id)
            }
        }
        .onDisappear {
            viewModel.releaseImage(id: id)
        }
    }

    private var previewView: some View {
        ScrollView {
            VStack(spacing: 18) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.teal)
                Text("Your keepsake is ready")
                    .font(.title2.weight(.semibold))
                if let book = viewModel.yearbook {
                    VStack(spacing: 7) {
                        Text(book.child.name)
                            .font(.system(.largeTitle, design: .serif).weight(.semibold))
                        Text("\(book.year) · aged \(book.child.age)")
                            .foregroundStyle(.secondary)
                        HStack(spacing: 20) {
                            previewCount(book.sections.photos.count, "photos")
                            previewCount(book.sections.artwork.count, "artworks")
                            previewCount(book.sections.adventures.count, "adventures")
                        }
                        .padding(.top, 10)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(24)
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                }
                Text("The PDF includes the story, chosen moments and HausKlar's automatic record of the year.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                if let exportItem {
                    ShareLink(item: exportItem.url, preview: SharePreview("Yearbook PDF")) {
                        Label("Export PDF", systemImage: "square.and.arrow.up")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                } else {
                    ProgressView("Preparing PDF…")
                }
            }
            .padding()
        }
    }

    private func previewCount(_ value: Int, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text("\(value)").font(.title3.weight(.semibold))
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            if stage != .choose {
                Button("Back") {
                    stage = stage == .preview ? .arrange : .choose
                }
                .frame(minHeight: 44)
                .disabled(viewModel.isBuilderSaving)
            }
            Button {
                advance()
            } label: {
                if viewModel.isBuilderSaving {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 28)
                } else {
                    Text(stage == .choose ? "Arrange" : stage == .arrange ? "Save & preview" : "Done")
                        .frame(maxWidth: .infinity, minHeight: 28)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(viewModel.isBuilderSaving)
        }
        .padding()
        .background(.regularMaterial)
    }

    private func advance() {
        switch stage {
        case .choose:
            stage = .arrange
        case .arrange:
            Task {
                if await viewModel.saveArrangement(), viewModel.yearbook != nil {
                    stage = .preview
                }
            }
        case .preview:
            dismiss()
        }
    }
}

// MARK: - PDF export

/// A real, self-contained PDF rather than a screenshot. It keeps the chosen image
/// order and writes the quieter structured sections as text so the export remains
/// useful even when a thumbnail could not be fetched.
private enum YearbookPDFExporter {
    private static let page = CGRect(x: 0, y: 0, width: 595, height: 842)
    private static let margin: CGFloat = 44
    private static let teal = UIColor(red: 0.02, green: 0.50, blue: 0.48, alpha: 1)

    static func export(
        book: YearbookDTO,
        images: [String: UIImage]
    ) async throws -> ShareExportItem {
        let lease = try await ShareExportStore.shared.currentLease()
        let safeName = book.child.name.replacingOccurrences(of: "/", with: "-")
        return try await ShareExportStore.shared.publishGeneratedFile(
            filename: "\(safeName)-\(book.year)-Yearbook.pdf",
            maximumBytes: 75 * 1_024 * 1_024,
            lease: lease
        ) { destination in
            try Task.checkCancellation()
            let renderer = UIGraphicsPDFRenderer(bounds: page)
            try renderer.writePDF(to: destination) { context in
                guard !Task.isCancelled else { return }
                drawCover(book, context: context)
                if !book.sections.photos.highlights.isEmpty, !Task.isCancelled {
                    drawPhotoPage(book, images: images, context: context)
                }
                if !book.sections.artwork.items.isEmpty, !Task.isCancelled {
                    drawArtworkPage(book, images: images, context: context)
                }
                if !Task.isCancelled {
                    drawDetailsPage(book, context: context)
                }
            }
            try Task.checkCancellation()
        }
    }

    private static func drawCover(_ book: YearbookDTO, context: UIGraphicsPDFRendererContext) {
        context.beginPage()
        var y: CGFloat = 96
        y += draw(
            "THE YEARBOOK",
            at: y,
            font: .systemFont(ofSize: 12, weight: .bold),
            colour: teal,
            alignment: .center,
            tracking: 2.5
        ) + 18
        y += draw(
            book.child.name,
            at: y,
            font: .systemFont(ofSize: 48, weight: .semibold),
            alignment: .center
        ) + 8
        y += draw(
            "\(book.year) · aged \(book.child.age)",
            at: y,
            font: .systemFont(ofSize: 18),
            colour: .secondaryLabel,
            alignment: .center
        ) + 42
        if let narrative = book.narrative {
            y += draw(
                narrative,
                at: y,
                font: .italicSystemFont(ofSize: 17),
                colour: .label,
                alignment: .center,
                maxHeight: 310
            )
        }
        _ = draw(
            "MADE WITH HAUSKLAR",
            at: page.height - 72,
            font: .systemFont(ofSize: 9, weight: .medium),
            colour: .secondaryLabel,
            alignment: .center,
            tracking: 1.2
        )
    }

    private static func drawPhotoPage(
        _ book: YearbookDTO,
        images: [String: UIImage],
        context: UIGraphicsPDFRendererContext
    ) {
        context.beginPage()
        _ = draw("Snapshots", at: margin, font: .systemFont(ofSize: 28, weight: .semibold))
        let items = Array(book.sections.photos.highlights.prefix(12))
        drawGrid(
            ids: items.map(\.assetId),
            images: images,
            startY: 104,
            context: context
        )
        _ = draw(
            "\(book.sections.photos.count) chosen moment\(book.sections.photos.count == 1 ? "" : "s") from \(book.year)",
            at: page.height - 62,
            font: .systemFont(ofSize: 10),
            colour: .secondaryLabel,
            alignment: .center
        )
    }

    private static func drawArtworkPage(
        _ book: YearbookDTO,
        images: [String: UIImage],
        context: UIGraphicsPDFRendererContext
    ) {
        context.beginPage()
        _ = draw("Masterpieces", at: margin, font: .systemFont(ofSize: 28, weight: .semibold))
        let items = Array(book.sections.artwork.items.prefix(12))
        drawGrid(ids: items.map(\.id), images: images, startY: 104, context: context)
        let titles = items.compactMap { $0.title?.trimmed.nilIfEmpty }
        if !titles.isEmpty {
            _ = draw(
                titles.joined(separator: " · "),
                at: page.height - 78,
                font: .systemFont(ofSize: 10),
                colour: .secondaryLabel,
                alignment: .center,
                maxHeight: 34
            )
        }
    }

    private static func drawDetailsPage(
        _ book: YearbookDTO,
        context: UIGraphicsPDFRendererContext
    ) {
        context.beginPage()
        var y = margin
        y += draw("The year in detail", at: y, font: .systemFont(ofSize: 28, weight: .semibold)) + 24

        var lines: [(String, String)] = []
        if let growth = book.sections.growth {
            var values: [String] = ["\(growth.measurements) measurements"]
            if let cm = growth.grewCm { values.append("\(yearbookTrim(cm)) cm taller") }
            if let kg = growth.gainedKg { values.append("\(yearbookTrim(kg)) kg gained") }
            lines.append(("How they grew", values.joined(separator: " · ")))
        }
        if !book.sections.adventures.items.isEmpty {
            lines.append((
                "Adventures",
                book.sections.adventures.items.map(\.title).joined(separator: " · ")
            ))
        }
        if book.sections.starCharts.completed > 0 {
            lines.append((
                "Star charts",
                "\(book.sections.starCharts.completed) completed · \(book.sections.starCharts.earnedDisplay) earned"
            ))
        }
        if !book.sections.learning.books.isEmpty {
            lines.append(("Books & learning", book.sections.learning.books.joined(separator: " · ")))
        }
        if !book.sections.favouriteMeals.isEmpty {
            lines.append(("Favourite dinners", book.sections.favouriteMeals.joined(separator: " · ")))
        }
        if book.sections.illnesses.count > 0 {
            lines.append((
                "Poorly days",
                "\(book.sections.illnesses.count) spell\(book.sections.illnesses.count == 1 ? "" : "s") — and better again."
            ))
        }
        if lines.isEmpty {
            lines.append(("A gentle year", "The pages will fill as more moments are kept in HausKlar."))
        }

        for (title, value) in lines {
            y += draw(title, at: y, font: .systemFont(ofSize: 16, weight: .semibold), colour: teal) + 5
            y += draw(value, at: y, font: .systemFont(ofSize: 13), maxHeight: 90) + 22
        }
        _ = draw(
            "\(book.child.name) · \(book.year) · Made with HausKlar",
            at: page.height - 58,
            font: .systemFont(ofSize: 9),
            colour: .secondaryLabel,
            alignment: .center
        )
    }

    private static func drawGrid(
        ids: [String],
        images: [String: UIImage],
        startY: CGFloat,
        context: UIGraphicsPDFRendererContext
    ) {
        let gap: CGFloat = 10
        let width = (page.width - margin * 2 - gap * 2) / 3
        let height: CGFloat = 154
        for (index, id) in ids.enumerated() {
            let column = index % 3
            let row = index / 3
            let rect = CGRect(
                x: margin + CGFloat(column) * (width + gap),
                y: startY + CGFloat(row) * (height + gap),
                width: width,
                height: height
            )
            UIColor.secondarySystemBackground.setFill()
            UIBezierPath(roundedRect: rect, cornerRadius: 7).fill()
            if let image = images[id] {
                context.cgContext.saveGState()
                UIBezierPath(roundedRect: rect, cornerRadius: 7).addClip()
                image.draw(in: aspectFillRect(image.size, inside: rect))
                context.cgContext.restoreGState()
            }
        }
    }

    private static func aspectFillRect(_ size: CGSize, inside rect: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return rect }
        let scale = max(rect.width / size.width, rect.height / size.height)
        let scaled = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(
            x: rect.midX - scaled.width / 2,
            y: rect.midY - scaled.height / 2,
            width: scaled.width,
            height: scaled.height
        )
    }

    @discardableResult
    private static func draw(
        _ text: String,
        at y: CGFloat,
        font: UIFont,
        colour: UIColor = .label,
        alignment: NSTextAlignment = .left,
        tracking: CGFloat = 0,
        maxHeight: CGFloat = .greatestFiniteMagnitude
    ) -> CGFloat {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineSpacing = 4
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: colour,
            .paragraphStyle: paragraph,
            .kern: tracking,
        ]
        let width = page.width - margin * 2
        let measured = (text as NSString).boundingRect(
            with: CGSize(width: width, height: maxHeight),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes,
            context: nil
        )
        let height = min(ceil(measured.height), maxHeight)
        (text as NSString).draw(
            with: CGRect(x: margin, y: y, width: width, height: height),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes,
            context: nil
        )
        return height
    }
}

// MARK: - Helpers

/// Formats a measurement as an integer when whole, otherwise to one decimal place.
private func yearbookTrim(_ value: Double) -> String {
    if value.rounded() == value {
        return String(Int(value))
    }
    return String(format: "%.1f", value)
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

#Preview {
    NavigationStack {
        YearbookView()
    }
}
