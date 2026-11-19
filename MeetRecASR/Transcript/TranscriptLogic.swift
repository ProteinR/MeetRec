// What turns recognised words and speaker turns into a transcript. Pure functions on numbers and
// text, no models: unit tests compile this folder too (Tests/MeetRecTests/TranscriptTests.swift).
// Ported from the earlier Python helper (`transcribe.py`, removed on 2026-11-17) without changes
// in behaviour.
import Foundation

let sampleRate = 16000
let frameSeconds = 0.05

struct Word: Equatable {
    var start: Double
    var end: Double
    var text: String
}

struct Segment: Equatable {
    var start: Double
    var end: Double
    var text: String
    /// nil: the segment counts as one word.
    var words: [Word]?

    var wordList: [Word] { words ?? [Word(start: start, end: end, text: text)] }
}

struct Turn: Equatable {
    var start: Double
    var end: Double
    var speaker: String
}

/// Loudness in dB of each 0.05 s of the microphone and of the system audio.
struct Levels {
    var microphone: [Double]
    var system: [Double]
}

struct Score: Equatable {
    var name: String?
    var score: Double
    var microphone: Double?
}

// MARK: - Messages

/// MeetRec passes its UI language (MEETREC_LANGUAGE: "ru" or "en"); messages and the marker lines
/// in the transcript follow it. Russian when unset.
let englishUI = ProcessInfo.processInfo.environment["MEETREC_LANGUAGE"]?.hasPrefix("en") ?? false

func tr(_ russian: String, _ english: String) -> String {
    englishUI ? english : russian
}

