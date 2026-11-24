import SwiftUI

/// A class or project's emoji, or a folder/cap symbol, on its color.
struct AreaIcon: View {
    let area: Area
    var size: CGFloat = 28
    var sub = false
    var body: some View {
        Group {
            if let e = area.icon, !e.isEmpty, !sub { Text(e).font(.system(size: size * 0.56)) }
            else { Image(systemName: sub ? "folder" : area.isClass ? "graduationcap" : "folder").font(.system(size: size * 0.44, weight: .semibold)).foregroundStyle(area.tint.ink) }
        }.frame(width: size, height: size).background(area.tint.wash, in: .rect(cornerRadius: size * 0.3))
    }
}

/// Classes and projects in three sections: Priority, Active, Done (done or archived).
struct ProjectsPage: View {
    @State private var store = Store.shared
    @State private var query = ""
    @State private var open: Set<UUID> = []
    var body: some View {
        let all = (store.data.areas ?? []).filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || ($0.subs ?? []).contains { $0.localizedCaseInsensitiveContains(query) } }
        Scroll {
            HStack(spacing: 10) {
                TextField("Filter", text: $query).textFieldStyle(.roundedBorder).frame(maxWidth: 240)
                Spacer()
                Button("New Class") { add(true) }.buttonStyle(QuietButton())
                Button("New Project") { add(false) }.buttonStyle(PillButton())
            }
            section("Priority", all.filter { $0.active && $0.priority == true })
            section("Active", all.filter { $0.active && $0.priority != true })
            section("Done", all.filter { !$0.active })
        }
    }
    @ViewBuilder private func section(_ title: String, _ list: [Area]) -> some View {
        if !list.isEmpty || title == "Active" {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(title)  \(list.count)").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).padding(.leading, 4)
                VStack(spacing: 0) {
                    ForEach(list) { a in
                        ProjectRow(area: a, expanded: Binding(get: { open.contains(a.id) }, set: { if $0 { open.insert(a.id) } else { open.remove(a.id) } }))
                        if a.id != list.last?.id { Divider().padding(.leading, 56) }
                    }
                    if list.isEmpty { Text("Nothing here yet.").foregroundStyle(.secondary).padding(16).frame(maxWidth: .infinity, alignment: .leading) }
                }.surface(16)
            }
        }
    }
    private func add(_ isClass: Bool) {
        let a = Area(name: isClass ? "New class" : "New project", isClass: isClass, color: (store.data.areas?.count ?? 0) % goalPalette.count)
        store.data.areas = (store.data.areas ?? []) + [a]; open.insert(a.id)
    }
}

