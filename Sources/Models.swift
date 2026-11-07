import SwiftUI
import Observation

// MARK: - Data

struct Goal: Codable, Identifiable, Hashable {
    var id = UUID()
    var title = ""
    var why = ""
    var metric = ""            // how you'll know it's done
    var color = 0
    var weeklyHours = 5.0
    var notes = ""             // brief next actions
    var status = GoalStatus.none
    var coachNote = ""
    var archived = false
}
enum GoalStatus: String, Codable { case none, onTrack, adjust, offTrack
    var label: String { switch self { case .none: "Not reviewed"; case .onTrack: "On track"; case .adjust: "Adjust"; case .offTrack: "Off track" } }
    var color: Color { switch self { case .none: .secondary; case .onTrack: goalPalette[4]; case .adjust: goalPalette[6]; case .offTrack: goalPalette[1] } }
}
struct TaskItem: Codable, Identifiable, Hashable {
    var id = UUID()
    var todoistID: String?
    var title = ""
    var notes = ""
    var project = ""
    var goalID: UUID?
    var due: Date?
    var priority = 1           // Todoist scale: 4 is P1
    var done = false
}
struct Block: Codable, Identifiable, Hashable {
    var id = UUID()
    var title = ""
    var start = Date()
    var end = Date()
    var goalID: UUID?
    var taskID: UUID?
    var eventID: String?       // macOS Calendar event
}
struct Session: Codable, Identifiable, Hashable {
    var id = UUID()
    var title = ""
    var goalID: UUID?
    var taskID: UUID?
    var start = Date()
    var seconds = 0.0
    var pausedSeconds = 0.0
    var distractions = 0
    var quality: Int { Self.quality(seconds: seconds, paused: pausedSeconds, distractions: distractions) }
    static func quality(seconds: Double, paused: Double, distractions: Int) -> Int {
        guard seconds > 0 else { return 0 }
        return max(0, Int((seconds / (seconds + paused) * 100).rounded()) - distractions * 5)
    }
}
struct JournalEntry: Codable, Identifiable, Hashable {
    var id: String             // yyyy-MM-dd
    var prompt = ""
    var text = ""
}
struct ChatMsg: Codable, Identifiable, Hashable {
    var id = UUID()
    var role: String           // user | assistant
    var text: String
}
struct Capture: Codable, Identifiable, Hashable {
    var id = UUID()
    var date = Date()
    var title = ""
    var source = "Voice"       // Voice | Notes
    var audioFile: String?
    var text = ""
    var followUps = ""
}
struct TodoistCommand: Codable, Hashable {
    var uuid = UUID().uuidString
    var type: String
    var tempID: String?
    var taskID: UUID?
    var args: [String: JSONValue]
}
enum JSONValue: Codable, Hashable {
    case string(String), int(Int), object([String: String]), null
    func encode(to e: Encoder) throws {
        var c = e.singleValueContainer()
        switch self { case .string(let s): try c.encode(s); case .int(let i): try c.encode(i); case .object(let o): try c.encode(o); case .null: try c.encodeNil() }
    }
    init(from d: Decoder) throws {
        let c = try d.singleValueContainer()
        if c.decodeNil() { self = .null } else if let i = try? c.decode(Int.self) { self = .int(i) }
        else if let s = try? c.decode(String.self) { self = .string(s) } else { self = .object(try c.decode([String: String].self)) }
    }
}
enum TimerMode: String, Codable, CaseIterable { case stopwatch = "Stopwatch", countdown = "Timer", pomodoro = "Pomodoro" }
enum MusicSource: String, Codable, CaseIterable { case library = "Library", folder = "My folder", spotify = "Spotify", appleMusic = "Apple Music", none = "Silence" }

struct Prefs: Codable {
    var provider = AIProvider.ollama
    var models: [String: String] = [:]
    var customURL = "http://localhost:8080/v1"
    var coachReadsJournal = true
    var calendarID: String?
    var eventGoals: [String: UUID] = [:]
    var blockSites = ["x.com", "twitter.com", "reddit.com", "youtube.com", "instagram.com", "facebook.com", "tiktok.com"]
    var blockApps: [String] = []
    var blockDuringFocus = false
    var exitDelay = 60
    var timerMode = TimerMode.pomodoro
    var countdownMinutes = 50
    var workMinutes = 25, breakMinutes = 5, longBreakMinutes = 15, cycles = 4
    var musicSource = MusicSource.library
    var musicCategory = "Lo-fi"
    var musicVolume = 0.6
    var musicFolder: String?
    var externalURI = ""
    var soundLevels: [String: Double] = [:]
    var playOnFocus = true
}
struct AppData: Codable {
    var compass = ""
    var seasonName = "This season"
    var seasonStart = Calendar.current.startOfDay(for: Date())
    var seasonWeeks = 12
    var goals: [Goal] = []
    var tasks: [TaskItem] = []
    var blocks: [Block] = []
    var sessions: [Session] = []
    var journal: [JournalEntry] = []
    var chat: [ChatMsg] = []
    var captures: [Capture] = []
    var todoistToken = false
    var syncToken = "*"
    var outbox: [TodoistCommand] = []
    var projects: [String: String] = [:]
    var prefs = Prefs()
}

