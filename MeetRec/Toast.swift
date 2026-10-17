import AppKit
import Combine
import SwiftUI

/// A short MeetRec message for live moments: recording started, a call noticed ("Записать?"),
/// recording saved. Problems (silent microphone, disk full) go to macOS notifications instead,
/// because those stay in Notification Center.
struct Toast: Equatable, Identifiable {
    enum Kind: Equatable { case started, stopped, info, screenshot }
    enum Action: Equatable { case switchMicrophone(uid: String) }

    let id = UUID()
    let kind: Kind
    let title: String
    var detail: String?
    /// The recording file, for "Показать" after a stop.
    var file: URL?
    /// A button next to the message ("Переключить").
    var action: Action?
    /// Screenshot: shown instead of the icon; dragged out it drops `file` into a chat or a browser.
    var preview: NSImage?

    /// How long it stays when not hovered; a suggestion waits a bit longer.
    var duration: TimeInterval { action != nil ? 12 : kind == .screenshot ? 5 : (kind == .started ? 4.5 : 7) }
}

/// Shows the current toast or call question in a small floating window under the menu bar item.
/// It never takes keyboard focus (typing in the meeting app keeps working) and its transparent
/// margins let clicks through.
@MainActor
final class ToastController {
    private final class ToastPanel: NSPanel {
        // Buttons work, but the panel becomes key only if a text field needs it (it has none).
        override var canBecomeKey: Bool { true }
    }

    static let width: CGFloat = 360
    static let height: CGFloat = 170
    private static let margin: CGFloat = 16

    private let panel: ToastPanel
    private let model: RecorderModel
    private let anchor: () -> NSRect?
    private var hideWork: DispatchWorkItem?
    private var hovering = false
    /// The question folded away after a while (it stays in the panel); per call.
    private var foldedPrompt: String?
    static let promptVisibleFor: TimeInterval = 25
    private var cancellables: Set<AnyCancellable> = []

    /// A screenshot preview is being dragged out: the toast stays until the drop.
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

        let view = ToastView(onHover: { [weak self] inside in self?.hover(inside) },
                             onDrag: { [weak self] state in self?.drag(state) })
            .environmentObject(model)
        let hosting = NSHostingView(rootView: view)
        hosting.sizingOptions = []
        panel.contentView = hosting

        Publishers.CombineLatest(model.$toast.map { $0?.id }.removeDuplicates(), model.$callPrompt.map { $0?.id }.removeDuplicates())
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in self?.update() }
            .store(in: &cancellables)
        // The panel shows everything itself; no toast on top of it.
        model.$panelVisible
            .receive(on: RunLoop.main)
            .sink { [weak self] visible in
                if visible { self?.model.dismissToast() }
                // A pending question moves into the panel and comes back when it folds away.
                DispatchQueue.main.async { self?.update() }
            }
            .store(in: &cancellables)
    }

    func setSharingType(_ type: NSWindow.SharingType) {
        if panel.sharingType != type { panel.sharingType = type }
    }

    private func update() {
        if model.callPrompt == nil { foldedPrompt = nil }
        // Not in the discreet style, and only for a while: an unanswered question folds into the panel.
        let prompt = model.callPrompt != nil && !model.isRecording && MenuBarStyle.current != .discreet
            && foldedPrompt != model.callPrompt?.id
        guard (prompt || model.toast != nil) && !model.panelVisible else {
            // Let SwiftUI play the slide-out, then take the window away.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                guard let self else { return }
                let pending = (self.model.toast != nil || self.model.callPrompt != nil) && !self.model.panelVisible
                if !pending { self.panel.orderOut(nil) }
            }
            return
        }
        position()
        panel.orderFrontRegardless()
        hideWork?.cancel()
        // Messages fold away on their own; a question after `promptVisibleFor`, staying in the panel.
        if prompt, let id = model.callPrompt?.id {
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.hovering, self.model.callPrompt?.id == id else { return }
                Log.info("Call question folded into the panel (no answer in \(Int(Self.promptVisibleFor)) s)", "meetings")
                self.foldedPrompt = id
                self.update()
            }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.promptVisibleFor, execute: work)
        } else if let toast = model.toast {
            scheduleHide(after: toast.duration)
        }
    }

    private func scheduleHide(after delay: TimeInterval) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.hovering else { return }
            self.model.dismissToast()
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Dropped somewhere: done, like Shottr's thumbnail; cancelled: the toast folds away as usual.
    private func drag(_ state: ToastView.DragState) {
        switch state {
        case .began:
            dragging = true
            hideWork?.cancel()
        case .ended(let dropped):
            dragging = false
            if dropped {
                Log.info("Screenshot preview dropped into another app", "screenshots")
                model.dismissToast()
            } else {
                hover(false)
            }
        }
    }

    private func hover(_ inside: Bool) {
        hovering = inside || dragging
        if hovering {
            hideWork?.cancel()
        } else if model.toast != nil, model.callPrompt == nil {
            scheduleHide(after: 2)
        }
    }

    /// Under the menu bar item, like the panel; top right when the item is hidden.
    private func position() {
        let item = anchor()
        let screen = item.flatMap { frame in NSScreen.screens.first { $0.frame.intersects(frame) } }
            ?? NSScreen.screens.first ?? NSScreen.main
        guard let screen else { return }
        let visible = screen.visibleFrame
        let top = (item?.minY ?? visible.maxY) - 4 + Self.margin
        var x = item.map { $0.midX - Self.width / 2 } ?? (visible.maxX - Self.width + Self.margin - 6)
        x = min(max(x, visible.minX - Self.margin + 6), visible.maxX - Self.width + Self.margin - 6)
        panel.setFrame(NSRect(x: x, y: top - Self.height, width: Self.width, height: Self.height), display: true)
    }
}

