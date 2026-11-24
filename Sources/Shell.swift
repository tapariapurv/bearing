import SwiftUI

// MARK: - Window shell: a gray backdrop with floating panels for tasks, the calendar, and context.

extension Color {
    static let now = dyn(0xEF4444, 0xF87171)      // today badge and the current-time line
    static let action = dyn(0x3B82F6, 0x60A5FA)   // Start Focus
    static let good = dyn(0x22C55E, 0x4ADE80)     // daily score
}
extension View {
    func panel() -> some View {
        background(Color.surface).clipShape(.rect(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(Color.primary.opacity(0.05)))
            .shadow(color: .black.opacity(0.04), radius: 14, y: 4)
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
        Group { if store.data.prefs.profile == nil || store.data.prefs.onboarded == false { Onboarding() } else { Shell() } }
            .sheet(isPresented: $nav.seasonSetup) { SeasonSetup().bearingStyle() }
            .sheet(isPresented: $nav.dailySync) { DailySync().bearingStyle() }
            .sheet(isPresented: $nav.reflect) { ReflectView().bearingStyle() }
            .bearingStyle()
    }
}

struct Shell: View {
    @State private var nav = Nav.shared
    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Color.clear.contentShape(.rect)
                #if os(macOS)
                    .gesture(WindowDragGesture())
                #endif
                HStack(spacing: 6) {
                    IconButton(icon: "sidebar.left", label: nav.showTasks ? "Hide tasks" : "Show tasks", on: !nav.showTasks) { nav.showTasks.toggle() }
                    Spacer()
                    TopActions()
                }.padding(.leading, 76)
                ModeSwitch()
            }.frame(height: 30).padding(.top, 0)   // centered on the traffic lights
            HStack(spacing: 18) {
                if nav.showTasks { TasksPanel().frame(width: 288).panel() }
                PageView(page: nav.page).id(nav.page).transition(.opacity.combined(with: .offset(y: 6))).frame(maxWidth: .infinity, maxHeight: .infinity).panel()
                if nav.side { CoachPage().frame(width: 360).panel() }
                else if nav.page == .today { DayPanel().frame(width: 310).panel().transition(.opacity.combined(with: .move(edge: .trailing))) }
            }.animation(.easeOut(duration: 0.2), value: nav.page).animation(.easeOut(duration: 0.2), value: nav.side).animation(.easeOut(duration: 0.2), value: nav.showTasks)
        }
        .padding([.horizontal, .bottom], 18)
        .background(Color.chrome)
        .ignoresSafeArea(edges: .top)
    }
}

