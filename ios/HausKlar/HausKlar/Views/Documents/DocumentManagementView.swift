import SwiftUI
import UIKit

struct DocumentManagementView: View {
    @ObservedObject var viewModel: DocumentsViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var showingEmailCapture = false
    @State private var previewItem: DocumentPreviewItem?

    var body: some View {
        NavigationStack {
            List {
                if let message = viewModel.errorMessage {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                        Button("Try again") {
                            Task { await viewModel.loadManagement() }
                        }
                    }
                }

                Section("Storage") {
                    if let stats = viewModel.stats {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(
                                    ByteCountFormatter.string(
                                        fromByteCount: Int64(stats.storageBytes),
                                        countStyle: .file
                                    )
                                )
                                .fontWeight(.semibold)
                                Spacer()
                                Text("of \(ByteCountFormatter.string(fromByteCount: Int64(stats.storageQuotaBytes), countStyle: .file))")
                                    .foregroundStyle(.secondary)
                            }
                            ProgressView(
                                value: Double(stats.storageBytes),
                                total: Double(max(stats.storageQuotaBytes, 1))
                            )
                            .accessibilityLabel("Document storage used")
                        }
                        .padding(.vertical, 4)
                    } else if viewModel.isLoadingManagement {
                        ProgressView("Loading storage…")
                    } else {
                        Text("Storage details are unavailable.")
                            .foregroundStyle(.secondary)
                    }
                }

                if let address = viewModel.inboxAddress {
                    Section("Email filing") {
                        Button {
                            showingEmailCapture = true
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "envelope.badge")
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Forward family email")
                                    Text(address)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                }

                Section {
                    if viewModel.isLoadingManagement && viewModel.archivedDocuments.isEmpty {
                        ProgressView("Loading archive…")
                    } else if viewModel.archivedDocuments.isEmpty && viewModel.errorMessage == nil {
                        Text("No archived documents")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(viewModel.archivedDocuments) { document in
                            NavigationLink {
                                DocumentDetailView(document: document, viewModel: viewModel) { url in
                                    previewItem = DocumentPreviewItem(url: url, title: document.title)
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(document.title)
                                        .font(.subheadline.weight(.semibold))
                                    Text(archiveSubtitle(document))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .frame(minHeight: 44, alignment: .leading)
                            }
                            .swipeActions {
                                Button {
                                    Task { _ = await viewModel.restoreDocument(document) }
                                } label: {
                                    Label("Restore", systemImage: "arrow.uturn.backward")
                                }
                                .tint(.blue)
                            }
                        }
                        if viewModel.canLoadMoreArchive {
                            Button {
                                Task { await viewModel.loadMoreArchive() }
                            } label: {
                                if viewModel.isLoadingMore { ProgressView() } else { Text("Load more archive") }
                            }
                            .disabled(viewModel.isLoadingMore)
                        }
                    }
                } header: {
                    Text("Archive")
                } footer: {
                    Text("Open an old file or swipe it to restore it to Filed.")
                }

                Section {
                    Text("Family documents are shared with the household. Adult-only financial files belong in Private Finance.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Manage Documents")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await viewModel.loadManagement() }
            .sheet(isPresented: $showingEmailCapture) {
                if let address = viewModel.inboxAddress {
                    EmailCaptureView(address: address)
                }
            }
            .sheet(item: $previewItem) { item in
                DocumentPreviewSheet(item: item)
                    .onDisappear { viewModel.removePreview(at: item.url) }
            }
        }
    }

    private func archiveSubtitle(_ document: DocumentDTO) -> String {
        let date = document.documentDate ?? document.createdAt
        let dateLabel =
            ISODateParser.parse(date)?.formatted(date: .abbreviated, time: .omitted)
            ?? String(date.prefix(10))
        let people = document.people.map(\.personName).joined(separator: ", ")
        return [dateLabel, people.isEmpty ? "Whole family" : people].joined(separator: " · ")
    }
}

private struct EmailCaptureView: View {
    let address: String

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Family inbox") {
                    Text(address)
                        .font(.body.monospaced())
                        .textSelection(.enabled)

                    Button {
                        UIPasteboard.general.string = address
                        HapticManager.success()
                    } label: {
                        Label("Copy Address", systemImage: "doc.on.doc")
                    }

                    ShareLink(item: address) {
                        Label("Share Address", systemImage: "square.and.arrow.up")
                    }
                }

                Section {
                    Label("Family account senders only", systemImage: "lock.example_9ab66176")
                    Label("Attachments arrive in the capture inbox", systemImage: "tray.and.arrow.down")
                }
                .foregroundStyle(.secondary)
            }
            .navigationTitle("Email Capture")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
