import AppKit

/// Right click on the menu bar item: the frequent actions without opening the panel.
extension AppDelegate {
    /// Right click on the menu bar item: the frequent actions without opening the panel.
    @MainActor
    func showQuickMenu() {
        let model = RecorderModel.shared
        if panel.isShown { panel.close() }
        let menu = NSMenu()
        let shortcuts = Shortcuts.shared
        /// An item showing its shortcut when one is set and on.
        func item(_ title: String, _ action: ShortcutAction?, handler: @escaping () -> Void) -> QuickMenuItem {
            let key = action.flatMap { shortcuts.isEnabled($0) ? shortcuts.combo($0)?.menuKey : nil }
            return QuickMenuItem(title, key: key?.key ?? "", modifiers: key?.modifiers ?? []) { handler() }
        }
        menu.addItem(item(model.isRecording ? "Остановить запись" : "Начать запись", .record) { model.toggle() })
        if model.isRecording && !model.isStopping {
            menu.addItem(item(model.isPaused ? "Снять с паузы" : "Пауза", .pause) { model.togglePause() })
            menu.addItem(item("Отметить момент", .marker) { model.addMarker() })
        }
        if let last = model.lastFile {
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: "Последняя запись"))
            menu.addItem(QuickMenuItem("Показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting([last]) })
            let transcriber = Transcriber.shared
            if transcriber.runningFile == last {
                let percent = transcriber.progress.map { " \(Int($0 * 100)) %" } ?? "…"
                let running = QuickMenuItem("Транскрибация\(percent)") {}
                running.isEnabled = false
                menu.addItem(running)
            } else if let transcript = Transcriber.existingTranscript(for: last) {
                menu.addItem(QuickMenuItem("Открыть транскрипт") { NSWorkspace.shared.open(transcript) })
            }
        }
        menu.addItem(.separator())
        for action in ShortcutAction.screenshots {
            menu.addItem(item(action.title, action) {
                // After the menu has closed, so it is not in the picture.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { Screenshotter.shared.capture(action) }
            })
        }
        menu.addItem(.separator())
        menu.addItem(QuickMenuItem(CameraMirror.shared.isShown ? "Закрыть зеркало" : "Как я выгляжу") { CameraMirror.shared.toggle() })
        menu.addItem(QuickMenuItem("Настройки…", key: ",") { [weak self] in
            self?.showPanel()
            model.requestSettings()
        })
        let quit = QuickMenuItem("Завершить MeetRec", key: "q") { NSApp.terminate(nil) }
        quit.isEnabled = !model.isRecording
        menu.addItem(quit)
        menu.autoenablesItems = false
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }
}
