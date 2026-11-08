import SwiftUI

// MARK: - Window shell: a gray backdrop with floating panels for tasks, the calendar, and context.

extension Color {
    static let now = dyn(0xEF4444, 0xF87171)      // today badge and the current-time line
    static let action = dyn(0x3B82F6, 0x60A5FA)   // Start Focus
    static let good = dyn(0x22C55E, 0x4ADE80)     // daily score
}
extension View {
    func panel() -> some View {
        background(Color.surface).clipShape(.rect(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.primary.opacity(0.06)))
            .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
    }
}
/// A borderless round icon button, the toolbar and panel headers' only control.
struct IconButton: View {
    let icon: String, label: String
    var on = false
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 13, weight: .medium)).foregroundStyle(on ? Color.primary : .secondary)
                .frame(width: 28, height: 28).background(Color.primary.opacity(on ? 0.1 : hover ? 0.06 : 0), in: .circle).contentShape(.circle)
        }.buttonStyle(.plain).onHover { hover = $0 }.help(label).accessibilityLabel(label)
    }
}

struct RootView: View {
    @State private var nav = Nav.shared
    @State private var store = Store.shared
    var body: some View {
        Group { if store.data.prefs.profile == nil { WelcomeView() } else { Shell() } }
            .sheet(isPresented: $nav.seasonSetup) { SeasonSetup().bearingStyle() }
            .sheet(isPresented: $nav.dailySync) { DailySync().bearingStyle() }
            .sheet(isPresented: $nav.reflect) { ReflectView().bearingStyle() }
            .bearingStyle()
    }
}

struct Shell: View {
    @State private var nav = Nav.shared
    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Color.clear.contentShape(.rect).gesture(WindowDragGesture())
                HStack(spacing: 6) {
                    IconButton(icon: "sidebar.left", label: nav.showTasks ? "Hide tasks" : "Show tasks", on: !nav.showTasks) { nav.showTasks.toggle() }
                    Spacer()
                    TopActions()
                }.padding(.leading, 76)
                ModeSwitch()
            }.frame(height: 32).padding(.top, 6)
            HStack(spacing: 8) {
                if nav.showTasks { TasksPanel().frame(width: 272).panel() }
                PageView(page: nav.page).id(nav.page).transition(.opacity).frame(maxWidth: .infinity, maxHeight: .infinity).panel()
                    .animation(.easeOut(duration: 0.14), value: nav.page)
                if nav.side { CoachPage().frame(width: 360).panel() }
                else if nav.page == .today { DayPanel().frame(width: 290).panel() }
            }
        }
        .padding([.horizontal, .bottom], 8)
        .background(Color.chrome)
        .ignoresSafeArea(edges: .top)
    }
}

