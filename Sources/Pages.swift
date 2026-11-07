import SwiftUI
import Charts
import UniformTypeIdentifiers

// MARK: - Shared bits

extension View {
    /// The app's raised surface: white card, hairline, soft shadow, optional color bar on the left.
    func surface(_ radius: CGFloat = 14, accent: Color? = nil) -> some View {
        background {
            ZStack(alignment: .leading) {
                Color.surface
                if let accent { accent.frame(width: 4) }
            }.clipShape(.rect(cornerRadius: radius))
        }
        .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(Color.primary.opacity(0.07)))
        .shadow(color: .black.opacity(0.035), radius: 10, y: 3)
    }
}
struct PillButton: ButtonStyle {
    var color: Color? = nil
    @Environment(\.isEnabled) private var enabled
    @Environment(\.controlSize) private var size
    func makeBody(configuration c: Configuration) -> some View {
        let big = size == .large
        c.label.font(big ? .body.weight(.semibold) : .callout.weight(.semibold))
            .foregroundStyle(color == nil ? Color.onBrand : .white)
            .padding(.horizontal, big ? 22 : 14).padding(.vertical, big ? 11 : 6)
            .background(color ?? .brand, in: .capsule).contentShape(.capsule)
            .opacity(enabled ? 1 : 0.4)
            .scaleEffect(c.isPressed ? 0.97 : 1).animation(.easeOut(duration: 0.1), value: c.isPressed)
    }
}
struct GoalBar: View {
    let value: Double, color: Color
    var body: some View {
        Capsule().fill(color.wash).overlay(alignment: .leading) {
            GeometryReader { g in
                if value > 0 { Capsule().fill(color).frame(width: max(g.size.height, g.size.width * min(1, value))) }
            }
        }.frame(height: 6)
    }
}
struct GoalTag: View {
    let goal: Goal
    var body: some View {
        let c = goalColor(goal.color)
        HStack(spacing: 4) { Circle().fill(c).frame(width: 6, height: 6); Text(goal.title).lineLimit(1) }
            .font(.caption.weight(.medium)).foregroundStyle(c.ink)
            .padding(.horizontal, 7).padding(.vertical, 2).background(c.wash, in: .capsule)
    }
}
struct PlanRow<T: View>: View {
    let title: String, time: String, color: Color
    @ViewBuilder var trailing: T
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout.weight(.medium)).lineLimit(1)
                Text(time).font(.caption).opacity(0.8)
            }.foregroundStyle(color.ink)
            Spacer()
            trailing
        }
        .padding(.horizontal, 10).padding(.vertical, 7).frame(maxWidth: .infinity, alignment: .leading)
        .background(color.wash, in: .rect(cornerRadius: 8))
    }
}
struct Card<C: View>: View {
    var title: String? = nil
    var accent: Color? = nil
    @ViewBuilder var content: C
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title { Text(title).font(.headline) }
            content
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .leading)
        .surface(18, accent: accent)
    }
}
struct Pill: View {
    let status: GoalStatus
    var body: some View {
        Text(status.label).font(.caption.weight(.medium)).padding(.horizontal, 8).padding(.vertical, 2)
            .foregroundStyle(status.color).background(status.color.opacity(0.14), in: .capsule)
    }
}
struct Scroll<C: View>: View {
    @ViewBuilder var content: C
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 16) { content }.padding(24).frame(maxWidth: 1040, alignment: .leading).frame(maxWidth: .infinity) }
    }
}
struct ErrorText: View {
    let text: String?
    var body: some View { if let text, !text.isEmpty { Label(text, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.red).textSelection(.enabled) } }
}
struct GoalPicker: View {
    var label = "Goal"
    @Binding var goal: UUID?
    var body: some View {
        Dropdown(label, selection: $goal, options: [Opt("No goal", UUID?.none)] + Store.shared.goals.map { Opt($0.title, UUID?.some($0.id), goalColor($0.color)) })
    }
}
struct GoalStrip: View {
    @State private var store = Store.shared
    var body: some View {
        let goals = store.goals.filter { $0.tier != .support }
        if store.goals.isEmpty {
            Card {
                Text("Start with what matters.").font(.title3.weight(.semibold))
                Text("Bearing works best with one to three goals for this season.").foregroundStyle(.secondary)
                HStack {
                    Button("Set Up Your Season") { Nav.shared.seasonSetup = true }.buttonStyle(PillButton())
                    Button("Talk It Through with the Coach") { Coach.startInterview() }
                }
            }
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)], spacing: 12) {
                ForEach(goals) { g in
                    Button { Nav.shared.page = .goals } label: {
                        let c = goalColor(g.color)
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(g.title).font(.headline).lineLimit(1)
                                if g.tier != .core { Text(g.tier.rawValue).font(.caption2.weight(.semibold)).foregroundStyle(.secondary) }
                                Spacer(minLength: 4)
                                Pill(status: g.status)
                            }
                            GoalBar(value: g.weeklyHours > 0 ? store.plannedHours(goal: g.id) / g.weeklyHours : 0, color: c)
                            Text("\(String(format: "%.1f", store.plannedHours(goal: g.id))) of \(String(format: "%g", g.weeklyHours))h planned · \(hm(store.focused(goal: g.id, since: Date().startOfWeek))) focused")
                                .font(.caption).foregroundStyle(.secondary)
                            Text("Plan strength \(store.planStrength(g))").font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(14).padding(.leading, 2).frame(maxWidth: .infinity, alignment: .leading)
                        .surface(12, accent: c)
                        .contentShape(.rect)
                    }.buttonStyle(.plain)
                }
            }
        }
    }
}
/// Streams one coach reply into a card, with an error state and a way to carry on in chat.
struct CoachBrief: View {
    let title: String, button: String, prompt: String
    @State private var text = ""
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        Card(title: title) {
            if !text.isEmpty { Text(text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
            ErrorText(text: error)
            HStack {
                Button(busy ? "Thinking…" : (text.isEmpty ? button : "Ask Again")) { run() }.disabled(busy)
                if !text.isEmpty {
                    Button("Chat with Coach") {
                        Store.shared.data.chat.append(ChatMsg(role: "assistant", text: text)); Nav.shared.page = .coach
                    }
                }
            }
        }
    }
    private func run() {
        busy = true; error = nil; text = ""
        Task {
            do { try await AI.stream(system: Coach.system, messages: [ChatMsg(role: "user", text: prompt)]) { text += $0 } }
            catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}

// MARK: - Today

struct GoalsPage: View {
    @State private var store = Store.shared
    @State private var editing: Goal?
    @State private var reviewing = false
    @State private var error: String?
    var body: some View {
        @Bindable var s = store
        Scroll {
            Card(title: "Compass") {
                Text("What matters most to you, whatever this season brings.").font(.caption).foregroundStyle(.secondary)
                TextField("For example: do work I'm proud of and stay close to my family", text: $s.data.compass, axis: .vertical).field().lineLimit(2...4)
            }
            Card(title: "Season") {
                HStack(spacing: 16) {
                    TextField("Name", text: $s.data.seasonName).field().frame(maxWidth: 220)
                    DatePicker("Starts", selection: $s.data.seasonStart, displayedComponents: .date)
                    Step("\(s.data.seasonWeeks) weeks", value: $s.data.seasonWeeks, in: 4...26)
                }
                HStack {
                    Text("Day \(store.seasonDay) of \(s.data.seasonWeeks * 7), ending \(store.seasonEnd.formatted(date: .abbreviated, time: .omitted)).").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Plan a New Season") { Nav.shared.seasonSetup = true }
                }
            }
            HStack {
                Text("Goals").font(.title3.weight(.semibold))
                Spacer()
                Button("Set Goals with the Coach") { Coach.startInterview() }
                Button(reviewing ? "Reviewing…" : "Review with Coach") {
                    reviewing = true; error = nil
                    Task { do { try await Coach.reviewGoals() } catch { self.error = error.localizedDescription }; reviewing = false }
                }.disabled(reviewing || store.goals.isEmpty)
                Button("Add Goal") { editing = Goal(color: store.data.goals.count) }.buttonStyle(PillButton())
            }
            ErrorText(text: error)
            if store.goals.count > 3 {
                Label("You have \(store.goals.count) goals. Three or fewer tend to get done. Which could wait until next season?", systemImage: "exclamationmark.bubble").foregroundStyle(.orange)
            }
            ForEach(store.goals) { g in
                Card(accent: goalColor(g.color)) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(g.title).font(.title3.weight(.semibold))
                        Pill(status: g.status)
                        Spacer()
                        Text("Plan strength \(store.planStrength(g))").font(.caption).foregroundStyle(.secondary)
                        Button("Edit") { editing = g }
                    }
                    if !g.metric.isEmpty { Text("Done when: \(g.metric)").foregroundStyle(.secondary) }
                    if !g.coachNote.isEmpty { Text(g.coachNote).padding(8).frame(maxWidth: .infinity, alignment: .leading).background(g.status.color.opacity(0.1), in: .rect(cornerRadius: 8)) }
                    Trajectory(goal: g).frame(height: 120)
                }
            }
        }
        .sheet(item: $editing) { g in GoalEditor(goal: g) }
    }
}
/// Weekly focus hours across the season against the weekly target.
struct Trajectory: View {
    let goal: Goal
    @State private var store = Store.shared
    var body: some View {
        let start = store.data.seasonStart, weeks = store.data.seasonWeeks
        let hours = (0..<weeks).map { i -> (Int, Double) in
            let a = start.adding(days: i * 7), b = a.adding(days: 7)
            return (i + 1, store.data.sessions.filter { $0.goalID == goal.id && $0.start >= a && $0.start < b }.reduce(0) { $0 + $1.seconds } / 3600)
        }
        let target = goal.weeklyHours, top = max(target * 1.4, (hours.map(\.1).max() ?? 0) * 1.1)
        Chart {
            RectangleMark(yStart: .value("From", target), yEnd: .value("To", top)).foregroundStyle(GoalStatus.onTrack.color.opacity(0.1))
            RectangleMark(yStart: .value("From", target / 2), yEnd: .value("To", target)).foregroundStyle(GoalStatus.adjust.color.opacity(0.1))
            RectangleMark(yStart: .value("From", 0), yEnd: .value("To", target / 2)).foregroundStyle(GoalStatus.offTrack.color.opacity(0.08))
            ForEach(hours, id: \.0) { BarMark(x: .value("Week", $0.0), y: .value("Hours", $0.1), width: .fixed(14)).foregroundStyle(goalColor(goal.color)).cornerRadius(3) }
            RuleMark(y: .value("Target", goal.weeklyHours)).foregroundStyle(.secondary).lineStyle(.init(lineWidth: 1, dash: [4, 3]))
                .annotation(position: .top, alignment: .trailing) { Text("Target \(String(format: "%g", goal.weeklyHours))h").font(.caption2).foregroundStyle(.secondary) }
        }
        .chartXScale(domain: 0...(weeks + 1)).chartYScale(domain: 0...top)
        .chartXAxis { AxisMarks(values: .stride(by: 2)) }
        .accessibilityLabel("Weekly focus hours for \(goal.title)")
    }
}
struct GoalEditor: View {
    @State var goal: Goal
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        Form {
            TextField("Goal", text: $goal.title)
            TextField("Why it matters", text: $goal.why, axis: .vertical)
            TextField("Done when", text: $goal.metric)
            Step("\(String(format: "%g", goal.weeklyHours)) hours a week", value: $goal.weeklyHours, in: 0.5...60, step: 0.5)
            LabeledContent("Color") {
                HStack(spacing: 8) {
                    ForEach(0..<8, id: \.self) { i in
                        Button { goal.color = i } label: {
                            Circle().fill(goalColor(i)).frame(width: 20, height: 20).overlay {
                                if abs(goal.color) % 8 == i { Image(systemName: "checkmark").font(.caption2.bold()).foregroundStyle(.white) }
                            }
                        }.buttonStyle(.plain).accessibilityLabel(goalColorNames[i]).accessibilityAddTraits(abs(goal.color) % 8 == i ? .isSelected : [])
                    }
                }
            }
            TextField("Notes and next actions", text: $goal.notes, axis: .vertical).lineLimit(3...8)
        }
        .formStyle(.grouped).environment(\.fillRow, true).frame(width: 460)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    let s = Store.shared
                    if let i = s.data.goals.firstIndex(where: { $0.id == goal.id }) { s.data.goals[i] = goal } else { s.data.goals.append(goal) }
                    dismiss()
                }.disabled(goal.title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if Store.shared.data.goals.contains(where: { $0.id == goal.id }) {
                ToolbarItem(placement: .destructiveAction) {
                    Button("Archive") { if let i = Store.shared.data.goals.firstIndex(where: { $0.id == goal.id }) { Store.shared.data.goals[i].archived = true }; dismiss() }
                }
            }
        }
    }
}
extension Coach {
    static func startInterview() {
        let s = Store.shared
        s.data.chat.append(ChatMsg(role: "assistant", text: "Let's find what deserves this season. If this season went really well, what would be different when it ends? Answer however you like. I'll ask a few follow-ups, then you can turn this chat into goals."))
        Nav.shared.page = .coach
    }
}

