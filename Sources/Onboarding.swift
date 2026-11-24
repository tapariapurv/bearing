import SwiftUI

/// First run: account, the person's own setup, a hands-on tour, then the coach learns about them and drafts goals.
struct Onboarding: View {
    @State private var store = Store.shared
    @State private var google = GoogleCalendar.shared
    @State private var step = 0
    @State private var forward = true
    @State private var busy = false
    @State private var cal = "google"
    @State private var tasks = "bearing"
    @State private var brain = AIProvider.bearing
    @State private var todoistKey = ""
    private let steps = ["Welcome", "Account", "Your system", "How it works", "Your coach", "Ready"]

    var body: some View {
        VStack(spacing: 0) {
            if step > 0 { progress.padding(.top, 22).transition(.opacity) }
            ZStack {
                page.id(step)
                    .transition(.asymmetric(insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                                            removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)))
            }
            .frame(maxWidth: 620, maxHeight: .infinity).clipped()
        }
        .onAppear { if store.data.prefs.onboarded == nil { store.data.prefs.onboarded = false } }
        .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.page)
        .animation(.snappy(duration: 0.38), value: step)
    }

    private func go(_ to: Int) { forward = to > step; step = to }
    private func next() { go(step == 0 && store.data.prefs.profile != nil ? 2 : step + 1) }

    private var progress: some View {
        HStack(spacing: 6) {
            ForEach(1..<steps.count, id: \.self) { i in
                Capsule().fill(i <= step ? Color.brand : Color.primary.opacity(0.1)).frame(width: i == step ? 28 : 8, height: 8)
                    .onTapGesture { if i < step { go(i) } }.accessibilityLabel(steps[i])
            }
        }
    }

    @ViewBuilder private var page: some View {
        switch step {
        case 0: welcome
        case 1: account
        case 2: system
        case 3: TourStep { next() }
        case 4: CoachStep { next() }
        default: done
        }
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(spacing: 0) {
            Spacer()
            Compass().frame(width: 120, height: 120)
            Text("Welcome to Bearing").font(.system(size: 34, weight: .bold)).padding(.top, 26)
            Text("Plan your week around what matters, focus without distractions, and get an honest coach for where your time goes.")
                .font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 480).padding(.top, 10)
            Button("Get Started") { next() }.buttonStyle(BigButton()).keyboardShortcut(.defaultAction).padding(.top, 34)
            Text("Takes about two minutes.").font(.caption).foregroundStyle(.tertiary).padding(.top, 12)
            Spacer()
        }
    }

    private var account: some View {
        StepFrame("Make it yours", "Sign in to sync across your Mac, iPhone and the web, and to bring in Google Calendar.") {
            VStack(spacing: 12) {
                Button {
                    busy = true
                    Task { await google.connect(); busy = false; if store.data.prefs.profile != nil { next() } }
                } label: {
                    HStack(spacing: 10) {
                        Text("G").font(.system(size: 13, weight: .heavy)).foregroundStyle(Color.action).frame(width: 20, height: 20).background(.white, in: .circle)
                        Text(busy ? "Finish signing in in your browser…" : "Continue with Google")
                    }
                }
                .buttonStyle(BigButton()).disabled(busy || GoogleClient.id.isEmpty)
                Button("Use Bearing on this device only") { store.data.prefs.profile = Profile(name: fullName); cal = "apple"; next() }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                if !google.status.isEmpty && !busy { Text(google.status).font(.caption).foregroundStyle(.secondary) }
            }
        } footer: { EmptyView() }
    }

    private var system: some View {
        StepFrame("Choose your system", "Bearing fits around the tools you already use. You can change any of this in Settings.") {
            VStack(alignment: .leading, spacing: 18) {
                Choice(title: "Calendar", selection: $cal, options: [
                    ("google", "Google", "g.circle", store.data.prefs.profile?.email.isEmpty == false),
                    ("apple", "Apple Calendar", "calendar", true), ("none", "Not now", "minus.circle", true)])
                Choice(title: "Tasks", selection: $tasks, options: [
                    ("bearing", "In Bearing", "checklist", true), ("todoist", "Todoist", "arrow.triangle.2.circlepath", true)])
                if tasks == "todoist" {
                    SecureField("Todoist API token (Todoist › Settings › Integrations › Developer)", text: $todoistKey)
                        .textFieldStyle(.roundedBorder).transition(.move(edge: .top).combined(with: .opacity))
                }
                Choice(title: "Coach", selection: $brain, options: [
                    (.bearing, "Bearing AI", "sparkles", true), (.ollama, "On this Mac", "lock.laptopcomputer", true), (.anthropic, "My own key", "key", true)])
                Text(brainNote).font(.caption).foregroundStyle(.secondary).contentTransition(.opacity)
            }
            .animation(.snappy(duration: 0.25), value: tasks)
        } footer: {
            Button("Continue") { Task { await applySystem(); next() } }.buttonStyle(BigButton()).keyboardShortcut(.defaultAction)
        }
    }

    private var brainNote: String { switch brain {
        case .bearing: "Free, private by default, and no key needed. Runs on Claude."
        case .ollama: "Runs fully offline with Ollama. Install it from ollama.com, then pull a model."
        default: "Add your key in Settings › AI after setup. The coach uses Bearing AI until then." } }

    private func applySystem() async {
        if cal == "apple" { await CalendarService.shared.request() }
        if tasks == "todoist", !todoistKey.isEmpty { await Todoist.shared.connect(todoistKey) }
        store.data.prefs.provider = brain == .anthropic ? .bearing : brain
    }

    private var done: some View {
        VStack(spacing: 0) {
            Spacer()
            Image(systemName: "checkmark").font(.system(size: 34, weight: .bold)).foregroundStyle(Color.onBrand)
                .frame(width: 84, height: 84).background(Color.brand, in: .circle)
                .phaseAnimator([0.6, 1.0], trigger: step) { $0.scaleEffect($1) } animation: { _ in .spring(duration: 0.45, bounce: 0.35) }
            Text("You're all set").font(.system(size: 32, weight: .bold)).padding(.top, 22)
            VStack(alignment: .leading, spacing: 12) {
                tip("calendar.badge.plus", "Each morning, press Plan with Coach to fill your day.")
                tip("hand.draw", "Drag any task onto the calendar to block time for it.")
                tip("timer", "Start Focus to block distractions and track real hours.")
                tip("moon.stars", "At night, a two-minute check-in keeps your coach honest.")
            }.padding(18).surface(16).frame(maxWidth: 440).padding(.top, 24)
            Button("Open Bearing") { store.data.prefs.onboarded = true }.buttonStyle(BigButton()).keyboardShortcut(.defaultAction).padding(.top, 28)
            Spacer()
        }
    }
    private func tip(_ icon: String, _ text: String) -> some View {
        Label { Text(text).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: icon).foregroundStyle(Color.brand).frame(width: 22) }
    }
    private var fullName: String {
        #if os(macOS)
        NSFullUserName()
        #else
        ""
        #endif
    }
}

