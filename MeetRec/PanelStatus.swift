import SwiftUI
import AVFoundation

// The live status of a running recording in the panel: levels, sources, what is captured.

/// The recording timer; observes only `LiveRecording`, so it redraws once a second on its own.
struct ElapsedLabel: View {
    @EnvironmentObject private var live: LiveRecording

    var body: some View {
        Label(live.elapsedText, systemImage: "record.circle.fill")
            .foregroundStyle(.red)
            .monospacedDigit()
    }
}

/// `StatusPanel` fed from `LiveRecording`: the meters redraw without redrawing the rest of the panel.
struct LiveStatusPanel: View {
    @EnvironmentObject private var live: LiveRecording

    var body: some View {
        if let health = live.health {
            StatusPanel(health: health, load: live.load)
        }
    }
}

/// Microphones to switch to during a recording (status row "Микрофон").
struct MicrophoneMenuItems: View {
    @EnvironmentObject private var model: RecorderModel

    var body: some View {
        ForEach(model.microphones) { mic in
            Button {
                model.switchMicrophone(to: mic.id, byUser: true)
            } label: {
                if mic.id == model.recordingMicUID {
                    Label(mic.name, systemImage: "checkmark")
                } else {
                    Text(mic.name)
                }
            }
        }
    }
}

/// Monitors and windows to record (status row "Экран").
struct CaptureMenuItems: View {
    @EnvironmentObject private var model: RecorderModel

    var body: some View {
        // Whole monitors first: the one being recorded is ticked, another can be switched to.
        ForEach(model.displays) { display in
            Button {
                if display.id == model.recordingDisplayID {
                    model.record(window: nil)
                } else {
                    model.switchDisplay(to: display.id)
                }
            } label: {
                if model.captureWindow == nil && display.id == model.recordingDisplayID {
                    Label("Монитор «\(display.name)»", systemImage: "checkmark")
                } else {
                    Label("Монитор «\(display.name)»", systemImage: "display")
                }
            }
        }
        Divider()
        if model.windows.isEmpty {
            Text("Нет окон")
        }
        ForEach(model.windows) { window in
            Button {
                model.record(window: window)
            } label: {
                if model.captureWindow?.id == window.id {
                    Label(window.label, systemImage: "checkmark")
                } else {
                    Text("Только окно: \(window.label)")
                }
            }
        }
        Divider()
        Button("Обновить список окон") { model.refreshWindows() }
    }
}

/// Live "is everything being recorded?" panel shown while recording.
struct StatusPanel: View {
    let health: RecordingHealth
    let load: SystemLoad?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Статус записи").font(.subheadline.weight(.semibold))
            // The device lines are menus: switching happens where the device is shown.
            StatusRow(icon: "mic.fill", signal: health.microphone, menu: health.microphone.state == .off ? nil : AnyView(MicrophoneMenuItems()),
                      menuHelp: "Переключить микрофон, не останавливая запись")
            StatusRow(icon: "speaker.wave.2.fill", signal: health.systemAudio)
            StatusRow(icon: "display", signal: health.screen, menu: AnyView(CaptureMenuItems()),
                      menuHelp: "Записывать другой монитор или только одно окно")
            StatusRow(icon: "internaldrive", signal: health.file)
            if let load {
                HStack(spacing: 8) {
                    Image(systemName: "cpu").frame(width: 18).foregroundStyle(.secondary)
                    Text("Процессор \(Int(load.systemCPU.rounded()))%")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("MeetRec \(Int(load.appCPU.rounded()))% · \(load.memoryText)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .help("Общая загрузка процессора Mac; справа — сколько процессора (в % одного ядра) и памяти занимает MeetRec")
            }
            if health.fileStalledFor >= HealthTracker.fileStalledAfter {
                Text("Файл записи перестал расти: данные не сохраняются. Остановите и начните запись заново.")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if health.diskLow {
                Text("Заканчивается место на диске. Запись остановится сама, когда останется меньше \(DiskSpace.format(DiskSpace.stopBelow)).")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if health.hasProblem {
                Text("Один из источников не передаёт сигнал. Проверьте устройство или остановите и начните запись заново.")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct StatusRow: View {
    let icon: String
    let signal: SignalHealth
    /// Items of a menu opened from the detail line (the device being recorded).
    var menu: AnyView?
    var menuHelp: String?

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: icon)
                .frame(width: 18)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(signal.title).font(.callout)
                    Spacer()
                    Circle().fill(color).frame(width: 8, height: 8)
                }
                if let menu {
                    Menu {
                        menu
                    } label: {
                        detail
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.visible)
                    .fixedSize()
                    .help(menuHelp ?? "")
                } else {
                    detail
                }
                if let level = signal.levelDB {
                    LevelMeter(levelDB: level)
                }
            }
        }
    }

    private var detail: some View {
        Text(signal.detail)
            .font(.caption)
            .foregroundStyle(signal.state == .noSignal ? .red : .secondary)
            .lineLimit(1)
            .truncationMode(.middle)
    }

    private var color: Color {
        switch signal.state {
        case .ok: return .green
        case .quiet: return signal.title == "Микрофон" ? .yellow : .gray
        case .noSignal: return .red
        case .off: return .gray.opacity(0.4)
        }
    }
}

/// Horizontal level bar from -60 dBFS to 0 dBFS.
struct LevelMeter: View {
    let levelDB: Float

