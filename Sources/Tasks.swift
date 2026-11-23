import SwiftUI
#if os(macOS)
import AppKit
#endif

enum AppSystem: String, Codable, CaseIterable { case gps = "GPS: goals, plan, system", classes = "Classes and projects" }
struct Area: Codable, Identifiable, Hashable { var id = UUID(); var name = ""; var isClass = true; var subs: [String]? }
enum TaskGrouping: String, Codable, CaseIterable { case none = "None", due = "Due date", area = "Class or project", priority = "Priority", goal = "Goal" }
enum TaskSort: String, Codable, CaseIterable { case due = "Due date", priority = "Priority", title = "Title" }
struct TaskView: Codable, Identifiable, Hashable {
    var id = UUID(), name = "All tasks", icon = "tray"
    var group = TaskGrouping.due, sort = TaskSort.due
    var area: UUID?, sub: String?, showDone = false
}

/// One section of tasks, and what a task added to it inherits.
struct TaskBucket: Identifiable {
    var id: String { title }
    var title: String, rank: Int
    var goal: UUID? = nil, area: UUID? = nil, sub: String? = nil, due: Date? = nil
    var tasks: [TaskItem] = []
}
extension TaskView {
    static func all(_ custom: Bool) -> TaskView { TaskView(group: custom ? .area : .goal) }
    @MainActor func buckets(_ s: Store) -> [TaskBucket] {
        let areas = s.data.areas ?? []
        let list = s.data.tasks.filter { (showDone || !$0.done) && (area == nil || $0.areaID == area) && (sub == nil || $0.sub == sub) }
            .sorted { a, b in
                switch sort {
                case .due: (a.due ?? .distantFuture, -a.priority) < (b.due ?? .distantFuture, -b.priority)
                case .priority: (-a.priority, a.due ?? .distantFuture) < (-b.priority, b.due ?? .distantFuture)
                case .title: a.title.localizedStandardCompare(b.title) == .orderedAscending
                }
            }
        var out: [String: TaskBucket] = [:]
        // Empty goals, classes and sub-projects still show, so you can add to them.
        if group == .goal { for (i, g) in s.goals.enumerated() { out[g.title] = TaskBucket(title: g.title, rank: i, goal: g.id) } }
        if group == .area {
            for (i, a) in areas.enumerated() where area == nil || a.id == area {
                out[a.name] = TaskBucket(title: a.name, rank: (a.isClass ? 0 : 1000) + i, area: a.id)
                for x in a.subs ?? [] where sub == nil || x == sub { out[a.name + " › " + x] = TaskBucket(title: a.name + " › " + x, rank: i, area: a.id, sub: x) }
            }
        }
        for t in list { let b = bucket(t, s, areas); if out[b.title] == nil { out[b.title] = b }; out[b.title]!.tasks.append(t) }
        return out.values.sorted { ($0.rank, $0.title) < ($1.rank, $1.title) }
    }
    @MainActor private func bucket(_ t: TaskItem, _ s: Store, _ areas: [Area]) -> TaskBucket {
        let today = Date().startOfDay
        switch group {
        case .none: return TaskBucket(title: "Tasks", rank: 0)
        case .due:
            guard let d = t.due else { return TaskBucket(title: "No date", rank: 5) }
            return d < today ? TaskBucket(title: "Overdue", rank: 0) : d < today.adding(days: 1) ? TaskBucket(title: "Today", rank: 1, due: today)
                : d < today.adding(days: 2) ? TaskBucket(title: "Tomorrow", rank: 2, due: today.adding(days: 1)) : d < today.adding(days: 7) ? TaskBucket(title: "Next 7 days", rank: 3) : TaskBucket(title: "Later", rank: 4)
        case .priority: return TaskBucket(title: "P\(5 - t.priority)", rank: 4 - t.priority)
        case .goal:
            guard let i = s.goals.firstIndex(where: { $0.id == t.goalID }) else { return TaskBucket(title: "Inbox", rank: 999) }
            return TaskBucket(title: s.goals[i].title, rank: i, goal: t.goalID)
        case .area:
            guard let i = areas.firstIndex(where: { $0.id == t.areaID }) else { return TaskBucket(title: "Unsorted", rank: 5000) }
            let a = areas[i]
            return TaskBucket(title: a.name + (t.sub.map { " › " + $0 } ?? ""), rank: (a.isClass ? 0 : 1000) + i, area: a.id, sub: t.sub)
        }
    }
}

extension AppData {
    /// Todoist labels for a task: its class or project name, then its sub-project tag.
    func labels(for t: TaskItem) -> [String] {
        let a = (areas ?? []).first { $0.id == t.areaID }?.name
        return [a, a == nil ? nil : t.sub].compactMap { $0 }.filter { !$0.isEmpty }
    }
    func applyLabels(_ ls: [String], to t: inout TaskItem) {
        guard let a = (areas ?? []).first(where: { ls.contains($0.name) }) else { t.areaID = nil; t.sub = nil; return }
        t.areaID = a.id; t.sub = a.isClass ? ls.first { $0 != a.name } : nil
    }
}

