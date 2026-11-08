import SwiftUI
import EventKit
import Security
import Observation

// MARK: - Keychain

enum Keychain {
    private static func q(_ k: String) -> [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "Bearing", kSecAttrAccount as String: k] }
    static func get(_ k: String) -> String {
        var q = q(k); q[kSecReturnData as String] = true
        var r: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &r) == errSecSuccess, let d = r as? Data else { return "" }
        return String(decoding: d, as: UTF8.self)
    }
    static func set(_ k: String, _ v: String) {
        SecItemDelete(q(k) as CFDictionary)
        guard !v.isEmpty else { return }
        var a = q(k); a[kSecValueData as String] = Data(v.utf8)
        SecItemAdd(a as CFDictionary, nil)
    }
}

// MARK: - Todoist two-way sync

struct TDItem: Decodable {
    struct Due: Decodable { var date: String }
    var id: String, content: String
    var description: String?
    var project_id: String?
    var priority: Int?
    var checked: Bool?
    var is_deleted: Bool?
    var due: Due?
}
struct TDProject: Decodable { var id: String, name: String; var is_deleted: Bool? }
struct TDResponse: Decodable {
    var sync_token: String?
    var items: [TDItem]?
    var projects: [TDProject]?
    var temp_id_mapping: [String: String]?
    var sync_status: [String: TDStatus]?
}
enum TDStatus: Decodable {
    case ok, failed(String, Int)
    private struct E: Decodable { var error: String?; var http_code: Int? }
    init(from d: Decoder) throws {
        if let e = try? d.singleValueContainer().decode(E.self) { self = .failed(e.error ?? "Todoist rejected a change", e.http_code ?? 400) } else { self = .ok }
    }
}
func parseTodoistDate(_ s: String) -> Date? {
    if let d = ISO8601DateFormatter().date(from: s) { return d }
    let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
    for p in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd"] { f.dateFormat = p; if let d = f.date(from: s) { return d } }
    return nil
}
/// Applies a sync response to local state. Pure so it can be self-tested.
func applyTodoist(_ r: TDResponse, to d: inout AppData) -> String? {
    var failure: String?
    for (temp, real) in r.temp_id_mapping ?? [:] {
        if let i = d.tasks.firstIndex(where: { $0.todoistID == temp }) { d.tasks[i].todoistID = real }
    }
    let status = r.sync_status ?? [:]
    d.outbox.removeAll { c in
        switch status[c.uuid] {
        case .ok: return true
        case .failed(let m, let code): if code == 429 || code >= 500 { return false }; failure = m; return true // retries only when transient
        case nil: return false
        }
    }
    for p in r.projects ?? [] { d.projects[p.id] = p.is_deleted == true ? nil : p.name }
    let pending = Set(d.outbox.compactMap { c -> String? in if case .string(let s)? = c.args["id"] { return s }; return nil })
    for it in r.items ?? [] where !pending.contains(it.id) {
        let i = d.tasks.firstIndex { $0.todoistID == it.id }
        if it.is_deleted == true {
            if let i { let id = d.tasks[i].id; d.tasks.remove(at: i); for b in d.blocks.indices where d.blocks[b].taskID == id { d.blocks[b].taskID = nil } }
            continue
        }
        var t = i.map { d.tasks[$0] } ?? TaskItem()
        t.todoistID = it.id; t.title = it.content; t.notes = it.description ?? ""
        t.project = it.project_id.flatMap { d.projects[$0] } ?? ""
        t.priority = it.priority ?? 1; t.done = it.checked ?? false
        t.due = it.due.flatMap { parseTodoistDate($0.date) }
        if let i { d.tasks[i] = t } else { d.tasks.insert(t, at: 0) }
        // Titles follow the task onto its time blocks
        for b in d.blocks.indices where d.blocks[b].taskID == t.id { d.blocks[b].title = t.title }
    }
    if let s = r.sync_token { d.syncToken = s }
    return failure
}

@Observable @MainActor final class Todoist {
    static let shared = Todoist()
    var status = "Not connected"
    var lastSync: Date?
    var syncing = false
    @ObservationIgnored private var nudged = false
    @ObservationIgnored private var loop: Task<Void, Never>?