private struct ProjectRow: View {
    let area: Area
    @Binding var expanded: Bool
    @State private var store = Store.shared
    @State private var name: String?
    @State private var styling = false
    @State private var newSub = ""
    @FocusState private var focused: Bool
    var body: some View {
        let a = area, tasks = store.data.tasks.filter { $0.areaID == a.id }, openCount = tasks.filter { !$0.done }.count
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Button { styling = true } label: { AreaIcon(area: a, size: 32) }.buttonStyle(.plain).help("Icon and color")
                    .popover(isPresented: $styling, arrowEdge: .bottom) { StylePicker(area: a) }
                if let n = name {
                    TextField("Name", text: Binding(get: { n }, set: { name = $0 })).textFieldStyle(.plain).font(.system(size: 14, weight: .semibold))
                        .focused($focused).onSubmit(commit).onAppear { focused = true }.onChange(of: focused) { if !focused { commit() } }
                } else {
                    Text(a.name).font(.system(size: 14, weight: .semibold)).lineLimit(1).strikethrough(a.done == true, color: .secondary)
                        .onTapGesture(count: 2) { name = a.name }
                    IconButton(icon: "pencil", label: "Rename") { name = a.name }
                }
                if a.archived == true { Text("Archived").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary) }
                Spacer(minLength: 8)
                Text("\(openCount) open").font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
                Segments(selection: Binding(get: { a.isClass }, set: { v in store.editArea(a.id) { $0.isClass = v; if !v { $0.subs = nil } }; store.relabel(tasks.map(\.id)) }),
                         options: [Opt("Class", true), Opt("Project", false)]).frame(width: 140)
                Dropdown("Goal", selection: Binding(get: { a.goal }, set: { store.link(area: a.id, goal: $0) }),
                         options: [Opt("No goal", UUID?.none)] + store.goals.map { Opt($0.title, UUID?.some($0.id), goalColor($0.color)) }).frame(width: 180)
                if a.isClass {
                    IconButton(icon: expanded ? "chevron.up" : "chevron.down", label: "Sub-projects", on: expanded) { withAnimation(.snappy(duration: 0.22)) { expanded.toggle() } }
                }
                Menu {
                    Button(a.priority == true ? "Remove from Priority" : "Move to Priority") { store.editArea(a.id) { $0.priority = a.priority == true ? nil : true } }
                    Button(a.done == true ? "Restore" : "Mark Done") { store.editArea(a.id) { $0.done = a.done == true ? nil : true } }
                    Button(a.archived == true ? "Unarchive" : "Archive") { store.editArea(a.id) { $0.archived = a.archived == true ? nil : true } }
                    Divider()
                    Button("Delete \(a.name)", role: .destructive) { store.deleteArea(a.id) }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            if expanded && a.isClass {
                FlowRow(spacing: 6) {
                    ForEach(a.subs ?? [], id: \.self) { s in
                        HStack(spacing: 5) {
                            Text(s); Text("\(tasks.filter { $0.sub == s && !$0.done }.count)").foregroundStyle(.secondary)
                            Button { removeSub(s) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }.buttonStyle(.plain).foregroundStyle(.secondary)
                        }.font(.system(size: 12, weight: .medium)).padding(.horizontal, 10).padding(.vertical, 5)
                        .background(a.tint.wash, in: .capsule).foregroundStyle(a.tint.ink)
                    }
                    TextField("Add sub-project", text: $newSub).textFieldStyle(.plain).font(.system(size: 12)).frame(width: 140)
                        .onSubmit {
                            let s = newSub.trimmingCharacters(in: .whitespaces)
                            guard !s.isEmpty, !(a.subs ?? []).contains(s) else { return }
                            store.editArea(a.id) { $0.subs = ($0.subs ?? []) + [s] }; newSub = ""
                        }
                }.padding(.leading, 44).transition(.opacity.combined(with: .offset(y: -4)))
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .opacity(a.active ? 1 : 0.6)
    }
    private func commit() {
        if let n = name, n != area.name { store.renameArea(area.id, to: n) }
        name = nil
    }
    private func removeSub(_ s: String) {
        let ids = store.data.tasks.filter { $0.areaID == area.id && $0.sub == s }.map(\.id)
        store.editArea(area.id) { $0.subs?.removeAll { $0 == s } }
        for t in store.data.tasks where ids.contains(t.id) { var n = t; n.sub = nil; store.updateTask(n) }
    }
}

/// Emoji library, palette swatches and any hex color.
private struct StylePicker: View {
    let area: Area
    @State private var store = Store.shared
    @State private var hex = ""
    @State private var search = ""
    var body: some View {
        let a = store.data.areas?.first { $0.id == area.id } ?? area
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                ForEach(goalPalette.indices, id: \.self) { i in
                    Button { store.editArea(a.id) { $0.color = i; $0.hex = nil } } label: {
                        Circle().fill(goalPalette[i]).frame(width: 20, height: 20)
                            .overlay(Circle().stroke(Color.primary.opacity(a.hex == nil && a.color == i ? 0.8 : 0), lineWidth: 2).padding(-3))
                    }.buttonStyle(.plain).help(goalColorNames[i])
                }
                ColorPicker("", selection: Binding(get: { a.tint }, set: { c in store.editArea(a.id) { $0.hex = c.hexString } }), supportsOpacity: false).labelsHidden()
                TextField("#3FAE86", text: $hex).textFieldStyle(.roundedBorder).frame(width: 84)
                    .onSubmit { if Color(hex: hex) != nil { store.editArea(a.id) { $0.hex = "#" + hex.replacingOccurrences(of: "#", with: "").uppercased() } } }
            }
            HStack {
                TextField("Search icons, or type any emoji", text: $search).textFieldStyle(.roundedBorder)
                    .onSubmit { if let e = search.first, e.unicodeScalars.first?.properties.isEmojiPresentation == true { set(String(e)) } }
                Button("None") { set(nil) }.buttonStyle(QuietButton())
            }
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(32), spacing: 4), count: 10), spacing: 4) {
                    ForEach(Emoji.search(search), id: \.self) { e in
                        Button { set(e) } label: {
                            Text(e).font(.system(size: 20)).frame(width: 32, height: 32)
                                .background(a.icon == e ? a.tint.wash : .clear, in: .rect(cornerRadius: 8)).contentShape(.rect)
                        }.buttonStyle(.plain)
                    }
                }
            }.frame(height: 220)
        }.padding(16).frame(width: 376).onAppear { hex = a.hex ?? "" }
    }
    private func set(_ e: String?) { store.editArea(area.id) { $0.icon = e } }
}

