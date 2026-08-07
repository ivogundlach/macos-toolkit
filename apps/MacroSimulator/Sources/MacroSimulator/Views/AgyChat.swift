import SwiftUI
import Observation
import AppKit
import Foundation
import SQLite3

// MARK: - Types

struct AgyConversation: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let lastViewed: TimeInterval
    let isArchived: Bool
}

struct AgyChatMessage: Identifiable, Equatable {
    let id = UUID()
    let role: String // "You" | "AGY"
    let text: String
}

// MARK: - Conversation silo
// The Tax Simulator's AGY pane only shows and uses conversations that belong to this
// app, kept separate from unrelated Antigravity chats. Membership is an app-owned
// registry, seeded once from conversations that already reference the app and grown
// as you chat here.

#if IVO_PREVIEW
private let agyConversationsRoot = URL(fileURLWithPath: "/tmp/public-app-preview/conversations")
private let agyAnnotationsRoot = URL(fileURLWithPath: "/tmp/public-app-preview/annotations")
#else
private let agyConversationsRoot = URL(fileURLWithPath: "/Users/YOUR_USERNAME/.gemini/antigravity/conversations")
private let agyAnnotationsRoot = URL(fileURLWithPath: "/Users/YOUR_USERNAME/.gemini/antigravity/annotations")
#endif

