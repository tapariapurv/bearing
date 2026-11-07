import SwiftUI

// Bearing's own controls. Set once at the root, so screens don't restyle anything.

extension Color { static let onBrand = dyn(0x082F49, 0x082F49) }
extension EnvironmentValues { @Entry var fillRow = false }

extension View {
    func bearingStyle() -> some View {
        tint(.brand).buttonStyle(QuietButton()).toggleStyle(SwitchToggle()).fontDesign(.rounded)
    }
    func field() -> some View { modifier(FieldStyle()) }
}

private struct PressHover<Content: View>: View {
    var pressed: Bool
    @ViewBuilder var content: (Bool) -> Content
    @State private var hover = false
    var body: some View {
        content(hover).onHover { hover = $0 }
            .scaleEffect(pressed ? 0.97 : 1).animation(.easeOut(duration: 0.1), value: pressed)
    }
}

struct QuietButton: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration c: Configuration) -> some View {
        PressHover(pressed: c.isPressed) { hover in
            c.label.font(.callout.weight(.medium))
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(Color.primary.opacity(hover && enabled ? 0.12 : 0.07), in: .capsule).contentShape(.capsule)
                .opacity(enabled ? 1 : 0.4)
        }
    }
}

struct FieldStyle: ViewModifier {
    @FocusState private var focused: Bool
    func body(content: Content) -> some View {
        content.textFieldStyle(.plain).labelsHidden().focused($focused)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 9))
            .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(focused ? Color.brand : Color.primary.opacity(0.08), lineWidth: focused ? 1.5 : 1) }
    }
}

struct SwitchToggle: ToggleStyle {
    @Environment(\.fillRow) private var fill
    func makeBody(configuration c: Configuration) -> some View {
        Button { c.isOn.toggle() } label: {
            HStack(spacing: 10) {
                c.label
                if fill { Spacer(minLength: 8) }
                Capsule().fill(c.isOn ? Color.brand : Color.primary.opacity(0.15)).frame(width: 34, height: 20)
                    .overlay(alignment: c.isOn ? .trailing : .leading) {
                        Circle().fill(.white).shadow(color: .black.opacity(0.2), radius: 1, y: 0.5).padding(2)
                    }
                    .animation(.spring(duration: 0.2, bounce: 0), value: c.isOn)
            }.contentShape(.rect)
        }
        .buttonStyle(.plain).accessibilityAddTraits(.isToggle).accessibilityValue(c.isOn ? "On" : "Off")
    }
}

struct CheckToggle: ToggleStyle {
    func makeBody(configuration c: Configuration) -> some View {
        Button { c.isOn.toggle() } label: {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 5).fill(c.isOn ? Color.brand : Color.primary.opacity(0.1)).frame(width: 18, height: 18)
                    .overlay { if c.isOn { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Color.onBrand) } }
                c.label
            }.contentShape(.rect)
        }
        .buttonStyle(.plain).accessibilityAddTraits(.isToggle).accessibilityValue(c.isOn ? "On" : "Off")
    }
}

struct ChipToggle: ToggleStyle {
    func makeBody(configuration c: Configuration) -> some View {
        Button { c.isOn.toggle() } label: {
            c.label.font(.callout.weight(.medium)).foregroundStyle(c.isOn ? Color.onBrand : .primary)
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(c.isOn ? Color.brand : Color.primary.opacity(0.07), in: .capsule).contentShape(.capsule)
        }
        .buttonStyle(.plain).accessibilityAddTraits(.isToggle).accessibilityValue(c.isOn ? "On" : "Off")
    }
}

struct Opt<T: Hashable>: Hashable {
    var title: String, value: T, color: Color?
    init(_ title: String, _ value: T, _ color: Color? = nil) { self.title = title; self.value = value; self.color = color }
}

struct Segments<T: Hashable>: View {
    @Binding var selection: T
    var options: [Opt<T>]
    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { o in
                let on = o.value == selection
                Button { selection = o.value } label: {
                    Text(o.title).font(.callout.weight(on ? .semibold : .medium)).lineLimit(1).minimumScaleFactor(0.8)
                        .foregroundStyle(on ? Color.onBrand : .secondary)
                        .frame(maxWidth: .infinity).padding(.horizontal, 8).padding(.vertical, 5)
                        .background(on ? Color.brand : .clear, in: .capsule).contentShape(.capsule)
                }
                .buttonStyle(.plain).accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(3).background(Color.primary.opacity(0.06), in: .capsule)
    }
}

