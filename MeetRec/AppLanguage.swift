import AppKit
import SwiftUI

/// MeetRec's own language: as the system's, or fixed. macOS keeps it as the app's `AppleLanguages`
/// (the same setting as System Settings → General → Language & Region → Applications) and applies
/// it only at launch, so a change offers a restart.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, ru, en
    var id: String { rawValue }

    /// Each language in its own words.
    var title: String {
        switch self {
        case .system: return String(localized: "Как в системе")
        case .ru: return "Русский"
        case .en: return "English"
        }
    }

    /// The app's own choice (its defaults domain, not the global list of languages).
    static var chosen: AppLanguage {
        let domain = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")
        guard let first = (domain?["AppleLanguages"] as? [String])?.first else { return .system }
        return first.hasPrefix("en") ? .en : first.hasPrefix("ru") ? .ru : .system
    }

    static func choose(_ language: AppLanguage) {
        if language == .system {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([language.rawValue], forKey: "AppleLanguages")
        }
        Log.info("Language: \(language.rawValue) (after a restart: \(nextLocalization), now: \(currentLocalization))", "app")
    }

    /// The localization the running app uses.
    static var currentLocalization: String { Bundle.main.preferredLocalizations.first ?? "ru" }

    /// The localization the next launch will use.
    static var nextLocalization: String {
        let preferences = UserDefaults.standard.stringArray(forKey: "AppleLanguages") ?? Locale.preferredLanguages
        return Bundle.preferredLocalizations(from: Bundle.main.localizations, forPreferences: preferences).first ?? "ru"
    }

    /// Quits (as usual: the watchdog flag is removed) and opens MeetRec again once this process is gone.
    static func relaunch() {
        let script = "while /bin/kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$0\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, Bundle.main.bundlePath]
        do {
            try process.run()
            Log.info("Restarting for the language", "app")
            NSApp.terminate(nil)
        } catch {
            Log.error("Could not restart: \(Log.describe(error))")
        }
    }
}

/// Settings row: "Язык" with a picker and, when the choice differs from what is shown, a restart.
struct LanguagePicker: View {
    @EnvironmentObject private var model: RecorderModel
    @EnvironmentObject private var transcriber: Transcriber
    @State private var chosen = AppLanguage.chosen
    @State private var next = AppLanguage.nextLocalization

    private var busy: Bool {
        if case .running = transcriber.job { return true }
        return model.isRecording || model.isBusy
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "globe")
                Text("Язык").font(.callout)
                Spacer(minLength: 4)
                Picker("Язык", selection: $chosen) {
                    ForEach(AppLanguage.allCases) { Text(verbatim: $0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .onChange(of: chosen) { _, language in
                    AppLanguage.choose(language)
                    next = AppLanguage.nextLocalization
                }
            }
            if next != AppLanguage.currentLocalization {
                HStack(spacing: 8) {
                    Text(busy ? "Язык сменится после перезапуска — сейчас идёт запись или транскрибация"
                              : "Язык сменится после перезапуска")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Button("Перезапустить") { AppLanguage.relaunch() }
                        .disabled(busy)
                }
            }
        }
    }
}
