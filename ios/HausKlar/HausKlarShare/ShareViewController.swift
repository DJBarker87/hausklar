import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    private let statusLabel = UILabel()
    private let openButton = UIButton(type: .system)
    private let cancelButton = UIButton(type: .system)
    private let collection = ShareCollectionState()

    override func viewDidLoad() {
        super.viewDidLoad()
        configureView()
        collectSharedItems()
    }

    private func configureView() {
        view.backgroundColor = .systemBackground
        statusLabel.text = "Preparing for HausKlar…"
        statusLabel.font = .preferredFont(forTextStyle: .headline)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0

        var openConfiguration = UIButton.Configuration.filled()
        openConfiguration.title = "Open HausKlar to review"
        openConfiguration.cornerStyle = .large
        openButton.configuration = openConfiguration
        openButton.isEnabled = false
        openButton.addTarget(self, action: #selector(openHausKlar), for: .touchUpInside)

        cancelButton.setTitle("Cancel", for: .normal)
        cancelButton.addTarget(self, action: #selector(cancel), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [statusLabel, openButton, cancelButton])
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            openButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 48),
            cancelButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
    }

    private func collectSharedItems() {
        let group = DispatchGroup()
        let items = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
        let providers: [NSItemProvider] = items.flatMap { $0.attachments ?? [] }

        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                load(provider, type: .fileURL, group: group)
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                load(provider, type: .image, group: group)
            } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                load(provider, type: .url, group: group)
            } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                load(provider, type: .plainText, group: group)
            }
        }

        group.notify(queue: .main) { [weak self] in self?.finishCollecting() }
    }

    private func load(_ provider: NSItemProvider, type: UTType, group: DispatchGroup) {
        group.enter()
        let collection = collection
        provider.loadItem(forTypeIdentifier: type.identifier, options: nil) { item, error in
            defer { group.leave() }
            if let error {
                collection.recordError(error)
                return
            }
            if let text = item as? String {
                collection.recordText(text)
            } else if let url = item as? URL {
                if type == .url && !url.isFileURL {
                    collection.recordText(url.absoluteString)
                } else if url.pathExtension.lowercased() == "fit" {
                    do {
                        collection.recordFitnessFile(try ShareItemPublisher.copyFITIntoSharedContainer(url))
                    } catch {
                        collection.recordError(error)
                    }
                } else {
                    do {
                        try ShareItemPublisher.publishSharedFile(url, advertisedType: type)
                        collection.recordCapture()
                    } catch {
                        collection.recordError(error)
                    }
                }
            } else if let image = item as? UIImage,
                      let data = image.jpegData(compressionQuality: 0.9) {
                do {
                    try SharedCaptureStore.enqueueFileData(
                        data,
                        originalFilename: "Shared image.jpg",
                        mediaType: "image/jpeg"
                    )
                    collection.recordCapture()
                } catch {
                    collection.recordError(error)
                }
            } else {
                collection.recordError(ShareCollectionError.unsupportedItem)
            }
        }
    }

    private func finishCollecting() {
        let snapshot = collection.snapshot()
        let text = snapshot.sharedText
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        var captureCount = snapshot.sharedCaptureCount
        var captureErrors = snapshot.sharedCaptureErrors
        if !text.isEmpty {
            do {
                try SharedCaptureStore.enqueueText(String(text.prefix(10_000)))
                captureCount += 1
            } catch {
                captureErrors.append(error.localizedDescription)
            }
        }
        guard captureCount > 0 || !snapshot.sharedFitnessFiles.isEmpty else {
            statusLabel.text = captureErrors.first ?? "HausKlar couldn’t read that item."
            return
        }
        let count = captureCount + snapshot.sharedFitnessFiles.count
        if captureErrors.isEmpty {
            statusLabel.text = count == 1 ? "Ready to review in HausKlar" : "\(count) items are ready to review"
        } else {
            statusLabel.text = "\(count) ready; some items couldn’t be added"
        }
        openButton.isEnabled = true
    }

    @objc private func openHausKlar() {
        let destination = collection.snapshot().sharedFitnessFiles.isEmpty
            ? "hausklar://capture"
            : "hausklar://fitness/imports"
        guard let url = URL(string: destination) else { return }
        extensionContext?.open(url) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.extensionContext?.completeRequest(returningItems: nil)
            }
        }
    }

    @objc private func cancel() {
        extensionContext?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
    }
}

private struct ShareCollectionSnapshot: Sendable {
    let sharedText: [String]
    let sharedCaptureCount: Int
    let sharedCaptureErrors: [String]
    let sharedFitnessFiles: [String]
}

/// `NSItemProvider` may invoke different provider callbacks concurrently. Every
/// access to this state is serialized by `lock`; the unchecked conformance only
/// supplies the Sendable declaration that `NSLock`-protected reference types
/// cannot express structurally.
private final class ShareCollectionState: @unchecked Sendable {
    private let lock = NSLock()
    private var sharedText: [String] = []
    private var sharedCaptureCount = 0
    private var sharedCaptureErrors: [String] = []
    private var sharedFitnessFiles: [String] = []

    func recordText(_ text: String) {
        lock.withLock { sharedText.append(text) }
    }

    func recordCapture() {
        lock.withLock { sharedCaptureCount += 1 }
    }

    func recordError(_ error: Error) {
        lock.withLock { sharedCaptureErrors.append(error.localizedDescription) }
    }

    func recordFitnessFile(_ filename: String) {
        lock.withLock { sharedFitnessFiles.append(filename) }
    }

    func snapshot() -> ShareCollectionSnapshot {
        lock.withLock {
            ShareCollectionSnapshot(
                sharedText: sharedText,
                sharedCaptureCount: sharedCaptureCount,
                sharedCaptureErrors: sharedCaptureErrors,
                sharedFitnessFiles: sharedFitnessFiles
            )
        }
    }
}

private enum ShareItemPublisher {
    static func publishSharedFile(_ source: URL, advertisedType: UTType) throws {
        let values = try? source.resourceValues(forKeys: [.contentTypeKey, .nameKey])
        let contentType = values?.contentType
            ?? UTType(filenameExtension: source.pathExtension)
            ?? advertisedType
        try SharedCaptureStore.enqueueFile(
            at: source,
            originalFilename: values?.name ?? source.lastPathComponent,
            mediaType: contentType.preferredMIMEType
        )
    }

    static func copyFITIntoSharedContainer(_ source: URL) throws -> String {
        try FitnessPendingFITInbox.enqueueFIT(
            at: source,
            originalFilename: String(source.lastPathComponent.prefix(240))
        )
    }
}

private enum ShareCollectionError: LocalizedError {
    case unsupportedItem

    var errorDescription: String? {
        "HausKlar couldn’t read that item."
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }
        return body()
    }
}
