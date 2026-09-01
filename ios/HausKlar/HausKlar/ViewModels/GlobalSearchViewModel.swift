import Foundation

@MainActor
final class GlobalSearchViewModel: ObservableObject {
    @Published var query = ""
    @Published private(set) var results: [GlobalSearchResultDTO] = []
    @Published private(set) var isSearching = false
    @Published private(set) var searchedQuery = ""
    @Published var errorMessage: String?

    private var requestGeneration = 0

    func search() async {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        requestGeneration += 1
        let generation = requestGeneration
        guard term.count >= 2 else {
            results = []
            searchedQuery = ""
            errorMessage = nil
            isSearching = false
            return
        }

        do {
            try await Task.sleep(for: .milliseconds(250))
            try Task.checkCancellation()
            isSearching = true
            errorMessage = nil
            let response: GlobalSearchResponseDTO = try await APIClient.shared.get(
                "/search",
                queryItems: [
                    URLQueryItem(name: "q", value: term),
                    URLQueryItem(name: "limit", value: "40")
                ],
                bypassCache: true
            )
            guard generation == requestGeneration, !Task.isCancelled else { return }
            results = response.results
            searchedQuery = response.query
        } catch is CancellationError {
            return
        } catch {
            guard generation == requestGeneration, !Task.isCancelled else { return }
            results = []
            searchedQuery = term
            errorMessage = (error as? APIError)?.errorDescription ?? "Search is unavailable just now."
        }
        if generation == requestGeneration { isSearching = false }
    }

    func tryAgain() async {
        requestGeneration += 1
        await search()
    }
}
