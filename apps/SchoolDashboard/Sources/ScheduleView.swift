import SwiftUI

/// A real week timetable, drawn from the same dated class occurrences the sync
/// puts on the UAH calendar — so the app and the calendar can never disagree.
struct ScheduleView: View {
    let snapshot: Snapshot
    @State private var anchor: Date

    private let calendar = Calendar.current

    /// Open on the current week during term, and on the first week of classes
    /// outside it. Landing on a blank grid over the summer makes the app look
    /// broken when it is simply not term time yet.
    init(snapshot: Snapshot) {
        self.snapshot = snapshot
        let now = Date()
        let firstClass = snapshot.classes
            .compactMap(\.start)
            .min() ?? now
        let lastClass = snapshot.classes
            .compactMap(\.start)
            .max() ?? now
        _anchor = State(initialValue: now < firstClass ? firstClass
                                    : (now > lastClass ? lastClass : now))
    }

    /// Monday of the displayed week.
    private var weekStart: Date {
        let start = calendar.date(from: calendar.dateComponents(
            [.yearForWeekOfYear, .weekOfYear], from: anchor)) ?? anchor
        // Calendar week starts on Sunday in en_US; classes run Mon–Fri.
        return calendar.component(.weekday, from: start) == 1
            ? (calendar.date(byAdding: .day, value: 1, to: start) ?? start)
            : start
    }

    private var days: [Date] {
        (0..<5).compactMap { calendar.date(byAdding: .day, value: $0, to: weekStart) }
    }

    private var weekMeetings: [ClassMeeting] {
        guard let end = calendar.date(byAdding: .day, value: 5, to: weekStart) else { return [] }
        return snapshot.classes.filter { m in
            guard let s = m.start else { return false }
            return s >= weekStart && s < end
        }
    }

    /// Hour range that actually contains classes, padded by one hour each side.
    private var hourRange: ClosedRange<Int> {
        let starts = weekMeetings.compactMap { $0.start.map { calendar.component(.hour, from: $0) } }
        let ends = weekMeetings.compactMap { m -> Int? in
            guard let f = m.finish else { return nil }
            let h = calendar.component(.hour, from: f)
            return calendar.component(.minute, from: f) > 0 ? h + 1 : h
        }
        guard let low = starts.min(), let high = ends.max() else { return 8...17 }
        return max(6, low - 1)...min(22, max(high + 1, low + 3))
    }

    private let hourHeight: CGFloat = 46

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if weekMeetings.isEmpty {
                Card(flat: true) {
                    EmptyNote(symbol: "calendar",
                              title: "No classes this week",
                              detail: emptyDetail)
                }
                .padding(18)
                Spacer()
            } else {
                ScrollView {
                    grid.padding(18)
                }
            }
        }
    }

    private var emptyDetail: String {
        if let start = snapshot.term.startDate, weekStart < start {
            return "\(snapshot.term.name) classes begin \(Format.mediumDate.string(from: start))."
        }
        if snapshot.term.breaks.contains(where: { raw in
            guard let day = SchoolDate.day(raw) else { return false }
            return days.contains { calendar.isDate($0, inSameDayAs: day) }
        }) {
            return "This week falls on a scheduled break."
        }
        return "Nothing on the timetable for these five days."
    }

    private var header: some View {
        HStack(spacing: 10) {
            SectionHeader(title: "Week of \(Format.mediumDate.string(from: weekStart))",
                          subtitle: "\(weekMeetings.count) class meetings",
                          symbol: "calendar",
                          color: Color(red: 0.13, green: 0.58, blue: 0.52))
            Spacer()
            Button("Today") { anchor = Date() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .focusEffectDisabled()
            HStack(spacing: 4) {
                Button {
                    anchor = calendar.date(byAdding: .day, value: -7, to: weekStart) ?? weekStart
                } label: { Image(systemName: "chevron.left") }
                Button {
                    anchor = calendar.date(byAdding: .day, value: 7, to: weekStart) ?? weekStart
                } label: { Image(systemName: "chevron.right") }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .focusEffectDisabled()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
    }

    private var grid: some View {
        let hours = Array(hourRange)
        return VStack(spacing: 0) {
            // Day headings
            HStack(spacing: 6) {
                Color.clear.frame(width: 52)
                ForEach(days, id: \.self) { day in
                    let isToday = calendar.isDateInToday(day)
                    VStack(spacing: 1) {
                        Text(Format.weekday.string(from: day).prefix(3).uppercased())
                            .font(.system(size: 9.5, weight: .bold))
                            .kerning(0.6)
                            .foregroundStyle(isToday ? SchoolTheme.accent : .secondary)
                        Text("\(calendar.component(.day, from: day))")
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundStyle(isToday ? SchoolTheme.accent : .primary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: SchoolTheme.rowRadius, style: .continuous)
                        .fill(isToday ? SchoolTheme.accent.opacity(0.12) : Color.clear))
                }
            }
            .padding(.bottom, 8)

            // Hour rows + positioned class blocks
            HStack(alignment: .top, spacing: 6) {
                VStack(spacing: 0) {
                    ForEach(hours, id: \.self) { hour in
                        Text(Format.clock(hour * 60))
                            .font(.system(size: 9.5, weight: .medium, design: .rounded))
                            .foregroundStyle(.tertiary)
                            .frame(height: hourHeight, alignment: .top)
                            .offset(y: -5)
                    }
                }
                .frame(width: 52, alignment: .trailing)

                ForEach(days, id: \.self) { day in
                    dayColumn(day: day, hours: hours)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func dayColumn(day: Date, hours: [Int]) -> some View {
        let meetings = snapshot.classes(on: day)
        let top = CGFloat(hours.first ?? 8) * 60
        return ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                ForEach(hours, id: \.self) { _ in
                    Divider().frame(height: 1)
                    Spacer(minLength: 0).frame(height: hourHeight - 1)
                }
            }
            ForEach(meetings) { meeting in
                if let start = meeting.start, let finish = meeting.finish {
                    let startMinutes = CGFloat(calendar.component(.hour, from: start) * 60
                                               + calendar.component(.minute, from: start))
                    let duration = max(CGFloat(finish.timeIntervalSince(start) / 60), 30)
                    ClassBlock(meeting: meeting,
                               color: Palette.color(for: meeting.code, in: snapshot.courses),
                               compact: duration < 55)
                        .frame(height: duration / 60 * hourHeight - 3)
                        .offset(y: (startMinutes - top) / 60 * hourHeight)
                }
            }
        }
        .frame(height: CGFloat(hours.count) * hourHeight, alignment: .top)
        .clipped()
    }
}

struct ClassBlock: View {
    let meeting: ClassMeeting
    let color: Color
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 0 : 2) {
            Text(meeting.code ?? meeting.title)
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(color)
                .lineLimit(1)
            if !compact {
                Text(meeting.title)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let location = meeting.location {
                Text(location)
                    .font(.system(size: 9))
                    // .secondary, not .tertiary: tertiary text over the tinted
                    // block is too faint to read in light appearance.
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(color.opacity(0.15)))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(color)
                .frame(width: 2.5)
                .padding(.vertical, 2)
        }
        .help(helpText)
    }

    private var helpText: String {
        var parts = [meeting.title]
        if let s = meeting.start, let f = meeting.finish {
            parts.append("\(Format.time.string(from: s)) – \(Format.time.string(from: f))")
        }
        if let location = meeting.location { parts.append(location) }
        return parts.joined(separator: "\n")
    }
}