    func start() {
        guard loop == nil else { return }
        loop = Task {
            while !Task.isCancelled {
                await sync()
                // ponytail: 8s polling stays under Todoist's 1000 partial syncs per 15 min; webhooks would need a server
                for _ in 0..<80 where !nudged { try? await Task.sleep(for: .milliseconds(100)) }
                nudged = false
            }
        }
    }
    func nudge() { nudged = true }
    func connect(_ token: String) async {
        Keychain.set("todoist", token.trimmingCharacters(in: .whitespacesAndNewlines))
        Store.shared.data.todoistToken = !token.isEmpty
        Store.shared.data.syncToken = "*"
        await sync()
        // Tasks made before connecting go up to Todoist as well
        for t in Store.shared.data.tasks where t.todoistID == nil {
            let temp = UUID().uuidString
            if let i = Store.shared.data.tasks.firstIndex(where: { $0.id == t.id }) { Store.shared.data.tasks[i].todoistID = temp }
            Store.shared.data.outbox.append(TodoistCommand(type: "item_add", tempID: temp, taskID: t.id, args: ["content": .string(t.title)]))
        }
        nudge()
    }
    func disconnect() {
        Keychain.set("todoist", ""); let s = Store.shared
        s.data.todoistToken = false; s.data.syncToken = "*"; s.data.outbox = []; status = "Not connected"
    }
    func sync() async {
        let s = Store.shared
        guard s.data.todoistToken, !syncing else { return }
        let token = Keychain.get("todoist"); guard !token.isEmpty else { status = "Token missing"; return }
        syncing = true; defer { syncing = false }
        var req = URLRequest(url: URL(string: "https://api.todoist.com/api/v1/sync")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let sent = s.data.outbox
        var parts = ["sync_token=" + Self.enc(s.data.syncToken), "resource_types=" + Self.enc("[\"projects\",\"items\"]")]
        if !sent.isEmpty { parts.append("commands=" + Self.enc(Self.commandsJSON(sent))) }
        req.httpBody = parts.joined(separator: "&").data(using: .utf8)
        do {
            let (d, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 || code == 403 { status = "Todoist rejected this token"; return }
            if code == 429 { status = "Todoist rate limit, retrying shortly"; return }
            guard code == 200 else { status = "Todoist error \(code)"; return }
            let r = try JSONDecoder().decode(TDResponse.self, from: d)
            let failure = applyTodoist(r, to: &s.data)
            lastSync = Date(); status = failure ?? "Synced"
        } catch { status = "Offline. Changes will sync when you reconnect" }
    }
    nonisolated static func enc(_ s: String) -> String {
        var c = CharacterSet.alphanumerics; c.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: c) ?? s
    }
    nonisolated static func commandsJSON(_ cmds: [TodoistCommand]) -> String {
        struct W: Encodable { var type: String, uuid: String, temp_id: String?, args: [String: JSONValue] }
        let d = try? JSONEncoder().encode(cmds.map { W(type: $0.type, uuid: $0.uuid, temp_id: $0.tempID, args: $0.args) })
        return String(decoding: d ?? Data(), as: UTF8.self)
    }
}

// MARK: - Calendar (every account already added to macOS)

struct CalEvent: Identifiable, Hashable { var id: String, title: String, start: Date, end: Date, allDay: Bool, color: Color }

@Observable @MainActor final class CalendarService {
    static let shared = CalendarService()
    let ek = EKEventStore()
    var granted = EKEventStore.authorizationStatus(for: .event) == .fullAccess
    var revision = 0