func agySiloRegistryURL() -> URL {
#if IVO_PREVIEW
    return URL(fileURLWithPath: "/tmp/public-app-preview/agy-conversations.json")
#else
    let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
        ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
    let dir = base.appendingPathComponent("TaxSimulator", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("agy-conversations.json")
#endif
}

func loadAgySilo() -> Set<String> {
#if IVO_PREVIEW
    return ["preview-baseline", "preview-tax-package"]
#else
    guard let data = try? Data(contentsOf: agySiloRegistryURL()),
          let ids = try? JSONDecoder().decode([String].self, from: data) else { return [] }
    return Set(ids)
#endif
}

func saveAgySilo(_ ids: Set<String>) {
#if IVO_PREVIEW
    _ = ids
#else
    if let data = try? JSONEncoder().encode(ids.sorted()) {
        try? data.write(to: agySiloRegistryURL())
    }
#endif
}

func registerAgyConversation(_ id: String) {
    guard !id.isEmpty else { return }
    var ids = loadAgySilo()
    guard !ids.contains(id) else { return }
    ids.insert(id)
    saveAgySilo(ids)
}

func currentAgyConversationIDs() -> Set<String> {
#if IVO_PREVIEW
    return ["preview-baseline", "preview-tax-package"]
#else
    let dbs = (try? FileManager.default.contentsOfDirectory(at: agyConversationsRoot, includingPropertiesForKeys: nil)) ?? []
    return Set(dbs.filter { $0.pathExtension == "db" }.map { $0.deletingPathExtension().lastPathComponent })
#endif
}

/// First run only: seed the silo with existing conversations that reference the app
/// (their DB content mentions "MacroSimulator" or "Tax Simulator"). After that the
/// registry is authoritative and only grows from conversations started in this pane.
func agySeedSiloIfNeeded() {
#if IVO_PREVIEW
    return
#else
    guard !FileManager.default.fileExists(atPath: agySiloRegistryURL().path) else { return }
    let dbs = (try? FileManager.default.contentsOfDirectory(at: agyConversationsRoot, includingPropertiesForKeys: nil)) ?? []
    let needleA = Data("MacroSimulator".utf8)
    let needleB = Data("Tax Simulator".utf8)
    var seeded = Set<String>()
    for db in dbs where db.pathExtension == "db" {
        guard let data = try? Data(contentsOf: db) else { continue }
        if data.range(of: needleA) != nil || data.range(of: needleB) != nil {
            seeded.insert(db.deletingPathExtension().lastPathComponent)
        }
    }
    saveAgySilo(seeded)
#endif
}

// MARK: - Conversation listing

func loadAgyConversations() -> [AgyConversation] {
#if IVO_PREVIEW
    return [
        AgyConversation(id: "preview-baseline", title: "Review the baseline", subtitle: "Today", lastViewed: 2, isArchived: false),
        AgyConversation(id: "preview-tax-package", title: "Compare a tax package", subtitle: "Yesterday", lastViewed: 1, isArchived: false)
    ]
#else
    agySeedSiloIfNeeded()
    let silo = loadAgySilo()
    let allDBs = (try? FileManager.default.contentsOfDirectory(at: agyConversationsRoot, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
    let dbs = allDBs.filter { $0.pathExtension == "db" && silo.contains($0.deletingPathExtension().lastPathComponent) }

    return dbs
        .compactMap { dbURL in
            let id = dbURL.deletingPathExtension().lastPathComponent
            let annotation = agyAnnotationsRoot.appendingPathComponent("\(id).pbtxt")
            let annotationText = (try? String(contentsOf: annotation, encoding: .utf8)) ?? ""
            let isArchived = annotationText.contains("archived:true")
            let lastViewed = parseAgyLastViewed(annotationText)
                ?? ((try? dbURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate?.timeIntervalSince1970) ?? 0)
            let title = agyFirstMessageTitle(dbPath: dbURL.path) ?? "Untitled conversation"
            let dateStr = lastViewed > 0 ? agyShortDate(lastViewed) : ""
            let subtitle = isArchived
                ? (dateStr.isEmpty ? "Archived" : "Archived · \(dateStr)")
                : dateStr
            return AgyConversation(id: id, title: title, subtitle: subtitle, lastViewed: lastViewed, isArchived: isArchived)
        }
        .sorted { $0.lastViewed > $1.lastViewed }
#endif
}

func parseAgyLastViewed(_ text: String) -> TimeInterval? {
    guard let range = text.range(of: #"seconds:(\d+)"#, options: .regularExpression) else {
        return nil
    }
    let match = String(text[range])
    return TimeInterval(match.replacingOccurrences(of: "seconds:", with: ""))
}

private let agyShortDateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "MMM d"
    return f
}()

func agyShortDate(_ t: TimeInterval) -> String {
    agyShortDateFormatter.string(from: Date(timeIntervalSince1970: t))
}

// MARK: - SQLite step reading
// Conversation DBs store one protobuf blob per step. Step types observed:
// 14 = user message, 15 = assistant text, 8/9/25 = tool JSON, others internal.

private func agyReadSteps(dbPath: String, types: [Int], limit: Int) -> [(type: Int, payload: Data)] {
    var db: OpaquePointer?
    guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
        sqlite3_close(db)
        return []
    }
    defer { sqlite3_close(db) }

    let typeList = types.map(String.init).joined(separator: ",")
    var stmt: OpaquePointer?
    let sql = "SELECT step_type, step_payload FROM steps WHERE step_type IN (\(typeList)) ORDER BY idx LIMIT \(limit)"
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
    defer { sqlite3_finalize(stmt) }

    var rows: [(Int, Data)] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
        let type = Int(sqlite3_column_int(stmt, 0))
        guard let bytes = sqlite3_column_blob(stmt, 1) else { continue }
        let len = Int(sqlite3_column_bytes(stmt, 1))
        guard len > 0 else { continue }
        rows.append((type, Data(bytes: bytes, count: len)))
    }
    return rows
}

/// Extracts the main human-readable text from a step's protobuf blob by walking
/// the wire format and taking the longest plausible string field. Structural
/// parsing keeps multi-line/non-ASCII text intact and drops field-boundary noise.
private func agyMessageText(in data: Data) -> String? {
    var candidates: [String] = []
    _ = agyProtoStrings(data, into: &candidates)
    guard var text = candidates.max(by: { $0.count < $1.count }) else { return nil }
    text = agyStripLeadingArtifact(text)
    if text.count > 6000 {
        text = String(text.prefix(6000)) + "\n…"
    }
    return text
}

