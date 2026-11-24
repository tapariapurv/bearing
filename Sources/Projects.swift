import SwiftUI

/// One place to manage classes, projects and their sub-projects.
struct ProjectsPage: View {
    @State private var store = Store.shared
    @State private var query = ""
    @State private var showArchived = false
    @State private var newSub: [UUID: String] = [:]

    var body: some View {
        let all = store.data.areas ?? []
        let list = all.filter { (showArchived || $0.archived != true) && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || ($0.subs ?? []).contains { $0.localizedCaseInsensitiveContains(query) }) }
        Scroll {
            HStack(spacing: 10) {
                TextField("Filter classes and projects", text: $query).textFieldStyle(.roundedBorder).frame(maxWidth: 280)
                Toggle("Show archived", isOn: $showArchived).fixedSize()
                Spacer()
                Button("New Class") { add(true) }
                Button("New Project") { add(false) }.buttonStyle(.borderedProminent).tint(.brand)
            }
            if list.isEmpty {
                Card { Text(all.isEmpty ? "No classes or projects yet. Add one to group tasks, color them, and link them to a goal." : "Nothing matches.").foregroundStyle(.secondary) }
            }
            ForEach(list) { a in row(a) }
        }
    }

    private func add(_ isClass: Bool) {
        let a = Area(name: isClass ? "New class" : "New project", isClass: isClass, color: (store.data.areas?.count ?? 0) % goalPalette.count)
        store.data.areas = (store.data.areas ?? []) + [a]
    }

    private func move(_ id: UUID, _ by: Int) {
        guard var l = store.data.areas, let i = l.firstIndex(where: { $0.id == id }), l.indices.contains(i + by) else { return }
        l.swapAt(i, i + by); store.data.areas = l
    }

    @ViewBuilder private func row(_ a: Area) -> some View {
        let tasks = store.data.tasks.filter { $0.areaID == a.id }
        let open = tasks.filter { !$0.done }.count
        Card(accent: a.tint) {
            HStack(spacing: 12) {
                Image(systemName: a.isClass ? "graduationcap" : "folder").font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(a.tint.ink).frame(width: 32, height: 32).background(a.tint.wash, in: .rect(cornerRadius: 9))
                TextField("Name", text: Binding(get: { a.name }, set: { v in store.editArea(a.id) { $0.name = v } }))
                    .textFieldStyle(.plain).font(.system(size: 17, weight: .semibold))
                Text("\(open) open · \(tasks.count - open) done").font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
                Menu {
                    Button("Move Up") { move(a.id, -1) }
                    Button("Move Down") { move(a.id, 1) }
                    Button(a.archived == true ? "Unarchive" : "Archive") { store.editArea(a.id) { $0.archived = a.archived == true ? nil : true } }
                    Divider()
                    Button("Delete \(a.name)", role: .destructive) { store.deleteArea(a.id) }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
            }
            HStack(spacing: 16) {
                HStack(spacing: 6) {
                    ForEach(goalPalette.indices, id: \.self) { i in
                        let on = (a.color ?? Int(a.id.uuid.0)) % goalPalette.count == i
                        Button { store.editArea(a.id) { $0.color = i } } label: {
                            Circle().fill(goalPalette[i]).frame(width: 18, height: 18)
                                .overlay(Circle().stroke(Color.primary.opacity(on ? 0.8 : 0), lineWidth: 2).padding(-3))
                        }.buttonStyle(.plain).help(goalColorNames[i])
                    }
                }
                Picker("", selection: Binding(get: { a.isClass }, set: { v in store.editArea(a.id) { $0.isClass = v } })) {
                    Text("Class").tag(true); Text("Project").tag(false)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 150)
                Dropdown("Goal", selection: Binding(get: { a.goal }, set: { store.link(area: a.id, goal: $0) }),
                         options: [Opt("No goal", UUID?.none)] + store.data.goals.map { Opt($0.title, UUID?.some($0.id), goalColor($0.color)) })
                    .frame(maxWidth: 220)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Sub-projects").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                FlowRow(spacing: 6) {
                    ForEach(a.subs ?? [], id: \.self) { s in
                        let n = tasks.filter { $0.sub == s && !$0.done }.count
                        HStack(spacing: 5) {
                            Text(s); Text("\(n)").foregroundStyle(.secondary)
                            Button { removeSub(a, s) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }.buttonStyle(.plain).foregroundStyle(.secondary)
                        }
                        .font(.system(size: 12, weight: .medium)).padding(.horizontal, 10).padding(.vertical, 5)
                        .background(a.tint.wash, in: .capsule).foregroundStyle(a.tint.ink)
                    }
                    TextField("Add sub-project", text: Binding(get: { newSub[a.id] ?? "" }, set: { newSub[a.id] = $0 }))
                        .textFieldStyle(.plain).font(.system(size: 12)).frame(width: 130)
                        .onSubmit {
                            let s = (newSub[a.id] ?? "").trimmingCharacters(in: .whitespaces)
                            guard !s.isEmpty, !(a.subs ?? []).contains(s) else { return }
                            store.editArea(a.id) { $0.subs = ($0.subs ?? []) + [s] }; newSub[a.id] = ""
                        }
                }
            }
        }.opacity(a.archived == true ? 0.55 : 1)
    }

    private func removeSub(_ a: Area, _ s: String) {
        store.editArea(a.id) { $0.subs?.removeAll { $0 == s } }
        for t in store.data.tasks where t.areaID == a.id && t.sub == s { var n = t; n.sub = nil; store.updateTask(n) }
    }
}

/// Wraps children onto new lines when they run out of width.
struct FlowRow: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, maxX: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > w { x = 0; y += line + spacing; line = 0 }
            x += s.width + spacing; line = max(line, s.height); maxX = max(maxX, x - spacing)
        }
        return CGSize(width: maxX, height: y + line)
    }
    func placeSubviews(in b: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = b.minX, y = b.minY, line: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > b.minX, x + s.width > b.maxX { x = b.minX; y += line + spacing; line = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: .init(s)); x += s.width + spacing; line = max(line, s.height)
        }
    }
}
