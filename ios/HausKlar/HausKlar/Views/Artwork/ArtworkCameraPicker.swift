import SwiftUI
import UIKit
import VisionKit

/// UIKit and VisionKit document that these UI delegate callbacks arrive on the
/// main thread. `MainActor.assumeIsolated` executes synchronously, so the value
/// never escapes that callback; this wrapper only teaches strict concurrency
/// about that framework-owned threading guarantee.
private struct MainThreadCallbackValue<Value>: @unchecked Sendable {
    let value: Value
}

/// Simple camera capture for artwork photos. Downsampling happens at upload time.
struct ArtworkCameraPicker: UIViewControllerRepresentable {
    let onCapture: (UIImage) -> Void

    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let controller = UIImagePickerController()
        controller.sourceType = .camera
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    @MainActor
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let parent: ArtworkCameraPicker

        init(_ parent: ArtworkCameraPicker) {
            self.parent = parent
        }

        nonisolated func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            // UIImagePickerController delivers delegate callbacks on the main
            // thread. Keep the non-Sendable UIImage on that thread rather than
            // transferring it through an unstructured task.
            let callback = MainThreadCallbackValue(value: info)
            MainActor.assumeIsolated {
                if let image = callback.value[.originalImage] as? UIImage {
                    parent.onCapture(image)
                }
                parent.dismiss()
            }
        }

        nonisolated func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            MainActor.assumeIsolated {
                parent.dismiss()
            }
        }
    }
}

/// Apple's document camera finds the paper edges, straightens the page and can
/// capture several drawings in one pass. The original scan is still retained by
/// the server, so later light/rotation changes never destroy it.
struct ArtworkPileScanner: UIViewControllerRepresentable {
    let onCapture: ([UIImage]) -> Void

    @Environment(\.dismiss) private var dismiss

    static var isSupported: Bool { VNDocumentCameraViewController.isSupported }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        private let parent: ArtworkPileScanner

        init(_ parent: ArtworkPileScanner) { self.parent = parent }

        nonisolated func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFinishWith scan: VNDocumentCameraScan
        ) {
            // VisionKit likewise invokes its UI delegate on the main thread;
            // extract and deliver UIImage pages synchronously on MainActor.
            let callback = MainThreadCallbackValue(value: scan)
            MainActor.assumeIsolated {
                parent.onCapture(
                    (0..<callback.value.pageCount).map(callback.value.imageOfPage(at:))
                )
                parent.dismiss()
            }
        }

        nonisolated func documentCameraViewControllerDidCancel(
            _ controller: VNDocumentCameraViewController
        ) {
            MainActor.assumeIsolated {
                parent.dismiss()
            }
        }

        nonisolated func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFailWithError error: Error
        ) {
            MainActor.assumeIsolated {
                parent.dismiss()
            }
        }
    }
}
