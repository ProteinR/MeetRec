"""Tests for MeetRec/Resources/transcribe.py that need no models: python3 -m unittest discover Tests"""
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

HELPER = Path(__file__).resolve().parent.parent / "MeetRec" / "Resources" / "transcribe.py"
spec = importlib.util.spec_from_file_location("transcribe", HELPER)
transcribe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(transcribe)


class FormatTimeTests(unittest.TestCase):
    def test_format(self):
        self.assertEqual(transcribe.format_time(0), "00:00:00")
        self.assertEqual(transcribe.format_time(3725.9), "01:02:05")


class MarkerTests(unittest.TestCase):
    def test_markers_go_before_the_first_line_at_or_after_them(self):
        lines = [(0, "[00:00:00] A: hi"), (30, "[00:00:30] B: yo")]
        self.assertEqual(transcribe.insert_markers(lines, [10.4, 30, 99]), [
            "[00:00:00] A: hi",
            "⭐ [00:00:10] Отметка",
            "⭐ [00:00:30] Отметка",
            "[00:00:30] B: yo",
            "⭐ [00:01:39] Отметка",
        ])

    def test_no_markers(self):
        self.assertEqual(transcribe.insert_markers([(0, "a")], []), ["a"])

    def test_load_markers_next_to_the_video(self):
        with tempfile.TemporaryDirectory() as folder:
            video = Path(folder) / "2026-10-16 14-03-22 Sync.mov"
            self.assertEqual(transcribe.load_markers(video), [])
            (Path(folder) / "2026-10-16 14-03-22 Sync.markers.json").write_text(
                json.dumps([{"time": 40}, {"time": 5.5, "note": None}]), encoding="utf-8")
            self.assertEqual(transcribe.load_markers(video), [5.5, 40.0])

    def test_unreadable_markers_are_ignored(self):
        with tempfile.TemporaryDirectory() as folder:
            video = Path(folder) / "rec.mov"
            (Path(folder) / "rec.markers.json").write_text("not json", encoding="utf-8")
            self.assertEqual(transcribe.load_markers(video), [])


class SpeakerTests(unittest.TestCase):
    def test_known_voice_gets_its_name_unknown_get_numbers(self):
        references = {"Dima": [[1.0, 0.0, 0.0]], "Elena": [[0.0, 1.0, 0.0]]}
        embeddings = {"SPEAKER_00": [0.9, 0.1, 0.0], "SPEAKER_01": [0.0, 0.0, 1.0], "SPEAKER_02": [0.1, 0.2, 0.9]}
        names, scores = transcribe.match_speakers(embeddings, references, threshold=0.7)
        self.assertEqual(names["SPEAKER_00"], "Dima")
        self.assertEqual({names["SPEAKER_01"], names["SPEAKER_02"]}, {"Speaker 1", "Speaker 2"})
        self.assertEqual(scores["SPEAKER_00"]["name"], "Dima")

    def test_best_of_several_samples_counts(self):
        references = {"Dima": [[0.0, 1.0], [1.0, 0.0]]}
        names, _ = transcribe.match_speakers({"S": [1.0, 0.05]}, references, threshold=0.7)
        self.assertEqual(names["S"], "Dima")

    def test_build_lines_joins_turns_of_one_speaker(self):
        segments = [
            {"start": 0.0, "end": 2.0, "text": "hello"},
            {"start": 2.0, "end": 4.0, "text": "there"},
            {"start": 5.0, "end": 6.0, "text": "hi"},
            {"start": 20.0, "end": 21.0, "text": "Thank you."},  # in silence: no speaker
        ]
        turns = [{"start": 0.0, "end": 4.5, "speaker": "S0"}, {"start": 4.5, "end": 7.0, "speaker": "S1"}]
        lines, dropped = transcribe.build_lines(segments, turns, {"S0": "Dima", "S1": "Speaker 1"})
        self.assertEqual([text for _, text in lines], ["[00:00:00] Dima: hello there", "[00:00:05] Speaker 1: hi"])
        self.assertEqual(dropped, 1)


if __name__ == "__main__":
    unittest.main()
