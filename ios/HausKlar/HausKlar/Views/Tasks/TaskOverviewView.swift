import SwiftUI

/// Overview screen showing each family member's task summary in a grid.
struct TaskOverviewView: View {
    @StateObject private var viewModel = TaskOverviewViewModel()

    private let columns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16),
    ]

    var body: some View {
        Group {
            if viewModel.isLoading && viewModel.people.isEmpty {
                VStack {
                    Spacer()
                    ProgressView("Loading overview...")
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.people.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "person.example_81b06587.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("No task assignments yet")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    if let error = viewModel.errorMessage {
                        Text(error)
                            .foregroundStyle(.red)
                            .font(.subheadline)
                            .padding()
                    }

                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(viewModel.people) { person in
                            NavigationLink {
                                TasksView(
                                    assigneeFilterId: person.personId,
                                    assigneeFilterName: person.personName
                                )
                            } label: {
                                personCard(person)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding()
                }
                .refreshable {
                    await viewModel.loadOverview()
                }
            }
        }
        .navigationTitle("Task Overview")
        .task {
            await viewModel.loadOverview()
        }
    }

    // MARK: - Person Card

    private func personCard(_ person: TaskOverviewPersonDTO) -> some View {
        VStack(spacing: 10) {
            // Avatar initial
            ZStack {
                Circle()
                    .fill(person.personType == "user" ? Color.blue.opacity(0.2) : Color.green.opacity(0.2))
                    .frame(width: 48, height: 48)
                Text(String(person.personName.prefix(1)).uppercased())
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundStyle(person.personType == "user" ? .blue : .green)
            }

            Text(person.personName)
                .font(.headline)
                .lineLimit(1)

            HStack(spacing: 12) {
                statBadge(count: person.totalPending, label: "To Do", color: .orange)
                statBadge(count: person.totalCompletedToday, label: "Done", color: .green)
            }

            if person.overdue > 0 {
                Text("\(person.overdue) overdue")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.red)
                    .clipShape(Capsule())
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func statBadge(count: Int, label: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text("\(count)")
                .font(.title3)
                .fontWeight(.bold)
                .foregroundStyle(color)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    NavigationStack {
        TaskOverviewView()
    }
}
