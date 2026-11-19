import AppKit
import SwiftUI

/// What a hover tip says: a bold first line, then plain and secondary lines.
struct HoverTipContent: Equatable {
    var title: String
    var lines: [String] = []
    /// Greyed, e.g. "клик — открыть".
    var hint: String?
    /// A picture above the text (a recording's frames, one at a time), `Thumbnails.previewSize`.
    var preview: NSImage?
    /// Which part of the recording the preview comes from, 0…1: a thin line under it.
    var progress: Double?
    /// Lines of a transcript in place of the picture, as big as it; what does not fit is cut off.
    var transcript: TranscriptPreview?
    /// Marked in the transcript's lines (the search text).
    var highlight: String?
}

/// The panel's own tooltip: appears at once (the system one waits about a second) and follows the
/// pointer. A borderless, click-through window above the panel, so it is not cut off by the card's
/// edges. Hidden when the pointer leaves and when the panel closes; a click or a context menu
/// closes it until the pointer leaves that view (the preview's next frame must not bring it back over
/// the menu).
@MainActor
final class HoverTip {
    static let shared = HoverTip()

    private let panel: NSPanel
    private let hosting: NSHostingView<HoverTipView>
    private var owner: String?
    private var clickMonitor: Any?
    /// The view whose tip a click or a menu closed: not shown again until the pointer leaves it.
    private var dismissed: String?
    /// From the pointer to the tip's top-left corner, like the system tooltip.
    private let offset = CGSize(width: 14, height: 18)

    private init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        // Above the panel and the toasts (both `.statusBar`).
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]
        hosting = NSHostingView(rootView: HoverTipView(content: HoverTipContent(title: "")))
        panel.contentView = hosting
        // A context menu (right click, or ⌃-click) opens: the tip would cover it.
        NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { HoverTip.shared.dismiss() }
        }
    }

    /// Shows `content` for `id` (or updates it) next to the pointer.
    func show(_ content: HoverTipContent, for id: String) {
        guard id != dismissed else { return }
        dismissed = nil
        owner = id
        hosting.rootView = HoverTipView(content: content)
        let size = hosting.fittingSize
        panel.setContentSize(size)
        let hidden = UserDefaults.standard.object(forKey: MenuBarStyle.hideFromSharingKey) as? Bool ?? true
        let sharing: NSWindow.SharingType = hidden ? .none : .readOnly
        if panel.sharingType != sharing { panel.sharingType = sharing }
        move()
        if !panel.isVisible { panel.orderFrontRegardless() }
        startClickMonitor()
    }

    /// Follows the pointer; flips to the other side near a screen's right or bottom edge.
    func move() {
        guard owner != nil else { return }
        let mouse = NSEvent.mouseLocation
        let size = panel.frame.size
        var origin = NSPoint(x: mouse.x + offset.width, y: mouse.y - offset.height - size.height)
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) {
            let visible = screen.visibleFrame
            if origin.x + size.width > visible.maxX { origin.x = mouse.x - offset.width / 2 - size.width }
            if origin.y < visible.minY { origin.y = mouse.y + offset.height / 2 }
        }
        panel.setFrameOrigin(origin)
    }

    /// The pointer left `id`'s view: hides its tip if it still shows it (another tile may have taken
    /// it over meanwhile), and it may show again next time. nil hides the tip whoever shows it.
    func hide(for id: String? = nil) {
        if id == nil || id == dismissed { dismissed = nil }
        guard id == nil || id == owner else { return }
        owner = nil
        panel.orderOut(nil)
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
    }

    /// Closed by a click or a menu: stays hidden while the pointer is still on the same view.
    func dismiss() {
        guard let owner else { return }
        hide()
        dismissed = owner
    }

    private func startClickMonitor() {
        guard clickMonitor == nil else { return }
        // A click opens a video or the editor, a right click a menu: the tip would cover either.
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { event in
            MainActor.assumeIsolated { HoverTip.shared.dismiss() }
            return event
        }
    }
}

struct HoverTipView: View {
    let content: HoverTipContent

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let preview = content.preview {
                Color.black
                    .frame(width: Thumbnails.previewSize.width, height: Thumbnails.previewSize.height)
                    .overlay { Image(nsImage: preview).resizable().scaledToFill() }
                    .overlay(alignment: .bottomLeading) {
                        if let progress = content.progress {
                            Rectangle().fill(Color.accentColor)
                                .frame(width: Thumbnails.previewSize.width * progress, height: 3)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .padding(.bottom, 4)
            }
            if let transcript = content.transcript {
                TranscriptTipText(preview: transcript, highlight: content.highlight)
                    .padding(.bottom, 4)
            }
            Text(content.title).font(.callout.weight(.semibold)).lineLimit(2)
            ForEach(Array(content.lines.enumerated()), id: \.offset) { _, line in
                Text(line).font(.caption).monospacedDigit()
            }
            if let hint = content.hint {
                Text(hint).font(.caption2).foregroundStyle(.secondary).padding(.top, 1)
            }
        }
        .frame(maxWidth: content.preview == nil && content.transcript == nil ? 280 : Thumbnails.previewSize.width, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
    }
}

extension View {
    /// The panel's own tooltip for this view (see `HoverTip`); `id` must be unique on screen.
    func hoverTip(_ content: HoverTipContent, id: String) -> some View {
        modifier(HoverTipModifier(content: content, id: id))
    }
}

private struct HoverTipModifier: ViewModifier {
    let content: HoverTipContent
    let id: String
    @State private var inside = false

    func body(content view: Content) -> some View {
        view
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    if inside {
                        HoverTip.shared.move()
                    } else {
                        inside = true
                        HoverTip.shared.show(content, for: id)
                    }
                case .ended:
                    inside = false
                    HoverTip.shared.hide(for: id)
                }
            }
            // E.g. the transcription percent while the tip is shown.
            .onChange(of: content) { if inside { HoverTip.shared.show(content, for: id) } }
            .onDisappear {
                if inside { HoverTip.shared.hide(for: id) }
                inside = false
            }
    }
}

/// A transcript's first lines in the tip, as big as the video preview: grey time, bold speaker,
/// text; the lines that do not fit fade out at the bottom.
private struct TranscriptTipText: View {
    let preview: TranscriptPreview
    let highlight: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(preview.lines.enumerated()), id: \.offset) { _, line in
                text(line).font(.caption).fixedSize(horizontal: false, vertical: true)
            }
            if preview.lines.isEmpty {
                Text("Транскрипт пуст").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(width: Thumbnails.previewSize.width - 16, height: Thumbnails.previewSize.height - 16, alignment: .topLeading)
        .clipped()
        .mask(LinearGradient(stops: [.init(color: .black, location: 0.8), .init(color: .clear, location: 1)],
                             startPoint: .top, endPoint: .bottom))
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.05)))
    }

    private func text(_ line: TranscriptPreview.Line) -> Text {
        var result = Text("")
        if let time = line.time { result = result + Text(time + " ").foregroundColor(.secondary).monospacedDigit() }
        if let speaker = line.speaker { result = result + Text(speaker + ": ").bold() }
        return result + Text(marked(line.text))
    }

    private func marked(_ text: String) -> AttributedString {
        var string = AttributedString(text)
        guard let highlight, !highlight.isEmpty,
              let range = string.range(of: highlight, options: [.caseInsensitive, .diacriticInsensitive]) else { return string }
        string[range].backgroundColor = .yellow.opacity(0.45)
        return string
    }
}
