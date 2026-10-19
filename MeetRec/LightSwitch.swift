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
