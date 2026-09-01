import SwiftUI

struct CommitmentsHubView: View {
    @ObservedObject var viewModel: CommitmentsViewModel
    let currentUserId: String?
    let fallbackMembers: [FamilyMemberDTO]

    @Environment(\.dismiss) private var dismiss
    @State private var createKind: CommitmentKind?
    @State private var choosingWorkflow = false

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.draft != nil {
                    CommitmentReviewView(viewModel: viewModel)
                } else if let createKind {
                    CommitmentCreateView(
                        kind: createKind,
                        viewModel: viewModel,
                        onBack: { self.createKind = nil },
                        onQueued: { self.createKind = nil }
                    )
                } else if choosingWorkflow {
                    workflowChooser
                } else {
                    plansList
                }
            }
            .navigationTitle("Plans to sort")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .disabled(viewModel.busyAction != nil)
                }
                if viewModel.draft == nil, createKind == nil, !choosingWorkflow {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            HapticManager.selection()
                            choosingWorkflow = true
                        } label: {
                            Label("New plan", systemImage: "plus")
                        }
                        .accessibilityIdentifier("commitmentsNewPlan")
                    }
                }
            }
        }
        .interactiveDismissDisabled(viewModel.busyAction != nil)
        .task {
            viewModel.configure(currentUserId: currentUserId)
            await viewModel.loadHub(fallbackMembers: fallbackMembers)
        }
        .accessibilityIdentifier("commitmentsHub")
    }

    private var plansList: some View {
        List {
            if let notice = viewModel.notice {
                Section {
                    Label(notice, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .accessibilityIdentifier("commitmentsNotice")
                }
            }

            if viewModel.isFromCache {
                Section {
                    Label(
                        "Saved plans shown while offline",
                        systemImage: "wifi.slash"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            Section {
                if viewModel.isLoading, viewModel.items.isEmpty {
                    ForEach(0..<4, id: \.self) { _ in
                        planPlaceholder
                    }
                } else if let error = viewModel.errorMessage, viewModel.items.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Button("Try again") {
                            Task { await viewModel.loadPending(refresh: true) }
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.vertical, 8)
                } else if viewModel.items.isEmpty {
                    ContentUnavailableView {
                        Label("You’re all sorted", systemImage: "checkmark.circle")
                    } description: {
                        Text("School messages, invitations, bookings and gaps will wait here for review.")
                    } actions: {
                        Button("Start a plan") { choosingWorkflow = true }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    ForEach(viewModel.items) { item in
                        Button {
                            HapticManager.selection()
                            viewModel.select(item)
                        } label: {
                            CommitmentPlanRow(commitment: item)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("commitmentRow-\(item.id)")
                    }
                }
            } header: {
                Text(waitingTitle)
            } footer: {
                if !viewModel.items.isEmpty {
                    Text("The most urgent plan is first. Nothing reaches Calendar or Tasks until you confirm it.")
                }
            }
        }
        .refreshable { await viewModel.loadPending(refresh: true) }
    }

    private var workflowChooser: some View {
        List {
            Section {
                Button {
                    choosingWorkflow = false
                } label: {
                    Label("Plans to sort", systemImage: "chevron.left")
                        .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
            }

            Section {
                ForEach(CommitmentKind.allCases) { kind in
                    Button {
                        HapticManager.selection()
                        createKind = kind
                        choosingWorkflow = false
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: kind.symbol)
                                .foregroundStyle(.tint)
                                .frame(width: 34, height: 34)
                                .background(Color.accentColor.opacity(0.1), in: Circle())
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(kind.title)
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                Text(kind.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                        }
                        .frame(minHeight: 56)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("commitmentWorkflow-\(kind.rawValue)")
                }
            } header: {
                Text("What are you sorting out?")
            } footer: {
                Text("HausKlar keeps the dates, actions and preparation together in one reviewed plan.")
            }
        }
        .accessibilityIdentifier("commitmentWorkflowChooser")
    }

    private var planPlaceholder: some View {
        HStack(spacing: 12) {
            Circle().fill(.secondary.opacity(0.18)).frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 6) {
                Text("A plan title that is loading")
                Text("Type · Date")
                    .font(.caption)
            }
        }
        .redacted(reason: .placeholder)
        .accessibilityLabel("Loading plans")
    }

    private var waitingTitle: String {
        let count = viewModel.items.count
        if viewModel.isLoading, count == 0 { return "Plans".localized }
        return count == 1
            ? "1 plan waiting".localized
            : String(format: "%lld plans waiting".localized, Int64(count))
    }
}

private struct CommitmentPlanRow: View {
    let commitment: Commitment

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: commitment.kind.symbol)
                .foregroundStyle(.tint)
                .frame(width: 38, height: 38)
                .background(Color.accentColor.opacity(0.1), in: Circle())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(commitment.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 6)

            VStack(alignment: .trailing, spacing: 5) {
                Text(status)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(commitment.reviewIssues.isEmpty ? Color.secondary : Color.orange)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: 56)
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        let visibility = commitment.visibility == .owner ? "Just me".localized : "Family".localized
        return "\(commitment.kind.title) · \(dueText) · \(visibility)"
    }

    private var dueText: String {
        guard let urgency = commitment.temporalUrgency else { return "No date yet".localized }
        return urgency.formatted(locale: .hausKlarSelected)
    }

    private var status: String {
        if !commitment.reviewIssues.isEmpty {
            return commitment.reviewIssues.count == 1
                ? "1 to check".localized
                : String(format: "%lld to check".localized, Int64(commitment.reviewIssues.count))
        }
        if commitment.externalActionStatus == .pending { return "Outside step".localized }
        return "Ready".localized
    }
}
