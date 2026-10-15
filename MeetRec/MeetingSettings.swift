import SwiftUI

/// "Автозапись встреч": on/off and the calling apps found on this Mac.
struct MeetingSettings: View {
    @EnvironmentObject private var model: RecorderModel
    @State private var installed: [MeetingApp] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Определять встречи и записывать сами", isOn: $model.meetingDetection)
                .onChange(of: model.meetingDetection) { model.configureDetector() }
            Text("Teams: запись начнётся сама, когда он возьмёт микрофон дольше \(Int(MeetingDetector.startAfter)) с. Браузер и Telegram держат микрофон не только для звонков, поэтому MeetRec спросит, записывать ли. Запись встречи останавливается через \(Int(MeetingDetector.endAfter)) с после того, как приложение отпустит микрофон; начатые вручную — нет.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Приложения на этом Mac").font(.caption.weight(.semibold)).padding(.top, 2)
            if installed.isEmpty {
                Text("Не найдено поддерживаемых приложений для звонков").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(installed) { app in
                HStack(spacing: 8) {
                    if let icon = icon(for: app) {
                        Image(nsImage: icon).resizable().frame(width: 18, height: 18)
                    }
                    Toggle(app.name, isOn: Binding(
                        get: { app.supported && model.selectedMeetingApps.contains(app.id) },
                        set: { model.setMeetingApp(app, enabled: $0) }
                    ))
                    .disabled(!app.supported || !model.meetingDetection)
                    if app.supported && app.asks {
                        Spacer()
                        Text("спросит").font(.caption2).foregroundStyle(.tertiary)
                    } else if let note = app.note {
                        Spacer()
                        Text(note).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                    }
                }
            }
            if installed.contains(where: { $0.id == "browser" }) {
                BrowserRulesEditor()
                    .disabled(!model.meetingDetection || !model.selectedMeetingApps.contains("browser"))
            }
            if let status = model.detectorStatus {
                Label(status, systemImage: "waveform")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 4)
        .onAppear { installed = MeetingApp.all.filter(\.isInstalled) }
    }

    private func icon(for app: MeetingApp) -> NSImage? {
        guard let url = app.bundlePrefixes.lazy.compactMap({ NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }).first else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

/// Browser calls normally ask first; tabs listed here are recorded right away (e.g. "Vimbox" → Skyeng).
struct BrowserRulesEditor: View {
    @EnvironmentObject private var model: RecorderModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Записывать сразу, без вопроса, если в заголовке вкладки есть").font(.caption.weight(.semibold))
                .padding(.top, 4)
            ForEach(model.browserRules) { rule in
                HStack(spacing: 6) {
                    TextField("Текст вкладки", text: binding(rule, \.keyword))
                        .textFieldStyle(.roundedBorder)
                    Image(systemName: "arrow.right").foregroundStyle(.secondary).font(.caption)
                    TextField("Название записи", text: binding(rule, \.title))
                        .textFieldStyle(.roundedBorder)
                    Button {
                        model.browserRules.removeAll { $0.id == rule.id }
                    } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Убрать правило")
                }
            }
            Button {
                model.browserRules.append(BrowserRule(keyword: "", title: ""))
            } label: {
                Label("Добавить сайт", systemImage: "plus.circle.fill")
            }
            .buttonStyle(.borderless)
            Text("MeetRec видит заголовок активной вкладки каждого окна браузера. Название записи попадёт в имя файла после даты.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func binding(_ rule: BrowserRule, _ field: WritableKeyPath<BrowserRule, String>) -> Binding<String> {
        Binding(get: { rule[keyPath: field] }, set: { value in
            var rules = model.browserRules
            guard let index = rules.firstIndex(where: { $0.id == rule.id }) else { return }
            rules[index][keyPath: field] = value
            model.browserRules = rules
        })
    }
}
