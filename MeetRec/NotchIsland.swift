import AppKit
import Combine
import SwiftUI

/// A Dynamic-Island-style indicator around the MacBook notch while recording: a red dot left of the
/// notch and the timer right of it; hovering expands it downwards with level meters and buttons.
///
/// macOS has no Live Activities for Mac apps (Tahoe only mirrors the iPhone's), so this is an own
/// borderless window drawn black to merge with the notch, on the main screen (the one with the menu
/// bar). A screen without a notch gets no island: a floating capsule would cover browser tabs and
/// catch the eye on a screen share. The window is resized (not just redrawn) between compact and expanded, so its
/// transparent parts never block clicks on the menu bar or windows below.
@MainActor
final class IslandController {
    static let enabledKey = "notchIsland"

    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    private let panel: NSPanel
    private let model: RecorderModel
    private let state = IslandState()
    private var collapseWork: DispatchWorkItem?
    private var screenObserver: NSObjectProtocol?

    init(model: RecorderModel) {
        self.model = model
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        let view = IslandView(state: state,
                              onHover: { [weak self] inside in self?.hover(inside) },
                              onOpenPanel: { NotificationCenter.default.post(name: RecorderModel.showPanelNotification, object: nil) })
            .environmentObject(model)
            .environmentObject(model.live)
        let hosting = NSHostingView(rootView: view)
        hosting.sizingOptions = []
        panel.contentView = hosting

        // Monitor plugged in or out, main display changed: move to the right place.
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.update() // shows or hides it when a notched screen becomes or stops being the main one
                guard self.panel.isVisible else { return }
                self.applyGeometry()
                self.panel.setFrame(self.frame(expanded: self.state.expanded), display: true)
            }
        }
    }

    private func applyGeometry() {
        let notch = geometry().notch
        state.notchWidth = notch?.width ?? 0
        state.notchHeight = notch?.height ?? 0
    }

    /// Shows or hides the island for the current recording state and settings.
    func update() {
        let show = model.isCapturing && Self.enabled && MenuBarStyle.current != .discreet && geometry().notch != nil
        let sharing: NSWindow.SharingType = MenuBarStyle.hideFromSharing ? .none : .readOnly
        if panel.sharingType != sharing { panel.sharingType = sharing }
        if show {
            guard !panel.isVisible else { return }
            state.expanded = false
            applyGeometry()
            panel.setFrame(frame(expanded: false), display: true)
            panel.orderFrontRegardless()
            Log.debug("Island shown at \(NSStringFromRect(panel.frame))")
        } else if panel.isVisible {
            panel.orderOut(nil)
            state.expanded = false
        }
    }

    // MARK: - Hover

    private func hover(_ inside: Bool) {
        collapseWork?.cancel()
        if inside {
            setExpanded(true)
        } else {
            let work = DispatchWorkItem { [weak self] in self?.setExpanded(false) }
            collapseWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
        }
    }

    private func setExpanded(_ expanded: Bool) {
        guard panel.isVisible, state.expanded != expanded else { return }
        let target = frame(expanded: expanded)
        if expanded {
            // Grow the window first, then let SwiftUI unfold the content into it.
            panel.setFrame(target, display: true)
            withAnimation(.spring(response: 0.38, dampingFraction: 0.8)) { state.expanded = true }
        } else {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { state.expanded = false }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) { [weak self] in
                guard let self, !self.state.expanded else { return }
                self.panel.setFrame(target, display: true)
            }
        }
    }

    // MARK: - Geometry

    /// The main screen (menu bar; `screens[0]`) and its notch, if it has one.
    private func geometry() -> (screen: NSScreen, notch: NSRect?) {
        guard let screen = NSScreen.screens.first ?? NSScreen.main else { return (NSScreen.main!, nil) }
        if screen.safeAreaInsets.top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            let notch = NSRect(x: left.maxX, y: screen.frame.maxY - screen.safeAreaInsets.top,
                               width: right.minX - left.maxX, height: screen.safeAreaInsets.top)
            return (screen, notch)
        }
        return (screen, nil)
    }

    private func frame(expanded: Bool) -> NSRect {
        let (screen, notch) = geometry()
        let size = IslandView.size(notchWidth: notch?.width ?? 0, notchHeight: notch?.height ?? 0, expanded: expanded)
        if let notch {
            return NSRect(x: notch.midX - size.width / 2, y: screen.frame.maxY - size.height,
                          width: size.width, height: size.height)
        }
        // No notch: just under the menu bar, centred.
        let top = screen.visibleFrame.maxY - 6
        return NSRect(x: screen.frame.midX - size.width / 2, y: top - size.height, width: size.width, height: size.height)
    }
}