/// Day, Week, Goals and Focus: icons, with the selected one labelled in a raised pill.
struct ModeSwitch: View {
    @State private var nav = Nav.shared
    @Namespace private var pill
    private let modes: [(page: Page, title: String, icon: String)] = [(.today, "Day", "doc.text"), (.week, "Week", "rectangle.split.3x1"), (.goals, "Goals", "scope"), (.focus, "Focus", "timer"), (.coach, "AI", "sparkles")]
    var body: some View {
        HStack(spacing: 2) {
            ForEach(modes, id: \.page) { m in
                let on = nav.page == m.page
                Button { nav.page = m.page; if m.page == .coach { nav.side = false } } label: {
                    HStack(spacing: 5) { Image(systemName: m.icon); if on { Text(m.title) } }
                        .font(.system(size: 12, weight: on ? .semibold : .medium)).foregroundStyle(on ? Color.primary : .secondary)
                        .padding(.horizontal, on ? 11 : 9).frame(height: 26)
                        .background { if on { Capsule().fill(Color.surface).shadow(color: .black.opacity(0.08), radius: 2, y: 1).matchedGeometryEffect(id: "pill", in: pill) } }
                        .contentShape(.capsule)
                }.buttonStyle(.plain).help(m.title).accessibilityLabel(m.title).accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(3).background(Color.primary.opacity(0.06), in: .capsule)
        .animation(.spring(duration: 0.22, bounce: 0), value: nav.page)   // only the pill slides
    }
}

struct TopActions: View {
    @State private var nav = Nav.shared
    @State private var store = Store.shared
    @Environment(\.openURL) private var openURL
    var body: some View {
        HStack(spacing: 4) {
            IconButton(icon: "arrow.clockwise", label: "Sync calendars and tasks") {
                Todoist.shared.nudge(); Task { await GoogleCalendar.shared.sync() }
            }
            Button { openURL(URL(string: "https://github.com/tapariapurv/bearing/issues")!) } label: {
                Text("Help us improve").font(.system(size: 12, weight: .medium)).padding(.horizontal, 11).frame(height: 26)
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.15))).contentShape(.capsule)
            }.buttonStyle(.plain).padding(.horizontal, 4)
            IconButton(icon: "chart.bar", label: "Insights", on: nav.page == .insights) { nav.page = .insights }
            IconButton(icon: "book", label: "Journal", on: nav.page == .journal) { nav.page = .journal }
            IconButton(icon: "waveform", label: "Capture", on: nav.page == .capture) { nav.page = .capture }
            IconButton(icon: "bubble.left", label: "Coach", on: nav.side) { nav.side.toggle() }
            IconButton(icon: "sparkles", label: "Plan today with your coach") { nav.dailySync = true }
            ScoreRing(value: store.dayScore).padding(.horizontal, 4)
            Avatar()
        }
    }
}

extension Store {
    /// Today's focused time against today's planned time, 0 to 100.
    var dayScore: Int {
        let t = Date()
        let planned = blocks(on: t).reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
        let done = data.sessions.filter { Calendar.current.isDateInToday($0.start) }.reduce(0) { $0 + $1.seconds }
        return planned > 0 ? min(100, Int(done / planned * 100)) : (done > 0 ? 100 : 0)
    }
}

struct ScoreRing: View {
    let value: Int
    var body: some View {
        ZStack {
            Circle().stroke(Color.good.opacity(0.18), lineWidth: 3)
            Circle().trim(from: 0, to: CGFloat(value) / 100).stroke(Color.good, style: .init(lineWidth: 3, lineCap: .round)).rotationEffect(.degrees(-90))
            Text("\(value)").font(.system(size: 10, weight: .bold, design: .rounded)).monospacedDigit()
        }
        .frame(width: 26, height: 26).help("Today: \(value)% of planned time focused").accessibilityLabel("Today's score \(value) percent")
    }
}

