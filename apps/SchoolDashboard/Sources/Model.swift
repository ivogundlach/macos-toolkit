import Foundation
import SwiftUI

// MARK: - Snapshot decoding
//
// The app is a reader. Everything it shows comes from one JSON file written by
// `school-sync export`, which is the only thing that holds the Canvas feed URL
// and session cookies. Nothing here authenticates, and nothing here writes to
// Reminders, Calendar, or Canvas.

/// Lenient ISO-8601. The exporter emits three shapes — a local offset with
/// microsecond fractions (`generated`), a local offset without them (class
/// meetings), and UTC `Z` (Canvas REST due dates) — and `ISO8601DateFormatter`
/// will not take all three under one option set.
enum SchoolDate {
    private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let dayOnly: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func parse(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        if let d = plain.date(from: raw) { return d }
        if let d = withFraction.date(from: raw) { return d }
        // Python's isoformat() emits 6 fractional digits; ISO8601DateFormatter
        // only accepts 3. Trim rather than lose the timestamp entirely.
        if let dot = raw.firstIndex(of: "."), let end = raw[dot...].firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" }) {
            let trimmed = raw.replacingCharacters(in: dot..<end, with: "")
            if let d = plain.date(from: trimmed) { return d }
        }
        return dayOnly.date(from: raw)
    }

    static func day(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        return dayOnly.date(from: raw)
    }
}

struct Meeting: Decodable, Hashable {
    var days: [String]
    var begin: String        // "0800"
    var end: String          // "0855"
    var location: String?

    /// Minutes from midnight, or nil if Banner handed us something unparseable.
    private static func minutes(_ hhmm: String) -> Int? {
        guard hhmm.count == 4,
              let h = Int(hhmm.prefix(2)), let m = Int(hhmm.suffix(2)),
              (0..<24).contains(h), (0..<60).contains(m) else { return nil }
        return h * 60 + m
    }

    var startMinutes: Int? { Meeting.minutes(begin) }
    var endMinutes: Int? { Meeting.minutes(end) }

    var dayLabel: String {
        let order = ["MO": "Mon", "TU": "Tue", "WE": "Wed", "TH": "Thu",
                     "FR": "Fri", "SA": "Sat", "SU": "Sun"]
        return days.compactMap { order[$0] }.joined(separator: " ")
    }

    var timeLabel: String {
        guard let s = startMinutes, let e = endMinutes else { return "" }
        return "\(Format.clock(s)) – \(Format.clock(e))"
    }
}

struct Course: Decodable, Identifiable, Hashable {
    var crn: String
    var code: String
    var title: String
    var section: String?
    var credits: Int?
    var schedule_type: String?
    var instructor: String?
    var instructor_email: String?
    var meetings: [Meeting]

    var id: String { crn }

    /// "Brown, William" reads as a database row; the app shows people's names.
    var instructorName: String? {
        guard let raw = instructor?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        let parts = raw.split(separator: ",", maxSplits: 1).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        return parts.count == 2 ? "\(parts[1]) \(parts[0])" : raw
    }

    var primaryLocation: String? { meetings.first(where: { $0.location != nil })?.location }
}

struct ClassMeeting: Decodable, Identifiable, Hashable {
    var code: String?
    var title: String
    var when: String
    var end: String?
    var location: String?

    var id: String { "\(code ?? "?")-\(when)" }
    var start: Date? { SchoolDate.parse(when) }
    var finish: Date? { SchoolDate.parse(end) }
}

struct Assignment: Decodable, Identifiable, Hashable {
    var title: String
    var course_code: String?
    var when: String?
    var all_day: Bool
    var url: String?
    /// nil means "the Canvas session is dead so we genuinely do not know",
    /// which the UI must not render as "not done".
    var done: Bool?

    var id: String { "\(course_code ?? "")-\(title)-\(when ?? "undated")" }
    var due: Date? { SchoolDate.parse(when) }
}

struct GradeRow: Decodable, Identifiable, Hashable {
    var course_id: String?
    var code: String?
    var name: String?
    var credits: Int?
    var score: Double?
    var letter: String?

    var id: String { course_id ?? code ?? name ?? UUID().uuidString }
}

struct Grades: Decodable, Hashable {
    var available: Bool
    var reason: String?
    var rows: [GradeRow]
    var gpa: Double?
    var credits: Int
}

struct SourceHealth: Decodable, Hashable {
    var ok: Bool
    var error: String?
}

