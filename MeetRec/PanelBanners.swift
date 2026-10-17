import SwiftUI
import AppKit

// Banners at the top of the panel (a call question, the countdowns before an automatic start or
// stop) and the notice about the last recording under it.

/// The last recording at the bottom of the panel: saved (when, how long) and its transcript —
/// progress while it runs, then a click opens it.
struct LastRecordingNotice: View {
    let notice: String
    let file: URL?
    @State private var namingSpeakers = false
    let close: () -> Void
    @EnvironmentObject private var transcriber: Transcriber

    private var interrupted: Bool { notice.hasPrefix("Запись прервалась") }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 5) {
                row(icon: interrupted ? "exclamationmark.triangle.fill" : "checkmark.circle.fill",
                    color: interrupted ? .orange : .green) {
                    Text(notice).fixedSize(horizontal: false, vertical: true)
                }
                if let file {
                    transcript(file)
                }
            }
            Spacer(minLength: 0)
            Button(action: close) { Image(systemName: "xmark").font(.caption2) }
                .buttonStyle(.borderless)
        }
        .font(.caption)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
    }

    @ViewBuilder
    private func transcript(_ file: URL) -> some View {
        if transcriber.runningFile == file {
            row(icon: nil, color: .secondary) {
                Text("Транскрибация\(transcriber.progress.map { " · \(Int($0 * 100))%" } ?? "…")").monospacedDigit()
            }
        } else if transcriber.queue.contains(file) {
            row(icon: "clock", color: .secondary) { Text("В очереди на транскрибацию") }
        } else if let transcript = Transcriber.existingTranscript(for: file) {
            row(icon: "checkmark.circle.fill", color: .green) {
                Button("Транскрипт готов") { QuickLookPresenter.shared.preview(transcript) }
                    .buttonStyle(.link)
                    .help("Открыть транскрипт")
            }
            if namingSpeakers {
                SpeakersEditor(recording: file) { namingSpeakers = false }
            } else if SpeakerNaming.hasUnnamed(file) {
                row(icon: "person.2.badge.gearshape", color: .secondary) {
                    Button("Есть безымянные спикеры — подписать…") { namingSpeakers = true }
                        .buttonStyle(.link)
                        .help("Назвать «Speaker N» по именам; голоса запомнятся для следующих встреч")
                }
            }
        } else if let failure = transcriber.failures[file.path] {
            row(icon: "exclamationmark.triangle.fill", color: .orange) {
                Button("Транскрибация не удалась — повторить") { transcriber.enqueue(file) }
                    .buttonStyle(.link)
                    .help(failure)
            }
        }
    }

    /// Icon column of the same width for every line, so the texts line up.
    private func row<Content: View>(icon: String?, color: Color, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Group {
                if let icon {
                    Image(systemName: icon).foregroundStyle(color)
                } else {
                    ProgressView(value: transcriber.progress ?? 0)
                        .progressViewStyle(.circular)
                        .controlSize(.mini)
                }
            }
            .frame(width: 14)
            content()
        }
    }
}

/// "Похоже, идёт звонок в Telegram. Записать?" for apps that may hold the mic for other things.
struct CallPromptBanner: View {
    let app: MeetingApp
    @EnvironmentObject private var model: RecorderModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: app.icon)
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color.accentColor))
                VStack(alignment: .leading, spacing: 1) {
                    Text(app.promptTitle(reminder: model.promptIsReminder)).font(.callout.weight(.semibold))
                    Text(app.promptDetail)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 8) {
                Button {
                    model.acceptCallPrompt()
                } label: {
                    Label("Записать", systemImage: "record.circle").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .keyboardShortcut(.defaultAction)
                Button {
                    model.dismissCallPrompt()
                } label: {
                    Text("Не сейчас").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.large)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.12)))
    }
}

enum RecordingCountdownTitle {
    /// " 5" next to the menu bar icon while waiting to record automatically.
    static func text(_ countdown: RecorderModel.Countdown?) -> String? {
        countdown.map { " \($0.seconds)" }
    }
}

/// "Через 5 с начну записывать встречу в Teams" with "Записать сейчас" / "Не записывать".
struct CountdownBanner: View {
    let countdown: RecorderModel.Countdown
    @EnvironmentObject private var model: RecorderModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("\(countdown.seconds)")
                    .font(.system(size: 15, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText(countsDown: true))
                    .frame(width: 26, height: 26)
                    .background(Circle().strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1.5))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Через \(countdown.seconds) с начну записывать \(countdown.what)")
                        .font(.callout.weight(.semibold))
                        .contentTransition(.numericText(countsDown: true))
                    Text("Остановится сама, когда \(countdown.app.noun) закончится.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 8) {
                Button {
                    model.recordNow()
                } label: {
                    Label("Записать сейчас", systemImage: "record.circle").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                Button {
                    model.skipMeeting()
                } label: {
                    Text("Не записывать").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.large)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.06)))
        .animation(.default, value: countdown.seconds)
    }
}

/// "Встреча закончилась, запись остановится через 9 с" with "Остановить сейчас" / "Продолжить запись".
struct StopCountdownBanner: View {
    let countdown: RecorderModel.StopCountdown
    @EnvironmentObject private var model: RecorderModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("\(countdown.seconds)")
                    .font(.system(size: 15, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText(countsDown: true))
                    .frame(width: 26, height: 26)
                    .background(Circle().strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1.5))
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(countdown.app.asks ? "Звонок закончился" : "Встреча закончилась"), запись остановится через \(countdown.seconds) с")
                        .font(.callout.weight(.semibold))
                        .contentTransition(.numericText(countsDown: true))
                    Text("\(countdown.app.name) отпустил микрофон. Если он снова его возьмёт, запись продолжится.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 8) {
                Button {
                    model.stopNow()
                } label: {
                    Label("Остановить сейчас", systemImage: "stop.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                Button {
                    model.keepRecording()
                } label: {
                    Text("Продолжить запись").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            .controlSize(.large)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.06)))
        .animation(.default, value: countdown.seconds)
    }
}