    func request() async {
        granted = (try? await ek.requestFullAccessToEvents()) ?? false
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: ek, queue: .main) { _ in
            MainActor.assumeIsolated { CalendarService.shared.reconcile() }
        }
        reconcile()
    }
    var calendars: [EKCalendar] { granted ? ek.calendars(for: .event).filter(\.allowsContentModifications) : [] }
    private var target: EKCalendar? {
        Store.shared.data.prefs.calendarID.flatMap { ek.calendar(withIdentifier: $0) } ?? ek.defaultCalendarForNewEvents
    }
    func events(from: Date, to: Date) -> [CalEvent] {
        let blocks = Store.shared.data.blocks.filter { $0.eventID != nil }
        let linked = Set(blocks.compactMap(\.eventID))
        // A Google account can also be added to Apple Calendar, so one event may arrive twice.
        var seen = Set(blocks.map { "\($0.title)|\($0.start.timeIntervalSince1970)" })
        var out: [CalEvent] = []
        func add(_ e: CalEvent) { if !linked.contains(e.id), seen.insert("\(e.title)|\(e.start.timeIntervalSince1970)").inserted { out.append(e) } }
        if granted {
            ek.events(matching: ek.predicateForEvents(withStart: from, end: to, calendars: nil)).forEach {
                add(CalEvent(id: $0.eventIdentifier ?? UUID().uuidString, title: $0.title ?? "Busy", start: $0.startDate, end: $0.endDate, allDay: $0.isAllDay, color: Color(cgColor: $0.calendar.cgColor)))
            }
        }
        let g = GoogleCalendar.shared
        let colors = Dictionary(g.calendars.map { ($0.id, $0.color) }, uniquingKeysWith: { a, _ in a })
        for e in g.events where e.start < to && e.end > from {
            add(CalEvent(id: e.key, title: e.title, start: e.start, end: e.end, allDay: e.allDay, color: colors[e.cal] ?? .brand))
        }
        return out
    }
    func save(_ b: Block) -> String? {
        let g = GoogleCalendar.shared
        if b.eventID?.hasPrefix("g:") == true || (b.eventID == nil && g.isTarget) { g.push(b); return b.eventID }
        guard granted, let cal = target else { return b.eventID }
        let e = b.eventID.flatMap { ek.event(withIdentifier: $0) } ?? {
            let n = EKEvent(eventStore: ek); n.calendar = cal; return n
        }()
        e.title = b.title; e.startDate = b.start; e.endDate = b.end
        try? ek.save(e, span: .thisEvent)
        return e.eventIdentifier
    }
    func remove(_ b: Block) {
        if let id = b.eventID, id.hasPrefix("g:") { GoogleCalendar.shared.remove(id); return }
        if let id = b.eventID, let e = ek.event(withIdentifier: id) { try? ek.remove(e, span: .thisEvent) }
    }
    /// Changes made in Calendar.app flow back into blocks.
    func reconcile() {
        guard granted else { return }
        let s = Store.shared
        for b in s.data.blocks {
            guard let id = b.eventID, !id.hasPrefix("g:"), let i = s.data.blocks.firstIndex(of: b) else { continue }
            if let e = ek.event(withIdentifier: id) {
                if e.startDate != b.start || e.endDate != b.end || e.title != b.title {
                    s.data.blocks[i].start = e.startDate; s.data.blocks[i].end = e.endDate; s.data.blocks[i].title = e.title ?? b.title
                }
            } else { s.data.blocks.remove(at: i) }
        }
        revision += 1
    }
}

// MARK: - AI (any major provider, or a local server)

enum AIProvider: String, Codable, CaseIterable, Identifiable {
    case ollama, lmstudio, custom, anthropic, openai, google, xai, meta, mistral, deepseek, groq, openrouter
    var id: String { rawValue }
    var name: String { switch self {
        case .ollama: "Ollama (free, on this Mac)"; case .lmstudio: "LM Studio (free, on this Mac)"; case .custom: "Custom server"
        case .anthropic: "Anthropic (Claude)"; case .openai: "OpenAI (ChatGPT)"; case .google: "Google (Gemini)"; case .xai: "xAI (Grok)"
        case .meta: "Meta (Llama)"; case .mistral: "Mistral"; case .deepseek: "DeepSeek"; case .groq: "Groq"; case .openrouter: "OpenRouter" } }
    @MainActor var baseURL: String { switch self {
        case .ollama: "http://localhost:11434/v1"; case .lmstudio: "http://localhost:1234/v1"; case .custom: Store.shared.data.prefs.customURL
        case .anthropic: "https://api.anthropic.com/v1"; case .openai: "https://api.openai.com/v1"
        case .google: "https://generativelanguage.googleapis.com/v1beta/openai"; case .xai: "https://api.x.ai/v1"; case .meta: "https://api.llama.com/v1"
        case .mistral: "https://api.mistral.ai/v1"; case .deepseek: "https://api.deepseek.com/v1"; case .groq: "https://api.groq.com/openai/v1"; case .openrouter: "https://openrouter.ai/api/v1" } }
    var isLocal: Bool { self == .ollama || self == .lmstudio || self == .custom }
}
struct AIError: LocalizedError { var errorDescription: String? }

@MainActor enum AI {
    static var provider: AIProvider { Store.shared.data.prefs.provider }
    static var model: String { Store.shared.data.prefs.models[provider.rawValue] ?? (provider == .ollama ? "llama3.2" : "") }

