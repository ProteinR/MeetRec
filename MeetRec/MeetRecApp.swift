import SwiftUI

@main
struct MeetRecApp: App {
    @StateObject private var model = RecorderModel()

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environmentObject(model)
        } label: {
            if model.isRecording {
                Image(systemName: "record.circle.fill")
                Text(model.elapsedText)
            } else {
                Image(systemName: "record.circle")
            }
        }
        .menuBarExtraStyle(.window)
    }
}

struct ContentView: View {
    @EnvironmentObject private var model: RecorderModel
    @State private var showVideoSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            recordButton
            Divider()
            sources
            DisclosureGroup("Видео", isExpanded: $showVideoSettings) { videoSettings }
            Divider()
            folderRow
            if let error = model.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            footer
        }
        .padding(14)
        .frame(width: 320)
        .onAppear { model.refreshDevices() }
    }

    private var header: some View {
        HStack {
            Text("MeetRec").font(.headline)
            Spacer()
            if model.isRecording {
                Label(model.elapsedText, systemImage: "record.circle.fill")
                    .foregroundStyle(.red)
                    .monospacedDigit()
            }
        }
    }

    private var recordButton: some View {
        Button {
            model.toggle()
        } label: {
            HStack {
                Image(systemName: model.isRecording ? "stop.fill" : "record.circle")
                Text(model.isRecording ? "Остановить" : "Начать запись")
                Spacer()
                Text(RecorderModel.hotKeyHint).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        }
        .buttonStyle(.borderedProminent)
        .tint(model.isRecording ? .gray : .red)
        .controlSize(.large)
        .disabled(model.isBusy)
    }

    private var sources: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Монитор", selection: $model.displayID) {
                Text(autoDisplayTitle).tag(RecorderModel.autoDisplay)
                ForEach(model.displays) { display in
                    Text(display.name).tag(Int(display.id))
                }
            }
            Toggle("Звук системы", isOn: $model.systemAudio)
            Toggle("Микрофон", isOn: $model.microphone)
            if model.microphone {
                Picker("Устройство", selection: $model.microphoneID) {
                    Text("Системный по умолчанию").tag("")
                    ForEach(model.microphones) { mic in
                        Text(mic.name).tag(mic.id)
                    }
                }
            }
        }
        .disabled(model.isRecording)
    }

    private var videoSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Кадров/с", selection: $model.fps) {
                ForEach([5, 10, 15, 30, 60], id: \.self) { Text("\($0)").tag($0) }
            }
            Picker("Разрешение", selection: $model.resolution) {
                ForEach(ResolutionPreset.allCases) { Text($0.title).tag($0.rawValue) }
            }
            Picker("Кодек", selection: $model.codec) {
                Text("H.264 (совместимость)").tag("h264")
                Text("HEVC (меньше файлы)").tag("hevc")
            }
        }
        .padding(.top, 6)
        .disabled(model.isRecording)
    }

    private var folderRow: some View {
        HStack {
            Image(systemName: "folder")
            Text(model.folderURL.lastPathComponent)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(model.folderPath)
            Spacer()
            Button("Изменить") { model.chooseFolder() }
                .disabled(model.isRecording)
            Button("Открыть") { model.openFolder() }
        }
    }

    private var footer: some View {
        HStack {
            if model.lastFile != nil {
                Button("Последняя запись") { model.revealLastFile() }
            }
            Button("Лог") { model.openLog() }
            Spacer()
            Button("Выйти") { NSApp.terminate(nil) }
                .disabled(model.isRecording)
        }
        .buttonStyle(.borderless)
    }

    private var autoDisplayTitle: String {
        if let display = model.effectiveDisplay {
            return "Авто (\(display.name))"
        }
        return "Авто"
    }
}
