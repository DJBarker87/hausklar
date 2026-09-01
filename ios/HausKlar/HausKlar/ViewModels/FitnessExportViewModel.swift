import Foundation

@MainActor
final class FitnessExportViewModel: FitnessViewModelBase {
    @Published var shareURL: URL?
    private let service: FitnessExportService

    init(service: FitnessExportService = .shared) { self.service=service }

    func export() async {
        if let shareURL { await service.cleanup(shareURL) }
        shareURL=nil
        await run { self.shareURL=try await self.service.createExport() }
    }

    func cleanup() {
        guard let shareURL else { return }
        self.shareURL=nil
        Task { await service.cleanup(shareURL) }
    }
}
