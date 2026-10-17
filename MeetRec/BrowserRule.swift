import Foundation

/// "If a browser tab titled like this has a call, record it without asking", e.g. "Vimbox" → "Skyeng".
struct BrowserRule: Codable, Identifiable, Equatable {
    var id = UUID()
    /// Text looked for in browser window titles (the active tab), case-insensitive; several
    /// separated by commas ("Vimbox, Skysmart": the same lessons show either).
    var keyword: String
    /// Put into the file name after the timestamp; empty keeps just the date.
    var title: String
    /// A one-on-one call (a lesson): in the transcript everyone not heard through the microphone is
    /// one person, even when diarization split them because their voice changed with the connection.
    var oneOther: Bool? = nil

    var keywords: [String] {
        keyword.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    func matches(_ title: String) -> Bool {
        keywords.contains { title.localizedCaseInsensitiveContains($0) }
    }

    /// The saved rules, for code without the model (the transcriber).
    static func saved() -> [BrowserRule] {
        let json = UserDefaults.standard.string(forKey: "browserAutoRules") ?? ""
        return (try? JSONDecoder().decode([BrowserRule].self, from: Data(json.utf8))) ?? []
    }
}
