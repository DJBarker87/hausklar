import SwiftUI

/// The main Routine tab view showing routine items, term dates, and override controls per person.
struct RoutineView: View {
    @StateObject private var viewModel = RoutineViewModel()
    @State private var advancedExpanded = false

    @ScaledMetric(relativeTo: .caption2) private var weekGridFontSize: CGFloat = 10

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Person selector
                personSelector
                    .padding(.vertical, 8)

                Divider()

                if viewModel.isLoading && viewModel.items.isEmpty {
                    loadingView
                } else {
                    ScrollView {
                        VStack(spacing: 16) {
                            setupProgress
                                .padding(.horizontal)

                            // Week grid
                            weekGrid
                                .padding(.horizontal)

                            // Routine items list
                            itemsSection

                            // Term dates list
                            termsSection

                            Text("Weekly activities carry forward automatically between terms. Only add what changed.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal)

                            advancedSection
                                .padding(.horizontal)
                        }
                        .padding(.vertical, 8)
                        .frame(maxWidth: 700)
                        .frame(maxWidth: .infinity)
                    }
                    .refreshable {
                        await viewModel.loadAll()
                    }
                }
            }
            .navigationTitle("Routines")
            .task {
                await viewModel.loadFamilyMembers()
                await viewModel.loadAll()
            }
            .onChange(of: viewModel.selectedPersonId) {
                Task {
                    await viewModel.loadOverride()
                }
            }
            .sheet(isPresented: $viewModel.showingAddItem) {
                RoutineItemFormSheet(viewModel: viewModel, isEditing: false)
            }
            .sheet(item: $viewModel.editingItem) { _ in
                RoutineItemFormSheet(viewModel: viewModel, isEditing: true)
            }
            .sheet(isPresented: $viewModel.showingAddTerm) {
                TermDateFormSheet(viewModel: viewModel, isEditing: false)
            }
            .sheet(item: $viewModel.editingTerm) { _ in
                TermDateFormSheet(viewModel: viewModel, isEditing: true)
            }
            .alert(
                "Routines",
                isPresented: Binding(
                    get: { viewModel.errorMessage != nil },
                    set: { if !$0 { viewModel.errorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) { viewModel.errorMessage = nil }
            } message: {
                Text(viewModel.errorMessage ?? "")
            }
        }
    }

    private var setupProgress: some View {
        HStack(spacing: 8) {
            setupStep(number: 1, title: "Child", detail: viewModel.selectedPersonName, complete: true)
            setupStep(
                number: 2,
                title: "School dates",
                detail: viewModel.termDatesForSelectedPerson.isEmpty
                    ? "Add dates" : "\(viewModel.termDatesForSelectedPerson.count) ranges",
                complete: !viewModel.termDatesForSelectedPerson.isEmpty
            )
            setupStep(
                number: 3,
                title: "Activities",
                detail: viewModel.itemsForSelectedPerson.isEmpty
                    ? "Build week" : "\(viewModel.itemsForSelectedPerson.count) set up",
                complete: !viewModel.itemsForSelectedPerson.isEmpty
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Routine setup progress")
    }

    private func setupStep(
        number: Int,
        title: String,
        detail: String,
        complete: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label("\(number). \(title)", systemImage: complete ? "checkmark.circle.fill" : "circle")
                .font(.caption.weight(.semibold))
                .foregroundStyle(complete ? Color.green : Color.secondary)
                .lineLimit(1)
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Person Selector

    private var personSelector: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(viewModel.people, id: \.id) { person in
                    let isSelected = viewModel.selectedPersonId == person.id
                    Button {
                        viewModel.selectedPersonId = person.id
                    } label: {
                        Text(person.name)
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(isSelected ? Color.accentColor : Color(.systemGray5))
                            .foregroundStyle(isSelected ? .white : .primary)
                            .cornerRadius(20)
                    }
                }
            }
            .padding(.horizontal)
        }
    }

    // MARK: - Override Banner