struct ToastView: View {
    enum DragState { case began, ended(dropped: Bool) }

    let onHover: (Bool) -> Void
    let onDrag: (DragState) -> Void
    @EnvironmentObject private var model: RecorderModel

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if let app = model.callPrompt, !model.isRecording {
                    prompt(app).id("prompt-\(app.id)")
                } else if let toast = model.toast {
                    message(toast).id(toast.id)
                }
            }
            .padding(12)
            .frame(width: ToastController.width - 32)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
            .onHover(perform: onHover)
            .transition(.move(edge: .top).combined(with: .opacity))
            Spacer(minLength: 0)
        }
        .padding(.top, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: model.toast?.id)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: model.callPrompt?.id)
    }

    private func message(_ toast: Toast) -> some View {
        HStack(spacing: 10) {
            if let preview = toast.preview, let file = toast.file {
                screenshotPreview(preview, file: file)
            } else {
                Image(systemName: icon(toast.kind))
                    .font(.system(size: 22))
                    .foregroundStyle(toast.kind == .started ? Color.red : toast.kind == .info ? Color.accentColor : Color.green)
            }
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
            } else if toast.kind == .screenshot, let file = toast.file, toast.preview != nil {
                VStack(spacing: 4) {
                    Button {
                        model.dismissToast()
                        ScreenshotEditor.open(file)
                    } label: {
                        Text("Редактировать").frame(maxWidth: .infinity)
                    }
                    Button {
                        model.dismissToast()
                        Screenshotter.shared.recognizeText(file)
                    } label: {
                        Text("OCR").frame(maxWidth: .infinity)
                    }
                    .help("Распознать текст на снимке и скопировать его")
                }
                .controlSize(.small)
                .fixedSize()
            } else if toast.kind == .stopped, let file = toast.file {
                Button("Показать в Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([file])
                    model.dismissToast()
                }
                .controlSize(.small)
            }
        }
        .contentShape(Rectangle())
        // A click just puts it away (the panel is one click on the menu bar icon).
        .onTapGesture { model.dismissToast() }
    }

    /// Drag it into a chat or a browser's upload field; a click edits it.
    private func screenshotPreview(_ image: NSImage, file: URL) -> some View {
        Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: 72, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.2), lineWidth: 0.5))
            .overlay(FileDragSource(file: file, image: image,
                                    onClick: {
                                        model.dismissToast()
                                        ScreenshotEditor.open(file)
                                    },
                                    onBegin: { onDrag(.began) },
                                    onEnd: { onDrag(.ended(dropped: $0)) }))
            .help("Перетащите в чат или в поле загрузки; клик — редактировать")
    }

    private func icon(_ kind: Toast.Kind) -> String {
        switch kind {
        case .started: return "record.circle.fill"
        case .info: return "mic.fill"
        case .stopped: return "checkmark.circle.fill"
        case .screenshot: return "camera.viewfinder"
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
private struct FileDragSource: NSViewRepresentable {
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