struct Avatar: View {
    @State private var store = Store.shared
    var body: some View {
        let p = store.data.prefs.profile ?? Profile()
        Menu {
            Text(p.name.isEmpty ? "Bearing" : p.name)
            if !p.email.isEmpty { Text(p.email) }
            Divider()
            Button("All Tasks") { Nav.shared.page = .tasks }
            Button("Set Up a New Season…") { Nav.shared.seasonSetup = true }
            SettingsLink { Text("Settings…") }
            Divider()
            Button("Sign Out") { GoogleCalendar.shared.signOut() }
        } label: {
            Text(p.initials.isEmpty ? "?" : p.initials).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                .frame(width: 28, height: 28).background(Color.primary.opacity(0.1), in: .circle)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().accessibilityLabel("Account")
    }
}

// MARK: - Tasks panel

struct TasksPanel: View {
    @State private var store = Store.shared
    @State private var nav = Nav.shared
    @State private var collapsed: Set<String> = []
    @State private var showSupport = true
    @State private var drafts: [String: String] = [:]
    var body: some View {
        let goals = store.goals, main = goals.filter { $0.tier != .support }, support = goals.filter { $0.tier == .support }
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Tasks").font(.system(size: 17, weight: .semibold))
                    Spacer()
                    IconButton(icon: "square.and.arrow.down", label: "Sync Todoist") { Todoist.shared.nudge() }
                    IconButton(icon: "line.3.horizontal.decrease", label: "All tasks") { nav.page = .tasks }
                }.padding(.bottom, 8)
                header("Season goals") { nav.seasonSetup = true }
                if main.isEmpty {
                    Button("Set up your season") { nav.seasonSetup = true }.padding(.vertical, 6)
                }
                ForEach(main) { g in group(g.id.uuidString, g.title, goal: g) }
                Button { showSupport.toggle() } label: {
                    HStack(spacing: 4) {
                        Text("Support areas")
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).rotationEffect(.degrees(showSupport ? 90 : 0))
                        Spacer()
                    }.font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).padding(.top, 14).padding(.bottom, 4).contentShape(.rect)
                }.buttonStyle(.plain).accessibilityLabel(showSupport ? "Hide support areas" : "Show support areas")
                if showSupport {
                    group("inbox", "Inbox", goal: nil)
                    ForEach(support) { g in group(g.id.uuidString, g.title, goal: g) }
                }
            }.padding(14)
        }
    }
    private func header(_ t: String, add: @escaping () -> Void) -> some View {
        HStack {
            Text(t).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            Spacer()
            IconButton(icon: "plus", label: "New season", action: add)
        }
    }
    @ViewBuilder private func group(_ key: String, _ title: String, goal: Goal?) -> some View {
        let open = !collapsed.contains(key)
        Button { if open { collapsed.insert(key) } else { collapsed.remove(key) } } label: {
            HStack(spacing: 9) {
                if let goal { GoalIcon(goal: goal, size: 24) }
                else { Image(systemName: "tray").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).frame(width: 24, height: 24).background(Color.primary.opacity(0.07), in: .rect(cornerRadius: 7)) }
                Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Spacer(minLength: 0)
            }.padding(.vertical, 5).contentShape(.rect)
        }.buttonStyle(.plain).accessibilityValue(open ? "Expanded" : "Collapsed")
        if open {
            ForEach(store.data.tasks.filter { !$0.done && $0.goalID == goal?.id }) { taskRow($0) }
            HStack(spacing: 8) {
                Image(systemName: "plus").font(.system(size: 11, weight: .medium)).frame(width: 16)
                TextField("Add task…", text: Binding(get: { drafts[key, default: ""] }, set: { drafts[key] = $0 })).textFieldStyle(.plain)
                    .onSubmit {
                        let t = drafts[key, default: ""].trimmingCharacters(in: .whitespaces)
                        if !t.isEmpty { store.addTask(t, goal: goal?.id); drafts[key] = "" }
                    }
            }.font(.system(size: 13)).foregroundStyle(.secondary).padding(.leading, 33).padding(.vertical, 5)
        }
    }
    private func taskRow(_ t: TaskItem) -> some View {
        let b = store.data.blocks.first { $0.taskID == t.id && $0.end > Date() }
        return HStack(spacing: 8) {
            Button { store.toggleDone(t) } label: { Image(systemName: "circle").font(.system(size: 14)).foregroundStyle(.tertiary) }
                .buttonStyle(.plain).accessibilityLabel("Complete \(t.title)")
            Text(t.title).font(.system(size: 13)).lineLimit(2)
            Spacer(minLength: 4)
            if let b {
                let m = Int(b.end.timeIntervalSince(b.start) / 60)
                Label(String(format: "%d:%02d", m / 60, m % 60), systemImage: "stopwatch").font(.system(size: 11, weight: .medium)).monospacedDigit()
                    .foregroundStyle(.secondary).padding(.horizontal, 6).padding(.vertical, 2).background(Color.primary.opacity(0.06), in: .capsule)
            }
        }
        .padding(.leading, 33).padding(.vertical, 5).contentShape(.rect)
        .draggable(t.id.uuidString) {   // a 1-hour block preview, the size it will land as
            Text(t.title).font(.caption.weight(.semibold)).lineLimit(2).padding(8)
                .frame(width: 150, height: WeekPage.hourH, alignment: .topLeading)
                .background(Color.surface, in: .rect(cornerRadius: 8))
                .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 2).fill(store.goal(t.goalID).map { goalColor($0.color) } ?? .gray).frame(width: 3).padding(.vertical, 4).padding(.leading, 2) }
        }
        .contextMenu {
            Button("Start Focus") { Focus.shared.begin(title: t.title, goal: t.goalID, task: t.id); Nav.shared.page = .focus }
            Button("Time Block Next Free Hour") { store.block(task: t, at: store.nextFreeSlot()) }
            Divider()
            Button("Delete", role: .destructive) { store.deleteTask(t) }
        }
    }
}

