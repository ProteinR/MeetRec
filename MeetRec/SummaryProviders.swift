import Foundation

/// Where a meeting summary is written: a cloud model by the user's own API key, or a local model
/// behind an OpenAI-compatible server (Ollama, LM Studio), where nothing leaves the Mac.
enum SummaryProvider: String, CaseIterable, Identifiable {
    case anthropic, openai, openrouter, local

    var id: String { rawValue }

    var title: String {
        switch self {
        case .anthropic: "Anthropic (Claude)"
        case .openai: "OpenAI"
        case .openrouter: "OpenRouter"
        case .local: String(localized: "Локальная модель")
        }
    }

    /// Used until the user picks another one (the list of the provider's models is in settings).
    var defaultModel: String {
        switch self {
        case .anthropic: "claude-opus-5-5"
        case .openai: "gpt-5"
        case .openrouter: "openrouter/auto"
        case .local: ""
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .anthropic: "https://api.anthropic.com/v1"
        case .openai: "https://api.openai.com/v1"
        case .openrouter: "https://openrouter.ai/api/v1"
        case .local: "http://localhost:11434/v1"
        }
    }

    var needsKey: Bool { self != .local }

    /// Where the user gets a key.
    var keyPage: URL? {
        switch self {
        case .anthropic: URL(string: "https://console.anthropic.com/settings/keys")
        case .openai: URL(string: "https://platform.openai.com/api-keys")
        case .openrouter: URL(string: "https://openrouter.ai/keys")
        case .local: nil
        }
    }
}

/// API keys in a file only this user can read (`api-keys.json` in Application Support, mode 0600),
/// as command-line tools keep theirs. Not the keychain: an ad-hoc signed build (from source) looks
/// like a new app after every rebuild, and macOS would then ask for the login password to read it.
/// Never in user defaults or the log.
enum APIKeyStore {
    static var file: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MeetRec/api-keys.json")
    }

    static func key(for provider: SummaryProvider) -> String? {
        let key = load()[provider.rawValue] ?? ""
        return key.isEmpty ? nil : key
    }

    @discardableResult
    static func setKey(_ key: String?, for provider: SummaryProvider) -> Bool {
        var keys = load()
        let value = key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        keys[provider.rawValue] = value.isEmpty ? nil : value
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: keys, options: [.prettyPrinted, .sortedKeys])
            // Created with 0600 from the start, so the key is never readable by others even for a moment.
            if !FileManager.default.fileExists(atPath: file.path) {
                FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            try data.write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            return true
        } catch {
            Log.error("API keys: could not save the \(provider.rawValue) key: \(Log.describe(error))", "summary")
            return false
        }
    }

    /// "sk-ant-api03-Ab…x9Yz": enough to tell keys apart, not enough to use one.
    static func masked(_ key: String) -> String {
        guard key.count > 16 else { return String(repeating: "•", count: max(key.count, 4)) }
        return "\(key.prefix(12))…\(key.suffix(4))"
    }

    private static func load() -> [String: String] {
        guard let data = try? Data(contentsOf: file) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: String] ?? [:]
    }
}

/// A model in the settings' picker.
struct SummaryModel: Identifiable, Hashable {
    var id: String
    var name: String
}

/// One request to a provider: the transcript in, the summary text out. Requests are built by pure
/// functions so the tests check their shape.
enum SummaryClient {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    struct Answer {
        var text: String
        /// The model that answered, when the provider says (a refusal fallback, OpenRouter's auto).
        var model: String?
        var inputTokens = 0
        var outputTokens = 0
        /// What the provider says the request cost (OpenRouter), in US dollars.
        var reportedCost: Double?
        /// The answer was cut by the output limit.
        var truncated = false

        var usage: String { "\(inputTokens) in / \(outputTokens) out" }
    }

    /// Claude models that take server-side refusal fallbacks (`fallbacks: "default"`).
    static let fallbackModels: Set<String> = ["claude-fable-5-2", "claude-fable-5-1", "claude-opus-5-5", "claude-opus-5", "claude-sonnet-5-5"]
    static let anthropicVersion = "2026-10-21"

