import SwiftUI
import AVFoundation
import UserNotifications
import AppKit

enum Page: String, CaseIterable, Identifiable {
    case today = "Today", goals = "Goals", week = "Week", tasks = "Tasks", focus = "Focus", coach = "Coach", journal = "Journal", capture = "Capture", insights = "Insights"
    var id: String { rawValue }
    var icon: String { switch self {
        case .today: "sun.max"; case .goals: "scope"; case .week: "calendar"; case .tasks: "checklist"; case .focus: "timer"
        case .coach: "bubble.left.and.text.bubble.right"; case .journal: "book"; case .capture: "waveform"; case .insights: "chart.bar" } }
    var tint: Color { switch self {
        case .today: goalPalette[6]; case .goals: goalPalette[1]; case .week: goalPalette[0]; case .tasks: goalPalette[2]; case .focus: goalPalette[3]
        case .coach: goalPalette[7]; case .journal: goalPalette[4]; case .capture: goalPalette[5]; case .insights: goalPalette[0] } }
}
@Observable @MainActor final class Nav {
    static let shared = Nav()
    var page = Page.today
    var coachDraft = ""        // text waiting in the coach composer
    var seasonSetup = false
    var dailySync = false
    var reflect = false
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ n: Notification) {
        MainActor.assumeIsolated {
            let args = CommandLine.arguments
            if args.contains("--selftest") { selfTest(); return }
            if let i = args.firstIndex(of: "--transcribe"), i + 1 < args.count {
                let u = URL(fileURLWithPath: args[i + 1])
                Task { do { print(try await Voice.transcribe(u)); exit(0) } catch { print("ERROR", error); exit(1) } }
                return
            }
            if args.contains("--coachtest") { // live check against a running local model, on demo data
                Snapshot.demo()
                Task {
                    do {
                        let r = try await AI.complete(system: Coach.system, prompt: "In one sentence, what should I do first today?")
                        print("REPLY:", r)
                        let d = try await Coach.draftWeek()
                        print("PLAN:", d.changes.count, "changes;", d.summary ?? "")
                        try await Coach.reviewGoals()
                        for g in Store.shared.data.goals { print("GOAL:", g.title, g.status, g.coachNote) }
                        exit(0)
                    } catch { print("ERROR", error.localizedDescription); exit(1) }
                }
                return
            }
            if let i = args.firstIndex(of: "--snapshot"), i + 2 < args.count { Snapshot.run(dir: args[i + 1], dark: args[i + 2] == "dark"); return }
            Blocker.shared.clearStale()
            Todoist.shared.start()
            if GoogleCalendar.shared.connected { GoogleCalendar.shared.start() }
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
            if CalendarService.shared.granted { Task { await CalendarService.shared.request() } }
        }
    }
    func applicationWillTerminate(_ n: Notification) {
        MainActor.assumeIsolated {
            if Focus.shared.active { Focus.shared.finish() }
            Store.shared.saveNow()
        }
    }
    func applicationDidBecomeActive(_ n: Notification) { MainActor.assumeIsolated { if !Store.isTesting { Todoist.shared.nudge() } } }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { false } // the menu bar stays
}

@main struct BearingApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @State private var focus = Focus.shared
    var body: some Scene {
        Window("Bearing", id: "main") {
            RootView().frame(minWidth: 960, minHeight: 620)
        }
        .defaultSize(width: 1240, height: 800)
        .commands {
            CommandMenu("Go") {
                ForEach(Array(Page.allCases.enumerated()), id: \.element) { i, p in
                    Button(p.rawValue) { Nav.shared.page = p }.keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
                }
            }
            CommandMenu("Session") {
                Button(focus.active ? "End Session" : "Start Focus") { focus.active ? focus.requestStop() : focus.begin() }.keyboardShortcut("f", modifiers: [.command, .shift])
                Button(focus.paused ? "Resume" : "Pause") { focus.togglePause() }.keyboardShortcut("p", modifiers: [.command, .shift]).disabled(!focus.active)
            }
        }
        Settings { SettingsView().bearingStyle() }
        MenuBarExtra {
            MenuBarView().bearingStyle()
        } label: {
            if focus.active { Text(focus.display).monospacedDigit() } else { Image(systemName: "safari") }
        }
        .menuBarExtraStyle(.window)
    }
}