struct RunRecord: Decodable, Identifiable, Hashable {
    var ts: String?
    var mode: String?
    var ok: Bool?
    var applied: Int?
    var failed: Int?
    var error: String?

    var id: String { ts ?? UUID().uuidString }
    var at: Date? { SchoolDate.parse(ts) }
}

struct ActiveAlert: Decodable, Identifiable, Hashable {
    var key: String
    var message: String
    var since: String?

    var id: String { key }
    var sinceDate: Date? { SchoolDate.parse(since) }

    /// The sync writes its alert messages for a log, so they name Python files
    /// and internal guards. Nothing on screen should. Known alerts get written
    /// wording; an unknown one falls through to the raw message rather than
    /// being swallowed — a problem shown awkwardly beats a problem hidden.
    var headline: String {
        switch key {
        case "preflight_session", "session_dead": return "Your Canvas login has expired"
        case "ics_backbone": return "Canvas is not answering"
        case "shrink_guard": return "A large drop was blocked as a precaution"
        default: return message
        }
    }

    var explanation: String? {
        switch key {
        case "preflight_session":
            return "Classes and due dates still work. Grades and what you have turned in stay blank until you log back in — it takes about a minute."
        case "session_dead":
            return "Grades and turned-in status are paused. Your class schedule and due dates are unaffected."
        case "ics_backbone":
            return "The Canvas feed has been failing, so due dates may be out of date."
        case "shrink_guard":
            return "Far fewer items came back than last time, so nothing was removed from your calendar or reminders. It usually clears on the next run."
        default:
            return nil
        }
    }
}

struct Health: Decodable, Hashable {
    var canvas_session: SourceHealth
    var feed: SourceHealth
    var writes_enabled: Bool
    var sync_start_date: String?
    var started: Bool
    var last_run: RunRecord?
    var recent_runs: [RunRecord]
    var tracked_items: Int
    var last_ics_ok: String?
    var last_rest_ok: String?
    var alerts: [ActiveAlert]
    var reminders_list: String?
    var calendar_name: String?

    var hasProblem: Bool { !alerts.isEmpty || !canvas_session.ok || !feed.ok }
}

struct Term: Decodable, Hashable {
    var code: String?
    var start: String?
    var end: String?
    var classes_end: String?
    var breaks: [String]
    var study_days: [String: [String]]

    var startDate: Date? { SchoolDate.day(start) }
    var endDate: Date? { SchoolDate.day(classes_end ?? end) }

    var name: String {
        // Banner term codes are YYYYMM: 202609 = Fall 2026.
        guard let code, code.count == 6, let year = Int(code.prefix(4)),
              let month = Int(code.suffix(2)) else { return "Term" }
        switch month {
        case 1...5: return "Spring \(year)"
        case 6...7: return "Summer \(year)"
        default: return "Fall \(year)"
        }
    }
}

struct Snapshot: Decodable {
    var schema: Int
    var generated: String
    var stale_after_hours: Double?
    var term: Term
    var courses: [Course]
    var classes: [ClassMeeting]
    var assignments: [Assignment]
    var grades: Grades
    var health: Health

    var generatedAt: Date? { SchoolDate.parse(generated) }

    var isStale: Bool {
        guard let generatedAt else { return true }
        let hours = stale_after_hours ?? 3
        return Date().timeIntervalSince(generatedAt) > hours * 3600
    }
}

// MARK: - Model

enum LoadState: Equatable {
    case loading
    case ready
    case missing          // the exporter has never run
    case failed(String)
}

@MainActor
final class SchoolModel: ObservableObject {
    @Published private(set) var snapshot: Snapshot?
    @Published private(set) var state: LoadState = .loading
    @Published private(set) var refreshing = false
    /// Set when a manual refresh fails while an older snapshot is still on
    /// screen — the data stays, but the failure is never silent.
    @Published private(set) var refreshError: String?