// MARK: - Tour

private struct TourStep: View {
    var next: () -> Void
    @State private var tab = 0
    private let items: [(String, String, String)] = [
        ("Plan", "calendar", "Pick a few goals for the season. Each morning your coach turns them and your tasks into time blocks."),
        ("Focus", "timer", "Start a block to focus. Bearing blocks distracting sites and records the hours you really put in."),
        ("Reflect", "chart.bar.fill", "Planned versus actual, side by side. A short check-in each night, and a weekly review with fixes."),
    ]
    var body: some View {
        StepFrame("How Bearing works", "Three loops, every day. Tap each one.") {
            VStack(spacing: 18) {
                HStack(spacing: 8) {
                    ForEach(items.indices, id: \.self) { i in
                        Button { tab = i } label: {
                            Label(items[i].0, systemImage: items[i].1).font(.callout.weight(.semibold)).padding(.horizontal, 16).padding(.vertical, 9)
                                .foregroundStyle(tab == i ? Color.onBrand : .primary)
                                .background(tab == i ? Color.brand : Color.primary.opacity(0.06), in: .capsule)
                        }.buttonStyle(.plain)
                    }
                }
                Group {
                    switch tab { case 0: PlanDemo(); case 1: FocusDemo(); default: ReflectDemo() }
                }
                .id(tab).transition(.opacity.combined(with: .scale(scale: 0.97))).frame(height: 190).frame(maxWidth: .infinity).surface(18)
                Text(items[tab].2).font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(minHeight: 56, alignment: .top).id("t\(tab)").transition(.opacity)
            }
            .animation(.snappy(duration: 0.3), value: tab)
        } footer: {
            Button(tab < 2 ? "Next" : "Meet Your Coach") { tab < 2 ? (tab += 1) : next() }.buttonStyle(BigButton()).keyboardShortcut(.defaultAction)
        }
    }
}

