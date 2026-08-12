import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

// UsageQueue — queue a message into an existing Codex thread;
// the backend (~/.local/bin/queue-when-usage) delivers it the moment usage resets.

let backendPath = NSString(string: "~/.local/bin/queue-when-usage").expandingTildeInPath
let homePath = NSHomeDirectory()

struct SessionRow: Codable, Identifiable {
    let id: String
    let agent: String
    let cwd: String
    let mtime: Int
    let label: String
    let archived: Bool?
    let model: String?
    let effort: String?
    let source: String?

    var identity: String { "\(agent):\(id)" }
}

struct Job: Codable, Identifiable {
    let id: String
    let agent: String
    let session: String
    let cwd: String?
    let auto: Bool?
    let prompt: String
    let status: String
    let attempts: Int?
    let created: Int?
    let next_attempt: Int?
    let model: String?
    let effort: String?
    let images: [String]?
    let thread: String?
    let inherit: Bool?
    let error: String?
}

let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp"]

// Custom model/effort choices, used only when the model source is "custom".
let codexModels: [(String, String)] = [
    ("gpt-5.6-sol", "GPT-5.6 Sol"), ("gpt-5.6-luna", "GPT-5.6 Luna"),
]
let codexSolEfforts: [(String, String)] = [
    ("low", "Low"), ("medium", "Medium"), ("high", "High"),
]
let codexLunaEfforts: [(String, String)] = [
    ("high", "High"), ("xhigh", "X-High"), ("max", "Max"),
]

func codexEfforts(for model: String) -> [(String, String)] {
    model == "gpt-5.6-luna" ? codexLunaEfforts : codexSolEfforts
}

func normalizedEffort(_ current: String, options: [(String, String)], preferred: String) -> String {
    let values = options.map { $0.0 }
    if values.contains(current) { return current }
    if values.contains(preferred) { return preferred }
    return options.first?.0 ?? current
}

func shortModelName(_ m: String) -> String {
    m.replacingOccurrences(of: "gpt-5.6-", with: "")
}

func modelChip(_ job: Job) -> String? {
    if job.inherit == true { return "same as chat" }
    guard let m = job.model else { return nil }
    let short = m.replacingOccurrences(of: "gpt-5.6-", with: "")
    if let e = job.effort { return "\(short) · \(e == "ultra" ? "Ultra mode" : e)" }
    return short
}

