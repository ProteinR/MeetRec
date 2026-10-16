import AppKit
import Carbon
import SwiftUI

/// "Скриншоты" under "Записи": a button for an area shot, the folder, and the last five as thumbnails.
/// A click opens the editor; right click: edit, copy, recognise text, show in Finder, Trash. A
/// thumbnail can be dragged into a chat.
struct ScreenshotsSection: View {
    @Binding var isExpanded: Bool
    /// Closes the panel before a capture or an editor window.
    let close: () -> Void
    @EnvironmentObject private var model: RecorderModel
    @ObservedObject private var shots = Screenshotter.shared
    @State private var items: [ScreenshotFiles.Item] = []
    @State private var total = 0

    var body: some View {
        CollapsibleSection(title: "Скриншоты", icon: "camera.viewfinder", summary: summary, isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    captureButton(.screenshot, icon: "plus.viewfinder", title: "Снимок")
                    captureButton(.text, icon: "text.viewfinder", title: "Текст")
                    Spacer(minLength: 4)
                    Button { shots.openFolder() } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.borderless)
                    .help("Открыть папку «\(shots.folderURL.lastPathComponent)» в Finder")
                }
                if items.isEmpty {
                    Text(shots.saveToFolder ? "Пока нет скриншотов в «\(shots.folderURL.lastPathComponent)»"
                                            : "Сохранение в папку выключено: снимки только копируются")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: ScreenshotFiles.panelLimit),
                              spacing: 6) {
                        ForEach(items) { item in
                            ScreenshotThumbnail(item: item, close: close)
                        }
                    }
                }
            }
        }
        .onAppear(perform: reload)
        .onChange(of: model.panelVisible) { if model.panelVisible { reload() } }
        .onChange(of: isExpanded) { if isExpanded { reload() } }
        .onChange(of: shots.version) { reload() }
        .onChange(of: model.folderPath) { reload() }
    }

    private func captureButton(_ action: ScreenAction, icon: String, title: String) -> some View {
        Button {
            close()
            // Let the panel go before the screens are frozen.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { Screenshotter.shared.capture(action) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                Text(title)
                if shots.isEnabled(action) { Text(shots.combo(action).text).foregroundStyle(.secondary) }
            }
        }
        .help(action == .text ? "Выделить область — её текст скопируется (OCR)" : "Выделить область или кликнуть по окну")
    }

    private var summary: String {
        guard let last = items.first else { return "\(shots.hotKeyHint) — снимок области" }
        return "\(total) · последний \(Self.when(last.date))"
    }

    /// "14:03", "вчера 18:20", "14 окт".
    static func when(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        if calendar.isDateInYesterday(date) { return "вчера " + date.formatted(date: .omitted, time: .shortened) }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }

    private func reload() {
        let list = ScreenshotFiles.list(in: shots.folderURL)
        items = list.items
        total = list.total
    }
}

private struct ScreenshotThumbnail: View {
    let item: ScreenshotFiles.Item
    let close: () -> Void
    @ObservedObject private var shots = Screenshotter.shared
    @State private var image: NSImage?
    @State private var hovering = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.06))
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            }
        }
        .frame(height: 54)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5)
            .strokeBorder(hovering ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: hovering ? 2 : 0.5))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { edit() }
        .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
        .help("\(ScreenshotsSection.when(item.date)) · клик — редактировать, правый клик — ещё")
        .contextMenu {
            Button("Редактировать") { edit() }
            Button("Копировать") { Screenshotter.shared.copy(item.url) }
            Button("Распознать текст") {
                close()
                Screenshotter.shared.recognizeText(item.url)
            }
            Button("Показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
            Divider()
            Button("В корзину") { Screenshotter.shared.trash(item.url) }
        }
        // Reloaded after an edit too (the file keeps its name).
        .task(id: "\(item.id)#\(shots.version)") {
            // Decoding a 5K PNG takes a moment; not on the main thread while the panel opens.
            let url = item.url
            image = await Task.detached(priority: .userInitiated) { ScreenshotFiles.thumbnail(url) }.value
        }
    }

    private func edit() {
        close()
        ScreenshotEditor.open(item.url)
    }
}

