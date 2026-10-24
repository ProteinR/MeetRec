import SwiftUI

/// "Встречи и звонки": on/off and the calling apps found on this Mac.
struct MeetingSettings: View {
    @EnvironmentObject private var model: RecorderModel
    @State private var installed: [MeetingApp] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Определять встречи и звонки автоматически", isOn: $model.meetingDetection)
                .onChange(of: model.meetingDetection) { model.configureDetector() }
            Text("Встреча замечается, когда приложение берёт микрофон. «Записывать» — запись начнётся сама через несколько секунд, у значка идёт отсчёт. «Спрашивать» — появится вопрос «Записать?». Остановится запись сама, через \(Int(MeetingDetector.endAfter)) с после конца встречи.")
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
                    if app.supported {
                        Spacer()
                        Picker("Режим", selection: Binding(get: { model.asks(app) }, set: { model.setAsks(app, $0) })) {
                            Text("Записывать").tag(false)
                            Text("Спрашивать").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                        .controlSize(.small)
                        .disabled(!model.meetingDetection || !model.selectedMeetingApps.contains(app.id))
                        .help(model.asks(app) ? String(localized: "Спросит «Записать?», когда \(app.name) возьмёт микрофон")
                                              : String(localized: "Начнёт запись сама, с отсчётом у значка"))
                    } else if let note = app.note {
                        Spacer()
                        Text(note).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                    }
                }
            }
            if let browser = installed.first(where: { $0.id == "browser" }), model.asks(browser) {
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

/// Browser calls normally ask first; sites listed here are recorded right away. Each rule is a card
/// with labelled fields and the file name it gives, so it reads as "recognise the site by …" and "name
/// the recording …", not as renaming one thing into another.
struct BrowserRulesEditor: View {
    @EnvironmentObject private var model: RecorderModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Сайты, где запись начинается сразу").font(.caption.weight(.semibold))
                Text("Звонки в браузере обычно спрашивают «Записать?». На этих сайтах MeetRec начинает запись без вопроса.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 4)
            ForEach(model.browserRules) { rule in
                card(rule)
            }
            Button {
                model.browserRules.append(BrowserRule(keyword: "", title: ""))
            } label: {
                Label("Добавить сайт", systemImage: "plus.circle.fill")
            }
            .buttonStyle(.borderless)
            Text("MeetRec видит только активную вкладку окна браузера: если в начале звонка открыта другая вкладка, появится обычный вопрос.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func card(_ rule: BrowserRule) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            field("Вкладка называется", hint: "можно несколько через запятую") {
                TextField("Vimbox, Skysmart", text: binding(rule, \.keyword))
                    .textFieldStyle(.roundedBorder)
            }
            field("Название записи", hint: nil) {
                TextField("Skyeng", text: binding(rule, \.title))
                    .textFieldStyle(.roundedBorder)
            }
            HStack(spacing: 4) {
                Text("Файл будет:").foregroundStyle(.secondary)
                Text(Self.exampleFileName(title: rule.title)).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
            }
            .font(.caption)
            Toggle("Собеседник один (урок): в транскрипте все, кроме вас, — один человек", isOn: oneOther(rule))
                .toggleStyle(.checkbox)
                .font(.caption)
                .help("Например, урок: если голос преподавателя меняется со связью, он не распадётся на двух спикеров")
            HStack {
                Spacer()
                Button("Удалить правило", role: .destructive) {
                    model.browserRules.removeAll { $0.id == rule.id }
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.08)))
    }

    private func field<Content: View>(_ label: LocalizedStringKey, hint: LocalizedStringKey?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(label).font(.caption)
                if let hint { (Text(verbatim: "— ") + Text(hint)).font(.caption).foregroundStyle(.secondary) }
            }
            content()
        }
    }

    /// "2026-10-17 14-03-22 Skyeng.mov": what a recording started by this rule is called.
    static func exampleFileName(title: String, date: Date = Date()) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        let stem = RecordingFiles.stem(timestamp: RecordingFiles.timestamp(date),
                                       title: trimmed.isEmpty ? "" : RecordingFiles.sanitize(trimmed))
        return stem + ".mov"
    }

    private func oneOther(_ rule: BrowserRule) -> Binding<Bool> {
        Binding(get: { rule.oneOther == true }, set: { value in
            var rules = model.browserRules
            guard let index = rules.firstIndex(where: { $0.id == rule.id }) else { return }
            rules[index].oneOther = value
            model.browserRules = rules
        })
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