func runBackend(_ args: [String]) -> (Int32, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = ["python3", backendPath] + args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return (1, "cannot launch backend: \(error)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

final class AppModel: ObservableObject {
    /// The harness used for the currently selected row, or as the new-thread destination.
    @Published var agent = "codex" { didSet { persist("agent", agent) } }
    @Published var newThreadAgent = "codex" { didSet { persist("newThreadAgent", newThreadAgent) } }
    @Published var newThreadKind = "codex" { didSet { persist("newThreadKind", newThreadKind) } }
    @Published var sessions: [SessionRow] = []
    @Published var loadingSessions = false
    @Published var selected = "last" {   // "last" | "new" | agent:session id
        didSet {
            // A brand-new thread has no chat setting to inherit.
            if selected == "new" {
                modelMode = "custom"
            } else if selected != oldValue {
                modelMode = "chat"
            }
        }
    }
    @Published var statusFilter = "active" { didSet { persist("statusFilter", statusFilter); if statusFilter != oldValue { loadSessions() } } }
    @Published var prompt = "" { didSet { if prompt != oldValue { extractImagePaths() } } }
    @Published var images: [String] = []

    /// Dropping a file on a TextEditor inserts its PATH as text (NSTextView wins
    /// the drop before our handler). Convert any image path in the text into a
    /// real attachment.
    private func extractImagePaths() {
        guard prompt.contains("/") else { return }
        let pattern = "[~/][^\\n\"']*?\\.(?:png|jpe?g|gif|webp)"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return }
        var text = prompt
        var found: [String] = []
        for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let r = Range(m.range, in: text) else { continue }
            let path = (String(text[r]) as NSString).expandingTildeInPath
            if FileManager.default.fileExists(atPath: path) {
                found.append(path)
                text.removeSubrange(r)
            }
        }
        guard !found.isEmpty else { return }
        prompt = text.trimmingCharacters(in: .whitespaces)
        addImages(found.reversed().map { URL(fileURLWithPath: $0) })
    }
    @Published var modelMode = "chat" { didSet { persist("modelMode", modelMode) } }
    @Published var codexModel = "gpt-5.6-sol" {
        didSet {
            persist("codexModel", codexModel)
            if codexModel != "gpt-5.6-sol" && codexUltra {
                codexUltra = false
            }
            let options = codexEfforts(for: codexModel)
            if !options.contains(where: { $0.0 == codexEffort }) {
                codexEffort = normalizedEffort(codexEffort, options: options, preferred: "high")
            }
        }
    }
    @Published var codexEffort = "medium" { didSet { persist("codexEffort", codexEffort) } }
    /// Ultra is a persisted Sol-only mode, separate from the normal effort scale.
    @Published var codexUltra = false { didSet { persist("codexUltra", codexUltra) } }

    private func persist(_ key: String, _ value: String) {
        UserDefaults.standard.set(value, forKey: key)
    }

    private func persist(_ key: String, _ value: Bool) {
        UserDefaults.standard.set(value, forKey: key)
    }

    init() {
        // Assignments inside init don't fire didSet, so no reload cascade here.
        let d = UserDefaults.standard
        agent = "codex"
        newThreadAgent = "codex"
        newThreadKind = "codex"
        d.set(agent, forKey: "agent")
        d.set(newThreadAgent, forKey: "newThreadAgent")
        d.set(newThreadKind, forKey: "newThreadKind")
        statusFilter = d.string(forKey: "statusFilter") ?? statusFilter
        modelMode = "chat"
        if d.string(forKey: "modelMode") != modelMode { d.set(modelMode, forKey: "modelMode") }
        codexModel = d.string(forKey: "codexModel") ?? codexModel
        codexEffort = d.string(forKey: "codexEffort") ?? codexEffort
        codexUltra = (d.object(forKey: "codexUltra") as? Bool) ?? false
        queueFilter = d.string(forKey: "queueFilter") ?? queueFilter
        // A stored model that has since left the plan would still be passed to
        // the CLI and fail at delivery. Drop back to the default and rewrite the
        // stored value (didSet doesn't fire for assignments in init).
        if !codexModels.contains(where: { $0.0 == codexModel }) {
            codexModel = "gpt-5.6-sol"
            d.set(codexModel, forKey: "codexModel")
        }
        // Migrate the old Sol effort value into the persisted Ultra mode while
        // keeping a normal effort baseline for when Ultra is turned off.
        if codexModel == "gpt-5.6-sol" && codexEffort == "ultra" {
            codexUltra = true
            d.set(codexUltra, forKey: "codexUltra")
            codexEffort = "high"
            d.set(codexEffort, forKey: "codexEffort")
        }
        if codexModel != "gpt-5.6-sol" {
            codexUltra = false
            d.set(codexUltra, forKey: "codexUltra")
        }
        let validCodexEffort = normalizedEffort(codexEffort,
                                                 options: codexEfforts(for: codexModel),
                                                 preferred: "high")
        if validCodexEffort != codexEffort {
            codexEffort = validCodexEffort
            d.set(codexEffort, forKey: "codexEffort")
        }
    }

    /// The thread the queued message will land in, for "Same as chat" resolution.
    var targetSession: SessionRow? {
        if selected == "new" { return nil }
        if selected == "last" { return sessions.first }
        return sessions.first { $0.identity == selected }
            ?? sessions.first { $0.id == selected && $0.agent == agent }
    }

    var effectiveAgent: String {
        if selected == "new" { return newThreadAgent }
        return targetSession?.agent ?? agent
    }

    var effectiveSource: String? {
        return targetSession?.source
    }

    var effectiveDisplayAgent: String {
        agentDisplay(effectiveAgent, source: effectiveSource)
    }

    func selectLatest() {
        selected = "last"
        if let row = sessions.first { agent = row.agent }
    }

    func selectSession(_ row: SessionRow) {
        agent = row.agent
        selected = row.identity
    }

    func selectNewThread(_ destination: String) {
        newThreadKind = "codex"
        newThreadAgent = "codex"
        agent = newThreadAgent
        selected = "new"
    }
    @Published var jobs: [Job] = []
    @Published var queueFilter = "all" { didSet { persist("queueFilter", queueFilter) } }
    @Published var banner = ""
    @Published var bannerIsError = false

    private func matchesQueueFilter(_ j: Job) -> Bool {
        switch queueFilter {
        case "active": return ["queued", "running", "waiting"].contains(j.status)
        case "delivered": return j.status == "done"
        case "failed": return ["failed", "gave_up"].contains(j.status)
        case "cancelled": return j.status == "cancelled"
        default: return true
        }
    }

    func filteredJobs() -> [Job] {
        jobs.filter { matchesQueueFilter($0) }.sorted { a, b in
            let act = ["queued", "running", "waiting"]
            let aa = act.contains(a.status), bb = act.contains(b.status)
            if aa != bb { return aa }
            return (a.created ?? 0) > (b.created ?? 0)
        }
    }

    func loadSessions() {
        loadingSessions = true
        let st = statusFilter
        DispatchQueue.global().async {
            let (rc, out) = runBackend(["sessions", "all", "--json", "--limit", "0", "--status", st])
            let rows = (rc == 0 ? try? JSONDecoder().decode([SessionRow].self, from: Data(out.utf8)) : nil) ?? []
            DispatchQueue.main.async {
                guard self.statusFilter == st else { return }
                self.sessions = rows
                self.loadingSessions = false
                if self.selected != "last" && self.selected != "new" &&
                    !rows.contains(where: { $0.identity == self.selected }) {
                    self.selectLatest()
                } else if self.selected == "last" {
                    if let row = rows.first { self.agent = row.agent }
                } else if let row = self.targetSession {
                    self.agent = row.agent
                }
            }
        }
    }

    func refreshJobs() {
        DispatchQueue.global().async {
            let (rc, out) = runBackend(["jobs", "--json"])
            guard rc == 0, let js = try? JSONDecoder().decode([Job].self, from: Data(out.utf8)) else { return }
            DispatchQueue.main.async { self.jobs = js.filter { $0.agent == "codex" } }
        }
    }

    func queue() {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { banner = "Write a message first."; bannerIsError = true; return }
        let row = targetSession
        let destination = effectiveAgent
        let sessionID = row?.id ?? (selected == "new" ? "new" : selected)
        var args = ["add", destination, "--session", sessionID]
        if let row = row {
            args += ["--cwd", row.cwd]
        }
        args.append("--auto")   // unattended by design; approval prompts would stall the job
        var m: String?, e: String?
        if modelMode == "chat" {
            // Send no model/effort: resuming makes the CLI restore the thread's
            // own settings, so a picker change in the app is always honored.
            args.append("--inherit")
        } else {
            m = codexModel
            e = codexModel == "gpt-5.6-sol" && codexUltra ? "ultra" : codexEffort
        }
        if let m = m { args += ["--model", m] }
        if let e = e { args += ["--effort", e] }
        for img in images { args += ["--image", img] }
        let label = selected == "new" ? "New thread"
                  : (row?.label ?? "Latest thread")
        args += ["--label", label]
        args.append(text)
        banner = "Queuing…"; bannerIsError = false
        DispatchQueue.global().async {
            let (rc, out) = runBackend(args)
            DispatchQueue.main.async {
                if rc == 0 {
                    self.banner = "Queued — it sends the moment usage is available."
                    self.bannerIsError = false
                    self.prompt = ""
                    self.images = []
                    self.refreshJobs()
                } else {
                    self.banner = "Failed to queue: \(out.prefix(160))"
                    self.bannerIsError = true
                }
            }
        }
    }

    func cancel(_ id: String) {
        DispatchQueue.global().async {
            _ = runBackend(["cancel", id])
            DispatchQueue.main.async { self.refreshJobs() }
        }
    }

    func clearFinished() {
        DispatchQueue.global().async {
            _ = runBackend(["clear"])
            DispatchQueue.main.async { self.refreshJobs() }
        }
    }

    private func restore(_ job: Job) {
        agent = "codex"
        if job.session == "new" {
            newThreadAgent = "codex"
            newThreadKind = "codex"
            selected = "new"
        } else {
            let restoredSession = sessions.first(where: { $0.agent == job.agent && $0.id == job.session })
            selected = restoredSession?.identity ?? job.session
        }
        prompt = job.prompt
        images = (job.images ?? []).filter { FileManager.default.fileExists(atPath: $0) }
        modelMode = "custom"
        if let m = job.model, codexModels.contains(where: { $0.0 == m }) { codexModel = m }
        if job.effort == "ultra" && codexModel == "gpt-5.6-sol" {
            codexUltra = true
            codexEffort = "high"
        } else {
            codexUltra = false
            if let e = job.effort { codexEffort = e }
        }
        codexEffort = normalizedEffort(codexEffort,
                                       options: codexEfforts(for: codexModel),
                                       preferred: "high")
    }

    func editAndResend(_ job: Job) {
        restore(job)
        banner = "Failed message restored. Edit it, change the model, or switch lanes."
        bannerIsError = false
    }

    func resendNow(_ job: Job) {
        restore(job)
        queue()
    }

    func attachImages() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.png, .jpeg, .gif, .webP]
        if panel.runModal() == .OK {
            addImages(panel.urls)
        }
    }

    func addImages(_ urls: [URL]) {
        for u in urls where imageExtensions.contains(u.pathExtension.lowercased()) {
            if !images.contains(u.path) { images.append(u.path) }
        }
    }

    func removeImage(_ path: String) {
        images.removeAll { $0 == path }
    }
}

