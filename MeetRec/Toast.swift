import AppKit
import Combine
import SwiftUI

/// A short MeetRec message for live moments: recording started, a call noticed ("Записать?"),
/// recording saved. Problems (silent microphone, disk full) go to macOS notifications instead,
/// because those stay in Notification Center.
struct Toast: Equatable, Identifiable {
    enum Kind: Equatable { case started, stopped, info, screenshot, summary, problem }
    enum Action: Equatable { case switchMicrophone(uid: String) }

    let id = UUID()
    let kind: Kind
    let title: String
    var detail: String?
    /// The recording file, for "Показать" after a stop.
    var file: URL?
    /// A button next to the message ("Переключить").
    var action: Action?
    /// Screenshot: the toast becomes the shot itself (`ScreenshotToastCard`); dragged out it drops
    /// `file` into a chat or a browser.
    var preview: NSImage?
    /// Screenshot: already in the clipboard ("Скопировано" instead of "Копировать").
    var copied = false
    /// Screenshot: `file` is the saved one in the folder, not a temporary copy (offers Finder).
    var saved = false

    /// How long it stays when not hovered; a suggestion waits a bit longer.
    var duration: TimeInterval { action != nil ? 12 : kind == .screenshot ? 6 : (kind == .started ? 4.5 : 7) }
}

/// How much of a toast's time is left, for the thin line along its bottom: runs down while the
/// toast is up, stops while the pointer is on it, and runs out over the last 2 s after it leaves.
/// One linear animation per run, not a timer: nothing is redrawn by MeetRec meanwhile.
@MainActor
final class ToastCountdown: ObservableObject {
    @Published private(set) var fraction: CGFloat = 1
    private var started: Date?
    private var duration: TimeInterval = 1
    private var from: CGFloat = 1

    /// A new toast: full again.
    func reset() {
        started = nil
        from = 1
        set(1)
    }

    /// From where it is now down to nothing in `seconds`.
    func run(_ seconds: TimeInterval) {
        set(from)
        started = Date()
        duration = max(seconds, 0.1)
        DispatchQueue.main.async {
            withAnimation(.linear(duration: seconds)) { self.fraction = 0 }
        }
    }

    /// Stops where it is (the pointer is on the toast).
    func pause() {
        guard let started else { return }
        let left = from * CGFloat(max(0, 1 - Date().timeIntervalSince(started) / duration))
        self.started = nil
        from = left
        set(left)
    }

    private func set(_ value: CGFloat) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { fraction = value }
    }
}

/// One countdown per card on screen (the message and each screenshot card), so each folds away
/// on its own time.
@MainActor
final class ToastTimers {
    private var countdowns: [UUID: ToastCountdown] = [:]

    func countdown(_ id: UUID) -> ToastCountdown {
        if let existing = countdowns[id] { return existing }
        let new = ToastCountdown()
        countdowns[id] = new
        return new
    }

    func remove(_ id: UUID) { countdowns[id] = nil }
}

/// Shows the current toast or call question, and the screenshot cards in a column under it, in a
/// small floating window under the menu bar item. It never takes keyboard focus (typing in the
/// meeting app keeps working) and its transparent margins let clicks through.
@MainActor
final class ToastController {
    private final class ToastPanel: NSPanel {
        // Buttons work, but the panel becomes key only if a text field needs it (it has none).
        override var canBecomeKey: Bool { true }
    }

    /// The card is 328 wide at most; the rest is a transparent margin wide enough for its shadow (radius 10,
    /// reaching about 20 plus the offset), so it fades out instead of being cut off.
    static let margin: CGFloat = 30
    static let width: CGFloat = 328 + 2 * margin
    /// Room for a message and `RecorderModel.maxShotToasts` screenshot cards (up to 184 pt each).
    static let height: CGFloat = 720

    private let panel: ToastPanel
    private let model: RecorderModel
    private let anchor: () -> NSRect?
    /// The question folding into the panel.
    private var promptWork: DispatchWorkItem?
    /// Each card's own fold-away.
    private var hideWorks: [UUID: DispatchWorkItem] = [:]
    /// The cards on screen now, to tell the new ones from those already counting down.
    private var shown: Set<UUID> = []
    private var hovering = false
    /// The question folded away after a while (it stays in the panel); per call.
    private var foldedPrompt: String?
    static let promptVisibleFor: TimeInterval = 25
    private var cancellables: Set<AnyCancellable> = []
    private let timers = ToastTimers()

