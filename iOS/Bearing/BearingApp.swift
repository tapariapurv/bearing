import PostHog
import SwiftUI
import UserNotifications

/// The phone app runs the same Store, Coach, sync and integrations as the Mac; only the layout differs.
@main struct BearingApp: App {
    @Environment(\.scenePhase) private var phase

    init() {
        configurePostHog()
        if Store.isTesting { Snapshot.demo() }
    }
    var body: some Scene {
        WindowGroup {
            PhoneRoot().onChange(of: phase, initial: true) {
                guard phase == .active else {
                    if phase == .background {
                        PostHogAppLogger.info("app_entered_background", attributes: ["lifecycle_state": "background"])
                        Store.shared.saveNow()
                    }
                    return
                }
                PostHogAppLogger.info("app_became_active", attributes: ["lifecycle_state": "active"])
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

private func configurePostHog() {
    guard let token = Bundle.main.object(forInfoDictionaryKey: "POSTHOG_PROJECT_TOKEN") as? String,
          !token.isEmpty else {
#if DEBUG
        assertionFailure("POSTHOG_PROJECT_TOKEN variable required by PostHog is missing or un-configured, this causes events to be silently missed. This error stops appearing once POSTHOG_PROJECT_TOKEN is configured")
#endif
        return
    }

    guard let host = Bundle.main.object(forInfoDictionaryKey: "POSTHOG_HOST") as? String,
          !host.isEmpty else {
#if DEBUG
        assertionFailure("POSTHOG_HOST variable required by PostHog is missing or un-configured, this causes events to be silently missed. This error stops appearing once POSTHOG_HOST is configured")
#endif
        return
    }

    let config = PostHogConfig(projectToken: token, host: host)
    config.errorTrackingConfig.autoCapture = true
    config.logs.serviceName = Bundle.main.bundleIdentifier ?? "Bearing"
    PostHogSDK.shared.setup(config)
    PostHogAppLogger.info("posthog_logs_configured", attributes: ["capture_scope": "app_lifecycle"])
}

private enum PostHogAppLogger {
    static func info(_ message: String, attributes: [String: Any]) {
        PostHogSDK.shared.logger?.info(message, attributes: attributes)
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
        .onChange(of: tab) {
            PostHogSDK.shared.capture("tab_selected", properties: ["tab": tab])
        }
    }
}
