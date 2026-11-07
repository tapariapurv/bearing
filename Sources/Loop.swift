import SwiftUI

// MARK: - Plan, Focus, Reflect: the daily loop

extension Coach {
    static func draftDay() async throws -> PlanDraft {
        let p = """
        Plan my day for today only, from now until evening. Reply with JSON only: {"summary":"one sentence","changes":[{"action":"add|move|remove","title":"...","goal":"exact goal title or null","blockId":"block id for move or remove","day":"\(Date().dayKey)","start":"HH:mm","minutes":60,"reason":"short"}]}. \
        Put core goals first and in my best hours. Respect energizing and draining patterns from my reflections. Never overlap existing events or blocks. \
        Leave breathing room; 3 to 5 blocks is plenty. Use open tasks as block titles where they fit.
        """
        let r = try await AI.complete(system: system, prompt: p)
        guard let d = extractJSON(PlanDraft.self, from: r) else { throw AIError(errorDescription: "The model didn't return a usable plan. Try again, or choose a stronger model.") }
        return d
    }
    /// Reflections and energy tags for the coach, most recent first.
    static var loopContext: String {
        let s = Store.shared, d = s.data
        var o = ""
        let r = (d.reflections ?? []).sorted { $0.id > $1.id }.prefix(7)
        if !r.isEmpty {
            o += "Recent reflections (progress per goal):\n"
            for x in r { o += "- \(x.id): " + x.ratings.compactMap { g in s.goal(g.goal).map { "\($0.title) = \(g.rating)\(g.note.isEmpty ? "" : " (\(g.note))")" } }.joined(separator: "; ") + "\n" }
        }
        let since = Date().adding(days: -14)
        let tagged = d.blocks.filter { $0.energy != nil && $0.start > since }
        if !tagged.isEmpty { o += "Energy tags, last 2 weeks:\n"; for b in tagged { o += "- \(b.start.formatted(.dateTime.weekday().hour())) \(b.title): \(b.energy!.rawValue)\n" } }
        return o
    }
}

/// Plan, Focus and Reflect as three steps across the top of Today.
struct DailyLoop: View {
    @State private var store = Store.shared
    var body: some View {
        let d = store.data, key = Date().dayKey
        let focused = d.sessions.contains { Calendar.current.isDateInToday($0.start) }
        HStack(spacing: 8) {
            step("Plan", "calendar", d.plannedDay == key) { Nav.shared.dailySync = true }
            step("Focus", "scope", focused) { Nav.shared.page = .focus }
            step("Reflect", "moon.stars", d.reflections?.contains { $0.id == ReflectView.day.dayKey } == true) { Nav.shared.reflect = true }
        }
    }
    private func step(_ t: String, _ icon: String, _ done: Bool, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Label(t, systemImage: done ? "checkmark.circle.fill" : icon).font(.callout.weight(.medium))
                .foregroundStyle(done ? Color.secondary : Color.primary)
        }.accessibilityValue(done ? "Done" : "Not done")
    }
}

