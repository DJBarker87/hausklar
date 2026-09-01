import SwiftUI

struct MonthCalendarGrid: View {
    @ObservedObject var viewModel: CalendarViewModel
    let dates: [Date]
    let eventsByDate: [Date: [CalendarEventDTO]]
    let calendar: Calendar
    let onEventSelect: (CalendarEventDTO) -> Void
    let onCoordinationSelect: (Date) -> Void

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.locale) private var locale

    private let columns = Array(
        repeating: GridItem(.flexible(minimum: 40), spacing: 2),
        count: 7
    )

    private static let identifierDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private var showsEventTitles: Bool {
        horizontalSizeClass == .regular && !dynamicTypeSize.isAccessibilitySize
    }

    var body: some View {
        VStack(spacing: 12) {
            monthNavigation
            weekdayHeader

            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(dates, id: \.self) { date in
                    dayButton(for: date)
                }
            }
            .accessibilityIdentifier("calendarMonthGrid")
        }
        .padding(8)
        .background(
            Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 16)
        )
    }

    private var monthNavigation: some View {
        HStack(spacing: 8) {
            Button {
                HapticManager.selection()
                viewModel.moveMonth(by: -1, calendar: calendar)
            } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Previous month")
            .accessibilityIdentifier("calendarPreviousMonth")

            Spacer()

            Text(viewModel.selectedDate, format: .dateTime.month(.wide).year())
                .font(.headline)
                .multilineTextAlignment(.center)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .accessibilityIdentifier("calendarMonthHeading")

            Spacer()

            Button {
                HapticManager.selection()
                viewModel.moveMonth(by: 1, calendar: calendar)
            } label: {
                Image(systemName: "chevron.right")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Next month")
            .accessibilityIdentifier("calendarNextMonth")
        }
    }

    private var weekdayHeader: some View {
        LazyVGrid(columns: columns, spacing: 4) {
            ForEach(
                Array(
                    viewModel.monthWeekdaySymbols(calendar: calendar).enumerated()
                ),
                id: \.offset
            ) { _, symbol in
                Text(symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity)
                    .accessibilityHidden(true)
            }
        }
    }

    private func dayButton(for date: Date) -> some View {
        let dayKey = calendar.startOfDay(for: date)
        let events = eventsByDate[dayKey] ?? []
        let planContext = viewModel.dayPlanItems(on: date, calendar: calendar)
        let isSelected = calendar.isDate(date, inSameDayAs: viewModel.selectedDate)
        let isToday = calendar.isDateInToday(date)
        let isInDisplayedMonth = calendar.isDate(
            date,
            equalTo: viewModel.selectedDate,
            toGranularity: .month
        )

        return VStack(spacing: 4) {
            Button {
                HapticManager.selection()
                viewModel.selectMonthDate(date, calendar: calendar)
            } label: {
                VStack(spacing: 4) {
                    Text(date, format: .dateTime.day())
                        .font(.system(size: 15, weight: isSelected || isToday ? .bold : .regular))
                        .foregroundStyle(isInDisplayedMonth ? Color.primary : Color.secondary)
                        .frame(width: 28, height: 28)
                        .background(
                            isToday ? Color.accentColor.opacity(0.18) : Color.clear,
                            in: Circle()
                        )
                        .overlay {
                            if isToday {
                                Circle()
                                    .stroke(Color.accentColor, lineWidth: 1)
                            }
                        }

                    if !showsEventTitles {
                        compactEventMarkers(
                            events,
                            hasCoordination: planContext.contains {
                                if case .coordination = $0.kind { return true }
                                return false
                            }
                        )
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel(for: date, items: planContext))
            .accessibilityHint("Selects this date and shows its events below")
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .accessibilityIdentifier(
                "calendarMonthDay-\(Self.identifierDateFormatter.string(from: date))"
            )

            if showsEventTitles {
                regularWidthPlanContext(planContext, date: date)
            }

            Spacer(minLength: 0)
        }
        .padding(4)
        .frame(
            maxWidth: .infinity,
            minHeight: showsEventTitles ? 132 : 56,
            alignment: .top
        )
        .background(
            isSelected
                ? Color.accentColor.opacity(0.12)
                : Color(.tertiarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.accentColor, lineWidth: 1.5)
            }
        }
        .opacity(isInDisplayedMonth ? 1 : 0.55)
    }

    private func regularWidthPlanContext(
        _ items: [PlannerDayItem],
        date: Date
    ) -> some View {
        VStack(spacing: 2) {
            ForEach(Array(items.prefix(3).enumerated()), id: \.element.id) { _, item in
                if case .event(let event) = item.kind {
                    Button {
                        HapticManager.selection()
                        onEventSelect(event)
                    } label: {
                        monthContextLabel(item, color: color(for: event))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(event.title)
                    .accessibilityHint("Opens event details")
                } else if case .coordination = item.kind {
                    Button {
                        HapticManager.selection()
                        onCoordinationSelect(date)
                    } label: {
                        monthContextLabel(item, color: .accentColor)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Leave and pickup")
                    .accessibilityHint("Opens the daily coordination plan")
                } else {
                    monthContextLabel(item, color: .secondary)
                }
            }

            if items.count > 3 {
                Text(
                    "+"
                        + String(
                            format: "%lld more".localized,
                            Int64(items.count - 3)
                        )
                )
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private func monthContextLabel(_ item: PlannerDayItem, color: Color) -> some View {
        HStack(spacing: 4) {
            if case .coordination = item.kind {
                Capsule()
                    .fill(Color.accentColor.opacity(0.78))
                    .frame(width: 10, height: 2)
            } else {
                Circle()
                    .fill(color)
                    .frame(width: 4, height: 4)
            }
            Text(item.title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
        .padding(.horizontal, 3)
    }

    private func compactEventMarkers(
        _ events: [CalendarEventDTO],
        hasCoordination: Bool
    ) -> some View {
        HStack(spacing: 2) {
            if hasCoordination {
                Capsule()
                    .fill(Color.accentColor.opacity(0.78))
                    .frame(width: 10, height: 2)
            }
            ForEach(Array(events.prefix(3).enumerated()), id: \.offset) { _, event in
                Circle()
                    .fill(color(for: event))
                    .frame(width: 5, height: 5)
            }

            if events.count > 3 {
                Text("+\(events.count - 3)")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(height: 10)
    }

    private func color(for event: CalendarEventDTO) -> Color {
        event.sourceColor.map(Color.init(hex:)) ?? viewModel.colorForEvent(event)
    }

    private func accessibilityLabel(
        for date: Date,
        items: [PlannerDayItem]
    ) -> String {
        var dateStyle = Date.FormatStyle(
            date: .complete,
            time: .omitted,
            locale: locale
        )
        dateStyle.calendar = calendar
        var parts = [date.formatted(dateStyle)]
        if calendar.isDateInToday(date) {
            parts.append("Today".localized)
        }
        if calendar.isDate(date, inSameDayAs: viewModel.selectedDate) {
            parts.append("Selected".localized)
        }
        if items.isEmpty {
            parts.append("No plans".localized)
        } else {
            let count = Int64(items.count)
            let countKey = count == 1 ? "%lld plan item" : "%lld plan items"
            parts.append(String(format: countKey.localized, count))
            parts.append(items.prefix(3).map(\.title).joined(separator: ", "))
            if count > 3 {
                parts.append(
                    String(format: "%lld more".localized, count - 3)
                )
            }
        }
        return parts.joined(separator: ", ")
    }
}