private struct PlanDemo: View {
    @State private var shown = 0
    private let blocks: [(String, Int, CGFloat)] = [("Deep work: thesis", 4, 0), ("Gym", 2, 1.3), ("Ship landing page", 0, 2.1)]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(blocks.indices, id: \.self) { i in
                HStack(spacing: 10) {
                    Text("\(9 + i * 2):00").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 40)
                    Text(blocks[i].0).font(.callout.weight(.semibold)).foregroundStyle(goalColor(blocks[i].1).ink)
                        .padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                        .background(goalColor(blocks[i].1).wash, in: .rect(cornerRadius: 10))
                        .opacity(i < shown ? 1 : 0).offset(x: i < shown ? 0 : 40)
                }
            }
        }
        .padding(20)
        .task { for i in 1...3 { try? await Task.sleep(for: .milliseconds(260)); withAnimation(.spring(duration: 0.4, bounce: 0.2)) { shown = i } } }
    }
}

private struct FocusDemo: View {
    @State private var p = 0.0
    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.08), lineWidth: 12)
            Circle().trim(from: 0, to: p).stroke(Color.brand, style: StrokeStyle(lineWidth: 12, lineCap: .round)).rotationEffect(.degrees(-90))
            VStack(spacing: 2) {
                Text("25:00").font(.system(size: 26, weight: .bold).monospacedDigit())
                Text("Focusing").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(width: 140, height: 140)
        .onAppear { withAnimation(.easeInOut(duration: 1.6)) { p = 0.72 } }
    }
}

private struct ReflectDemo: View {
    @State private var on = false
    private let data: [(CGFloat, CGFloat)] = [(0.8, 0.7), (0.6, 0.3), (0.9, 0.85), (0.5, 0.55), (0.7, 0.4)]
    var body: some View {
        HStack(alignment: .bottom, spacing: 14) {
            ForEach(data.indices, id: \.self) { i in
                HStack(alignment: .bottom, spacing: 3) {
                    Capsule().fill(Color.primary.opacity(0.12)).frame(width: 12, height: on ? data[i].0 * 120 : 4)
                    Capsule().fill(Color.brand).frame(width: 12, height: on ? data[i].1 * 120 : 4)
                }
            }
        }
        .frame(height: 140, alignment: .bottom)
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 10) { Label("Planned", systemImage: "circle.fill").foregroundStyle(.secondary); Label("Actual", systemImage: "circle.fill").foregroundStyle(Color.brand) }
                .font(.caption2).labelStyle(.titleAndIcon).offset(y: -18)
        }
        .onAppear { withAnimation(.spring(duration: 0.7, bounce: 0.15).delay(0.1)) { on = true } }
    }
}

// MARK: - Coach

private struct Draft: Decodable { var notes: String?; var goals: [DraftGoal]? }
private struct DraftGoal: Decodable, Hashable { var title: String; var why: String?; var hours: Double? }

private struct CoachStep: View {
    var next: () -> Void
    @State private var store = Store.shared
    @State private var msgs: [ChatMsg] = [ChatMsg(role: "assistant", text: Self.known.isEmpty
        ? "Hi, I'm your coach. I'll help you spend your time on what matters. To start: what are you working toward right now? School, a project, a skill, anything."
        : "Welcome back. I still remember what you've told me, so we can pick up from there. What's changed, or what do you want to work toward next?")]
    /// What the coach already knows, so a repeat run builds on it. Empty after Start Fresh.
    static var known: String {
        let d = Store.shared.data
        return [d.aboutSummary, d.about?.suffix(8).map { "\($0.q) → \($0.a)" }.joined(separator: "\n"),
                d.goals.filter { !$0.archived }.isEmpty ? nil : "Current goals: " + d.goals.filter { !$0.archived }.map(\.title).joined(separator: ", ")]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
    }
    @State private var input = ""
    @State private var thinking = false
    @State private var draft: [DraftGoal] = []
    @State private var picked: Set<DraftGoal> = []
    @State private var error = ""
    private var answers: Int { msgs.filter { $0.role == "user" }.count }
    private let chips = [["I'm a student", "Building a startup", "Learning a skill", "Getting fit"], ["Mornings", "Evenings", "Late at night", "It changes"], ["My phone", "Too many tasks", "Losing motivation", "Meetings"]]

