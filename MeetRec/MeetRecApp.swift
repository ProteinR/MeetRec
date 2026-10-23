import AVFoundation
import Carbon
import Combine
import Quartz
import SwiftUI

@main
struct MeetRecApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The UI lives in a menu bar panel (see AppDelegate); SwiftUI needs at least one scene.
        Settings { EmptyView() }
    }
}

/// Owns the menu bar item and the dropdown panel. Clicking the item, or opening the app again from
/// Finder/Spotlight, shows the panel; clicking anywhere outside closes it.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var panel: MenuPanelController!
    private var island: IslandController!
    private var toasts: ToastController!
    private var cancellables: Set<AnyCancellable> = []
    private var statusIconKey = ""
    /// The title currently shows the grey countdown (an attributed title), not the timer.
    private var showingCountdown = false

    /// Started by macOS at login or by the crash watchdog: stay quiet, no panel.
    private var launchedInBackground = false

    /// Unit tests use the app as their host: then nothing starts (no watchdog, hot keys, detector).
    static let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    func applicationWillFinishLaunching(_ notification: Notification) {
        guard !Self.isRunningTests else { return }
        // The launch Apple event is only available this early.
        let event = NSAppleEventManager.shared().currentAppleEvent
        let loginItem = event?.eventID == AEEventID(kAEOpenApplication)
            && event?.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
        let watchdog = CommandLine.arguments.contains("--background")
        // Login items started by launchd do not always carry the Apple event; right after boot or
        // login nobody opened MeetRec by hand either.
        let justBooted = ProcessInfo.processInfo.systemUptime < 180
        launchedInBackground = loginItem || watchdog || justBooted
        Log.info("Launch: \(loginItem ? "login item" : watchdog ? "watchdog relaunch" : justBooted ? "right after boot" : "opened by user")")
    }

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !Self.isRunningTests else { return }
        let model = RecorderModel.shared
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePanel)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem.button?.imagePosition = .imageLeading

        panel = MenuPanelController(rootView: ContentView(close: { [weak self] in self?.panel.close() },
                                                          closeAnimated: { [weak self] in self?.panel.closeAnimated() })
            .environmentObject(model)
            .environmentObject(model.live)
            .environmentObject(Transcriber.shared))
        panel.onVisibilityChange = { visible in model.panelVisible = visible }
        island = IslandController(model: model)
        Shortcuts.shared.start()
        Screenshotter.shared.start()
        toasts = ToastController(model: model) { [weak self] in
            guard let window = self?.statusItem.button?.window, Self.isOnScreen(window) else { return nil }
            return window.frame
        }
        // Recording on/off, and Stop pressed: the island goes at once, not after the file is finished.
        Publishers.CombineLatest(model.$isRecording, model.$isBusy)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in DispatchQueue.main.async { self?.island.update() } }
            .store(in: &cancellables)
        model.$isPaused
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.updateStatusItem(recording: model.isCapturing, problem: model.showsWarning)
                }
            }
            .store(in: &cancellables)

        // Only when something visible changes: the second, recording on/off, problem on/off.
        Publishers.CombineLatest4(Publishers.CombineLatest(model.$isRecording, model.$isBusy).map { $0 && !$1 },
                                  model.live.$elapsed,
                                  model.live.$health.map { $0?.hasProblem == true }.removeDuplicates(),
                                  model.$meetingWindowWarning.map { $0 != nil }.removeDuplicates())
            .receive(on: RunLoop.main)
            .sink { [weak self] recording, _, problem, meetingElsewhere in
                self?.updateStatusItem(recording: recording, problem: problem || meetingElsewhere)
            }
            .store(in: &cancellables)
        updateStatusItem(recording: false, problem: false)

        // Countdown before an automatic recording: grey seconds next to the icon.
        Publishers.CombineLatest(model.$countdown.map { $0?.seconds }, model.$stopCountdown.map { $0?.seconds })
            .map { "\($0 ?? -1) \($1 ?? -1)" }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateStatusItem(recording: model.isCapturing, problem: model.showsWarning)
            }
            .store(in: &cancellables)

        // Menu bar style or "hide from screen sharing" changed in the panel.
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateStatusItem(recording: model.isCapturing, problem: model.showsWarning)
                self?.island.update()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: RecorderModel.foldPanelNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.panel.closeAnimated() }
            .store(in: &cancellables)

        // Auto-recording opens the panel so it is obvious that recording started.
        NotificationCenter.default.publisher(for: RecorderModel.showPanelNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.showPanel() }
            .store(in: &cancellables)

        // Opening the app by hand shows the panel right away, so it is never "nothing happened";
        // a launch at login or by the watchdog stays in the menu bar.
        if !launchedInBackground {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.showPanel() }
        }
        Profiling.start(delegate: self)
    }

    /// Quitting while recording (logout, shutdown, `install.sh`) first closes the file properly.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !Self.isRunningTests else { return .terminateNow }
        return MainActor.assumeIsolated {
            let model = RecorderModel.shared
            guard model.isRecording || model.isBusy else { return .terminateNow }
            Log.warning("Quit requested while recording: finishing the file first")
            model.stop(reason: "выход из MeetRec")
            Task { @MainActor in
                for _ in 0..<100 where model.isRecording || model.isBusy {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                NSApp.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !Self.isRunningTests else { return false }
        Log.info("App reopened, showing panel")
        Task { @MainActor in self.showPanel() }
        return false
    }

    @MainActor
    private func updateStatusItem(recording: Bool, problem: Bool) {
        guard let button = statusItem.button else { return }
        let style = MenuBarStyle.current
        // Discreet: a plain monochrome icon like any menu bar app; filled while recording.
        let colored = recording && style != .discreet
        // On pause: a pause sign instead of the record dot, orange, so it is obvious nothing is written.
        let paused = recording && RecorderModel.shared.isPaused
        let symbol = paused ? (colored ? "pause.circle.fill" : "pause.circle")
            : problem ? (colored ? "exclamationmark.triangle.fill" : "exclamationmark.triangle")
            : (recording ? "record.circle.fill" : "record.circle")
        let iconKey = "\(symbol) \(colored) \(problem)"
        if iconKey != statusIconKey {
            statusIconKey = iconKey
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "MeetRec")
            image?.isTemplate = !colored
            let tint: NSColor = paused ? .systemOrange : problem ? .systemYellow : .systemRed
            button.image = colored ? image?.withSymbolConfiguration(.init(paletteColors: [tint])) : image
            button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        }
        if !recording, let countdown = RecordingCountdownTitle.text(RecorderModel.shared.countdown) {
            // Small and grey: "the meeting was noticed, recording starts in N s", not yet a red alert.
            let attributed = NSAttributedString(string: countdown, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium),
                .foregroundColor: NSColor.secondaryLabelColor,
                .baselineOffset: 1,
            ])
            if button.attributedTitle != attributed { button.attributedTitle = attributed }
            showingCountdown = true
        } else if recording, let stop = RecorderModel.shared.stopCountdown {
            // The meeting ended: grey seconds until the automatic stop after the timer, "34:12 · 9".
            let timer = style == .full ? " " + RecorderModel.shared.elapsedText : ""
            let attributed = NSMutableAttributedString(string: timer, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
            ])
            attributed.append(NSAttributedString(string: " · \(stop.seconds)", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]))
            if button.attributedTitle != attributed { button.attributedTitle = attributed }
            showingCountdown = true
        } else {
            let title = recording && style == .full ? " " + RecorderModel.shared.elapsedText : ""
            if button.title != title || showingCountdown { button.title = title }
            showingCountdown = false
        }
        // Keep MeetRec out of screen sharing (apps that honour the window sharing type).
        let sharing: NSWindow.SharingType = MenuBarStyle.hideFromSharing ? .none : .readOnly
        if button.window?.sharingType != sharing { button.window?.sharingType = sharing }
        panel.setSharingType(sharing)
        toasts?.setSharingType(sharing)
    }

    @objc @MainActor
    private func togglePanel() {
        if NSApp.currentEvent?.type == .rightMouseUp || NSApp.currentEvent?.modifierFlags.contains(.control) == true {
            showQuickMenu()
            return
        }
        if panel.isShown { panel.close() } else { showPanel() }
    }

    @MainActor
    func showPanel() {
        guard !panel.isShown else { return }
        if let button = statusItem.button, let window = button.window, Self.isOnScreen(window) {
            panel.show(below: window.frame)
        } else {
            Log.debug("Status item hidden (frame \(NSStringFromRect(statusItem.button?.window?.frame ?? .zero))), showing panel top right")
            panel.show(below: nil)
        }
    }

    // MARK: - Quick Look
    // The app delegate is the end of the responder chain, so it can own the shared preview panel.

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = QuickLookPresenter.shared
            panel.delegate = QuickLookPresenter.shared
        }
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {}

    /// Menu bar managers like Ice "hide" items by pushing them past the left edge of the screen, where
    /// they still count as visible windows. Only an item that lies entirely on a screen, to the right of
    /// the app menus, is a usable anchor.
    private static func isOnScreen(_ window: NSWindow) -> Bool {
        guard window.isVisible, window.occlusionState.contains(.visible) else { return false }
        let frame = window.frame
        guard frame.width > 1, let screen = NSScreen.screens.first(where: { $0.frame.contains(frame) }) else { return false }
        return frame.minX > screen.frame.minX + screen.frame.width * 0.25
    }
}

