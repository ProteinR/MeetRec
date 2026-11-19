import AppKit
import Foundation
import SwiftUI

/// Meeting summaries by a language model: after a transcript is written (if turned on) or from a
/// recording's menu. The summary goes into the transcript itself as "## Суммаризация" under its header
/// (`SummaryText`). The transcript is sent to the chosen provider with the user's own key; with a
/// local model nothing leaves the Mac.
@MainActor
final class Summarizer: ObservableObject {
    static let shared = Summarizer()

    @AppStorage("summarizeAfterTranscription") var summarizeAfterTranscription = false
    @AppStorage("summaryProvider") private var providerRaw = SummaryProvider.anthropic.rawValue
    /// "meeting": the language the meeting was held in; "app": MeetRec's own language.
    @AppStorage("summaryLanguage") var language = "meeting"
    @AppStorage("summaryLocalURL") var localURL = SummaryProvider.local.defaultBaseURL
    /// Running total of all summaries (since the last "Сбросить").
    @AppStorage("summarySpentUSD") private(set) var spentUSD = 0.0
    @AppStorage("summaryTokens") private(set) var spentTokens = 0
    @AppStorage("summaryRuns") private(set) var summaryRuns = 0
    /// Runs whose price was not known (not in `spentUSD`).
    @AppStorage("summaryUnpricedRuns") private(set) var unpricedRuns = 0

    /// Recording paths whose summary is being written.
    @Published private(set) var running: Set<String> = []
    /// Last error per recording path.
    @Published private(set) var failures: [String: String] = [:]
    /// Models of the current provider for the picker, loaded when the settings show it.
    @Published private(set) var models: [SummaryModel] = []
    /// Why there is no list (no key, no server, an error).
    @Published private(set) var modelsMessage: String?
    @Published private(set) var loadingModels = false
    /// Lists already loaded this launch, per provider.
    private var modelCache: [SummaryProvider: [SummaryModel]] = [:]
    /// Bumped when a key is saved, so views re-read it.
    @Published private(set) var keyVersion = 0

    /// Shorter transcripts (a test call, a few words) are not summarised automatically.
    static let minimumWords = 40

    private init() {}

    var provider: SummaryProvider {
        get { SummaryProvider(rawValue: providerRaw) ?? .anthropic }
        set {
            providerRaw = newValue.rawValue
            models = modelCache[newValue] ?? []
            modelsMessage = nil
            loadModelsIfNeeded()
            Log.info("Summary provider: \(newValue.rawValue), model \(model(for: newValue))", "summary")
        }
    }

    /// Model per provider: `summaryModel.<provider>` in user defaults.
    func model(for provider: SummaryProvider) -> String {
        let saved = UserDefaults.standard.string(forKey: "summaryModel.\(provider.rawValue)") ?? ""
        return saved.isEmpty ? provider.defaultModel : saved
    }

    func setModel(_ model: String, for provider: SummaryProvider) {
        objectWillChange.send()
        UserDefaults.standard.set(model.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "summaryModel.\(provider.rawValue)")
    }

    func baseURL(for provider: SummaryProvider) -> String {
        provider == .local ? localURL : provider.defaultBaseURL
    }

    /// Whether a key is saved, cached: views ask on every redraw.
    private var keyPresence: [SummaryProvider: Bool] = [:]

    func hasKey(_ provider: SummaryProvider) -> Bool {
        if let known = keyPresence[provider] { return known }
        let present = APIKeyStore.key(for: provider) != nil
        keyPresence[provider] = present
        return present
    }

    /// The saved key with its middle hidden, for the settings.
    func maskedKey(_ provider: SummaryProvider) -> String? {
        _ = keyVersion
        return APIKeyStore.key(for: provider).map(APIKeyStore.masked)
    }

