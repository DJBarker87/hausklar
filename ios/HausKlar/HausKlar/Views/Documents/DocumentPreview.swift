import QuickLook
import SwiftUI

struct DocumentPreviewItem: Identifiable {
    let url: URL
    let title: String
    var id: String { url.path }
}

/// Quick Look hosted inside a SwiftUI navigation bar so a visible Done control
/// is always available, including for PDFs whose own chrome is hidden.
struct DocumentPreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let item: DocumentPreviewItem

    var body: some View {
        NavigationStack {
            QuickLookPreview(url: item.url)
                .navigationTitle(item.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                            .accessibilityIdentifier("documentPreviewDone")
                    }
                }
        }
    }
}

struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: QLPreviewController, context: Context) {}

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}
