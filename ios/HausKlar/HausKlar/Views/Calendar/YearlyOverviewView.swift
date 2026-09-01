import SwiftUI

// MARK: - Yearly Overview View

/// A year-at-a-glance Gantt-style view showing term dates and holidays for each family member.
/// Horizontal strips per person show filled segments (in term) and gaps (holidays),
/// with red dots for manually added days off.
struct YearlyOverviewView: View {
    @ObservedObject var viewModel: CalendarViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // MARK: - People Config (dynamic from API via viewModel)

    /// Build people list from the viewModel's familyMembers.
    private var people: [(id: String, name: String, shortName: String)] {
        viewModel.familyMembers.map { member in
            let short = String(member.name.prefix(3)).uppercased()
            return (member.id, member.name, short)
        }
    }

    private var childIds: Set<String> {
        viewModel.childIds
    }

    private static let termColor = Color.blue
    private static let insetColor = Color.red
    private static let shortLeaveColor = Color.green
    private static let tripColor = Color.yellow

    private static let monthLetters = ["J", "F", "M", "A", "M", "J", "J", "A", "S", "O", "N", "D"]
    private static let monthNames = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    private static let monthFullNames = ["January", "February", "March", "April", "May", "June",
                                          "July", "August", "September", "October", "November", "December"]

    // MARK: - Constants

    private let nameColumnWidth: CGFloat = 40
    private let stripHeight: CGFloat = 22

    // MARK: - Local State

    @State private var showingAddDayOff = false
    @State private var tappedSegment: TappedSegmentInfo?

    // MARK: - Zoom State

    @State private var zoomScale: CGFloat = 1.0
    @State private var lastZoomScale: CGFloat = 1.0
    @State private var scrollToDay: Int?
    private let minZoom: CGFloat = 1.0
    private let maxZoom: CGFloat = 20.0

    // MARK: - Add Day Off Form State

    @State private var dayOffPersonIds: Set<String> = []
    @State private var dayOffAllSelected = false
    @State private var dayOffDate = Date()
    @State private var dayOffHasEndDate = false
    @State private var dayOffEndDate = Date()
    @State private var dayOffReason: DayOffReason = .inset
    @State private var dayOffCustomLabel = ""

    // MARK: - Precomputed Segments

    @State private var segmentsCache: [String: [TermSegment]] = [:]
    @State private var holidayDaysCache: [String: [(dayOfYear: Int, label: String?, id: String)]] = [:]
    @State private var conflictDaysCache: Set<Int> = []

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            yearPicker
                .padding(.vertical, 12)

            Divider()

            colorLegend
                .padding(.vertical, 8)

            Divider()

            zoomControls
                .padding(.vertical, 4)

            Divider()

            chartArea

            Divider()

