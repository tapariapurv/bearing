import SwiftUI

@main struct BearingApp: App {
    var body: some Scene { WindowGroup { Root() } }
}

struct Root: View {
    @Environment(\.scenePhase) private var phase
    private var cloud = Cloud.shared
    var body: some View {
        Group {
            if cloud.email.isEmpty { SignIn() }
            else {
                TabView {
                    Tab("Today", systemImage: "sun.max") { TodayView() }
                    Tab("Tasks", systemImage: "checklist") { TasksView() }
                    Tab("Goals", systemImage: "scope") { GoalsView() }
                }
            }
        }
        .onChange(of: phase, initial: true) { if phase == .active { Task { await cloud.pull() } } }
    }
}

struct SignIn: View {
    @State private var busy = false
    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "location.north.circle.fill").font(.system(size: 64)).foregroundStyle(.tint)
            Text("Bearing").font(.largeTitle.bold())
            Text("Your goals, plan and tasks from the Mac, in your pocket.").multilineTextAlignment(.center).foregroundStyle(.secondary)
            Spacer()
            Button { busy = true; Task { await Cloud.shared.signIn(); busy = false } } label: {
                Text(busy ? "Signing in…" : "Continue with Google").frame(maxWidth: .infinity)
            }.buttonStyle(.borderedProminent).controlSize(.large).disabled(busy)
            if !Cloud.shared.status.isEmpty { Text(Cloud.shared.status).font(.footnote).foregroundStyle(.secondary) }
        }.padding(24)
    }
}

struct TaskRow: View {
    var t: Cloud.Item
    var body: some View {
        Button { Cloud.shared.toggle(t.id) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Image(systemName: t.done ? "checkmark.circle.fill" : "circle").foregroundStyle(t.done ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(t.title).strikethrough(t.done).foregroundStyle(t.done ? .secondary : .primary)
                    let sub = [t.goal, t.due.map { $0.formatted(.dateTime.month().day()) }].compactMap { $0 }.joined(separator: " · ")
                    if !sub.isEmpty { Text(sub).font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
        .buttonStyle(.plain)
        .swipeActions { Button("Delete", role: .destructive) { Cloud.shared.delete(t.id) } }
    }
}

struct TodayView: View {
    private var cloud = Cloud.shared
    var body: some View {
        let end = Calendar.current.startOfDay(for: .now).addingTimeInterval(86400)
        let due = cloud.tasks.filter { !$0.done && ($0.due ?? .distantFuture) < end }
        NavigationStack {
            List {
                if !cloud.compass.isEmpty { Section("Compass") { Text(cloud.compass) } }
                Section("Plan") {
                    let slots = cloud.slots(on: .now)
                    if slots.isEmpty { Text("Nothing planned today").foregroundStyle(.secondary) }
                    ForEach(slots) { s in
                        HStack {
                            Text(s.start.formatted(date: .omitted, time: .shortened)).monospacedDigit().foregroundStyle(.secondary).frame(width: 72, alignment: .leading)
                            Text(s.title)
                        }.opacity(s.end < .now ? 0.5 : 1)
                    }
                }
                Section("Due") {
                    if due.isEmpty { Text("Nothing due").foregroundStyle(.secondary) }
                    ForEach(due) { TaskRow(t: $0) }
                }
            }
            .navigationTitle(Date.now.formatted(.dateTime.weekday(.wide).month().day()))
            .refreshable { await cloud.pull() }
            .safeAreaInset(edge: .bottom) { if !cloud.status.isEmpty { Text(cloud.status).font(.footnote).foregroundStyle(.secondary).padding(8) } }
        }
    }
}

struct TasksView: View {
    private var cloud = Cloud.shared
    @State private var new = ""
    @State private var showDone = false
    var body: some View {
        NavigationStack {
            List {
                TextField("Add a task", text: $new).submitLabel(.done).onSubmit {
                    let t = new.trimmingCharacters(in: .whitespaces); if !t.isEmpty { cloud.add(t) }; new = ""
                }
                ForEach(cloud.tasks.filter { showDone || !$0.done }) { TaskRow(t: $0) }
            }
            .navigationTitle("Tasks")
            .refreshable { await cloud.pull() }
            .toolbar { Toggle("Show done", systemImage: "checkmark.circle", isOn: $showDone) }
        }
    }
}

struct GoalsView: View {
    private var cloud = Cloud.shared
    var body: some View {
        NavigationStack {
            List {
                ForEach(cloud.goals) { g in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack { Text(g.title).font(.headline); Spacer(); Text("\(g.hours, format: .number)h/week").font(.caption).foregroundStyle(.secondary) }
                        if !g.why.isEmpty { Text(g.why).font(.subheadline).foregroundStyle(.secondary) }
                        let open = cloud.tasks.filter { !$0.done && $0.goal == g.title }.count
                        Text("\(open) open task\(open == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section { Button("Sign out \(cloud.email)", role: .destructive) { cloud.signOut() } }
            }
            .navigationTitle("Goals")
            .refreshable { await cloud.pull() }
        }
    }
}
