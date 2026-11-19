import AVFoundation
import SwiftUI

/// The first launch, in the panel itself: permissions, when to record meetings, transcripts. Three
/// steps and a last word; each can be skipped and everything is in the settings later. Shown until
/// finished (`onboardingDone`); a copy that already had screen recording allowed (an update) skips it.
struct OnboardingView: View {
    static let storageKey = "onboardingDone"

    /// Called at the end ("Начать").
    let done: () -> Void

    @EnvironmentObject private var model: RecorderModel
    @EnvironmentObject private var transcriber: Transcriber
    @State private var step = 1
    @State private var screenAllowed = CGPreflightScreenCaptureAccess()
    @State private var screenAsked = false
    @State private var micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var installed: [MeetingApp] = []
    @State private var downloadAsked = false
    /// Permissions are granted in System Settings: looked at again while the first step is shown.
    private let permissionsTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    /// An update from a version before the first launch existed: the copy is already set up.
    static func skipForExistingInstall() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: storageKey), CGPreflightScreenCaptureAccess() else { return }
        defaults.set(true, forKey: storageKey)
        Log.info("First launch skipped: screen recording is already allowed", "app")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 6) {
                ForEach(1...3, id: \.self) { index in
                    Capsule()
                        .fill(index <= step ? Color.accentColor : Color.primary.opacity(0.15))
                        .frame(width: 24, height: 4)
                }
                Spacer()
                Text(step <= 3 ? String(localized: "Шаг \(step) из 3") : String(localized: "Всё настроено"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Group {
                switch step {
                case 1: permissions
                case 2: meetings
                case 3: transcripts
                default: finished
                }
            }
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                    removal: .move(edge: .leading).combined(with: .opacity)))
            .id(step)
            HStack(spacing: 8) {
                if step > 1, step <= 3 {
                    Button("Назад") { go(step - 1) }
                        .buttonStyle(.borderless)
                }
                Spacer()
                if step == 3 {
                    Button("Пропустить") { go(4) }
                        .buttonStyle(.borderless)
                }
                Button {
                    if step >= 4 { finish() } else { go(step + 1) }
                } label: {
                    Text(step >= 4 ? String(localized: "Начать") : (step == 3 ? String(localized: "Готово") : String(localized: "Дальше")))
                        .fontWeight(.semibold)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .foregroundStyle(.white)
                        .background(Capsule().fill(Color.accentColor))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
            }
        }
        .onAppear {
            installed = MeetingApp.all.filter { $0.supported && $0.isInstalled }
            Log.info("First launch shown", "app")
        }
        .onReceive(permissionsTimer) { _ in
            guard step == 1 else { return }
            screenAllowed = CGPreflightScreenCaptureAccess()
            micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        }
        .onChange(of: transcriber.modelsState) {
            // Downloaded from here: transcribe after each recording, which is why they were fetched.
            if downloadAsked, transcriber.modelsState == .ready { transcriber.transcribeAfterRecording = true }
        }
    }

    private func go(_ next: Int) {
        withAnimation(.smooth(duration: 0.3)) { step = next }
    }

    private func finish() {
        Log.info("First launch finished: detection \(model.meetingDetection ? "on" : "off"), apps \(model.meetingAppsRaw), modes \(model.meetingAppModesRaw), transcription after recording \(transcriber.transcribeAfterRecording)", "app")
        done()
    }

    // MARK: - Steps

    private func title(_ text: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text).font(.title3.weight(.bold))
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 12) {
            title(String(localized: "Записывайте встречи без забот"),
                  String(localized: "MeetRec записывает экран, ваш голос и собеседников, а потом делает текст встречи. Всё остаётся на вашем Mac. Для начала нужны два разрешения macOS."))
            permissionRow(icon: "display", title: String(localized: "Запись экрана"),
                          detail: String(localized: "Чтобы записывать видео встречи и звук собеседников"),
                          granted: screenAllowed) {
                if screenAsked {
                    openPrivacy("Privacy_ScreenCapture")
                } else {
                    screenAsked = true
                    Log.info("First launch: asking for screen recording", "permissions")
                    CGRequestScreenCaptureAccess()
                }
            }
            permissionRow(icon: "mic.fill", title: String(localized: "Микрофон"),
                          detail: String(localized: "Чтобы в записи был ваш голос"),
                          granted: micStatus == .authorized) {
                if micStatus == .notDetermined {
                    Task {
                        let granted = await AVCaptureDevice.requestAccess(for: .audio)
                        Log.info("First launch: microphone \(granted ? "granted" : "denied")", "permissions")
                        micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
                    }
                } else {
                    openPrivacy("Privacy_Microphone")
                }
            }
            if screenAsked, !screenAllowed {
                HStack(spacing: 8) {
                    Text("Разрешили запись экрана? macOS включит её после перезапуска MeetRec.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button("Перезапустить") { AppLanguage.relaunch() }
                        .controlSize(.small)
                }
            } else {
                Text("Кнопка покажет вопрос macOS или откроет нужное место в Системных настройках.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func permissionRow(icon: String, title: String, detail: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 16)).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            if granted {
                Label("Разрешено", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
            } else {
                Button("Разрешить", action: action)
                    .controlSize(.small)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.05)))
    }

    private func openPrivacy(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    private var meetings: some View {
        VStack(alignment: .leading, spacing: 12) {
            title(String(localized: "Когда начинать запись?"),
                  String(localized: "MeetRec видит, когда приложение для звонков включает микрофон. Здесь только приложения, которые нашлись на этом Mac; поменять можно в любой момент в настройках."))
            if installed.isEmpty {
                Text("Приложений для звонков не нашлось. Записывайте вручную, а когда что-то появится, включите его в настройках → «Встречи и звонки».")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(installed) { app in
                MeetingModeRow(app: app)
            }
            Text("Вручную можно всегда: \(RecorderModel.hotKeyHint ?? "⌃⌥⌘R") или кнопка в панели.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var transcripts: some View {
        VStack(alignment: .leading, spacing: 12) {
            title(String(localized: "Текст встречи"),
                  String(localized: "После записи MeetRec сделает транскрипт с именами говорящих. Распознавание идёт на этом Mac, без интернета и без аккаунтов."))
            VStack(alignment: .leading, spacing: 6) {
                Text("Как вас подписывать в тексте").font(.callout.weight(.semibold))
                TextField("Ваше имя", text: $transcriber.myName)
                    .textFieldStyle(.roundedBorder)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.05)))
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.circle").font(.system(size: 16)).frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Модели распознавания · ~650 МБ").font(.callout.weight(.semibold))
                    Text(modelsDetail).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                switch transcriber.modelsState {
                case .ready:
                    Label("Готово", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.semibold)).foregroundStyle(.green)
                case .downloading, .checking:
                    ProgressView().controlSize(.small).frame(width: 16, height: 16)
                case .missing, .failed:
                    Button(String(localized: "Скачать")) {
                        downloadAsked = true
                        transcriber.downloadModels()
                    }
                    .controlSize(.small)
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.05)))
            Toggle("Делать транскрипт после каждой записи", isOn: $transcriber.transcribeAfterRecording)
                .toggleStyle(LightSwitchStyle())
                .disabled(transcriber.modelsState != .ready)
            Text("Можно пропустить: записи будут без текста, транскрибацию можно включить позже в настройках.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var modelsDetail: String {
        switch transcriber.modelsState {
        case .ready: return String(localized: "Скачаны, всё работает без сети")
        case .downloading(let phase): return phase
        case .checking: return String(localized: "Проверка моделей…")
        case .failed(let message): return message
        case .missing: return String(localized: "Один раз, дальше всё работает без сети")
        }
    }

    private var finished: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 36))
                .foregroundStyle(.green)
            title(String(localized: "Готово"),
                  String(localized: "MeetRec живёт в строке меню — значок с красной точкой. Начните запись кнопкой или \(RecorderModel.hotKeyHint ?? "⌃⌥⌘R"); записи и их тексты появятся в панели."))
            VStack(alignment: .leading, spacing: 2) {
                Text("Ещё умеет").font(.callout.weight(.semibold))
                Text("Скриншоты с пометками, текст с экрана (OCR), отметки важных моментов во время записи. Всё это — во вкладке «Скриншоты» и в настройках → «Клавиши».")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.05)))
        }
    }
}