struct RootView: View {
    @State private var nav = Nav.shared
    @State private var store = Store.shared
    var body: some View {
        NavigationSplitView {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Page.allCases) { p in
                        SidebarRow(title: p.rawValue, selected: nav.page == p, action: { nav.page = p }) {
                            Image(systemName: p.icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                                .frame(width: 22, height: 22).background(p.tint, in: .rect(cornerRadius: 6))
                        }
                    }
                    let goals = store.goals, main = goals.filter { $0.tier != .support }, support = goals.filter { $0.tier == .support }
                    if !main.isEmpty {
                        Text("Goals").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 6).padding(.top, 14).padding(.bottom, 2)
                        ForEach(main) { goalRow($0) }
                    }
                    if !support.isEmpty {
                        Button { showSupport.toggle() } label: {
                            HStack(spacing: 4) { Text("Support areas"); Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).rotationEffect(.degrees(showSupport ? 90 : 0)) }
                                .font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 6).padding(.top, 14).padding(.bottom, 2).contentShape(.rect)
                        }.buttonStyle(.plain).accessibilityLabel(showSupport ? "Hide support areas" : "Show support areas")
                        if showSupport { ForEach(support) { goalRow($0) } }
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
        } detail: {
            PageView(page: nav.page).frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.page).navigationTitle(nav.page.rawValue)
        }
        .sheet(isPresented: $nav.seasonSetup) { SeasonSetup().bearingStyle() }
        .sheet(isPresented: $nav.dailySync) { DailySync().bearingStyle() }
        .sheet(isPresented: $nav.reflect) { ReflectView().bearingStyle() }
        .bearingStyle()
    }
    @State private var showSupport = true
    private func goalRow(_ g: Goal) -> some View {
        SidebarRow(title: g.title, selected: false, action: { nav.page = .goals }) { GoalIcon(goal: g) }
    }
}
struct PageView: View {
    let page: Page
    var body: some View {
        switch page {
        case .today: TodayPage(); case .goals: GoalsPage(); case .week: WeekPage(); case .tasks: TasksPage(); case .focus: FocusPage()
        case .coach: CoachPage(); case .journal: JournalPage(); case .capture: CapturePage(); case .insights: InsightsPage()
        }
    }
}

// MARK: - Menu bar

enum QuickKind: String, CaseIterable {
    case task = "Task", note = "Note", journal = "Journal"
    var icon: String { switch self { case .task: "checkmark.circle"; case .note: "note.text"; case .journal: "book.closed" } }
    var prompt: String { switch self { case .task: "Add a task"; case .note: "Jot a note"; case .journal: "Add to today's journal" } }
}
extension Store {
    func quickAdd(_ raw: String, as kind: QuickKind) {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines); guard !t.isEmpty else { return }
        switch kind {
        case .task: addTask(t)
        case .note: data.captures.append(Capture(title: t, source: "Notes", text: t))
        case .journal:
            let key = Date().dayKey
            if let i = data.journal.firstIndex(where: { $0.id == key }) { data.journal[i].text += (data.journal[i].text.isEmpty ? "" : "\n") + t }
            else { data.journal.append(JournalEntry(id: key, prompt: Prompts.today(Date()), text: t)) }
        }
    }
}

struct MenuBarView: View {
    enum Tab: String, CaseIterable { case today = "Today", tasks = "Tasks", goals = "Goals" }
    @State private var focus = Focus.shared
    @State private var music = Music.shared
    @State private var store = Store.shared
    @State private var calendar = CalendarService.shared
    @State private var tab: Tab
    init(tab: Tab = .today) { _tab = State(initialValue: tab) }
    @State private var kind = QuickKind.task
    @State private var quick = ""
    @Environment(\.openWindow) private var openWindow

    private var nextBlock: Block? { store.data.blocks.filter { $0.end > Date() }.min { $0.start < $1.start } }
    private var openTasks: [TaskItem] {
        store.data.tasks.filter { !$0.done }.sorted { a, b in
            switch (a.due, b.due) {
            case let (x?, y?) where x != y: x < y
            case (_?, nil): true
            case (nil, _?): false
            default: a.priority > b.priority
            }
        }
    }
    private func open(_ p: Page) { Nav.shared.page = p; openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }

    var body: some View {
        @Bindable var s = store
        VStack(alignment: .leading, spacing: 12) {
            hero(s)
            HStack(spacing: 6) {
                TextField(kind.prompt, text: $quick).field().onSubmit { store.quickAdd(quick, as: kind); quick = "" }
                ForEach(QuickKind.allCases, id: \.self) { k in
                    icon(k.icon, "Add as \(k.rawValue.lowercased())", on: k == kind) { kind = k }
                }
            }
            Segments(selection: $tab, options: [Opt("Today", .today), Opt("Tasks", .tasks), Opt("Goals", .goals)])
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    switch tab { case .today: agenda; case .tasks: tasks; case .goals: goals }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 168)
            Divider()
            HStack(spacing: 6) {
                icon(music.playing ? "pause.fill" : "play.fill", music.playing ? "Pause music" : "Play music") { music.toggle() }
                icon("forward.fill", "Next track") { music.next() }
                Text(music.nowPlaying.isEmpty ? store.data.prefs.musicSource.rawValue : music.nowPlaying).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 4)
                icon("hand.raised.fill", "Block distractions during focus", on: store.data.prefs.blockDuringFocus) { s.data.prefs.blockDuringFocus.toggle() }
            }
            Divider()
            HStack(spacing: 0) {
                ForEach(Page.allCases) { p in
                    Button { open(p) } label: {
                        Image(systemName: p.icon).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white)
                            .frame(width: 22, height: 22).background(p.tint, in: .rect(cornerRadius: 6))
                    }
                    .buttonStyle(.plain).help(p.rawValue).accessibilityLabel("Open \(p.rawValue)")
                    Spacer(minLength: 0)
                }
                SettingsLink { Image(systemName: "gearshape").font(.system(size: 12)).frame(width: 22, height: 22).contentShape(.rect) }
                    .buttonStyle(.plain).help("Settings").accessibilityLabel("Settings")
                Spacer(minLength: 0)
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power").font(.system(size: 12)).frame(width: 22, height: 22).contentShape(.rect) }
                    .buttonStyle(.plain).help("Quit Bearing").accessibilityLabel("Quit Bearing")
            }
        }
        .padding(14).frame(width: 340)
    }

    @ViewBuilder private func hero(_ s: Store) -> some View {
        @Bindable var s = s
        if focus.active {
            HStack(alignment: .firstTextBaseline) {
                Text(focus.phase == .rest ? "Break" : (focus.title.isEmpty ? "Focus" : focus.title)).font(.headline).lineLimit(1)
                Spacer()
                Text(focus.display).font(.system(size: 28, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(store.goal(focus.goalID).map { goalColor($0.color) } ?? Color.primary)
            }
            TimerButtons()
        } else {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(nextBlock.map { "Next: \($0.title)" } ?? "Nothing planned").font(.headline).lineLimit(1)
                    Text(nextBlock.map { "\($0.start.formatted(.dateTime.weekday().hour().minute())) to \($0.end.clock)" } ?? "\(hm(focusedToday)) focused today").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                Button("Start") {
                    if let b = nextBlock, Calendar.current.isDateInToday(b.start) { focus.begin(title: b.title, goal: b.goalID, task: b.taskID) } else { focus.begin() }
                }.buttonStyle(PillButton())
            }
            Segments(selection: $s.data.prefs.timerMode, options: TimerMode.allCases.map { Opt($0.rawValue, $0) })
        }
    }
    private var focusedToday: Double { store.data.sessions.filter { $0.start >= Date().startOfDay }.reduce(0) { $0 + $1.seconds } }

    @ViewBuilder private var agenda: some View {
        let now = Date(), blocks = store.blocks(on: now).filter { $0.end > now }
        let events = calendar.events(from: now, to: now.startOfDay.adding(days: 1)).filter { !$0.allDay && $0.end > now }
        let rows: [(id: String, title: String, start: Date, end: Date, color: Color, block: Block?)] =
            (blocks.map { ($0.id.uuidString, $0.title, $0.start, $0.end, store.goal($0.goalID).map { goalColor($0.color) } ?? Color.brand, $0) }
             + events.map { ($0.id, $0.title, $0.start, $0.end, $0.color, nil) }).sorted { $0.start < $1.start }
        let cutoff = now.startOfDay.adding(days: 1), due = openTasks.filter { ($0.due ?? .distantFuture) < cutoff }
        if rows.isEmpty && due.isEmpty { empty("Nothing else today") }
        ForEach(rows, id: \.id) { r in
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2).fill(r.color).frame(width: 3, height: 26)
                VStack(alignment: .leading, spacing: 0) {
                    Text(r.title).font(.callout).lineLimit(1)
                    Text("\(r.start.clock) to \(r.end.clock)").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if let b = r.block { icon("play.fill", "Focus on \(b.title)") { focus.begin(title: b.title, goal: b.goalID, task: b.taskID) } }
            }
        }
        ForEach(due) { taskRow($0) }
    }

    @ViewBuilder private var tasks: some View {
        if openTasks.isEmpty { empty("No open tasks") }
        ForEach(openTasks.prefix(20)) { taskRow($0) }
    }
    private func taskRow(_ t: TaskItem) -> some View {
        let blocked = store.data.blocks.contains { $0.taskID == t.id && $0.end > Date() }
        return HStack(spacing: 6) {
            icon("circle", "Complete \(t.title)") { store.toggleDone(t) }
            if let g = store.goal(t.goalID) { Circle().fill(goalColor(g.color)).frame(width: 7, height: 7) }
            Text(t.title).font(.callout).lineLimit(1)
            Spacer(minLength: 4)
            icon(blocked ? "calendar.badge.checkmark" : "calendar.badge.plus", blocked ? "Already time blocked" : "Time block the next free hour") {
                store.block(task: t, at: store.nextFreeSlot())
            }.disabled(blocked)
            icon("play.fill", "Focus on \(t.title)") { focus.begin(title: t.title, goal: t.goalID, task: t.id) }
        }
    }

    @ViewBuilder private var goals: some View {
        if store.goals.isEmpty { empty("No goals yet") }
        ForEach(store.goals) { g in
            let done = store.focused(goal: g.id, since: Date().startOfWeek) / 3600
            Button { open(.goals) } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(g.title).font(.callout).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(String(format: "%.1f of %gh", done, g.weeklyHours)).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                    }
                    GeometryReader { p in
                        ZStack(alignment: .leading) {
                            Capsule().fill(goalColor(g.color).wash)
                            Capsule().fill(goalColor(g.color)).frame(width: p.size.width * min(1, g.weeklyHours > 0 ? done / g.weeklyHours : 0))
                        }
                    }.frame(height: 5)
                }.contentShape(.rect)
            }.buttonStyle(.plain)
        }
    }

    private func empty(_ t: String) -> some View { Text(t).font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 60) }
    private func icon(_ name: String, _ label: String, on: Bool = false, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Image(systemName: name).font(.system(size: 11, weight: .medium)).foregroundStyle(on ? Color.onBrand : .secondary)
                .frame(width: 24, height: 24).background(on ? Color.brand : .clear, in: .rect(cornerRadius: 7)).contentShape(.rect)
        }
        .buttonStyle(.plain).help(label).accessibilityLabel(label).accessibilityAddTraits(on ? .isSelected : [])
    }
}