    var body: some View {
        StepFrame("Meet your coach", "A short chat so your coach knows you. It sets up your first goals for you.") {
            VStack(spacing: 12) {
                ScrollViewReader { sv in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(msgs) { m in bubble(m).id(m.id).transition(.move(edge: .bottom).combined(with: .opacity)) }
                            if thinking && msgs.last?.role == "user" { TypingDots().id("dots") }
                            if !draft.isEmpty { goals.id("goals").transition(.opacity.combined(with: .scale(scale: 0.98))) }
                        }.padding(4)
                    }
                    .frame(height: 300)
                    .onChange(of: msgs) { withAnimation { sv.scrollTo(draft.isEmpty ? msgs.last?.id as AnyHashable? : "goals", anchor: .bottom) } }
                    .onChange(of: draft) { withAnimation { sv.scrollTo("goals", anchor: .bottom) } }
                }
                if draft.isEmpty {
                    if answers < chips.count && !thinking {
                        HStack(spacing: 6) { ForEach(chips[answers], id: \.self) { c in Button(c) { send(c) }.buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.small) } }
                    }
                    HStack {
                        TextField("Reply to your coach", text: $input).textFieldStyle(.plain).padding(.horizontal, 14).frame(height: 40)
                            .background(Color.primary.opacity(0.05), in: .capsule).onSubmit { send(input) }
                        Button { send(input) } label: { Image(systemName: "arrow.up").font(.body.weight(.bold)).frame(width: 40, height: 40).foregroundStyle(Color.onBrand).background(Color.brand, in: .circle) }
                            .buttonStyle(.plain).disabled(input.trimmingCharacters(in: .whitespaces).isEmpty || thinking)
                    }
                }
                if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.secondary) }
            }
            .animation(.snappy(duration: 0.3), value: msgs).animation(.snappy(duration: 0.3), value: draft)
        } footer: {
            HStack {
                Button("Skip for now") { next() }.buttonStyle(.plain).foregroundStyle(.secondary)
                if !draft.isEmpty { Button("Add \(picked.count) Goal\(picked.count == 1 ? "" : "s")") { save(); next() }.buttonStyle(BigButton()).disabled(picked.isEmpty) }
            }
        }
    }

    private func bubble(_ m: ChatMsg) -> some View {
        let me = m.role == "user"
        return Text(m.text).textSelection(.enabled).padding(.horizontal, 14).padding(.vertical, 10)
            .foregroundStyle(me ? Color.onBrand : .primary).background(me ? Color.brand : Color.primary.opacity(0.06), in: .rect(cornerRadius: 18))
            .frame(maxWidth: 440, alignment: me ? .trailing : .leading).frame(maxWidth: .infinity, alignment: me ? .trailing : .leading)
    }

    private var goals: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your first goals").font(.headline)
            ForEach(draft, id: \.self) { g in
                Button { if picked.contains(g) { picked.remove(g) } else { picked.insert(g) } } label: {
                    HStack(spacing: 12) {
                        Image(systemName: picked.contains(g) ? "checkmark.circle.fill" : "circle").font(.title3).foregroundStyle(picked.contains(g) ? Color.brand : .secondary)
                        VStack(alignment: .leading, spacing: 2) { Text(g.title).font(.callout.weight(.semibold)); if let w = g.why { Text(w).font(.caption).foregroundStyle(.secondary) } }
                        Spacer()
                        Text("\(Int(g.hours ?? 5)) h/wk").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }.padding(12).contentShape(.rect).surface(14)
                }.buttonStyle(.plain)
            }
        }
    }

    private var system: String {
        """
        You are the coach inside Bearing, a planner with three loops: Plan (season goals turned into daily time blocks), Focus (timed sessions that block distractions and log real hours) and Reflect (planned vs actual, a nightly check-in, a weekly review).
        You are onboarding a new person. Be warm, brief (2 to 3 sentences), and encouraging. Each reply: react to what they said in one line, teach one Bearing feature that fits them, then ask one question.
        Learn in order: what they work toward, when they focus best, what derails them. Skip anything you already know.\(Self.known.isEmpty ? "" : "\nWhat you already know about them:\n" + Self.known + "\nDon't suggest goals they already have.") \(answers >= 3 ? """
        You now know enough. Thank them in one sentence, then on a new line output only JSON: {"notes":"3 short lines on their preferences for future coaching","goals":[{"title":"short goal","why":"one line","hours":weekly hours}]} with 1 to 3 goals that fit what they said.
        """ : "")
        """
    }

    private func send(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines); guard !t.isEmpty, !thinking else { return }
        input = ""; error = ""; msgs.append(ChatMsg(role: "user", text: t)); thinking = true
        store.data.about = (store.data.about ?? []) + [QA(q: msgs[msgs.count - 2].text, a: t)]
        Task {
            var reply = ChatMsg(role: "assistant", text: "")
            do {
                try await AI.stream(system: system, messages: msgs) { tok in
                    if reply.text.isEmpty { msgs.append(reply) }
                    reply.text += tok
                    if let i = msgs.lastIndex(where: { $0.id == reply.id }) { msgs[i].text = reply.text.components(separatedBy: "{").first ?? reply.text }
                }
                if let d = extractJSON(Draft.self, from: reply.text) {
                    if let n = d.notes, !n.isEmpty { store.data.aboutSummary = [store.data.aboutSummary, n].compactMap { $0 }.joined(separator: "\n") }
                    draft = d.goals ?? []; picked = Set(draft)
                }
            } catch { self.error = "The coach couldn't reply: \(error.localizedDescription). You can skip and chat later." }
            thinking = false
        }
    }

    private func save() {
        var used = Set(store.data.goals.map(\.color))
        for (i, g) in draft.filter(picked.contains).enumerated() {
            let c = (0..<8).first { !used.contains($0) } ?? i; used.insert(c)
            store.data.goals.append(Goal(title: g.title, why: g.why ?? "", color: c, weeklyHours: g.hours ?? 5, level: i == 0 ? .core : .secondary))
        }
    }
}