/// Minimal protobuf wire-format walker. Returns true if `data` parses cleanly as a
/// message; collects every length-delimited field that reads like prose, recursing
/// into fields that themselves parse as messages.
private func agyProtoStrings(_ data: Data, depth: Int = 0, into out: inout [String]) -> Bool {
    let bytes = [UInt8](data)
    var pos = 0
    func varint() -> UInt64? {
        var result: UInt64 = 0, shift: UInt64 = 0
        while pos < bytes.count {
            let b = bytes[pos]; pos += 1
            result |= UInt64(b & 0x7F) << shift
            if b & 0x80 == 0 { return result }
            shift += 7
            if shift > 63 { return nil }
        }
        return nil
    }
    while pos < bytes.count {
        guard let key = varint() else { return false }
        switch key & 7 {
        case 0: guard varint() != nil else { return false }
        case 1: guard pos + 8 <= bytes.count else { return false }; pos += 8
        case 5: guard pos + 4 <= bytes.count else { return false }; pos += 4
        case 2:
            guard let len = varint(), len <= UInt64(bytes.count - pos) else { return false }
            let slice = data.subdata(in: data.startIndex + pos ..< data.startIndex + pos + Int(len))
            pos += Int(len)
            var nested: [String] = []
            if depth < 8, slice.count > 1, agyProtoStrings(slice, depth: depth + 1, into: &nested) {
                out.append(contentsOf: nested)
            }
            if let s = agyPlausibleText(slice) { out.append(s) }
        default:
            return false
        }
    }
    return true
}

