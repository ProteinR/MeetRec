import SwiftUI

/// "Встречи и звонки": each calling app found on this Mac with the same choice as the first
/// launch ("Сразу записывать" / "Спрашивать" / "Не записывать"), the browser's site rules, and the
/// apps not supported yet.
struct MeetingSettings: View {
    @EnvironmentObject private var model: RecorderModel
    /// Found before the first frame: filled in `onAppear`, the apps appeared after the page had
    /// started sliding in, and the card grew in a second animation behind it.
    @State private var installed = MeetingApp.all.filter(\.isInstalled)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Встреча замечается, когда приложение берёт микрофон. Остановится запись сама, через \(Int(MeetingDetector.endAfter)) с после конца встречи.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            let supported = installed.filter(\.supported)
            if supported.isEmpty {
                Text("Не найдено поддерживаемых приложений для звонков").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(supported) { app in
                MeetingModeRow(app: app, icon: icon(for: app))
                if app.id == "browser", model.selectedMeetingApps.contains("browser"), model.asks(app) {
                    BrowserRulesEditor()
                }
            }
            let later = installed.filter { !$0.supported }
            if !later.isEmpty {
                Text("Скоро: \(later.map(\.name).formatted(.list(type: .and)))")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            if model.meetingDetection, let status = model.detectorStatus {
                Label(status, systemImage: "waveform")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
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
