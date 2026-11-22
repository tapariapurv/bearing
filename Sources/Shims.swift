import SwiftUI
#if os(iOS)
import AudioToolbox
// iOS stand-ins for Mac-only pieces: no floating window, cursors or split views on a phone.
@MainActor enum FloatingTimer { static func show() {}; static func hide() {} }
enum NSCursor { case closedHand, resizeUpDown; func push() {}; static func pop() {} }
struct HSplitView<C: View>: View { @ViewBuilder var content: C; var body: some View { VStack(spacing: 0) { content } } }
struct SettingsLink<L: View>: View { @ViewBuilder var label: L; var body: some View { NavigationLink { SettingsView() } label: { label } } }
#endif