/// Day, Week, Goals and Focus: icons, with the selected one labelled in a raised pill.
struct ModeSwitch: View {
    @State private var nav = Nav.shared
    @Namespace private var pill
    private let modes: [(page: Page, title: String, icon: String)] = [(.today, "Day", "doc.text"), (.week, "Week", "rectangle.split.3x1"), (.month, "Month", "calendar"), (.goals, "Goals", "scope"), (.projects, "Projects", "folder"), (.focus, "Focus", "timer"), (.coach, "Coach", "sparkles")]
    var body: some View {
        HStack(spacing: 2) {
            ForEach(modes, id: \.page) { m in
                let on = nav.page == m.page
                Button { nav.page = m.page; if m.page == .coach { nav.side = false } } label: {
                    // Every label always shows at a fixed weight, so nothing resizes; only the pill slides.
                    HStack(spacing: 5) { Image(systemName: m.icon); Text(m.title).fixedSize() }
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(on ? Color.primary : .secondary)
                        .padding(.horizontal, 11).frame(height: 26)
                        .background { if on { Capsule().fill(Color.surface).shadow(color: .black.opacity(0.08), radius: 2, y: 1).matchedGeometryEffect(id: "pill", in: pill) } }
                        .contentShape(.capsule)
                }.buttonStyle(.plain).help(m.title).accessibilityLabel(m.title).accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(3).background(Color.primary.opacity(0.06), in: .capsule)
        .animation(.snappy(duration: 0.26), value: nav.page)   // only the pill slides
    }
}

struct TopActions: View {
    @State private var nav = Nav.shared
    @State private var store = Store.shared
    var body: some View {
        HStack(spacing: 4) {
            IconButton(icon: "arrow.clockwise", label: "Sync calendars and tasks") {
                Todoist.shared.nudge(); Task { await GoogleCalendar.shared.sync() }
            }
            IconButton(icon: "chart.bar", label: "Insights", on: nav.page == .insights) { nav.page = .insights }
            IconButton(icon: "book", label: "Journal", on: nav.page == .journal) { nav.page = .journal }
            IconButton(icon: "waveform", label: "Capture", on: nav.page == .capture) { nav.page = .capture }
            IconButton(icon: "bubble.left", label: "Coach", on: nav.side) { nav.side.toggle() }
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
    @State private var adding: Bool?   // true = class, false = project
    @State private var subFor: Area?
    @State private var newName = ""
    var body: some View {
        @Bindable var nav = nav
        let goals = store.goals, main = goals.filter { $0.tier != .support }, support = goals.filter { $0.tier == .support }
        let custom = store.data.prefs.system == .classes
        let classic = !custom && nav.taskView.group == .goal && nav.taskView.name == "All tasks"   // the GPS sidebar as before
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Menu {
                        ViewChips()
                    } label: { Label(nav.taskView.name, systemImage: nav.taskView.icon).font(.system(size: 17, weight: .semibold)).labelStyle(.titleAndIcon) }
                        .menuStyle(.button).buttonStyle(.plain).fixedSize().help("Switch view")
                    Spacer()
                    ViewOptions(v: $nav.taskView)
                    IconButton(icon: "square.and.arrow.down", label: "Sync Todoist") { Todoist.shared.nudge() }
                    IconButton(icon: "list.bullet", label: "All tasks") { nav.page = .tasks }
                }.padding(.bottom, 8)
                if classic {
                    header("Season goals") { nav.seasonSetup = true }
                    if main.isEmpty { Button("Set up your season") { nav.seasonSetup = true }.padding(.vertical, 6) }
                    ForEach(main) { g in group(TaskBucket(title: g.title, rank: 0, goal: g.id, tasks: open(goal: g.id))) }
                    Button { showSupport.toggle() } label: {
                        HStack(spacing: 4) {
                            Text("Support areas")
                            Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).rotationEffect(.degrees(showSupport ? 90 : 0))
                            Spacer()
                        }.font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).padding(.top, 14).padding(.bottom, 4).contentShape(.rect)
                    }.buttonStyle(.plain).accessibilityLabel(showSupport ? "Hide support areas" : "Show support areas")
                    if showSupport {
                        group(TaskBucket(title: "Inbox", rank: 0, tasks: open(goal: nil)))
                        ForEach(support) { g in group(TaskBucket(title: g.title, rank: 0, goal: g.id, tasks: open(goal: g.id))) }
                    }
                } else {
                    ForEach(nav.taskView.buckets(store)) { group($0) }
                    if custom {
                        HStack {
                            Button("+ Class") { newName = ""; adding = true }
                            Button("+ Project") { newName = ""; adding = false }
                        }.buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).padding(.top, 12)
                    }
                }
            }.padding(14)
        }
        .alert(adding == true ? "New class" : "New project", isPresented: Binding(get: { adding != nil }, set: { if !$0 { adding = nil } })) {
            TextField("Name", text: $newName)
            Button("Add") { if !newName.isEmpty, let c = adding { store.data.areas = (store.data.areas ?? []) + [Area(name: newName, isClass: c)] } }
            Button("Cancel", role: .cancel) {}
        }
        .alert("New sub-project", isPresented: Binding(get: { subFor != nil }, set: { if !$0 { subFor = nil } })) {
            TextField("Name", text: $newName)
            Button("Add") { if !newName.isEmpty, let a = subFor, let i = store.data.areas?.firstIndex(where: { $0.id == a.id }) { store.data.areas![i].subs = (a.subs ?? []) + [newName] } }
            Button("Cancel", role: .cancel) {}
        }
    }
    private func open(goal: UUID?) -> [TaskItem] { store.data.tasks.filter { !$0.done && $0.goalID == goal } }
    private func header(_ t: String, add: @escaping () -> Void) -> some View {
        HStack {
            Text(t).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            Spacer()
            IconButton(icon: "plus", label: "New season", action: add)
        }
    }
    @ViewBuilder private func group(_ b: TaskBucket) -> some View {
        let key = b.title, open = !collapsed.contains(key)
        let area = store.data.areas?.first { $0.id == b.area }
        Button { if open { collapsed.insert(key) } else { collapsed.remove(key) } } label: {
            HStack(spacing: 9) {
                if let g = store.goal(b.goal) { GoalIcon(goal: g, size: 24) }
                else {
                    if let area { AreaIcon(area: area, size: 24, sub: b.sub != nil) }
                    else { Image(systemName: "tray").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).frame(width: 24, height: 24).background(Color.primary.opacity(0.07), in: .rect(cornerRadius: 7)) }
                }
                Text(b.sub ?? b.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Spacer(minLength: 0)
            }.padding(.vertical, 5).padding(.leading, b.sub != nil ? 16 : 0).contentShape(.rect)
        }.buttonStyle(.plain).accessibilityValue(open ? "Expanded" : "Collapsed")
        .contextMenu {
            if let area {
                if area.isClass && b.sub == nil { Button("New Sub-project…") { newName = ""; subFor = area } }
                if b.sub == nil {
                    Picker("Goal", selection: Binding(get: { area.goal }, set: { store.link(area: area.id, goal: $0) })) {
                        Text("None").tag(UUID?.none); ForEach(store.goals) { Text($0.title).tag(UUID?.some($0.id)) }
                    }
                }
                if b.sub == nil {
                    Picker("Color", selection: Binding(get: { area.color ?? Int(area.id.uuid.0) % 8 }, set: { c in store.editArea(area.id) { $0.color = c } })) {
                        ForEach(0..<8, id: \.self) { Text(goalColorNames[$0]).tag($0) }
                    }
                }
                Button("Manage Classes and Projects…") { Nav.shared.page = .projects }
                Button("Delete \(b.sub ?? area.name)", role: .destructive) {
                    if let s = b.sub { if let i = store.data.areas?.firstIndex(where: { $0.id == area.id }) { store.data.areas![i].subs?.removeAll { $0 == s } } }
                    else { store.data.areas?.removeAll { $0.id == area.id } }
                }
            }
        }
        if open {
            ForEach(b.tasks) { taskRow($0) }
            HStack(spacing: 8) {
                Image(systemName: "plus").font(.system(size: 11, weight: .medium)).frame(width: 16)
                TextField("Add task…", text: Binding(get: { drafts[key, default: ""] }, set: { drafts[key] = $0 })).textFieldStyle(.plain)
                    .onSubmit {
                        let t = drafts[key, default: ""].trimmingCharacters(in: .whitespaces)
                        if !t.isEmpty { store.addTask(t, goal: b.goal, area: b.area, sub: b.sub, due: b.due); drafts[key] = "" }
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
                IdeaCard()
                Divider()
                FindTasksCard()
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
            #if os(iOS)
            Image(systemName: "location.north.circle.fill").font(.system(size: 64)).foregroundStyle(.tint)
            #else
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 76, height: 76).accessibilityHidden(true)
            #endif
            Text("Welcome to Bearing").font(.system(size: 30, weight: .bold)).padding(.top, 16)
            Text("Plan your week around what matters, focus without distractions, and get an honest coach for where your time goes.")
                .font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 460).fixedSize(horizontal: false, vertical: true).padding(.top, 8)
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
            Text("Signing in connects your Google Calendar. Everything else stays on your devices.").font(.caption).foregroundStyle(.tertiary).padding(.top, 14)
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