// MARK: - Day context panel

struct DayPanel: View {
    @State private var store = Store.shared
    var body: some View {
        let today = Date(), key = today.dayKey
        let planned = store.blocks(on: today).reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
        let sessions = store.data.sessions.filter { Calendar.current.isDateInToday($0.start) }
        let open = store.data.tasks.filter { !$0.done && ($0.due ?? .distantFuture) < today.startOfDay.adding(days: 1) }.count
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(store.dayScore)%").font(.system(size: 34, weight: .bold, design: .rounded)).monospacedDigit()
                    GoalBar(value: Double(store.dayScore) / 100, color: .good)
                    Text("\(hm(sessions.reduce(0) { $0 + $1.seconds })) focused / \(hm(planned)) planned · \(open) due today").font(.callout).foregroundStyle(.secondary)
                }
                DailyLoop()
                Divider()
                Text("Sessions").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                if sessions.isEmpty { Text("Start a focus session and it shows up here with its focus quality.").font(.callout).foregroundStyle(.secondary) }
                ForEach(sessions) { s in
                    let c = store.goal(s.goalID).map { goalColor($0.color) } ?? .gray
                    HStack(spacing: 8) {
                        Circle().fill(c).frame(width: 7, height: 7)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(s.title).font(.callout.weight(.medium)).lineLimit(1)
                            Text("\(hhmm(s.start)) - \(hhmm(s.start.addingTimeInterval(s.seconds)))").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let a = s.activity { Text("\(Tracker.breakdown(a, intention: s.title).score)%").font(.callout.weight(.semibold)).monospacedDigit() }
                    }
                }
                Divider()
                Text("Notes").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                TextField("Add notes for today…", text: Binding(
                    get: { store.data.journal.first { $0.id == key }?.text ?? "" },
                    set: { t in
                        if let i = store.data.journal.firstIndex(where: { $0.id == key }) { store.data.journal[i].text = t }
                        else { store.data.journal.append(JournalEntry(id: key, prompt: Prompts.today(today), text: t)) }
                    }), axis: .vertical).textFieldStyle(.plain).lineLimit(3...20)
            }.padding(18)
        }
    }
}

// MARK: - Welcome and sign-in