// MARK: - Presentation helpers

let openAIColor    = Color(red: 0.24, green: 0.55, blue: 0.52)  // OpenAI teal

func agentColor(_ a: String, source: String? = nil) -> Color {
    openAIColor
}

/// The lab that makes `m`, by model id. Anything unrecognised falls back to the
/// lane colour rather than inventing a third hue.
func labColor(forModel m: String?, fallback: Color) -> Color {
    guard let m = m?.lowercased() else { return fallback }
    if m.contains("gpt") || m.contains("sol") || m.contains("luna") || m.contains("codex") {
        return openAIColor
    }
    return fallback
}

// MARK: - New-thread lanes
//
let allNewThreadChoices: [(String, String, String, String?)] = [
    ("codex", "Codex", "chevron.left.forwardslash.chevron.right", nil),
]

let hiddenNewThreadKinds: Set<String> = []

/// Maps a hidden lane onto the visible lane that shares its backend, so a
/// restored job or a persisted preference never selects an invisible button.
func visibleNewThreadKind(_ kind: String) -> String {
    "codex"
}

func agentDisplay(_ a: String, source: String? = nil) -> String {
    "Codex"
}
func agentIcon(_ a: String, source: String? = nil) -> String {
    "chevron.left.forwardslash.chevron.right"
}

func shortPath(_ p: String) -> String {
    p.hasPrefix(homePath) ? "~" + p.dropFirst(homePath.count) : p
}

func relTime(_ epoch: Int?) -> String {
    guard let e = epoch else { return "" }
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .abbreviated
    return f.localizedString(for: Date(timeIntervalSince1970: TimeInterval(e)), relativeTo: Date())
}

func statusColor(_ s: String) -> Color {
    switch s {
    case "done": return .green
    case "waiting": return .orange
    case "running", "queued": return .blue
    case "cancelled": return .secondary
    default: return .red
    }
}

func statusText(_ s: String) -> String {
    switch s {
    case "waiting": return "Waiting for usage reset"
    case "running": return "Sending"
    case "queued": return "Starting"
    case "done": return "Delivered"
    case "gave_up": return "Gave up after 24 h"
    case "cancelled": return "Cancelled"
    default: return "Failed"
    }
}

func detailTime(_ epoch: Int?) -> String? {
    guard let epoch else { return nil }
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(epoch)))
}

func statusTimingText(_ job: Job) -> String {
    let status = statusText(job.status)
    if let next = job.next_attempt, let when = detailTime(next) {
        return status + " · next attempt " + when + " (" + relTime(next) + ")"
    }
    if let created = job.created {
        return status + " · " + relTime(created)
    }
    return status
}

/// Owns the short hover timers for one card. Keeping the work items here lets
/// card and popover hover callbacks cancel one another without stale delayed
/// work reopening a preview after the pointer has moved on.
final class JobCardHoverState: ObservableObject {
    @Published var isPresented = false
    private var cardHovered = false
    private var popoverHovered = false
    private var openWorkItem: DispatchWorkItem?
    private var closeWorkItem: DispatchWorkItem?