struct DailySync: View {
    @Environment(\.dismiss) private var dismiss
    @State private var store = Store.shared
    @State private var step = 0
    @State private var changes: [PlanChange] = []
    @State private var summary = ""
    @State private var error: String?
    @State private var loading = false
    @State private var tab = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            StepBar(count: 2, index: step)
            Group {
                if step == 0 { askStep } else if loading { thinking } else { draftStep }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            HStack {
                Button(step == 0 ? "Cancel" : "Back") { if step == 0 { dismiss() } else { step = 0 } }.keyboardShortcut(.cancelAction)
                Spacer()
                if step == 1 && !loading {
                    if error != nil { Button("Try Again") { draft() } }
                    Button("Add to Calendar") { Coach.apply(changes); done() }
                        .buttonStyle(PillButton()).controlSize(.large).keyboardShortcut(.defaultAction).disabled(!changes.contains { $0.keep })
                }
            }
        }
        .padding(28).frame(width: 620, height: 600)
    }
    private var askStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Good \(Date().greetingPart). Do you need help planning today?").font(.title2.weight(.bold))
            Text("Your coach will draft today's calendar around your core goals. Nothing is added until you confirm.").foregroundStyle(.secondary)
            ChoiceRow(title: "Yes, help me plan", selected: false) { step = 1; draft() }
            ChoiceRow(title: "No, I've got a clear idea", selected: false) { done() }
        }
    }
    private var thinking: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Drafting your day…").font(.title2.weight(.bold))
            Text("Looking at your goals, calendar and how recent days went.").foregroundStyle(.secondary)
            ProgressView().controlSize(.small)
        }
    }
    private var draftStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Here's a plan for today").font(.title2.weight(.bold))
            if !summary.isEmpty { Text(summary).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            ErrorText(text: error)
            Segments(selection: $tab, options: [Opt("Planned", 0), Opt("All tasks", 1)]).frame(width: 240)
            ScrollView {
                VStack(spacing: 8) {
                    if tab == 0 {
                        if changes.isEmpty { Text("No blocks drafted. Add some from All tasks.").foregroundStyle(.secondary) }
                        ForEach($changes) { $c in
                            let color = store.goals.first { $0.title == c.goal }.map { goalColor($0.color) } ?? .gray
                            Toggle(isOn: $c.keep) {
                                HStack(spacing: 10) {
                                    RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 4, height: 30)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(c.action == "remove" ? "Remove: \(c.title)" : c.title).font(.body.weight(.medium))
                                        Text([c.start, c.minutes.map { "\($0) min" }, c.reason].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    }
                                }
                            }.toggleStyle(CheckToggle()).padding(.horizontal, 12).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading).surface(12)
                        }
                    } else {
                        let open = store.data.tasks.filter { t in !t.done && !changes.contains { $0.title == t.title } }
                        if open.isEmpty { Text("No open tasks.").foregroundStyle(.secondary) }
                        ForEach(open) { t in
                            HStack {
                                Circle().fill(store.goal(t.goalID).map { goalColor($0.color) } ?? Color.secondary.opacity(0.4)).frame(width: 8, height: 8)
                                Text(t.title).lineLimit(1)
                                Spacer()
                                Button("Plan It") { add(t) }
                            }.padding(.horizontal, 12).padding(.vertical, 8).surface(12)
                        }
                    }
                }.padding(2)
            }
        }
    }
    private func draft() {
        loading = true; error = nil
        Task {
            do { let d = try await Coach.draftDay(); changes = d.changes; summary = d.summary ?? "" }
            catch { self.error = error.localizedDescription }
            loading = false
        }
    }
    /// Appends a task as an hour block right after the last planned one (or the next half hour).
    private func add(_ t: TaskItem) {
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        let ends = changes.filter { $0.keep && $0.action != "remove" }.compactMap { c in c.start.flatMap(f.date).map { $0.addingTimeInterval(Double(c.minutes ?? 60) * 60) } }
        let now = Calendar.current.dateComponents([.hour, .minute], from: Date())
        let next = f.date(from: String(format: "%02d:%02d", now.hour! + (now.minute! >= 30 ? 1 : 0), now.minute! >= 30 ? 0 : 30))!
        let start = max(next, ends.max() ?? next)
        changes.append(PlanChange(action: "add", title: t.title, goal: store.goal(t.goalID)?.title, day: Date().dayKey, start: f.string(from: start), minutes: 60, reason: "Added by you"))
        tab = 0
    }
    private func done() { store.data.plannedDay = Date().dayKey; dismiss() }
}

