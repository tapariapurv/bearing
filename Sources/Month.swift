import SwiftUI

/// A month at a glance: blocks and events per day. Click a day to open it.
struct MonthPage: View {
    @State private var store = Store.shared
    @State private var month = Calendar.current.dateInterval(of: .month, for: Date())!.start
    private var first: Date { month.startOfWeek }
    private var cells: [Date] { (0..<42).map { first.adding(days: $0) } }
    var body: some View {
        let evs = CalendarService.shared.events(from: first, to: first.adding(days: 42))
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                step("chevron.left", -1); step("chevron.right", 1)
                Button("This month") { month = Calendar.current.dateInterval(of: .month, for: Date())!.start }.buttonStyle(QuietButton())
                    .disabled(Calendar.current.isDate(month, equalTo: Date(), toGranularity: .month))
                Spacer()
            }.overlay { Text(month.formatted(.dateTime.month(.wide).year())).font(.system(size: 15, weight: .semibold)) }
            .padding(.horizontal, 18).frame(height: 54)
            HStack(spacing: 0) {
                ForEach(0..<7, id: \.self) { i in Text(first.adding(days: i).formatted(.dateTime.weekday(.abbreviated))).frame(maxWidth: .infinity) }
            }.font(.caption.weight(.medium)).foregroundStyle(.secondary).padding(.bottom, 6)
            Divider()
            GeometryReader { g in
                let h = g.size.height / 6
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 0) {
                    ForEach(cells, id: \.self) { d in cell(d, evs: evs).frame(height: h) }
                }
            }
        }
    }
    private func step(_ icon: String, _ by: Int) -> some View {
        Button { month = Calendar.current.date(byAdding: .month, value: by, to: month)! } label: {
            Image(systemName: icon).font(.system(size: 11, weight: .semibold)).frame(width: 28, height: 28)
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.12))).contentShape(.circle)
        }.buttonStyle(.plain).accessibilityLabel(by < 0 ? "Previous month" : "Next month")
    }
    private func cell(_ d: Date, evs: [CalEvent]) -> some View {
        let end = d.adding(days: 1), today = Calendar.current.isDateInToday(d)
        let inMonth = Calendar.current.isDate(d, equalTo: month, toGranularity: .month)
        let items: [(String, Color)] = store.data.blocks.filter { $0.start >= d && $0.start < end }.sorted { $0.start < $1.start }
            .map { ($0.title, store.tint(goal: $0.goalID, task: $0.taskID)) }
            + evs.filter { $0.start < end && $0.end > d }.map { ($0.title, $0.color) }
        return Button { Nav.shared.jump = d; Nav.shared.page = .today } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(d.formatted(.dateTime.day())).font(.system(size: 12, weight: today ? .bold : .medium))
                    .foregroundStyle(today ? Color.onBrand : inMonth ? Color.primary : Color.secondary.opacity(0.6))
                    .frame(minWidth: 22, minHeight: 22).background(today ? Color.brand : .clear, in: .circle)
                ForEach(Array(items.prefix(3).enumerated()), id: \.offset) { _, x in
                    Text(x.0).font(.system(size: 11, weight: .medium)).lineLimit(1).padding(.horizontal, 6).padding(.vertical, 2)
                        .frame(maxWidth: .infinity, alignment: .leading).background(x.1.wash, in: .rect(cornerRadius: 5)).foregroundStyle(x.1.ink)
                }
                if items.count > 3 { Text("+\(items.count - 3) more").font(.system(size: 10)).foregroundStyle(.secondary) }
                Spacer(minLength: 0)
            }.padding(6).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .opacity(inMonth ? 1 : 0.55).contentShape(.rect)
        }.buttonStyle(.plain)
        .overlay(alignment: .trailing) { Rectangle().fill(Color.primary.opacity(0.06)).frame(width: 1) }
        .overlay(alignment: .bottom) { Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 1) }
    }
}