/// A length-delimited field counts as message text if it's valid UTF-8 prose:
/// long enough, has words, no control chars, and isn't a UUID or tool-JSON blob.
private func agyPlausibleText(_ data: Data) -> String? {
    guard data.count >= 16, let s = String(data: data, encoding: .utf8) else { return nil }
    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    guard t.count >= 16, t.contains(" "), t.rangeOfCharacter(from: .letters) != nil else { return nil }
    if t.hasPrefix("{") || t.hasPrefix("[{") { return nil }
    if t.range(of: #"^[0-9a-fA-F-]{20,}$"#, options: .regularExpression) != nil { return nil }
    let control = t.unicodeScalars.contains { $0.value < 32 && $0 != "\n" && $0 != "\t" && $0 != "\r" }
    guard !control else { return nil }
    return t
}

/// Drops a leading protobuf length-prefix byte that decoded as a stray character:
/// leading non-letter junk, or one letter glued onto the real first word
/// ("qPlease…" → "Please…", "NWhenever…" → "Whenever…").
private func agyStripLeadingArtifact(_ s: String) -> String {
    var chars = Array(s)
    while let first = chars.first, !first.isLetter, !first.isNumber, !"(\"'/#$".contains(first) {
        chars.removeFirst()
    }
    if chars.count > 2, chars[0].isLetter, chars[1].isLetter,
       (chars[0].isLowercase && chars[1].isUppercase) ||
       (chars[0].isUppercase && chars[1].isUppercase && chars[2].isLowercase) {
        chars.removeFirst()
    }
    return String(chars)
}

/// Full best-effort chat history for a conversation: each user message (type 14)
/// starts a turn; the LAST assistant text (type 15) before the next user message is
/// that turn's reply (intermediate tool narrations are dropped).
func agyConversationHistory(dbPath: String) -> [AgyChatMessage] {
#if IVO_PREVIEW
    if dbPath.contains("preview-tax-package") {
        return [
            AgyChatMessage(role: "You", text: "Compare this package with the FY 2026 baseline."),
            AgyChatMessage(role: "AGY", text: "The package raises revenue while keeping the largest spending programs near baseline. The main trade-off is a higher effective burden on capital income.")
        ]
    }
    return [
        AgyChatMessage(role: "You", text: "What should I notice in the baseline?"),
        AgyChatMessage(role: "AGY", text: "Revenue remains below outlays, so the dashboard starts in deficit. Open any policy lever to test how a single assumption changes the balance and risk thresholds.")
    ]
#else
    let rows = agyReadSteps(dbPath: dbPath, types: [14, 15], limit: 2000)
    var messages: [AgyChatMessage] = []
    var pendingReply: String? = nil

    for (type, payload) in rows {
        guard let text = agyMessageText(in: payload) else { continue }
        if type == 14 {
            if let reply = pendingReply {
                messages.append(AgyChatMessage(role: "AGY", text: reply))
                pendingReply = nil
            }
            // Retried/echoed user steps produce back-to-back duplicates — keep one.
            if messages.last?.role == "You", messages.last?.text == text { continue }
            messages.append(AgyChatMessage(role: "You", text: text))
        } else {
            pendingReply = text
        }
    }
    if let reply = pendingReply {
        messages.append(AgyChatMessage(role: "AGY", text: reply))
    }
    if messages.count > 80 {
        messages = Array(messages.suffix(80))
    }
    return messages
#endif
}

/// Short chatbot-style conversation name derived from the first user message.
private func agyFirstMessageTitle(dbPath: String) -> String? {
    for (_, payload) in agyReadSteps(dbPath: dbPath, types: [14], limit: 1) {
        if let text = agyMessageText(in: payload), let title = agyDeriveTitle(text) {
            return title
        }
    }
    return nil
}

/// Turns a raw first user message into a short conversation name: the file's
/// basename for path-dominant messages, otherwise the first clean phrase with
/// lead-in filler stripped and cut at the first sentence boundary.
func agyDeriveTitle(_ raw: String) -> String? {
    var s = raw.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)

    if s.lowercased().hasPrefix("command("), s.hasSuffix(")") {
        s = String(s.dropFirst("command(".count).dropLast())
    }
    for lead in ["/goal", "/command", "/ask"] where s.lowercased().hasPrefix(lead) {
        s = String(s.dropFirst(lead.count)).trimmingCharacters(in: .whitespaces)
    }

    let fillers = ["read ", "please ", "fact-check the ", "fact check the ", "fact-check ",
                   "fact check ", "discover and extract actual ", "discover and extract ",
                   "verify that this docs has no factual errors:", "verify that ", "go to ",
                   "can you ", "i want to ", "help me "]
    let lower = s.lowercased()
    for f in fillers where lower.hasPrefix(f) {
        s = String(s.dropFirst(f.count)).trimmingCharacters(in: .whitespaces)
        break
    }

    if let base = agyPathBasename(s) { return base }

    if let r = s.range(of: #"[.!?](\s|$)"#, options: .regularExpression) {
        let head = String(s[..<r.lowerBound])
        if head.count >= 12 { s = head }
    }

    s = s.trimmingCharacters(in: CharacterSet(charactersIn: " `'\"-/:()"))
    let stop: Set<String> = ["a","an","the","and","or","of","to","in","on","for","that",
                             "as","is","with","my","this","these","at","by","from"]
    var picked: [String] = []
    var count = 0
    for w in s.split(separator: " ") {
        let word = String(w)
        let add = (picked.isEmpty ? 0 : 1) + word.count
        if count + add > 42 { break }
        picked.append(word)
        count += add
        if picked.count >= 8 { break }
    }
    while let last = picked.last, stop.contains(last.lowercased()) { picked.removeLast() }
    let joined = picked.joined(separator: " ")
        .trimmingCharacters(in: CharacterSet(charactersIn: " `'\".,:;-/()"))
    guard joined.count >= 3 else { return nil }
    return joined.prefix(1).uppercased() + joined.dropFirst()
}

