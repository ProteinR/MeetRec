import Foundation

/// What one summary took: model, tokens and money. Kept per recording in `summary.json` in its
/// folder (`<stem>.summary.json` next to a flat recording), one entry per run ("Сделать резюме
/// заново" adds one), and as a line under the summary's heading in the transcript.
struct SummaryUsage: Codable, Equatable {
    var date: Date
    var appVersion: String
    var provider: String
    /// The model that answered (with a refusal fallback, not necessarily the one asked for).
    var model: String
    /// "Claude Opus 5.5" when the provider's list gave a name.
    var modelName: String
    var inputTokens: Int
    var outputTokens: Int
    /// US dollars; nil when the price of the model is not known.
    var costUSD: Double?

    var totalTokens: Int { inputTokens + outputTokens }

    /// "$0.073", "$1.24"; "$0" for a local model.
    static func money(_ value: Double) -> String {
        if value == 0 { return "$0" }
        if value < 0.001 { return "<$0.001" }
        return String(format: value < 1 ? "$%.3f" : "$%.2f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    static func tokens(_ value: Int) -> String { value.formatted(.number.grouping(.automatic)) }

    var costText: String {
        guard let costUSD else { return String(localized: "цена неизвестна") }
        return provider == SummaryProvider.local.rawValue ? String(localized: "локально, бесплатно") : Self.money(costUSD)
    }

    /// The line under "## Резюме" in the transcript (Markdown quote, skipped by the tip's preview).
    var metaLine: String {
        let name = modelName == model ? model : "\(modelName) (\(model))"
        return String(localized: "MeetRec \(appVersion) · \(name) · токены: \(Self.tokens(inputTokens)) на входе, \(Self.tokens(outputTokens)) на выходе · \(costText)")
    }

    /// "Claude Opus 5.5 · токены: 15 042 · $0.073" for the recording's tip.
    var shortText: String {
        String(localized: "\(modelName) · токены: \(Self.tokens(totalTokens)) · \(costText)")
    }
}

enum SummaryUsageFile {
    struct Contents: Codable { var runs: [SummaryUsage] }

    static func url(for recording: URL) -> URL { RecordingFiles.companion("summary.json", of: recording) }

    static func load(for recording: URL) -> [SummaryUsage] {
        guard let data = try? Data(contentsOf: url(for: recording)) else { return [] }
        return (try? decoder.decode(Contents.self, from: data))?.runs ?? []
    }

    static func append(_ usage: SummaryUsage, for recording: URL) throws {
        let runs = load(for: recording) + [usage]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(Contents(runs: runs)).write(to: url(for: recording), options: .atomic)
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// Prices in US dollars per million tokens (input, output).
enum SummaryPricing {
    /// Anthropic's list prices (claude.com/pricing, November 2026). Claude Haiku 5.5 costs more
    /// above 100K input tokens.
    static let anthropic: [String: (input: Double, output: Double)] = [
        "claude-fable-5-2": (8, 40), "claude-fable-5-1": (10, 50), "claude-fable-5": (10, 50),
        "claude-opus-5-5": (4, 20), "claude-opus-5": (5, 25), "claude-opus-4-8": (5, 25),
        "claude-opus-4-7": (5, 25), "claude-opus-4-6": (5, 25), "claude-opus-4-5": (5, 25),
        "claude-sonnet-5-5": (2, 10), "claude-sonnet-5": (2, 10), "claude-sonnet-4-6": (3, 15),
        "claude-sonnet-4-5": (3, 15), "claude-haiku-5-5": (0.10, 0.50), "claude-haiku-4-5": (1, 5),
    ]

    static func anthropicCost(model: String, input: Int, output: Int) -> Double? {
        // Dated ids ("claude-opus-4-5-20251101") cost the same as the plain ones.
        let key = anthropic.keys.sorted { $0.count > $1.count }.first { model == $0 || model.hasPrefix($0 + "-") }
        guard let key, var price = anthropic[key] else { return nil }
        if key == "claude-haiku-5-5" && input > 100_000 { price = (0.50, 2.50) }
        return (Double(input) * price.input + Double(output) * price.output) / 1_000_000
    }

    /// OpenAI does not say what a request cost: its models' prices come from OpenRouter's public
    /// catalog (no key, nothing about the user is sent), loaded once per launch.
    @MainActor private static var catalog: [String: (input: Double, output: Double)]?

    @MainActor static func openAICost(model: String, input: Int, output: Int) async -> Double? {
        if catalog == nil { catalog = await loadCatalog() }
        guard let price = catalog?["openai/" + model] else { return nil }
        return Double(input) * price.input + Double(output) * price.output
    }

    /// Per-token prices by OpenRouter model id.
    private static func loadCatalog() async -> [String: (input: Double, output: Double)] {
        guard let url = URL(string: "https://openrouter.ai/api/v1/models"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        var prices: [String: (input: Double, output: Double)] = [:]
        for item in json["data"] as? [[String: Any]] ?? [] {
            guard let id = item["id"] as? String, let pricing = item["pricing"] as? [String: Any],
                  let input = Double("\(pricing["prompt"] ?? "")"), let output = Double("\(pricing["completion"] ?? "")") else { continue }
            prices[id] = (input, output)
        }
        Log.info("Summary prices: \(prices.count) models from OpenRouter's catalog", "summary")
        return prices
    }
}
