import SwiftUI

struct GradesView: View {
    @ObservedObject var model: SchoolModel
    let snapshot: Snapshot

    private var grades: Grades { snapshot.grades }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !grades.available {
                    Banner(symbol: "lock.fill",
                           title: "Grades need a Canvas login",
                           detail: unavailableDetail,
                           color: HealthColor.warn,
                           actionLabel: "Log in to Canvas",
                           action: model.openSessionSetup)
                }

                if grades.available || !grades.rows.isEmpty {
                    HStack(spacing: 14) {
                        Card {
                            StatTile(value: grades.gpa.map { String(format: "%.2f", $0) } ?? "—",
                                     label: "Projected term GPA",
                                     caption: grades.gpa == nil
                                        ? "Available once letter grades are posted."
                                        : "Weighted across \(grades.credits) credit hours",
                                     symbol: "chart.bar.fill",
                                     color: Color(red: 0.20, green: 0.55, blue: 0.78))
                        }
                        Card {
                            StatTile(value: "\(grades.rows.count)",
                                     label: "Courses reporting",
                                     caption: "\(snapshot.courses.count) enrolled this term",
                                     symbol: "books.vertical.fill",
                                     color: Color(red: 0.62, green: 0.34, blue: 0.78))
                        }
                        Card {
                            StatTile(value: averageScoreLabel,
                                     label: "Average score",
                                     caption: "Across courses with a posted percentage",
                                     symbol: "percent",
                                     color: Color(red: 0.13, green: 0.58, blue: 0.52))
                        }
                    }
                }

                Card(flat: true) {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader(title: "By course",
                                      subtitle: snapshot.term.name,
                                      symbol: "list.number",
                                      color: Color(red: 0.20, green: 0.55, blue: 0.78))
                        if grades.rows.isEmpty {
                            EmptyNote(symbol: "chart.bar.doc.horizontal",
                                      title: "No grades posted yet",
                                      detail: grades.available
                                        ? "Your instructors have not posted any scores. This fills in as the term goes on."
                                        : "Grades appear here once you log back in to Canvas and the term is underway.")
                        } else {
                            VStack(spacing: 0) {
                                header
                                Divider()
                                ForEach(grades.rows.sorted { ($0.code ?? "") < ($1.code ?? "") }) { row in
                                    GradeRowView(row: row, courses: snapshot.courses)
                                    if row.id != grades.rows.last?.id {
                                        Divider().padding(.leading, 12)
                                    }
                                }
                            }
                        }
                    }
                }

                if grades.gpa != nil {
                    Text("Projected, not official. It is calculated from the current Canvas grade in each course and the credit hours from your registration, on a 4.0 scale.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 4)
                }
            }
            .padding(18)
        }
    }

    /// Written out rather than assembled around `grades.reason`: that field is a
    /// machine string, and splicing it in mid-sentence produced things like
    /// "and canvas session is not active." The reason is only worth showing when
    /// it is something other than the ordinary expired login.
    private var unavailableDetail: String {
        let base = "Grades are only visible while you are logged in to Canvas. "
            + "Logging back in opens a browser window and takes about a minute. "
            + "It also restores which assignments show as already turned in."
        guard let reason = grades.reason,
              !reason.localizedCaseInsensitiveContains("session") else { return base }
        return base + " (Canvas said: \(reason))"
    }

    private var averageScoreLabel: String {
        let scores = grades.rows.compactMap(\.score)
        guard !scores.isEmpty else { return "—" }
        return String(format: "%.1f%%", scores.reduce(0, +) / Double(scores.count))
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Course").frame(width: 82, alignment: .leading)
            Text("Title").frame(maxWidth: .infinity, alignment: .leading)
            Text("Credits").frame(width: 58, alignment: .trailing)
            Text("Score").frame(width: 62, alignment: .trailing)
            Text("Grade").frame(width: 56, alignment: .trailing)
        }
        .font(.system(size: 9.5, weight: .bold))
        .kerning(0.6)
        .foregroundStyle(.secondary)
        .textCase(.uppercase)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }
}

struct GradeRowView: View {
    let row: GradeRow
    let courses: [Course]

    var body: some View {
        HStack(spacing: 10) {
            Text(row.code ?? "—")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Palette.color(for: row.code, in: courses))
                .frame(width: 82, alignment: .leading)
            Text(row.name ?? "—")
                .font(.system(size: 11.5))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(row.credits.map(String.init) ?? "—")
                .font(.system(size: 11.5, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .trailing)
            Text(row.score.map { String(format: "%.1f%%", $0) } ?? "—")
                .font(.system(size: 11.5, design: .rounded))
                .frame(width: 62, alignment: .trailing)
            Text(row.letter ?? "—")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(letterColor)
                .frame(width: 56, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var letterColor: Color {
        switch (row.letter ?? "").prefix(1) {
        case "A", "B": return HealthColor.ok
        case "C": return HealthColor.warn
        case "D", "F": return HealthColor.fail
        default: return .secondary
        }
    }
}