// MARK: - Tasks

struct TaskBlockMenu: View {
    let task: TaskItem
    var body: some View {
        Menu {
            let s = Store.shared
            ForEach([30, 60, 90, 120], id: \.self) { m in
                let slot = s.nextFreeSlot(minutes: m)
                Button("\(m) min, \(slot.formatted(.dateTime.weekday().hour().minute()))") { s.block(task: task, at: slot, minutes: m) }
            }
            Divider()
            Button("Choose on the Week…") { Nav.shared.page = .week }
        } label: { Label("Time Block", systemImage: "calendar.badge.plus") }
        .fixedSize()
    }
}
struct TasksPage: View {
    @State private var store = Store.shared
    @State private var todoist = Todoist.shared
    @State private var newTask = ""
    @State private var goalFilter: UUID?
    @State private var showDone = false
    @State private var editing: TaskItem?
    var body: some View {
        let list = store.data.tasks.filter { (showDone || !$0.done) && (goalFilter == nil || $0.goalID == goalFilter) }
            .sorted { ($0.done ? 1 : 0, $0.due ?? .distantFuture, -$0.priority) < ($1.done ? 1 : 0, $1.due ?? .distantFuture, -$1.priority) }
        VStack(spacing: 0) {
            HStack {
                TextField("Add a task", text: $newTask).field().onSubmit {
                    let t = newTask.trimmingCharacters(in: .whitespaces); if !t.isEmpty { store.addTask(t, goal: goalFilter); newTask = "" }
                }
                GoalPicker(label: "Goal", goal: $goalFilter).labelsHidden().frame(width: 170)
                Toggle("Done", isOn: $showDone).toggleStyle(ChipToggle())
            }.padding(12)
            if list.isEmpty {
                ContentUnavailableView("No tasks here", systemImage: "checklist", description: Text(store.data.todoistToken ? "Add one above, or in Todoist." : "Add one above. Connect Todoist in Settings to sync both ways."))
            } else {
                List(list) { t in
                    HStack(spacing: 10) {
                        Button { store.toggleDone(t) } label: { Image(systemName: t.done ? "checkmark.circle.fill" : "circle").foregroundStyle(t.done ? .green : (t.priority == 4 ? .red : t.priority == 3 ? .orange : .secondary)).font(.title3) }
                            .buttonStyle(.plain).accessibilityLabel(t.done ? "Mark not done" : "Mark done")
                        VStack(alignment: .leading, spacing: 1) {
                            Text(t.title).strikethrough(t.done).lineLimit(2)
                            HStack(spacing: 8) {
                                if let d = t.due { Text(d.formatted(.dateTime.month(.abbreviated).day())).foregroundStyle(d < Date().startOfDay && !t.done ? .red : .secondary) }
                                if !t.project.isEmpty { Text(t.project).foregroundStyle(.secondary) }
                                if let g = store.goal(t.goalID) { GoalTag(goal: g) }
                            }.font(.caption)
                        }
                        Spacer()
                        if !t.done { TaskBlockMenu(task: t) }
                    }
                    .padding(.vertical, 2).contentShape(.rect)
                    .onTapGesture(count: 2) { editing = t }
                    .draggable(t.id.uuidString)
                    .contextMenu {
                        Button("Edit…") { editing = t }
                        Button("Start Focus") { Focus.shared.begin(title: t.title, goal: t.goalID, task: t.id); Nav.shared.page = .focus }
                        Divider()
                        Button("Delete", role: .destructive) { store.deleteTask(t) }
                    }
                }.scrollContentBackground(.hidden)
            }
            Divider()
            HStack {
                Text(store.data.todoistToken ? todoist.status + (todoist.lastSync.map { " · \($0.clock)" } ?? "") : "Tasks stay on this Mac. Connect Todoist in Settings.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if store.data.todoistToken { Button("Sync Now") { todoist.nudge() }.controlSize(.small) }
            }.padding(.horizontal, 12).padding(.vertical, 6)
        }
        .sheet(item: $editing) { TaskEditor(task: $0) }
    }
}
struct TaskEditor: View {
    @State var task: TaskItem
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        Form {
            TextField("Task", text: $task.title)
            TextField("Notes", text: $task.notes, axis: .vertical).lineLimit(2...6)
            GoalPicker(goal: $task.goalID)
            Dropdown("Priority", selection: $task.priority, options: [Opt("P1", 4), Opt("P2", 3), Opt("P3", 2), Opt("P4", 1)])
            Toggle("Due date", isOn: Binding(get: { task.due != nil }, set: { task.due = $0 ? Date() : nil }))
            if task.due != nil { DatePicker("Due", selection: Binding(get: { task.due ?? Date() }, set: { task.due = $0 }), displayedComponents: .date) }
        }
        .formStyle(.grouped).environment(\.fillRow, true).frame(width: 420)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("Save") { Store.shared.updateTask(task); dismiss() } }
        }
    }
}