    private var overrideBanner: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Temporary term status")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                switch viewModel.overrideMode {
                case "force_on":
                    Text("In term")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(.green)
                case "force_off":
                    Text("Holiday")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(.red)
                default:
                    Text("Automatic from term dates")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                }
            }

            Spacer()

            Menu {
                Button("Automatic") {
                    Task { await viewModel.clearOverride() }
                }
                Button("In term temporarily") {
                    Task { await viewModel.setOverride(active: true) }
                }
                Button("Holiday temporarily") {
                    Task { await viewModel.setOverride(active: false) }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
            }
            }

            if viewModel.overrideMode != "auto" {
                DatePicker(
                    "Return to automatic after",
                    selection: $viewModel.overrideExpiresOn,
                    in: Date()...,
                    displayedComponents: .date
                )
                .font(.subheadline)
                Button("Update expiry") {
                    Task { await viewModel.setOverride(active: viewModel.overrideMode == "force_on") }
                }
                .buttonStyle(.bordered)
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(12)
    }

    private var advancedSection: some View {
        DisclosureGroup("Advanced", isExpanded: $advancedExpanded) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Import configured school dates or make a temporary, expiring change to term status.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    Task { await viewModel.refreshSchoolDates() }
                } label: {
                    Label("Import school dates", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.bordered)
                overrideBanner
            }
            .padding(.top, 8)
        }
        .font(.subheadline.weight(.semibold))
    }

    // MARK: - Week Grid

    private var weekGrid: some View {
        let personItems = viewModel.itemsForSelectedPerson
        return VStack(spacing: 4) {
            HStack(spacing: 2) {
                ForEach(0..<7, id: \.self) { day in
                    VStack(spacing: 4) {
                        Text(RoutineViewModel.dayNames[day])
                            .font(.caption2)
                            .fontWeight(.bold)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)

                        let dayItems = personItems.filter { $0.daysOfWeek.contains(day) }
                        if dayItems.isEmpty {
                            Text("--")
                                .font(.caption2)
                                .foregroundStyle(.quaternary)
                                .frame(minHeight: 30)
                        } else {
                            VStack(spacing: 2) {
                                ForEach(dayItems) { item in
                                    Button {
                                        viewModel.populateItemForm(from: item)
                                        viewModel.editingItem = item
                                    } label: {
                                        VStack(spacing: 0) {
                                            if let time = item.timeOfDay {
                                                Text(time)
                                                    .font(.system(size: weekGridFontSize - 1))
                                            }
                                            Text(item.name)
                                                .font(.system(size: weekGridFontSize, weight: .medium))
                                        }
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 3)
                                        .frame(maxWidth: .infinity)
                                        .background(Color(hex: item.color).opacity(0.2))
                                        .foregroundStyle(Color(hex: item.color))
                                        .cornerRadius(8)
                                        .lineLimit(1)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(12)
    }

    // MARK: - Items Section

    private var itemsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Weekly activities")
                    .font(.headline)
                    Text("What happens each week")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    viewModel.resetItemForm()
                    viewModel.showingAddItem = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                }
            }
            .padding(.horizontal)

            if viewModel.itemsForSelectedPerson.isEmpty {
                ContentUnavailableView {
                    Label("No weekly activities", systemImage: "calendar.badge.clock")
                } description: {
                    Text("Add the first routine item for \(viewModel.selectedPersonName).")
                } actions: {
                    Button("Add activity") {
                        viewModel.resetItemForm()
                        viewModel.showingAddItem = true
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.horizontal)
            } else {
                ForEach(viewModel.itemsForSelectedPerson) { item in
                    routineItemRow(item)
                }
            }
        }
    }

    private func routineItemRow(_ item: RoutineItemDTO) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color(hex: item.color))
                .frame(width: 12, height: 12)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text(
                    ([item.timeOfDay, item.location].compactMap { $0 }
                        + [item.daysOfWeek.map { RoutineViewModel.dayNames[$0] }.joined(separator: ", ")])
                        .joined(separator: " · ")
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let preparation = item.preparationNote, !preparation.isEmpty {
                    Text(preparation)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer()

            Button {
                viewModel.populateItemForm(from: item)
                viewModel.editingItem = item
            } label: {
                Image(systemName: "pencil")
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("Edit \(item.name)")

            Menu {
                ForEach(viewModel.people.filter { $0.id != item.personId }, id: \.id) { person in
                    Button("Copy to \(person.name)") {
                        Task { await viewModel.duplicateItem(item, to: person.id) }
                    }
                }
            } label: {
                Image(systemName: "doc.on.doc")
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("Copy \(item.name) to another person")

            Button(role: .destructive) {
                Task { await viewModel.deleteItem(item.id) }
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
            }
            .accessibilityLabel("Delete \(item.name)")
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    // MARK: - Terms Section

    private var termsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("School dates")
                    .font(.headline)
                    Text("School-only activities pause in holidays")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    viewModel.resetTermForm()
                    viewModel.showingAddTerm = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                }
            }
            .padding(.horizontal)

            if viewModel.termDatesForSelectedPerson.isEmpty {
                Text("No term dates yet. Add them here or import configured school dates in Advanced.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            } else {
                ForEach(viewModel.termDatesForSelectedPerson) { term in
                    termRow(term)
                }
            }
        }
    }

    private func termRow(_ term: TermDateDTO) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                if let label = term.label, !label.isEmpty {
                    Text(label)
                        .font(.subheadline)
                        .fontWeight(.medium)
                }
                Text("\(term.startDate) — \(term.endDate)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                viewModel.populateTermForm(from: term)
                viewModel.editingTerm = term
            } label: {
                Image(systemName: "pencil")
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("Edit term \(term.label ?? "\(term.startDate) to \(term.endDate)")")

            Button(role: .destructive) {
                Task { await viewModel.deleteTerm(term.id) }
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
            }
            .accessibilityLabel("Delete term \(term.label ?? "\(term.startDate) to \(term.endDate)")")
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    // MARK: - Loading

    private var loadingView: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView()
                .controlSize(.large)
            Text("Loading routines...")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    RoutineView()
}