    func saveKey(_ key: String, for provider: SummaryProvider) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        APIKeyStore.setKey(trimmed, for: provider)
        keyPresence[provider] = nil
        keyVersion += 1
        modelCache[provider] = nil
        models = []
        modelsMessage = nil
        if !trimmed.isEmpty { loadModels() }
        Log.info("Summary: \(provider.rawValue) API key \(trimmed.isEmpty ? "removed" : "saved")", "summary")
    }

    /// Provider, model and (for the cloud) a key are set.
    var isConfigured: Bool {
        let provider = provider
        guard !model(for: provider).isEmpty, !baseURL(for: provider).isEmpty else { return false }
        return !provider.needsKey || hasKey(provider)
    }

    /// The summary's language for the prompt.
    private var languageName: String {
        guard language == "app" else { return "the language the meeting was mostly held in" }
        let code = Bundle.main.preferredLocalizations.first ?? "ru"
        return Locale(identifier: "en").localizedString(forLanguageCode: code) ?? "Russian"
    }

    // MARK: - Running

    /// After transcription: summarises when turned on and the transcript has enough speech.
    func summarizeAfterTranscript(_ transcript: URL, of recording: URL) async {
        guard summarizeAfterTranscription, !Profiling.isActive else { return }
        guard isConfigured else {
            Log.warning("Summary skipped for \(recording.lastPathComponent): provider not set up", "summary")
            return
        }
        guard let text = try? String(contentsOf: transcript, encoding: .utf8),
              SummaryText.spokenWords(text) >= Self.minimumWords else {
            Log.info("Summary skipped for \(recording.lastPathComponent): fewer than \(Self.minimumWords) words", "summary")
            return
        }
        await summarize(recording, notifyOnFailure: true)
    }

    /// Writes (or rewrites) the summary of `recording`'s newest transcript. Returns whether it worked.
    @discardableResult
    func summarize(_ recording: URL, notifyOnFailure: Bool = false) async -> Bool {
        let key = recording.path
        guard !running.contains(key) else { return false }
        guard let transcript = Transcriber.existingTranscript(for: recording),
              let original = try? String(contentsOf: transcript, encoding: .utf8) else {
            fail(recording, String(localized: "Транскрипта нет"), notify: notifyOnFailure)
            return false
        }
        let provider = provider
        let model = model(for: provider)
        let apiKey = APIKeyStore.key(for: provider)
        if provider.needsKey && apiKey == nil {
            fail(recording, String(localized: "Не задан ключ API для \(provider.title)"), notify: notifyOnFailure)
            return false
        }
        running.insert(key)
        failures[key] = nil
        defer { running.remove(key) }
        let title = recording.deletingPathExtension().lastPathComponent
        let modelName = (modelCache[provider] ?? []).first { $0.id == model }?.name ?? model
        RecorderModel.shared.showToast(Toast(kind: .summary, title: String(localized: "Делаю суммаризацию…"),
                                             detail: String(localized: "\(title) · \(modelName), обычно до минуты")))

        let body = SummaryText.removingSummary(original)
        let me = Transcriber.shared.myName.trimmingCharacters(in: .whitespaces)
        let started = Date()
        Log.info("Summary started: \(transcript.lastPathComponent) via \(provider.rawValue) \(model), \(body.count) characters", "summary")
        do {
            let request = try SummaryClient.request(provider: provider, baseURL: baseURL(for: provider), key: apiKey, model: model,
                                                    system: SummaryClient.systemPrompt(myName: me, language: languageName),
                                                    transcript: body)
            let answer = try await SummaryClient.send(request, provider: provider)
            let summary = SummaryText.cleaned(answer.text)
            guard !summary.isEmpty else { throw SummaryClient.Failure(message: String(localized: "Модель вернула пустой ответ")) }
            if answer.truncated { Log.warning("Summary was cut by the output limit", "summary") }

            // The file may have changed meanwhile (speakers named): insert into what is there now.
            guard let current = try? String(contentsOf: transcript, encoding: .utf8) else {
                throw SummaryClient.Failure(message: String(localized: "Транскрипт пропал, пока делалась суммаризация"))
            }
            let usage = await usage(of: answer, provider: provider, requested: model)
            let russian = (Bundle.main.preferredLocalizations.first ?? "ru") == "ru"
            let updated = SummaryText.inserting(summary, into: current,
                                                heading: russian ? "Суммаризация" : "Summary",
                                                transcriptHeading: russian ? "Транскрипт" : "Transcript",
                                                meta: usage.metaLine)
            try updated.write(to: transcript, atomically: true, encoding: .utf8)
            record(usage, for: recording)
            RecorderModel.shared.showToast(Toast(kind: .summary, title: String(localized: "Суммаризация готова"),
                                                 detail: "\(title) · \(usage.shortText)", file: transcript))
            Log.info("Summary written to \(transcript.path) in \(Int(Date().timeIntervalSince(started)))s: \(usage.model), \(answer.usage), \(usage.costUSD.map(SummaryUsage.money) ?? "price unknown")", "summary")
            Transcriber.shared.transcriptChanged()
            return true
        } catch {
            fail(recording, error.localizedDescription, notify: notifyOnFailure)
            return false
        }
    }

    /// Tokens and price of one answer: OpenRouter says the price, Anthropic's comes from its list,
    /// OpenAI's from OpenRouter's catalog; a local model is free.
    private func usage(of answer: SummaryClient.Answer, provider: SummaryProvider, requested: String) async -> SummaryUsage {
        let model = (answer.model?.isEmpty == false ? answer.model : nil) ?? requested
        let cost: Double?
        switch provider {
        case .anthropic: cost = SummaryPricing.anthropicCost(model: model, input: answer.inputTokens, output: answer.outputTokens)
        case .openrouter: cost = answer.reportedCost
        case .openai: cost = await SummaryPricing.openAICost(model: model, input: answer.inputTokens, output: answer.outputTokens)
        case .local: cost = 0
        }
        // Readable names come with the list, which is loaded only when the settings show it.
        if modelCache[provider] == nil,
           let loaded = try? await SummaryClient.models(provider: provider, baseURL: baseURL(for: provider), key: APIKeyStore.key(for: provider)) {
            modelCache[provider] = loaded
        }
        let list = modelCache[provider] ?? []
        let name = list.first { $0.id == model }?.name ?? list.first { $0.id == requested && model.hasPrefix(requested) }?.name ?? model
        return SummaryUsage(date: Date(), appVersion: RecorderModel.appVersion, provider: provider.rawValue, model: model,
                            modelName: name, inputTokens: answer.inputTokens, outputTokens: answer.outputTokens, costUSD: cost)
    }

    /// Adds the run to the recording's `summary.json` and to the running total.
    private func record(_ usage: SummaryUsage, for recording: URL) {
        do {
            try SummaryUsageFile.append(usage, for: recording)
        } catch {
            Log.warning("Summary usage not saved for \(recording.lastPathComponent): \(Log.describe(error))", "summary")
        }
        spentUSD += usage.costUSD ?? 0
        spentTokens += usage.totalTokens
        summaryRuns += 1
        if usage.costUSD == nil { unpricedRuns += 1 }
    }

    func resetTotals() {
        Log.info("Summary totals reset (were \(SummaryUsage.money(spentUSD)), \(spentTokens) tokens, \(summaryRuns) runs)", "summary")
        spentUSD = 0
        spentTokens = 0
        summaryRuns = 0
        unpricedRuns = 0
    }

    private func fail(_ recording: URL, _ message: String, notify: Bool) {
        failures[recording.path] = message
        Log.error("Summary failed for \(recording.lastPathComponent): \(message)", "summary")
        if !notify {
            // Asked for from the menu: the answer comes where the user is looking.
            RecorderModel.shared.showToast(Toast(kind: .problem, title: String(localized: "Суммаризация не сделана"), detail: message))
        } else {
            Notifier.shared.send(id: "meetrec-summary-failed", title: String(localized: "Суммаризация не сделана"),
                                 body: String(localized: "\(recording.deletingPathExtension().lastPathComponent): \(message). Транскрипт готов, суммаризацию можно сделать из меню записи."))
        }
    }

    // MARK: - Settings helpers

    /// The local server's address changed: its list is loaded again when asked.
    func invalidateModels() {
        modelCache[.local] = nil
        models = []
        modelsMessage = nil
    }

    /// Loads the list once per launch and provider (when the settings page shows the picker).
    func loadModelsIfNeeded() {
        if let cached = modelCache[provider] {
            models = cached
            return
        }
        guard !loadingModels else { return }
        loadModels()
    }

    /// Asks the provider for its models; also tells whether the key or the local server works.
    func loadModels() {
        let provider = provider
        if provider.needsKey && !hasKey(provider) {
            models = []
            modelsMessage = String(localized: "Вставьте ключ API — список моделей загрузится сам")
            return
        }
        loadingModels = true
        modelsMessage = nil
        Task {
            defer { loadingModels = false }
            do {
                let list = try await SummaryClient.models(provider: provider, baseURL: baseURL(for: provider), key: APIKeyStore.key(for: provider))
                modelCache[provider] = list
                Log.info("Summary: \(list.count) models from \(provider.rawValue)", "summary")
                guard provider == self.provider else { return }
                models = list
                modelsMessage = list.isEmpty ? String(localized: "Список моделей пуст") : nil
                // The default may not be offered (a new key, a local server): the first one is.
                let current = model(for: provider)
                if let first = list.first, !list.contains(where: { $0.id == current }) {
                    let preferred = list.first { $0.id == provider.defaultModel } ?? first
                    setModel(preferred.id, for: provider)
                    Log.info("Summary model \(current.isEmpty ? "(none)" : current) is not offered by \(provider.rawValue); using \(preferred.id)", "summary")
                }
            } catch {
                guard provider == self.provider else { return }
                models = []
                modelsMessage = error.localizedDescription
                Log.warning("Summary: model list from \(provider.rawValue) failed: \(Log.describe(error))", "summary")
            }
        }
    }

    static func hasSummary(_ recording: URL) -> Bool {
        guard let transcript = Transcriber.existingTranscript(for: recording),
              let text = try? String(contentsOf: transcript, encoding: .utf8) else { return false }
        return SummaryText.hasSummary(text)
    }
}