// MARK: - Week (time blocking)

func hhmm(_ d: Date) -> String { let c = Calendar.current.dateComponents([.hour, .minute], from: d); return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0) }

/// The calendar: one day beside what actually happened, or the whole week.
struct WeekPage: View {
    var dayMode = false
    @State private var store = Store.shared
    @State private var start = Date().startOfDay
    @State private var editing: Block?
    @State private var draft: DraftBox?
    @State private var planning = false
    @State private var error: String?
    static let hourH: CGFloat = 52, firstHour = 0, lastHour = 24, gutter: CGFloat = 52
    private var first: Date { dayMode ? start : start.startOfWeek }
    private var days: [Date] { (0..<(dayMode ? 1 : 7)).map { first.adding(days: $0) } }
    private var isCurrent: Bool { dayMode ? Calendar.current.isDateInToday(start) : first == Date().startOfWeek }
    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                HStack(spacing: 6) {
                    round("chevron.left", dayMode ? "Previous day" : "Previous week") { start = start.adding(days: dayMode ? -1 : -7) }
                    round("chevron.right", dayMode ? "Next day" : "Next week") { start = start.adding(days: dayMode ? 1 : 7) }
                    Button(dayMode ? "Today" : "This week") { start = Date().startOfDay }.buttonStyle(QuietButton()).disabled(isCurrent)
                    Spacer()
                    IconButton(icon: store.data.prefs.blockDuringFocus ? "shield.fill" : "shield", label: "Block distractions while focusing", on: store.data.prefs.blockDuringFocus) { store.data.prefs.blockDuringFocus.toggle() }
                    Button(planning ? "Planning…" : "Plan with Coach") {
                        planning = true; error = nil
                        Task { do { draft = DraftBox(draft: try await Coach.draftWeek()) } catch { self.error = error.localizedDescription }; planning = false }
                    }.buttonStyle(PillButton()).disabled(planning)
                }
                title
            }.padding(.horizontal, 14).frame(height: 54)
            ErrorText(text: error).padding(.horizontal, 14)
            if !dayMode { dayHeader }
            else {
                HStack(spacing: 0) {
                    Color.clear.frame(width: Self.gutter, height: 1)
                    Text("Planned").frame(maxWidth: .infinity)
                    Text("Actual").frame(maxWidth: .infinity)
                }.font(.caption.weight(.medium)).foregroundStyle(.secondary).padding(.bottom, 6)
            }
            Divider()
            ScrollViewReader { proxy in
                ScrollView { grid }
                    .onAppear { proxy.scrollTo(max(0, Calendar.current.component(.hour, from: Date()) - 2), anchor: .top) }
            }
        }
        .sheet(item: $editing) { BlockEditor(block: $0) }
        .sheet(item: $draft) { PlanSheet(draft: $0.draft) }
    }
    private func round(_ icon: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 11, weight: .semibold)).frame(width: 28, height: 28)
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.12))).contentShape(.circle)
        }.buttonStyle(.plain).accessibilityLabel(label)
    }
    @ViewBuilder private var title: some View {
        if dayMode {
            HStack(spacing: 6) {
                Text(start.formatted(.dateTime.weekday(.abbreviated))).font(.system(size: 15, weight: .semibold))
                Text(start.formatted(.dateTime.day())).font(.system(size: 13, weight: .bold)).foregroundStyle(isCurrent ? .white : .primary)
                    .frame(minWidth: 24, minHeight: 24).background(isCurrent ? Color.now : .clear, in: .circle)
            }
        } else {
            Text("\(first.formatted(.dateTime.month(.abbreviated).day())) – \(first.adding(days: 6).formatted(.dateTime.month(.abbreviated).day()))").font(.system(size: 15, weight: .semibold))
        }
    }
    private var dayHeader: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: Self.gutter, height: 1)
            ForEach(days, id: \.self) { d in
                let isToday = Calendar.current.isDateInToday(d)
                HStack(spacing: 4) {
                    Text(d.formatted(.dateTime.weekday(.abbreviated))).font(.caption).foregroundStyle(.secondary)
                    Text(d.formatted(.dateTime.day())).font(.caption.weight(.semibold)).foregroundStyle(isToday ? .white : .primary)
                        .frame(minWidth: 20, minHeight: 20).background(isToday ? Color.now : .clear, in: .circle)
                }.frame(maxWidth: .infinity).padding(.bottom, 6)
            }
        }
    }
    private var grid: some View {
        GeometryReader { geo in
            let colW = (geo.size.width - Self.gutter) / CGFloat(dayMode ? 2 : 7)
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    ForEach(Self.firstHour..<Self.lastHour, id: \.self) { h in
                        Text(h == 0 ? "" : String(format: "%02d:00", h)).font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                            .frame(width: Self.gutter - 8, height: Self.hourH, alignment: .topTrailing).offset(y: -6).id(h)
                    }
                }.padding(.trailing, 8)
                ForEach(days, id: \.self) { d in DayColumn(day: d, colW: colW, editing: $editing).frame(width: colW) }
                if dayMode { ActualGrid(day: start, colW: colW).frame(width: colW) }
            }
            .overlay(alignment: .topLeading) {
                if days.contains(where: Calendar.current.isDateInToday) {
                    TimelineView(.periodic(from: .now, by: 60)) { t in
                        Text(hhmm(t.date)).font(.system(size: 10, weight: .semibold)).monospacedDigit().foregroundStyle(.white)
                            .padding(.horizontal, 4).padding(.vertical, 1).background(Color.now, in: .rect(cornerRadius: 4))
                            .frame(width: Self.gutter - 4, alignment: .trailing).offset(y: DayColumn.y(t.date) - 8).allowsHitTesting(false)
                    }
                }
            }
        }
        .frame(height: CGFloat(Self.lastHour - Self.firstHour) * Self.hourH)
    }
}

/// Focus sessions laid on the same time grid as the plan.
struct ActualGrid: View {
    let day: Date, colW: CGFloat
    @State private var store = Store.shared
    var body: some View {
        let sessions = store.data.sessions.filter { Calendar.current.isDate($0.start, inSameDayAs: day) }
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                ForEach(WeekPage.firstHour..<WeekPage.lastHour, id: \.self) { _ in Color.clear.frame(height: WeekPage.hourH).overlay(alignment: .top) { Divider() } }
            }.overlay(alignment: .leading) { Divider() }
            if sessions.isEmpty {
                Text("As you make progress, what you actually did will appear here.").font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .frame(width: colW - 40).offset(x: 20, y: DayColumn.y(Date()) + 16)
            }
            ForEach(sessions) { s in
                let c = store.goal(s.goalID).map { goalColor($0.color) } ?? .gray
                let top = DayColumn.y(s.start), h = max(22, DayColumn.y(s.start.addingTimeInterval(s.seconds)) - top)
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(s.title).font(.caption.weight(.semibold)).lineLimit(1)
                        if h > 34 { Text("\(hhmm(s.start)) - \(hhmm(s.start.addingTimeInterval(s.seconds)))").font(.caption2).opacity(0.8) }
                    }
                    Spacer(minLength: 0)
                    if let a = s.activity { Text("\(Tracker.breakdown(a, intention: s.title).score)%").font(.caption2.weight(.bold)).padding(.horizontal, 5).padding(.vertical, 1).background(.white.opacity(0.7), in: .capsule) }
                }
                .foregroundStyle(c.ink).padding(6).frame(width: colW - 8, height: h, alignment: .topLeading)
                .background(c.wash, in: .rect(cornerRadius: 8)).offset(x: 4, y: top)
            }
        }
    }
}
struct DraftBox: Identifiable { let id = UUID(); let draft: PlanDraft }