struct WelcomeView: View {
    @State private var google = GoogleCalendar.shared
    @State private var store = Store.shared
    @State private var busy = false
    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 76, height: 76).accessibilityHidden(true)
            Text("Welcome to Bearing").font(.system(size: 30, weight: .bold)).padding(.top, 16)
            Text("Plan your week around what matters, focus without distractions, and get an honest coach for where your time goes.")
                .font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 460).padding(.top, 8)
            VStack(spacing: 10) {
                feature("scope", 1, "Seasons, not resolutions", "Pick a few goals for the next 6 to 12 weeks and rank them.")
                feature("calendar", 0, "Plan, Focus, Reflect", "A daily sync with your coach, focus sessions, and a nightly check-in.")
                feature("chart.bar", 4, "Honest accountability", "See where your hours really went, with a fix for each gap.")
            }.frame(maxWidth: 440).padding(.top, 28)
            Button {
                busy = true
                Task {
                    await google.connect(); busy = false
                    if store.data.prefs.profile != nil && store.goals.isEmpty { Nav.shared.seasonSetup = true }
                }
            } label: {
                HStack(spacing: 10) {
                    Text("G").font(.system(size: 13, weight: .heavy)).foregroundStyle(Color.action).frame(width: 20, height: 20).background(.white, in: .circle)
                    Text(busy ? "Finish signing in in your browser…" : "Continue with Google").font(.system(size: 14, weight: .semibold))
                }
                .foregroundStyle(Color.onBrand).frame(width: 320, height: 44).background(Color.brand, in: .capsule).contentShape(.capsule)
            }
            .buttonStyle(.plain).disabled(busy || GoogleClient.id.isEmpty).padding(.top, 30).keyboardShortcut(.defaultAction)
            if !google.status.isEmpty && !busy { Text(google.status).font(.caption).foregroundStyle(.secondary).padding(.top, 8) }
            if GoogleClient.id.isEmpty {
                Button("Continue without an account") { store.data.prefs.profile = Profile(name: NSFullUserName()); if store.goals.isEmpty { Nav.shared.seasonSetup = true } }
                    .buttonStyle(.plain).font(.callout).foregroundStyle(.secondary).padding(.top, 10)
            }
            Text("Signing in connects your Google Calendar. Everything else stays on this Mac.").font(.caption).foregroundStyle(.tertiary).padding(.top, 14)
            Spacer()
        }
        .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.page)
    }
    private func feature(_ icon: String, _ color: Int, _ title: String, _ sub: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 14, weight: .semibold)).foregroundStyle(goalColor(color).ink)
                .frame(width: 36, height: 36).background(goalColor(color).wash, in: .rect(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                Text(sub).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12).background(Color.surface, in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.08)))
    }
}

// MARK: - Event and task detail

struct BlockDetail: View {
    let block: Block
    @Binding var editing: Block?
    @Binding var shown: Bool
    @State private var store = Store.shared
    var body: some View {
        let task = block.taskID.flatMap { store.task($0) }
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                Text(block.title).font(.system(size: 20, weight: .bold)).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Menu {
                    Button("Edit…") { shown = false; editing = block }
                    Button("Delete", role: .destructive) { shown = false; store.deleteBlock(block) }
                } label: { Image(systemName: "ellipsis").frame(width: 24, height: 24) }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().accessibilityLabel("More")
            }
            HStack(spacing: 10) {
                Button { shown = false; Focus.shared.begin(title: block.title, goal: block.goalID, task: block.taskID); Nav.shared.page = .focus } label: {
                    Label("Start Focus", systemImage: "play").font(.callout.weight(.semibold)).foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 34).background(Color.action, in: .rect(cornerRadius: 10)).contentShape(.rect)
                }.buttonStyle(.plain)
                if let task {
                    Button { shown = false; store.toggleDone(task) } label: {
                        Label("Mark as done", systemImage: "checkmark").font(.callout.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 34).overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.15))).contentShape(.rect)
                    }.buttonStyle(.plain)
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                row(task == nil ? "calendar" : "checkmark.circle", task == nil ? "Time block" : "Task")
                if let g = store.goal(block.goalID) { row("star", g.title, tint: goalColor(g.color)) }
                row("clock", "\(block.start.clock) – \(block.end.clock)")
                row("calendar", block.start.formatted(.dateTime.weekday().day().month()))
                if let e = block.energy { row(e == .energizing ? "bolt" : "battery.25percent", e.rawValue.capitalized) }
            }
        }
        .padding(20).frame(width: 320)
    }
    private func row(_ icon: String, _ text: String, tint: Color = .secondary) -> some View {
        HStack(spacing: 12) { Image(systemName: icon).foregroundStyle(tint).frame(width: 18); Text(text) }.font(.callout)
    }
}