struct Dropdown<T: Hashable>: View {
    var label: String
    @Binding var selection: T
    var options: [Opt<T>]
    init(_ label: String, selection: Binding<T>, options: [Opt<T>]) { self.label = label; _selection = selection; self.options = options }
    var body: some View {
        let current = options.first { $0.value == selection }
        LabeledContent(label) {
            Menu {
                ForEach(options, id: \.self) { o in
                    Button { selection = o.value } label: {
                        if o.value == selection { Label(o.title, systemImage: "checkmark") } else { Text(o.title) }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    if let c = current?.color { Circle().fill(c).frame(width: 8, height: 8) }
                    Text(current?.title ?? "Choose…").font(.callout.weight(.medium)).lineLimit(1)
                    Spacer(minLength: 2)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(Color.primary.opacity(0.07), in: .capsule).contentShape(.capsule)
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).accessibilityLabel(label)
        }
    }
}

struct Step<V: Numeric & Comparable>: View {
    var label: String
    @Binding var value: V
    var range: ClosedRange<V>
    var step: V
    @Environment(\.fillRow) private var fill
    init(_ label: String, value: Binding<V>, in range: ClosedRange<V>, step: V = 1) { self.label = label; _value = value; self.range = range; self.step = step }
    var body: some View {
        HStack(spacing: 10) {
            Text(label).monospacedDigit().lineLimit(1).fixedSize()
            if fill { Spacer(minLength: 8) }
            HStack(spacing: 0) {
                button("minus", "Decrease \(label)", value > range.lowerBound) { value = max(range.lowerBound, value - step) }
                Color.primary.opacity(0.12).frame(width: 1, height: 12)
                button("plus", "Increase \(label)", value < range.upperBound) { value = min(range.upperBound, value + step) }
            }
            .background(Color.primary.opacity(0.07), in: .capsule)
        }
    }
    private func button(_ icon: String, _ a11y: String, _ on: Bool, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Image(systemName: icon).font(.system(size: 9, weight: .bold)).frame(width: 26, height: 22).contentShape(.rect)
        }
        .buttonStyle(.plain).disabled(!on).opacity(on ? 1 : 0.35).accessibilityLabel(a11y)
    }
}

struct Bar: View {
    @Binding var value: Double
    var body: some View {
        GeometryReader { g in
            let knob: CGFloat = 12
            let x = (g.size.width - knob) * CGFloat(min(1, max(0, value)))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1)).frame(height: 6)
                Capsule().fill(Color.brand).frame(width: x + knob / 2, height: 6)
                Circle().fill(.white).shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5).frame(width: knob, height: knob).offset(x: x)
            }
            .frame(maxHeight: .infinity).contentShape(.rect)
            .gesture(DragGesture(minimumDistance: 0).onChanged { value = min(1, max(0, Double(($0.location.x - knob / 2) / (g.size.width - knob)))) })
        }
        .frame(height: 18)
        .accessibilityElement().accessibilityValue("\(Int(value * 100)) percent")
        .accessibilityAdjustableAction { value = min(1, max(0, value + ($0 == .increment ? 0.1 : -0.1))) }
    }
}

struct SidebarRow<Icon: View>: View {
    var title: String
    var selected: Bool
    var action: () -> Void
    @ViewBuilder var icon: Icon
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                icon
                Text(title).font(.system(size: 13, weight: selected ? .semibold : .regular)).lineLimit(1)
                    .foregroundStyle(selected ? Color.brand.ink : .primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
            .background(selected ? Color.brand.wash : hover ? Color.primary.opacity(0.05) : .clear, in: .rect(cornerRadius: 8))
            .contentShape(.rect)
        }
        .buttonStyle(.plain).onHover { hover = $0 }.accessibilityAddTraits(selected ? .isSelected : [])
    }
}
