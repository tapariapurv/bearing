#if os(macOS)
import SwiftUI
import Network
import AppKit

/// MCP server for AI agents: JSON-RPC over HTTP on 127.0.0.1, bearer token, per-scope permissions.
/// The local switch and token live in UserDefaults (this Mac only). Permissions and the remote key live in
/// Prefs, so they sync and the hosted server (web/api/mcp.js) obeys the same choices.
@Observable @MainActor final class Agents {
    static let shared = Agents()
    static let port: UInt16 = 7319
    static let remoteURL = "https://bearing-planner.vercel.app/api/mcp"
    enum Mode: String, CaseIterable { case off, ask, allow
        var title: String { switch self { case .off: "Off"; case .ask: "Ask each time"; case .allow: "Allow" } }
    }
    struct Scope { let key, title, detail: String; let fallback: Mode }
    static let scopes = [
        Scope(key: "read", title: "Read", detail: "Tasks, goals, classes, schedule, journal, focus stats, search", fallback: .allow),
        Scope(key: "write", title: "Write", detail: "Add tasks, classes, projects, time blocks and journal notes", fallback: .ask),
        Scope(key: "edit", title: "Edit", detail: "Change or complete tasks, rename classes, update goals", fallback: .ask),
        Scope(key: "delete", title: "Delete", detail: "Remove tasks, classes, projects and time blocks", fallback: .ask),
    ]
    struct Entry: Identifiable { let id = UUID(); let date = Date(); let agent, tool, result: String }
    var log: [Entry] = []
    private var listener: NWListener?
    private let ud = UserDefaults.standard

    var enabled: Bool { get { access(keyPath: \.log); return ud.bool(forKey: "mcp.on") } set { ud.set(newValue, forKey: "mcp.on"); newValue ? start() : stop() } }
    var token: String {
        if let t = ud.string(forKey: "mcp.token") { return t }
        let t = UUID().uuidString + UUID().uuidString; ud.set(t, forKey: "mcp.token"); return t
    }
    func rotate() { ud.removeObject(forKey: "mcp.token"); _ = token; log.insert(Entry(agent: "You", tool: "New token", result: "old token revoked"), at: 0) }
    func mode(_ s: String) -> Mode { Store.shared.data.prefs.agentAccess?[s].flatMap(Mode.init) ?? Self.scopes.first { $0.key == s }?.fallback ?? .off }
    func setMode(_ s: String, _ m: Mode) { Store.shared.data.prefs.agentAccess = (Store.shared.data.prefs.agentAccess ?? [:]).merging([s: m.rawValue]) { $1 } }
    var command: String { "claude mcp add --transport http bearing http://127.0.0.1:\(Self.port)/mcp --header \"Authorization: Bearer \(token)\"" }
    /// Remote token: bk_<email, base64url>_<secret>. The server finds the account from it, then checks the secret.
    static let webURL = Web.url
    var remoteToken: String? { bearer(Store.shared.data.prefs.agentKey) }
    func bearer(_ key: String?) -> String? { Web.bearer(key) }
    static func newKey() -> String { Web.newKey() }
    func newRemoteKey() { Store.shared.data.prefs.agentKey = Self.newKey(); Task { await Sync.push() } }
    func openWeb() { // the token rides in the URL fragment, which the browser never sends to a server
        if Store.shared.data.prefs.webKey == nil { Store.shared.data.prefs.webKey = Self.newKey() }
        let t = bearer(Store.shared.data.prefs.webKey) ?? ""
        Task { await Sync.push(); NSWorkspace.shared.open(URL(string: "\(Self.webURL)/#t=\(t)")!) }
    }
    var remoteCommand: String { "claude mcp add --transport http bearing \(Self.remoteURL) --header \"Authorization: Bearer \(remoteToken ?? "")\"" }