extension Date {
    var dayKey: String { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX"); return f.string(from: self) }
    var startOfDay: Date { Calendar.current.startOfDay(for: self) }
    var startOfWeek: Date { Calendar.current.dateInterval(of: .weekOfYear, for: self)?.start ?? startOfDay }
    func adding(days: Int) -> Date { Calendar.current.date(byAdding: .day, value: days, to: self)! }
    var clock: String { formatted(date: .omitted, time: .shortened) }
}
func hm(_ seconds: Double) -> String {
    let m = Int(seconds / 60); return m < 60 ? "\(m)m" : "\(m / 60)h \(m % 60)m"
}
func dyn(_ l: UInt32, _ d: UInt32) -> Color {
    func c(_ v: UInt32) -> NSColor { NSColor(srgbRed: CGFloat(v >> 16 & 255) / 255, green: CGFloat(v >> 8 & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1) }
    return Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? c(d) : c(l) })
}
let goalPalette = [dyn(0x38BDF8, 0x7DD3FC), dyn(0xEF4444, 0xF87171), dyn(0x14B8A6, 0x2DD4BF), dyn(0xE5409F, 0xF472B6),
                   dyn(0x3FAE86, 0x4ADE9F), dyn(0x6366F1, 0x818CF8), dyn(0xF59E0B, 0xFBBF24), dyn(0x8B5CF6, 0xA78BFA)]
let goalColorNames = ["Sky", "Coral", "Teal", "Pink", "Green", "Indigo", "Amber", "Violet"]
func goalColor(_ i: Int) -> Color { goalPalette[abs(i) % 8] }
extension Color {
    /// Ink: black pills and selection, like a pen on white paper.
    static let brand = dyn(0x111114, 0xF4F4F5)
    static let page = dyn(0xFFFFFF, 0x161618)
    static let surface = dyn(0xFFFFFF, 0x1F2023)
    /// Soft fill behind colored content, and readable text to put on it.
    var wash: Color { opacity(0.16) }
    var ink: Color { mix(with: .primary, by: 0.4) }
}

// MARK: - Store

@Observable @MainActor final class Store {
    static let shared = Store()
    static let dir: URL = {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(isDemo ? "BearingDemo" : "Bearing")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()
    nonisolated static var isDemo: Bool { isTesting }
    nonisolated static var isTesting: Bool { CommandLine.arguments.contains("--snapshot") || CommandLine.arguments.contains("--selftest") || CommandLine.arguments.contains("--coachtest") }
    var data = AppData() { didSet { scheduleSave() } }
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    private var file: URL { Self.dir.appendingPathComponent("data.json") }

    init() {
        guard !Self.isTesting, let raw = try? Data(contentsOf: file) else { return }
        do { data = try Self.decoder.decode(AppData.self, from: raw) }
        catch { // Never overwrite data we couldn't read
            try? raw.write(to: Self.dir.appendingPathComponent("data-unreadable-\(Int(Date().timeIntervalSince1970)).json"))
        }
    }
    static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
    static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { try? await Task.sleep(for: .milliseconds(300)); if !Task.isCancelled { saveNow() } }
    }
    // ponytail: whole-file JSON save; move to SQLite if data ever reaches tens of MB
    func saveNow() { guard !Self.isTesting else { return }; if let d = try? Self.encoder.encode(data) { try? d.write(to: file, options: .atomic) } }