    /// A screenshot preview is being dragged out: the cards stay until the drop.
    private var dragging = false

    init(model: RecorderModel, anchor: @escaping () -> NSRect?) {
        self.model = model
        self.anchor = anchor
        panel = ToastPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.height),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        let view = ToastView(timers: timers,
                             onHover: { [weak self] inside in self?.hover(inside) },
                             onDrag: { [weak self] id, state in self?.drag(id, state) })
            .environmentObject(model)
        let hosting = NSHostingView(rootView: view)
        hosting.sizingOptions = []
        panel.contentView = hosting

        Publishers.CombineLatest3(model.$toast.map { $0?.id }.removeDuplicates(),
                                  model.$callPrompt.map { $0?.id }.removeDuplicates(),
                                  model.$shotToasts.map { $0.map(\.id) }.removeDuplicates())
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _ in self?.update() }
            .store(in: &cancellables)
        // The panel shows everything itself; no toast on top of it.
        model.$panelVisible
            .receive(on: RunLoop.main)
            .sink { [weak self] visible in
                if visible { self?.model.dismissAllToasts() }
                // A pending question moves into the panel and comes back when it folds away.
                DispatchQueue.main.async { self?.update() }
            }
            .store(in: &cancellables)
    }

    func setSharingType(_ type: NSWindow.SharingType) {
        if panel.sharingType != type { panel.sharingType = type }
    }

    /// The question is shown instead of a message (it waits for an answer).
    private var promptShown: Bool { model.callPrompt != nil && !model.isRecording }

    /// The cards that count down: the message (unless the question is up) and the screenshots.
    private var cardIDs: [UUID] {
        var ids = model.shotToasts.map(\.id)
        if let toast = model.toast, !promptShown { ids.insert(toast.id, at: 0) }
        return ids
    }

    private func duration(_ id: UUID) -> TimeInterval {
        if let toast = model.toast, toast.id == id { return toast.duration }
        return model.shotToasts.first { $0.id == id }?.duration ?? 6
    }

    private func update() {
        if model.callPrompt == nil { foldedPrompt = nil }
        // Not in the discreet style, and only for a while: an unanswered question folds into the panel.
        let prompt = promptShown && MenuBarStyle.current != .discreet && foldedPrompt != model.callPrompt?.id
        let ids = cardIDs
        for id in shown.subtracting(ids) {
            hideWorks.removeValue(forKey: id)?.cancel()
            timers.remove(id)
        }
        guard (prompt || !ids.isEmpty) && !model.panelVisible else {
            shown = []
            // Let SwiftUI play the slide-out, then take the window away.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                guard let self else { return }
                let pending = (self.model.toast != nil || self.model.callPrompt != nil || !self.model.shotToasts.isEmpty)
                    && !self.model.panelVisible
                if !pending { self.panel.orderOut(nil) }
            }
            return
        }
        // Not moved while cards are up: a new shot taken on another screen would carry the others away.
        if shown.isEmpty || !panel.isVisible { position() }
        panel.orderFrontRegardless()
        // Messages fold away on their own; a question after `promptVisibleFor`, staying in the panel.
        promptWork?.cancel()
        if prompt, let id = model.callPrompt?.id {
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.hovering, self.model.callPrompt?.id == id else { return }
                Log.info("Call question folded into the panel (no answer in \(Int(Self.promptVisibleFor)) s)", "meetings")
                self.foldedPrompt = id
                self.update()
            }
            promptWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.promptVisibleFor, execute: work)
        }
        for id in ids where !shown.contains(id) {
            timers.countdown(id).reset()
            if !hovering { scheduleHide(id, after: duration(id)) }
        }
        shown = Set(ids)
    }

    private func scheduleHide(_ id: UUID, after delay: TimeInterval) {
        hideWorks[id]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.hovering else { return }
            self.dismiss(id)
        }
        hideWorks[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        timers.countdown(id).run(delay)
    }

    private func dismiss(_ id: UUID) {
        if model.toast?.id == id { model.dismissToast() } else { model.dismissShot(id) }
    }

    /// Dropped somewhere: that card is done, like Shottr's thumbnail; cancelled: they fold away as usual.
    private func drag(_ id: UUID, _ state: ToastView.DragState) {
        switch state {
        case .began:
            dragging = true
            hover(true)
        case .ended(let dropped):
            dragging = false
            if dropped {
                Log.info("Screenshot preview dropped into another app", "screenshots")
                model.dismissShot(id)
            }
            hover(false)
        }
    }

    private func hover(_ inside: Bool) {
        hovering = inside || dragging
        if hovering {
            for work in hideWorks.values { work.cancel() }
            hideWorks = [:]
            for id in shown { timers.countdown(id).pause() }
        } else {
            // The message first, then the oldest shot, the newest last.
            var delay: TimeInterval = 2
            for id in [model.toast?.id].compactMap({ $0 }) + model.shotToasts.reversed().map(\.id) where shown.contains(id) {
                scheduleHide(id, after: delay)
                delay += 0.6
            }
        }
    }

    /// Where the menu bar item sits, counted from the right edge of its screen. Remembered, because
    /// the item cannot be read while a full-screen window covers it (the screenshot selector).
    private var itemOffset: CGFloat?

    /// Under the menu bar item on the screen with the cursor (the one the user works on, where a
    /// screenshot was just taken): every menu bar shows the items at the same distance from the right
    /// edge. Top right when the item was never seen.
    private func position() {
        if let item = anchor(), let itemScreen = NSScreen.screens.first(where: { $0.frame.intersects(item) }) {
            itemOffset = itemScreen.frame.maxX - item.midX
        }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let visible = screen.visibleFrame
        let top = visible.maxY - 4 + Self.margin
        let height = min(Self.height, visible.height + Self.margin)
        var x = itemOffset.map { screen.frame.maxX - $0 - Self.width / 2 } ?? (visible.maxX - Self.width + Self.margin - 6)
        x = min(max(x, visible.minX - Self.margin + 6), visible.maxX - Self.width + Self.margin - 6)
        panel.setFrame(NSRect(x: x, y: top - height, width: Self.width, height: height), display: true)
    }
}