    func setCardHovered(_ hovering: Bool) {
        cardHovered = hovering
        if hovering {
            closeWorkItem?.cancel()
            closeWorkItem = nil
            guard !isPresented, openWorkItem == nil else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.openWorkItem = nil
                guard self.cardHovered || self.popoverHovered else { return }
                self.isPresented = true
            }
            openWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
        } else {
            openWorkItem?.cancel()
            openWorkItem = nil
            scheduleClose()
        }
    }

    func setPopoverHovered(_ hovering: Bool) {
        popoverHovered = hovering
        if hovering {
            closeWorkItem?.cancel()
            closeWorkItem = nil
        } else {
            scheduleClose()
        }
    }

    private func scheduleClose() {
        guard !cardHovered, !popoverHovered, isPresented else { return }
        closeWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.closeWorkItem = nil
            guard !self.cardHovered, !self.popoverHovered else { return }
            self.openWorkItem?.cancel()
            self.openWorkItem = nil
            self.isPresented = false
        }
        closeWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }

    func cancelPendingWork() {
        openWorkItem?.cancel()
        closeWorkItem?.cancel()
        openWorkItem = nil
        closeWorkItem = nil
        cardHovered = false
        popoverHovered = false
        isPresented = false
    }

    deinit {
        openWorkItem?.cancel()
        closeWorkItem?.cancel()
    }
}

let cardBG = Color.primary.opacity(0.045)
let cardStroke = Color.primary.opacity(0.07)

// Liquid Glass. Cards and selected segments only — chips and inset tracks keep
// the flat `cardBG` fill, since they sit inside glass and stacking the material
// on itself reads as neither layer.
let cardGlass: Glass = .regular
let interactiveGlass: Glass = .regular.interactive()

struct Card<Content: View>: View {
    let content: Content
    /// Set on a card that wraps a scroller. `glassEffect` is a backdrop blur, so it
    /// re-renders whenever its content changes — and a scrolled list changes on
    /// every frame, which pins the GPU for as long as the finger is moving. Measured
    /// across the fleet this was the whole of the scroll lag, so the material is
    /// swapped for the flat `cardBG` on exactly the cards that scroll. Cards holding
    /// static content are unaffected and keep their glass.
    var scrolls = false
    init(scrolls: Bool = false, @ViewBuilder _ content: () -> Content) {
        self.scrolls = scrolls
        self.content = content()
    }
    var body: some View {
        Group {
            if scrolls {
                content.background(RoundedRectangle(cornerRadius: 12).fill(cardBG))
            } else {
                content.refractiveGlass(cornerRadius: 12)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(cardStroke, lineWidth: 1))
    }
}

struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .kerning(0.8)
            .foregroundColor(.secondary)
    }
}

// MARK: - Header

struct HeaderView: View {
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9)
                    .fill(LinearGradient(colors: [Color(red: 0.16, green: 0.22, blue: 0.55),
                                                  Color(red: 0.45, green: 0.25, blue: 0.85)],
                                         startPoint: .bottomLeading, endPoint: .topTrailing))
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.white)
            }
            .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 1) {
                Text("UsageQueue").font(.system(size: 15, weight: .semibold))
                Text("Sends the moment usage is back")
                    .font(.system(size: 11)).foregroundColor(.secondary)
            }
            Spacer()
        }
    }
}

// MARK: - Shared controls

struct PillGroup: View {
    let options: [(String, String)]
    let tint: Color
    let selection: Binding<String>
    var compact = false
    var body: some View {
        HStack(spacing: 3) {
            ForEach(options, id: \.0) { value, name in
                Button(action: { selection.wrappedValue = value }) {
                    Text(name)
                        .font(.system(size: compact ? 10 : 11, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, compact ? 4 : 5)
                        .background(RoundedRectangle(cornerRadius: 7)
                            .fill(selection.wrappedValue == value ? tint : .clear))
                        .foregroundColor(selection.wrappedValue == value ? .white : .secondary)
                        .contentShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
            }
        }
        .padding(3)
        .refractiveInset(cornerRadius: 10)
    }
}

struct EffortSlider: View {
    let options: [(String, String)]
    let tint: Color
    let selection: Binding<String>
    var index: Int { options.firstIndex(where: { $0.0 == selection.wrappedValue }) ?? 1 }
    var body: some View {
        VStack(spacing: 5) {
            HStack {
                Text("Effort").font(.system(size: 11, weight: .medium)).foregroundColor(.secondary)
                Spacer()
                Text(options[index].1)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(tint)
            }
            Slider(value: Binding(
                get: { Double(index) },
                set: { selection.wrappedValue = options[max(0, min(options.count - 1, Int($0.rounded()))) ].0 }
            ), in: 0...Double(options.count - 1), step: 1)
            .tint(tint)
            .controlSize(.small)
            GeometryReader { geometry in
                ForEach(Array(options.enumerated()), id: \.offset) { i, opt in
                    Text(opt.1)
                        .font(.system(size: 9, weight: i == index ? .semibold : .regular))
                        .foregroundColor(i == index ? tint : .secondary.opacity(0.7))
                        .frame(maxWidth: .infinity,
                               alignment: i == 0 ? .leading : (i == options.count - 1 ? .trailing : .center))
                        .offset(x: i == 0 || i == options.count - 1 ? 0 :
                            (Double(i) / Double(options.count - 1) - 0.5) * geometry.size.width)
                }
            }
            .frame(height: 11)
        }
    }
}

// MARK: - Thread picking

struct QuickPickCard: View {
    let icon: String
    let title: String
    let subtitle: String
    let tint: Color
    let isSelected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(isSelected ? .white : tint)
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 13)).foregroundColor(.white)
                    }
                }
                Text(title).font(.system(size: 12, weight: .semibold))
                    .foregroundColor(isSelected ? .white : .primary)
                Text(subtitle).font(.system(size: 10))
                    .foregroundColor(isSelected ? .white.opacity(0.85) : .secondary)
                    .lineLimit(1)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Selection rides behind the material, so a picked card keeps its
            // colour and still reads as the same glass as everything else.
            .background(RoundedRectangle(cornerRadius: 10)
                .fill(isSelected ? AnyShapeStyle(tint) : AnyShapeStyle(Color.clear)))
            .refractiveGlass(cornerRadius: 10)
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }
}

struct NewThreadChoices: View {
    @ObservedObject var model: AppModel