func agyPathBasename(_ s: String) -> String? {
    let trimmed = s.trimmingCharacters(in: CharacterSet(charactersIn: " `\""))
    guard let token = trimmed.split(separator: " ").first.map(String.init) else { return nil }
    let clean = token.trimmingCharacters(in: CharacterSet(charactersIn: "`\".,:;()"))
    guard clean.contains("/"), let last = clean.split(separator: "/").last else { return nil }
    let base = String(last)
    guard base.contains("."), base.count >= 3, base.count <= 40 else { return nil }
    return base.replacingOccurrences(of: "_", with: " ")
}

// MARK: - View model

@Observable
final class AgyChatModel {
    var conversations: [AgyConversation] = []
    var selectedID: String? = nil   // nil while composing a brand-new conversation
    var messages: [AgyChatMessage] = []
    var prompt = ""
    var isRunning = false
    var isLoadingHistory = false
    var status = ""
    var includeContext = true
    private var hasLoaded = false

    var selectedConversation: AgyConversation? {
        conversations.first { $0.id == selectedID }
    }

    var headerTitle: String {
        selectedConversation?.title ?? "New conversation"
    }

    var canSend: Bool {
        !isRunning && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Initial load: list silo conversations, select the most recent, show its history.
    func loadIfNeeded() {
        guard !hasLoaded else { return }
        hasLoaded = true
        refreshConversations(thenSelectLatest: true)
    }

    func refreshConversations(thenSelectLatest: Bool = false) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let list = loadAgyConversations()
            DispatchQueue.main.async {
                guard let self else { return }
                self.conversations = list
                if thenSelectLatest, self.selectedID == nil, let latest = list.first {
                    self.select(latest.id)
                }
            }
        }
    }

    func select(_ id: String) {
        guard id != selectedID else { return }
        selectedID = id
        messages = []
        isLoadingHistory = true
        status = ""
        let path = agyConversationsRoot.appendingPathComponent("\(id).db").path
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let history = agyConversationHistory(dbPath: path)
            DispatchQueue.main.async {
                guard let self, self.selectedID == id else { return }
                self.messages = history
                self.isLoadingHistory = false
            }
        }
    }

    func startNewChat() {
        selectedID = nil
        messages = []
        status = ""
    }

    /// Sends the prompt. `context` is the scenario block built by the view (which owns
    /// the engine); empty means don't attach. Never touches the global `--continue` —
    /// a selected conversation is resumed by id, otherwise a new one is created and
    /// registered into the silo.
    func send(context: String) {
        let message = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, !isRunning else { return }
        let fullPrompt = context.isEmpty ? message : "Context:\n\(context)\n\nUser request:\n\(message)"

        var args: [String] = []
        if let id = selectedID {
            args += ["--conversation", id]
        } else {
            args.append("--new-project")
        }
        args += ["--print", fullPrompt]

        let knownBefore = currentAgyConversationIDs()
        let continuingID = selectedID
        isRunning = true
        status = "Waiting for AGY…"
        messages.append(AgyChatMessage(role: "You", text: message))
        prompt = ""

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let output = Self.runAgy(arguments: args)
            let newIDs = currentAgyConversationIDs().subtracting(knownBefore)
            for id in newIDs { registerAgyConversation(id) }
            if let continuingID { registerAgyConversation(continuingID) }
            let activeID = continuingID ?? newIDs.sorted().first
            DispatchQueue.main.async {
                guard let self else { return }
                self.messages.append(AgyChatMessage(role: "AGY", text: output))
                if self.selectedID == nil, let activeID { self.selectedID = activeID }
                self.status = ""
                self.isRunning = false
                self.refreshConversations()
            }
        }
    }

    private static func runAgy(arguments: [String]) -> String {
#if IVO_PREVIEW
        _ = arguments
        return "Preview response: scenario context received. This isolated build does not read conversations, write the silo registry, or run AGY."
#else
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/Users/YOUR_USERNAME/.local/bin/agy")
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: "/Users/YOUR_USERNAME/Projects/MacroSimulator")

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        // The pipe MUST be drained while agy runs. Waiting for exit before
        // reading deadlocks the moment output passes the ~64KB pipe buffer: agy
        // blocks writing, this blocks waiting, and neither ever returns. A model
        // reply is free-form text with no size ceiling, and stderr shares this
        // pipe, so exceeding 64KB is ordinary rather than exceptional.
        var data = Data()
        let drain = DispatchGroup()
        let drainQueue = DispatchQueue(label: "dev.ivogundlach.macrosimulator.agy.output")

        do {
            // Started only after a successful launch: this process holds the
            // write end open, so on a launch failure the reader would never see
            // EOF and would block forever.
            try process.run()
            drainQueue.async(group: drain) {
                data = pipe.fileHandleForReading.readDataToEndOfFile()
            }
            process.waitUntilExit()
            _ = drain.wait(timeout: .now() + 10)
            let text = String(data: data, encoding: .utf8) ?? ""
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "agy exited with status \(process.terminationStatus)"
                : text
        } catch {
            return "Failed to run agy: \(error.localizedDescription)"
        }
