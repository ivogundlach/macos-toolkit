import SwiftUI

struct AssignmentsView: View {
    let snapshot: Snapshot
    @State private var showDone = false
    @State private var courseFilter: String?

    private struct Group: Identifiable {
        let id: String
        let items: [Assignment]
        let color: Color
        let symbol: String
    }

    private var filtered: [Assignment] {
        var items = showDone ? snapshot.assignments : snapshot.assignments.filter { $0.done != true }
        if let courseFilter {
            items = items.filter { $0.course_code == courseFilter }
        }
        return items.sorted { a, b in
            switch (a.due, b.due) {
            case let (x?, y?): return x < y
            case (nil, _?): return false
            case (_?, nil): return true
            default: return a.title < b.title
            }
        }
    }

    private var groups: [Group] {
        let now = Date()
        let cal = Calendar.current
        let weekEnd = cal.date(byAdding: .day, value: 7, to: now) ?? now
        var overdue: [Assignment] = []
        var today: [Assignment] = []
        var week: [Assignment] = []
        var later: [Assignment] = []
        var undated: [Assignment] = []
        var done: [Assignment] = []

        for item in filtered {
            if item.done == true { done.append(item); continue }
            guard let due = item.due else { undated.append(item); continue }
            if due < now { overdue.append(item) }
            else if cal.isDateInToday(due) { today.append(item) }
            else if due <= weekEnd { week.append(item) }
            else { later.append(item) }
        }

        return [
            Group(id: "Overdue", items: overdue, color: HealthColor.fail, symbol: "exclamationmark.triangle.fill"),
            Group(id: "Due today", items: today, color: Color(red: 0.80, green: 0.47, blue: 0.14), symbol: "sun.max.fill"),
            Group(id: "Next 7 days", items: week, color: SchoolTheme.accent, symbol: "calendar"),
            Group(id: "Later", items: later, color: Color(red: 0.48, green: 0.52, blue: 0.58), symbol: "tray.full.fill"),
            Group(id: "No due date", items: undated, color: Color(red: 0.48, green: 0.52, blue: 0.58), symbol: "questionmark.circle.fill"),
            Group(id: "Done", items: done, color: HealthColor.ok, symbol: "checkmark.circle.fill"),
        ].filter { !$0.items.isEmpty }
    }

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if snapshot.health.canvas_session.ok == false && !snapshot.assignments.isEmpty {
                        Banner(symbol: "questionmark.circle.fill",
                               title: "Turned-in status is unknown",
                               detail: "Canvas needs you to log in again before the app can tell which of these you have already submitted. Until then everything shows as still to do.",
                               color: HealthColor.warn)
                    }
                    if groups.isEmpty {
                        Card(flat: true) {
                            EmptyNote(symbol: "checkmark.circle",
                                      title: snapshot.assignments.isEmpty ? "No assignments yet" : "Nothing matches",
                                      detail: snapshot.assignments.isEmpty
                                        ? "Canvas has not published any work yet. Assignments appear here as soon as your instructors post them."
                                        : "Try clearing the course filter.")
                        }
                    }
                    ForEach(groups) { group in
                        Card(flat: true) {
                            VStack(alignment: .leading, spacing: 10) {
                                SectionHeader(title: group.id,
                                              subtitle: "\(group.items.count) item\(group.items.count == 1 ? "" : "s")",
                                              symbol: group.symbol, color: group.color)
                                VStack(spacing: 0) {
                                    ForEach(group.items) { item in
                                        AssignmentRow(assignment: item, courses: snapshot.courses)
                                        if item.id != group.items.last?.id {
                                            Divider().padding(.leading, 12)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(18)
            }
        }
    }

    private var filterBar: some View {
        HStack(spacing: 6) {
            SegmentPill(label: "All courses", isActive: courseFilter == nil) { courseFilter = nil }
            ForEach(snapshot.courses) { course in
                SegmentPill(label: course.code, isActive: courseFilter == course.code) {
                    courseFilter = course.code
                }
            }
            Spacer()
            Toggle("Show finished", isOn: $showDone)
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
                .focusEffectDisabled()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }
}
