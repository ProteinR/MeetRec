import SwiftUI

/// The big start/stop button. Switching morphs it: the colour deepens, the record icon turns into a
/// stop square, the title slides, and a ring ripples out on start. While recording it glows (a steady
/// glow, not a pulse: an endless animation would redraw the panel every frame during the recording).
struct RecordButton: View {
    let isRecording: Bool
    let isBusy: Bool
    let action: () -> Void

    @State private var hovering = false
    @State private var pressed = false
    @State private var ripple = false

    private var title: String {
        isRecording ? (isBusy ? String(localized: "Сохраняю запись…") : String(localized: "Остановить запись")) : String(localized: "Начать запись")
    }

    private static let startColor = Color(red: 0.96, green: 0.26, blue: 0.27)
    private static let stopColor = Color(red: 0.62, green: 0.08, blue: 0.10)

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    if isBusy {
                        // A fixed size: on its own the spinner took the panel window's whole height
                        // for a frame (a red column down the screen at every stop).
                        ProgressView().controlSize(.small).tint(.white)
                            .frame(width: 16, height: 16)
                            .transition(.scale.combined(with: .opacity))
                    } else {
                        Image(systemName: isRecording ? "stop.fill" : "record.circle")
                            .contentTransition(.symbolEffect(.replace.downUp))
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .frame(width: 20)
                ZStack(alignment: .leading) {
                    Text(title)
                        .id(title)
                        .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                                                removal: .move(edge: .top).combined(with: .opacity)))
                }
                .clipped()
                Spacer()
                if let hint = RecorderModel.hotKeyHint {
                    Text(hint).foregroundStyle(.white.opacity(0.7))
                }
            }
            .font(.body.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity)
            .background {
                Capsule()
                    .fill(isRecording ? Self.stopColor : Self.startColor)
                    .brightness(hovering && !isBusy ? 0.06 : 0)
            }
            .overlay {
                // Ripple on start.
                Capsule()
                    .stroke(Self.startColor, lineWidth: 3)
                    .scaleEffect(x: ripple ? 1.06 : 1, y: ripple ? 1.5 : 1)
                    .opacity(ripple ? 0 : (isRecording ? 0.9 : 0))
                    .allowsHitTesting(false)
            }
            .shadow(color: (isRecording ? Self.stopColor : Self.startColor).opacity(isRecording ? 0.6 : 0.25),
                    radius: isRecording ? 10 : 5)
            .scaleEffect(pressed ? 0.97 : 1)
            .contentShape(Capsule())
        }
        .buttonStyle(PressReportingStyle(pressed: $pressed))
        .disabled(isBusy)
        .onHover { hovering = $0 }
        .animation(.spring(response: 0.45, dampingFraction: 0.78), value: isRecording)
        .animation(.easeInOut(duration: 0.2), value: isBusy)
        .animation(.easeOut(duration: 0.15), value: hovering)
        .animation(.spring(response: 0.25, dampingFraction: 0.6), value: pressed)
        .onChange(of: isRecording) { _, recording in
            guard recording else { return }
            ripple = false
            withAnimation(.easeOut(duration: 0.8)) { ripple = true }
        }
    }
}

/// Plain look, but tells the button when it is held down, for the press-in effect.
private struct PressReportingStyle: ButtonStyle {
    @Binding var pressed: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, isPressed in pressed = isPressed }
    }
}
