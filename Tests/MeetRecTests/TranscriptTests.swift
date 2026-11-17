import XCTest

/// MeetRecASR's transcript logic (`MeetRecASR/Transcript`, compiled into this test bundle): no
/// models needed.
final class TranscriptTests: XCTestCase {
    private func w(_ start: Double, _ end: Double, _ text: String) -> Word { Word(start: start, end: end, text: text) }
    private func turn(_ start: Double, _ end: Double, _ speaker: String) -> Turn { Turn(start: start, end: end, speaker: speaker) }
    private func texts(_ lines: [(start: Double, text: String)]) -> [String] { lines.map(\.text) }
    private func marker(_ time: Double, _ note: String? = nil) -> TranscriptMarker { TranscriptMarker(time: time, kind: .note(note)) }

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    // MARK: - Times and markers

    func testFormatTime() {
        XCTAssertEqual(formatTime(0), "00:00:00")
        XCTAssertEqual(formatTime(3725.9), "01:02:05")
    }

    func testMarkersGoBeforeTheFirstLineAtOrAfterThem() {
        let lines = [(start: 0.0, text: "[00:00:00] A: hi"), (start: 30.0, text: "[00:00:30] B: yo")]
        XCTAssertEqual(insertMarkers(lines, [marker(10.4), marker(30), marker(99)]), [
            "[00:00:00] A: hi", "⭐ [00:00:10] Отметка", "⭐ [00:00:30] Отметка", "[00:00:30] B: yo", "⭐ [00:01:39] Отметка",
        ])
    }

    func testPauseMarkersGetTheirOwnLine() {
        let lines = [(start: 0.0, text: "[00:00:00] A: hi"), (start: 30.0, text: "[00:00:30] B: yo")]
        XCTAssertEqual(insertMarkers(lines, [marker(20, "Пауза"), marker(10)]), [
            "[00:00:00] A: hi", "⭐ [00:00:10] Отметка", "⏸ [00:00:20] Пауза", "[00:00:30] B: yo",
        ])
    }

    func testNoMarkers() {
        XCTAssertEqual(insertMarkers([(start: 0.0, text: "a")], []), ["a"])
    }