/// One calling app: "Сразу записывать", "Спрашивать" or "Не записывать", with what that means
/// under it.
struct MeetingModeRow: View {
    let app: MeetingApp
    /// The app's own icon next to its name (settings).
    var icon: NSImage?
    @EnvironmentObject private var model: RecorderModel

    enum Mode: CaseIterable { case auto, ask, off }

    /// "Спрашивать" works whenever the app is selected; recording by itself also needs detection on
    /// (`RecorderModel.meetingStarted`).
    private var mode: Mode {
        guard model.selectedMeetingApps.contains(app.id) else { return .off }
        if model.asks(app) { return .ask }
        return model.meetingDetection ? .auto : .off
    }

    private func set(_ mode: Mode) {
        switch mode {
        case .off:
            model.setMeetingApp(app, enabled: false)
        case .auto, .ask:
            model.setAsks(app, mode == .ask)
            if !model.selectedMeetingApps.contains(app.id) { model.setMeetingApp(app, enabled: true) }
            if mode == .auto, !model.meetingDetection {
                model.meetingDetection = true
                model.configureDetector()
            }
        }
        Log.info("Meeting app \(app.name): \(mode)", "meetings")
    }

    private func title(_ mode: Mode) -> String {
        switch mode {
        case .auto: String(localized: "Сразу записывать")
        case .ask: String(localized: "Спрашивать")
        case .off: String(localized: "Не записывать")
        }
    }

    private var hint: String {
        switch mode {
        case .auto:
            app.asks
                ? String(localized: "Звонок начался — MeetRec сам начнёт запись и сам остановит её после звонка. Осторожно: \(app.name) включает микрофон и для голосовых сообщений, они тоже запишутся.")
                : String(localized: "Встреча началась — через несколько секунд MeetRec сам начнёт запись и сам остановит её после встречи. У значка в строке меню идёт отсчёт, его можно отменить.")
        case .ask:
            String(localized: "Под строкой меню появится вопрос «Похоже, идёт звонок… Записать?» с кнопками «Записать» и «Не сейчас».")
        case .off:
            String(localized: "MeetRec ничего не начнёт и ни о чём не спросит. Запись только вручную.")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if let icon {
                    Image(nsImage: icon).resizable().frame(width: 18, height: 18)
                }
                Text(app.name).font(.callout.weight(.semibold))
            }
            HStack(spacing: 2) {
                ForEach(Mode.allCases, id: \.self) { option in
                    Button {
                        set(option)
                    } label: {
                        Text(title(option))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(mode == option ? .primary : .secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                            .background {
                                if mode == option {
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(Color(nsColor: .controlBackgroundColor))
                                        .shadow(color: .black.opacity(0.12), radius: 1, y: 0.5)
                                }
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(mode == option ? .isSelected : [])
                }
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.07)))
            Text(hint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.05)))
    }
}