// MARK: - Screenshots and self-test

@MainActor enum Snapshot {
    static func demo() {
        let s = Store.shared, now = Date(), week = now.startOfWeek
        s.data.compass = "Do work I'm proud of, stay healthy, and be present with the people I love."
        s.data.seasonName = "Autumn season"; s.data.seasonStart = now.adding(days: -51)
        let g = [Goal(title: "Ship the book draft", why: "It's the thing I'll regret not finishing", metric: "60,000 words by January", color: 0, weeklyHours: 10, notes: "Finish chapter 7 outline", status: .onTrack, coachNote: "You're ahead of pace. Keep mornings protected."),
                 Goal(title: "Run a half marathon", why: "Energy for everything else", metric: "Finish in under 2 hours", color: 2, weeklyHours: 4, status: .adjust, coachNote: "Only one run is planned. Add a long run on Saturday."),
                 Goal(title: "Launch the newsletter", why: "Build an audience I own", metric: "1,000 subscribers", color: 1, weeklyHours: 3, status: .offTrack, coachNote: "Nothing is scheduled. Pick a first issue date, or drop this for the season.")]
        s.data.goals = g + [Goal(title: "Home admin", color: 4, weeklyHours: 1, level: .support)]
        s.data.goals[2].level = .secondary
        s.data.plannedDay = now.dayKey
        s.data.reflections = [Reflection(id: now.adding(days: -1).dayKey, ratings: [GoalRating(goal: g[0].id, rating: "Solid progress")])]
        s.data.tasks = [TaskItem(todoistID: "1", title: "Outline chapter 7", project: "Book", goalID: g[0].id, due: now, priority: 4),
                        TaskItem(title: "Book physio appointment", goalID: g[1].id, due: now.adding(days: 1)),
                        TaskItem(todoistID: "2", title: "Draft first newsletter issue", project: "Newsletter", goalID: g[2].id, priority: 3),
                        TaskItem(title: "Renew passport", due: now.adding(days: 6))]
        func at(_ d: Int, _ h: Int, _ m: Int) -> (Date, Date) { let a = week.adding(days: d).addingTimeInterval(Double(h) * 3600); return (a, a.addingTimeInterval(Double(m) * 60)) }
        for (d, h, m, t, i) in [(1, 9, 120, "Write: chapter 6", 0), (2, 9, 120, "Write: chapter 7", 0), (3, 7, 45, "Easy run", 1), (3, 9, 150, "Write: revisions", 0), (4, 9, 120, "Write: chapter 8", 0), (5, 8, 90, "Long run", 1)] {
            let (a, b) = at(d, h, m); s.data.blocks.append(Block(title: t, start: a, end: b, goalID: g[i].id))
        }
        let today = now.startOfDay
        s.data.blocks.append(Block(title: "Outline chapter 7", start: today.addingTimeInterval(14 * 3600), end: today.addingTimeInterval(15.5 * 3600), goalID: g[0].id))
        for d in 0..<35 where d % 2 == 0 {
            s.data.sessions.append(Session(title: "Writing", goalID: g[d % 4 == 0 ? 0 : 1].id, start: now.adding(days: -d), seconds: Double(40 + d * 2) * 60, pausedSeconds: 120, distractions: d % 3,
                activity: [AppTime(id: "com.apple.iWork.Pages", name: "Pages", seconds: 1900), AppTime(id: "com.apple.Safari|youtube", name: "Safari · youtube", seconds: 260, site: "youtube"), AppTime(id: "idle", name: "Away", seconds: 240)]))
        }
        Focus.shared.finished = s.data.sessions.first
        s.data.chat = [ChatMsg(role: "user", text: "What should I change this week?"),
                       ChatMsg(role: "assistant", text: "Your newsletter has no time on the calendar, and you've missed it three weeks running. Either give it Thursday 2 to 4pm, or drop it until next season. Which would you like?")]
        s.data.journal = [JournalEntry(id: now.dayKey, prompt: Prompts.today(now), text: "Good morning of writing. The chapter finally has a shape.")]
        s.data.captures = [Capture(title: "Morning walk brain dump", text: "I keep coming back to the idea that the book needs a stronger opening…")]
        s.data.prefs.soundLevels = ["Rain": 0.5, "Brown noise": 0.3]
    }
    static func run(dir: String, dark: Bool) {
        demo()
        NSApp.setActivationPolicy(.regular)
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            for p in Page.allCases {
                let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 800), styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
                Nav.shared.page = p
                w.contentView = NSHostingView(rootView: RootView())
                w.isReleasedWhenClosed = false
                w.orderFrontRegardless()
                try? await Task.sleep(for: .milliseconds(900))
                // A real window capture includes the sidebar and toolbar materials; cacheDisplay can't draw those.
                let out = "\(dir)/\(p.rawValue)-\(dark ? "dark" : "light").png"
                let shot = Process(); shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                shot.arguments = ["-x", "-o", "-l\(w.windowNumber)", out]
                try? shot.run(); shot.waitUntilExit()
                if !FileManager.default.fileExists(atPath: out), let v = w.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                    v.cacheDisplay(in: v.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
                }
                w.close()
            }
            for tab in MenuBarView.Tab.allCases {
                let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 460), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
                w.isReleasedWhenClosed = false; w.contentView = NSHostingView(rootView: MenuBarView(tab: tab).bearingStyle().background(Color.surface))
                w.orderFrontRegardless()
                try? await Task.sleep(for: .milliseconds(500))
                let shot = Process(); shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                shot.arguments = ["-x", "-o", "-l\(w.windowNumber)", "\(dir)/Menu\(tab.rawValue)-\(dark ? "dark" : "light").png"]
                try? shot.run(); shot.waitUntilExit(); w.close()
            }
            exit(0)
        }
    }
}