    private var choices: [(String, String, String, String?)] {
        allNewThreadChoices.filter { !hiddenNewThreadKinds.contains($0.0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: "plus.bubble.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                Text("New thread")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                Text("Choose a lane")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            HStack(spacing: 5) {
                ForEach(choices, id: \.0) { choice in
                    let isSelected = model.selected == "new" && model.newThreadKind == choice.0
                    let tint = agentColor(choice.0, source: choice.3)
                    Button(action: { model.selectNewThread(choice.0) }) {
                        HStack(spacing: 5) {
                            Image(systemName: choice.2)
                                .font(.system(size: 10, weight: .semibold))
                            Text(choice.1)
                                .font(.system(size: 10, weight: .semibold))
                                .lineLimit(1)
                            if isSelected {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 8, weight: .bold))
                            }
                        }
                        .foregroundColor(isSelected ? .white : tint)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 7)
                            .fill(isSelected ? tint : Color.clear))
                        .overlay(RoundedRectangle(cornerRadius: 7)
                            .stroke(isSelected ? tint.opacity(0.9) : Color.primary.opacity(0.08), lineWidth: 1))
                        .contentShape(RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                }
            }
        }
        .padding(8)
        .refractiveInset(cornerRadius: 10)
    }
}

struct ThreadRow: View {
    let session: SessionRow
    let isSelected: Bool
    let action: () -> Void
    var tint: Color { agentColor(session.agent, source: session.source) }
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(tint.opacity(0.14))
                    Image(systemName: "bubble.left.and.text.bubble.right.fill")
                        .font(.system(size: 12)).foregroundColor(tint)
                }
                .frame(width: 30, height: 30)

                VStack(alignment: .leading, spacing: 2) {
                    Text(session.label)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Text(shortPath(session.cwd)).lineLimit(1).truncationMode(.middle)
                        Text("·")
                        Text(relTime(session.mtime))
                        Text(agentDisplay(session.agent))
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(tint)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Capsule().fill(tint.opacity(0.12)))
                        if let m = session.model {
                            Text("·")
                            Text(shortModelName(m) + (session.effort.map { " · \($0)" } ?? ""))
                                .foregroundColor(labColor(forModel: m, fallback: tint).opacity(0.9))
                        }
                    }
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                }
                Spacer(minLength: 4)
                if session.archived == true {
                    HStack(spacing: 3) {
                        Image(systemName: "archivebox.fill").font(.system(size: 7))
                        Text("Archived").font(.system(size: 9, weight: .medium))
                    }
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.07)))
                }
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14)).foregroundColor(tint)
                }
            }
            .padding(.horizontal, 9).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 9)
                .fill(isSelected ? tint.opacity(0.13) : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 9)
                .stroke(isSelected ? tint.opacity(0.55) : Color.clear, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }
}

// MARK: - Workspace columns

struct ThreadSelectionColumn: View {
    @ObservedObject var model: AppModel
    var tint: Color { agentColor(model.effectiveAgent, source: model.effectiveSource) }
    var latestTint: Color {
        agentColor(model.sessions.first?.agent ?? model.effectiveAgent,
                   source: model.sessions.first?.source)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                SectionLabel(text: "Deliver to")
                Spacer()
                Menu {
                    Picker("Status", selection: $model.statusFilter) {
                        Text("Active").tag("active")
                        Text("Archived").tag("archived")
                        Text("All").tag("all")
                    }
                    .pickerStyle(.inline)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                            .font(.system(size: 11, weight: .semibold))
                        if model.statusFilter != "active" {
                            Text(model.statusFilter == "archived" ? "Archived" : "All")
                                .font(.system(size: 10, weight: .semibold))
                        }
                    }
                    .foregroundColor(model.statusFilter == "active" ? .secondary : tint)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .focusEffectDisabled()
                .focusable(false)
                .help("Filter threads by status")
                Button(action: { model.loadSessions() }) {
                    Image(systemName: "arrow.clockwise").font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.plain).foregroundColor(.secondary)
                .focusEffectDisabled()
                .help("Reload threads")
            }

            QuickPickCard(icon: "clock.arrow.circlepath", title: "Latest thread",
                          subtitle: "Continue the most recent one", tint: latestTint,
                          isSelected: model.selected == "last") { model.selectLatest() }

            NewThreadChoices(model: model)

            Card(scrolls: true) {
                ScrollView {
                    VStack(spacing: 2) {
                        if model.loadingSessions {
                            ProgressView().controlSize(.small)
                                .frame(maxWidth: .infinity).padding(.vertical, 16)
                        } else if model.sessions.isEmpty {
                            VStack(spacing: 6) {
                                Image(systemName: "bubble.left.and.bubble.right")
                                    .font(.system(size: 18)).foregroundColor(.secondary.opacity(0.5))
                                Text("No conversations found")
                                    .font(.system(size: 11)).foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity).padding(.vertical, 20)
                        }
                        ForEach(model.sessions, id: \.identity) { s in
                            ThreadRow(session: s,
                                      isSelected: model.selected == s.identity) { model.selectSession(s) }
                        }
                    }
                    .padding(5)
                }
            }
            .frame(maxHeight: .infinity)
        }
    }
}

private final class MessageEditorTextView: NSTextView {
    var onLayout: (() -> Void)?

    override func layout() {
        super.layout()
        onLayout?()
    }
}

private final class MessageEditorScrollView: NSScrollView {
    var onLayout: (() -> Void)?

    override func layout() {
        super.layout()
        onLayout?()
    }
}