struct DayColumn: View {
    let day: Date, colW: CGFloat
    @Binding var editing: Block?
    @State private var store = Store.shared
    @State private var cal = CalendarService.shared
    @State private var targeted = false
    private func y(_ d: Date) -> CGFloat { Self.y(d) }
    static func y(_ d: Date) -> CGFloat {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return (CGFloat(c.hour ?? 0) + CGFloat(c.minute ?? 0) / 60 - CGFloat(WeekPage.firstHour)) * WeekPage.hourH
    }
    private func date(atY v: CGFloat) -> Date {
        let quarters = (v / WeekPage.hourH * 4).rounded(.down)
        return day.addingTimeInterval(Double(WeekPage.firstHour) * 3600 + Double(max(0, quarters)) * 900)
    }
    var body: some View {
        let _ = cal.revision
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                ForEach(WeekPage.firstHour..<WeekPage.lastHour, id: \.self) { _ in
                    Rectangle().fill(.clear).frame(height: WeekPage.hourH).overlay(alignment: .top) { Divider() }
                }
            }
            .background(targeted ? Color.brand.opacity(0.08) : .clear)
            .overlay(alignment: .leading) { Divider() }
            .contentShape(.rect)
            .gesture(SpatialTapGesture(count: 2).onEnded { v in
                let s = date(atY: v.location.y)
                editing = store.addBlock(Block(title: "New block", start: s, end: s.addingTimeInterval(3600)))
            })
            .dropDestination(for: String.self) { items, loc in
                guard let id = items.first.flatMap(UUID.init(uuidString:)), let t = store.task(id) else { return false }
                store.block(task: t, at: date(atY: loc.y))
                return true
            } isTargeted: { targeted = $0 }
            ForEach(cal.events(from: day, to: day.adding(days: 1)).filter { !$0.allDay }) { e in
                let goal = store.goal(store.data.prefs.eventGoals[e.id])
                let c = goal.map { goalColor($0.color) } ?? e.color
                VStack(alignment: .leading, spacing: 1) {
                    Text(e.title).font(.caption.weight(.semibold)).lineLimit(2)
                    if y(e.end) - y(e.start) > 34 { Text("\(hhmm(e.start)) - \(hhmm(e.end))").font(.caption2).opacity(0.8) }
                }.padding(6)
                    .frame(width: colW - 6, height: max(18, y(e.end) - y(e.start) - 2), alignment: .topLeading)
                    .background(c.wash, in: .rect(cornerRadius: 8)).foregroundStyle(c.ink)
                    .offset(x: 3, y: y(e.start) + 1)
                    .contextMenu {
                        ForEach(store.goals) { g in Button("Counts toward \(g.title)") { store.data.prefs.eventGoals[e.id] = g.id } }
                        if goal != nil { Button("Remove Goal") { store.data.prefs.eventGoals[e.id] = nil } }
                    }
            }
            ForEach(store.blocks(on: day)) { b in BlockView(block: b, colW: colW, top: y(b.start), height: y(b.end) - y(b.start), editing: $editing) }
            if Calendar.current.isDateInToday(day) {
                TimelineView(.periodic(from: .now, by: 60)) { t in
                    Rectangle().fill(Color.now).frame(width: colW, height: 1.5)
                        .overlay(alignment: .leading) { Circle().fill(Color.now).frame(width: 7, height: 7).offset(x: -3) }
                        .offset(y: y(t.date)).allowsHitTesting(false)
                }
            }
        }
    }
}
struct BlockView: View {
    let block: Block, colW: CGFloat, top: CGFloat, height: CGFloat
    @Binding var editing: Block?
    @State private var store = Store.shared
    @State private var drag = CGSize.zero
    @State private var grow: CGFloat = 0
    @State private var detail = false
    private static let quarter = WeekPage.hourH / 4
    private func snap(_ v: CGFloat) -> CGFloat { (v / Self.quarter).rounded() * Self.quarter }
    var body: some View {
        let c = store.goal(block.goalID).map { goalColor($0.color) } ?? .gray
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 3) {
                if let e = block.energy { Image(systemName: e == .energizing ? "bolt.fill" : "battery.25percent").font(.system(size: 8)).accessibilityLabel(e.rawValue) }
                Text(block.title).font(.caption.weight(.semibold)).lineLimit(2)
            }
            if height > 34 { Text("\(hhmm(block.start)) - \(hhmm(block.end))").font(.caption2).opacity(0.8) }
            Spacer(minLength: 0)
        }
        .foregroundStyle(c.ink)
        .padding(6)
        .frame(width: colW - 6, height: max(18, height + grow - 2), alignment: .topLeading)
        .background(Color.surface, in: .rect(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).fill(c.opacity(0.22)).allowsHitTesting(false) }
        .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 2).fill(c).frame(width: 3).padding(.vertical, 4).padding(.leading, 2).allowsHitTesting(false) }
        .popover(isPresented: $detail, arrowEdge: .trailing) { BlockDetail(block: block, editing: $editing, shown: $detail) }
        .overlay(alignment: .bottom) {
            Color.clear.frame(height: 8).contentShape(.rect)
                .onHover { $0 ? NSCursor.resizeUpDown.push() : NSCursor.pop() }
                .gesture(DragGesture(coordinateSpace: .global)
                    .onChanged { grow = max(Self.quarter - height, snap($0.translation.height)) }
                    .onEnded { _ in
                        var b = block; b.end = b.end.addingTimeInterval(Double(grow / Self.quarter) * 900); grow = 0
                        store.updateBlock(b)
                    })
        }
        .contentShape(.rect)
        .onTapGesture(count: 2) { editing = block }
        .onTapGesture { detail = true }
        .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .global)
            .onChanged { drag = CGSize(width: ($0.translation.width / colW).rounded() * colW, height: snap($0.translation.height)) }
            .onEnded { _ in
                let days = Int((drag.width / colW).rounded()), mins = Double(drag.height / Self.quarter) * 900
                var b = block
                b.start = b.start.adding(days: days).addingTimeInterval(mins); b.end = b.end.adding(days: days).addingTimeInterval(mins)
                drag = .zero
                store.updateBlock(b)
            })
        .contextMenu {
            Button("Start Focus") { Focus.shared.begin(title: block.title, goal: block.goalID, task: block.taskID); Nav.shared.page = .focus }
            Button("Edit…") { editing = block }
            Divider()
            ForEach([Energy.energizing, .draining], id: \.self) { e in
                Toggle(e.rawValue.capitalized, isOn: Binding(get: { block.energy == e }, set: { var b = block; b.energy = $0 ? e : nil; store.updateBlock(b) }))
                    .keyboardShortcut(KeyEquivalent(e == .energizing ? "e" : "d"), modifiers: [])
            }
            Divider()
            Button("Delete", role: .destructive) { store.deleteBlock(block) }
        }
        .offset(x: 3 + drag.width, y: top + 1 + drag.height)
        .zIndex(drag == .zero ? 0 : 1)
        .animation(.spring(duration: 0.2, bounce: 0), value: drag)
    }
}
struct BlockEditor: View {
    @State var block: Block
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        Form {
            TextField("Title", text: $block.title)
            GoalPicker(goal: $block.goalID)
            DatePicker("Starts", selection: $block.start)
            DatePicker("Ends", selection: $block.end, in: block.start...)
        }
        .formStyle(.grouped).environment(\.fillRow, true).frame(width: 400)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .destructiveAction) { Button("Delete") { Store.shared.deleteBlock(block); dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("Save") { Store.shared.updateBlock(block); dismiss() } }
        }
    }
}
struct PlanSheet: View {
    @State var draft: PlanDraft
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Suggested Week").font(.title2.weight(.semibold))
            if let s = draft.summary { Text(s).foregroundStyle(.secondary) }
            List($draft.changes) { $c in
                Toggle(isOn: $c.keep) {
                    VStack(alignment: .leading) {
                        Text("\(c.action.capitalized): \(c.title)").font(.headline)
                        Text([c.day, c.start, c.minutes.map { "\($0) min" }].compactMap { $0 }.joined(separator: " · ")).font(.caption)
                        if let r = c.reason { Text(r).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }.toggleStyle(CheckToggle()).frame(minHeight: 280)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply Selected") { Coach.apply(draft.changes); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 540, height: 500)
    }
}

// MARK: - Focus

struct TimerButtons: View {
    @State private var focus = Focus.shared
    var body: some View {
        HStack {
            if let e = focus.exitAt {
                TimelineView(.periodic(from: .now, by: 1)) { t in Text("Ending in \(max(0, Int(e.timeIntervalSince(t.date))))s").monospacedDigit() }
                Button("Stay Focused") { focus.cancelExit() }.buttonStyle(PillButton())
            } else {
                if focus.phase == .rest { Button("Skip Break") { focus.skipBreak() } }
                else { Button(focus.paused ? "Resume" : "Pause") { focus.togglePause() } }
                Button("End Session") { focus.requestStop() }
            }
        }
    }
}
struct FocusPage: View {
    @State private var focus = Focus.shared
    @State private var store = Store.shared
    var body: some View {
        @Bindable var s = store
        @Bindable var f = focus
        let tint = store.goal(focus.goalID).map { goalColor($0.color) } ?? Color.brand
        let ring = focus.phase == .rest && focus.active ? goalPalette[4] : tint
        Scroll {
            Card(accent: tint) {
                VStack(spacing: 14) {
                    if focus.active {
                        Text(focus.phase == .rest ? "Break" : (focus.title.isEmpty ? "Focus" : focus.title)).font(.title3.weight(.semibold))
                    } else {
                        Segments(selection: Binding(get: { s.data.prefs.timerMode }, set: { s.data.prefs.timerMode = $0 }), options: TimerMode.allCases.map { Opt($0.rawValue, $0) }).frame(maxWidth: 340)
                        HStack {
                            TextField("What are you focusing on?", text: $f.title).field()
                            GoalPicker(goal: $f.goalID).labelsHidden().frame(width: 170)
                        }.frame(maxWidth: 520)
                    }
                    ZStack {
                        Circle().stroke(ring.wash, lineWidth: 10)
                        if focus.active && focus.mode != .stopwatch {
                            Circle().trim(from: 0, to: focus.progress).stroke(ring, style: .init(lineWidth: 10, lineCap: .round)).rotationEffect(.degrees(-90))
                        }
                        Text(focus.active ? focus.display : idleDisplay).font(.system(size: 64, weight: .bold, design: .rounded)).monospacedDigit().foregroundStyle(focus.active ? ring.ink : Color.primary)
                    }.frame(width: 260, height: 260)
                    if focus.active {
                        if focus.mode == .pomodoro { Text("Round \(focus.cycle) of \(store.data.prefs.cycles)").foregroundStyle(.secondary) }
                        TimerButtons()
                    } else {
                        Button("Start Focus") { focus.begin() }.buttonStyle(PillButton()).controlSize(.large)
                        settings
                    }
                }.frame(maxWidth: .infinity)
            }
            if let r = focus.finished, !focus.active { FocusSummary(session: r) }
            HStack(alignment: .top, spacing: 16) {
                MusicCard()
                BlockCard().frame(maxWidth: 340)
            }
        }
    }
    private var idleDisplay: String {
        let p = store.data.prefs
        switch p.timerMode { case .stopwatch: return "00:00"; case .countdown: return String(format: "%02d:00", p.countdownMinutes); case .pomodoro: return String(format: "%02d:00", p.workMinutes) }
    }
    @ViewBuilder private var settings: some View {
        @Bindable var s = store
        switch s.data.prefs.timerMode {
        case .stopwatch: Text("Counts up until you stop.").font(.caption).foregroundStyle(.secondary)
        case .countdown: Step("\(s.data.prefs.countdownMinutes) minutes", value: $s.data.prefs.countdownMinutes, in: 5...240, step: 5).fixedSize()
        case .pomodoro:
            HStack(spacing: 16) {
                Step("Focus \(s.data.prefs.workMinutes)m", value: $s.data.prefs.workMinutes, in: 5...120, step: 5)
                Step("Break \(s.data.prefs.breakMinutes)m", value: $s.data.prefs.breakMinutes, in: 1...30)
                Step("Long \(s.data.prefs.longBreakMinutes)m", value: $s.data.prefs.longBreakMinutes, in: 5...60, step: 5)
                Step("\(s.data.prefs.cycles) rounds", value: $s.data.prefs.cycles, in: 1...8)
            }.fixedSize()
        }
    }
}
struct MusicCard: View {
    @State private var music = Music.shared
    @State private var store = Store.shared
    var body: some View {
        @Bindable var s = store
        Card(title: "Sound") {
            Segments(selection: Binding(get: { s.data.prefs.musicSource }, set: { s.data.prefs.musicSource = $0; music.reload() }), options: MusicSource.allCases.map { Opt($0.rawValue, $0) })
            switch s.data.prefs.musicSource {
            case .library:
                Dropdown("Style", selection: Binding(get: { s.data.prefs.musicCategory }, set: { s.data.prefs.musicCategory = $0; music.reload() }), options: music.categories.map { Opt($0, $0) }).labelsHidden()
            case .folder:
                HStack {
                    Text(s.data.prefs.musicFolder ?? "No folder chosen").lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                    Button("Choose…") {
                        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false
                        if p.runModal() == .OK { s.data.prefs.musicFolder = p.url?.path; music.reload() }
                    }
                }
            case .spotify: TextField("Optional Spotify link, like spotify:playlist:…", text: $s.data.prefs.externalURI).field()
            case .appleMusic: TextField("Optional playlist name", text: $s.data.prefs.externalURI).field()
            case .none: EmptyView()
            }
            HStack {
                Button { music.toggle() } label: { Image(systemName: music.playing ? "pause.fill" : "play.fill") }.accessibilityLabel(music.playing ? "Pause" : "Play")
                Button { music.next() } label: { Image(systemName: "forward.fill") }.accessibilityLabel("Next track")
                Text(music.nowPlaying).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Bar(value: Binding(get: { s.data.prefs.musicVolume }, set: { music.setVolume($0) })).frame(width: 100).accessibilityLabel("Music volume")
            }
            ErrorText(text: music.status)
            Toggle("Play when a session starts", isOn: $s.data.prefs.playOnFocus)
            Divider()
            Text("Soundscapes").font(.subheadline.weight(.semibold))
            Text("Mix these on their own or under your music.").font(.caption).foregroundStyle(.secondary)
            Grid(alignment: .leading, verticalSpacing: 4) {
                ForEach(NoiseSynth.names, id: \.self) { n in
                    GridRow {
                        Text(n).font(.callout)
                        Bar(value: Binding(get: { music.level(n) }, set: { music.setLevel(n, $0) })).accessibilityLabel(n)
                    }
                }
            }
        }
    }
}
struct BlockCard: View {
    @State private var store = Store.shared
    @State private var blocker = Blocker.shared
    @State private var newSite = ""
    var body: some View {
        @Bindable var s = store
        Card(title: "Blocking") {
            Toggle("Block distractions during focus", isOn: $s.data.prefs.blockDuringFocus)
            Text("Ending a session early takes \(s.data.prefs.exitDelay) seconds.").font(.caption).foregroundStyle(.secondary)
            if !blocker.helperInstalled {
                Text("Apps can be blocked now. Website blocking needs one admin password prompt.").font(.caption).foregroundStyle(.secondary)
                Button("Set Up Website Blocking…") { blocker.installHelper() }
            }
            if !blocker.message.isEmpty { Text(blocker.message).font(.caption).foregroundStyle(.secondary) }
            Text("\(s.data.prefs.blockSites.count) sites, \(s.data.prefs.blockApps.count) apps blocked. Change these in Settings.").font(.caption).foregroundStyle(.secondary)
            SettingsLink { Text("Edit List…") }
        }
    }
}

// MARK: - Coach

struct CoachPage: View {
    @State private var store = Store.shared
    @State private var nav = Nav.shared
    @State private var busy = false
    @State private var error: String?
    @State private var voice = Voice.shared
    @State private var transcribing = false
    @State private var extracted: Extracted?
    private let starters = ["What should I change this week?", "Which goal should I drop?", "Review my last week honestly", "I'm overwhelmed. Help me choose."]
    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if store.data.chat.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Ask your coach anything about your goals, week or habits.").foregroundStyle(.secondary)
                                ForEach(starters, id: \.self) { p in Button(p) { nav.coachDraft = p; send() } }
                            }
                        }
                        ForEach(store.data.chat) { m in
                            HStack {
                                if m.role == "user" { Spacer(minLength: 80) }
                                if m.role == "user" {
                                    Text(m.text).textSelection(.enabled).foregroundStyle(Color.onBrand).padding(.horizontal, 14).padding(.vertical, 9)
                                        .background(Color.brand, in: .rect(cornerRadius: 18))
                                } else {
                                    Text(m.text.isEmpty ? "…" : m.text).textSelection(.enabled).lineSpacing(3)
                                }
                                if m.role != "user" { Spacer(minLength: 80) }
                            }.id(m.id)
                        }
                    }.padding(20).frame(maxWidth: 780, alignment: .leading).frame(maxWidth: .infinity)
                }
                .onChange(of: store.data.chat.last?.text) { if let id = store.data.chat.last?.id { proxy.scrollTo(id, anchor: .bottom) } }
            }
            ErrorText(text: error).padding(.horizontal, 20)
            HStack(alignment: .bottom, spacing: 8) {
                TextField(transcribing ? "Transcribing…" : "Ask your coach…", text: $nav.coachDraft, axis: .vertical).textFieldStyle(.plain).lineLimit(1...5)
                    .onSubmit { send() }.padding(.vertical, 6)
                Button { toggleVoice() } label: { Image(systemName: voice.recording ? "stop.circle.fill" : "mic").foregroundStyle(voice.recording ? .red : .secondary).frame(width: 28, height: 28) }
                    .buttonStyle(.plain).accessibilityLabel(voice.recording ? "Stop recording" : "Record a message").disabled(transcribing)
                Button { send() } label: { Image(systemName: "arrow.up").font(.callout.weight(.bold)).foregroundStyle(Color.onBrand).frame(width: 28, height: 28).background(Color.brand, in: .circle) }
                    .buttonStyle(.plain).accessibilityLabel("Send").disabled(busy || nav.coachDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.leading, 16).padding(.trailing, 8).padding(.vertical, 6).surface(22)
            .padding(14).frame(maxWidth: 780)
        }
        .toolbar {
            Button("Turn into Goals") { adopt() }.disabled(store.data.chat.isEmpty || busy)
            Button("Clear") { store.data.chat = [] }.disabled(store.data.chat.isEmpty)
        }
    }
    private func send() {
        let t = nav.coachDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !busy else { return }
        nav.coachDraft = ""; error = nil; busy = true
        store.data.chat.append(ChatMsg(role: "user", text: t))
        let history = Array(store.data.chat.suffix(30))
        let reply = ChatMsg(role: "assistant", text: "")
        store.data.chat.append(reply)
        Task {
            do {
                try await AI.stream(system: Coach.system, messages: history) { tok in
                    if let i = store.data.chat.firstIndex(where: { $0.id == reply.id }) { store.data.chat[i].text += tok }
                }
            } catch {
                self.error = error.localizedDescription
                store.data.chat.removeAll { $0.id == reply.id && $0.text.isEmpty }
            }
            busy = false
        }
    }
    private func adopt() {
        let text = store.data.chat.suffix(30).map { "\($0.role): \($0.text)" }.joined(separator: "\n")
        busy = true; error = nil
        Task {
            do { Coach.adopt(try await Coach.extract(from: text)); Nav.shared.page = .goals } catch { self.error = error.localizedDescription }
            busy = false
        }
    }
    private func toggleVoice() {
        if voice.recording {
            guard let u = voice.stop() else { return }
            transcribing = true
            Task {
                do { nav.coachDraft += try await Voice.transcribe(u) } catch { self.error = error.localizedDescription }
                try? FileManager.default.removeItem(at: u)
                transcribing = false
            }
        } else { Task { error = await voice.start() } }
    }
}