@MainActor func selfTest() {
    func check(_ ok: Bool, _ name: String) { print(ok ? "ok   " : "FAIL ", name); if !ok { failed += 1 } }
    var failed = 0
    // Todoist merge
    var d = AppData()
    var local = TaskItem(todoistID: "temp1", title: "Made here")
    let pendingID = "7"
    d.tasks = [local, TaskItem(todoistID: "9", title: "Old title"), TaskItem(todoistID: pendingID, title: "Edited here"), TaskItem(todoistID: "gone", title: "Delete me")]
    let block = Block(title: "Old title", taskID: d.tasks[1].id); d.blocks = [block]
    d.outbox = [TodoistCommand(uuid: "a", type: "item_add", tempID: "temp1", args: [:]), TodoistCommand(uuid: "b", type: "item_update", args: ["id": .string(pendingID)]), TodoistCommand(uuid: "c", type: "item_close", args: ["id": .string("bad")])]
    let json = #"""
    {"sync_token":"T2","temp_id_mapping":{"temp1":"100"},"sync_status":{"a":"ok","c":{"error":"nope","http_code":400}},
     "projects":[{"id":"p","name":"Work"}],
     "items":[{"id":"9","content":"New title","project_id":"p","priority":4,"checked":false,"due":{"date":"2026-12-01"}},
              {"id":"7","content":"Server title"},{"id":"gone","content":"x","is_deleted":true},{"id":"55","content":"Made in Todoist","checked":true}]}
    """#
    let r = try! JSONDecoder().decode(TDResponse.self, from: Data(json.utf8))
    let fail = applyTodoist(r, to: &d)
    local = d.tasks.first { $0.id == local.id }!
    check(local.todoistID == "100", "temp id becomes the real id")
    check(d.outbox.map(\.uuid) == ["b"], "acknowledged and rejected commands leave the queue; unanswered stay")
    check(fail == "nope", "rejected change is reported")
    check(d.tasks.first { $0.todoistID == "9" }?.title == "New title" && d.tasks.first { $0.todoistID == "9" }?.project == "Work", "remote edit applies")
    check(d.tasks.first { $0.todoistID == "9" }?.due?.dayKey == "2026-12-01", "due date parses")
    check(d.blocks[0].title == "New title", "title follows onto time block")
    check(d.tasks.first { $0.todoistID == pendingID }?.title == "Edited here", "pending local edit isn't overwritten")
    check(!d.tasks.contains { $0.todoistID == "gone" }, "remote delete applies")
    check(d.tasks.first { $0.todoistID == "55" }?.done == true, "remote task arrives")
    check(d.syncToken == "T2", "sync token advances")
    let cmd = Todoist.commandsJSON([TodoistCommand(uuid: "u", type: "item_add", tempID: "t", args: ["content": .string("Hi")])])
    check(cmd.contains("\"temp_id\":\"t\"") && cmd.contains("\"content\":\"Hi\""), "commands encode")
    check(Todoist.enc("a b&c") == "a%20b%26c", "form encoding")
    // Stored data survives a round trip
    var a = AppData(); a.goals = [Goal(title: "G")]; a.outbox = [TodoistCommand(type: "item_add", args: ["due": .object(["date": "x"]), "n": .null, "p": .int(4)])]
    let back = try? Store.decoder.decode(AppData.self, from: Store.encoder.encode(a))
    check(back?.goals.first?.title == "G" && back?.outbox == a.outbox, "data round trip")
    // Timer
    let f = Focus.shared
    Store.shared.data.prefs.workMinutes = 25; Store.shared.data.prefs.breakMinutes = 5; Store.shared.data.prefs.longBreakMinutes = 15; Store.shared.data.prefs.cycles = 2
    f.begin(title: "T", mode: .pomodoro)
    check(f.display == "25:00", "pomodoro starts full")
    f.tick(1500); check(f.phase == .rest && f.phaseLeft == 300, "work leads to break")
    f.tick(300); check(f.phase == .work && f.cycle == 2, "break leads to round 2")
    f.tick(1500); check(f.phase == .rest && f.phaseLeft == 900, "last round gets the long break")
    f.tick(900); check(f.phase == .idle && f.finished?.seconds == 3000, "cycle ends and saves 50 minutes")
    f.begin(title: "C", mode: .stopwatch); f.tick(120); f.togglePause(); f.tick(40); f.togglePause(); f.noteDistraction(); f.tick(40)
    check(f.worked == 160 && f.pausedFor == 40, "paused time isn't focus time")
    check(f.quality == 75, "quality: 80% focus minus 5 for one distraction")
    f.finish()
    f.begin(mode: .countdown); f.tick(30); f.finish()
    check(Store.shared.data.sessions.count == 2, "sessions under a minute aren't kept")
    // Plan strength
    check(Store.planStrength(hasWhy: true, hasMetric: true, hasNext: true, planned: 5, target: 5) == 100, "full plan scores 100")
    check(Store.planStrength(hasWhy: false, hasMetric: false, hasNext: false, planned: 0, target: 5) == 0, "empty plan scores 0")
    check(Store.planStrength(hasWhy: true, hasMetric: false, hasNext: true, planned: 2.5, target: 5) == 60, "half the hours scores half the time points")
    // Streaming formats and JSON pulled from chatty models
    check(parseStreamToken(#"{"choices":[{"delta":{"content":"hi"}}]}"#) == "hi", "OpenAI-format chunk")
    check(parseStreamToken(#"{"type":"content_block_delta","delta":{"type":"text_delta","text":"yo"}}"#) == "yo", "Anthropic chunk")
    check(parseStreamToken(#"{"type":"message_start"}"#) == nil, "other events ignored")
    let plan = extractJSON(PlanDraft.self, from: "Sure!\n```json\n{\"changes\":[{\"action\":\"add\",\"title\":\"X\",\"day\":\"2026-12-01\",\"start\":\"09:00\",\"minutes\":30}]}\n```")
    check(plan?.changes.first?.minutes == 30 && plan?.changes.first?.keep == true, "plan parses out of prose")
    // Soundscapes stay in range and aren't silent
    let syn = NoiseSynth(rate: 48000), l = UnsafeMutablePointer<Float>.allocate(capacity: 48000), rr = UnsafeMutablePointer<Float>.allocate(capacity: 48000)
    for i in 0..<NoiseSynth.names.count {
        for k in 0..<6 { syn.target[k] = k == i ? 1 : 0 }
        syn.render(l, rr, 48000); syn.render(l, rr, 48000)
        var peak: Float = 0, sum: Float = 0
        for j in 0..<48000 { peak = max(peak, abs(l[j])); sum += l[j] * l[j] }
        let rms = (sum / 48000).squareRoot()
        print("     \(NoiseSynth.names[i]) rms \(rms) peak \(peak)")
        check(rms > 0.01 && peak <= 1, "\(NoiseSynth.names[i]) sounds and doesn't clip")
    }
    check(!Prompts.all.isEmpty && Prompts.today(Date()) == Prompts.today(Date()), "prompt is stable for the day")
    let tracks = Music.shared.tracks
    let playable = tracks.filter { t in
        guard let u = Bundle.main.url(forResource: t.file, withExtension: "m4a", subdirectory: "Music"), let f = try? AVAudioFile(forReading: u) else { print("     unplayable:", t.file); return false }
        return Double(f.length) / f.fileFormat.sampleRate > 60
    }
    check(tracks.count == 25 && playable.count == tracks.count, "all \(tracks.count) bundled tracks open and run over a minute")
    // Google Calendar, against stubbed responses
    check(GoogleCalendar.challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", "PKCE challenge matches RFC 7636")
    check(GoogleCalendar.split("g:a:b@x:e1")?.cal == "a:b@x" && GoogleCalendar.split("g:a:b@x:e1")?.id == "e1" && GoogleCalendar.split("x") == nil, "event key splits")
    let parsed = GoogleCalendar.parseEvents(Data(GStub.events.utf8), cal: "me@x")
    check(parsed.map(\.id) == ["e1", "e2"] && parsed[1].allDay && parsed[1].start.dayKey == "2030-01-02", "Google events parse, cancelled ones drop")
    func spin(_ cond: () -> Bool) { let t = Date() + 5; while !cond() && Date() < t { RunLoop.main.run(until: Date() + 0.01) } }
    URLProtocol.registerClass(GStub.self)
    let g = GoogleCalendar.shared; g.connected = true; g.access = "t"; g.expiry = .distantFuture
    let st = Store.shared
    let soon = Date().adding(days: 1)
    let moved = Block(title: "Old", start: soon, end: soon + 60, eventID: "g:me@x:e3")
    let gone = Block(title: "Gone", start: soon, end: soon + 60, eventID: "g:me@x:missing")
    let other = Block(title: "Other", start: soon, end: soon + 60, eventID: "g:unfetched:z")
    st.data.blocks = [moved, gone, other]
    var synced = false; Task { await g.sync(); synced = true }; spin { synced }
    check(g.calendars.count == 2 && g.calendars[0].writable && g.calendars[0].primary && !g.calendars[1].writable, "Google calendars parse")
    check(st.data.blocks.first { $0.id == moved.id }?.title == "Moved in Google", "Google edits flow into blocks")
    check(!st.data.blocks.contains { $0.id == gone.id }, "event deleted in Google removes its block")
    check(st.data.blocks.contains { $0.id == other.id }, "blocks on calendars not fetched are kept")
    let shown = CalendarService.shared.events(from: GStub.day, to: GStub.day + 86400 * 3).filter { $0.id.hasPrefix("g:") }.map(\.id)
    check(shown == ["g:me@x:e1", "g:me@x:e2"], "Google events show, linked ones don't")
    st.data.prefs.calendarID = "google:me@x"
    let made = st.addBlock(Block(title: "Plan", start: soon, end: soon + 60))
    spin { st.data.blocks.first { $0.id == made.id }?.eventID != nil }
    let saved = st.data.blocks.first { $0.id == made.id }
    check(saved?.eventID == "g:me@x:new", "a new block creates a Google event")
    var edited = saved!; edited.title = "Plan 2"; st.updateBlock(edited)
    spin { GStub.log.contains("PATCH /calendar/v3/calendars/me%40x/events/new") }
    check(GStub.log.contains("PATCH /calendar/v3/calendars/me%40x/events/new"), "an edited block patches its event")
    st.deleteBlock(edited)
    spin { GStub.log.contains("DELETE /calendar/v3/calendars/me%40x/events/new") }
    check(GStub.log.contains("DELETE /calendar/v3/calendars/me%40x/events/new"), "a deleted block deletes its event")
    g.connected = false; st.data.prefs.calendarID = nil
    if let srv = try? Loopback() {
        final class Box: @unchecked Sendable { var got: [String: String]? }
        let box = Box(); var fin = false
        Task {
            box.got = await srv.wait { p in Task { _ = try? await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(p)/?code=abc&state=s")!) } }
            fin = true
        }
        spin { fin }
        check(box.got?["code"] == "abc" && box.got?["state"] == "s", "sign-in redirect is received")
    } else { check(false, "loopback listener opens") }
    let qs = Store.shared, qt = qs.data.tasks.count, qc = qs.data.captures.count
    qs.quickAdd("  buy milk ", as: .task); qs.quickAdd("idea", as: .note); qs.quickAdd("   ", as: .note)
    qs.data.journal.removeAll { $0.id == Date().dayKey }
    qs.quickAdd("one", as: .journal); qs.quickAdd("two", as: .journal)
    check(qs.data.tasks.count == qt + 1 && qs.data.captures.count == qc + 1, "quick add makes one task and one note, ignores blanks")
    check(qs.data.journal.first { $0.id == Date().dayKey }?.text == "one\ntwo", "quick add appends to today's journal")
    let old = try? JSONDecoder().decode(Goal.self, from: Data(#"{"id":"\#(UUID())","title":"Old","why":"","metric":"","color":0,"weeklyHours":5,"notes":"","status":"\#(GoalStatus.none.rawValue)","coachNote":"","archived":false}"#.utf8))
    check(old?.tier == .core, "goals saved before tiers load as core")
    let keep = qs.data.goals
    qs.data.goals = [Goal(title: "S", level: .support), Goal(title: "B", level: .secondary), Goal(title: "A"), Goal(title: "X", archived: true)]
    check(qs.goals.map(\.title) == ["A", "B", "S"], "goals rank core, secondary, support and hide archived")
    qs.data.goals = keep
    let ob = try? JSONDecoder().decode(Block.self, from: JSONEncoder().encode(Block(title: "b")))
    check(ob?.energy == nil && Energy(rawValue: "draining") == .draining, "blocks without energy tags still load")
    let act = [AppTime(id: "a", name: "Code", seconds: 60), AppTime(id: "b", name: "Chat", seconds: 20), AppTime(id: "x|youtube", name: "Safari", seconds: 10, site: "youtube"), AppTime(id: "idle", name: "Away", seconds: 10)]
    let fb = Tracker.breakdown(act, intention: "Write code", distracting: ["b"])
    check(fb.score == 60 && fb.distraction == 30 && fb.idle == 10, "focus quality counts on-task, distraction and idle time")
    check(Tracker.breakdown(act, intention: "Watch the YouTube lecture", distracting: ["b"]).onTask == 70, "a site named in the intention stays on task")
    check(Tracker.site(in: "Funny cats - YouTube") == "youtube" && Tracker.site(in: "Pull request") == nil, "distracting sites are found in window titles")
    check(Account.call(spent: 10, planned: 20, pace: 10, weekly: 2, lowDays: 0).ok, "on pace is ok")
    check(Account.call(spent: 1, planned: 2, pace: 20, weekly: 2, lowDays: 0).verdict.hasPrefix("You aren't putting"), "unplanned goal is called out")
    check(Account.call(spent: 2, planned: 20, pace: 20, weekly: 2, lowDays: 0).verdict.hasPrefix("You plan it, then skip"), "skipped plans are called out")
    check(Account.imbalance([("Book", .core, 2), ("Admin", .support, 9)])?.hasPrefix("Admin") == true && Account.imbalance([("Book", .core, 9), ("Admin", .support, 2)]) == nil, "support beating core is flagged")
    check(Coach.fallbackQuestions([Goal(title: "Run")]).allSatisfy { (2...4).contains($0.options.count) }, "fallback season questions have 2 to 4 options")
    print(failed == 0 ? "ALL PASSED" : "\(failed) FAILED")
    exit(failed == 0 ? 0 : 1)
}

final class GStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var log: [String] = []
    static let day = ISO8601DateFormatter().date(from: "2030-01-01T00:00:00Z")!
    static let list = ##"{"items":[{"id":"me@x","summary":"Me","accessRole":"owner","primary":true,"selected":true,"backgroundColor":"#112233"},{"id":"ro@x","summary":"Read only","accessRole":"reader"}]}"##
    static let events = #"{"items":[{"id":"e1","summary":"Timed","start":{"dateTime":"2030-01-01T10:00:00-05:00"},"end":{"dateTime":"2030-01-01T11:00:00-05:00"}},{"id":"e2","summary":"All day","start":{"date":"2030-01-02"},"end":{"date":"2030-01-03"}},{"id":"x","status":"cancelled"}]}"#
    override class func canInit(with r: URLRequest) -> Bool { r.url?.host == "www.googleapis.com" }
    override class func canonicalRequest(for r: URLRequest) -> URLRequest { r }
    override func startLoading() {
        let u = request.url!, m = request.httpMethod ?? ""
        let path = URLComponents(url: u, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? ""
        Self.log.append("\(m) \(path)")
        let moved = #"{"id":"e3","summary":"Moved in Google","start":{"dateTime":"\#(ISO8601DateFormatter().string(from: Date().adding(days: 2)))"},"end":{"dateTime":"\#(ISO8601DateFormatter().string(from: Date().adding(days: 2) + 60))"}}"#
        let body = path.hasSuffix("calendarList") ? Self.list : m == "POST" ? #"{"id":"new"}"# : m == "GET" ? Self.events.replacingOccurrences(of: #"{"id":"x","#, with: moved + #",{"id":"x","#) : "{}"
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: u, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

// MARK: - Floating timer

/// Stays above other apps during a session without taking focus from them.
@MainActor enum FloatingTimer {
    private static var panel: NSPanel?
    static func show() {
        guard panel == nil else { return }
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 48), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.hidesOnDeactivate = false
        p.isMovableByWindowBackground = true
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.contentView = NSHostingView(rootView: FloatingTimerView())
        if let f = NSScreen.main?.visibleFrame { p.setFrameOrigin(NSPoint(x: f.midX - 160, y: f.maxY - 60)) }
        p.orderFrontRegardless()
        panel = p
    }
    static func hide() { panel?.orderOut(nil); panel = nil }
}

private struct FloatingTimerView: View {
    private let focus = Focus.shared
    private var tint: Color {
        focus.phase == .rest ? goalColor(4) : Store.shared.goal(focus.goalID).map { goalColor($0.color) } ?? .brand
    }
    private var label: String {
        if let n = focus.notice { return "Focus Mode Active · \(n) is on your blocklist" }
        if focus.exitAt != nil { return "Ending soon" }
        if focus.phase == .rest { return "Break" }
        return focus.title.isEmpty ? "Focus" : focus.title
    }
    var body: some View {
        let music = Music.shared, store = Store.shared
        HStack(spacing: 6) {
            ZStack {
                Circle().stroke(tint.wash, lineWidth: 3)
                Circle().trim(from: 0, to: focus.mode == .stopwatch ? 1 : focus.progress).stroke(tint, style: .init(lineWidth: 3, lineCap: .round)).rotationEffect(.degrees(-90))
                Button { focus.togglePause() } label: { Image(systemName: focus.paused ? "play.fill" : "pause.fill").font(.system(size: 9, weight: .bold)).frame(width: 22, height: 22).contentShape(.circle) }
                    .buttonStyle(.plain).help(focus.paused ? "Resume" : "Pause").accessibilityLabel(focus.paused ? "Resume" : "Pause")
            }.frame(width: 26, height: 26)
            Text(label).font(.callout.weight(.medium)).lineLimit(1).padding(.leading, 4)
            Spacer(minLength: 4)
            Text(focus.display).font(.system(.callout, design: .rounded).weight(.semibold)).monospacedDigit()
            Menu {
                ForEach(music.categories, id: \.self) { c in
                    Button { store.data.prefs.musicSource = .library; store.data.prefs.musicCategory = c; music.reload(); music.play() } label: {
                        if music.playing && store.data.prefs.musicSource == .library && store.data.prefs.musicCategory == c { Label(c, systemImage: "checkmark") } else { Text(c) }
                    }
                }
                Divider()
                Button(music.playing ? "Pause Music" : "Play Music") { music.playing ? music.pause() : music.play() }
            } label: { Image(systemName: "headphones") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 24).help("Music").accessibilityLabel("Music")
            if focus.exitAt != nil { control("arrow.uturn.backward", "Keep going") { focus.cancelExit() } }
            else { control("checkmark", "Finish session") { focus.requestStop() } }
            control("chevron.down", "Hide until the next session") { FloatingTimer.hide() }
        }
        .padding(.leading, 11).padding(.trailing, 10)
        .frame(width: 320, height: 48)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator))
    }
    private func control(_ icon: String, _ name: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).frame(width: 24, height: 24).contentShape(Rectangle()) }
            .buttonStyle(.plain).foregroundStyle(.secondary).help(name).accessibilityLabel(name)
    }
}
