import SwiftUI

/// "Автозапись встреч": on/off and the calling apps found on this Mac.
struct MeetingSettings: View {
    @EnvironmentObject private var model: RecorderModel
    @State private var installed: [MeetingApp] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Определять встречи и записывать сами", isOn: $model.meetingDetection)
                .onChange(of: model.meetingDetection) { model.configureDetector() }
            Text("Запись начнётся, когда приложение звонка возьмёт микрофон дольше \(Int(MeetingDetector.startAfter)) с, и остановится через \(Int(MeetingDetector.endAfter)) с после того, как отпустит. Записи, начатые вручную, сами не останавливаются.")
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
                    if let note = app.note {
                        Spacer()
                        Text(note).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                    }
                }
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