// MARK: - Journal

enum Prompts {
    static let all = [
        "What gave you energy yesterday, and what drained it?",
        "What would make today feel worthwhile, even if nothing else got done?",
        "What are you avoiding right now? What's the smallest step toward it?",
        "If this season ended tomorrow, what would you wish you'd spent more time on?",
        "What's one thing you've said yes to that you'd like to say no to?",
        "Who do you want to show up for this week, and how?",
        "What went better than you expected recently? Why?",
        "Which of your goals still excites you? Which feels like an obligation?",
        "What are you learning about how you work best?",
        "What would you do today if it had to be easy?",
        "What's worrying you? What part of it is in your control?",
        "What are you grateful for that you usually overlook?",
        "What would the person you want to be in five years do today?",
        "Where did your time go this week, and does that match what you value?",
    ]
    static func today(_ d: Date) -> String { all[(Calendar.current.ordinality(of: .day, in: .era, for: d) ?? 0) % all.count] }
}
struct JournalPage: View {
    @State private var store = Store.shared
    @State private var day = Date()
    private var binding: Binding<String> {
        Binding(get: { store.data.journal.first { $0.id == day.dayKey }?.text ?? "" }, set: { v in
            if let i = store.data.journal.firstIndex(where: { $0.id == day.dayKey }) { store.data.journal[i].text = v }
            else { store.data.journal.append(JournalEntry(id: day.dayKey, prompt: Prompts.today(day), text: v)) }
        })
    }
    var body: some View {
        @Bindable var s = store
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button { day = day.adding(days: -1) } label: { Image(systemName: "chevron.left") }.accessibilityLabel("Previous day")
                Text(day.formatted(date: .long, time: .omitted)).font(.headline)
                Button { day = day.adding(days: 1) } label: { Image(systemName: "chevron.right") }.accessibilityLabel("Next day").disabled(Calendar.current.isDateInToday(day))
                Spacer()
                Toggle("Coach can read my journal", isOn: $s.data.prefs.coachReadsJournal).toggleStyle(CheckToggle())
            }
            Text(store.data.journal.first { $0.id == day.dayKey }?.prompt ?? Prompts.today(day)).font(.system(.title2, design: .serif)).lineLimit(3)
            TextEditor(text: binding).font(.body).scrollContentBackground(.hidden).padding(8)
                .frame(minHeight: 200, idealHeight: 400, maxHeight: .infinity)
                .surface(10)
        }.padding(20).frame(maxWidth: 780).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Capture (long voice brain dumps and pasted notes)

