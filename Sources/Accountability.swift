import SwiftUI
import Charts

// MARK: - Honest accountability: season hours spent vs planned vs the pace your targets need, said plainly.

struct Account: Identifiable {
    let goal: Goal
    let spent, planned, pace: Double      // hours this season; pace = weekly target × weeks elapsed
    let lowDays: Int                      // reflections in the last week rated little progress or not relevant
    var id: UUID { goal.id }
    var call: (verdict: String, fix: String, ok: Bool) { Self.call(spent: spent, planned: planned, pace: pace, weekly: goal.weeklyHours, lowDays: lowDays) }

    nonisolated static func call(spent: Double, planned: Double, pace: Double, weekly: Double, lowDays: Int) -> (verdict: String, fix: String, ok: Bool) {
        let h = { (x: Double) in String(format: "%.0fh", x) }
        if pace <= 0 || spent >= pace * 0.9 {
            return lowDays >= 3 ? ("The hours are there, but you rated \(lowDays) days as little progress.", "Hours aren't the problem. Change what you do in them.", false)
                                : ("On pace: \(h(spent)) of \(h(pace)).", "Keep the same slots.", true)
        }
        if planned < pace * 0.6 {
            return ("You aren't putting it on the calendar. \(h(planned)) planned against the \(h(pace)) it needs.", "Block \(String(format: "%g", weekly))h this week before anything else goes in.", false)
        }
        if spent < planned * 0.6 {
            return ("You plan it, then skip it. Only \(h(spent)) of \(h(planned)) planned happened.", "Fewer, shorter blocks at your best-energy time beat a full calendar you ignore.", false)
        }
        return ("Behind pace by \(h(pace - spent)).", "Add \(String(format: "%.1f", (pace - spent) / 4))h a week for the next four weeks, or lower the target.", false)
    }
    /// A secondary goal or support area taking more time than a core goal is backwards.
    nonisolated static func imbalance(_ a: [(title: String, tier: GoalTier, spent: Double)]) -> String? {
        guard let core = a.filter({ $0.tier == .core }).min(by: { $0.spent < $1.spent }),
              let other = a.filter({ $0.tier != .core && $0.spent > core.spent + 0.5 }).max(by: { $0.spent < $1.spent }) else { return nil }
        return "\(other.title) got \(String(format: "%.0f", other.spent))h, more than your core goal \(core.title) (\(String(format: "%.0f", core.spent))h). That's backwards for this season."
    }
}

extension Store {
    var accounts: [Account] {
        let s = data.seasonStart, now = Date(), weeks = Double(seasonDay) / 7
        let since = now.adding(days: -7).dayKey
        return goals.map { g in
            let planned = data.blocks.filter { $0.goalID == g.id && $0.start >= s && $0.start < now.startOfWeek.adding(days: 7) }.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) } / 3600
            let low = (data.reflections ?? []).filter { $0.id >= since }.flatMap(\.ratings).filter { $0.goal == g.id && ReflectView.ratings.suffix(2).contains($0.rating) }.count
            return Account(goal: g, spent: focused(goal: g.id, since: s) / 3600, planned: planned, pace: g.weeklyHours * weeks, lowDays: low)
        }
    }
    var imbalance: String? { Account.imbalance(accounts.map { ($0.goal.title, $0.goal.tier, $0.spent) }) }
}

extension Coach {
    /// Same numbers and verdicts the person sees, so the coach can't be softer than the chart.
    static var accountContext: String {
        let s = Store.shared
        var o = "Season accountability (hours spent / planned / pace needed):\n"
        for a in s.accounts { o += "- \(a.goal.title): \(String(format: "%.1f / %.1f / %.1f", a.spent, a.planned, a.pace)). \(a.call.verdict)\n" }
        if let i = s.imbalance { o += "Imbalance: \(i)\n" }
        return o
    }
}

struct AccountabilityCard: View {
    @State private var store = Store.shared
    var body: some View {
        let all = store.accounts, core = all.filter { $0.goal.tier == .core }
        Card(title: "Core Goals: Hours Spent This Season") {
            if core.isEmpty { Text("Rank a core goal in your season to see this.").foregroundStyle(.secondary) }
            else {
                Chart {
                    ForEach(core) { a in
                        ForEach([("Spent", a.spent), ("Planned", a.planned), ("Needed", a.pace)], id: \.0) { series, v in
                            BarMark(x: .value("Goal", a.goal.title), y: .value("Hours", v), width: .ratio(0.7))
                                .foregroundStyle(by: .value("Series", series)).position(by: .value("Series", series)).cornerRadius(3)
                        }
                    }
                }
                .chartForegroundStyleScale(["Spent": Color.primary, "Planned": Color.secondary.opacity(0.5), "Needed": Color.secondary.opacity(0.18)])
                .frame(height: 200).accessibilityLabel("Hours spent, planned and needed this season for each core goal")
            }
            if let i = store.imbalance { Label(i, systemImage: "exclamationmark.triangle.fill").foregroundStyle(GoalStatus.offTrack.color.ink).font(.callout) }
            ForEach(all.filter { $0.goal.tier != .support }) { a in
                let c = a.call
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: c.ok ? "checkmark.circle.fill" : "xmark.circle.fill").foregroundStyle(c.ok ? GoalStatus.onTrack.color.ink : GoalStatus.offTrack.color.ink)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(a.goal.title).font(.callout.weight(.semibold))
                        Text(c.verdict).font(.callout)
                        if !c.ok { Text("Fix: \(c.fix)").font(.caption).foregroundStyle(.secondary) }
                    }.fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

// Daily idea: one well-known productivity principle plus a practical step, rotated by day.
enum Idea {
    static let all: [(String, String)] = [
        ("Eat the frog", "Do your hardest task first, before email or chat."),
        ("Time blocking", "Give every important task a slot on the calendar, not just a list entry."),
        ("Two-minute rule", "If it takes under two minutes, do it now instead of tracking it."),
        ("Parkinson's law", "Work expands to fill the time. Give tasks a tighter block than feels comfortable."),
        ("Deep work", "Protect one 90-minute block today with blocking on and notifications off."),
        ("Implementation intentions", "Write it as: when X happens, I will do Y. It doubles follow-through."),
        ("Weekly review", "Once a week, clear inboxes, check goals and plan next week's blocks."),
        ("Single-tasking", "One tab, one task. Switching costs minutes of focus each time."),
        ("Energy management", "Put deep work in your peak hours and admin in your slump."),
        ("Batching", "Group small similar tasks, like replies or calls, into one block."),
        ("The one thing", "Ask: what is the one thing that makes everything else easier or unnecessary?"),
        ("Pareto principle", "20% of the work drives 80% of the result. Start with that 20%."),
        ("Shutdown ritual", "End the day by writing tomorrow's first task. Then stop."),
        ("Pomodoro", "25 minutes on, 5 off. After four rounds, take a longer break."),
        ("Done beats perfect", "Ship a rough first version today, then improve it."),
        ("Say no", "Every yes costs a block of time. Decline one thing that doesn't serve your goals."),
        ("Habit stacking", "Attach a new habit to one you already do: after coffee, plan the day."),
        ("Clear the desk", "A tidy space and closed apps lower the pull of distractions."),
    ]
    static func of(_ d: Date) -> (String, String) { all[(Calendar.current.ordinality(of: .day, in: .era, for: d) ?? 0) % all.count] }
}

struct IdeaCard: View {
    var body: some View {
        let i = Idea.of(Date())
        VStack(alignment: .leading, spacing: 4) {
            Text("Today's idea").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            Text(i.0).font(.callout.weight(.semibold))
            Text(i.1).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
