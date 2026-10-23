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
                    captureButton(.screenshot, icon: "plus.viewfinder", title: "Скриншот")
                    captureButton(.text, icon: "text.viewfinder", title: "OCR")
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

    private func captureButton(_ action: ShortcutAction, icon: String, title: String) -> some View {
        Button {
            close()
            // Let the panel go before the screens are frozen.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { Screenshotter.shared.capture(action) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                Text(title)
                if let hint = Shortcuts.shared.hint(action) { Text(hint).foregroundStyle(.secondary) }
            }
        }
        .help(action == .text ? "Выделите область — её текст скопируется (OCR)" : "Выделите область или кликните по окну")
    }

    private var summary: String {
        guard let last = items.first else { return Shortcuts.shared.hint(.screenshot).map { "\($0) — скриншот" } ?? "Пока пусто" }
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
        // The cell sets the size and the picture fills it as an overlay: a filled image laid out on its
        // own is wider than the cell and covered the neighbour's frame.
        Color.primary.opacity(0.06)
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .overlay {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5)
                .strokeBorder(hovering ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: hovering ? 2 : 0.5))
            .zIndex(hovering ? 1 : 0)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { edit() }
        .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
        .help("\(ScreenshotsSection.when(item.date)) · клик — редактировать, правый клик — ещё")
        .contextMenu {
            Button("Редактировать") { edit() }
            Button("Копировать") { Screenshotter.shared.copy(item.url) }
            Button("OCR") {
                close()
                Screenshotter.shared.recognizeText(item.url)
            }
            Button("Показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
            ImageSearchMenuRow { provider in
                close()
                ImageSearch.search(item.url, with: provider)
            }
            Divider()
            Button("Удалить") { Screenshotter.shared.trash(item.url) }
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
    @AppStorage(ImageSearch.enabledKey) private var searchProviders = ImageSearch.enabledByDefault
    @ObservedObject private var shots = Screenshotter.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(ShortcutAction.screenshots) { action in
                ShortcutRow(action: action)
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
                            .help("~/Pictures/screenshots, как было у Shottr")
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
            HStack(spacing: 8) {
                Text("Обои вокруг окна")
                Slider(value: $shots.windowMargin, in: 0...Double(WindowShot.maxMargin), step: 1)
                    .frame(width: 120)
                TextField("", value: Binding(get: { Int(shots.windowMargin) },
                                             set: { shots.windowMargin = Double(min(max($0, 0), Int(WindowShot.maxMargin))) }),
                          format: .number)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 44)
                Text("px")
            }
            .help("Снимок окна (клик по заголовку): сколько обоев оставить вокруг него. В редакторе можно поменять для каждого снимка")
            Toggle("Сообщение с превью после снимка", isOn: $shots.showToast)
                .help("Под значком в меню: превью можно перетащить в чат или в поле браузера, клик по нему — редактировать")
            VStack(alignment: .leading, spacing: 6) {
                Text("Поиск по картинке")
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                          alignment: .leading, spacing: 6) {
                    ForEach(ImageSearch.all, id: \.id) { provider in
                        Toggle(isOn: Binding(get: { searchProviders.split(separator: ",").contains(Substring(provider.id)) },
                                             set: { ImageSearch.setEnabled(provider, $0) })) {
                            HStack(spacing: 4) {
                                Image(nsImage: provider.icon).resizable().frame(width: 14, height: 14)
                                Text(provider.name)
                                if case .pasteOnPage = provider.method {
                                    Image(systemName: "doc.on.clipboard").font(.caption).foregroundStyle(.secondary)
                                        .help("Снимок кладётся в буфер обмена и открывается сайт: вставьте его там (⌘V)")
                                }
                            }
                        }
                    }
                }
                .padding(.leading, 20)
            }
            .help("Кнопки в сообщении после снимка, в меню снимков и в редакторе; снимок уходит в сервис только по клику")
        }
    }

    static var summary: String {
        let shots = Screenshotter.shared
        var parts = ShortcutAction.screenshots.compactMap { Shortcuts.shared.hint($0) }
        if parts.isEmpty { parts.append("без сочетаний") }
        if shots.copyToClipboard { parts.append("копировать") }
        if shots.saveToFolder { parts.append("сохранять") }
        return parts.joined(separator: " · ")
    }
}