struct SystemSettings: View {
    @State private var store = Store.shared
    var body: some View {
        Section {
            Dropdown("System", selection: Binding(get: { store.data.prefs.system ?? .gps }, set: { store.data.prefs.system = $0; Nav.shared.taskView = .all($0 == .classes) }), options: AppSystem.allCases.map { Opt($0.rawValue, $0) })
        } footer: {
            Text((store.data.prefs.system ?? .gps) == .gps ? "Tasks hang off your goals." : "Tasks live in classes, sub-projects or projects, and sync to Todoist as labels.").font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Tasks page

struct TasksPage: View {
    @State private var store = Store.shared
    @State private var nav = Nav.shared
    @State private var todoist = Todoist.shared
    @State private var newTask = ""
    @State private var editing: TaskItem?
    var body: some View {
        @Bindable var nav = nav
        VStack(spacing: 0) {
            #if os(iOS)
            ScrollView(.horizontal, showsIndicators: false) { HStack { ViewChips() }.padding(.horizontal, 12) }.padding(.top, 8)
            #endif
            HStack {
                TextField(nav.taskView.sub.map { "Add a task to \($0)" } ?? "Add a task", text: $newTask).field().onSubmit {
                    let t = newTask.trimmingCharacters(in: .whitespaces); guard !t.isEmpty else { return }
                    store.addTask(t, area: nav.taskView.area, sub: nav.taskView.sub); newTask = ""
                }
                ViewOptions(v: $nav.taskView)
            }.padding(12)
            let groups = nav.taskView.buckets(store).filter { !$0.tasks.isEmpty }
            if groups.isEmpty {
                ContentUnavailableView("No tasks here", systemImage: "checklist", description: Text("Add one above."))
            } else {
                List { ForEach(groups) { g in Section(g.title) { ForEach(g.tasks) { row($0) } } } }.scrollContentBackground(.hidden)
            }
            Divider()
            HStack {
                Text(store.data.todoistToken ? todoist.status + (todoist.lastSync.map { " · \($0.clock)" } ?? "") : "Connect Todoist in Settings to sync.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if store.data.todoistToken { Button("Sync Now") { todoist.nudge() }.controlSize(.small) }
            }.padding(.horizontal, 12).padding(.vertical, 6)
        }
        .sheet(item: $editing) { TaskEditor(task: $0) }
    }
    private func row(_ t: TaskItem) -> some View {
        HStack(spacing: 10) {
            Button { store.toggleDone(t) } label: { Image(systemName: t.done ? "checkmark.circle.fill" : "circle").foregroundStyle(t.done ? .green : (t.priority == 4 ? .red : t.priority == 3 ? .orange : .secondary)).font(.title3) }
                .buttonStyle(.plain).accessibilityLabel(t.done ? "Mark not done" : "Mark done")
            VStack(alignment: .leading, spacing: 1) {
                Text(t.title).strikethrough(t.done).lineLimit(2)
                TaskMeta(t: t)
            }
            Spacer()
            if !t.done { TaskBlockMenu(task: t).fixedSize() }
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
    }
}
struct TaskMeta: View {
    let t: TaskItem
    var body: some View {
        let s = Store.shared
        HStack(spacing: 8) {
            if let d = t.due { Text(d.formatted(.dateTime.month(.abbreviated).day())).foregroundStyle(d < Date().startOfDay && !t.done ? .red : .secondary) }
            ForEach(s.data.labels(for: t), id: \.self) { Text("#" + $0).foregroundStyle(.secondary) }
            if let g = s.goal(t.goalID) { GoalTag(goal: g) }
            if let r = t.resources, !r.isEmpty { Label("\(r.count)", systemImage: "paperclip").foregroundStyle(.secondary) }
        }.font(.caption).lineLimit(1)
    }
}

/// Saved views as tappable rows (iPhone shows them as chips above the list).
struct ViewChips: View {
    @State private var store = Store.shared
    @State private var nav = Nav.shared
    var body: some View {
        let all = TaskView.all(store.data.prefs.system == .classes)
        ForEach([all] + (store.data.views ?? [])) { v in
            let on = nav.taskView.id == v.id || (v.name == all.name && nav.taskView.name == all.name && store.data.views?.contains { $0.id == nav.taskView.id } != true)
            Button { nav.taskView = v } label: {
                Label(v.name, systemImage: v.icon).font(.callout).padding(.horizontal, 10).padding(.vertical, 5)
                    .background(on ? Color.primary.opacity(0.1) : Color.primary.opacity(0.04), in: .capsule)
            }.buttonStyle(.plain).accessibilityAddTraits(on ? .isSelected : [])
        }
    }
}

/// Group, sort, done and saving the current view.
struct ViewOptions: View {
    @Binding var v: TaskView
    @State private var store = Store.shared
    @State private var naming = false
    @State private var name = ""
    @State private var icon = "star"
    static let icons = ["star", "flag", "calendar", "book", "graduationcap", "briefcase", "folder", "bolt", "heart", "tray"]
    var body: some View {
        let custom = store.data.prefs.system == .classes
        Menu {
            Picker("Group by", selection: $v.group) { ForEach(TaskGrouping.allCases.filter { custom ? $0 != .goal : $0 != .area }, id: \.self) { Text($0.rawValue).tag($0) } }
            Picker("Sort by", selection: $v.sort) { ForEach(TaskSort.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
            Toggle("Show done", isOn: $v.showDone)
            Divider()
            Menu("Save as View") { ForEach(Self.icons, id: \.self) { i in Button { icon = i; name = ""; naming = true } label: { Label(i.capitalized, systemImage: i) } } }
            if store.data.views?.contains(where: { $0.id == v.id }) == true {
                Button("Update View") { if let i = store.data.views?.firstIndex(where: { $0.id == v.id }) { store.data.views?[i] = v } }
                Button("Delete View", role: .destructive) { store.data.views?.removeAll { $0.id == v.id }; v = .all(custom) }
            }
        } label: { Image(systemName: "line.3.horizontal.decrease").font(.system(size: 12, weight: .medium)) }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().help("View options").accessibilityLabel("View options")
        .alert("Name this view", isPresented: $naming) {
            TextField("Name", text: $name)
            Button("Save") { var n = v; n.id = UUID(); n.name = name.isEmpty ? "View" : name; n.icon = icon; store.data.views = (store.data.views ?? []) + [n]; v = n }
            Button("Cancel", role: .cancel) {}
        }
    }
}

struct TaskEditor: View {
    @State var task: TaskItem
    @State private var res = ""
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    private var store: Store { Store.shared }
    var body: some View {
        Form {
            TextField("Task", text: $task.title)
            TextField("Notes", text: $task.notes, axis: .vertical).lineLimit(2...6)
            if store.data.prefs.system == .classes {
                Dropdown("Class or project", selection: $task.areaID, options: [Opt("None", UUID?.none)] + (store.data.areas ?? []).map { Opt($0.name, UUID?.some($0.id)) })
                if (store.data.areas ?? []).first(where: { $0.id == task.areaID })?.isClass == true {
                    TextField("Sub-project (optional)", text: Binding(get: { task.sub ?? "" }, set: { task.sub = $0.isEmpty ? nil : $0 }))
                }
            } else { GoalPicker(goal: $task.goalID) }
            Dropdown("Priority", selection: $task.priority, options: [Opt("P1", 4), Opt("P2", 3), Opt("P3", 2), Opt("P4", 1)])
            Toggle("Due date", isOn: Binding(get: { task.due != nil }, set: { task.due = $0 ? Date() : nil }))
            if task.due != nil { DatePicker("Due", selection: Binding(get: { task.due ?? Date() }, set: { task.due = $0 }), displayedComponents: .date) }
            Section("Resources") {
                ForEach(task.resources ?? [], id: \.self) { r in
                    HStack {
                        Button { if let u = Self.url(r) { openURL(u) } } label: { Label(r.hasPrefix("/") ? (r as NSString).lastPathComponent : r, systemImage: r.contains("drive.google") || r.contains("GoogleDrive") ? "externaldrive" : r.hasPrefix("/") ? "doc" : "link").lineLimit(1) }.buttonStyle(.plain)
                        Spacer()
                        Button { task.resources?.removeAll { $0 == r } } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Remove")
                    }
                }
                HStack {
                    TextField("Paste a link, Google Drive link or file path", text: $res).onSubmit { add(res); res = "" }
                    #if os(macOS)
                    Button("Choose File…") {
                        let p = NSOpenPanel(); p.allowsMultipleSelection = true
                        if p.runModal() == .OK { p.urls.forEach { add($0.path) } }
                    }
                    #endif
                }
            }
        }
        .formStyle(.grouped).environment(\.fillRow, true).frame(minWidth: 420)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("Save") { if !res.isEmpty { add(res) }; Store.shared.updateTask(task); dismiss() } }
        }
    }
    private func add(_ r: String) { let r = r.trimmingCharacters(in: .whitespaces); if !r.isEmpty { task.resources = (task.resources ?? []) + [r] } }
    /// Web and Drive links open in the browser; paths (including the local Google Drive folder) open in Finder.
    static func url(_ r: String) -> URL? {
        let r = (r as NSString).expandingTildeInPath
        return r.hasPrefix("/") ? URL(fileURLWithPath: r) : URL(string: r.contains("://") ? r : "https://" + r)
    }
}