    // MARK: Queries
    var goals: [Goal] { data.goals.filter { !$0.archived } }
    func goal(_ id: UUID?) -> Goal? { data.goals.first { $0.id == id } }
    func task(_ id: UUID?) -> TaskItem? { data.tasks.first { $0.id == id } }
    var seasonEnd: Date { data.seasonStart.adding(days: data.seasonWeeks * 7) }
    var seasonDay: Int { min(data.seasonWeeks * 7, max(1, (Calendar.current.dateComponents([.day], from: data.seasonStart, to: Date()).day ?? 0) + 1)) }
    func blocks(on day: Date) -> [Block] { data.blocks.filter { Calendar.current.isDate($0.start, inSameDayAs: day) }.sorted { $0.start < $1.start } }
    func focused(goal: UUID?, since: Date) -> Double { data.sessions.filter { $0.goalID == goal && $0.start >= since }.reduce(0) { $0 + $1.seconds } }
    func plannedHours(goal: UUID, weekOf d: Date = Date()) -> Double {
        let s = d.startOfWeek, e = s.adding(days: 7)
        return data.blocks.filter { $0.goalID == goal && $0.start >= s && $0.start < e }.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) } / 3600
    }
    /// Plan strength: is this goal clear, has a next step, and does it have time on the calendar?
    func planStrength(_ g: Goal) -> Int {
        let open = data.tasks.contains { $0.goalID == g.id && !$0.done }
        return Self.planStrength(hasWhy: !g.why.isEmpty, hasMetric: !g.metric.isEmpty, hasNext: open || !g.notes.isEmpty, planned: plannedHours(goal: g.id), target: g.weeklyHours)
    }
    nonisolated static func planStrength(hasWhy: Bool, hasMetric: Bool, hasNext: Bool, planned: Double, target: Double) -> Int {
        let time = target > 0 ? min(1, planned / target) : 1
        return (hasWhy ? 15 : 0) + (hasMetric ? 15 : 0) + (hasNext ? 20 : 0) + Int((time * 50).rounded())
    }

    // MARK: Task mutations (each one queues a Todoist command)
    func addTask(_ title: String, goal: UUID? = nil) {
        var t = TaskItem(title: title, goalID: goal)
        if data.todoistToken {
            let temp = UUID().uuidString
            t.todoistID = temp
            data.outbox.append(TodoistCommand(type: "item_add", tempID: temp, taskID: t.id, args: ["content": .string(title)]))
        }
        data.tasks.insert(t, at: 0)
        Todoist.shared.nudge()
    }
    func updateTask(_ t: TaskItem) {
        guard let i = data.tasks.firstIndex(where: { $0.id == t.id }) else { return }
        let old = data.tasks[i]; data.tasks[i] = t
        guard let tid = t.todoistID else { return }
        var a: [String: JSONValue] = ["id": .string(tid)]
        if old.title != t.title { a["content"] = .string(t.title) }
        if old.notes != t.notes { a["description"] = .string(t.notes) }
        if old.priority != t.priority { a["priority"] = .int(t.priority) }
        if old.due != t.due { a["due"] = t.due.map { .object(["date": $0.dayKey]) } ?? .null }
        if a.count > 1 { data.outbox.append(TodoistCommand(type: "item_update", args: a)); Todoist.shared.nudge() }
    }
    func toggleDone(_ t: TaskItem) {
        guard let i = data.tasks.firstIndex(where: { $0.id == t.id }) else { return }
        data.tasks[i].done.toggle()
        if let tid = t.todoistID {
            data.outbox.append(TodoistCommand(type: data.tasks[i].done ? "item_close" : "item_uncomplete", args: ["id": .string(tid)]))
            Todoist.shared.nudge()
        }
    }
    func deleteTask(_ t: TaskItem) {
        data.tasks.removeAll { $0.id == t.id }
        if let tid = t.todoistID { data.outbox.append(TodoistCommand(type: "item_delete", args: ["id": .string(tid)])); Todoist.shared.nudge() }
    }

    // MARK: Blocks
    @discardableResult func addBlock(_ b: Block) -> Block {
        var b = b; b.eventID = CalendarService.shared.save(b); data.blocks.append(b); return b
    }
    func updateBlock(_ b: Block) {
        guard let i = data.blocks.firstIndex(where: { $0.id == b.id }) else { return }
        var b = b; b.eventID = CalendarService.shared.save(b); data.blocks[i] = b
    }
    func deleteBlock(_ b: Block) { CalendarService.shared.remove(b); data.blocks.removeAll { $0.id == b.id } }
    func block(task t: TaskItem, at start: Date, minutes: Int = 60) {
        addBlock(Block(title: t.title, start: start, end: start.addingTimeInterval(Double(minutes) * 60), goalID: t.goalID, taskID: t.id))
    }
    /// Next free slot today (or tomorrow morning) for one-click time blocking.
    func nextFreeSlot(minutes: Int = 60) -> Date {
        let cal = Calendar.current
        var t = cal.date(bySettingHour: cal.component(.hour, from: Date()) + 1, minute: 0, second: 0, of: Date()) ?? Date()
        let busy = data.blocks.map { ($0.start, $0.end) } + CalendarService.shared.events(from: Date(), to: Date().adding(days: 3)).map { ($0.start, $0.end) }
        for _ in 0..<96 {
            let h = cal.component(.hour, from: t)
            if h < 9 || h >= 19 { t = cal.date(bySettingHour: 9, minute: 0, second: 0, of: h < 9 ? t : t.adding(days: 1))!; continue }
            let e = t.addingTimeInterval(Double(minutes) * 60)
            if let clash = busy.first(where: { $0.0 < e && $0.1 > t }) { t = clash.1 } else { return t }
        }
        return t
    }
}