/// A searchable emoji library: keyword, then emoji.
enum Emoji {
    static let all: [(String, String)] = """
    book 📚 📖 📘 📙 📗 📕 📓 📔 📒 📝 ✏️ 🖊️ 🖋️ ✒️ 🖍️ 📐 📏 🔖 🏷️ 📎|school 🎓 🏫 🧑‍🎓 🧑‍🏫 🎒 📋 🗂️ 📁 📂 🗃️|english 🔤 🔡 🅰️ 🗣️ 💬 🗨️ 📜 ✍️|language 🌐 🌍 🌎 🌏 🗺️ 🇬🇧 🇺🇸 🇪🇸 🇫🇷 🇩🇪 🇮🇳 🇯🇵 🇨🇳
    math ➕ ➖ ✖️ ➗ 🟰 🔢 💯 📊 📈 📉 🧮 ♾️ π|science 🔬 🔭 🧪 🧫 🧬 ⚗️ 🧲 ⚛️ 🌡️ 🦠 🧠 🫀 🩺 💊|chess ♟️ ♞ ♜ ♛ ♚ 🎲 🧩 🃏 🎯 🎮 🕹️
    code 💻 🖥️ ⌨️ 🖱️ 💾 💿 🧑‍💻 👨‍💻 👩‍💻 🐍 ☕ 🦀 🐛 🔧 🔨 🛠️ ⚙️ 🔩 🧰 🤖 🦾 🔌 🔋 💡 📡 🛰️
    robotics 🤖 🦾 🦿 ⚙️ 🔩 🧲 🔋 🔌 🛠️|maker 🏗️ 🧱 🪚 🪛 🔧 🔨 ⚒️ 🪓 🧵 🪡 🧶 🎨 🖌️ 🖼️ ✂️
    business 💼 🏢 🏦 💰 💵 💳 🪙 📈 💹 🧾 🤝 📇 📊 🛒 🛍️ 🏪 🏬|money 💰 💵 💴 💶 💷 🪙 💸 📈 🏦|stock 📈 📉 💹 🐂 🐻 💲
    media 🎬 🎥 📹 📷 📸 📺 📻 🎙️ 🎧 🎤 🎼 🎵 🎶 🎹 🥁 🎸 🎻 🎺 🎷|youtube ▶️ 📺 🎬 🎥 🔴|design 🎨 🖌️ 🖍️ ✏️ 📐 🧵 🖼️ 💅 ✨
    writing ✍️ 📝 🖋️ 📰 🗞️ 📃 📄 📑|news 📰 🗞️ 📣 📢 🔔 📬 📨 ✉️ 📧
    sport ⚽ 🏀 🏈 ⚾ 🎾 🏐 🏉 🏓 🏸 🏒 🏑 🏏 ⛳ 🥊 🥋 🛹 ⛸️ 🎿 🏂 🏋️ 🤸 🧘 🚴 🏊 🏃 🧗 🏆 🥇 🏅
    health 💪 🧘 🫁 🥗 🍎 🥦 💧 😴 🛌 ❤️ 🩹 🏥|food 🍕 🍔 🍜 🍣 🍩 🍪 ☕ 🍵 🧋 🍳 🥐 🍰
    travel ✈️ 🚀 🚗 🚲 🚆 🛳️ 🗺️ 🧭 🏔️ 🏝️ 🏕️ 🌋 🗽 🗼|home 🏠 🏡 🛋️ 🪴 🧹 🧺 🔑 🚪
    nature 🌱 🌿 🍀 🌳 🌲 🌵 🌸 🌻 🌼 🍁 🌊 🔥 ⭐ 🌙 ☀️ 🌈 ⚡ ❄️ 🌍|animal 🐶 🐱 🦊 🐻 🐼 🦁 🐯 🐸 🐵 🦉 🦅 🐝 🦋 🐢 🐙 🐬 🐳 🦄
    spirit 🕉️ 🙏 🪷 📿 🛕 🕯️ ☮️ ☯️ 🧿|people 👤 👥 🧑 👪 🫂 🤝 👋 🙌 👏 🎉 🥳
    goal 🎯 🏁 🚩 🏆 🥇 🔥 ⚡ 🚀 ⭐ 🌟 ✨ 💎 👑 🔑 🗝️ 🧭 ⏳ ⌛ ⏰ 📅 🗓️ ✅ ☑️ ✔️
    symbol ❤️ 🧡 💛 💚 💙 🩵 🤍 🖤 🤎 🩶 🔴 🟠 🟡 🟢 🔵 🟤 ⚫ ⚪ 🟥 🟧 🟨 🟩 🟦 🟫 ⬛ ⬜ 🔶 🔷 🔺 🔻 💠 🔘 ♦️ ♠️ ♣️ ♥️
    brand 🛍️ 🏷️ 🧢 👕 👗 👟 👜 💍 🕶️ 🪞 🧴 🧼|web 🌐 🔗 🖇️ 📲 📱 ☁️ 🔒 🔓 🔐 🛡️ 📶 🧩
    """.split(whereSeparator: { $0 == "|" || $0 == "\n" }).flatMap { line -> [(String, String)] in
        let w = line.split(separator: " ").map(String.init); guard let k = w.first else { return [] }
        return w.dropFirst().map { (k, $0) }
    }
    static func search(_ q: String) -> [String] {
        let q = q.lowercased().trimmingCharacters(in: .whitespaces)
        var seen = Set<String>()
        return all.filter { q.isEmpty || $0.0.hasPrefix(q) || $0.0.contains(q) }.map(\.1).filter { seen.insert($0).inserted }
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