struct CapturePage: View {
    @State private var store = Store.shared
    @State private var voice = Voice.shared
    @State private var selected: UUID?
    @State private var busy = ""
    @State private var error: String?
    @State private var pasting = false
    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                VStack(spacing: 10) {
                    Button { toggle() } label: {
                        Label(voice.recording ? "Stop · \(Int(voice.elapsed) / 60):\(String(format: "%02d", Int(voice.elapsed) % 60))" : "Record Brain Dump", systemImage: voice.recording ? "stop.fill" : "mic.fill").frame(maxWidth: .infinity)
                    }.buttonStyle(PillButton(color: voice.recording ? goalPalette[1] : nil)).controlSize(.large)
                    if voice.recording { ProgressView(value: voice.level).accessibilityLabel("Input level") }
                    else { Text("Talk for up to 90 minutes. It's transcribed on this Mac.").font(.caption).foregroundStyle(.secondary) }
                    Button("Add Notes (Wispr Flow, Others)…") { pasting = true }.frame(maxWidth: .infinity)
                }.padding(12)
                List(store.data.captures.sorted { $0.date > $1.date }, selection: $selected) { c in
                    VStack(alignment: .leading) {
                        Text(c.title).lineLimit(1)
                        Text("\(c.source) · \(c.date.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                    }.tag(c.id).contextMenu { Button("Delete", role: .destructive) { delete(c) } }
                }.scrollContentBackground(.hidden)
            }.frame(minWidth: 240, idealWidth: 270, maxWidth: 340)
            detail.frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(isPresented: $pasting) { NotesSheet { selected = $0 } }
    }
    @ViewBuilder private var detail: some View {
        if let i = store.data.captures.firstIndex(where: { $0.id == selected }) {
            @Bindable var s = store
            let c = s.data.captures[i]
            VStack(alignment: .leading, spacing: 10) {
                TextField("Title", text: $s.data.captures[i].title).textFieldStyle(.plain).font(.title3.weight(.semibold))
                ErrorText(text: error)
                HStack {
                    if let a = c.audioFile, c.text.isEmpty { Button("Transcribe") { transcribe(c.id, Store.dir.appendingPathComponent("audio/\(a)")) }.disabled(!busy.isEmpty) }
                    Button("Ask Follow-ups") { followUps(i) }.disabled(!busy.isEmpty || c.text.isEmpty)
                    Button("Extract Goals and Tasks") { extract(c.text) }.disabled(!busy.isEmpty || c.text.isEmpty)
                    if !busy.isEmpty { ProgressView().controlSize(.small); Text(busy).font(.caption).foregroundStyle(.secondary) }
                }
                if !c.followUps.isEmpty { Text(c.followUps).textSelection(.enabled).padding(10).frame(maxWidth: .infinity, alignment: .leading).background(Color.brand.opacity(0.08), in: .rect(cornerRadius: 8)) }
                TextEditor(text: $s.data.captures[i].text).scrollContentBackground(.hidden).padding(6).surface(8)
            }.padding(16)
        } else {
            ContentUnavailableView("Get it out of your head", systemImage: "waveform", description: Text("Record a brain dump, then let the coach ask follow-ups and pull out goals and tasks."))
        }
    }
    private func toggle() {
        error = nil
        if voice.recording {
            guard let u = voice.stop() else { return }
            let c = Capture(title: "Brain dump, \(Date().formatted(date: .abbreviated, time: .shortened))", audioFile: u.lastPathComponent)
            store.data.captures.append(c); selected = c.id
            transcribe(c.id, u)
        } else { Task { error = await voice.start() } }
    }
    private func transcribe(_ id: UUID, _ u: URL) {
        busy = "Transcribing…"
        Task {
            do {
                let t = try await Voice.transcribe(u)
                if let i = store.data.captures.firstIndex(where: { $0.id == id }) { store.data.captures[i].text = t }
            } catch { self.error = "Transcription failed, but the recording is safe. \(error.localizedDescription)" }
            busy = ""
        }
    }
    private func followUps(_ i: Int) {
        let id = store.data.captures[i].id, text = store.data.captures[i].text
        busy = "Coach is reading…"; error = nil
        Task {
            do {
                let r = try await AI.complete(system: Coach.persona, prompt: "Here's my brain dump. Ask me the 3 questions that would help me most, then name the one thing you'd act on first.\n\n\(text)")
                if let i = store.data.captures.firstIndex(where: { $0.id == id }) { store.data.captures[i].followUps = r }
            } catch { self.error = error.localizedDescription }
            busy = ""
        }
    }
    private func extract(_ text: String) {
        busy = "Pulling out goals and tasks…"; error = nil
        Task {
            do { Coach.adopt(try await Coach.extract(from: text)); Nav.shared.page = .goals } catch { self.error = error.localizedDescription }
            busy = ""
        }
    }
    private func delete(_ c: Capture) {
        if let a = c.audioFile { try? FileManager.default.removeItem(at: Store.dir.appendingPathComponent("audio/\(a)")) }
        store.data.captures.removeAll { $0.id == c.id }
    }
}
struct NotesSheet: View {
    var onAdd: (UUID) -> Void
    @State private var text = ""
    @State private var title = ""
    @State private var importing = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add Notes").font(.title3.weight(.semibold))
            Text("Paste from Wispr Flow or anywhere else, or import a text file. The coach reads your latest notes.").font(.callout).foregroundStyle(.secondary)
            TextField("Title", text: $title).field()
            TextEditor(text: $text).scrollContentBackground(.hidden).padding(6).surface(8)
            HStack {
                Button("Import File…") { importing = true }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add") {
                    let c = Capture(title: title.isEmpty ? "Notes" : title, source: "Notes", text: text)
                    Store.shared.data.captures.append(c); onAdd(c.id); dismiss()
                }.keyboardShortcut(.defaultAction).disabled(text.isEmpty)
            }
        }
        .padding(20).frame(width: 520, height: 420)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText, .text]) { r in
            if case .success(let u) = r {
                let open = u.startAccessingSecurityScopedResource(); defer { if open { u.stopAccessingSecurityScopedResource() } }
                text = (try? String(contentsOf: u, encoding: .utf8)) ?? text
                if title.isEmpty { title = u.deletingPathExtension().lastPathComponent }
            }
        }
    }
}

