import SwiftUI

struct GlobalSearchView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState
    @StateObject private var viewModel = GlobalSearchViewModel()

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.isSearching && viewModel.results.isEmpty {
                    ProgressView("Searching…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = viewModel.errorMessage {
                    ContentUnavailableView {
                        Label("Search didn’t work", systemImage: "magnifyingglass")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Try again") { Task { await viewModel.tryAgain() } }
                            .buttonStyle(.borderedProminent)
                    }
                } else if viewModel.query.trimmingCharacters(in: .whitespacesAndNewlines).count < 2 {
                    ContentUnavailableView {
                        Label("Find anything", systemImage: "magnifyingglass")
                    } description: {
                        Text("Search Calendar, tasks, documents and family records. Search never changes anything.")
                    }
                } else if !viewModel.searchedQuery.isEmpty && viewModel.results.isEmpty {
                    ContentUnavailableView.search(text: viewModel.searchedQuery)
                } else {
                    List(viewModel.results) { result in
                        Button {
                            appState.openSearchResult(result)
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: icon(for: result.kind))
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(.tint)
                                    .frame(width: 38, height: 38)
                                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(result.title)
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(.primary)
                                    if let detail = detail(for: result) {
                                        Text(detail)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 8)
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                                    .accessibilityHidden(true)
                            }
                            .frame(minHeight: 48)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel([result.title, detail(for: result)].compactMap { $0 }.joined(separator: ", "))
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Find anything")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $viewModel.query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Sports day, passport, a person…")
            .task(id: viewModel.query) { await viewModel.search() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
        }
    }

    private func detail(for result: GlobalSearchResultDTO) -> String? {
        let date = result.date.flatMap(searchDateLabel)
        let detail = [result.subtitle, date].compactMap { value in
            guard let value, !value.isEmpty else { return nil }
            return value
        }.joined(separator: " · ")
        return detail.isEmpty ? nil : detail
    }

    private func searchDateLabel(_ value: String) -> String? {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateFormat = value.count == 7 ? "yyyy-MM" : "yyyy-MM-dd"
        guard let date = formatter.date(from: value) else { return value }
        formatter.dateFormat = value.count == 7 ? "MMM yyyy" : "d MMM yyyy"
        return formatter.string(from: date)
    }

    private func icon(for kind: GlobalSearchResultKindDTO) -> String {
        switch kind {
        case .event: "calendar"
        case .task: "checkmark.circle"
        case .document: "doc.text"
        case .person: "person.example_35fbacff.circle"
        case .photo: "photo"
        case .artwork: "paintpalette"
        case .homework: "book"
        case .health: "heart.text.square"
        case .renewal: "arrow.triangle.2.circlepath"
        case .birthday: "birthday.cake"
        }
    }
}