    var body: some View {
        GeometryReader { geometry in
            let fraction = CGFloat(max(0, min(1, (levelDB + 60) / 60)))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2))
                Capsule()
                    .fill(levelDB > -6 ? Color.red : levelDB > -20 ? Color.yellow : Color.green)
                    .frame(width: geometry.size.width * fraction)
            }
        }
        .frame(height: 5)
        // Not animated: a tween redrew the whole panel (card and shadows) on every display frame,
        // ~40 frames a second for two meters at 3 updates a second, +5% of a core while recording.
    }
}

/// While recording: mark the current moment, and choose between the whole screen and one window.
struct RecordingControls: View {
    @EnvironmentObject private var model: RecorderModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let warning = model.meetingWindowWarning {
                VStack(alignment: .leading, spacing: 6) {
                    WarningLabel(text: warning)
                        .font(.callout)
                    HStack {
                        if let display = model.meetingWindowDisplay {
                            Button("Записывать «\(display.name)»") { model.switchDisplay(to: display.id) }
                                .buttonStyle(.borderedProminent)
                        }
                        Button("Игнорировать") { model.ignoreMeetingWindow() }
                    }
                    .controlSize(.small)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .warningBox()
            }
            if model.isPaused {
                // Paused: one clear state and one clear way back.
                HStack(spacing: 8) {
                    Image(systemName: "pause.circle.fill").foregroundStyle(.orange).font(.title3)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Запись на паузе").font(.callout.weight(.semibold))
                        Text("Ничего не записывается; в файле пауза будет вырезана")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                }
                .warningBox()
            }
            HStack(spacing: 8) {
                Button {
                    model.togglePause()
                } label: {
                    HStack {
                        Image(systemName: model.isPaused ? "play.fill" : "pause.fill")
                            .foregroundStyle(model.isPaused ? Color.green : Color.orange)
                        Text(model.isPaused ? "Снять с паузы" : "Пауза")
                        if let hint = model.pauseHotKeyHint {
                            Spacer()
                            Text(hint).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .help(model.isPaused ? "Продолжить запись в тот же файл" : "Ничего не записывать, пока вы не снимете с паузы; в файле пауза будет вырезана")
                Button {
                    model.addMarker()
                } label: {
                    HStack {
                        Image(systemName: "star.fill").foregroundStyle(.yellow)
                        Text("Отметить момент")
                        if let hint = RecorderModel.markerHotKeyHint {
                            Spacer()
                            Text(hint).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .help("Отметка попадёт в транскрипт как «⭐ время»")
            }
            .controlSize(.large)
            if let last = model.markers.last {
                Text("Отметок: \(model.markers.count), последняя на \(last.timeText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if model.captureWindow != nil {
                Text("Пишется только это окно: другие окна и уведомления в запись не попадут.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { model.refreshWindows() }
        .onChange(of: model.panelVisible) { if model.panelVisible { model.refreshWindows() } }
    }
}