struct ToastView: View {
    enum DragState { case began, ended(dropped: Bool) }

    let timers: ToastTimers
    let onHover: (Bool) -> Void
    let onDrag: (UUID, DragState) -> Void
    @EnvironmentObject private var model: RecorderModel

    private static let spring = Animation.spring(response: 0.4, dampingFraction: 0.85)

    var body: some View {
        VStack(spacing: 10) {
            if let app = model.callPrompt, !model.isRecording {
                prompt(app)
                    .padding(12)
                    .frame(width: ToastController.width - 2 * ToastController.margin)
                    .modifier(ToastChrome(countdown: nil, close: nil))
                    .onHover(perform: onHover)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .id("prompt-\(app.id)")
            } else if let toast = model.toast {
                message(toast)
                    .padding(12)
                    .frame(width: ToastController.width - 2 * ToastController.margin)
                    .modifier(ToastChrome(countdown: timers.countdown(toast.id), close: { model.dismissToast() }))
                    .onHover(perform: onHover)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .id(toast.id)
            }
            // Newest on top; older ones move down.
            ForEach(model.shotToasts) { shot in
                if let preview = shot.preview, let file = shot.file {
                    ScreenshotToastCard(toast: shot, image: preview, file: file, onDrag: { onDrag(shot.id, $0) })
                        .padding(7)
                        .modifier(ToastChrome(countdown: timers.countdown(shot.id), close: { model.dismissShot(shot.id) }))
                        .onHover(perform: onHover)
                        .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity),
                                                removal: .scale(scale: 0.9).combined(with: .opacity)))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.top, ToastController.margin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(Self.spring, value: model.toast?.id)
        .animation(Self.spring, value: model.callPrompt?.id)
        .animation(Self.spring, value: model.shotToasts.map(\.id))
    }

    private func message(_ toast: Toast) -> some View {
        messageRow(toast)
            .contentShape(Rectangle())
            // A click just puts it away (the panel is one click on the menu bar icon).
            .onTapGesture { model.dismissToast() }
    }

