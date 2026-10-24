import SwiftUI

/// An on/off switch drawn by SwiftUI itself, looking like the small system one. The system switch
/// (macOS 26 glass) cost ~100 MB of graphics memory for a moment on the panel's first appearance and
/// kept ~6 MB; two of them sit on the main page.
struct LightSwitchStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.label
            Capsule()
                .fill(configuration.isOn ? Color.accentColor : Color.primary.opacity(0.15))
                .frame(width: 30, height: 17)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle()
                        .fill(.white)
                        .shadow(color: .black.opacity(0.25), radius: 0.5, y: 0.5)
                        .padding(1.5)
                }
                .animation(.snappy(duration: 0.18), value: configuration.isOn)
                .opacity(isEnabled ? 1 : 0.5)
                .contentShape(Capsule())
                .onTapGesture { if isEnabled { configuration.isOn.toggle() } }
                .accessibilityElement()
                .accessibilityAddTraits(.isButton)
                .accessibilityValue(configuration.isOn ? "Вкл." : "Выкл.")
                .accessibilityAction { configuration.isOn.toggle() }
        }
    }
}

/// A slider drawn by SwiftUI, for the same reason: the system one (macOS 26 glass) took ~100 MB for
/// a moment the first time the screenshot settings showed it.
struct LightSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    /// True when a drag starts, false when it ends (the editor records one undo step per drag).
    var onEditingChanged: (Bool) -> Void = { _ in }

    @State private var dragging = false

    var body: some View {
        GeometryReader { geometry in
            let knob: CGFloat = 16
            let track = max(geometry.size.width - knob, 1)
            let fraction = CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.15)).frame(height: 4)
                Capsule().fill(Color.accentColor).frame(width: knob / 2 + track * fraction, height: 4)
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.3), radius: 1, y: 0.5)
                    .frame(width: knob, height: knob)
                    .offset(x: track * fraction)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                if !dragging {
                    dragging = true
                    onEditingChanged(true)
                }
                let raw = range.lowerBound + Double((drag.location.x - knob / 2) / track) * (range.upperBound - range.lowerBound)
                value = min(max((raw / step).rounded() * step, range.lowerBound), range.upperBound)
            }.onEnded { _ in
                dragging = false
                onEditingChanged(false)
            })
        }
        .frame(height: 18)
        .accessibilityElement()
        .accessibilityValue("\(Int(value))")
        .accessibilityAdjustableAction { direction in
            value = min(max(value + (direction == .increment ? step : -step), range.lowerBound), range.upperBound)
        }
    }
}
