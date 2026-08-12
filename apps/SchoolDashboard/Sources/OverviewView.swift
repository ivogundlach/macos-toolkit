import SwiftUI

/// The landing page: a little of everything, and enough of it to answer "what
/// do I need to do right now" without opening another tab.
struct OverviewView: View {
    @ObservedObject var model: SchoolModel
    let snapshot: Snapshot
    @Binding var tab: Tab

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let error = model.refreshError {
                    Banner(symbol: "exclamationmark.triangle.fill",
                           title: "The last refresh did not work",
                           detail: error, color: HealthColor.warn)
                } else if snapshot.isStale {
                    Banner(symbol: "clock.arrow.circlepath",
                           title: "This data is a few hours old",
                           detail: "The hourly background sync has not run recently. Refreshing now pulls straight from Canvas.",
                           color: HealthColor.warn,
                           actionLabel: "Refresh", action: model.refresh)
                }

                statRow
                HStack(alignment: .top, spacing: 14) {
                    todayCard.frame(maxWidth: .infinity)
                    dueCard.frame(maxWidth: .infinity)
                }
                coursesCard
            }
            .padding(18)
        }
    }

    // MARK: Hero row

    private var statRow: some View {
        HStack(spacing: 14) {
            Card { nextClassTile }
            Card { dueNextTile }
            Card { termTile }
        }
    }

    private var nextClassTile: some View {
        Group {
            if let current = snapshot.currentClass {
                StatTile(value: current.code ?? current.title,
                         label: "In class now",
                         caption: [current.title, current.location].compactMap { $0 }.joined(separator: " · "),
                         symbol: "record.circle",
                         color: HealthColor.ok)
            } else if let next = snapshot.nextClass, let start = next.start {
                StatTile(value: Format.time.string(from: start),
                         label: "Next class",
                         caption: "\(next.code ?? next.title) · \(Format.due(start, allDay: false).replacingOccurrences(of: " at \(Format.time.string(from: start))", with: ""))"
                            + (next.location.map { " · \($0)" } ?? ""),
                         symbol: "clock.fill",
                         color: SchoolTheme.accent)
            } else {
                StatTile(value: "—", label: "Next class",
                         caption: snapshot.classes.isEmpty
                            ? "No class schedule imported yet."
                            : "No more classes this term.",
                         symbol: "clock.fill", color: SchoolTheme.accent)
            }
        }
    }

    private var dueNextTile: some View {
        Group {
            if let next = snapshot.openAssignments.first {
                StatTile(value: next.due.map { Format.due($0, allDay: next.all_day) } ?? "No date",
                         label: snapshot.overdue.isEmpty ? "Due next" : "\(snapshot.overdue.count) overdue",
                         caption: [next.course_code, next.title].compactMap { $0 }.joined(separator: " · "),
                         symbol: "checklist",
                         color: snapshot.overdue.isEmpty
                            ? Color(red: 0.80, green: 0.47, blue: 0.14) : HealthColor.fail)
            } else {
                StatTile(value: "Nothing due",
                         label: "Assignments",
                         caption: snapshot.health.feed.ok
                            ? "Canvas has no open work for you right now."
                            : "Canvas could not be reached, so this may be incomplete.",
                         symbol: "checklist",
                         color: Color(red: 0.80, green: 0.47, blue: 0.14))
            }
        }
    }

    private var termTile: some View {
        Group {
            if let days = snapshot.daysUntilTerm {
                StatTile(value: "\(days) days",
                         label: "Until classes start",
                         caption: snapshot.term.startDate.map {
                            "\(snapshot.term.name) begins \(Format.mediumDate.string(from: $0))"
                         },
                         symbol: "calendar",
                         color: Color(red: 0.13, green: 0.58, blue: 0.52))
            } else if let progress = snapshot.termProgress {
                StatTile(value: "\(Int(progress * 100))%",
                         label: "Through the term",
                         caption: snapshot.term.endDate.map {
                            "Classes end \(Format.mediumDate.string(from: $0))"
                         },
                         symbol: "calendar",
                         color: Color(red: 0.13, green: 0.58, blue: 0.52))
            } else {
                StatTile(value: "\(snapshot.totalCredits)",
                         label: "Credit hours",
                         caption: "\(snapshot.courses.count) courses this term",
                         symbol: "calendar",
                         color: Color(red: 0.13, green: 0.58, blue: 0.52))
            }
        }
    }

    // MARK: Today

    private var todayCard: some View {
        Card(flat: true) {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Today", subtitle: Format.weekday.string(from: Date()),
                              symbol: "sun.max.fill",
                              color: Color(red: 0.13, green: 0.58, blue: 0.52)) {
                    Button("Schedule") { tab = .schedule }
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                        .focusEffectDisabled()
                }
                let today = snapshot.today
                if today.isEmpty {
                    EmptyNote(symbol: "cup.and.saucer",
                              title: "No classes today",
                              detail: snapshot.daysUntilTerm != nil
                                ? "The semester has not started yet."
                                : "Nothing on the timetable for today.")
                } else {
                    VStack(spacing: 0) {
                        ForEach(today) { meeting in
                            ClassRow(meeting: meeting, courses: snapshot.courses)
                            if meeting.id != today.last?.id {
                                Divider().padding(.leading, 12)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Coming up

    private var comingUpSubtitle: String {
        let open = snapshot.openAssignments.count
        if !snapshot.overdue.isEmpty { return "\(snapshot.overdue.count) overdue" }
        if open == 0 { return "Nothing outstanding" }
        return open <= 5 ? "\(open) to do" : "Soonest 5 of \(open)"
    }

    private var dueCard: some View {
        Card(flat: true) {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Coming up",
                              subtitle: comingUpSubtitle,
                              symbol: "checklist",
                              color: Color(red: 0.80, green: 0.47, blue: 0.14)) {
                    Button("All work") { tab = .assignments }
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                        .focusEffectDisabled()
                }
                let items = Array(snapshot.openAssignments.prefix(5))
                if items.isEmpty {
                    EmptyNote(symbol: "checkmark.circle",
                              title: "Nothing due",
                              detail: snapshot.health.feed.ok
                                ? "Canvas is not showing any open work."
                                : "Canvas could not be reached, so this list may be incomplete.")
                } else {
                    VStack(spacing: 0) {
                        ForEach(items) { item in
                            AssignmentRow(assignment: item, courses: snapshot.courses)
                            if item.id != items.last?.id {
                                Divider().padding(.leading, 12)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Courses strip

    private var coursesCard: some View {
        Card(flat: true) {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Your courses",
                              subtitle: "\(snapshot.courses.count) courses · \(snapshot.totalCredits) credit hours",
                              symbol: "books.vertical.fill",
                              color: Color(red: 0.62, green: 0.34, blue: 0.78)) {
                    Button("Details") { tab = .courses }
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                        .focusEffectDisabled()
                }
                if snapshot.courses.isEmpty {
                    EmptyNote(symbol: "books.vertical",
                              title: "No courses loaded",
                              detail: "Course details come from the registrar. Run a refresh once registration is final.")
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 10)],
                              spacing: 10) {
                        ForEach(snapshot.courses) { course in
                            CourseChip(course: course,
                                       color: Palette.color(for: course.code, in: snapshot.courses))
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Rows

struct ClassRow: View {
    let meeting: ClassMeeting
    let courses: [Course]

    private var isNow: Bool {
        guard let s = meeting.start, let f = meeting.finish else { return false }
        return s <= Date() && Date() < f
    }

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Palette.color(for: meeting.code, in: courses))
                .frame(width: 3, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(meeting.code ?? meeting.title)
                    .font(.system(size: 12, weight: .semibold))
                Text(meeting.location ?? meeting.title)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if isNow {
                Pill(text: "Now", color: HealthColor.ok, symbol: "record.circle")
            } else if let start = meeting.start {
                Text(Format.time.string(from: start))
                    .font(.system(size: 11.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

struct AssignmentRow: View {
    let assignment: Assignment
    let courses: [Course]

    private var isOverdue: Bool {
        guard let due = assignment.due else { return false }
        return due < Date() && assignment.done != true
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: assignment.done == true ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 13))
                .foregroundStyle(assignment.done == true ? HealthColor.ok : Color.secondary.opacity(0.6))
            VStack(alignment: .leading, spacing: 1) {
                Text(assignment.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    if let code = assignment.course_code {
                        Text(code)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Palette.color(for: code, in: courses))
                    }
                    Text(assignment.due.map { Format.due($0, allDay: assignment.all_day) } ?? "No due date")
                        .font(.system(size: 10.5))
                        .foregroundStyle(isOverdue ? HealthColor.fail : .secondary)
                }
            }
            Spacer(minLength: 8)
            if isOverdue {
                Pill(text: "Overdue", color: HealthColor.fail, symbol: "exclamationmark.circle.fill")
            }
            if let raw = assignment.url, let url = URL(string: raw) {
                Link(destination: url) {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .focusEffectDisabled()
                .help("Open in Canvas")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

struct CourseChip: View {
    let course: Course
    let color: Color

    var body: some View {
        HStack(spacing: 9) {
            IconTile(symbol: "book.fill", color: color, size: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(course.code)
                    .font(.system(size: 12, weight: .semibold))
                Text(course.title)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
        }
        .padding(9)
        .background(RoundedRectangle(cornerRadius: SchoolTheme.rowRadius, style: .continuous)
            .fill(Color.primary.opacity(0.04)))
    }
}