private struct MessageTextEditor: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = MessageEditorScrollView()
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.borderType = .noBorder
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = false
        scrollView.scrollerStyle = .overlay
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.contentView.postsFrameChangedNotifications = true

        let textView = MessageEditorTextView()
        textView.delegate = context.coordinator
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.font = NSFont.systemFont(ofSize: 13)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: 0,
                                                       height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.string = text

        scrollView.documentView = textView
        let coordinator = context.coordinator
        scrollView.onLayout = { [weak coordinator, weak scrollView] in
            coordinator?.updateOverflow(in: scrollView)
        }
        textView.onLayout = { [weak coordinator, weak scrollView] in
            coordinator?.updateOverflow(in: scrollView)
        }
        coordinator.observeBounds(of: scrollView.contentView, scrollView: scrollView)
        coordinator.updateOverflow(in: scrollView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? MessageEditorTextView else { return }
        context.coordinator.text = $text
        textView.font = NSFont.systemFont(ofSize: 13)
        if textView.string != text {
            textView.string = text
        }
        context.coordinator.updateOverflow(in: scrollView)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        private var boundsObserver: NSObjectProtocol?
        private var frameObserver: NSObjectProtocol?
        private var isUpdatingOverflow = false

        init(text: Binding<String>) {
            self.text = text
        }

        deinit {
            if let boundsObserver {
                NotificationCenter.default.removeObserver(boundsObserver)
            }
            if let frameObserver {
                NotificationCenter.default.removeObserver(frameObserver)
            }
        }

        func observeBounds(of clipView: NSClipView, scrollView: NSScrollView) {
            let center = NotificationCenter.default
            boundsObserver = center.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: clipView,
                queue: .main
            ) { [weak self, weak scrollView] _ in
                self?.updateOverflow(in: scrollView)
            }
            frameObserver = center.addObserver(
                forName: NSView.frameDidChangeNotification,
                object: clipView,
                queue: .main
            ) { [weak self, weak scrollView] _ in
                self?.updateOverflow(in: scrollView)
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? MessageEditorTextView else { return }
            if text.wrappedValue != textView.string {
                text.wrappedValue = textView.string
            }
            updateOverflow(in: textView.enclosingScrollView)
        }

        func updateOverflow(in scrollView: NSScrollView?) {
            guard !isUpdatingOverflow,
                  let scrollView,
                  let textView = scrollView.documentView as? MessageEditorTextView,
                  let textContainer = textView.textContainer,
                  let layoutManager = textView.layoutManager else { return }
            let visibleHeight = scrollView.contentView.bounds.height
            guard visibleHeight > 0 else { return }

            isUpdatingOverflow = true
            defer { isUpdatingOverflow = false }
            layoutManager.ensureLayout(for: textContainer)
            let usedRect = layoutManager.usedRect(for: textContainer)
            let extraLineHeight = layoutManager.extraLineFragmentRect.height
            let contentHeight = max(usedRect.height, extraLineHeight)
                + textView.textContainerInset.height * 2
            let shouldScroll = contentHeight > visibleHeight + 0.5
            if scrollView.hasVerticalScroller != shouldScroll {
                scrollView.hasVerticalScroller = shouldScroll
                scrollView.needsLayout = true
            }
        }
    }
}

struct ComposerColumn: View {
    @ObservedObject var model: AppModel
    var tint: Color { agentColor(model.effectiveAgent, source: model.effectiveSource) }
    var labTint: Color {
        labColor(forModel: model.codexModel, fallback: tint)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel(text: "Message")
                Spacer()
                Button(action: { model.attachImages() }) {
                    Image(systemName: "paperclip").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain).foregroundColor(.secondary)
                .focusEffectDisabled()
                .help("Attach images (or drag them onto the message box)")
            }
            Card {
                ZStack(alignment: .topLeading) {
                    MessageTextEditor(text: $model.prompt)
                        .frame(height: 138)
                        .padding(8)
                    if model.prompt.isEmpty {
                        Text("What should \(model.effectiveDisplayAgent) do when usage is back?")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary.opacity(0.6))
                            .padding(.leading, 13)
                            .padding(.top, 8)
                            .allowsHitTesting(false)
                    }
                }
            }
            .frame(height: 154, alignment: .top)
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                for p in providers {
                    _ = p.loadObject(ofClass: URL.self) { url, _ in
                        if let url = url {
                            DispatchQueue.main.async { model.addImages([url]) }
                        }
                    }
                }
                return true
            }

            if !model.images.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(model.images, id: \.self) { path in
                            HStack(spacing: 5) {
                                if let img = NSImage(contentsOfFile: path) {
                                    Image(nsImage: img)
                                        .resizable().aspectRatio(contentMode: .fill)
                                        .frame(width: 22, height: 22)
                                        .clipShape(RoundedRectangle(cornerRadius: 5))
                                } else {
                                    Image(systemName: "photo").font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                }
                                Text((path as NSString).lastPathComponent)
                                    .font(.system(size: 10)).lineLimit(1)
                                    .frame(maxWidth: 140)
                                Button(action: { model.removeImage(path) }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 11)).foregroundColor(.secondary.opacity(0.7))
                                        .frame(width: 22, height: 22)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .focusEffectDisabled()
                                .zIndex(1)
                            }
                            .padding(.horizontal, 7).padding(.vertical, 4)
                            .refractiveInset(cornerRadius: 8)
                            .fixedSize(horizontal: true, vertical: false)
                        }
                    }
                }
            }

            HStack(spacing: 10) {
                Image(systemName: "cpu")
                    .font(.system(size: 11)).foregroundColor(labTint)
                Text("Model").font(.system(size: 12, weight: .medium))
                Spacer()
                if model.selected != "new" {
                    PillGroup(options: [("chat", "Same as chat"), ("custom", "Custom")],
                              tint: labTint, selection: $model.modelMode, compact: true)
                        .frame(width: 190)
                } else {
                    Text("Custom for new threads")
                        .font(.system(size: 10)).foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 2)

            if model.modelMode == "custom" {
                Card {
                    VStack(spacing: 10) {
                        PillGroup(options: codexModels, tint: labTint,
                                  selection: $model.codexModel, compact: true)
                        EffortSlider(options: codexEfforts(for: model.codexModel), tint: labTint,
                                     selection: $model.codexEffort)
                        if model.codexModel == "gpt-5.6-sol" {
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("Ultra mode")
                                        .font(.system(size: 11, weight: .semibold))
                                    Text("Sol-only setting; sends Ultra instead of the effort value")
                                        .font(.system(size: 9)).foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Toggle("Ultra mode", isOn: $model.codexUltra)
                                    .labelsHidden()
                                    .toggleStyle(.switch)
                                    .controlSize(.mini)
                                    .focusEffectDisabled()
                            }
                        }
                    }
                    .padding(10)
                }
            }

            Button(action: { model.queue() }) {
                HStack {
                    Spacer()
                    Image(systemName: "paperplane.fill").font(.system(size: 12, weight: .semibold))
                    Text("Queue for \(model.effectiveDisplayAgent)")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                }
                .padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 9).fill(tint))
                .foregroundColor(.white)
                .contentShape(RoundedRectangle(cornerRadius: 9))
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .keyboardShortcut(.return, modifiers: .command)

            if !model.banner.isEmpty {
                HStack(spacing: 5) {
                    Image(systemName: model.bannerIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .font(.system(size: 10))
                    Text(model.banner).font(.system(size: 11))
                }
                .foregroundColor(model.bannerIsError ? .red : .secondary)
            }
        }
    }
}