final class IslandState: ObservableObject {
    @Published var expanded = false
    @Published var notchWidth: CGFloat = 0
    @Published var notchHeight: CGFloat = 0
}

struct IslandView: View {
    @ObservedObject var state: IslandState
    let onHover: (Bool) -> Void
    let onOpenPanel: () -> Void

    @EnvironmentObject private var model: RecorderModel
    @EnvironmentObject private var live: LiveRecording

    static let ear: CGFloat = 54
    static let compactHeightWithoutNotch: CGFloat = 26
    static let expandedExtra: CGFloat = 84
    static let expandedEar: CGFloat = 118

    static func size(notchWidth: CGFloat, notchHeight: CGFloat, expanded: Bool) -> CGSize {
        let rowHeight = notchHeight > 0 ? notchHeight : compactHeightWithoutNotch
        let width = notchWidth + 2 * (expanded ? expandedEar : ear)
        return CGSize(width: width, height: rowHeight + (expanded ? expandedExtra : 0))
    }

    private var hasNotch: Bool { state.notchWidth > 0 }

    var body: some View {
        VStack(spacing: 0) {
            compactRow
            if state.expanded {
                expandedContent
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(background)
        .contentShape(Rectangle())
        .onHover(perform: onHover)
        .onTapGesture(perform: onOpenPanel)
        .environment(\.colorScheme, .dark)
    }

    /// With a notch: flat top merging into it. Floating: a capsule (compact) or rounded card, with a
    /// faint edge so it stands out on a dark menu bar.
    private var background: some View {
        let top: CGFloat = hasNotch ? 0 : (state.expanded ? 22 : Self.compactHeightWithoutNotch / 2)
        let bottom: CGFloat = state.expanded ? 22 : (hasNotch ? 13 : Self.compactHeightWithoutNotch / 2)
        let shape = UnevenRoundedRectangle(topLeadingRadius: top, bottomLeadingRadius: bottom,
                                           bottomTrailingRadius: bottom, topTrailingRadius: top, style: .continuous)
        return shape.fill(Color.black)
            .overlay(shape.strokeBorder(Color.white.opacity(hasNotch ? 0 : 0.14), lineWidth: 0.5))
    }

    /// Red dot | notch | timer.
    private var compactRow: some View {
        HStack(spacing: 0) {
            HStack {
                if model.isPaused {
                    Image(systemName: "pause.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.orange)
                } else {
                    Circle()
                        .fill(model.showsWarning ? Color.yellow : Color.red)
                        .frame(width: 9, height: 9)
                        .shadow(color: .red.opacity(0.8), radius: 4)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 14)
            .frame(maxWidth: .infinity)
            if hasNotch {
                Color.clear.frame(width: state.notchWidth)
            }
            HStack {
                Spacer(minLength: 0)
                Text(live.elapsedText)
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(model.isPaused ? Color.orange : Color.white)
                    .contentTransition(.numericText())
            }
            .padding(.trailing, 12)
            .frame(maxWidth: .infinity)
        }
        .frame(height: rowHeight)
    }

    private var rowHeight: CGFloat {
        hasNotch ? state.notchHeight : Self.compactHeightWithoutNotch
    }

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let health = live.health {
                meter("mic.fill", health.microphone)
                meter("speaker.wave.2.fill", health.systemAudio)
            }
            HStack(spacing: 8) {
                if !model.isPaused {
                Button {
                    model.addMarker()
                } label: {
                    Label(model.markers.isEmpty ? String(localized: "Отметить") : String(localized: "Отметить · \(model.markers.count)"), systemImage: "star.fill")
                        .frame(maxWidth: .infinity)
                }
                }
                Button {
                    model.togglePause()
                } label: {
                    Label(model.isPaused ? "Снять с паузы" : "Пауза", systemImage: model.isPaused ? "play.fill" : "pause.fill")
                        .frame(maxWidth: .infinity)
                }
                .tint(.orange)
                .help(model.isPaused ? "Снять с паузы" : "Пауза")
                Button {
                    model.stop()
                } label: {
                    Label("Стоп", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .tint(.red)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(model.isBusy)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    private func meter(_ icon: String, _ signal: SignalHealth) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundStyle(signal.state == .noSignal ? .red : .secondary)
                .frame(width: 14)
            if let level = signal.levelDB {
                LevelMeter(levelDB: level)
            } else {
                Text(signal.detail).font(.caption2).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
    }
}
