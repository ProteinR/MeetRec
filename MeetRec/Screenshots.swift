import AppKit
import Carbon
import ImageIO
import ScreenCaptureKit
import SwiftUI
import UniformTypeIdentifiers
import Vision

/// Screenshots like Shottr: ⇧⌘4 freezes the screens and puts a crosshair over them (`AreaSelector`);
/// the picked area (or a clicked window) is copied to the clipboard and saved as PNG (or JPEG in
/// "Авто" for photo-like pictures), each switchable in settings. ⇧⌘2 does the same selection but
/// copies the text in it (OCR). Both shortcuts can be changed. The toast shows a preview to drag into a
/// chat or a browser; the panel lists the last ones; "Редактировать" opens `ScreenshotEditor`.
@MainActor
final class Screenshotter: ObservableObject {
    static let shared = Screenshotter()

    /// "auto": JPEG when it is much smaller (photos, gradients), else PNG; "png": always PNG.
    @AppStorage("screenshotFormat") var format = "auto"
    @AppStorage("screenshotCopy") var copyToClipboard = true
    @AppStorage("screenshotSave") var saveToFolder = true
    @AppStorage("screenshotToast") var showToast = true
    /// Empty: `defaultFolder`, where Shottr kept them, so the history stays in one place.
    @AppStorage("screenshotFolder") var folderPath = ""
    static let defaultFolder = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("screenshots", isDirectory: true)

    /// Bumped when a screenshot is saved, edited or deleted; the panel list reloads on it.
    @Published private(set) var version = 0

    private var selector: AreaSelector?
    /// The screens are being captured before the crosshair shows.
    private var freezing = false

    var folderURL: URL {
        folderPath.isEmpty ? Self.defaultFolder : URL(fileURLWithPath: folderPath, isDirectory: true)
    }

    func start() {
        ScreenshotFiles.clearDragCopies()
    }

