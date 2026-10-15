import AppKit
import Quartz

/// Shows files in the system Quick Look panel, the same preview as Space in Finder. Markdown
/// transcripts are rendered by the dotViewer Quick Look extension; the panel's own button opens the
/// file in the default editor.
@MainActor
final class QuickLookPresenter: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLookPresenter()

    private var items: [URL] = []

    func preview(_ url: URL) {
        guard let panel = QLPreviewPanel.shared() else {
            Log.warning("Quick Look panel unavailable, opening \(url.lastPathComponent) in the default app", "ui")
            NSWorkspace.shared.open(url)
            return
        }
        items = [url]
        Log.info("Quick Look preview: \(url.path)", "ui")
        // MeetRec is a menu bar app: activate it so the preview comes to the front.
        NSApp.activate(ignoringOtherApps: true)
        panel.dataSource = self
        panel.delegate = self
        panel.currentPreviewItemIndex = 0
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    // MARK: - QLPreviewPanelDataSource

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { items.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        MainActor.assumeIsolated { items[index] as NSURL }
    }
}