    static func endpoint(_ base: String, _ path: String) -> URL? {
        var trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        return URL(string: trimmed + path)
    }

    static func request(provider: SummaryProvider, baseURL: String, key: String?, model: String,
                        system: String, transcript: String) throws -> URLRequest {
        switch provider {
        case .anthropic:
            guard let url = endpoint(baseURL, "/messages") else { throw Failure(message: String(localized: "Неверный адрес сервера")) }
            var body: [String: Any] = [
                "model": model,
                "max_tokens": 16000,
                "system": system,
                "messages": [["role": "user", "content": transcript]],
            ]
            var request = URLRequest(url: url)
            if fallbackModels.contains(model) {
                // A safety classifier declining a meeting text is rare, but then another model answers.
                body["fallbacks"] = "default"
                request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
            }
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
            return try finish(request, body: body)
        case .openai, .openrouter, .local:
            guard let url = endpoint(baseURL, "/chat/completions") else { throw Failure(message: String(localized: "Неверный адрес сервера")) }
            var body: [String: Any] = [
                "model": model,
                "messages": [["role": "system", "content": system], ["role": "user", "content": transcript]],
            ]
            // OpenRouter then says what the request cost.
            if provider == .openrouter { body["usage"] = ["include": true] }
            var request = URLRequest(url: url)
            if let key, !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
            if provider == .openrouter {
                // OpenRouter's app attribution: the public project, nothing about the user.
                request.setValue("https://github.com/ProteinR/MeetRec", forHTTPHeaderField: "HTTP-Referer")
                request.setValue("MeetRec", forHTTPHeaderField: "X-Title")
            }
            return try finish(request, body: body)
        }
    }

    private static func finish(_ request: URLRequest, body: [String: Any]) throws -> URLRequest {
        var request = request
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        // A long meeting on a slow local model takes minutes.
        request.timeoutInterval = 600
        return request
    }

    static func parse(provider: SummaryProvider, status: Int, data: Data) throws -> Answer {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(status) else {
            let error = json?["error"]
            let message = (error as? [String: Any])?["message"] as? String ?? error as? String
                ?? String(data: data.prefix(300), encoding: .utf8) ?? ""
            throw Failure(message: describe(status: status, message: message))
        }
        guard let json else { throw Failure(message: String(localized: "Сервис вернул не JSON")) }
        switch provider {
        case .anthropic:
            let stop = json["stop_reason"] as? String
            if stop == "refusal" { throw Failure(message: String(localized: "Модель отказалась писать резюме")) }
            let blocks = json["content"] as? [[String: Any]] ?? []
            let text = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
            let usage = json["usage"] as? [String: Any]
            return Answer(text: text, model: json["model"] as? String,
                          inputTokens: number(usage?["input_tokens"]), outputTokens: number(usage?["output_tokens"]),
                          truncated: stop == "max_tokens")
        case .openai, .openrouter, .local:
            let choice = (json["choices"] as? [[String: Any]])?.first
            let text = (choice?["message"] as? [String: Any])?["content"] as? String ?? ""
            let usage = json["usage"] as? [String: Any]
            return Answer(text: text, model: json["model"] as? String,
                          inputTokens: number(usage?["prompt_tokens"]), outputTokens: number(usage?["completion_tokens"]),
                          reportedCost: (usage?["cost"] as? NSNumber)?.doubleValue,
                          truncated: choice?["finish_reason"] as? String == "length")
        }
    }

    private static func number(_ value: Any?) -> Int { (value as? NSNumber)?.intValue ?? 0 }

    private static func describe(status: Int, message: String) -> String {
        switch status {
        case 401, 403: String(localized: "Ключ API не подошёл (\(status)): \(message)")
        case 404: String(localized: "Модель или адрес не найдены (404): \(message)")
        case 429: String(localized: "Слишком много запросов или кончился баланс (429): \(message)")
        default: String(localized: "Ошибка сервиса (\(status)): \(message)")
        }
    }