    // MARK: - Folder

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Выбрать"
        panel.directoryURL = folderURL
        NSApp.activate()
        if panel.runModal() == .OK, let url = panel.url {
            folderPath = url.path
            version += 1
            Log.info("Screenshot folder changed to \(url.path)", "screenshots")
        }
    }

    func resetFolder() {
        folderPath = ""
        version += 1
    }

    func openFolder() {
        try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folderURL)
    }

    // MARK: - Capture

    func captureArea() { capture(.screenshot) }
    func captureText() { capture(.text) }

    /// Freezes all screens first (menus and tooltips of the app in front stay in the picture), then
    /// the crosshair over them; a drag takes an area, a click a window or the whole screen, Esc cancels.
    func capture(_ action: ShortcutAction) {
        guard action == .screenshot || action == .text, selector == nil, !freezing else { return }
        freezing = true
        let previous = NSWorkspace.shared.frontmostApplication
        Task { @MainActor in
            let screens: [FrozenScreen]
            do {
                screens = try await FrozenScreen.captureAll()
            } catch {
                freezing = false
                Log.error("Screen capture failed: \(Log.describe(error))", "screenshots")
                RecorderModel.shared.showToast(Toast(kind: .screenshot, title: "Не удалось снять экран",
                                                     detail: error.localizedDescription))
                return
            }
            freezing = false
            guard !screens.isEmpty else { return }
            let selector = AreaSelector(screens: screens, purpose: action == .text ? .text : .screenshot) { [weak self] selection in
                guard let self else { return }
                self.selector = nil
                defer { Self.reactivate(previous) }
                guard let selection else {
                    Log.info("Selection cancelled (\(action.rawValue))", "screenshots")
                    return
                }
                Log.info("Selected \(selection.kind) \(selection.image.width)×\(selection.image.height) px (\(action.rawValue))", "screenshots")
                if action == .text {
                    let image = selection.image
                    Task {
                        let text = await ScreenshotFiles.recognizeText(in: image)
                        Self.copyRecognized(text, from: "screen")
                    }
                } else {
                    self.deliver(selection.image, scale: selection.scale)
                }
            }
            self.selector = selector
            selector.begin()
        }
    }

    /// The selector takes focus (for Esc and the cursor); give it back to the app the user was in.
    private static func reactivate(_ app: NSRunningApplication?) {
        guard let app, app != NSRunningApplication.current else { return }
        app.activate()
    }

    /// Clipboard and/or folder as set; with both off it is still copied, so the shot is never lost.
    private func deliver(_ image: CGImage, scale: CGFloat) {
        let copy = copyToClipboard || !saveToFolder
        var saved: URL?
        if saveToFolder {
            do {
                saved = try ScreenshotFiles.save(image, scale: scale, in: folderURL, auto: format == "auto")
                version += 1
            } catch {
                Log.error("Screenshot not saved to \(folderURL.path): \(Log.describe(error))", "screenshots")
            }
        }
        if copy || saved == nil { ScreenshotFiles.copy(image, scale: scale) }
        ScreenshotFiles.releaseFreedMemory()
        Log.info("Screenshot \(image.width)×\(image.height) px (\(Int(scale))×)"
                 + (copy || saved == nil ? ", copied" : "") + (saved.map { ", saved: \($0.lastPathComponent)" } ?? ""), "screenshots")
        guard showToast else { return }
        // Says it is in the clipboard already, so there is no urge to copy it again.
        let title = copy && saved != nil ? "Скопирован и сохранён" : copy || saved == nil ? "Скриншот скопирован" : "Скриншот сохранён"
        let detail = saved != nil ? "Папка «\(folderURL.lastPathComponent)»"
            : (saveToFolder ? "В папку сохранить не удалось" : nil)
        // Something to drag out of the toast even when nothing was saved.
        let dragFile = saved ?? ScreenshotFiles.dragCopy(image, scale: scale)
        // A small copy: the toast shows 72×48 points, no need to keep the full picture for it.
        let preview = ScreenshotFiles.downscaled(image, maxPixels: 400).map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
        RecorderModel.shared.showToast(Toast(kind: .screenshot, title: title, detail: detail, file: dragFile, preview: preview))
    }

    // MARK: - Actions on saved screenshots

    func copy(_ url: URL) {
        guard let loaded = ScreenshotFiles.load(url) else { return }
        ScreenshotFiles.copy(loaded.image, scale: loaded.scale)
        Log.info("Screenshot copied: \(url.lastPathComponent)", "screenshots")
    }

    /// Whole image to text, into the clipboard, with a toast.
    func recognizeText(_ url: URL) {
        guard let loaded = ScreenshotFiles.load(url) else { return }
        Task {
            let text = await ScreenshotFiles.recognizeText(in: loaded.image)
            Self.copyRecognized(text, from: url.lastPathComponent)
        }
    }

    /// Puts recognised text into the clipboard and says so; returns the toast-like line for the editor.
    @discardableResult
    static func copyRecognized(_ text: String, from name: String) -> String {
        let lines = text.split(separator: "\n").count
        guard !text.isEmpty else {
            Log.info("OCR found no text in \(name)", "screenshots")
            RecorderModel.shared.showToast(Toast(kind: .screenshot, title: "Текст не найден"))
            return "Текст не найден"
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        Log.info("OCR: \(lines) lines, \(text.count) characters copied from \(name)", "screenshots")
        let title = "Текст скопирован · \(lines) \(Self.lineWord(lines))"
        RecorderModel.shared.showToast(Toast(kind: .screenshot, title: title,
                                             detail: String(text.prefix(80)).replacingOccurrences(of: "\n", with: " ")))
        return title
    }

    static func lineWord(_ count: Int) -> String {
        let mod10 = count % 10, mod100 = count % 100
        if mod10 == 1 && mod100 != 11 { return "строка" }
        if (2...4).contains(mod10) && !(12...14).contains(mod100) { return "строки" }
        return "строк"
    }

    func trash(_ url: URL) {
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            Log.info("Screenshot moved to Trash: \(url.lastPathComponent)", "screenshots")
        } catch {
            Log.error("Screenshot not moved to Trash: \(Log.describe(error))", "screenshots")
        }
        version += 1
    }

    /// After the editor wrote the file.
    func edited(_ url: URL) {
        version += 1
    }
}