private struct TypingDots: View {
    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3) { i in
                Circle().fill(Color.secondary).frame(width: 7, height: 7)
                    .phaseAnimator([0.3, 1.0]) { $0.opacity($1) } animation: { _ in .easeInOut(duration: 0.5).delay(Double(i) * 0.15) }
            }
        }.padding(.horizontal, 16).padding(.vertical, 14).background(Color.primary.opacity(0.06), in: .capsule)
    }
}

// MARK: - Pieces

private struct StepFrame<Content: View, Footer: View>: View {
    let title: String, sub: String
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer
    init(_ title: String, _ sub: String, @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        self.title = title; self.sub = sub; self.content = content(); self.footer = footer()
    }
    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 20)
            Text(title).font(.system(size: 30, weight: .bold))
            Text(sub).font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 500).padding(.top, 8)
            content.padding(.top, 28)
            footer.padding(.top, 24)
            Spacer(minLength: 20)
        }
    }
}

private struct Choice<T: Hashable>: View {
    let title: String
    @Binding var selection: T
    let options: [(T, String, String, Bool)]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                ForEach(options.indices, id: \.self) { i in
                    let (v, name, icon, ok) = options[i], on = selection == v
                    Button { selection = v } label: {
                        VStack(spacing: 8) {
                            Image(systemName: icon).font(.title2).foregroundStyle(on ? Color.brand : .secondary).symbolEffect(.bounce, value: on)
                            Text(name).font(.callout.weight(.semibold))
                        }
                        .frame(maxWidth: .infinity, minHeight: 82).contentShape(.rect)
                        .background(on ? Color.brandSoft : Color.surface, in: .rect(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(on ? Color.brand : Color.primary.opacity(0.08), lineWidth: on ? 2 : 1))
                        .scaleEffect(on ? 1 : 0.98)
                    }
                    .buttonStyle(.plain).disabled(!ok).opacity(ok ? 1 : 0.4)
                }
            }
            .animation(.snappy(duration: 0.22), value: selection)
        }
    }
}

private struct BigButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.onBrand)
            .frame(minWidth: 240).padding(.horizontal, 24).frame(height: 46).background(Color.brand, in: .capsule)
            .scaleEffect(configuration.isPressed ? 0.97 : 1).animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// The welcome mark: a needle that settles on north.
private struct Compass: View {
    @State private var angle = -140.0
    var body: some View {
        ZStack {
            Circle().fill(Color.brandSoft)
            Circle().strokeBorder(Color.brand.opacity(0.25), lineWidth: 2).padding(10)
            ForEach(0..<4) { i in Capsule().fill(Color.brand.opacity(0.4)).frame(width: 3, height: 10).offset(y: -44).rotationEffect(.degrees(Double(i) * 90)) }
            VStack(spacing: 0) {
                Triangle().fill(Color.brand).frame(width: 18, height: 38)
                Triangle().fill(Color.primary.opacity(0.2)).frame(width: 18, height: 38).rotationEffect(.degrees(180))
            }
            .rotationEffect(.degrees(angle))
            Circle().fill(Color.page).frame(width: 10, height: 10)
        }
        .onAppear { withAnimation(.spring(duration: 1.4, bounce: 0.45).delay(0.2)) { angle = 0 } }
        .accessibilityHidden(true)
    }
}

private struct Triangle: Shape {
    func path(in r: CGRect) -> Path { Path { p in p.move(to: CGPoint(x: r.midX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX, y: r.maxY)); p.closeSubpath() } }
}
