import AppKit
import Carbon
import Combine
import SwiftUI

/// "Редактировать" on a screenshot: the picture under a small toolbar (arrow, rectangle, ellipse,
/// caption, numbered steps, blur, crop, text recognition, colours, undo, copy). Every mark stays an
/// object: click selects it, drag moves it, its handles reshape it (the arrow's middle point bends it),
/// Delete removes it. Marks are kept apart from the original pixels until saved, so undo works after a
/// save too; saving writes the result over the same file (also on closing with unsaved changes).
@MainActor
final class ScreenshotEditor: NSObject, NSWindowDelegate {
    private static var editors: [ScreenshotEditor] = []

    private let document: EditorDocument
    private let window: NSWindow
    private var cancellables: Set<AnyCancellable> = []
    private var keyMonitor: Any?

    static func open(_ url: URL) {
        if let editor = editors.first(where: { $0.document.url == url }) {
            editor.window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        guard let loaded = ScreenshotFiles.load(url) else {
            RecorderModel.shared.showToast(Toast(kind: .screenshot, title: String(localized: "Скриншот не открылся"), detail: url.lastPathComponent))
            return
        }
        let editor = ScreenshotEditor(document: EditorDocument(url: url, image: loaded.image, scale: loaded.scale,
                                                               windowShot: WindowShotCache.load(for: url)))
        editors.append(editor)
        editor.show()
    }

    private init(document: EditorDocument) {
        self.document = document
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = document.url.lastPathComponent
        window.representedURL = document.url
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 840, height: 380)
        window.delegate = self
        let hosting = NSHostingView(rootView: EditorView(document: document) { [weak self] in self?.window.performClose(nil) })
        hosting.sizingOptions = []
        window.contentView = hosting
        document.$dirty
            .receive(on: RunLoop.main)
            .sink { [weak self] dirty in self?.window.isDocumentEdited = dirty }
            .store(in: &cancellables)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            return self.handleKey(event) ? nil : event
        }
    }

    /// Letters pick tools, 1–4 colours, Delete removes the selected mark, Enter applies the crop frame,
    /// Esc drops the crop frame, deselects or closes,
    /// ⇧⌘Z redoes. Not while a caption is being typed: then the keys belong to the text field.
    private func handleKey(_ event: NSEvent) -> Bool {
        if window.firstResponder is NSTextView { return false }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let code = Int(event.keyCode)
        if flags == [.command, .shift], code == kVK_ANSI_Z {
            document.redo()
            return true
        }
        guard flags.isEmpty else { return false }
        switch code {
        case kVK_Escape:
            if document.pendingCrop != nil {
                document.pendingCrop = nil
            } else if document.selectedID != nil {
                document.selectedID = nil
            } else {
                window.performClose(nil)
            }
            return true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            guard document.pendingCrop != nil else { return false }
            document.applyPendingCrop()
            return true
        case kVK_Delete, kVK_ForwardDelete:
            document.deleteSelected()
            return true
        case kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4:
            let index = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4].firstIndex(of: code)!
            document.setColor(index)
            return true
        default:
            guard let tool = EditorTool.allCases.first(where: { $0.key.code == code }) else { return false }
            document.tool = tool
            return true
        }
    }

    /// At the screenshot's point size when it fits, else as large as the screen allows.
    private func show() {
        let image = CGSize(width: CGFloat(document.image.width) / document.scale,
                           height: CGFloat(document.image.height) / document.scale)
        let chrome = CGSize(width: 32, height: 32 + EditorView.toolbarHeight + EditorView.footerHeight)
        let visible = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        let width = min(max(image.width + chrome.width, window.minSize.width), visible.width * 0.85)
        let height = min(max(image.height + chrome.height, window.minSize.height), visible.height * 0.85)
        window.setContentSize(NSSize(width: width, height: height))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        Log.info("Screenshot editor opened: \(document.url.lastPathComponent) (\(document.image.width)×\(document.image.height) px)", "screenshots")
    }

    func windowWillClose(_ notification: Notification) {
        document.finishEditing?()
        // It holds the view's state, and the view holds the document: break the cycle, or every
        // closed editor keeps its picture in memory.
        document.finishEditing = nil
        // However the editor is left (Esc, ⌘W, the close button), the result is in the clipboard and
        // in the file. "Копировать" did it already.
        if !document.copiedOnClose { document.copyResult() }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        Self.editors.removeAll { $0 === self }
        // AppKit keeps the last key window (`NSApp`'s previous key window) after it closes, and the
        // window held the view, the document and its picture (~30 MB for a 5K shot with the window's
        // buffers). Without its content the window is only a shell. After this run loop pass the
        // document and its picture are gone.
        let window = window
        DispatchQueue.main.async {
            window.contentView = nil
            ScreenshotFiles.releaseFreedMemory()
        }
        Log.info("Screenshot editor closed: \(document.url.lastPathComponent)", "screenshots")
    }
}