    private func messageRow(_ toast: Toast) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon(toast.kind))
                .font(.system(size: 22))
                .foregroundStyle(iconColor(toast.kind))
            VStack(alignment: .leading, spacing: 2) {
                Text(toast.title).font(.callout.weight(.semibold))
                if let detail = toast.detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 4)
            if let action = toast.action {
                Button("Переключить") { model.performToastAction(action) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            } else if toast.kind == .summary, let file = toast.file {
                Button("Открыть") {
                    NSWorkspace.shared.open(file)
                    model.dismissToast()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            } else if toast.kind == .stopped, let file = toast.file {
                Button("Показать в Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([file])
                    model.dismissToast()
                }
                .controlSize(.small)
            }
        }
    }

    private func icon(_ kind: Toast.Kind) -> String {
        switch kind {
        case .started: return "record.circle.fill"
        case .info: return "mic.fill"
        case .stopped: return "checkmark.circle.fill"
        case .screenshot: return "camera.viewfinder"
        case .summary: return "sparkles"
        case .problem: return "exclamationmark.triangle.fill"
        }
    }

    private func iconColor(_ kind: Toast.Kind) -> Color {
        switch kind {
        case .started: .red
        case .info: .accentColor
        case .summary: .purple
        case .problem: .orange
        default: .green
        }
    }

    private func prompt(_ app: MeetingApp) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: app.icon)
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.accentColor))
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.promptTitle(reminder: model.promptIsReminder))
                        .font(.callout.weight(.semibold))
                    Text(app.promptDetail)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 8) {
                Button {
                    model.acceptCallPrompt()
                } label: {
                    Label("Записать", systemImage: "record.circle").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                Button {
                    model.dismissCallPrompt()
                } label: {
                    Text("Не сейчас").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
    }
}

/// An AppKit drag source over the toast's preview: drags the file itself (browsers' upload fields and
/// messengers take files), works in the non-activating toast window and reports where the drag ended.
struct FileDragSource: NSViewRepresentable {
    let file: URL
    let image: NSImage
    let onClick: () -> Void
    let onBegin: () -> Void
    let onEnd: (Bool) -> Void

    func makeNSView(context: Context) -> SourceView { SourceView() }

    func updateNSView(_ view: SourceView, context: Context) {
        view.file = file
        view.image = image
        view.onClick = onClick
        view.onBegin = onBegin
        view.onEnd = onEnd
    }

    final class SourceView: NSView, NSDraggingSource {
        var file: URL?
        var image: NSImage?
        var onClick: (() -> Void)?
        var onBegin: (() -> Void)?
        var onEnd: ((Bool) -> Void)?
        private var mouseDown: NSEvent?

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

        override func mouseDown(with event: NSEvent) { mouseDown = event }

        override func mouseUp(with event: NSEvent) {
            if mouseDown != nil { onClick?() }
            mouseDown = nil
        }

        override func mouseDragged(with event: NSEvent) {
            guard let down = mouseDown, let file else { return }
            let start = down.locationInWindow, now = event.locationInWindow
            guard hypot(now.x - start.x, now.y - start.y) >= 3 else { return }
            mouseDown = nil
            let item = NSDraggingItem(pasteboardWriter: file as NSURL)
            item.setDraggingFrame(bounds, contents: image)
            beginDraggingSession(with: [item], event: down, source: self)
            onBegin?()
        }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            .copy
        }

        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            onEnd?(operation != [])
        }
    }
}

/// A toast card's look: material, hairline, shadow; for messages also the ✕ at the top left and
/// the line along the bottom with the time left.
private struct ToastChrome: ViewModifier {
    let countdown: ToastCountdown?
    let close: (() -> Void)?

    func body(content: Content) -> some View {
        content
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5))
            .overlay(alignment: .bottom) {
                if let countdown { CountdownLine(countdown: countdown) }
            }
            .overlay(alignment: .topLeading) {
                if let close { CloseButton(action: close) }
            }
            .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
    }
}

/// The time left before a card folds away.
private struct CountdownLine: View {
    @ObservedObject var countdown: ToastCountdown

    var body: some View {
        Capsule()
            .fill(Color.primary.opacity(0.35))
            .frame(height: 2)
            .scaleEffect(x: countdown.fraction, anchor: .leading)
            .padding(.horizontal, 14)
            .padding(.bottom, 2.5)
            .allowsHitTesting(false)
    }
}

/// Like a notification's: puts the card away at once.
private struct CloseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .background(Circle().fill(.regularMaterial))
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.18), lineWidth: 0.5))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .offset(x: -6, y: -6)
        .help("Закрыть")
        .accessibilityLabel("Закрыть")
    }
}