/// A line for the log: MeetRec writes the helper's stderr there.
func log(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

// MARK: - Text helpers

func trimmed(_ text: String) -> String {
    text.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Python's `" ".join(text.split())`.
func collapsed(_ text: String) -> String {
    text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
}

func matches(_ pattern: String, _ text: String) -> Bool {
    text.range(of: pattern, options: .regularExpression) != nil
}

func removing(_ pattern: String, from text: String) -> String {
    text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
}

func formatTime(_ seconds: Double) -> String {
    let s = Int(seconds)
    return String(format: "%02d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60)
}

func capitalized(_ text: String) -> String {
    guard let first = text.first else { return text }
    return first.uppercased() + text.dropFirst()
}

func rounded(_ value: Double, _ places: Double) -> Double {
    let scale = pow(10, places)
    return (value * scale).rounded() / scale
}

// MARK: - Audio tracks and the user's own track

/// Positions of the microphone and system audio among the audio streams, as far as known.
///
/// MeetRec writes [system, microphone]; after a recording it puts a mix of both first, the only
/// default stream: [mix, microphone, system]. A single stream (one source was off) is unknown.
func streamRoles(_ streams: [Bool]) -> (microphone: Int, system: Int)? {
    if streams.count >= 3 && !streams.allSatisfy({ $0 }) {
        let separate = streams.indices.filter { !streams[$0] }
        if separate.count >= 2 { return (separate[0], separate[1]) }
    }
    if streams.count == 2 { return (1, 0) }
    return nil
}

/// Loudness (dB) of each 0.05 s of 16 kHz samples.
func frameLevels(_ audio: [Float]) -> [Double] {
    let size = Int(Double(sampleRate) * frameSeconds)
    let count = audio.count / size
    var levels = [Double](repeating: 0, count: count)
    audio.withUnsafeBufferPointer { samples in
        for frame in 0..<count {
            var sum = 0.0
            for i in frame * size..<(frame + 1) * size {
                let x = Double(samples[i])
                sum += x * x
            }
            levels[frame] = 20 * log10((sum / Double(size)).squareRoot() + 1e-9)
        }
    }
    return levels
}

// With headphones the microphone hears only the user and the system audio only the other side, so
// the two are transcribed apart: the user's speech (a few minutes of a meeting) in pieces, everyone
// else with diarization. No guessing who said what, also when people speak at once. Through the
// Mac's speakers the microphone hears the others too (ScreenCaptureKit gives the raw microphone):
// then the mixed way with per-word guessing is used.

let echoLimit = 0.25

/// Share of the other side's speech that is also heard in the microphone: near 0 with headphones
/// (only when the user talks at the same time), high through speakers (echo).
func echoRatio(_ microphone: [Double], _ system: [Double], speech: Double = -40, heard: Double = -45) -> Double {
    let count = min(microphone.count, system.count)
    let talking = (0..<count).filter { system[$0] > speech }
    if talking.isEmpty { return 0 }
    return Double(talking.filter { microphone[$0] > heard }.count) / Double(talking.count)
}

/// (start, end) seconds of the user's speech in the microphone track: loud frames, joined over
/// pauses shorter than `gap`, `pad` added at both ends so no word is cut; pieces with less than
/// `minSpeech` of sound (a cough, a click) are left out.
func speechChunks(_ microphone: [Double], frame: Double = frameSeconds, threshold: Double = -45, gap: Double = 1.5,
                  pad: Double = 0.3, minSpeech: Double = 0.3) -> [(Double, Double)] {
    var chunks: [(start: Double, end: Double, voiced: Double)] = []
    for (i, level) in microphone.enumerated() where level > threshold {
        let start = Double(i) * frame, end = Double(i + 1) * frame
        if let last = chunks.last, start - last.end <= gap {
            chunks[chunks.count - 1].end = end
            chunks[chunks.count - 1].voiced += frame
        } else {
            chunks.append((start, end, frame))
        }
    }
    let total = Double(microphone.count) * frame
    return chunks.filter { $0.voiced >= minSpeech }.map { (max($0.start - pad, 0), min($0.end + pad, total)) }
}

// MARK: - Recognised words

let fillers: Set<String> = ["uh", "um", "uhm", "umm", "erm", "eh", "ah", "э", "ээ", "эм", "эээ"]

/// Hesitations Parakeet writes down ("uh", "um", "эм").
func isFiller(_ text: String) -> Bool {
    fillers.contains(removing("[^\\w]+", from: text.lowercased()))
}

/// MeetRecASR's (text, start, end) as words, hesitations left out (a sentence end or comma they
/// carried goes to the word before), and "<unk>": a character missing from Parakeet's vocabulary,
/// mostly quotes («сохранить»).
func withoutFillers(_ raw: [(text: String, start: Double, end: Double)]) -> [Word] {
    var words: [Word] = []
    for item in raw {
        let text = item.text.replacingOccurrences(of: "<unk>", with: "")
        if text.isEmpty { continue }
        if isFiller(text) {
            let ending = removing("^[\\w'’-]+", from: text)
            if !words.isEmpty, !ending.isEmpty, !matches("[.,?!…]$", words[words.count - 1].text) {
                words[words.count - 1].text += ending
            }
            continue
        }
        words.append(Word(start: item.start, end: item.end, text: text))
    }
    return words
}

/// Words in phrases: a new one after a sentence end, a pause or `longest` seconds. Each word of a
/// phrase gets a leading space, as the transcript joins them.
func phrases(_ words: [Word], pause: Double = 0.8, longest: Double = 30) -> [Segment] {
    var segments: [Segment] = []
    for word in words {
        var startsPhrase = true
        if let last = segments.last, let lastWord = last.words?.last {
            startsPhrase = word.start - last.end > pause || word.start - last.start > longest
                || matches("[.?!…]$", trimmed(lastWord.text))
        }
        if startsPhrase { segments.append(Segment(start: word.start, end: word.end, text: "", words: [])) }
        segments[segments.count - 1].words!.append(Word(start: word.start, end: word.end, text: " " + word.text))
        segments[segments.count - 1].end = word.end
    }
    for i in segments.indices {
        segments[i].text = trimmed(segments[i].words!.map(\.text).joined())
    }
    return segments
}

/// Parakeet does not say which language it heard: "ru" when most letters are Cyrillic, else "en".
func guessLanguage(_ segments: [Segment]) -> String {
    var cyrillic = 0, latin = 0
    for segment in segments {
        for scalar in segment.text.lowercased().unicodeScalars {
            if ("а"..."я").contains(scalar) || scalar == "ё" { cyrillic += 1 }
            if ("a"..."z").contains(scalar) { latin += 1 }
        }
    }
    return cyrillic > latin ? "ru" : "en"
}

// MARK: - The user's pieces, joined

/// Long enough that word times (±0.5 s) tell the pieces apart.
let joinPause = 2.0

struct Place: Equatable {
    var start: Double
    var joined: Double
    var length: Double
}

/// Where each piece goes when the pieces are put one after another with `silence` between them.
func joinedChunks(_ chunks: [(Double, Double)], silence: Double = joinPause) -> [Place] {
    var places: [Place] = []
    var at = 0.0
    for (start, end) in chunks {
        places.append(Place(start: start, joined: at, length: end - start))
        at += end - start + silence
    }
    return places
}

/// Index of the piece a time in the joined audio belongs to; in a pause, the nearer piece (a word
/// may start or end a little inside the pause).
func pieceOf(_ t: Double, _ places: [Place]) -> Int {
    for (index, place) in places.enumerated() where t < place.joined + place.length {
        if index > 0 && t < place.joined {
            let previousEnd = places[index - 1].joined + places[index - 1].length
            return t - previousEnd < place.joined - t ? index - 1 : index
        }
        return index
    }
    return places.count - 1
}

/// A time in the joined audio back in the recording (in piece `index`, else the nearest one).
func recordingTime(_ t: Double, _ places: [Place], index: Int? = nil) -> Double {
    guard !places.isEmpty else { return t }
    let place = places[index ?? pieceOf(t, places)]
    return place.start + min(max(t - place.joined, 0), place.length)
}

/// One phrase per piece of the user's speech, times back in the recording. Recognition joins
/// neighbouring pieces into one phrase ("Hi." at 0:05 and "Okay, thank you." at 0:50), so a phrase is
/// cut where its words change piece; and it splits one piece into several ("Okay." "Okay." "Okay."),
/// so those are joined again, and someone else's words said at that moment cannot get between them.
func splitByPiece(_ segments: [Segment], _ places: [Place]) -> [Segment] {
    var groups: [(index: Int, words: [Word])] = []
    for segment in segments {
        for word in segment.wordList {
            let index = pieceOf((word.start + word.end) / 2, places)
            if groups.last?.index != index { groups.append((index, [])) }
            groups[groups.count - 1].words.append(Word(start: recordingTime(word.start, places, index: index),
                                                       end: recordingTime(word.end, places, index: index), text: word.text))
        }
    }
    return groups.map { group in
        Segment(start: group.words[0].start, end: group.words[group.words.count - 1].end,
                text: collapsed(group.words.map(\.text).joined()), words: group.words)
    }
}

// MARK: - Loops

/// "Okay. Okay. Okay." is speech; the same word more times in a row is a loop.
let maxRepeat = 5

func wordKey(_ text: String) -> String {
    removing("[\\W_]+", from: text.lowercased())
}

func loopingWord(_ text: String) -> Bool {
    matches("(.{1,4}?)\\1{8,}", trimmed(text))
}

/// Recognition sometimes loops on unclear audio and writes one word hundreds of times ("dot dot
/// dot…", "1,1,1,1…"). Runs of the same word longer than `maxRepeat`, and words that are one short
/// piece repeated, are left out (and logged); the rest of the segment stays.
func withoutLoops(_ segments: [Segment]) -> [Segment] {
    var result: [Segment] = []
    for segment in segments {
        guard let words = segment.words, !words.isEmpty else {
            result.append(segment)
            continue
        }
        var kept: [Word] = []
        var i = 0
        while i < words.count {
            let key = wordKey(words[i].text)
            var j = i
            while j + 1 < words.count && !key.isEmpty && wordKey(words[j + 1].text) == key { j += 1 }
            let run = words[i...j]
            if run.count > maxRepeat {
                log("Left out a loop at \(formatTime(run.first!.start)): '\(trimmed(run.first!.text))' × \(run.count)")
            } else {
                for word in run {
                    if loopingWord(word.text) {
                        log("Left out a looping word at \(formatTime(word.start)): '\(trimmed(word.text).prefix(30))'…")
                    } else {
                        kept.append(word)
                    }
                }
            }
            i = j + 1
        }
        if !kept.isEmpty {
            result.append(Segment(start: kept[0].start, end: kept[kept.count - 1].end,
                                  text: collapsed(kept.map(\.text).joined()), words: kept))
        }
    }
    return result
}

// MARK: - Speakers

func cosine(_ a: [Double], _ b: [Double]) -> Double {
    var dot = 0.0, na = 0.0, nb = 0.0
    for (x, y) in zip(a, b) { dot += x * y }
    for x in a { na += x * x }
    for y in b { nb += y * y }
    let norm = (na * nb).squareRoot()
    return norm > 0 ? dot / norm : 0
}

/// Each diarized speaker named after the closest enrolled voice when it is at least `threshold`
/// alike, else "Speaker N"; and how alike the closest voice was.
func matchSpeakers(_ embeddings: [String: [Double]], _ references: [String: [[Double]]],
                   threshold: Double) -> (names: [String: String], scores: [String: Score]) {
    var names: [String: String] = [:], scores: [String: Score] = [:]
    for label in embeddings.keys.sorted() {
        let embedding = embeddings[label]!
        var bestName: String?, bestScore = -1.0
        for name in references.keys.sorted() {
            guard let score = references[name]!.map({ cosine(embedding, $0) }).max() else { continue }
            if score > bestScore { (bestName, bestScore) = (name, score) }
        }
        scores[label] = Score(name: bestName, score: rounded(bestScore, 3))
        if let bestName, bestScore >= threshold { names[label] = bestName }
    }
    for (i, label) in embeddings.keys.filter({ names[$0] == nil }).sorted().enumerated() {
        names[label] = "Speaker \(i + 1)"
    }
    return (names, scores)
}

/// (frames, frames heard through the user's microphone) between start and end: sound clearly
/// louder in the microphone track than in the system audio.
func microphoneFrames(_ start: Double, _ end: Double, _ levels: Levels, margin: Double = 6,
                      floor: Double = -50) -> (total: Int, microphone: Int) {
    let first = Int(start / frameSeconds)
    let last = min(Int(end / frameSeconds), levels.microphone.count, levels.system.count)
    guard first < last else { return (max(last - first, 0), 0) }
    var mic = 0
    for i in first..<last where levels.microphone[i] > floor && levels.microphone[i] > levels.system[i] + margin {
        mic += 1
    }
    return (last - first, mic)
}

/// For each diarized speaker: the share of their speaking time that comes through the user's
/// microphone, and their seconds of speech.
func microphoneShares(_ turns: [Turn], _ levels: Levels) -> [String: (share: Double, seconds: Double)] {
    var stats: [String: (total: Int, microphone: Int)] = [:]
    for turn in turns {
        let frames = microphoneFrames(turn.start, turn.end, levels)
        let before = stats[turn.speaker] ?? (0, 0)
        stats[turn.speaker] = (before.total + frames.total, before.microphone + frames.microphone)
    }
    return stats.mapValues { ($0.total > 0 ? Double($0.microphone) / Double($0.total) : 0, Double($0.total) * frameSeconds) }
}

/// A recognised phrase heard mostly through the user's microphone: the user said it, even when
/// diarization put it with someone else (the Teams echo test plays the user's voice back).
func spokenIntoMicrophone(_ start: Double, _ end: Double, _ levels: Levels, minShare: Double = 0.6) -> Bool {
    let frames = microphoneFrames(start, end, levels)
    return frames.total > 0 && Double(frames.microphone) / Double(frames.total) >= minShare
}

/// A word heard mostly through the user's microphone. A word's time is often longer than the sound
/// itself, so only frames where anything is heard count.
func wordSpokenIntoMicrophone(_ word: Word, _ levels: Levels, margin: Double = 6, floor: Double = -50,
                              minShare: Double = 0.6) -> Bool {
    let first = Int(word.start / frameSeconds)
    let last = min(Int(word.end / frameSeconds), levels.microphone.count, levels.system.count)
    var audible = 0, mic = 0
    if first < last {
        for i in first..<last where max(levels.microphone[i], levels.system[i]) > floor {
            audible += 1
            if levels.microphone[i] > floor && levels.microphone[i] > levels.system[i] + margin { mic += 1 }
        }
    }
    return mic >= 2 && Double(mic) / Double(audible) >= minShare
}

/// Speakers heard through the user's microphone are the user, whatever their voice matched.
/// Anyone else who matched the user's voice becomes an unnamed speaker. Returns new names and the
/// labels taken as the user.
func nameMicrophoneSpeakers(_ names: [String: String], _ shares: [String: (share: Double, seconds: Double)],
                            me: String, minShare: Double = 0.6,
                            minSeconds: Double = 1) -> (names: [String: String], mine: Set<String>) {
    let mine = Set(shares.filter { $0.value.share >= minShare && $0.value.seconds >= minSeconds }.keys)
    if me.isEmpty || mine.isEmpty { return (names, []) }
    var result = names
    var taken = Set(names.values.filter { $0.hasPrefix("Speaker ") })
    var number = 1
    for label in names.keys.sorted() {
        if mine.contains(label) {
            result[label] = me
        } else if names[label] == me {
            while taken.contains("Speaker \(number)") { number += 1 }
            result[label] = "Speaker \(number)"
            taken.insert("Speaker \(number)")
        }
    }
    return (result, mine)
}

/// A one-on-one call (a lesson): everyone who is not the user is the one other person, even when
/// diarization split them (a voice changes when the connection gets worse). They take the name of
/// whoever of them was recognised by voice, else of the one who spoke most; the user stays as is.
func mergeOtherSide(_ names: [String: String], _ speaking: [String: Double], me: String) -> [String: String] {
    let others = names.keys.sorted().filter { !(!me.isEmpty && names[$0] == me) }
        .enumerated().sorted { a, b in
            let sa = speaking[a.element] ?? 0, sb = speaking[b.element] ?? 0
            return sa != sb ? sa > sb : a.offset < b.offset
        }.map(\.element)
    if others.count < 2 { return names }
    let known = others.filter { !names[$0]!.hasPrefix("Speaker ") }
    let name = known.first.map { names[$0]! } ?? "Speaker 1"
    var result = names
    for label in others { result[label] = name }
    return result
}

/// Diarization sometimes splits one voice: a second cluster made of short pieces, often where the
/// user talks over them and the call app changes their sound, matches nobody. When exactly one
/// person of the other side was recognised by voice, an unnamed speaker with less than `maxShare`
/// of the other side's speech is taken as that person (a Teams one-on-one, 2026-10-28).
///
/// A small cluster can also match someone else by a weak margin: FluidAudio gave 0.4 min of one
/// voice to another person at 0.80 (2026-11-17). So a recognised name with less than `maxShare` of
/// the speech and a match below `sure` does not count as a second person and is merged as well.
func mergeStrayVoices(_ names: [String: String], _ speaking: [String: Double], me: String, maxShare: Double = 0.2,
                      scores: [String: Double] = [:], sure: Double = 0.9) -> [String: String] {
    let others = names.keys.filter { !(!me.isEmpty && names[$0] == me) }
    let total = others.reduce(0) { $0 + (speaking[$1] ?? 0) }
    func small(_ label: String) -> Bool { (speaking[label] ?? 0) < maxShare * total }
    func weak(_ label: String) -> Bool {
        names[label]!.hasPrefix("Speaker ") || (small(label) && (scores[label] ?? 1) < sure)
    }
    let known = Set(others.filter { !weak($0) }.map { names[$0]! })
    guard known.count == 1, let name = known.first else { return names }
    var result = names
    for label in others where weak(label) && small(label) { result[label] = name }
    return result
}

/// The speaker of the closest turn at most `within` seconds away: a short phrase in a gap
/// between turns (FluidAudio's turns are tight) is still speech.
func nearestSpeaker(_ start: Double, _ end: Double, _ turns: [Turn], within: Double = .infinity) -> String? {
    var best: String?, distance = within
    for turn in turns {
        let gap = max(turn.start - end, start - turn.end, 0)
        if gap <= distance { (best, distance) = (turn.speaker, gap) }
    }
    return best
}

/// The speaker whose turn overlaps start…end most.
func assignSpeaker(_ start: Double, _ end: Double, _ turns: [Turn]) -> String? {
    var best: String?, overlap = 0.0
    for turn in turns {
        let value = min(end, turn.end) - max(start, turn.start)
        if value > overlap { (best, overlap) = (turn.speaker, value) }
    }
    return best
}

/// The other side's speakers: whoever matched the user's voice there (the Teams echo test plays
/// it back) becomes an unnamed speaker.
func withoutMe(_ names: [String: String], me: String) -> [String: String] {
    if me.isEmpty { return names }
    var result = names
    var taken = Set(names.values)
    var number = 1
    for label in names.keys.sorted() where names[label] == me {
        while taken.contains("Speaker \(number)") { number += 1 }
        result[label] = "Speaker \(number)"
        taken.insert("Speaker \(number)")
    }
    return result
}

// MARK: - Lines

/// A word with its speaker. `group` tells which recognised phrase it came from.
struct NamedWord {
    var start: Double
    var end: Double
    var name: String
    var text: String
    var mine: Bool
    var group: Int
}

/// Each word of a segment with its speaker. A word heard mostly through the microphone is the
/// user's (mine); otherwise it goes to the diarized speaker it overlaps most, else the segment's.
func wordNames(_ segment: Segment, group: Int, label: String?, _ turns: [Turn], _ names: [String: String],
               me: String = "", levels: Levels? = nil) -> [NamedWord] {
    segment.wordList.map { word in
        let mine = !me.isEmpty && levels.map { wordSpokenIntoMicrophone(word, $0) } == true
        let wordLabel = assignSpeaker(word.start, word.end, turns) ?? label
        let name = mine || wordLabel == nil ? me : names[wordLabel!] ?? wordLabel!
        return NamedWord(start: word.start, end: word.end, name: name, text: word.text, mine: mine, group: group)
    }
}

/// Index ranges of consecutive words of one speaker.
func speakerRuns(_ words: [NamedWord]) -> [Range<Int>] {
    var runs: [Range<Int>] = []
    for i in words.indices {
        if let last = runs.last, words[last.lowerBound].name == words[i].name {
            runs[runs.count - 1] = last.lowerBound..<(i + 1)
        } else {
            runs.append(i..<(i + 1))
        }
    }
    return runs
}

/// Diarization at word level makes slips at the edges of turns; one or two words not from the
/// microphone and not a sentence of their own (a reply "Yes." between two sentences of someone else
/// stays) are moved:
/// - between two runs of the same speaker, back to them ("Julius: ok but are / Dima: you finished /
///   Julius: in this branch?");
/// - after a finished sentence and before someone else's words that go on the sentence (lower
///   case, same phrase), to them: the next speaker's first word left with the previous one
///   ("Julius: …reinfolgen. / Falk: Das / Julius: ist ja praktisch…").
func smoothShortRuns(_ words: inout [NamedWord], maxWords: Int = 2) {
    func movable(_ run: Range<Int>) -> Bool {
        run.count <= maxWords && !run.contains { words[$0].mine } && !endsSentence(words[run.upperBound - 1].text)
    }
    var runs = speakerRuns(words)
    if runs.count >= 3 {
        for i in 1..<(runs.count - 1) {
            let run = runs[i], before = words[runs[i - 1].upperBound - 1], after = words[runs[i + 1].lowerBound]
            if movable(run) && before.name == after.name && after.name != words[run.lowerBound].name && !endsSentence(before.text) {
                for j in run { words[j].name = before.name }
            }
        }
    }
    runs = speakerRuns(words)
    if runs.count >= 3 {
        for i in 1..<(runs.count - 1) {
            let run = runs[i], before = words[runs[i - 1].upperBound - 1], after = words[runs[i + 1].lowerBound]
            if movable(run) && endsSentence(before.text) && trimmed(after.text).first?.isLowercase == true
                && words[run.upperBound - 1].group == after.group {
                for j in run { words[j].name = after.name }
            }
        }
    }
}

/// A new line of the same speaker after this pause, or once the line is this long and a sentence
/// ends: a long monologue as one line gave a 5-minute speech one time, [00:00:00] (2026-11-20).
let linePause = 5.0
let lineLongest = 60.0
/// When only one person speaks, lines follow the phrases more closely: the times are what tells
/// which moment of the video "this one here" means.
let monologuePause = 2.0
let monologueLongest = 20.0

func endsSentence(_ text: String) -> Bool {
    matches("[.?!…]$", trimmed(text))
}

/// A speaker's words joined into one line until someone else speaks, they pause for `pause` seconds,
/// or the line is `longest` seconds long and a sentence ends. A line starts with a capital: a phrase
/// cut by a pause goes on in lower case ("then I have to…"). Without `named` lines have no name.
func joinLines(_ words: [NamedWord], pause: Double = linePause, longest: Double = lineLongest,
               named: Bool = true) -> [(start: Double, text: String)] {
    var lines: [(start: Double, name: String, text: String)] = []
    var previous: NamedWord?
    for word in words {
        if let last = lines.last, let previous, last.name == word.name, word.start - previous.end <= pause,
           !(word.start - last.start >= longest && endsSentence(previous.text)) {
            lines[lines.count - 1].text += " " + word.text
        } else {
            lines.append((word.start, word.name, word.text))
        }
        previous = word
    }
    return lines.map { line in
        let text = capitalized(collapsed(line.text))
        return (line.start, named ? "[\(formatTime(line.start))] \(line.name): \(text)" : "[\(formatTime(line.start))] \(text)")
    }
}

/// The one person who speaks in the whole recording, when they have a name ("Speaker 1" stays on
/// every line so it can still be named in the transcript).
func soleSpeaker(_ words: [NamedWord]) -> String? {
    let names = Set(words.map(\.name))
    guard names.count == 1, let name = names.first, !name.isEmpty, !name.hasPrefix("Speaker ") else { return nil }
    return name
}

/// Lines of a conversation, or of a monologue: then without the name (it goes to the header) and
/// cut closer, at phrases.
func speakerLines(_ words: [NamedWord]) -> (lines: [(start: Double, text: String)], sole: String?) {
    if let sole = soleSpeaker(words) {
        return (joinLines(words, pause: monologuePause, longest: monologueLongest, named: false), sole)
    }
    return (joinLines(words), nil)
}

/// Transcript lines, a speaker's words joined until someone else speaks; with the user's name and
/// the microphone/system levels, words spoken into the microphone are the user's. A phrase outside
/// every turn goes to the nearest speaker (at most `near` seconds away, else it is dropped):
/// Parakeet does not write text into silence, and FluidAudio's turns leave short phrases
/// ("Let me check.") outside (2026-11-17).
func buildLines(_ segments: [Segment], _ turns: [Turn], _ names: [String: String], me: String = "",
                levels: Levels? = nil, near: Double = .infinity) -> (lines: [(start: Double, text: String)], dropped: Int, sole: String?) {
    var words: [NamedWord] = [], dropped = 0
    for (index, segment) in segments.enumerated() {
        let label = assignSpeaker(segment.start, segment.end, turns) ?? nearestSpeaker(segment.start, segment.end, turns, within: near)
        if label == nil && !(!me.isEmpty && levels.map { spokenIntoMicrophone(segment.start, segment.end, $0) } == true) {
            dropped += 1
            continue
        }
        words += wordNames(segment, group: index, label: label, turns, names, me: me, levels: levels)
    }
    smoothShortRuns(&words)
    let built = speakerLines(words)
    return (built.lines, dropped, built.sole)
}

/// Transcript lines when the user's microphone track was transcribed apart (`mine`): the other
/// side's words get their diarized speakers, the user's words are the user's, and both are put in
/// order of time. A phrase outside every turn goes to a speaker at most `near` seconds away.
func buildSplitLines(_ segments: [Segment], _ mine: [Segment], _ turns: [Turn], _ names: [String: String],
                     me: String, near: Double = .infinity) -> (lines: [(start: Double, text: String)], dropped: Int, sole: String?) {
    var words: [NamedWord] = [], dropped = 0
    for (index, segment) in segments.enumerated() {
        guard let label = assignSpeaker(segment.start, segment.end, turns)
                ?? nearestSpeaker(segment.start, segment.end, turns, within: near) else {
            dropped += 1
            continue
        }
        words += wordNames(segment, group: index, label: label, turns, names)
    }
    // A phrase of the user stays whole: the other side's words said at the same moment (everyone's
    // "bye") follow it instead of cutting it in two.
    var phraseStart: [Int: Double] = [:]
    for (index, segment) in mine.enumerated() {
        let group = segments.count + index
        phraseStart[group] = segment.start
        words += segment.wordList.map { NamedWord(start: $0.start, end: $0.end, name: me, text: $0.text, mine: true, group: group) }
    }
    func key(_ word: NamedWord) -> (Double, Int, Double) {
        if word.mine { return (phraseStart[word.group]!, 0, word.start) }
        let inside = mine.first { $0.start <= word.start && word.start < $0.end }?.start
        return (inside ?? word.start, 1, word.start)
    }
    words = words.enumerated().sorted { a, b in
        let ka = key(a.element), kb = key(b.element)
        return ka != kb ? ka < kb : a.offset < b.offset
    }.map(\.element)
    smoothShortRuns(&words)
    let built = speakerLines(words)
    return (built.lines, dropped, built.sole)
}