    private static func request(_ path: String, _ p: AIProvider) -> URLRequest? {
        guard let u = URL(string: p.baseURL + path) else { return nil }
        var r = URLRequest(url: u); r.timeoutInterval = 300
        let key = Keychain.get("ai." + p.rawValue)
        if p == .anthropic { r.setValue(key, forHTTPHeaderField: "x-api-key"); r.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version") }
        else if !key.isEmpty { r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        return r
    }
    static func listModels(_ p: AIProvider) async -> [String] {
        guard let r = request("/models", p), let (d, _) = try? await URLSession.shared.data(for: r),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let a = o["data"] as? [[String: Any]] else { return [] }
        return a.compactMap { $0["id"] as? String }.sorted()
    }
    /// Streams a reply. onToken runs on the main actor for every chunk.
    static func stream(system: String, messages: [ChatMsg], onToken: (String) -> Void) async throws {
        let p = provider, anth = p == .anthropic
        guard !model.isEmpty else { throw AIError(errorDescription: "Choose a model in Settings → AI first.") }
        if !p.isLocal && Keychain.get("ai." + p.rawValue).isEmpty { throw AIError(errorDescription: "Add your \(p.name) API key in Settings → AI, or switch to free local Ollama.") }
        guard var r = request(anth ? "/messages" : "/chat/completions", p) else { throw AIError(errorDescription: "That server address isn't valid.") }
        r.httpMethod = "POST"; r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var msgs: [[String: String]] = messages.map { ["role": $0.role, "content": $0.text] }
        // Anthropic and Gemini require the first message to come from the user; the coach can open a chat.
        if messages.first?.role == "assistant" { msgs.insert(["role": "user", "content": "Let's begin."], at: 0) }
        var body: [String: Any] = ["model": model, "stream": true]
        if anth { body["system"] = system; body["max_tokens"] = 4096 } else { msgs.insert(["role": "system", "content": system], at: 0) }
        body["messages"] = msgs
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        let bytes: URLSession.AsyncBytes, resp: URLResponse
        do { (bytes, resp) = try await URLSession.shared.bytes(for: r) }
        catch {
            throw AIError(errorDescription: p.isLocal ? "Couldn't reach \(p.name). Check that it's running, then try again." : error.localizedDescription)
        }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            var t = ""; for try await l in bytes.lines { t += l; if t.count > 500 { break } }
            throw AIError(errorDescription: "\(p.name) returned \(code). \(t.prefix(300))")
        }
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let json = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if json == "[DONE]" { break }
            if let t = parseStreamToken(json) { onToken(t) }
        }
    }
    static func complete(system: String, prompt: String) async throws -> String {
        var s = ""
        try await stream(system: system, messages: [ChatMsg(role: "user", text: prompt)]) { s += $0 }
        return s
    }
}
/// Reads one SSE chunk from either wire format (OpenAI-compatible or Anthropic).
func parseStreamToken(_ json: String) -> String? {
    guard let o = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return nil }
    if let c = (o["choices"] as? [[String: Any]])?.first, let d = c["delta"] as? [String: Any] { return d["content"] as? String }
    if o["type"] as? String == "content_block_delta", let d = o["delta"] as? [String: Any] { return d["text"] as? String }
    return nil
}
/// Pulls the JSON object out of a model reply that may include prose or code fences.
func extractJSON<T: Decodable>(_ type: T.Type, from s: String) -> T? {
    guard let a = s.firstIndex(of: "{"), let b = s.lastIndex(of: "}"), a < b else { return nil }
    return try? JSONDecoder().decode(T.self, from: Data(s[a...b].utf8))
}

// MARK: - Coach

struct PlanDraft: Decodable { var summary: String?; var changes: [PlanChange] }
struct PlanChange: Decodable, Identifiable {
    var id = UUID()
    var action: String         // add | move | remove
    var title: String
    var goal: String?
    var blockId: String?
    var day: String?           // yyyy-MM-dd
    var start: String?         // HH:mm
    var minutes: Int?
    var reason: String?
    var keep = true
    enum CodingKeys: String, CodingKey { case action, title, goal, blockId, day, start, minutes, reason }
}
struct GoalReview: Decodable { struct R: Decodable { var goal: String; var status: String; var assessment: String; var fix: String }; var reviews: [R] }
struct Extracted: Decodable {
    struct G: Decodable { var title: String; var why: String?; var metric: String?; var weeklyHours: Double? }
    struct T: Decodable { var title: String; var goal: String? }
    var compass: String?; var goals: [G]?; var tasks: [T]?
}

