import SwiftUI

// MARK: - Wizard pieces, shared by season setup, daily sync and reflection

/// Segmented progress: one capsule per step, filled up to the current one.
struct StepBar: View {
    let count: Int, index: Int
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<max(1, count), id: \.self) { i in Capsule().fill(i <= index ? Color.brand : Color.primary.opacity(0.1)).frame(height: 4) }
        }.accessibilityElement().accessibilityLabel("Step \(index + 1) of \(count)")
    }
}
/// A tappable answer card. Selected cards get an ink border.
struct ChoiceRow: View {
    let title: String
    var detail: String? = nil
    var badge: String? = nil
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title).font(.body.weight(.medium))
                        if let badge { Text(badge).font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 1).background(Color.primary.opacity(0.07), in: .capsule) }
                    }
                    if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 4)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle").foregroundStyle(selected ? Color.brand : Color.primary.opacity(0.2))
            }
            .padding(.horizontal, 14).padding(.vertical, 11).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.surface, in: .rect(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? Color.brand : Color.primary.opacity(0.1), lineWidth: selected ? 1.5 : 1))
            .contentShape(.rect)
        }
        .buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }
}
/// Multiple choice with a free-text "Something else…" answer.
struct ChoiceList: View {
    let options: [String]
    @Binding var answer: String
    @State private var other = false
    var body: some View {
        VStack(spacing: 8) {
            ForEach(options, id: \.self) { o in ChoiceRow(title: o, selected: !other && answer == o) { other = false; answer = o } }
            ChoiceRow(title: "Something else…", selected: other) { other = true; if options.contains(answer) { answer = "" } }
            if other { TextField("Tell your coach", text: $answer, axis: .vertical).field().lineLimit(1...4) }
        }
        .onAppear { other = !answer.isEmpty && !options.contains(answer) }
    }
}
/// A goal's small colored tile, used in the sidebar and lists.
struct GoalIcon: View {
    let goal: Goal
    var size: CGFloat = 22
    var body: some View {
        let c = goalColor(goal.color)
        Text(goal.title.first.map { String($0).uppercased() } ?? "•").font(.system(size: size * 0.5, weight: .bold, design: .rounded))
            .foregroundStyle(c.ink).frame(width: size, height: size).background(c.wash, in: .rect(cornerRadius: size * 0.28))
            .accessibilityHidden(true)
    }
}

// MARK: - Season setup

struct MCQuestion: Codable, Hashable { var question: String; var options: [String] }
private struct MCQuestions: Decodable { var questions: [MCQuestion] }

extension Coach {
    /// Sharp follow-ups for a new season. Falls back to fixed questions so setup never stalls without a model.
    static func seasonQuestions() async -> [MCQuestion] {
        let p = """
        I'm setting up a new season. Ask me 5 sharp multiple-choice follow-up questions that will help you coach me: which goal is most at risk, what usually derails me, \
        early warning signs I'm drifting, how often I'll work on each core goal, and what I'm willing to drop. Make every option specific to my goals above. \
        Reply with JSON only: {"questions":[{"question":"...","options":["...","...","...","..."]}]}. Exactly 4 options each, each under 9 words.
        """
        if let r = try? await AI.complete(system: system, prompt: p), let q = extractJSON(MCQuestions.self, from: r)?.questions {
            let clean = q.map { MCQuestion(question: $0.question, options: Array($0.options.filter { !$0.isEmpty }.prefix(4))) }.filter { !$0.question.isEmpty && $0.options.count >= 2 }
            if clean.count >= 3 { return Array(clean.prefix(6)) }
        }
        return fallbackQuestions(Store.shared.goals)
    }
    static func fallbackQuestions(_ goals: [Goal]) -> [MCQuestion] {
        let core = goals.filter { $0.tier == .core }.map(\.title)
        let names = Array((core.isEmpty ? goals.map(\.title) : core).prefix(3))
        return [
            MCQuestion(question: "Which goal is most likely to slip first?", options: names + ["None, I'm confident in all of them"]),
            MCQuestion(question: "What usually gets in the way when you fall behind?", options: ["Work spills into my evenings", "Low energy by the afternoon", "Saying yes to too much", "Losing momentum after a missed day"]),
            MCQuestion(question: "What's the earliest sign you're drifting?", options: ["Skipping planned blocks", "Late nights on my phone", "Not reviewing my week", "Feeling busy but not moving"]),
            MCQuestion(question: "How often will you work on your top goal?", options: ["Every day", "4 to 5 times a week", "2 to 3 times a week", "Once a week in a long block"]),
            MCQuestion(question: "If you could only protect one thing this season, what would it be?", options: Array((names + ["My health and energy"]).prefix(4))),
        ]
    }
}