#endif
    }
}

// MARK: - View

struct AgyChatView: View {
    @Bindable var model: AgyChatModel
    @Bindable var engine: MacroMathEngine
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
            Divider()
            transcript
            Divider()
            composer
                .padding(12)
                .background(TaxLabTheme.grouped)
        }
        .refractiveCanvas()
        .onAppear { model.loadIfNeeded() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("AGY scenario assistant")
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(TaxLabTheme.accent.opacity(0.13))
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(TaxLabTheme.accent)
            }
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                TaxLabSectionLabel(text: "AGY workspace")
                Menu {
                    ForEach(model.conversations) { conversation in
                        Button {
                            model.select(conversation.id)
                        } label: {
                            if conversation.id == model.selectedID {
                                Label(conversation.title, systemImage: "checkmark")
                            } else {
                                Text(conversation.title)
                            }
                        }
                    }
                    if !model.conversations.isEmpty { Divider() }
                    Button {
                        model.refreshConversations()
                    } label: {
                        Label("Refresh conversations", systemImage: "arrow.clockwise")
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(model.headerTitle)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize(horizontal: false, vertical: true)
                .help("Switch conversation")
                .accessibilityLabel("Conversation: \(model.headerTitle)")
            }

            Spacer(minLength: 6)

            if model.isRunning {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.mini)
                    Text("Thinking")
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            }

            Button {
                model.startNewChat()
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 7).fill(TaxLabTheme.panel))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("New AGY conversation")
            .help("New conversation")

            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 7).fill(TaxLabTheme.panel))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Hide AGY assistant")
            .help("Hide AGY assistant pane")
        }
    }

    // MARK: Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if model.isLoadingHistory {
                        VStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Loading conversation")
                                .font(.system(size: 11, weight: .medium))
                            Text("Reading this thread's local history")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 36)
                    } else if model.messages.isEmpty {
                        emptyState
                    } else {
                        ForEach(model.messages) { message in
                            bubble(message)
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(TaxLabTheme.grouped)
            .onChange(of: model.messages.count) { _, _ in
                if let last = model.messages.last {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .onChange(of: model.isLoadingHistory) { _, loading in
                if !loading, let last = model.messages.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(TaxLabTheme.accent.opacity(0.10))
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(TaxLabTheme.accent)
            }
            .frame(width: 42, height: 42)

            Text(model.selectedID == nil ? "Start a scenario review" : "No messages recovered")
                .font(.system(size: 12, weight: .semibold))
            Text(model.selectedID == nil
                 ? "Ask AGY to explain trade-offs, compare the baseline, or stress-test this policy mix."
                 : "This conversation has no readable user or assistant messages.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 38)
        .accessibilityElement(children: .combine)
    }

    private func bubble(_ message: AgyChatMessage) -> some View {
        let isUser = message.role == "You"
        return HStack(alignment: .top, spacing: 8) {
            if isUser { Spacer(minLength: 38) }

            if !isUser {
                ZStack {
                    RoundedRectangle(cornerRadius: 6).fill(TaxLabTheme.accent.opacity(0.12))
                    Image(systemName: "sparkles")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(TaxLabTheme.accent)
                }
                .frame(width: 24, height: 24)
            }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 3) {
                Text(isUser ? "You" : "AGY")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(message.text)
                    .font(.system(size: 12))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 10)
                        .fill(isUser ? TaxLabTheme.accent.opacity(0.13) : TaxLabTheme.panel))
                    .overlay(RoundedRectangle(cornerRadius: 10)
                        .stroke(isUser ? TaxLabTheme.accent.opacity(0.16) : TaxLabTheme.border, lineWidth: 1))
            }

            if !isUser { Spacer(minLength: 38) }
        }
        .id(message.id)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(message.role): \(message.text)")
    }

    // MARK: Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    model.includeContext.toggle()
                } label: {
                    Label(model.includeContext ? "Scenario attached" : "Scenario off",
                          systemImage: model.includeContext ? "paperclip.circle.fill" : "paperclip.circle")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(model.includeContext ? TaxLabTheme.accent : Color.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(model.includeContext
                            ? TaxLabTheme.accent.opacity(0.12)
                            : TaxLabTheme.panelStrong))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(model.includeContext ? "Scenario context attached" : "Scenario context not attached")
                .accessibilityHint("Toggle whether current fiscal values are sent with each message")
                .help("Attach current fiscal numbers and changes from baseline")

                if !model.status.isEmpty {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.mini)
                        Text(model.status)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }

            HStack(alignment: .bottom, spacing: 8) {
                ZStack(alignment: .topLeading) {
                    if model.prompt.isEmpty {
                        Text("Ask about this scenario…")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 10)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $model.prompt)
                        .font(.system(size: 12))
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 42, maxHeight: 116)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .onKeyPress(.return, phases: .down) { press in
                            if press.modifiers.contains(.shift) { return .ignored }
                            guard model.canSend else { return .handled }
                            model.send(context: model.includeContext ? contextBlock() : "")
                            return .handled
                        }
                        .accessibilityLabel("Message AGY")
                }
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(TaxLabTheme.borderStrong, lineWidth: 1))

                Button {
                    model.send(context: model.includeContext ? contextBlock() : "")
                } label: {
                    Group {
                        if model.isRunning {
                            ProgressView().controlSize(.small).tint(.white)
                        } else {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 12, weight: .bold))
                        }
                    }
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(model.canSend ? TaxLabTheme.accent : Color.secondary.opacity(0.25)))
                    .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .disabled(!model.canSend)
                .accessibilityLabel(model.isRunning ? "AGY is responding" : "Send message")
                .help("Send (Enter) — Shift+Enter for a new line")
            }

            Text("Enter to send · Shift+Enter for a new line")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Scenario context

    private func contextBlock() -> String {
        var parts = ["""
        Tax Simulator scenario:
        Revenues: \(formatBillions(engine.activeTotalRevenues))
        Outlays: \(formatBillions(engine.activeTotalOutlays))
        Deficit: \(formatBillions(engine.activeDeficit))
        Novel revenue: \(formatBillions(engine.activeNovelRevenue))
        Novel programs: \(formatBillions(engine.activeNovelSpending))
        """]

        var changed: [String] = []
        if abs(engine.activeTotalRevenues - engine.currentBaseline.totalRevenues) > 0.01 {
            changed.append("Revenue change: \(formatBillions(engine.revenueChange))")
        }
        if abs(engine.activeTotalOutlays - engine.currentBaseline.totalOutlays) > 0.01 {
            changed.append("Outlay change: \(formatBillions(engine.outlayChange))")
        }
        if abs(engine.activeDeficit - engine.currentBaseline.deficit) > 0.01 {
            changed.append("Deficit change: \(formatBillions(engine.deficitChange))")
        }
        if !changed.isEmpty {
            parts.append("Changed values:\n" + changed.joined(separator: "\n"))
        }
        return parts.joined(separator: "\n\n")
    }
}