// MARK: - Insights

struct InsightsPage: View {
    @State private var store = Store.shared
    var body: some View {
        let week = Date().startOfWeek
        let thisWeek = store.data.sessions.filter { $0.start >= week }
        let total = thisWeek.reduce(0) { $0 + $1.seconds }
        let quality = thisWeek.isEmpty ? 0 : thisWeek.map(\.quality).reduce(0, +) / thisWeek.count
        let days = (0..<7).map { week.adding(days: $0).formatted(.dateTime.weekday(.abbreviated)) }
        Scroll {
            HStack(spacing: 16) {
                stat("Focused this week", hm(total), goalPalette[0])
                stat("Sessions", "\(thisWeek.count)", goalPalette[2])
                stat("Average quality", thisWeek.isEmpty ? "None yet" : "\(quality)", goalPalette[3])
            }
            AccountabilityCard()
            Card(title: "This Week by Day") {
                Chart(thisWeek) { s in
                    BarMark(x: .value("Day", s.start.formatted(.dateTime.weekday(.abbreviated))), y: .value("Hours", s.seconds / 3600), width: .ratio(0.6))
                        .foregroundStyle(store.goal(s.goalID).map { goalColor($0.color) } ?? Color.gray.opacity(0.5)).cornerRadius(3)
                }.chartXScale(domain: days).frame(height: 180).accessibilityLabel("Focus hours by day this week, colored by goal")
                HStack(spacing: 6) { ForEach(store.goals) { GoalTag(goal: $0) } }
            }
            Card(title: "By Goal") {
                if store.goals.isEmpty { Text("Add a goal to see this.").foregroundStyle(.secondary) }
                ForEach(store.goals) { g in
                    let sec = store.focused(goal: g.id, since: store.data.seasonStart), w = store.focused(goal: g.id, since: week) / 3600
                    VStack(alignment: .leading, spacing: 4) {
                        HStack { Text(g.title); Spacer(); Text("\(String(format: "%.1f", w)) of \(String(format: "%g", g.weeklyHours))h this week · \(hm(sec)) this season").font(.caption).foregroundStyle(.secondary).monospacedDigit() }
                        GoalBar(value: g.weeklyHours > 0 ? w / g.weeklyHours : 0, color: goalColor(g.color))
                    }
                }
            }
            Card(title: "Recent Sessions") {
                let recent = store.data.sessions.sorted { $0.start > $1.start }.prefix(10)
                if recent.isEmpty { Text("Finished sessions appear here.").foregroundStyle(.secondary) }
                ForEach(Array(recent)) { s in
                    HStack(spacing: 8) {
                        Circle().fill(store.goal(s.goalID).map { goalColor($0.color) } ?? Color.secondary.opacity(0.4)).frame(width: 8, height: 8)
                        Text(s.title).lineLimit(1)
                        Spacer()
                        Text("\(s.start.formatted(.dateTime.month(.abbreviated).day())) · \(hm(s.seconds))").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        let q = s.quality >= 70 ? GoalStatus.onTrack.color : s.quality >= 40 ? GoalStatus.adjust.color : GoalStatus.offTrack.color
                        Text("\(s.quality)").font(.caption.weight(.semibold)).monospacedDigit().foregroundStyle(q.ink).frame(width: 34).padding(.vertical, 1).background(q.wash, in: .capsule).accessibilityLabel("Quality \(s.quality)")
                    }
                }
            }
            CoachBrief(title: "Weekly Coaching", button: "Get This Week's Review", prompt: "Give me an honest review of my season so far. Be blunt: say plainly which goals I'm neglecting and where my time is going against my priorities, using the accountability numbers, my reflections and energy tags. Then give one specific fix per problem, and say what to drop if I'm overcommitted. No flattery. Under 180 words.")
        }
    }
    private func stat(_ t: String, _ v: String, _ c: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(t).font(.caption.weight(.medium))
            Text(v).font(.system(size: 28, weight: .bold, design: .rounded)).monospacedDigit()
        }
        .foregroundStyle(c.ink).padding(16).frame(maxWidth: .infinity, alignment: .leading).background(c.wash, in: .rect(cornerRadius: 14))
    }
}