    nonisolated static let snapshotURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".local/state/school-dashboard/dashboard.json")
    nonisolated static let syncCLI = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("School/sync/.venv/bin/python")
    nonisolated static let syncScript = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("School/sync/school_sync.py")
    nonisolated static let sessionSetupScript = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("School/sync/setup_session.py")

    private var timer: Timer?

    init() {
        load()
        // The exporter runs hourly behind the sync. Re-reading a small local
        // file every 60s costs nothing and keeps a window left open honest.
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.load() }
        }
    }

    func load() {
        do {
            let data = try Data(contentsOf: Self.snapshotURL)
            snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
            state = .ready
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            state = .missing
        } catch {
            // Keep any snapshot already on screen; a corrupt rewrite should not
            // blank the window.
            state = snapshot == nil ? .failed(error.localizedDescription) : .ready
            if snapshot != nil { refreshError = "Could not read the latest data: \(error.localizedDescription)" }
        }
    }

    /// Re-run the exporter, then reload. Read-only: `export` takes no lock and
    /// writes nothing but its own snapshot file.
    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        refreshError = nil
        Task.detached(priority: .userInitiated) {
            let result = Self.runExport()
            await MainActor.run {
                self.refreshing = false
                if case .failure(let message) = result { self.refreshError = message }
                self.load()
            }
        }
    }

    private enum ExportResult { case success, failure(String) }

    /// Runs off the main actor: this blocks on a subprocess.
    private nonisolated static func runExport() -> ExportResult {
        let process = Process()
        process.executableURL = syncCLI
        process.arguments = [syncScript.path, "export"]
        process.currentDirectoryURL = syncScript.deletingLastPathComponent()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return .failure("Could not start the sync tool: \(error.localizedDescription)")
        }
        // Drain before waiting: a full 64KB pipe buffer deadlocks the child.
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let text = String(data: output, encoding: .utf8) ?? ""
            let lastLine = text.split(separator: "\n").last.map(String.init) ?? "exit \(process.terminationStatus)"
            return .failure("Refresh failed: \(lastLine)")
        }
        return .success
    }

    /// Opens Terminal on the Canvas re-login script. This one genuinely needs
    /// Ivo: it drives a visible browser window he has to log into.
    func openSessionSetup() {
        let command = "cd \(Self.syncScript.deletingLastPathComponent().path) "
            + "&& .venv/bin/python setup_session.py"
        let script = "tell application \"Terminal\" to do script \"\(command)\"\n"
            + "tell application \"Terminal\" to activate"
        guard let appleScript = NSAppleScript(source: script) else { return }
        var error: NSDictionary?
        appleScript.executeAndReturnError(&error)
    }

    func openToolDashboard() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Tool Dashboard.app"))
    }
}

// MARK: - Derived views of the data

extension Snapshot {
    var today: [ClassMeeting] { classes(on: Date()) }

    func classes(on day: Date) -> [ClassMeeting] {
        let cal = Calendar.current
        return classes
            .filter { m in m.start.map { cal.isDate($0, inSameDayAs: day) } ?? false }
            .sorted { ($0.start ?? .distantPast) < ($1.start ?? .distantPast) }
    }

    var nextClass: ClassMeeting? {
        let now = Date()
        return classes
            .filter { ($0.start ?? .distantPast) > now }
            .min { ($0.start ?? .distantFuture) < ($1.start ?? .distantFuture) }
    }

    /// The class happening right now, if any.
    var currentClass: ClassMeeting? {
        let now = Date()
        return classes.first { m in
            guard let s = m.start, let f = m.finish else { return false }
            return s <= now && now < f
        }
    }

    /// Work still to do, soonest first. Undated work is included — it is real
    /// work — but sorts after everything with a date.
    var openAssignments: [Assignment] {
        assignments
            .filter { $0.done != true }
            .sorted { a, b in
                switch (a.due, b.due) {
                case let (x?, y?): return x < y
                case (nil, _?): return false
                case (_?, nil): return true
                default: return a.title < b.title
                }
            }
    }

    var overdue: [Assignment] {
        let now = Date()
        return openAssignments.filter { ($0.due.map { $0 < now }) ?? false }
    }

    var dueThisWeek: [Assignment] {
        let now = Date()
        guard let horizon = Calendar.current.date(byAdding: .day, value: 7, to: now) else { return [] }
        return openAssignments.filter { a in
            guard let due = a.due else { return false }
            return due >= now && due <= horizon
        }
    }

    /// 0...1 through the term by class days elapsed, or nil before it starts.
    var termProgress: Double? {
        guard let start = term.startDate, let end = term.endDate, end > start else { return nil }
        let now = Date()
        if now < start { return nil }
        if now > end { return 1 }
        return now.timeIntervalSince(start) / end.timeIntervalSince(start)
    }

    var daysUntilTerm: Int? {
        guard let start = term.startDate else { return nil }
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: Date()),
                                      to: cal.startOfDay(for: start)).day ?? 0
        return days > 0 ? days : nil
    }

    var totalCredits: Int { courses.compactMap(\.credits).reduce(0, +) }

    func course(code: String?) -> Course? {
        guard let code else { return nil }
        return courses.first { $0.code == code }
    }
}