struct SeasonSetup: View {
    @Environment(\.dismiss) private var dismiss
    @State private var store = Store.shared
    @State private var step = 0
    @State private var weeks = 12
    @State private var length = 12            // 12, 4, or 0 for custom
    @State private var name = ""
    @State private var goals: [Goal] = []
    @State private var newGoal = ""
    @State private var questions: [MCQuestion] = []
    @State private var answers: [String] = []
    @State private var loading = false

    private var total: Int { 2 + max(questions.count, 5) + 1 }
    private var qIndex: Int { step - 2 }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            StepBar(count: total, index: step)
            Group {
                if step == 0 { lengthStep } else if step == 1 { goalsStep }
                else if loading { loadingStep } else if qIndex < questions.count { questionStep } else { doneStep }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            HStack {
                if step == 0 { Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction) }
                else { Button("Back") { step -= 1 }.disabled(loading) }
                Spacer()
                if step > 1 && qIndex < questions.count { Button("Skip") { advance() }.disabled(loading) }
                Button(step > 1 && qIndex >= questions.count && !loading ? "Start Season" : "Continue") { advance() }
                    .buttonStyle(PillButton()).controlSize(.large).keyboardShortcut(.defaultAction).disabled(!canContinue)
            }
        }
        .padding(28).frame(width: 620, height: 600)
        .onAppear {
            let d = store.data
            weeks = d.seasonWeeks; length = [12, 4].contains(weeks) ? weeks : 0
            name = d.seasonName == "This season" ? "" : d.seasonName
            goals = store.goals
        }
    }
    private func header(_ title: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.title2.weight(.bold))
            Text(sub).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    private var lengthStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            header("How long is this season?", "A season is a stretch where a few goals get most of your attention. Everything else waits its turn.")
            ChoiceRow(title: "12 weeks", detail: "Long enough for real progress, short enough to stay urgent.", badge: "Recommended", selected: length == 12) { length = 12; weeks = 12 }
            ChoiceRow(title: "4 weeks", detail: "A sprint for one big push.", selected: length == 4) { length = 4; weeks = 4 }
            ChoiceRow(title: "Custom", detail: length == 0 ? nil : "Choose any length from 2 to 26 weeks.", selected: length == 0) { length = 0 }
            if length == 0 { Step("\(weeks) weeks", value: $weeks, in: 2...26) }
            TextField("Name it (optional), for example: Spring reset", text: $name).field()
        }
    }
    private var goalsStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            header("Rank what matters this season", "Core goals get your best hours. Secondary goals are nice to have. Support areas keep life running. One to three core goals works best.")
            ScrollView {
                VStack(spacing: 8) {
                    ForEach($goals) { $g in
                        HStack(spacing: 8) {
                            GoalIcon(goal: g)
                            TextField("Goal", text: $g.title).textFieldStyle(.plain).font(.body.weight(.medium))
                            Segments(selection: $g.tier, options: GoalTier.allCases.map { Opt($0 == .support ? "Support" : $0.rawValue, $0) }).fixedSize()
                            VStack(spacing: 0) {
                                Button { move(g.id, -1) } label: { Image(systemName: "chevron.up").frame(width: 18, height: 12) }.accessibilityLabel("Move \(g.title) up")
                                Button { move(g.id, 1) } label: { Image(systemName: "chevron.down").frame(width: 18, height: 12) }.accessibilityLabel("Move \(g.title) down")
                            }.buttonStyle(.plain).font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                            Button { goals.removeAll { $0.id == g.id } } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Remove \(g.title)")
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8).surface(12)
                    }
                    TextField("Add a goal and press Return", text: $newGoal).field().onSubmit(addGoal)
                }.padding(2)
            }
            let core = goals.filter { $0.tier == .core }.count
            if core > 3 { Label("\(core) core goals is a lot. Which could be secondary this season?", systemImage: "exclamationmark.bubble").font(.callout).foregroundStyle(GoalStatus.adjust.color.ink) }
        }
    }
    private var loadingStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            header("Your coach is reading your goals…", "A few sharp questions are coming. Pick the closest answer, or write your own.")
            ProgressView().controlSize(.small)
        }
    }
    @ViewBuilder private var questionStep: some View {
        let q = questions[qIndex]
        VStack(alignment: .leading, spacing: 16) {
            Text("Question \(qIndex + 1) of \(questions.count)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(q.question).font(.title2.weight(.bold)).fixedSize(horizontal: false, vertical: true)
            ChoiceList(options: q.options, answer: $answers[qIndex]).id(qIndex)
        }
    }
    private var doneStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            header("Your season is ready", "\(weeks) weeks, starting today. Your coach will use this to plan your days and keep you honest.")
            ForEach(goals.filter { $0.tier == .core }) { g in HStack { GoalIcon(goal: g); Text(g.title).font(.body.weight(.medium)) } }
            let answered = zip(questions, answers).filter { !$0.1.isEmpty }
            if !answered.isEmpty { Text("\(answered.count) answers saved for your coach.").font(.caption).foregroundStyle(.secondary) }
        }
    }
    private var canContinue: Bool {
        if loading { return false }
        if step == 0 { return weeks >= 2 }
        if step == 1 { return goals.contains { !$0.title.trimmingCharacters(in: .whitespaces).isEmpty } }
        if qIndex < questions.count { return !answers[qIndex].trimmingCharacters(in: .whitespaces).isEmpty }
        return true
    }
    private func addGoal() {
        let t = newGoal.trimmingCharacters(in: .whitespaces); guard !t.isEmpty else { return }
        let used = Set(store.data.goals.map(\.color) + goals.map(\.color))
        goals.append(Goal(title: t, color: (0..<8).first { !used.contains($0) } ?? goals.count, level: goals.contains { $0.tier == .core } ? .secondary : .core))
        newGoal = ""
    }
    private func move(_ id: UUID, _ by: Int) {
        guard let i = goals.firstIndex(where: { $0.id == id }), goals.indices.contains(i + by) else { return }
        goals.swapAt(i, i + by)
    }
    private func advance() {
        if step == 0 { step = 1; return }
        if step == 1 {
            saveGoals(); step = 2; loading = true
            Task {
                let q = await Coach.seasonQuestions()
                questions = q; answers = q.map { _ in "" }; loading = false
            }
            return
        }
        if qIndex < questions.count { step += 1; return }
        let d = store.data
        if d.seasonWeeks != weeks || d.seasonQA == nil { store.data.seasonStart = Date().startOfDay }
        store.data.seasonWeeks = weeks
        store.data.seasonName = name.trimmingCharacters(in: .whitespaces).isEmpty ? "This season" : name
        store.data.seasonQA = zip(questions, answers).filter { !$0.1.isEmpty }.map { QA(q: $0.0.question, a: $0.1) }
        Nav.shared.page = .today
        dismiss()
    }
    /// Writes the ranked list back: kept goals in the new order, then archived ones untouched.
    private func saveGoals() {
        let kept = goals.filter { !$0.title.trimmingCharacters(in: .whitespaces).isEmpty }
        let removed = store.data.goals.filter { g in !g.archived && !kept.contains { $0.id == g.id } }.map { var g = $0; g.archived = true; return g }
        store.data.goals = kept.map { k in var g = store.data.goals.first { $0.id == k.id } ?? k; g.title = k.title; g.level = k.level; return g }
            + store.data.goals.filter(\.archived) + removed
        goals = kept
    }
}