// MARK: - Settings

struct SettingsView: View {
    var body: some View {
        TabView {
            AISettings().tabItem { Label("AI", systemImage: "sparkles") }
            ConnectSettings().tabItem { Label("Connections", systemImage: "link") }
            BlockSettings().tabItem { Label("Blocking", systemImage: "hand.raised") }
            CreditsView().tabItem { Label("Music Credits", systemImage: "music.note") }
        }.frame(width: 560, height: 460)
    }
}
struct AISettings: View {
    @State private var store = Store.shared
    @State private var key = ""
    @State private var models: [String] = []
    @State private var result = ""
    @State private var testing = false
    var body: some View {
        @Bindable var s = store
        let p = s.data.prefs.provider
        Form {
            Dropdown("Provider", selection: $s.data.prefs.provider, options: AIProvider.allCases.map { Opt($0.name, $0) })
            if p == .custom { TextField("Server address", text: $s.data.prefs.customURL) }
            if !p.isLocal || p == .custom {
                SecureField("API key", text: $key).onChange(of: key) { Keychain.set("ai." + p.rawValue, key) }
                if !p.isLocal { Text("Kept in your Mac's Keychain and sent only to \(p.name). Usage is billed by them. A Claude or ChatGPT app subscription doesn't include an API key.").font(.caption).foregroundStyle(.secondary) }
            }
            if p == .ollama { Text("Free and private. Install Ollama from ollama.com, then run a model such as llama3.2.").font(.caption).foregroundStyle(.secondary) }
            TextField("Model", text: Binding(get: { s.data.prefs.models[p.rawValue] ?? (p == .ollama ? "llama3.2" : "") }, set: { s.data.prefs.models[p.rawValue] = $0 }))
            if !models.isEmpty {
                Dropdown("Available", selection: Binding(get: { s.data.prefs.models[p.rawValue] ?? "" }, set: { s.data.prefs.models[p.rawValue] = $0 }), options: [Opt("Choose…", "")] + models.map { Opt($0, $0) })
            }
            HStack {
                Button(testing ? "Testing…" : "Test Connection") {
                    testing = true; result = ""
                    Task {
                        do { let r = try await AI.complete(system: "Reply with one word.", prompt: "Say ready."); result = "Connected: \(r.prefix(40))" }
                        catch { result = error.localizedDescription }
                        testing = false
                    }
                }.disabled(testing)
                Text(result).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
        }
        .formStyle(.grouped).environment(\.fillRow, true)
        .task(id: p) { key = Keychain.get("ai." + p.rawValue); result = ""; models = await AI.listModels(p) }
    }
}
struct ConnectSettings: View {
    @State private var store = Store.shared
    @State private var todoist = Todoist.shared
    @State private var cal = CalendarService.shared
    @State private var google = GoogleCalendar.shared
    @State private var token = ""
    var body: some View {
        @Bindable var s = store
        Form {
            Section("Todoist") {
                if s.data.todoistToken {
                    LabeledContent("Status", value: todoist.status)
                    Button("Disconnect") { todoist.disconnect() }
                } else {
                    SecureField("API token", text: $token, prompt: Text("Todoist API token")).field()
                    Text("Find it in Todoist under Settings → Integrations → Developer. Free Todoist accounts work.").font(.caption).foregroundStyle(.secondary)
                    Button("Connect") { Task { await todoist.connect(token); token = "" } }.disabled(token.isEmpty)
                }
            }
            Section("Google Calendar") {
                if google.connected {
                    LabeledContent("Status", value: google.status.isEmpty ? "Connecting…" : google.status)
                    HStack { Button("Sync Now") { Task { await google.sync() } }; Button("Disconnect") { google.disconnect() } }
                } else {
                    Button("Sign in with Google") { Task { await google.connect() } }
                        .buttonStyle(PillButton()).disabled(GoogleClient.id.isEmpty)
                    if GoogleClient.id.isEmpty { Text("This build has no Google client. See the README.").font(.caption).foregroundStyle(.secondary) }
                    if !google.status.isEmpty { Text(google.status).font(.caption).foregroundStyle(.secondary) }
                }
            }
            Section("Apple Calendar") {
                if cal.granted { LabeledContent("Status", value: "Connected") }
                else { Button("Connect Apple Calendar") { Task { await cal.request() } } }
            }
            if cal.granted || google.connected {
                Section("Time blocks") {
                    Dropdown("Save time blocks to", selection: $s.data.prefs.calendarID, options: [Opt("Default calendar", String?.none)]
                        + cal.calendars.map { Opt("Apple · \($0.title)", String?.some($0.calendarIdentifier), Color(cgColor: $0.cgColor)) }
                        + google.calendars.filter(\.writable).map { Opt("Google · \($0.title)", String?.some("google:\($0.id)"), $0.color) })
                }
            }
        }.formStyle(.grouped).environment(\.fillRow, true)
    }
}
struct BlockSettings: View {
    @State private var store = Store.shared
    @State private var blocker = Blocker.shared
    @State private var site = ""
    var body: some View {
        @Bindable var s = store
        Form {
            Toggle("Block during focus sessions", isOn: $s.data.prefs.blockDuringFocus)
            Step("Wait \(s.data.prefs.exitDelay) seconds to end early", value: $s.data.prefs.exitDelay, in: 0...600, step: 15)
            Section("Websites") {
                if blocker.helperInstalled { Button("Remove Website Blocking…") { blocker.uninstallHelper() } }
                else { Button("Set Up Website Blocking…") { blocker.installHelper() } }
                if !blocker.message.isEmpty { Text(blocker.message).font(.caption).foregroundStyle(.secondary) }
                HStack {
                    TextField("example.com", text: $site).onSubmit(add)
                    Button("Add", action: add).disabled(clean == nil)
                }
                ForEach(s.data.prefs.blockSites, id: \.self) { d in
                    HStack { Text(d); Spacer(); Button("Remove") { s.data.prefs.blockSites.removeAll { $0 == d } } }
                }
            }
            Section("Apps") {
                Button("Add App…") {
                    let p = NSOpenPanel(); p.allowedContentTypes = [.application]; p.directoryURL = URL(fileURLWithPath: "/Applications")
                    if p.runModal() == .OK, let id = p.url.flatMap({ Bundle(url: $0)?.bundleIdentifier }), !s.data.prefs.blockApps.contains(id) { s.data.prefs.blockApps.append(id) }
                }
                ForEach(s.data.prefs.blockApps, id: \.self) { a in
                    HStack { Text(a); Spacer(); Button("Remove") { s.data.prefs.blockApps.removeAll { $0 == a } } }
                }
            }
        }.formStyle(.grouped).environment(\.fillRow, true)
    }
    /// Same rule the root helper enforces, so a bad entry can't break every block.
    private var clean: String? {
        var d = site.lowercased().trimmingCharacters(in: .whitespaces)
        for p in ["https://", "http://", "www."] where d.hasPrefix(p) { d.removeFirst(p.count) }
        d = d.split(separator: "/").first.map(String.init) ?? ""
        guard d.contains("."), !d.hasPrefix("."), !d.hasSuffix("."), !d.hasPrefix("-"), !d.contains(".."), d.allSatisfy({ ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "." || $0 == "-" }) else { return nil }
        return d
    }
    private func add() {
        guard let d = clean else { return }
        if !store.data.prefs.blockSites.contains(d) { store.data.prefs.blockSites.append(d) }
        site = ""
    }
}
struct CreditsView: View {
    var body: some View {
        List(Music.shared.tracks) { t in
            VStack(alignment: .leading) {
                Text("\(t.title) by \(t.artist)")
                HStack {
                    Text(t.license).font(.caption).foregroundStyle(.secondary)
                    if let u = URL(string: t.source) { Link("Source", destination: u).font(.caption) }
                }
            }
        }
    }
}
