import SwiftUI

/// What the automatic sync is doing. Deliberately the last tab and deliberately
/// plain: the app's job is showing school information, and this page exists so
/// the machinery is inspectable, not so it competes for attention.
///
/// Problems are *raised* in the Tool Dashboard, which is the central hub for
/// background-job failures. This page mirrors them and links there.
struct StatusView: View {
    @ObservedObject var model: SchoolModel
    let snapshot: Snapshot

    private var health: Health { snapshot.health }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(health.alerts) { alert in
                    let needsLogin = alert.key.contains("session")
                    let label: String? = needsLogin ? "Log in to Canvas" : nil
                    let fix: (() -> Void)? = needsLogin ? { model.openSessionSetup() } : nil
                    Banner(symbol: "exclamationmark.triangle.fill",
                           title: alert.headline,
                           detail: alertDetail(alert),
                           color: HealthColor.warn,
                           actionLabel: label,
                           action: fix)
                }

                if let error = model.refreshError {
                    Banner(symbol: "xmark.octagon.fill",
                           title: "The last manual refresh failed",
                           detail: error, color: HealthColor.fail)
                }

                connections
                schedule
                recentRuns
                whereThingsGo
            }
            .padding(18)
        }
    }

    private func alertDetail(_ alert: ActiveAlert) -> String {
        var parts: [String] = []
        if let explanation = alert.explanation { parts.append(explanation) }
        if let since = alert.sinceDate {
            parts.append("Going on since \(Format.mediumDate.string(from: since)) (\(Format.relative(since))).")
        }
        parts.append("It also shows in Tool Dashboard.")
        return parts.joined(separator: " ")
    }

    private var connections: some View {
        Card(flat: true) {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Connections",
                              subtitle: "Where the information comes from",
                              symbol: "antenna.radiowaves.left.and.right",
                              color: SchoolTheme.accent)
                VStack(spacing: 0) {
                    StatusLine(label: "Assignment feed",
                               explanation: "The public Canvas calendar feed. Gives titles and due dates.",
                               ok: health.feed.ok,
                               detail: health.feed.error)
                    Divider().padding(.leading, 12)
                    StatusLine(label: "Canvas login",
                               explanation: "Your saved browser session. Adds grades and what you have turned in.",
                               ok: health.canvas_session.ok,
                               detail: health.canvas_session.error,
                               actionLabel: health.canvas_session.ok ? nil : "Log in",
                               action: model.openSessionSetup)
                    Divider().padding(.leading, 12)
                    StatusLine(label: "Course registrations",
                               explanation: "Saved from the registrar — class times, rooms, instructors.",
                               ok: !snapshot.courses.isEmpty,
                               detail: snapshot.courses.isEmpty
                                ? "No registrar data saved yet"
                                : "\(snapshot.courses.count) courses, \(snapshot.classes.count) class meetings")
                }
            }
        }
    }

    private var schedule: some View {
        Card(flat: true) {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Automatic sync",
                              subtitle: health.started ? "Running hourly" : "Not started yet",
                              symbol: "clock.arrow.circlepath",
                              color: Color(red: 0.58, green: 0.35, blue: 0.75)) {
                    Pill(text: health.started ? "Active" : "Waiting",
                         color: health.started ? HealthColor.ok : HealthColor.idle)
                }
                VStack(spacing: 0) {
                    if let start = health.sync_start_date, let date = SchoolDate.day(start) {
                        DetailRow(label: health.started ? "Started" : "Starts",
                                  value: Format.mediumDate.string(from: date))
                        Divider().padding(.leading, 12)
                    }
                    DetailRow(label: "Writing to your reminders and calendar",
                              value: health.writes_enabled ? "Yes" : "No — planning only")
                    Divider().padding(.leading, 12)
                    DetailRow(label: "Assignments go to",
                              value: health.reminders_list.map { "\"\($0)\" reminders list" } ?? "—")
                    Divider().padding(.leading, 12)
                    DetailRow(label: "Classes go to",
                              value: health.calendar_name.map { "\"\($0)\" calendar" } ?? "—")
                    Divider().padding(.leading, 12)
                    DetailRow(label: "Items being tracked", value: "\(health.tracked_items)")
                    if let generated = snapshot.generatedAt {
                        Divider().padding(.leading, 12)
                        DetailRow(label: "This page last updated",
                                  value: "\(Format.relative(generated)) · \(Format.time.string(from: generated))")
                    }
                }
            }
        }
    }

    private var recentRuns: some View {
        Card(flat: true) {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Recent runs",
                              subtitle: "Last \(health.recent_runs.count) checks",
                              symbol: "list.bullet.rectangle",
                              color: Color(red: 0.48, green: 0.52, blue: 0.58))
                if health.recent_runs.isEmpty {
                    EmptyNote(symbol: "clock", title: "No runs recorded",
                              detail: "The background sync has not run yet.")
                } else {
                    VStack(spacing: 0) {
                        let runs = health.recent_runs.reversed().map { $0 }
                        ForEach(runs) { run in
                            RunRow(run: run)
                            if run.id != runs.last?.id {
                                Divider().padding(.leading, 12)
                            }
                        }
                    }
                }
            }
        }
    }

    private var whereThingsGo: some View {
        Card(flat: true) {
            HStack(alignment: .top, spacing: 10) {
                IconTile(symbol: "bell.slash.fill", color: Color(red: 0.48, green: 0.52, blue: 0.58))
                VStack(alignment: .leading, spacing: 3) {
                    Text("This app does not send notifications")
                        .font(.system(size: 12, weight: .semibold))
                    Text("When something in the background breaks, it is raised in Tool Dashboard — the one place all background problems collect — and mirrored on this page.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button("Open Tool Dashboard", action: model.openToolDashboard)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .focusEffectDisabled()
            }
        }
    }
}

struct StatusLine: View {
    let label: String
    let explanation: String
    let ok: Bool
    var detail: String?
    var actionLabel: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(ok ? HealthColor.ok : HealthColor.warn)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.system(size: 12, weight: .semibold))
                Text(explanation)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail, !ok || !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(ok ? .secondary : HealthColor.warn)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if let actionLabel, let action {
                Button(actionLabel, action: action)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .focusEffectDisabled()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}

struct RunRow: View {
    let run: RunRecord

    private var ok: Bool { run.ok ?? false }

    private var summary: String {
        if let error = run.error { return error }
        switch run.mode {
        case "pre-start": return "Checked — the semester has not started yet"
        case "dry-run": return "Planned only, nothing written"
        case "export": return "Refreshed the dashboard data"
        default:
            let applied = run.applied ?? 0
            let failed = run.failed ?? 0
            if applied == 0 && failed == 0 { return "Nothing to change" }
            return "\(applied) update\(applied == 1 ? "" : "s")"
                + (failed > 0 ? ", \(failed) failed" : "")
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .font(.system(size: 11))
                .foregroundStyle(ok ? HealthColor.ok : HealthColor.fail)
            Text(summary)
                .font(.system(size: 11.5))
                .lineLimit(1)
            Spacer(minLength: 8)
            if let at = run.at {
                Text(Format.relative(at))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }
}