/// Settings page card: hotkey, clipboard, folder, toast.
struct ScreenshotSettings: View {
    @ObservedObject private var shots = Screenshotter.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(ScreenAction.allCases) { action in
                hotKeyRow(action)
            }
            Toggle("Копировать в буфер обмена", isOn: $shots.copyToClipboard)
            Toggle("Сохранять в папку", isOn: $shots.saveToFolder)
            if shots.saveToFolder {
                HStack(spacing: 8) {
                    Text(shots.folderURL.path)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    if !shots.folderPath.isEmpty {
                        Button("По умолчанию") { shots.resetFolder() }
                            .controlSize(.small)
                            .help("«Скриншоты» в папке для записей")
                    }
                    Button("Изменить") { shots.chooseFolder() }
                        .controlSize(.small)
                }
                .padding(.leading, 20)
            }
            if !shots.copyToClipboard && !shots.saveToFolder {
                Text("Оба выключены: снимок всё равно скопируется, чтобы не пропасть.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Text("Формат")
                Picker("Формат", selection: $shots.format) {
                    Text("PNG").tag("png")
                    Text("Авто (PNG/JPEG)").tag("auto")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Image(systemName: "questionmark.circle")
                    .foregroundStyle(.secondary)
                    .help("Авто выбирает по содержимому: фото, градиенты и шум сохраняются в JPEG (он тогда намного меньше), текст и плоские цвета — в PNG, чтобы оставались чёткими. В буфер обмена всегда идёт PNG.")
            }
            Toggle("Сообщение с превью после снимка", isOn: $shots.showToast)
                .help("Под значком в меню: превью можно перетащить в чат или в поле браузера, клик по нему — редактировать")
        }
    }

    @ViewBuilder
    private func hotKeyRow(_ action: ScreenAction) -> some View {
        HStack(spacing: 8) {
            Toggle(action.title, isOn: Binding(get: { shots.isEnabled(action) }, set: { shots.setEnabled(action, $0) }))
            Spacer(minLength: 4)
            HotKeyRecorder(action: action)
            if shots.combo(action) != action.defaultCombo {
                Button {
                    shots.endHotKeyRecording(action, action.defaultCombo)
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(.borderless)
                .help("Вернуть \(action.defaultCombo.text)")
            }
        }
        if shots.hotKeysTaken.contains(action) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                Text("\(shots.combo(action).text) занят другим приложением (например, Shottr) или самой macOS. Освободи сочетание там или задай другое и нажми «Повторить».")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button("Повторить") { shots.registerHotKey(action) }
                    .controlSize(.small)
            }
        }
    }

    static var summary: String {
        let shots = Screenshotter.shared
        var parts = ScreenAction.allCases.filter(shots.isEnabled).map { shots.combo($0).text }
        if parts.isEmpty { parts.append("без сочетаний") }
        if shots.copyToClipboard { parts.append("копировать") }
        if shots.saveToFolder { parts.append("сохранять") }
        return parts.joined(separator: " · ")
    }
}

/// Click, then press the new shortcut; Esc cancels. The current one is off while waiting, so pressing
/// it again keeps it.
private struct HotKeyRecorder: View {
    let action: ScreenAction
    @ObservedObject private var shots = Screenshotter.shared
    @EnvironmentObject private var model: RecorderModel
    @State private var monitor: Any?
    @State private var hint: String?

    var body: some View {
        Button {
            recording ? stop(nil) : start()
        } label: {
            Text(recording ? (hint ?? "Нажми сочетание…") : shots.combo(action).text)
                .font(.system(.callout, design: .rounded).weight(.medium))
                .frame(minWidth: 90)
        }
        .help(recording ? "Нажми новое сочетание с ⌘, ⌥ или ⌃; Esc — отмена" : "Нажми, чтобы задать другое сочетание")
        .onChange(of: model.panelVisible) { if !model.panelVisible { stop(nil) } }
        .onDisappear { stop(nil) }
    }

    private var recording: Bool { shots.recordingHotKey == action }

    private func start() {
        if let other = shots.recordingHotKey { shots.endHotKeyRecording(other, nil) }
        shots.beginHotKeyRecording(action)
        hint = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) {
                stop(nil)
                return nil
            }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard KeyCombo.isUsable(flags) else {
                hint = "Нужен ⌘, ⌥ или ⌃"
                NSSound.beep()
                return nil
            }
            let keyCode = Int(event.keyCode)
            let combo = KeyCombo(keyCode: keyCode, modifiers: KeyCombo.carbonModifiers(flags),
                                 label: KeyCombo.label(keyCode: keyCode, characters: event.charactersIgnoringModifiers))
            if let other = shots.conflict(combo, for: action) {
                hint = "Уже у «\(other.title)»"
                NSSound.beep()
                return nil
            }
            stop(combo)
            return nil
        }
    }

    private func stop(_ combo: KeyCombo?) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        hint = nil
        if recording { shots.endHotKeyRecording(action, combo) }
    }
}