    /// Sends one request.
    static func send(_ request: URLRequest, provider: SummaryProvider) async throws -> Answer {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            if provider == .local {
                throw Failure(message: String(localized: "Локальный сервер не отвечает (\(request.url?.host ?? "")): \(error.localizedDescription)"))
            }
            throw Failure(message: error.localizedDescription)
        }
        return try parse(provider: provider, status: (response as? HTTPURLResponse)?.statusCode ?? 0, data: data)
    }

    /// The provider's models for the picker in settings (loading them also checks the key):
    /// a readable name where the service gives one ("Claude Opus 5.5"), else the id.
    static func models(provider: SummaryProvider, baseURL: String, key: String?) async throws -> [SummaryModel] {
        guard let url = endpoint(baseURL, "/models") else { throw Failure(message: String(localized: "Неверный адрес сервера")) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        switch provider {
        case .anthropic:
            request.url = URL(string: url.absoluteString + "?limit=100")
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
        default:
            if let key, !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        }
        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            if provider == .local {
                throw Failure(message: String(localized: "Локальный сервер не отвечает (\(request.url?.host ?? "")): \(error.localizedDescription)"))
            }
            throw Failure(message: error.localizedDescription)
        }
        return try parseModels(provider: provider, status: (response as? HTTPURLResponse)?.statusCode ?? 0, data: data)
    }

    static func parseModels(provider: SummaryProvider, status: Int, data: Data) throws -> [SummaryModel] {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(status) else {
            let message = (json?["error"] as? [String: Any])?["message"] as? String ?? ""
            throw Failure(message: describe(status: status, message: message))
        }
        var models = (json?["data"] as? [[String: Any]] ?? []).compactMap { item -> SummaryModel? in
            guard let id = item["id"] as? String else { return nil }
            let name = (item["display_name"] as? String) ?? (item["name"] as? String) ?? id
            return SummaryModel(id: id, name: name.isEmpty ? id : name)
        }
        switch provider {
        case .anthropic:
            break // newest first, as the API lists them
        case .openai:
            // OpenAI lists speech, image and embedding models too.
            let skip = ["embedding", "tts", "whisper", "dall-e", "moderation", "audio", "realtime", "transcribe", "image",
                        "search", "davinci", "babbage", "sora", "codex"]
            models = models.filter { model in !skip.contains { model.id.contains($0) } }
                .sorted { $0.id.localizedStandardCompare($1.id) == .orderedDescending }
        case .openrouter, .local:
            models.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        return models
    }

    /// The instructions: the transcript's format, what to write and in which language.
    static func systemPrompt(myName: String, language: String) -> String {
        """
        You summarize meeting and call transcripts for the person who recorded them.

        The transcript is Markdown made by local speech recognition. Lines look like \
        "[hh:mm:ss] Name: text"; when one person speaks the whole time, lines are "[hh:mm:ss] text" and \
        the header's "- Speaker:" names them. "Speaker N" is a person whose name is unknown. The person who \
        recorded is \(myName.isEmpty ? "the speaker who talks into the microphone" : "\"\(myName)\""). \
        Lines with ⭐ are moments they marked as important during the meeting; lines with 🔇 are \
        times their microphone was muted; ⏸ is a pause in the recording. Recognition makes mistakes: \
        infer what was meant and never quote garbled words.

        Write the summary in \(language). Output only Markdown, without a preamble and without a \
        title. Structure:

        A short paragraph (2–4 sentences): what the meeting was about and how it ended.

        ### Key points
        Bullets with the main topics, facts and numbers that came up.

        ### Decisions
        Bullets; leave the section out if nothing was decided.

        ### Action items
        Bullets "**Who**: what" with a deadline if one was named; leave the section out if there are none.

        ### Open questions
        Leave the section out if there are none.

        Translate these section titles into the language of the summary. Use the people's names as \
        they appear in the transcript. Mention a ⭐ moment with its time when it matters. Be concise: \
        about 15 bullets in total for an hour, fewer for a short call. Do not invent anything that \
        was not said.
        """
    }
}
