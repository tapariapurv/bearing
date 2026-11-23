import SwiftUI
import UserNotifications

/// The phone app runs the same Store, Coach, sync and integrations as the Mac; only the layout differs.
@main struct BearingApp: App {
    @Environment(\.scenePhase) private var phase
    init() { if Store.isTesting { Snapshot.demo() } }
    var body: some Scene {
        WindowGroup {
            PhoneRoot().onChange(of: phase, initial: true) {
                guard phase == .active else { if phase == .background { Store.shared.saveNow() }; return }
                Todoist.shared.nudge(); Task { await Sync.pull() }
            }
            .task {
                guard !Store.isTesting else { return }
                Todoist.shared.start()
                if GoogleCalendar.shared.connected { GoogleCalendar.shared.start() }
                if CalendarService.shared.granted { await CalendarService.shared.request() }
                _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            }
        }
    }
}

struct PhoneRoot: View {
    @State private var nav = Nav.shared
    @State private var store = Store.shared
    private let more: [(Page, String, String)] = [(.goals, "Goals", "scope"), (.focus, "Focus", "timer"), (.journal, "Journal", "book"),
                                                  (.capture, "Capture", "waveform"), (.insights, "Insights", "chart.bar")]
    @State private var tab = CommandLine.arguments.contains("--tasks") ? "Tasks" : "Today"   // --tasks: open on Tasks (screenshots)
    var body: some View {
        Group {
            if store.data.prefs.profile == nil { NavigationStack { WelcomeView() } }
            else {
                TabView(selection: $tab) {
                    Tab("Today", systemImage: "sun.max", value: "Today") {
                        NavigationStack {
                            PageView(page: .today).toolbar { NavigationLink { ScrollView { DayPanel() }.navigationTitle("Today") } label: { Label("Summary", systemImage: "chart.pie") } }
                                .toolbarTitleDisplayMode(.inline)
                        }
                    }
                    Tab("Week", systemImage: "calendar", value: "Week") { NavigationStack { PageView(page: .week) } }
                    Tab("Tasks", systemImage: "checklist", value: "Tasks") { NavigationStack { PageView(page: .tasks) } }
                    Tab("Coach", systemImage: "sparkles", value: "Coach") { NavigationStack { PageView(page: .coach) } }
                    Tab("More", systemImage: "ellipsis", value: "More") {
                        NavigationStack {
                            List {
                                ForEach(more, id: \.0) { p in NavigationLink { PageView(page: p.0).navigationTitle(p.1) } label: { Label(p.1, systemImage: p.2) } }
                                NavigationLink { SettingsView() } label: { Label("Settings", systemImage: "gear") }
                            }.navigationTitle("More")
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $nav.seasonSetup) { SeasonSetup().bearingStyle() }
        .sheet(isPresented: $nav.dailySync) { DailySync().bearingStyle() }
        .sheet(isPresented: $nav.reflect) { ReflectView().bearingStyle() }
        .bearingStyle()
    }
}