            addDayOffButton
                .padding(.vertical, 12)
        }
        .onChange(of: viewModel.yearlyTermDates) { recomputeCache() }
        .onChange(of: viewModel.yearlyHolidayDates) { recomputeCache() }
        .onChange(of: viewModel.selectedYear) { recomputeCache() }
        .onAppear { recomputeCache() }
        .sheet(isPresented: $showingAddDayOff) { addDayOffSheet }
        .alert(item: $tappedSegment) { info in
            if let holidayId = info.holidayId {
                Alert(
                    title: Text(LocalizedStringKey(info.title)),
                    message: Text(info.detail),
                    primaryButton: .destructive(Text("Delete")) {
                        Task { await viewModel.deleteHolidayDate(holidayId) }
                    },
                    secondaryButton: .cancel()
                )
            } else {
                Alert(title: Text(LocalizedStringKey(info.title)), message: Text(info.detail), dismissButton: .default(Text("OK")))
            }
        }
    }

    // MARK: - Chart Area

    /// The scrollable chart. One GeometryReader measures the screen width, then
    /// everything inside uses the same `barWidth` derived from that measurement.
    private var chartArea: some View {
        GeometryReader { proxy in
            let screenWidth = proxy.size.width
            let totalContentWidth = screenWidth * zoomScale
            let barWidth = (totalContentWidth - nameColumnWidth - 16) // 8px padding each side
            let totalDays = daysInYear(viewModel.selectedYear)

            ScrollViewReader { scrollProxy in
                ScrollView([.horizontal, .vertical]) {
                    VStack(alignment: .leading, spacing: 0) {
                        // Date header — progressive detail by zoom level
                        datesHeaderRow(barWidth: barWidth)

                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(people, id: \.id) { person in
                                ganttRow(person: person, barWidth: barWidth)
                            }
                        }
                        .padding(.top, 4)

                        monthLabelsRow(barWidth: barWidth)
                            .padding(.top, 8)

                        // Invisible scroll anchor — positioned at today
                        HStack(spacing: 0) {
                            let anchorX = todayAnchorX(barWidth: barWidth, totalDays: totalDays)
                            Color.clear.frame(width: max(anchorX, 0), height: 1)
                            Color.clear.frame(width: 1, height: 1).id("today-anchor")
                            Spacer(minLength: 0)
                        }
                        .frame(height: 1)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 12)
                    .frame(width: totalContentWidth)
                }
                .onChange(of: scrollToDay) {
                    if scrollToDay != nil {
                        if reduceMotion {
                            scrollProxy.scrollTo("today-anchor", anchor: .center)
                        } else {
                            withAnimation(.easeInOut(duration: 0.3)) {
                                scrollProxy.scrollTo("today-anchor", anchor: .center)
                            }
                        }
                        scrollToDay = nil
                    }
                }
            }
            .gesture(
                MagnifyGesture()
                    .onChanged { value in
                        zoomScale = min(max(lastZoomScale * value.magnification, minZoom), maxZoom)
                    }
                    .onEnded { _ in lastZoomScale = zoomScale }
            )
        }
    }

    // MARK: - Gantt Row

    private func ganttRow(person: (id: String, name: String, shortName: String), barWidth: CGFloat) -> some View {
        let totalDays = daysInYear(viewModel.selectedYear)
        let segments = segmentsCache[person.id] ?? []
        let holidayEntries = holidayDaysCache[person.id] ?? []

        return HStack(spacing: 0) {
            // Name label — fixed width
            Text(person.shortName)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: nameColumnWidth, alignment: .leading)

            // Bar area — drawn on a Canvas for pixel-perfect positioning
            Canvas { context, size in
                let w = size.width
                let h = size.height
                let dayWidth = w / CGFloat(totalDays)

                // Background (holiday = light gray)
                let bgRect = CGRect(x: 0, y: 0, width: w, height: h)
                context.fill(RoundedRectangle(cornerRadius: 3).path(in: bgRect), with: .color(Color(.systemGray5)))

                // Term segments — blue
                for segment in segments {
                    let x1 = dayX(segment.startDay, totalDays: totalDays, width: w)
                    let x2 = dayX(segment.endDay + 1, totalDays: totalDays, width: w)
                    let rect = CGRect(x: x1, y: 0, width: x2 - x1, height: h)
                    context.fill(Rectangle().path(in: rect), with: .color(Self.termColor))

                    // Term label when zoomed
                    if zoomScale >= 2.5 && (x2 - x1) > 50 {
                        let text = Text(segment.label ?? "Term")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundColor(.white)
                        context.draw(context.resolve(text), at: CGPoint(x: (x1 + x2) / 2, y: h / 2))
                    }
                }

                // Holiday dates — color by type: red=INSET, green=Short Leave
                for entry in holidayEntries.sorted(by: { $0.dayOfYear < $1.dayOfYear }) {
                    let x = dayX(entry.dayOfYear, totalDays: totalDays, width: w)
                    let markerWidth = max(dayWidth, 2) // at least 2px wide so it's visible
                    let markerRect = CGRect(x: x, y: 0, width: markerWidth, height: h)
                    let markerColor: Color = {
                        guard let label = entry.label?.lowercased() else { return Self.insetColor }
                        if label.contains("short leave") { return Self.shortLeaveColor }
                        if label.hasPrefix("trip") { return Self.tripColor }
                        return Self.insetColor
                    }()
                    context.fill(Rectangle().path(in: markerRect), with: .color(markerColor))
                    // Show trip name at 6x+ zoom
                    if zoomScale >= 6.0, let label = entry.label, label.lowercased().hasPrefix("trip") {
                        let dayWidth = w / CGFloat(totalDays)
                        if dayWidth >= 8 {
                            let displayName = label.hasPrefix("Trip: ") ? String(label.dropFirst(6)) : "Trip"
                            let text = Text(displayName)
                                .font(.system(size: 7, weight: .semibold))
                                .foregroundColor(.black)
                            let x = dayX(entry.dayOfYear, totalDays: totalDays, width: w) + max(dayWidth, 2) / 2
                            context.draw(context.resolve(text), at: CGPoint(x: x, y: h / 2))
                        }
                    }
                }

                // Month grid lines
                for month in 2...12 {
                    let day = dayOfYearForMonthStart(month: month, year: viewModel.selectedYear)
                    let x = dayX(day, totalDays: totalDays, width: w)
                    let lineRect = CGRect(x: x, y: 0, width: 0.5, height: h)
                    context.fill(Rectangle().path(in: lineRect), with: .color(Color(.separator).opacity(0.5)))
                }

                // Day grid lines — show whenever day numbers are visible in the header
                if dayWidth >= 8 {
                    for day in 1...totalDays {
                        let x = dayX(day, totalDays: totalDays, width: w)
                        let weekend = isWeekend(day, year: viewModel.selectedYear)
                        let opacity: Double = weekend ? 0.25 : 0.12
                        let lineWidth: CGFloat = dayWidth >= 14 ? 0.5 : 0.25
                        let lineRect = CGRect(x: x, y: 0, width: lineWidth, height: h)
                        context.fill(Rectangle().path(in: lineRect), with: .color(Color(.separator).opacity(opacity)))
                    }
                }

                // Term boundary lines — always visible so you can see exactly where terms start/end
                for segment in segments {
                    let startX = dayX(segment.startDay, totalDays: totalDays, width: w)
                    let endX = dayX(segment.endDay + 1, totalDays: totalDays, width: w)
                    let boundaryWidth: CGFloat = dayWidth >= 8 ? 1.0 : 0.5
                    let startRect = CGRect(x: startX, y: 0, width: boundaryWidth, height: h)
                    let endRect = CGRect(x: endX - boundaryWidth, y: 0, width: boundaryWidth, height: h)
                    context.fill(Rectangle().path(in: startRect), with: .color(Color.white.opacity(0.6)))
                    context.fill(Rectangle().path(in: endRect), with: .color(Color.white.opacity(0.6)))
                }

                // Today marker
                let calendar = Calendar.current
                let today = Date()
                if calendar.component(.year, from: today) == viewModel.selectedYear {
                    let todayDay = calendar.ordinality(of: .day, in: .year, for: today) ?? 1
                    let tx = dayX(todayDay, totalDays: totalDays, width: w) + dayWidth / 2
                    let todayRect = CGRect(x: tx - 1, y: 0, width: 2, height: h)
                    context.fill(Rectangle().path(in: todayRect), with: .color(.orange))
                }

                // Childcare conflict markers — red "!" on child rows only
                if childIds.contains(person.id) && !conflictDaysCache.isEmpty && zoomScale >= 13.0 {
                    for day in conflictDaysCache.sorted() {
                        let x = dayX(day, totalDays: totalDays, width: w) + dayWidth / 2

                        if dayWidth >= 14 {
                            let text = Text("!")
                                .font(.system(size: 9, weight: .heavy))
                                .foregroundColor(.red)
                            context.draw(context.resolve(text), at: CGPoint(x: x, y: 4))
                        } else {
                            let dotRect = CGRect(x: x - 2, y: 1, width: 4, height: 4)
                            context.fill(Circle().path(in: dotRect), with: .color(.red))
                        }
                    }
                }
            }
            .frame(width: barWidth, height: stripHeight)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .accessibilityElement(children: .contain)
            .accessibilityChildren {
                ForEach(segments, id: \.id) { segment in
                    Text(segment.label ?? "Term")
                        .accessibilityLabel("\(person.name), \(segment.label ?? "Term"), \(formatDateLabel(segment.startDateString)) to \(formatDateLabel(segment.endDateString))")
                }
                ForEach(holidayEntries.sorted(by: { $0.dayOfYear < $1.dayOfYear }), id: \.dayOfYear) { entry in
                    Text(entry.label ?? "Day Off")
                        .accessibilityLabel("\(person.name), \(entry.label ?? "Day Off")")
                }
            }
            .contentShape(Rectangle())
            .gesture(
                SpatialTapGesture()
                    .onEnded { value in
                        let tapX = value.location.x
                        let tappedDay = max(1, Int(tapX / barWidth * CGFloat(totalDays)) + 1)
                        let isConflict = childIds.contains(person.id) && conflictDaysCache.contains(tappedDay)
                        let conflictNote = isConflict ? "\nChildcare needed — both adults working" : ""

                        if let entry = holidayEntries.first(where: { $0.dayOfYear == tappedDay }) {
                            // Holiday/INSET/trip entries take priority (deletable)
                            let displayLabel: String = {
                                guard let label = entry.label else { return "Day Off" }
                                if label.hasPrefix("Trip: ") { return String(label.dropFirst(6)) }
                                return label
                            }()
                            tappedSegment = TappedSegmentInfo(
                                title: entry.label?.lowercased().hasPrefix("trip") == true ? "Trip" : displayLabel,
                                detail: "\(person.name) — \(displayLabel)",
                                holidayId: entry.id
                            )
                        } else if let segment = segments.first(where: { $0.startDay <= tappedDay && $0.endDay >= tappedDay }) {
                            tappedSegment = TappedSegmentInfo(
                                title: isConflict ? "Childcare Needed" : (segment.label ?? "Term"),
                                detail: "\(formatDateLabel(segment.startDateString)) – \(formatDateLabel(segment.endDateString))\(conflictNote)"
                            )
                        } else if segments.isEmpty {
                            tappedSegment = TappedSegmentInfo(title: "No Term Dates", detail: "No term dates set for \(person.name)")
                        } else {
                            tappedSegment = TappedSegmentInfo(title: "Holiday", detail: "\(person.name) — not in term")
                        }
                    }
            )
        }
    }

    // MARK: - Dates Header (Progressive Detail)

    /// Shows date information at the top of the chart, with progressive detail based on zoom:
    /// - < 1.5x: hidden
    /// - 1.5x–7x: boundary markers at term start/end positions
    /// - 7x+: individual day numbers with tick marks
    /// - 12x+: day numbers + weekday letters in a second sub-row
    private func datesHeaderRow(barWidth: CGFloat) -> some View {
        let totalDays = daysInYear(viewModel.selectedYear)
        let dayWidth = barWidth / CGFloat(totalDays)

        let headerHeight: CGFloat = {
            if dayWidth >= 18 { return 28 }  // day + weekday
            if dayWidth >= 8 { return 16 }   // day numbers
            if zoomScale >= 1.5 { return 18 } // boundary markers
            return 0
        }()

        return HStack(spacing: 0) {
            Color.clear.frame(width: nameColumnWidth, height: 1)

            Canvas { context, size in
                let w = size.width
                let h = size.height
                let dw = w / CGFloat(totalDays)

                if dw >= 8 {
                    // Day-level header
                    let showEveryDay = dw >= 14
                    let showWeekday = dw >= 18

                    // Collect term boundary days (start and end) across all people
                    var boundaryDays = Set<Int>()
                    for person in people {
                        for segment in segmentsCache[person.id] ?? [] {
                            boundaryDays.insert(segment.startDay)
                            boundaryDays.insert(segment.endDay)
                        }
                    }

                    for day in 1...totalDays {
                        let (_, dayNum) = dayOfYearToMonthDay(day, year: viewModel.selectedYear)
                        let x = dayX(day, totalDays: totalDays, width: w) + dw / 2
                        let isBoundary = boundaryDays.contains(day)

                        // Skip days when too cramped — but always show boundary days
                        if !showEveryDay && dayNum % 2 == 0 && !isBoundary { continue }

                        // Tick mark
                        let tickRect = CGRect(x: x - 0.25, y: h - 3, width: 0.5, height: isBoundary ? h : 3)
                        context.fill(Rectangle().path(in: tickRect), with: .color(.secondary.opacity(isBoundary ? 0.5 : 0.3)))

                        // Day number — bold for 1st of month and term boundaries
                        let isBold = dayNum == 1 || isBoundary
                        let fontSize: CGFloat = dw >= 14 ? 9 : 7
                        let text = Text("\(dayNum)")
                            .font(.system(size: fontSize, weight: isBold ? .bold : .medium))
                            .foregroundColor(isBold ? .primary : .secondary)
                        let yPos: CGFloat = showWeekday ? 6 : h / 2 - 2
                        context.draw(context.resolve(text), at: CGPoint(x: x, y: yPos))

                        // Weekday letter
                        if showWeekday {
                            let wdLetter = weekdayLetter(day, year: viewModel.selectedYear)
                            let weekend = isWeekend(day, year: viewModel.selectedYear)
                            let wdText = Text(wdLetter)
                                .font(.system(size: 7, weight: .regular))
                                .foregroundColor(weekend ? .red.opacity(0.6) : .secondary.opacity(0.7))
                            context.draw(context.resolve(wdText), at: CGPoint(x: x, y: 18))
                        }
                    }
                } else if zoomScale >= 1.5 {
                    // Boundary markers mode (original behaviour)
                    let boundaries = boundaryMarkers(barWidth: w, totalDays: totalDays)
                    for marker in boundaries {
                        let x = dayX(marker.dayOfYear, totalDays: totalDays, width: w) + dw / 2

                        let tickRect = CGRect(x: x - 0.25, y: h - 4, width: 0.5, height: 4)
                        context.fill(Rectangle().path(in: tickRect), with: .color(.secondary.opacity(0.5)))

                        let label = shortDateLabel(marker.dateString)
                        let fontSize: CGFloat = zoomScale >= 3.0 ? 9 : 7
                        let text = Text(label)
                            .font(.system(size: fontSize, weight: .medium))
                            .foregroundColor(.secondary)
                        context.draw(context.resolve(text), at: CGPoint(x: x, y: h / 2 - 2))
                    }
                }
            }
            .frame(width: barWidth, height: headerHeight)
        }
        .frame(height: headerHeight)
        .clipped()
    }

    /// Collect and deduplicate boundary markers for term start/end positions.
    private func boundaryMarkers(barWidth: CGFloat, totalDays: Int) -> [BoundaryMarker] {
        var boundaries: [BoundaryMarker] = []
        for person in people {
            for segment in segmentsCache[person.id] ?? [] {
                boundaries.append(BoundaryMarker(dayOfYear: segment.startDay, dateString: segment.startDateString, isStart: true))
                boundaries.append(BoundaryMarker(dayOfYear: segment.endDay, dateString: segment.endDateString, isStart: false))
            }
        }

        var seen: Set<Int> = []
        let unique = boundaries.filter { seen.insert($0.dayOfYear).inserted }
            .sorted { $0.dayOfYear < $1.dayOfYear }

        // Filter markers too close together
        guard !unique.isEmpty else { return [] }
        let minPixelGap: CGFloat = 28
        var result: [BoundaryMarker] = [unique[0]]
        for i in 1..<unique.count {
            guard let previous = result.last else { break }
            let prevX = dayX(previous.dayOfYear, totalDays: totalDays, width: barWidth)
            let currX = dayX(unique[i].dayOfYear, totalDays: totalDays, width: barWidth)
            if currX - prevX >= minPixelGap {
                result.append(unique[i])
            }
        }
        return result
    }

    /// Formats "2026-01-06" as "6" or "6 Jan" depending on zoom.
    private func shortDateLabel(_ dateString: String) -> String {
        let parts = dateString.split(separator: "-")
        guard parts.count == 3, let month = Int(parts[1]), let day = Int(parts[2]),
              month >= 1, month <= 12 else { return "" }
        if zoomScale >= 3.0 {
            return "\(day) \(Self.monthNames[month - 1])"
        }
        return "\(day)"
    }

    // MARK: - Month Labels

    private func monthLabelsRow(barWidth: CGFloat) -> some View {
        let totalDays = daysInYear(viewModel.selectedYear)
        let dayWidth = barWidth / CGFloat(totalDays)

        return HStack(spacing: 0) {
            // Match the name column
            Color.clear
                .frame(width: nameColumnWidth, height: 1)

            // Month labels laid out proportionally in an HStack — no offsets needed
            HStack(spacing: 0) {
                ForEach(0..<12, id: \.self) { monthIndex in
                    let month = monthIndex + 1
                    let daysInMonth = self.daysInMonth(month: month, year: viewModel.selectedYear)
                    let monthWidth = barWidth * CGFloat(daysInMonth) / CGFloat(totalDays)

                    let label: String = {
                        if dayWidth >= 14 {
                            return "\(Self.monthFullNames[monthIndex]) \(viewModel.selectedYear)"
                        } else if zoomScale >= 1.8 {
                            return Self.monthNames[monthIndex]
                        } else {
                            return Self.monthLetters[monthIndex]
                        }
                    }()

                    Text(label)
                        .font(.system(size: dayWidth >= 14 ? 11 : 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: monthWidth)
                        .lineLimit(1)
                }
            }
            .frame(width: barWidth)
        }
        .frame(height: 16)
    }

    // MARK: - Year Picker

    private var yearPicker: some View {
        HStack(spacing: 20) {
            Button { viewModel.selectedYear -= 1 } label: {
                Image(systemName: "chevron.left").font(.title3).fontWeight(.semibold)
            }

            Button {
                viewModel.selectedYear = Calendar.current.component(.year, from: Date())
            } label: {
                Text(String(viewModel.selectedYear))
                    .font(.title2).fontWeight(.bold).monospacedDigit()
            }
            .buttonStyle(.plain)

            Button { viewModel.selectedYear += 1 } label: {
                Image(systemName: "chevron.right").font(.title3).fontWeight(.semibold)
            }
        }
    }

    // MARK: - Color Legend

    private var colorLegend: some View {
        HStack(spacing: 12) {
            HStack(spacing: 3) {
                RoundedRectangle(cornerRadius: 2).fill(Self.termColor).frame(width: 14, height: 10)
                Text("Term").font(.caption2).foregroundStyle(.primary)
            }
            HStack(spacing: 3) {
                RoundedRectangle(cornerRadius: 2).fill(Self.insetColor).frame(width: 14, height: 10)
                Text("INSET").font(.caption2).foregroundStyle(.primary)
            }
            HStack(spacing: 3) {
                RoundedRectangle(cornerRadius: 2).fill(Self.shortLeaveColor).frame(width: 14, height: 10)
                Text("Short Leave").font(.caption2).foregroundStyle(.primary)
            }
            HStack(spacing: 3) {
                RoundedRectangle(cornerRadius: 2).fill(Self.tripColor).frame(width: 14, height: 10)
                Text("Trip").font(.caption2).foregroundStyle(.primary)
            }
            HStack(spacing: 3) {
                RoundedRectangle(cornerRadius: 2).fill(Color(.systemGray5)).frame(width: 14, height: 10)
                Text("Holiday").font(.caption2).foregroundStyle(.primary)
            }
            HStack(spacing: 3) {
                RoundedRectangle(cornerRadius: 2).fill(.orange).frame(width: 3, height: 10)
                Text("Today").font(.caption2).foregroundStyle(.primary)
            }
            HStack(spacing: 3) {
                Text("!").font(.system(size: 10, weight: .heavy)).foregroundStyle(.red)
                    .frame(width: 14, height: 10)
                Text("Childcare needed").font(.caption2).foregroundStyle(.primary)
            }
        }
        .padding(.horizontal)
    }

    // MARK: - Zoom Controls

    private var zoomControls: some View {
        HStack(spacing: 8) {
            Button {
                updateZoom {
                    let step: CGFloat = zoomScale > 5 ? 1.0 : 0.5
                    zoomScale = max(zoomScale - step, minZoom)
                    lastZoomScale = zoomScale
                }
            } label: {
                Image(systemName: "minus.magnifyingglass")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Zoom out")
            .disabled(zoomScale <= minZoom)

            Text("\(Int(zoomScale * 100))%")
                .font(.caption).monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 50)

            Button {
                updateZoom {
                    let step: CGFloat = zoomScale >= 5 ? 1.0 : 0.5
                    zoomScale = min(zoomScale + step, maxZoom)
                    lastZoomScale = zoomScale
                }
            } label: {
                Image(systemName: "plus.magnifyingglass")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Zoom in")
            .disabled(zoomScale >= maxZoom)

            Button {
                updateZoom {
                    zoomScale = minZoom
                    lastZoomScale = minZoom
                }
            } label: {
                Text("Reset").font(.caption).frame(minHeight: 44)
            }
            .disabled(zoomScale <= minZoom)

            Button {
                let calendar = Calendar.current
                let today = Date()
                let currentYear = calendar.component(.year, from: today)
                if viewModel.selectedYear != currentYear {
                    viewModel.selectedYear = currentYear
                }
                let todayDay = calendar.ordinality(of: .day, in: .year, for: today) ?? 1
                updateZoom {
                    zoomScale = 10.0
                    lastZoomScale = zoomScale
                }
                // Slight delay so layout updates before scrolling
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    scrollToDay = todayDay
                }
            } label: {
                Text("This Week")
                    .font(.caption)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(minHeight: 44)
            }
        }
    }

    private func updateZoom(_ updates: () -> Void) {
        if reduceMotion {
            updates()
        } else {
            withAnimation(.easeInOut(duration: 0.2), updates)
        }
    }

    // MARK: - Add Day Off Button

    private var addDayOffButton: some View {
        Button {
            resetDayOffForm()
            showingAddDayOff = true
        } label: {
            Label("Add Event", systemImage: "plus")
                .font(.subheadline).fontWeight(.medium)
        }
        .buttonStyle(.borderedProminent)
    }

    // MARK: - Add Day Off Sheet

    private var addDayOffSheet: some View {
        NavigationStack {
            Form {
                Section("Who") { personChips }
                Section("When") {
                    DatePicker("Start Date", selection: $dayOffDate, displayedComponents: .date)
                    Toggle("Multi-day", isOn: $dayOffHasEndDate)
                    if dayOffHasEndDate {
                        DatePicker("End Date", selection: $dayOffEndDate, in: dayOffDate..., displayedComponents: .date)
                    }
                }
                Section("Reason") {
                    Picker("Reason", selection: $dayOffReason) {
                        ForEach(DayOffReason.allCases) { reason in
                            Text(LocalizedStringKey(reason.rawValue)).tag(reason)
                        }
                    }
                    .pickerStyle(.menu)
                    if dayOffReason == .trip {
                        TextField("Trip name (optional)", text: $dayOffCustomLabel)
                    } else if dayOffReason == .other {
                        TextField("Custom label", text: $dayOffCustomLabel)
                    }
                }
            }
            .navigationTitle("Add Day Off")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showingAddDayOff = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await saveDayOff() } }
                        .disabled(dayOffPersonIds.isEmpty)
                }
            }
        }
    }

    // MARK: - Person Chips

    private var personChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chipButton(label: "All", isSelected: dayOffAllSelected, color: .accentColor) {
                    if dayOffAllSelected {
                        dayOffAllSelected = false
                        dayOffPersonIds.removeAll()
                    } else {
                        dayOffAllSelected = true
                        dayOffPersonIds = Set(people.map(\.id))
                    }
                }

                ForEach(people, id: \.id) { person in
                    chipButton(label: person.name, isSelected: dayOffPersonIds.contains(person.id), color: .accentColor) {
                        if dayOffPersonIds.contains(person.id) {
                            dayOffPersonIds.remove(person.id)
                            dayOffAllSelected = false
                        } else {
                            dayOffPersonIds.insert(person.id)
                            if dayOffPersonIds.count == people.count { dayOffAllSelected = true }
                        }
                    }
                }
            }
        }
    }

    private func chipButton(label: String, isSelected: Bool, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.caption).fontWeight(.medium)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(isSelected ? color : Color(.systemGray5))
                .foregroundStyle(isSelected ? .white : .primary)
                .cornerRadius(16)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Save / Reset

    private func saveDayOff() async {
        let label: String? = {
            switch dayOffReason {
            case .trip:
                let name = dayOffCustomLabel.trimmingCharacters(in: .whitespaces)
                return name.isEmpty ? "Trip" : "Trip: \(name)"
            case .other:
                let custom = dayOffCustomLabel.trimmingCharacters(in: .whitespaces)
                return custom.isEmpty ? nil : custom
            default:
                return dayOffReason.rawValue
            }
        }()
        let endDate: Date? = dayOffHasEndDate ? dayOffEndDate : nil
        for personId in dayOffPersonIds {
            await viewModel.createHolidayDate(personId: personId, date: dayOffDate, endDate: endDate, label: label)
        }
        showingAddDayOff = false
    }

    private func resetDayOffForm() {
        dayOffPersonIds = []
        dayOffAllSelected = false
        dayOffDate = Date()
        dayOffHasEndDate = false
        dayOffEndDate = Date()
        dayOffReason = .inset
        dayOffCustomLabel = ""
    }

    // MARK: - Cache Computation

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private func recomputeCache() {
        let calendar = Calendar.current
        let year = viewModel.selectedYear
        let totalDays = daysInYear(year)
        let dateFormatter = Self.dateFormatter

        var newSegments: [String: [TermSegment]] = [:]
        for person in people {
            let personTerms = viewModel.yearlyTermDates.filter { $0.personId == person.id }
            var segments: [TermSegment] = []

            for term in personTerms {
                guard let startDate = dateFormatter.date(from: term.startDate),
                      let endDate = dateFormatter.date(from: term.endDate) else { continue }

                let yearStart = dateFromComponents(year: year, month: 1, day: 1)
                let yearEnd = dateFromComponents(year: year, month: 12, day: 31)
                let clampedStart = max(startDate, yearStart)
                let clampedEnd = min(endDate, yearEnd)
                guard clampedStart <= clampedEnd else { continue }

                let startDay = calendar.ordinality(of: .day, in: .year, for: clampedStart) ?? 1
                let endDay = calendar.ordinality(of: .day, in: .year, for: clampedEnd) ?? totalDays

                segments.append(TermSegment(
                    id: term.id, startDay: startDay, endDay: endDay,
                    startDateString: term.startDate, endDateString: term.endDate, label: term.label
                ))
            }

            segments.sort { $0.startDay < $1.startDay }
            newSegments[person.id] = mergeSegments(segments)
        }
        segmentsCache = newSegments

        var newHolidayDays: [String: [(dayOfYear: Int, label: String?, id: String)]] = [:]
        for person in people {
            let personHolidays = viewModel.yearlyHolidayDates.filter { $0.personId == person.id }
            var entries: [(dayOfYear: Int, label: String?, id: String)] = []
            for holiday in personHolidays {
                guard let date = dateFormatter.date(from: holiday.date) else { continue }
                let holidayYear = calendar.component(.year, from: date)
                guard holidayYear == year else { continue }
                if let dayOfYear = calendar.ordinality(of: .day, in: .year, for: date) {
                    entries.append((dayOfYear: dayOfYear, label: holiday.label, id: holiday.id))
                }
            }
            newHolidayDays[person.id] = entries
        }
        holidayDaysCache = newHolidayDays

        // Compute childcare conflict days:
        // A conflict exists when ANY child is in term AND ALL adults are also in term
        let adults = viewModel.adults
        var adultDaySets: [Set<Int>] = []
        for adult in adults {
            var days = Set<Int>()
            for seg in (newSegments[adult.id] ?? []) {
                for d in seg.startDay...seg.endDay { days.insert(d) }
            }
            adultDaySets.append(days)
        }

        var childDays = Set<Int>()
        for childId in childIds {
            for seg in (newSegments[childId] ?? []) {
                for d in seg.startDay...seg.endDay { childDays.insert(d) }
            }
        }

        var conflicts = childDays
        for adultDays in adultDaySets {
            conflicts = conflicts.intersection(adultDays)
        }
        conflictDaysCache = conflicts
    }

    // MARK: - Segment Merging

    private func mergeSegments(_ segments: [TermSegment]) -> [TermSegment] {
        guard !segments.isEmpty else { return [] }
        var merged: [TermSegment] = [segments[0]]

        for i in 1..<segments.count {
            let current = segments[i]
            let last = merged[merged.count - 1]

            if current.startDay <= last.endDay + 1 {
                let mergedLabel: String? = {
                    if let a = last.label, let b = current.label, a != b { return "\(a) / \(b)" }
                    return last.label ?? current.label
                }()
                merged[merged.count - 1] = TermSegment(
                    id: last.id, startDay: last.startDay,
                    endDay: max(last.endDay, current.endDay),
                    startDateString: last.startDateString,
                    endDateString: current.endDay > last.endDay ? current.endDateString : last.endDateString,
                    label: mergedLabel
                )
            } else {
                merged.append(current)
            }
        }
        return merged
    }

    // MARK: - Helpers

    /// Convert a 1-based day-of-year to an x pixel position.
    private func dayX(_ dayOfYear: Int, totalDays: Int, width: CGFloat) -> CGFloat {
        CGFloat(dayOfYear - 1) / CGFloat(totalDays) * width
    }

    /// Formats "2026-01-06" as "6 Jan".
    private func formatDateLabel(_ dateString: String) -> String {
        let parts = dateString.split(separator: "-")
        guard parts.count == 3, let month = Int(parts[1]), let day = Int(parts[2]),
              month >= 1, month <= 12 else { return dateString }
        return "\(day) \(Self.monthNames[month - 1])"
    }

    private func daysInYear(_ year: Int) -> Int {
        let start = dateFromComponents(year: year, month: 1, day: 1)
        let end = dateFromComponents(year: year + 1, month: 1, day: 1)
        return Calendar.current.dateComponents([.day], from: start, to: end).day ?? 365
    }

    private func daysInMonth(month: Int, year: Int) -> Int {
        var components = DateComponents()
        components.year = year; components.month = month; components.day = 1
        guard let date = Calendar.current.date(from: components),
              let range = Calendar.current.range(of: .day, in: .month, for: date) else { return 30 }
        return range.count
    }

    private func dayOfYearForMonthStart(month: Int, year: Int) -> Int {
        let date = dateFromComponents(year: year, month: month, day: 1)
        return Calendar.current.ordinality(of: .day, in: .year, for: date) ?? 1
    }

    private func dateFromComponents(year: Int, month: Int, day: Int) -> Date {
        var components = DateComponents()
        components.year = year; components.month = month; components.day = day
        return Calendar.current.date(from: components) ?? Date()
    }

    /// Compute the x position for today's anchor within the chart content.
    private func todayAnchorX(barWidth: CGFloat, totalDays: Int) -> CGFloat {
        let calendar = Calendar.current
        let today = Date()
        let todayDay: Int
        if calendar.component(.year, from: today) == viewModel.selectedYear {
            todayDay = calendar.ordinality(of: .day, in: .year, for: today) ?? 1
        } else {
            todayDay = totalDays / 2
        }
        return nameColumnWidth + barWidth * CGFloat(todayDay) / CGFloat(totalDays)
    }

    /// Check if a 1-based day-of-year falls on Saturday or Sunday.
    private func isWeekend(_ dayOfYear: Int, year: Int) -> Bool {
        let jan1 = dateFromComponents(year: year, month: 1, day: 1)
        guard let date = Calendar.current.date(byAdding: .day, value: dayOfYear - 1, to: jan1) else { return false }
        let weekday = Calendar.current.component(.weekday, from: date)
        return weekday == 1 || weekday == 7 // Sunday=1, Saturday=7
    }

    /// Convert a 1-based day-of-year to (month: 1-12, day: 1-31).
    private func dayOfYearToMonthDay(_ dayOfYear: Int, year: Int) -> (month: Int, day: Int) {
        let jan1 = dateFromComponents(year: year, month: 1, day: 1)
        guard let date = Calendar.current.date(byAdding: .day, value: dayOfYear - 1, to: jan1) else { return (1, 1) }
        let month = Calendar.current.component(.month, from: date)
        let day = Calendar.current.component(.day, from: date)
        return (month, day)
    }

    /// Get the weekday letter (M, T, W, T, F, S, S) for a 1-based day-of-year.
    private func weekdayLetter(_ dayOfYear: Int, year: Int) -> String {
        let jan1 = dateFromComponents(year: year, month: 1, day: 1)
        guard let date = Calendar.current.date(byAdding: .day, value: dayOfYear - 1, to: jan1) else { return "" }
        let weekday = Calendar.current.component(.weekday, from: date)
        return ["S", "M", "T", "W", "T", "F", "S"][weekday - 1]
    }
}

// MARK: - Day Off Reasons

enum DayOffReason: String, CaseIterable, Identifiable {
    case inset = "INSET Day"
    case familyHoliday = "Family Holiday"
    case sickDay = "Sick Day"
    case trip = "Trip"
    case other = "Other"

    var id: String { rawValue }
}

// MARK: - Supporting Types

private struct TermSegment: Identifiable {
    let id: String
    let startDay: Int
    let endDay: Int
    let startDateString: String
    let endDateString: String
    let label: String?
}

private struct BoundaryMarker {
    let dayOfYear: Int
    let dateString: String
    let isStart: Bool
}

private struct TappedSegmentInfo: Identifiable {
    let id = UUID()
    let title: String
    let detail: String
    var holidayId: String? = nil
}

#Preview {
    YearlyOverviewView(viewModel: CalendarViewModel())
}
