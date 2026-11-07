import SwiftUI
import ApplicationServices

// MARK: - Focus quality: on-device activity tracking. Nothing leaves the Mac; only app names and seconds are stored.

/// Seconds spent in one app (or one distracting site in a browser) during a session.
struct AppTime: Codable, Hashable, Identifiable {
    var id: String             // bundle id, bundle|site, or "idle"
    var name: String
    var seconds = 0.0
    var site: String?
}
struct FocusBreakdown: Equatable { var onTask = 0.0, distraction = 0.0, idle = 0.0
    var total: Double { onTask + distraction + idle }
    var score: Int { total > 0 ? Int((onTask / total * 100).rounded()) : 0 }
}

@MainActor enum Tracker {
    static let idleAfter = 90.0
    static let defaultDistracting = ["com.apple.MobileSMS", "com.hnc.Discord", "net.whatsapp.WhatsApp", "ru.keepcoder.Telegram", "com.apple.TV", "com.apple.news", "com.valvesoftware.steam", "com.apple.FaceTime"]
    nonisolated static let sites = ["youtube", "netflix", "reddit", "instagram", "facebook", "tiktok", "twitch", "x.com", "twitter", "news.ycombinator"]
    static var distracting: Set<String> { Set((Store.shared.data.prefs.distractingApps ?? defaultDistracting) + Store.shared.data.prefs.blockApps) }

    /// One second of the session: idle, or whatever app is in front.
    static func sample(_ dt: Double, into a: inout [String: AppTime]) {
        let quiet = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        var t: AppTime
        if quiet > idleAfter { t = a["idle"] ?? AppTime(id: "idle", name: "Away") }
        else {
            guard let app = NSWorkspace.shared.frontmostApplication, let b = app.bundleIdentifier else { return }
            let site = windowTitle(app).flatMap(site(in:))
            let key = site.map { b + "|" + $0 } ?? b
            t = a[key] ?? AppTime(id: key, name: (app.localizedName ?? b) + (site.map { " · \($0)" } ?? ""), site: site)
        }
        t.seconds += dt; a[t.id] = t
    }
    /// The front window's title, only when the person has allowed Accessibility. Read, matched, discarded.
    private static func windowTitle(_ app: NSRunningApplication) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let el = AXUIElementCreateApplication(app.processIdentifier)
        var w: CFTypeRef?, t: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXFocusedWindowAttribute as CFString, &w) == .success, let w,
              AXUIElementCopyAttributeValue(w as! AXUIElement, kAXTitleAttribute as CFString, &t) == .success else { return nil }
        return t as? String
    }
    nonisolated static func site(in title: String) -> String? { let l = title.lowercased(); return sites.first { l.contains($0) } }

    static func isDistraction(_ t: AppTime, intention: String, distracting: Set<String>) -> Bool {
        if let s = t.site { return !intention.lowercased().contains(s) }   // "watch the YouTube lecture" keeps YouTube on task
        return distracting.contains(t.id)
    }
    static func breakdown(_ a: [AppTime], intention: String, distracting: Set<String>? = nil) -> FocusBreakdown {
        let d = distracting ?? self.distracting
        var r = FocusBreakdown()
        for t in a {
            if t.id == "idle" { r.idle += t.seconds } else if isDistraction(t, intention: intention, distracting: d) { r.distraction += t.seconds } else { r.onTask += t.seconds }
        }
        return r
    }
    static func toggleDistraction(_ bundle: String) {
        var l = Store.shared.data.prefs.distractingApps ?? defaultDistracting
        if l.contains(bundle) { l.removeAll { $0 == bundle } } else { l.append(bundle) }
        Store.shared.data.prefs.distractingApps = l
    }
}

/// End-of-session card: the score, the split, and where the time went.
struct FocusSummary: View {
    let session: Session
    @State private var store = Store.shared
    var body: some View {
        let a = session.activity ?? []
        let b = Tracker.breakdown(a, intention: session.title, distracting: Tracker.distracting)
        Card(title: "Session Summary") {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(b.score)%").font(.system(size: 34, weight: .bold, design: .rounded)).monospacedDigit()
                Text("focus quality").foregroundStyle(.secondary)
                Spacer()
                Text(hm(session.seconds)).foregroundStyle(.secondary).monospacedDigit()
            }
            GeometryReader { g in
                HStack(spacing: 2) {
                    ForEach([(b.onTask, Color.green), (b.distraction, Color.red), (b.idle, Color.secondary.opacity(0.4))], id: \.1) { v, c in
                        if v > 0 { Capsule().fill(c).frame(width: max(4, g.size.width * v / max(1, b.total) - 2)) }
                    }
                }
            }.frame(height: 8)
            HStack(spacing: 14) {
                legend("On task", b.onTask, .green); legend("Distraction", b.distraction, .red); legend("Idle or away", b.idle, .secondary)
            }.font(.caption)
            if a.isEmpty { Text("No activity was recorded for this session.").font(.caption).foregroundStyle(.secondary) }
            ForEach(a.filter { $0.id != "idle" }.sorted { $0.seconds > $1.seconds }.prefix(6)) { t in
                let bad = Tracker.isDistraction(t, intention: session.title, distracting: Tracker.distracting)
                HStack {
                    Circle().fill(bad ? Color.red : .green).frame(width: 6, height: 6)
                    Text(t.name).lineLimit(1)
                    Spacer()
                    Text(hm(t.seconds)).monospacedDigit().foregroundStyle(.secondary)
                    if t.site == nil {
                        Button(bad ? "Mark On Task" : "Mark Distracting") { Tracker.toggleDistraction(t.id) }.controlSize(.small)
                    }
                }.font(.callout)
            }
            if !AXIsProcessTrusted() {
                Text("Allow Bearing under Privacy & Security > Accessibility to tell YouTube or Reddit apart from work in your browser. Titles are checked on this Mac and never stored.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    private func legend(_ t: String, _ s: Double, _ c: Color) -> some View {
        HStack(spacing: 5) { Circle().fill(c).frame(width: 6, height: 6); Text("\(t) \(hm(s))").foregroundStyle(.secondary) }
    }
}

/// Today's sessions beside the plan: what actually happened.
struct ActualColumn: View {
    @State private var store = Store.shared
    var body: some View {
        let today = store.data.sessions.filter { Calendar.current.isDateInToday($0.start) }.sorted { $0.start < $1.start }
        VStack(alignment: .leading, spacing: 8) {
            Text("Actual").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if today.isEmpty { Text("No focus sessions yet.").font(.callout).foregroundStyle(.secondary) }
            ForEach(today) { s in
                let c = store.goal(s.goalID).map { goalColor($0.color) } ?? .gray
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.title).font(.callout.weight(.medium)).lineLimit(1)
                    Text("\(s.start.clock) · \(hm(s.seconds))\(s.activity.map { " · \(Tracker.breakdown($0, intention: s.title).score)% focus" } ?? "")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10).padding(.vertical, 7).frame(maxWidth: .infinity, alignment: .leading)
                .background(c.opacity(0.1), in: .rect(cornerRadius: 10))
            }
        }
    }
}