struct ReflectView: View {
    static let ratings = ["A massive amount", "Solid progress", "Mixed", "Little progress", "Not relevant"]
    /// Mornings reflect on yesterday, afternoons and evenings on today.
    static var day: Date { Calendar.current.component(.hour, from: Date()) < 12 ? Date().adding(days: -1) : Date() }
    @Environment(\.dismiss) private var dismiss
    @State private var store = Store.shared
    @State private var step = 0
    @State private var ratings: [GoalRating] = []
    @State private var current = 0
    @FocusState private var energyFocus: Bool
    private var goals: [Goal] { store.goals.filter { $0.tier != .support } }
    private var blocks: [Block] { store.blocks(on: Self.day) }
    private var total: Int { goals.count + (blocks.isEmpty ? 0 : 1) }
    private var dayName: String { Calendar.current.isDateInToday(Self.day) ? "today" : "yesterday" }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            StepBar(count: max(1, total), index: step)
            Group {
                if goals.isEmpty { Text("Add a goal first, then reflect on it here.").foregroundStyle(.secondary) }
                else if step < goals.count { goalStep(step) } else { energyStep }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            HStack {
                Button(step == 0 ? "Cancel" : "Back") { if step == 0 { dismiss() } else { step -= 1 } }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(step >= total - 1 ? "Finish" : "Continue") { step >= total - 1 ? save() : (step += 1) }
                    .buttonStyle(PillButton()).controlSize(.large).keyboardShortcut(.defaultAction)
                    .disabled(step < goals.count && ratings.indices.contains(step) && ratings[step].rating.isEmpty)
            }
        }
        .padding(28).frame(width: 620, height: 600)
        .onAppear {
            let old = store.data.reflections?.first { $0.id == Self.day.dayKey }?.ratings ?? []
            ratings = goals.map { g in old.first { $0.goal == g.id } ?? GoalRating(goal: g.id, rating: "") }
        }
    }
    private func goalStep(_ i: Int) -> some View {
        let g = goals[i]
        return VStack(alignment: .leading, spacing: 14) {
            Text("How much closer did \(dayName) bring you to achieving your goals?").font(.title2.weight(.bold)).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) { GoalIcon(goal: g); Text(g.title).font(.headline); Text(g.tier.rawValue).font(.caption).foregroundStyle(.secondary) }
            if ratings.indices.contains(i) {
                VStack(spacing: 6) {
                    ForEach(Self.ratings, id: \.self) { r in ChoiceRow(title: r, selected: ratings[i].rating == r) { ratings[i].rating = r } }
                }
                TextField("Add a note (optional)", text: $ratings[i].note, axis: .vertical).field().lineLimit(1...3)
            }
        }
    }
    private var energyStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Which blocks gave you energy?").font(.title2.weight(.bold))
            Text("Press E for energizing, D for draining. Arrow keys move between blocks.").foregroundStyle(.secondary)
            VStack(spacing: 6) {
                ForEach(Array(blocks.enumerated()), id: \.element.id) { i, b in
                    HStack(spacing: 10) {
                        Text(b.start.clock).font(.caption).monospacedDigit().foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
                        Text(b.title).lineLimit(1)
                        Spacer()
                        tag(b, .energizing, "E", "bolt.fill")
                        tag(b, .draining, "D", "battery.25percent")
                    }
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(i == current && energyFocus ? Color.primary.opacity(0.05) : .clear, in: .rect(cornerRadius: 10))
                    .contentShape(.rect).onTapGesture { current = i }
                }
            }
            .focusable().focused($energyFocus).focusEffectDisabled()
            .onKeyPress(.upArrow) { current = max(0, current - 1); return .handled }
            .onKeyPress(.downArrow) { current = min(blocks.count - 1, current + 1); return .handled }
            .onKeyPress(characters: .init(charactersIn: "edED")) { k in
                guard blocks.indices.contains(current) else { return .ignored }
                set(blocks[current], k.characters.lowercased() == "e" ? .energizing : .draining)
                current = min(blocks.count - 1, current + 1); return .handled
            }
            .onAppear { energyFocus = true }
        }
    }
    private func tag(_ b: Block, _ e: Energy, _ key: String, _ icon: String) -> some View {
        let on = b.energy == e
        return Button { set(b, e) } label: {
            Label(e == .energizing ? "Energizing" : "Draining", systemImage: icon).font(.caption.weight(.medium))
                .foregroundStyle(on ? Color.onBrand : .secondary)
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(on ? Color.brand : Color.primary.opacity(0.06), in: .capsule)
        }.buttonStyle(.plain).help("\(e.rawValue.capitalized) (\(key))").accessibilityAddTraits(on ? .isSelected : [])
    }
    private func set(_ b: Block, _ e: Energy) { var b = b; b.energy = b.energy == e ? nil : e; store.updateBlock(b) }
    private func save() {
        var all = store.data.reflections ?? []
        all.removeAll { $0.id == Self.day.dayKey }
        all.append(Reflection(id: Self.day.dayKey, ratings: ratings.filter { !$0.rating.isEmpty }))
        store.data.reflections = all
        dismiss()
    }
}

extension Date {
    var greetingPart: String { let h = Calendar.current.component(.hour, from: self); return h < 12 ? "morning" : h < 17 ? "afternoon" : "evening" }
}