    func testLoadMarkersNextToTheVideo() throws {
        let dir = try folder()
        let video = dir.appendingPathComponent("2026-10-16 14-03-22 Sync.mov")
        XCTAssertEqual(loadMarkers(video), [])
        try #"[{"time": 40}, {"time": 5.5, "note": null}]"#.write(to: dir.appendingPathComponent("2026-10-16 14-03-22 Sync.markers.json"),
                                                                atomically: true, encoding: .utf8)
        XCTAssertEqual(loadMarkers(video), [marker(5.5), marker(40)])
    }

    func testMarkersAndMutesInTheRecordingsFolder() throws {
        let dir = try folder().appendingPathComponent("2026-10-16 14-03-22 Sync", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let video = dir.appendingPathComponent("2026-10-16 14-03-22 Sync.mov")
        try #"[{"time": 7}]"#.write(to: dir.appendingPathComponent("markers.json"), atomically: true, encoding: .utf8)
        try #"[{"start": 10, "end": 30}]"#.write(to: dir.appendingPathComponent("mutes.json"), atomically: true, encoding: .utf8)
        XCTAssertEqual(loadMarkers(video), [marker(7)])
        XCTAssertEqual(loadMutes(video), [TranscriptMarker(time: 10, kind: .mute(end: 30))])
    }

    func testMutesAreJoinedAndShortOnesLeftOut() {
        // 10-12 and 15-30 are one mute (gap 3 s); 100-102 is too short; the last lasts to the end.
        let merged = mergeMutes([(10, 12), (15, 30), (100, 102), (200, nil)])
        XCTAssertEqual(merged.map(\.0), [10, 200])
        XCTAssertEqual(merged.map(\.1), [30, nil])
        // Unmuted for 3 s to say "Okay": two mutes, not one over the word.
        let apart = mergeMutes([(0, 20), (23, 60)], speech: [21])
        XCTAssertEqual(apart.map(\.0), [0, 23])
        XCTAssertEqual(apart.map(\.1), [20, 60])
    }

    func testMutesInTheTranscript() throws {
        let dir = try folder()
        let video = dir.appendingPathComponent("rec.mov")
        try #"[{"start": 61, "end": 88}, {"start": 300}]"#.write(to: dir.appendingPathComponent("rec.mutes.json"),
                                                                 atomically: true, encoding: .utf8)
        let lines = insertMarkers([(start: 0.0, text: "[00:00:00] Dima: Hi"), (start: 90.0, text: "[00:01:30] Falk: So")], loadMutes(video))
        XCTAssertEqual(lines, ["[00:00:00] Dima: Hi", "🔇 [00:01:01–00:01:28] Микрофон выключен",
                               "[00:01:30] Falk: So", "🔇 [00:05:00] Микрофон выключен"])
    }

    func testUnreadableMarkersAreIgnored() throws {
        let dir = try folder()
        try "not json".write(to: dir.appendingPathComponent("rec.markers.json"), atomically: true, encoding: .utf8)
        XCTAssertEqual(loadMarkers(dir.appendingPathComponent("rec.mov")), [])
    }

    // MARK: - Speakers

    func testKnownVoiceGetsItsNameUnknownGetNumbers() {
        let references = ["Dima": [[1.0, 0, 0]], "Elena": [[0, 1.0, 0]]]
        let embeddings = ["SPEAKER_00": [0.9, 0.1, 0], "SPEAKER_01": [0, 0, 1.0], "SPEAKER_02": [0.1, 0.2, 0.9]]
        let (names, scores) = matchSpeakers(embeddings, references, threshold: 0.7)
        XCTAssertEqual(names["SPEAKER_00"], "Dima")
        XCTAssertEqual(Set([names["SPEAKER_01"]!, names["SPEAKER_02"]!]), ["Speaker 1", "Speaker 2"])
        XCTAssertEqual(scores["SPEAKER_00"]?.name, "Dima")
    }

    func testBestOfSeveralSamplesCounts() {
        let (names, _) = matchSpeakers(["S": [1.0, 0.05]], ["Dima": [[0, 1.0], [1.0, 0]]], threshold: 0.7)
        XCTAssertEqual(names["S"], "Dima")
    }

    func testBuildLinesJoinsTurnsOfOneSpeaker() {
        let segments = [
            Segment(start: 0, end: 2, text: "hello"), Segment(start: 2, end: 4, text: "there"),
            Segment(start: 5, end: 6, text: "hi"),
            Segment(start: 20, end: 21, text: "Thank you."), // outside every turn: the nearest speaker
        ]
        let turns = [turn(0, 4.5, "S0"), turn(4.5, 7, "S1")]
        let (lines, dropped) = buildLines(segments, turns, ["S0": "Dima", "S1": "Speaker 1"])
        XCTAssertEqual(texts(lines), ["[00:00:00] Dima: Hello there", "[00:00:05] Speaker 1: Hi Thank you."])
        XCTAssertEqual(dropped, 0)
    }

    // MARK: - Microphone

    func testStreamRoles() {
        XCTAssertEqual(streamRoles([true, false, false]).map { [$0.microphone, $0.system] }, [1, 2])
        XCTAssertEqual(streamRoles([true, true]).map { [$0.microphone, $0.system] }, [1, 0])
        XCTAssertNil(streamRoles([true]))
    }

    func testSpeakerOnTheMicrophoneIsMe() {
        // 0-2 s: loud on the microphone, quiet in the system audio (the user); 2-4 s: the other way round.
        let levels = Levels(microphone: Array(repeating: -25, count: 40) + Array(repeating: -48, count: 40),
                            system: Array(repeating: -80, count: 40) + Array(repeating: -20, count: 40))
        let shares = microphoneShares([turn(0, 2, "A"), turn(2, 4, "B")], levels)
        XCTAssertEqual(shares["A"]!.share, 1, accuracy: 1e-9)
        XCTAssertEqual(shares["B"]!.share, 0, accuracy: 1e-9)
        // The voice match got it the wrong way round: the microphone wins.
        let (names, mine) = nameMicrophoneSpeakers(["A": "Speaker 1", "B": "Dima"], shares, me: "Dima")
        XCTAssertEqual(names, ["A": "Dima", "B": "Speaker 2"])
        XCTAssertEqual(mine, ["A"])
    }

    func testPhraseSpokenIntoTheMicrophoneIsMine() {
        // One diarized speaker says both phrases (the echo test plays the user's voice back): the one
        // heard through the microphone is the user's, the playback stays with the speaker.
        let levels = Levels(microphone: Array(repeating: -25, count: 40) + Array(repeating: -60, count: 40),
                            system: Array(repeating: -80, count: 40) + Array(repeating: -20, count: 40))
        let segments = [Segment(start: 0, end: 2, text: "test"), Segment(start: 2, end: 4, text: "test")]
        let (lines, _) = buildLines(segments, [turn(0, 4, "A")], ["A": "Speaker 1"], me: "Dima", levels: levels)
        XCTAssertEqual(texts(lines), ["[00:00:00] Dima: Test", "[00:00:02] Speaker 1: Test"])
    }

    func testMyWordInsideSomeoneElsesSegmentIsMine() {
        // One segment "Thanks. Bye. Have a nice day." over 0-3 s: the user's "Bye." (1-2 s) is heard
        // through the microphone, the rest is the other side.
        let levels = Levels(microphone: Array(repeating: -80, count: 20) + Array(repeating: -25, count: 20) + Array(repeating: -80, count: 20),
                            system: Array(repeating: -20, count: 20) + Array(repeating: -70, count: 20) + Array(repeating: -20, count: 20))
        let words = [w(0, 1, " Thanks."), w(1, 2, " Bye."), w(2, 2.5, " Have"), w(2.5, 2.8, " a"), w(2.8, 3, " nice day.")]
        let segments = [Segment(start: 0, end: 3, text: "Thanks. Bye. Have a nice day.", words: words)]
        let (lines, _) = buildLines(segments, [turn(0, 3, "A")], ["A": "Falk"], me: "Dima", levels: levels)
        XCTAssertEqual(texts(lines), ["[00:00:00] Falk: Thanks.", "[00:00:01] Dima: Bye.", "[00:00:02] Falk: Have a nice day."])
    }

    func testShortWordWithPaddedTimeIsMine() {
        // "Hi." gets 0.7 s, the voice lasts 0.2 s; the rest of the time is silence.
        let levels = Levels(microphone: Array(repeating: -60, count: 10) + Array(repeating: -15, count: 4) + Array(repeating: -60, count: 10),
                            system: Array(repeating: -90, count: 24))
        let word = w(0.1, 0.8, " Hi.")
        XCTAssertTrue(wordSpokenIntoMicrophone(word, levels))
        XCTAssertFalse(spokenIntoMicrophone(word.start, word.end, levels))
        // The other side's word: loud in the system audio.
        XCTAssertFalse(wordSpokenIntoMicrophone(word, Levels(microphone: Array(repeating: -60, count: 24),
                                                             system: Array(repeating: -20, count: 24))))
    }

    func testWordsFollowDiarizationTurns() {
        let segments = [Segment(start: 0, end: 1.4, text: "Hi. Hello, Falk.",
                                words: [w(0, 0.5, " Hi."), w(0.6, 1, " Hello,"), w(1, 1.4, " Falk.")])]
        let (lines, _) = buildLines(segments, [turn(0, 0.55, "A"), turn(0.55, 1.5, "B")], ["A": "Falk", "B": "Julius"])
        XCTAssertEqual(texts(lines), ["[00:00:00] Falk: Hi.", "[00:00:00] Julius: Hello, Falk."])
    }

    func testALoneWordStaysWithItsNeighbours() {
        // Word times are approximate: one word just over a turn edge is not a change of speaker.
        let segments = [Segment(start: 0, end: 1.5, text: "we can go", words: [w(0, 0.5, " we"), w(0.5, 0.9, " can"), w(0.9, 1.5, " go")])]
        let turns = [turn(0, 0.5, "A"), turn(0.5, 0.9, "B"), turn(0.9, 1.5, "A")]
        XCTAssertEqual(texts(buildLines(segments, turns, ["A": "Falk", "B": "Julius"]).lines), ["[00:00:00] Falk: We can go"])
    }

    private func numbered(_ items: [String]) -> [Word] {
        items.enumerated().map { w(Double($0.offset), Double($0.offset) + 0.9, " " + $0.element) }
    }

    func testASlipMidSentenceGoesBackButAReplyStays() {
        let names = ["A": "Julius", "B": "Dima"]
        // "ok but are | you finished | in this branch?": the middle went to B by mistake.
        var segments = [Segment(start: 0, end: 7, text: "", words: numbered(["ok", "but", "are", "you", "finished", "in", "branch?"]))]
        var turns = [turn(0, 3, "A"), turn(3, 5, "B"), turn(5, 7, "A")]
        XCTAssertEqual(texts(buildLines(segments, turns, names).lines), ["[00:00:00] Julius: Ok but are you finished in branch?"])
        // "Is it done? | Yes. | Good.": a reply of its own stays.
        segments = [Segment(start: 0, end: 5, text: "", words: numbered(["Is", "it", "done?", "Yes.", "Good."]))]
        turns = [turn(0, 3, "A"), turn(3, 4, "B"), turn(4, 5, "A")]
        XCTAssertEqual(texts(buildLines(segments, turns, names).lines),
                       ["[00:00:00] Julius: Is it done?", "[00:00:03] Dima: Yes.", "[00:00:04] Julius: Good."])
    }

    func testTheNextSpeakersFirstWordGoesToThem() {
        let segments = [Segment(start: 0, end: 5, text: "", words: numbered(["Ja.", "Das", "ist", "ja", "praktisch."]))]
        let turns = [turn(0, 1, "B"), turn(1, 2, "A"), turn(2, 5, "B")]
        XCTAssertEqual(texts(buildLines(segments, turns, ["A": "Falk", "B": "Julius"]).lines),
                       ["[00:00:00] Julius: Ja. Das ist ja praktisch."])
    }

    func testMySpeechChunks() {
        // 0.05 s frames: speech 1.0-2.0 s and 2.5-3.0 s (one piece over a short pause), a click at
        // 6.0 s (too short), speech 9.0-10.0 s.
        var mic = [Double](repeating: -60, count: 220)
        for i in Array(20..<40) + Array(50..<60) + [120] + Array(180..<200) { mic[i] = -20 }
        let chunks = speechChunks(mic).map { [rounded($0.0, 2), rounded($0.1, 2)] }
        XCTAssertEqual(chunks, [[0.7, 3.3], [8.7, 10.3]])
    }

    func testEchoRatioTellsHeadphonesFromSpeakers() {
        let system = [Double](repeating: -20, count: 100)
        let headphones = Array(repeating: -60.0, count: 90) + Array(repeating: -20.0, count: 10) // the user talks over the others for a moment
        let speakers = [Double](repeating: -35, count: 100) // the others come back through the microphone
        XCTAssertLessThanOrEqual(echoRatio(headphones, system), echoLimit)
        XCTAssertGreaterThan(echoRatio(speakers, system), echoLimit)
        XCTAssertEqual(echoRatio(headphones, [Double](repeating: -90, count: 100)), 0)
    }

    func testSplitLinesPutBothSidesInTimeOrder() {
        let others = [Segment(start: 0, end: 4, text: "", words: [w(0, 0.5, " So"), w(0.5, 1, " the"), w(1, 1.5, " scanner"), w(3, 4, " works.")])]
        let mine = [Segment(start: 1.6, end: 2.4, text: "In the web?", words: [w(1.6, 1.9, " In"), w(1.9, 2.1, " the"), w(2.1, 2.4, " web?")])]
        let (lines, dropped) = buildSplitLines(others, mine, [turn(0, 4, "A")], ["A": "Falk"], me: "Dima")
        XCTAssertEqual(texts(lines), ["[00:00:00] Falk: So the scanner", "[00:00:01] Dima: In the web?", "[00:00:03] Falk: Works."])
        XCTAssertEqual(dropped, 0)
    }

    func testMyPhraseStaysWholeWhenSomeoneSpeaksAtOnce() {
        let others = [Segment(start: 0, end: 3, text: "", words: [w(0, 0.8, " Thanks."), w(1.3, 1.6, " Bye."), w(2.5, 3, " Bye.")])]
        let mine = [Segment(start: 1, end: 2.2, text: "Have a good day.",
                            words: [w(1, 1.2, " Have"), w(1.2, 1.5, " a"), w(1.5, 1.8, " good"), w(1.8, 2.2, " day.")])]
        let (lines, _) = buildSplitLines(others, mine, [turn(0, 3, "A")], ["A": "Falk"], me: "Dima")
        XCTAssertEqual(texts(lines), ["[00:00:00] Falk: Thanks.", "[00:00:01] Dima: Have a good day.", "[00:00:01] Falk: Bye. Bye."])
    }

    func testJoinedPiecesMapBackToTheRecording() {
        let places = joinedChunks([(10, 12), (30, 31)], silence: 0.5)
        XCTAssertEqual(places, [Place(start: 10, joined: 0, length: 2), Place(start: 30, joined: 2.5, length: 1)])
        XCTAssertEqual(recordingTime(1.5, places), 11.5, accuracy: 1e-9)
        XCTAssertEqual(recordingTime(2.1, places), 12, accuracy: 1e-9) // in the pause, nearer the first piece
        XCTAssertEqual(recordingTime(2.4, places), 30, accuracy: 1e-9) // nearer the second
        XCTAssertEqual(recordingTime(3, places), 30.5, accuracy: 1e-9)
    }

    func testAPhraseOverTwoPiecesIsCutBack() {
        let places = joinedChunks([(5, 6), (50, 52)]) // joined: 0-1, 3-5
        // "Okay," starts in the pause, nearer the first piece, but most of it is in the second.
        let segments = [Segment(start: 0.1, end: 4, text: "Hi. Okay, thank you.",
                                words: [w(0.1, 0.6, " Hi."), w(1.9, 3.4, " Okay,"), w(3.4, 3.6, " thank"), w(3.6, 4, " you.")])]
        let result = splitByPiece(segments, places)
        XCTAssertEqual(result.map { rounded($0.start, 1) }, [5.1, 50])
        XCTAssertEqual(result.map(\.text), ["Hi.", "Okay, thank you."])
    }

    func testPhrasesOfOnePieceAreJoined() {
        let places = joinedChunks([(100, 102)])
        let segments = [Segment(start: 0, end: 0.4, text: "Okay.", words: [w(0, 0.4, " Okay.")]),
                        Segment(start: 0.5, end: 0.9, text: "Okay.", words: [w(0.5, 0.9, " Okay.")])]
        let result = splitByPiece(segments, places)
        XCTAssertEqual(result.map(\.start), [100])
        XCTAssertEqual(result.map(\.text), ["Okay. Okay."])
    }

    func testLoopsAreLeftOut() {
        func words(_ items: [String]) -> [Word] { items.enumerated().map { w(Double($0.offset), Double($0.offset) + 0.5, " " + $0.element) } }
        let segments = [
            Segment(start: 0, end: 60, text: "", words: words(["tabs", "star"] + Array(repeating: "dot", count: 50) + ["STLV", "The"])),
            Segment(start: 0, end: 3, text: "", words: words(["Okay.", "Okay.", "Okay."])),
            Segment(start: 0, end: 3, text: "", words: words(["the", "1,1,1,1,1,1,1,1,1,1,1,1,1,1", "in"])),
        ]
        XCTAssertEqual(withoutLoops(segments).map(\.text), ["tabs star STLV The", "Okay. Okay. Okay.", "the in"])
    }

    func testMyVoiceOnTheOtherSideIsNotMe() {
        XCTAssertEqual(withoutMe(["A": "Dima", "B": "Falk"], me: "Dima"), ["A": "Speaker 1", "B": "Falk"])
    }

    func testOneOtherPersonMergesTheOtherSide() {
        // A lesson: the teacher split in two when her connection got worse.
        var names = ["S0": "Speaker 1", "S1": "Speaker 2", "S2": "Dima", "S3": "Dima"]
        XCTAssertEqual(mergeOtherSide(names, ["S0": 87, "S1": 245, "S2": 151, "S3": 68], me: "Dima"),
                       ["S0": "Speaker 1", "S1": "Speaker 1", "S2": "Dima", "S3": "Dima"])
        // A recognised voice names the whole other side.
        names = ["S0": "Юлия", "S1": "Speaker 1", "S2": "Dima"]
        XCTAssertEqual(mergeOtherSide(names, ["S1": 9, "S0": 1], me: "Dima"), ["S0": "Юлия", "S1": "Юлия", "S2": "Dima"])
        // Nothing to merge.
        names = ["S0": "Speaker 1", "S2": "Dima"]
        XCTAssertEqual(mergeOtherSide(names, [:], me: "Dima"), names)
    }

    func testASmallUnnamedVoiceGoesToTheOneRecognisedPerson() {
        // One voice split in two (2026-10-28): 183 s recognised, 29 s of short pieces unmatched.
        var names = ["S0": "Speaker 1", "S1": "Anna", "S2": "Dima"]
        XCTAssertEqual(mergeStrayVoices(names, ["S0": 29, "S1": 183, "S2": 120], me: "Dima"), ["S0": "Anna", "S1": "Anna", "S2": "Dima"])
        // Someone who speaks a lot is a person of their own.
        XCTAssertEqual(mergeStrayVoices(names, ["S0": 60, "S1": 183], me: "Dima"), names)
        // Two recognised people: an unnamed voice could be either.
        names = ["S0": "Speaker 1", "S1": "Anna", "S3": "Ben"]
        XCTAssertEqual(mergeStrayVoices(names, ["S0": 5, "S1": 100, "S3": 100], me: "Dima"), names)
        // Nobody recognised: nothing to merge into.
        names = ["S0": "Speaker 1", "S1": "Speaker 2"]
        XCTAssertEqual(mergeStrayVoices(names, ["S0": 5, "S1": 100], me: "Dima"), names)
    }

    func testASmallWeakMatchIsNotASecondPerson() {
        // FluidAudio, 2026-11-17: 0.4 min of Anna matched someone else at 0.80, which blocked the merge.
        let names = ["S1": "Anna", "S2": "Speaker 1", "S4": "Ben"]
        let speaking: [String: Double] = ["S1": 684, "S2": 168, "S4": 24]
        let scores = ["S1": 0.82, "S2": 0.55, "S4": 0.80]
        XCTAssertEqual(mergeStrayVoices(names, speaking, me: "Dima", scores: scores), ["S1": "Anna", "S2": "Anna", "S4": "Anna"])
        // A sure match stays a person of their own, and so does a recognised voice with a big share.
        XCTAssertEqual(mergeStrayVoices(names, speaking, me: "Dima", scores: scores.merging(["S4": 0.95]) { $1 }), names)
        XCTAssertEqual(mergeStrayVoices(names, ["S1": 684, "S2": 168, "S4": 300], me: "Dima", scores: scores), names)
    }

    func testAPhraseBetweenTurnsGoesToTheNearestSpeaker() {
        let turns = [turn(0, 5, "A"), turn(6, 9, "B")]
        XCTAssertEqual(nearestSpeaker(5.6, 5.9, turns), "B")
        XCTAssertEqual(nearestSpeaker(5.1, 5.3, turns), "A")
        XCTAssertNil(nearestSpeaker(12, 13, turns, within: 2))
        XCTAssertEqual(nearestSpeaker(12, 13, turns), "B")
        let segment = Segment(start: 5.2, end: 5.4, text: "Okay.", words: [w(5.2, 5.4, "Okay.")])
        XCTAssertEqual(buildLines([segment], turns, ["A": "Anna", "B": "Ben"], near: 0).dropped, 1)
        let (lines, dropped) = buildLines([segment], turns, ["A": "Anna", "B": "Ben"])
        XCTAssertEqual(dropped, 0)
        XCTAssertTrue(lines[0].text.contains("Anna"))
    }

    func testWithoutMyNameNothingChanges() {
        let names = ["A": "Speaker 1"]
        XCTAssertEqual(nameMicrophoneSpeakers(names, ["A": (1, 5)], me: "").names, names)
    }

    // MARK: - Parakeet

    func testHesitationsAreLeftOutAndGiveTheirPunctuationToTheWordBefore() {
        let raw = [("So", 0.0, 0.2), ("um,", 0.3, 0.5), ("hi", 0.6, 0.8), ("Эм.", 0.9, 1.0)].map { (text: $0.0, start: $0.1, end: $0.2) }
        XCTAssertEqual(withoutFillers(raw).map(\.text), ["So,", "hi."])
    }

    func testUnknownCharactersAreLeftOut() {
        let raw = [("на", 0.0, 0.2), ("<unk>сохранить<unk>,", 0.3, 0.8), ("<unk>", 0.9, 1.0)].map { (text: $0.0, start: $0.1, end: $0.2) }
        XCTAssertEqual(withoutFillers(raw).map(\.text), ["на", "сохранить,"])
    }

    func testPhrasesEndAtSentenceEndsAndPauses() {
        let segments = phrases([w(0, 0.3, "Hi."), w(0.4, 0.6, "How"), w(0.7, 0.9, "are"), w(2, 2.2, "you")])
        XCTAssertEqual(segments.map(\.text), ["Hi.", "How are", "you"])
        XCTAssertEqual(segments[1].start, 0.4)
        XCTAssertEqual(segments[1].end, 0.9)
        XCTAssertEqual(segments[1].words?.first?.text, " How")
    }

    func testLanguageIsGuessedFromTheLetters() {
        XCTAssertEqual(guessLanguage([Segment(start: 0, end: 1, text: "Давай откроем Excel")]), "ru")
        XCTAssertEqual(guessLanguage([Segment(start: 0, end: 1, text: "Kannst du das prüfen? Ок")]), "en")
    }

    func testLinesStartWithACapital() {
        let lines = joinLines([NamedWord(start: 5, name: "Elena", text: "then I have to", mine: false, group: 0)])
        XCTAssertEqual(lines.map(\.start), [5])
        XCTAssertEqual(lines.map(\.text), ["[00:00:05] Elena: Then I have to"])
    }
}
