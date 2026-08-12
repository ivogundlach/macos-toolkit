import SwiftUI

// MARK: - Tabs

enum Tab: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case assignments = "Assignments"
    case schedule = "Schedule"
    case courses = "Courses"
    case grades = "Grades"
    case status = "Background"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .overview: return "square.grid.2x2.fill"
        case .assignments: return "checklist"
        case .schedule: return "calendar"
        case .courses: return "books.vertical.fill"
        case .grades: return "chart.bar.fill"
        case .status: return "gearshape.2.fill"
        }
    }

    var color: Color {
        switch self {
        case .overview: return SchoolTheme.accent
        case .assignments: return Color(red: 0.80, green: 0.47, blue: 0.14)
        case .schedule: return Color(red: 0.13, green: 0.58, blue: 0.52)
        case .courses: return Color(red: 0.62, green: 0.34, blue: 0.78)
        case .grades: return Color(red: 0.20, green: 0.55, blue: 0.78)
        case .status: return Color(red: 0.48, green: 0.52, blue: 0.58)
        }
    }
}

struct ContentView: View {
    @ObservedObject var model: SchoolModel
    @State private var tab: Tab = .overview

    var body: some View {
        VStack(spacing: 0) {
            TopBar(model: model, tab: $tab)
            Divider()
            Group {
                switch model.state {
                case .loading:
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                case .missing:
                    SetupNeededView(model: model)
                case .failed(let message):
                    SetupNeededView(model: model, failure: message)
                case .ready:
                    if let snapshot = model.snapshot {
                        body(for: snapshot)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(SchoolTheme.page)
        .refractiveCanvas()
    }

    @ViewBuilder
    private func body(for snapshot: Snapshot) -> some View {
        switch tab {
        case .overview:
            OverviewView(model: model, snapshot: snapshot, tab: $tab)
        case .assignments:
            AssignmentsView(snapshot: snapshot)
        case .schedule:
            ScheduleView(snapshot: snapshot)
        case .courses:
            CoursesView(snapshot: snapshot)
        case .grades:
            GradesView(model: model, snapshot: snapshot)
        case .status:
            StatusView(model: model, snapshot: snapshot)
        }
    }
}

/// Title, term, tab pills, refresh. The background sync deliberately gets no
/// space up here — it is one tab at the end, not the app's subject.
struct TopBar: View {
    @ObservedObject var model: SchoolModel
    @Binding var tab: Tab

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                IconTile(symbol: "graduationcap.fill", color: SchoolTheme.accent, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text("School").font(.system(size: 15, weight: .semibold))
                    Text(subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.snapshot?.health.hasProblem == true {
                    Button {
                        tab = .status
                    } label: {
                        Pill(text: "Needs attention", color: HealthColor.warn,
                             symbol: "exclamationmark.triangle.fill")
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .help("Something in the background sync needs looking at")
                }
                Button(action: model.refresh) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .focusEffectDisabled()
                .disabled(model.refreshing)
                .help("Fetch the latest from Canvas")
            }
            HStack(spacing: 6) {
                ForEach(Tab.allCases) { item in
                    SegmentPill(label: item.rawValue, isActive: tab == item) { tab = item }
                }
                Spacer()
                if model.refreshing {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private var subtitle: String {
        guard let snapshot = model.snapshot else { return "Loading" }
        var parts = [snapshot.term.name]
        if let days = snapshot.daysUntilTerm {
            parts.append(days == 1 ? "starts tomorrow" : "starts in \(days) days")
        } else if let progress = snapshot.termProgress {
            parts.append("\(Int(progress * 100))% through the term")
        }
        if let generated = snapshot.generatedAt {
            parts.append("updated \(Format.relative(generated))")
        }
        return parts.joined(separator: " · ")
    }
}

/// Shown when the snapshot file does not exist yet, or cannot be read at all.
struct SetupNeededView: View {
    @ObservedObject var model: SchoolModel
    var failure: String?

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            IconTile(symbol: "tray", color: SchoolTheme.accent, size: 44)
            Text(failure == nil ? "No school data yet" : "Could not read the school data")
                .font(.system(size: 15, weight: .semibold))
            Text(failure ?? "The sync has not written a snapshot yet. Fetch one now and this page fills in.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button("Fetch now", action: model.refresh)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.refreshing)
                .focusEffectDisabled()
            if let error = model.refreshError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(HealthColor.fail)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