    func start() {
        guard listener == nil, enabled, !Store.isTesting,
              let l = try? NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: Self.port)!) else { return }
        l.newConnectionHandler = { c in
            // Loopback only: refuse anything that did not come from this Mac.
            if case .hostPort(let h, _) = c.endpoint, !"\(h)".hasPrefix("127.0.0.1"), !"\(h)".hasPrefix("::1") { c.cancel(); return }
            c.start(queue: .main); Agents.read(c, Data())
        }
        l.start(queue: .main); listener = l
    }
    func stop() { listener?.cancel(); listener = nil }

    // MARK: HTTP
    nonisolated private static func read(_ c: NWConnection, _ buf: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { d, _, done, err in
            var buf = buf; if let d { buf.append(d) }
            guard let end = buf.range(of: Data("\r\n\r\n".utf8)) else { if done || err != nil || buf.count > 1 << 20 { c.cancel() } else { read(c, buf) }; return }
            let head = String(decoding: buf[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
            var h: [String: String] = [:]
            for l in head.dropFirst() { if let i = l.firstIndex(of: ":") { h[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces) } }
            let body = buf[end.upperBound...], need = Int(h["content-length"] ?? "0") ?? 0
            if body.count < need { if done { c.cancel() } else { read(c, buf) }; return }
            let req = head.first ?? "", payload = Data(body.prefix(need)), auth = h["authorization"] ?? ""
            Task { @MainActor in
                let (code, out) = await Agents.shared.handle(req, auth: auth, body: payload)
                let msg = ["200": "OK", "202": "Accepted", "401": "Unauthorized", "404": "Not Found", "405": "Method Not Allowed"]["\(code)"] ?? "OK"
                var r = Data("HTTP/1.1 \(code) \(msg)\r\nContent-Type: application/json\r\nContent-Length: \(out.count)\r\nConnection: close\r\n\r\n".utf8); r.append(out)
                c.send(content: r, completion: .contentProcessed { _ in c.cancel() })
            }
        }
    }
    private var agentName = "Agent"
    func handle(_ request: String, auth: String, body: Data) async -> (Int, Data) {
        guard request.hasPrefix("POST /mcp") else { return request.hasPrefix("GET /mcp") ? (405, Data()) : (404, Data()) }
        guard enabled, auth == "Bearer " + token else { return (401, Data(#"{"error":"Bad or missing token. Copy it from Bearing › Settings › Agents."}"#.utf8)) }
        guard let m = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return (200, Self.json(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])) }
        guard let id = m["id"] else { return (202, Data()) }   // notification
        let p = m["params"] as? [String: Any] ?? [:]
        let result: Any
        switch m["method"] as? String ?? "" {
        case "initialize":
            agentName = (p["clientInfo"] as? [String: Any])?["name"] as? String ?? "Agent"
            result = ["protocolVersion": p["protocolVersion"] as? String ?? "2025-06-18", "capabilities": ["tools": [:]],
                      "serverInfo": ["name": "bearing", "version": "1.9.0"],
                      "instructions": "Bearing is the user's planner. Call get_overview first. Tasks belong to a class (optionally a sub-project inside it), a standalone project, or a season goal. Name classes, projects and goals by name. Dates are local: YYYY-MM-DD, times YYYY-MM-DDTHH:MM."]
        case "ping": result = [:]
        case "tools/list": result = ["tools": Self.tools.filter { mode($0.scope) != .off }.map(\.spec)]
        case "tools/call": result = await call(p["name"] as? String ?? "", p["arguments"] as? [String: Any] ?? [:])
        default: return (200, Self.json(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found"]]))
        }
        return (200, Self.json(["jsonrpc": "2.0", "id": id, "result": result]))
    }
    static func json(_ o: Any) -> Data { (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])) ?? Data() }

    // MARK: Tools
    struct Tool { let name, scope, about: String; let props: [String: [String: Any]]; let required: [String]
        var spec: [String: Any] { ["name": name, "description": about, "inputSchema": ["type": "object", "properties": props, "required": required]] }
    }
    private static func s(_ d: String) -> [String: Any] { ["type": "string", "description": d] }
    static let tools: [Tool] = [
        Tool(name: "get_overview", scope: "read", about: "The system in use, season goals, classes with their sub-projects, projects, and open task counts.", props: [:], required: []),
        Tool(name: "list_tasks", scope: "read", about: "List tasks, open ones by default.", props: [
            "area": s("Class or project name"), "sub_project": s("Sub-project name"), "goal": s("Goal title"), "query": s("Text in the title"),
            "due_before": s("YYYY-MM-DD, inclusive"), "include_done": ["type": "boolean"]], required: []),
        Tool(name: "get_schedule", scope: "read", about: "Time blocks (with ids) and calendar events, day by day.", props: ["date": s("YYYY-MM-DD, default today"), "days": ["type": "integer", "description": "1 to 14, default 1"]], required: []),
        Tool(name: "get_task", scope: "read", about: "One task with every field.", props: ["id": s("Task id")], required: ["id"]),
        Tool(name: "list_goals", scope: "read", about: "Season goals with why, metric, weekly hour target, status, notes and hours focused in the last 7 days.", props: [:], required: []),
        Tool(name: "get_journal", scope: "read", about: "Journal entries between two dates.", props: ["from": s("YYYY-MM-DD, default 7 days ago"), "to": s("YYYY-MM-DD, default today")], required: []),
        Tool(name: "get_focus_stats", scope: "read", about: "Focus sessions: hours, count, quality and distractions, per goal.", props: ["days": ["type": "integer", "description": "Look back this many days, default 7"]], required: []),
        Tool(name: "search", scope: "read", about: "Search tasks, goals, classes, projects and the journal.", props: ["query": s("Words to find")], required: ["query"]),
        Tool(name: "write_journal", scope: "write", about: "Add to (or replace) a day's journal entry.", props: ["text": s("Text"), "date": s("YYYY-MM-DD, default today"), "replace": ["type": "boolean"]], required: ["text"]),
        Tool(name: "update_area", scope: "edit", about: "Rename a class or project, switch its kind, or link it to a goal (empty goal unlinks).", props: ["name": s("Current name"), "new_name": s(""), "kind": ["type": "string", "enum": ["class", "project"]], "goal": s("Goal title")], required: ["name"]),
        Tool(name: "update_goal", scope: "edit", about: "Change a goal's fields.", props: ["title": s("Current title"), "new_title": s(""), "why": s(""), "metric": s(""), "notes": s("Next actions"),
            "status": ["type": "string", "enum": ["none", "onTrack", "adjust", "offTrack"]], "weekly_hours": ["type": "number"]], required: ["title"]),
        Tool(name: "delete_block", scope: "delete", about: "Remove a time block.", props: ["id": s("Block id from get_schedule")], required: ["id"]),
        Tool(name: "add_task", scope: "write", about: "Add a task. It syncs to Todoist tagged with its class/project and sub-project.", props: [
            "title": s("Task title"), "area": s("Class or project name"), "sub_project": s("Sub-project inside the class"), "goal": s("Goal title"),
            "due": s("YYYY-MM-DD"), "priority": ["type": "integer", "description": "1 normal to 4 urgent"], "notes": s("Details"),
            "resources": ["type": "array", "items": ["type": "string"], "description": "Links, Google Drive links or file paths"]], required: ["title"]),
        Tool(name: "update_task", scope: "edit", about: "Change a task. Only the fields you pass change; pass an empty string to clear due or sub_project.", props: [
            "id": s("Task id"), "title": s(""), "area": s("Class or project name"), "sub_project": s(""), "goal": s("Goal title"), "due": s("YYYY-MM-DD"),
            "priority": ["type": "integer"], "notes": s(""), "add_resources": ["type": "array", "items": ["type": "string"]]], required: ["id"]),
        Tool(name: "complete_task", scope: "edit", about: "Mark a task done (or not done with done=false).", props: ["id": s("Task id"), "done": ["type": "boolean"]], required: ["id"]),
        Tool(name: "delete_task", scope: "delete", about: "Delete a task.", props: ["id": s("Task id")], required: ["id"]),
        Tool(name: "add_area", scope: "write", about: "Create a class or a standalone project.", props: [
            "name": s("Name"), "kind": ["type": "string", "enum": ["class", "project"]], "goal": s("Optional season goal it serves")], required: ["name", "kind"]),
        Tool(name: "add_sub_project", scope: "write", about: "Create a sub-project inside a class.", props: ["class": s("Class name"), "name": s("Sub-project name")], required: ["class", "name"]),
        Tool(name: "delete_area", scope: "delete", about: "Remove a class or project. Its tasks stay, unsorted.", props: ["name": s("Class or project name")], required: ["name"]),
        Tool(name: "time_block", scope: "write", about: "Block time on the calendar for a task.", props: [
            "id": s("Task id"), "start": s("YYYY-MM-DDTHH:MM; default the next free slot"), "minutes": ["type": "integer"]], required: ["id"]),
    ]

    private func call(_ name: String, _ a: [String: Any]) async -> [String: Any] {
        func reply(_ text: String, error: Bool = false) -> [String: Any] {
            log.insert(Entry(agent: agentName, tool: name, result: error ? "✕ " + text.prefix(80) : "✓"), at: 0); log = Array(log.prefix(100))
            return ["content": [["type": "text", "text": text]], "isError": error]
        }
        guard let tool = Self.tools.first(where: { $0.name == name }) else { return reply("Unknown tool \(name)", error: true) }
        switch mode(tool.scope) {
        case .off: return reply("The user has turned off \(tool.scope) access for agents in Bearing › Settings › Agents.", error: true)
        case .ask: if !confirm(tool, a) { return reply("The user declined this request.", error: true) }
        case .allow: break
        }
        do { return reply(try run(name, a)) } catch { return reply("\(error)", error: true) }
    }
    private func confirm(_ t: Tool, _ a: [String: Any]) -> Bool {
        NSApp.activate()
        let al = NSAlert()
        al.messageText = "\(agentName) wants to \(t.name.replacingOccurrences(of: "_", with: " "))"
        al.informativeText = a.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
        al.addButton(withTitle: "Allow"); al.addButton(withTitle: "Deny")
        al.showsSuppressionButton = true; al.suppressionButton?.title = "Always allow \(t.scope) for agents"
        let ok = al.runModal() == .alertFirstButtonReturn
        if ok, al.suppressionButton?.state == .on { setMode(t.scope, .allow) }
        return ok
    }

    struct Fail: Error, CustomStringConvertible { let description: String }
    private func run(_ name: String, _ a: [String: Any]) throws -> String {
        let st = Store.shared
        func str(_ k: String) -> String? { (a[k] as? String).map { $0.trimmingCharacters(in: .whitespaces) } }
        func area(_ n: String) throws -> Area { guard let x = st.data.areas?.first(where: { $0.name.caseInsensitiveCompare(n) == .orderedSame || $0.id.uuidString == n }) else { throw Fail(description: "No class or project named \(n). Call get_overview for names.") }; return x }
        func goal(_ n: String) throws -> Goal { guard let g = st.goals.first(where: { $0.title.caseInsensitiveCompare(n) == .orderedSame || $0.id.uuidString == n }) else { throw Fail(description: "No goal named \(n).") }; return g }
        func task() throws -> TaskItem { guard let t = st.data.tasks.first(where: { $0.id.uuidString == str("id") }) else { throw Fail(description: "No task with that id.") }; return t }
        func day(_ s: String?) throws -> Date? { guard let s, !s.isEmpty else { return nil }; let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; guard let d = f.date(from: s) else { throw Fail(description: "Use YYYY-MM-DD, got \(s)") }; return d }
        func out(_ o: Any) -> String { String(decoding: Self.json(o), as: UTF8.self) }
        func row(_ t: TaskItem) -> [String: Any] {
            var r: [String: Any] = ["id": t.id.uuidString, "title": t.title, "done": t.done, "priority": t.priority]
            if let d = t.due { r["due"] = d.dayKey }
            if let x = st.data.areas?.first(where: { $0.id == t.areaID }) { r["area"] = x.name; r["kind"] = x.isClass ? "class" : "project" }
            if let s = t.sub { r["sub_project"] = s }
            if let g = st.goal(t.goalID) { r["goal"] = g.title }
            if !t.notes.isEmpty { r["notes"] = t.notes }
            if let x = t.resources, !x.isEmpty { r["resources"] = x }
            return r
        }
        switch name {
        case "get_overview":
            let open = st.data.tasks.filter { !$0.done }
            func ar(_ x: Area) -> [String: Any] {
                var r: [String: Any] = ["name": x.name, "goal": st.goal(x.goal)?.title ?? ""]
                r["open_tasks"] = open.filter { $0.areaID == x.id }.count
                if x.isClass { r["sub_projects"] = x.subs ?? [] }
                return r
            }
            let goals: [[String: Any]] = st.goals.map { g in ["title": g.title, "open_tasks": open.filter { $0.goalID == g.id }.count] }
            let areas = st.data.areas ?? []
            return out(["system": (st.data.prefs.system ?? .gps).rawValue, "goals": goals, "today": Date().dayKey,
                        "classes": areas.filter(\.isClass).map(ar), "projects": areas.filter { !$0.isClass }.map(ar)])
        case "list_tasks":
            let ar = try str("area").map(area), g = try str("goal").map(goal), q = str("query")?.lowercased(), sub = str("sub_project")
            let end = try day(str("due_before"))?.adding(days: 1), all = a["include_done"] as? Bool == true
            let l = st.data.tasks.filter { t in
                guard all || !t.done, ar == nil || t.areaID == ar?.id, sub == nil || t.sub == sub, g == nil || t.goalID == g?.id else { return false }
                if let end { guard let d = t.due, d < end else { return false } }
                return q == nil || t.title.lowercased().contains(q!)
            }
            return out(l.prefix(200).map(row))
        case "get_schedule":
            let d = (try day(str("date")) ?? Date()).startOfDay, e = d.adding(days: min(14, max(1, a["days"] as? Int ?? 1)))
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"
            let b = st.data.blocks.filter { $0.start < e && $0.end > d }.map { ["id": $0.id.uuidString, "title": $0.title, "start": f.string(from: $0.start), "end": f.string(from: $0.end), "kind": "block"] }
            let ev = CalendarService.shared.events(from: d, to: e).map { ["title": $0.title, "start": f.string(from: $0.start), "end": f.string(from: $0.end), "kind": "event"] }
            return out((b + ev).sorted { $0["start"]! < $1["start"]! })
        case "get_task": return out(row(try task()))
        case "list_goals":
            let wk = Date().adding(days: -7)
            return out(st.goals.map { g -> [String: Any] in
                ["title": g.title, "why": g.why, "metric": g.metric, "weekly_hours": g.weeklyHours, "tier": g.tier.rawValue, "status": g.status.rawValue, "notes": g.notes,
                 "focused_hours_7d": (st.focused(goal: g.id, since: wk) / 360).rounded() / 10, "open_tasks": st.data.tasks.filter { $0.goalID == g.id && !$0.done }.count]
            })
        case "get_journal":
            let to = try day(str("to"))?.dayKey ?? Date().dayKey, from = try day(str("from"))?.dayKey ?? Date().adding(days: -7).dayKey
            return out(st.data.journal.filter { $0.id >= from && $0.id <= to }.sorted { $0.id < $1.id }.map { ["date": $0.id, "prompt": $0.prompt, "text": $0.text] })
        case "get_focus_stats":
            let since = Date().adding(days: -(a["days"] as? Int ?? 7)), ss = st.data.sessions.filter { $0.start >= since }
            func sum(_ l: [Session]) -> [String: Any] {
                ["hours": (l.reduce(0) { $0 + $1.seconds } / 360).rounded() / 10, "sessions": l.count, "distractions": l.reduce(0) { $0 + $1.distractions },
                 "avg_quality": l.isEmpty ? 0 : l.reduce(0) { $0 + $1.quality } / l.count]
            }
            var per: [String: Any] = [:]
            for g in Set(ss.map(\.goalID)) { per[st.goal(g)?.title ?? "No goal"] = sum(ss.filter { $0.goalID == g }) }
            return out(["total": sum(ss), "by_goal": per])
        case "search":
            guard let q = str("query")?.lowercased(), !q.isEmpty else { throw Fail(description: "query is required") }
            return out(["tasks": st.data.tasks.filter { "\($0.title) \($0.notes)".lowercased().contains(q) }.prefix(50).map(row),
                        "goals": st.goals.filter { "\($0.title) \($0.why) \($0.notes)".lowercased().contains(q) }.map(\.title),
                        "areas": (st.data.areas ?? []).filter { "\($0.name) \(($0.subs ?? []).joined(separator: " "))".lowercased().contains(q) }.map(\.name),
                        "journal": st.data.journal.filter { $0.text.lowercased().contains(q) }.map { ["date": $0.id, "text": String($0.text.prefix(300))] }])
        case "write_journal":
            guard let tx = str("text"), !tx.isEmpty else { throw Fail(description: "text is required") }
            let k = try day(str("date"))?.dayKey ?? Date().dayKey
            if let i = st.data.journal.firstIndex(where: { $0.id == k }) { st.data.journal[i].text = a["replace"] as? Bool == true ? tx : [st.data.journal[i].text, tx].filter { !$0.isEmpty }.joined(separator: "\n\n") }
            else { st.data.journal.append(JournalEntry(id: k, text: tx)) }
            return "Saved the journal for \(k)"
        case "update_area":
            let x = try area(str("name") ?? ""), i = st.data.areas!.firstIndex { $0.id == x.id }!
            if let n = str("new_name"), !n.isEmpty { st.data.areas![i].name = n }
            if let k = str("kind") { st.data.areas![i].isClass = k != "project"; if k == "project" { st.data.areas![i].subs = nil } }
            if let g = str("goal") { st.link(area: x.id, goal: g.isEmpty ? nil : try goal(g).id) }
            return "Updated \(st.data.areas![i].name)"
        case "update_goal":
            let g = try goal(str("title") ?? ""), i = st.data.goals.firstIndex { $0.id == g.id }!
            if let v = str("new_title"), !v.isEmpty { st.data.goals[i].title = v }
            if let v = str("why") { st.data.goals[i].why = v }
            if let v = str("metric") { st.data.goals[i].metric = v }
            if let v = str("notes") { st.data.goals[i].notes = v }
            if let v = str("status") { guard let s = GoalStatus(rawValue: v) else { throw Fail(description: "Unknown status") }; st.data.goals[i].status = s }
            if let v = a["weekly_hours"] as? Double { st.data.goals[i].weeklyHours = v }
            return "Updated \(st.data.goals[i].title)"
        case "delete_block":
            guard let b = st.data.blocks.first(where: { $0.id.uuidString == str("id") }) else { throw Fail(description: "No block with that id") }
            st.deleteBlock(b); return "Removed \(b.title)"
        case "add_task":
            guard let title = str("title"), !title.isEmpty else { throw Fail(description: "title is required") }
            let ar = try str("area").map(area), sub = str("sub_project").flatMap { $0.isEmpty ? nil : $0 }
            if sub != nil, ar?.isClass != true { throw Fail(description: "sub_project needs a class in area") }
            st.addTask(title, goal: try str("goal").map(goal)?.id, area: ar?.id, sub: sub, due: try day(str("due")))
            var t = st.data.tasks[0]
            if let p = a["priority"] as? Int { t.priority = min(4, max(1, p)) }
            if let n = str("notes") { t.notes = n }
            if let r = a["resources"] as? [String] { t.resources = r }
            if t != st.data.tasks[0] { st.updateTask(t) }
            return out(row(t))
        case "update_task":
            var t = try task()
            if let v = str("title"), !v.isEmpty { t.title = v }
            if let v = str("area") { t.areaID = v.isEmpty ? nil : try area(v).id; if t.areaID == nil || st.data.areas?.first(where: { $0.id == t.areaID })?.isClass != true { t.sub = nil } }
            if let v = str("sub_project") { t.sub = v.isEmpty ? nil : v }
            if let v = str("goal") { t.goalID = v.isEmpty ? nil : try goal(v).id }
            if let v = str("due") { t.due = try day(v) }
            if let p = a["priority"] as? Int { t.priority = min(4, max(1, p)) }
            if let n = str("notes") { t.notes = n }
            if let r = a["add_resources"] as? [String] { t.resources = (t.resources ?? []) + r }
            st.updateTask(t); return out(row(t))
        case "complete_task":
            let t = try task(); if t.done != (a["done"] as? Bool ?? true) { st.toggleDone(t) }
            return out(row(st.data.tasks.first { $0.id == t.id }!))
        case "delete_task": let t = try task(); st.deleteTask(t); return "Deleted \(t.title)"
        case "add_area":
            guard let n = str("name"), !n.isEmpty else { throw Fail(description: "name is required") }
            if (try? area(n)) != nil { throw Fail(description: "\(n) already exists") }
            let x = Area(name: n, isClass: str("kind") != "project")
            st.data.areas = (st.data.areas ?? []) + [x]; if let g = try str("goal").map(goal) { st.link(area: x.id, goal: g.id) }; return "Added \(x.isClass ? "class" : "project") \(n)"
        case "add_sub_project":
            let x = try area(str("class") ?? ""); guard x.isClass else { throw Fail(description: "\(x.name) is a project; sub-projects live in classes") }
            guard let n = str("name"), !n.isEmpty else { throw Fail(description: "name is required") }
            let i = st.data.areas!.firstIndex { $0.id == x.id }!
            if !(st.data.areas![i].subs ?? []).contains(n) { st.data.areas![i].subs = (x.subs ?? []) + [n] }
            return "Added \(n) to \(x.name)"
        case "delete_area": let x = try area(str("name") ?? ""); st.data.areas?.removeAll { $0.id == x.id }; return "Removed \(x.name)"
        case "time_block":
            let t = try task(), m = a["minutes"] as? Int ?? st.data.prefs.blockLength
            var start = st.nextFreeSlot(minutes: m)
            if let s = str("start"), !s.isEmpty { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd'T'HH:mm"; guard let d = f.date(from: s) else { throw Fail(description: "Use YYYY-MM-DDTHH:MM") }; start = d }
            st.block(task: t, at: start, minutes: m)
            return "Block \(st.data.blocks.last!.id.uuidString): blocked \(m) min for \(t.title) at \(start.formatted(.dateTime.weekday().hour().minute()))"
        default: throw Fail(description: "Unknown tool")
        }
    }
}

struct AgentSettings: View {
    @State private var a = Agents.shared
    @State private var copied = false
    var body: some View {
        Section {
            Toggle("Let AI agents use Bearing", isOn: Binding(get: { a.enabled }, set: { a.enabled = $0 }))
        } footer: { Text("Runs an MCP server on this Mac only (127.0.0.1:\(Agents.port)). Agents need the token below.").font(.caption).foregroundStyle(.secondary) }
        if a.enabled {
            Section("Permissions") {
                ForEach(Agents.scopes, id: \.key) { s in
                    Picker(selection: Binding(get: { a.mode(s.key) }, set: { a.setMode(s.key, $0) })) { ForEach(Agents.Mode.allCases, id: \.self) { Text($0.title).tag($0) } }
                    label: { VStack(alignment: .leading) { Text(s.title); Text(s.detail).font(.caption).foregroundStyle(.secondary) } }
                }
            }
            Section("Connect") {
                Text(a.command).font(.system(.caption, design: .monospaced)).textSelection(.enabled).lineLimit(3)
                HStack {
                    Button(copied ? "Copied" : "Copy Claude Code Command") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(a.command, forType: .string); copied = true }
                    Button("Copy Token") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(a.token, forType: .string) }
                    Spacer()
                    Button("New Token", role: .destructive) { a.rotate(); copied = false }.help("Disconnects every agent using the old token")
                }
            }
            Section {
                if let t = a.remoteToken {
                    Text(a.remoteCommand).font(.system(.caption, design: .monospaced)).textSelection(.enabled).lineLimit(3)
                    HStack {
                        Button("Copy Remote Command") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(a.remoteCommand, forType: .string) }
                        Button("Copy URL and Token") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString("\(Agents.remoteURL)\nAuthorization: Bearer \(t)", forType: .string) }
                        Spacer()
                        Button("Turn Off", role: .destructive) { Store.shared.data.prefs.agentKey = nil; Task { await Sync.push() } }
                    }
                } else { Button("Turn On Remote Access") { a.newRemoteKey() }.disabled(Store.shared.data.prefs.profile?.email == nil) }
            } header: { Text("Remote") } footer: { Text("A hosted MCP server any device or server can reach. It follows the same permissions; \"Ask each time\" counts as Off there.").font(.caption).foregroundStyle(.secondary) }
            Section {
                HStack {
                    Button("Open Bearing on the Web") { a.openWeb() }.disabled(Store.shared.data.prefs.profile?.email == nil)
                    Spacer()
                    Button("Sign Out All Browsers", role: .destructive) { Store.shared.data.prefs.webKey = nil; Task { await Sync.push() } }
                }
            } header: { Text("Web") } footer: { Text("Signs this browser in to \(Agents.webURL). Works on any device; send the link to yourself to open it on another one.").font(.caption).foregroundStyle(.secondary) }
            Section("Activity") {
                if a.log.isEmpty { Text("No agent requests yet.").foregroundStyle(.secondary) }
                ForEach(a.log.prefix(20)) { e in
                    HStack { Text(e.agent).foregroundStyle(.secondary); Text(e.tool); Spacer(); Text(e.result).foregroundStyle(e.result.hasPrefix("✕") ? .red : .secondary).lineLimit(1); Text(e.date.clock).foregroundStyle(.tertiary) }.font(.caption)
                }
            }
        }
    }
}
#endif