// MARK: - Queue panel (always visible, mixed harnesses)

struct JobDetailRow: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .kerning(0.6)
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 11))
                .foregroundColor(.primary.opacity(0.9))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct JobDetailPopover: View {
    let job: Job
    let onHoverChanged: (Bool) -> Void

    private var modelValue: String? {
        if job.inherit == true { return "Same as chat" }
        let effort = job.effort.map { $0 == "ultra" ? "Ultra mode" : $0 }
        if let model = job.model {
            return model + (effort.map { " · \($0)" } ?? "")
        }
        return effort
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Circle().fill(statusColor(job.status)).frame(width: 7, height: 7)
                    Text(statusText(job.status))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(statusColor(job.status))
                    Spacer()
                    Text(agentDisplay(job.agent))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(agentColor(job.agent))
                }

                JobDetailRow(label: "Status timing", value: statusTimingText(job))
                JobDetailRow(label: "Harness / destination", value: agentDisplay(job.agent))

                if let modelValue {
                    JobDetailRow(label: "Model / effort", value: modelValue)
                }
                if let thread = job.thread, !thread.isEmpty {
                    JobDetailRow(label: "Target thread / label", value: thread)
                }
                JobDetailRow(label: "Session ID", value: job.session)
                if let cwd = job.cwd, !cwd.isEmpty {
                    JobDetailRow(label: "Working directory", value: cwd)
                }
                JobDetailRow(label: "Job ID", value: job.id)
                if let created = detailTime(job.created) {
                    JobDetailRow(label: "Created", value: created + " (" + relTime(job.created) + ")")
                }
                if let next = detailTime(job.next_attempt) {
                    JobDetailRow(label: "Next attempt", value: next + " (" + relTime(job.next_attempt) + ")")
                }
                if let attempts = job.attempts {
                    JobDetailRow(label: "Attempts", value: String(attempts))
                }
                if let auto = job.auto {
                    JobDetailRow(label: "Unattended", value: auto ? "Yes — automatic delivery" : "No — interactive")
                }
                if let images = job.images {
                    JobDetailRow(label: "Attachments", value: String(images.count))
                    ForEach(images, id: \.self) { path in
                        JobDetailRow(label: "Attachment path", value: path)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("PROMPT")
                        .font(.system(size: 9, weight: .semibold))
                        .kerning(0.6)
                        .foregroundColor(.secondary)
                    Text(job.prompt)
                        .font(.system(size: 12))
                        .foregroundColor(.primary.opacity(0.9))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let error = job.error, !error.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("ERROR")
                            .font(.system(size: 9, weight: .semibold))
                            .kerning(0.6)
                            .foregroundColor(.red.opacity(0.85))
                        Text(error.trimmingCharacters(in: .whitespacesAndNewlines))
                            .font(.system(size: 11))
                            .foregroundColor(.red.opacity(0.9))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(14)
        }
        .frame(width: 460)
        .frame(maxHeight: 520)
        .refractiveGlass(cornerRadius: 16)
        .onHover(perform: onHoverChanged)
        .focusEffectDisabled()
    }
}

struct JobCard: View {
    let job: Job
    let onCancel: () -> Void
    let onEditAndResend: () -> Void
    let onResendNow: () -> Void
    @StateObject private var hover = JobCardHoverState()
    var active: Bool { ["queued", "running", "waiting"].contains(job.status) }
    var color: Color { statusColor(job.status) }
    var cardStatusText: String {
        if job.status == "waiting", let t = job.next_attempt, t > Int(Date().timeIntervalSince1970) {
            let f = DateFormatter()
            f.timeStyle = .short
            return "Waiting · sends ~\(f.string(from: Date(timeIntervalSince1970: TimeInterval(t))))"
        }
        return statusText(job.status)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                HStack(spacing: 5) {
                    if active {
                        ProgressView().controlSize(.mini).scaleEffect(0.75).frame(width: 10, height: 10)
                    } else {
                        Circle().fill(color).frame(width: 6, height: 6)
                    }
                    Text(cardStatusText)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(color)
                }
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(color.opacity(0.13)))

                HStack(spacing: 4) {
                    Image(systemName: agentIcon(job.agent))
                        .font(.system(size: 8, weight: .bold))
                    Text(agentDisplay(job.agent))
                }
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(agentColor(job.agent))
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(Capsule().fill(agentColor(job.agent).opacity(0.13)))

