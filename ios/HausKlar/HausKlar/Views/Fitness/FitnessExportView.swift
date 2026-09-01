import SwiftUI

struct FitnessExportView: View {
    @StateObject private var viewModel=FitnessExportViewModel()

    var body: some View {
        List {
            Section {
                Text("Download a portable ZIP of the Fitness records owned by your account.")
                    .foregroundStyle(.secondary)
                Button {
                    Task { await viewModel.export() }
                } label: {
                    if viewModel.isLoading {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Preparing export…")
                        }
                    } else {
                        Label("Prepare Fitness export",systemImage: "square.and.arrow.down")
                    }
                }
                .frame(minHeight: 44)
                .disabled(viewModel.isLoading)
                if let url=viewModel.shareURL {
                    Label("Export ready",systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    ShareLink(item: url) {
                        Label("Share \(url.lastPathComponent)",systemImage: "square.and.arrow.up")
                    }
                    .frame(minHeight: 44)
                }
                if let error=viewModel.errorMessage {
                    Label(error,systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            } footer: {
                Text("The authenticated download is streamed to a temporary file and removed when you leave this screen.")
            }
        }
        .navigationTitle("Export Fitness data")
        .onDisappear { viewModel.cleanup() }
    }
}