/// What the AI may do from chat. Sent back only when asked, so plain answers cost nothing extra.
struct AIActions: Decodable {
    struct Note: Decodable { var title: String; var body: String }
    var changes: [PlanChange]?; var tasks: [Extracted.T]?; var notes: [Note]?
    var lines: [String] {
        (changes ?? []).map { "\($0.action.capitalized) \($0.title)\($0.day.map { " · \($0)" } ?? "")\($0.start.map { " \($0)" } ?? "")" }
            + (tasks ?? []).map { "New task: \($0.title)" } + (notes ?? []).map { "New note: \($0.title)" }
    }
}

@MainActor enum Coach {
    static let actionGuide = """
    You can act on the person's schedule. Only when they ask you to change, plan, reschedule, add or create something, end your reply with one block:
    <actions>{"changes":[{"action":"add|move|remove","title":"...","goal":"exact goal title or null","blockId":"id for move/remove","day":"yyyy-MM-dd","start":"HH:mm","minutes":60}],"tasks":[{"title":"...","goal":"..."}],"notes":[{"title":"...","body":"markdown"}]}</actions>
    Omit empty keys. Start times on the hour. Never overlap events. Keep the prose before it to one or two sentences; they will review and apply it.
    """
    /// Splits a reply into what to show and the actions it carries.
    static func split(_ text: String) -> (String, AIActions?) {
        guard let a = text.range(of: "<actions>") else { return (text, nil) }
        let rest = text[a.upperBound...], b = rest.range(of: "</actions>")
        let json = String(b.map { rest[..<$0.lowerBound] } ?? rest)
        return (String(text[..<a.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines), b == nil ? nil : extractJSON(AIActions.self, from: json))
    }
    static func perform(_ x: AIActions) {
        let s = Store.shared
        apply(x.changes ?? [])
        for t in x.tasks ?? [] { s.addTask(t.title, goal: s.goals.first { $0.title == t.goal }?.id) }
        for n in x.notes ?? [] { s.data.captures.insert(Capture(title: n.title, source: "AI", text: n.body), at: 0) }
    }
    static let persona = """
    You are the Bearing coach: a direct but kind productivity coach. Name problems plainly, propose one specific change, and ask for approval. \
    Principles: Goal, Plan, System: productivity means moving toward goals that matter, enjoyably and efficiently. Fewer goals, done better; \
    help the person choose what to drop, because trying to do everything is impossible. Turn intentions into time on the calendar \
    ("I will do X at time Y"). Protect deep work. Make work more enjoyable where possible. Use the person's real data below; never invent facts about them. Keep replies short.
    """
    static var context: String {
        let s = Store.shared, d = s.data, now = Date()
        var o = "Today is \(now.formatted(date: .complete, time: .shortened)).\nCompass (what matters most): \(d.compass.isEmpty ? "not set" : d.compass)\n"
        o += "Season \"\(d.seasonName)\": day \(s.seasonDay) of \(d.seasonWeeks * 7).\nGoals:\n"
        for g in s.goals {
            o += "- [\(g.tier.rawValue)] \(g.title) | why: \(g.why) | done when: \(g.metric) | target \(g.weeklyHours)h/week | planned this week \(String(format: "%.1f", s.plannedHours(goal: g.id)))h | focused this week \(hm(s.focused(goal: g.id, since: now.startOfWeek))) | plan strength \(s.planStrength(g)) | notes: \(g.notes.prefix(200))\n"
        }
        if let qa = d.seasonQA, !qa.isEmpty { o += "Season setup answers:\n"; for x in qa { o += "- \(x.q) \(x.a)\n" } }
        o += loopContext
        o += accountContext
        o += "Open tasks:\n"
        for t in d.tasks.filter({ !$0.done }).sorted(by: { $0.priority > $1.priority }).prefix(40) {
            o += "- \(t.title)\(s.goal(t.goalID).map { " [goal: \($0.title)]" } ?? "")\(t.due.map { " due \($0.dayKey)" } ?? "")\n"
        }
        o += "Blocks this week (id | start | minutes | title):\n"
        let st = now.startOfWeek, en = st.adding(days: 7)
        for b in d.blocks.filter({ $0.start >= st && $0.start < en }).sorted(by: { $0.start < $1.start }) {
            o += "- \(b.id.uuidString) | \(b.start.formatted(.iso8601)) | \(Int(b.end.timeIntervalSince(b.start) / 60)) | \(b.title)\n"
        }
        o += "Other calendar events:\n"
        for e in CalendarService.shared.events(from: st, to: en).filter({ !$0.allDay }).prefix(40) { o += "- \(e.start.formatted(.iso8601)) to \(e.end.clock): \(e.title)\n" }
        if d.prefs.coachReadsJournal {
            let j = d.journal.sorted { $0.id > $1.id }.prefix(5).filter { !$0.text.isEmpty }
            if !j.isEmpty { o += "Recent journal:\n"; for e in j { o += "\(e.id): \(e.text.prefix(500))\n" } }
        }
        let c = d.captures.sorted { $0.date > $1.date }.prefix(5)
        if !c.isEmpty { o += "Recent notes and brain dumps:\n"; for e in c { o += "\(e.date.dayKey) \(e.title): \(e.text.prefix(800))\n" } }
        return o
    }
    static var system: String { persona + "\n\n" + context }

    static func draftWeek() async throws -> PlanDraft {
        let p = """
        Draft my week. Reply with JSON only: {"summary":"one sentence","changes":[{"action":"add|move|remove","title":"...","goal":"exact goal title or null","blockId":"block id for move or remove","day":"yyyy-MM-dd","start":"HH:mm","minutes":60,"reason":"short"}]}. \
        Plan from now until the end of this week. Give each goal its weekly target, most important goal first, in the morning where possible. Never overlap existing events or blocks. Use open tasks as block titles where they fit.
        """
        let r = try await AI.complete(system: system, prompt: p)
        guard let d = extractJSON(PlanDraft.self, from: r) else { throw AIError(errorDescription: "The model didn't return a usable plan. Try again, or choose a stronger model.") }
        return d
    }
    static func apply(_ changes: [PlanChange]) {
        let s = Store.shared
        for c in changes where c.keep {
            let old = c.blockId.flatMap(UUID.init(uuidString:)).flatMap { id in s.data.blocks.first { $0.id == id } }
            if c.action == "remove" { if let old { s.deleteBlock(old) }; continue }
            guard let day = c.day, let st = c.start, let start = parseTodoistDate(day + "T" + st + ":00") else { continue }
            let mins = Double(c.minutes ?? 60) * 60
            if c.action == "move", var b = old { b.start = start; b.end = start.addingTimeInterval(mins); s.updateBlock(b) }
            else if c.action == "add" {
                let task = s.data.tasks.first { !$0.done && $0.title == c.title }
                let goal = s.goals.first { $0.title == c.goal }?.id ?? task?.goalID
                s.addBlock(Block(title: c.title, start: start, end: start.addingTimeInterval(mins), goalID: goal, taskID: task?.id))
            }
        }
    }
    static func reviewGoals() async throws {
        let p = """
        Review each goal against the season timeline and this week's time. Reply with JSON only: {"reviews":[{"goal":"exact title","status":"onTrack|adjust|offTrack","assessment":"one sentence","fix":"one specific change"}]}
        """
        let r = try await AI.complete(system: system, prompt: p)
        guard let d = extractJSON(GoalReview.self, from: r) else { throw AIError(errorDescription: "The model didn't return a usable review. Try again.") }
        let s = Store.shared
        for v in d.reviews { if let i = s.data.goals.firstIndex(where: { $0.title == v.goal }) {
            s.data.goals[i].status = GoalStatus(rawValue: v.status) ?? .adjust
            s.data.goals[i].coachNote = v.assessment + " " + v.fix
        } }
    }
    /// Turns a conversation or brain dump into goals and tasks.
    static func extract(from text: String) async throws -> Extracted {
        let p = """
        From the text below, extract only what the person clearly stated. Reply with JSON only: {"compass":"one sentence or null","goals":[{"title":"","why":"","metric":"","weeklyHours":5}],"tasks":[{"title":"","goal":"goal title or null"}]}. Maximum 3 goals.\n\nTEXT:\n\(text)
        """
        let r = try await AI.complete(system: persona, prompt: p)
        guard let e = extractJSON(Extracted.self, from: r) else { throw AIError(errorDescription: "The model didn't return usable goals. Try again.") }
        return e
    }
    static func adopt(_ e: Extracted) {
        let s = Store.shared
        if let c = e.compass, !c.isEmpty, s.data.compass.isEmpty { s.data.compass = c }
        for g in e.goals ?? [] where !s.data.goals.contains(where: { $0.title == g.title }) {
            s.data.goals.append(Goal(title: g.title, why: g.why ?? "", metric: g.metric ?? "", color: s.data.goals.count, weeklyHours: g.weeklyHours ?? 5))
        }
        for t in e.tasks ?? [] where !s.data.tasks.contains(where: { $0.title == t.title }) {
            s.addTask(t.title, goal: s.data.goals.first { $0.title == t.goal }?.id)
        }
    }
}