                if let chip = modelChip(job) {
                    // "same as chat" names no model, so it stays neutral.
                    let named = job.inherit != true
                    let chipTint = named ? labColor(forModel: job.model, fallback: .secondary) : .secondary
                    Text(chip)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(chipTint)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(named ? chipTint.opacity(0.13)
                                                        : Color.primary.opacity(0.07)))
                }
                if let imgs = job.images, !imgs.isEmpty {
                    HStack(spacing: 3) {
                        Image(systemName: "paperclip").font(.system(size: 8, weight: .semibold))
                        Text("\(imgs.count)").font(.system(size: 9, weight: .medium))
                    }
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.07)))
                }
                Spacer()
                Text(relTime(job.created)).font(.system(size: 10)).foregroundColor(.secondary)
                if active {
                    Button(action: onCancel) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13)).foregroundColor(.secondary.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .help("Cancel")
                } else if job.status == "failed" || job.status == "gave_up" {
                    Button(action: onEditAndResend) {
                        Image(systemName: "pencil")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.plain).foregroundColor(.secondary)
                    .focusEffectDisabled()
                    .help("Edit and resend")
                    Button(action: onResendNow) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.plain).foregroundColor(agentColor(job.agent))
                    .focusEffectDisabled()
                    .help("Resend now with the same settings")
                }
            }
            if let t = job.thread, !t.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.system(size: 8, weight: .semibold))
                    Text(t).lineLimit(1)
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundColor(agentColor(job.agent).opacity(0.9))
            }
            Text(job.prompt)
                .font(.system(size: 13))
                .foregroundColor(.primary.opacity(0.85))
                .lineLimit(4)
            if let e = job.error, !e.isEmpty {
                Text(e.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.system(size: 10)).foregroundColor(.red.opacity(0.85))
                    .lineLimit(4)
            }
        }
        .padding(12)
        .refractiveInset(cornerRadius: 11)
        .contentShape(RoundedRectangle(cornerRadius: 11))
        .onHover { hover.setCardHovered($0) }
        .popover(isPresented: $hover.isPresented) {
            JobDetailPopover(job: job, onHoverChanged: { hover.setPopoverHovered($0) })
        }
        .onDisappear { hover.cancelPendingWork() }
        .focusEffectDisabled()
    }
}

let queueFilterNames = ["all": "All", "active": "Active", "delivered": "Delivered",
                        "failed": "Failed", "cancelled": "Cancelled"]

struct QueuePanel: View {
    @ObservedObject var model: AppModel
    var visibleJobs: [Job] { model.filteredJobs() }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                SectionLabel(text: "Queued messages")
                Spacer()
                Menu {
                    Picker("Status", selection: $model.queueFilter) {
                        Text("All").tag("all")
                        Text("Active").tag("active")
                        Text("Delivered").tag("delivered")
                        Text("Failed").tag("failed")
                        Text("Cancelled").tag("cancelled")
                    }
                    .pickerStyle(.inline)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                            .font(.system(size: 11, weight: .semibold))
                        if model.queueFilter != "all" {
                            Text(queueFilterNames[model.queueFilter] ?? "")
                                .font(.system(size: 10, weight: .semibold))
                        }
                    }
                    .foregroundColor(model.queueFilter == "all" ? .secondary : .orange)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .focusEffectDisabled()
                .focusable(false)
                .help("Filter queue by status")
                Button(action: { model.clearFinished() }) {
                    Image(systemName: "trash").font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.plain).foregroundColor(.secondary)
                .focusEffectDisabled()
                .help("Clear finished messages (active ones are kept)")
            }
            Group {
                if visibleJobs.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "tray")
                            .font(.system(size: 19, weight: .medium))
                            .foregroundColor(.secondary.opacity(0.5))
                        Text(model.queueFilter == "all" ? "Nothing queued"
                             : "No \(queueFilterNames[model.queueFilter]?.lowercased() ?? "") messages")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)
                        Text("Queued messages appear here and fire at usage reset.")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary.opacity(0.75))
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 7) {
                            ForEach(visibleJobs) { j in
                                JobCard(job: j, onCancel: { model.cancel(j.id) },
                                        onEditAndResend: { model.editAndResend(j) },
                                        onResendNow: { model.resendNow(j) })
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .refractiveGlass(cornerRadius: 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Root

struct ContentView: View {
    @ObservedObject var model: AppModel
    let timer = Timer.publish(every: 4, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 14) {
            HeaderView()
            GeometryReader { geometry in
                let gap: CGFloat = 14
                let columnWidth = max(0, (geometry.size.width - gap) / 2)
                HStack(alignment: .top, spacing: gap) {
                    ThreadSelectionColumn(model: model)
                        .frame(width: columnWidth)
                    VStack(alignment: .leading, spacing: 10) {
                        QueuePanel(model: model)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .layoutPriority(1)
                        ComposerColumn(model: model)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(width: columnWidth)
                    .frame(maxHeight: .infinity, alignment: .topLeading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxHeight: .infinity)
        }
        .padding(16)
        .frame(minWidth: 900, idealWidth: 940, maxWidth: 1120, minHeight: 650, idealHeight: 700, maxHeight: 900)
        .refractiveCanvas()
        .onAppear { model.loadSessions(); model.refreshJobs() }
        .onReceive(timer) { _ in model.refreshJobs() }
    }
}

// Queued delivery runs in launchd-owned background processes (see cmd_add in
// the backend), not this UI process, so quitting when the last window closes
// never interrupts a job. Terminating on window close keeps UsageQueue out of
// the Dock as a windowless "Running in Background" tile.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct UsageQueueApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup("UsageQueue") {
            ContentView(model: model)
                // macOS 26 draws a heavy accent focus ring around whatever holds
                // keyboard focus. It reads as an error state here, so the whole
                // window opts out; selection is already shown by the pill fill.
                .focusEffectDisabled()
        }
        .defaultSize(width: 860, height: 660)
        .windowResizability(.contentSize)
    }
}
