# /// script
# requires-python = ">=3.12,<3.13"
# dependencies = [
#     "mlx-whisper==0.4.3",
#     "pyannote.audio==4.0.7",
#     "librosa==0.11.0",
# ]
# ///
"""MeetRec transcription helper: Parakeet Ultra (or mlx-whisper large-v3-turbo) + pyannote speaker
diarization.

Adapted from the author's earlier meeting transcription script. Runs locally on Apple Silicon;
the only network access is the model download (Hugging Face).

Speech recognition: Parakeet Ultra by default (`MeetRecASR`, a Swift helper next to MeetRec's
executable: FluidAudio, Neural Engine; the models are shared with Genius Typer's dictation), or
Whisper with `--engine whisper`. Parakeet was more accurate on the author's meetings and does not
invent text in silence or translate German into English, as Whisper did (2026-10-28).

Talks to the app through JSON lines on stdout: {"event": "phase"|"progress"|"done"|"error", ...}.
Human-readable diagnostics go to stderr, which the app writes to its log.

Commands:
  download [--engine e]            fetch both models (and build the uv environment)
  transcribe <recording> --output <md> [--engine parakeet|whisper] [--no-diarization] [--language xx] [--speakers file] [--me Name] [--one-other] [--mixed]
  enroll-sample <wav> --name <Name> --speakers <file>
"""
import argparse
import json
import math
import os
import re
import subprocess
import sys
import tempfile
import time
import unicodedata
from concurrent.futures import ProcessPoolExecutor
from datetime import datetime
from pathlib import Path

ASR_MODEL = "mlx-community/whisper-large-v3-turbo"
DIARIZATION_MODEL = "pyannote/speaker-diarization-community-1"
ENGINES = {"parakeet": "Parakeet Ultra", "whisper": "mlx-whisper large-v3-turbo"}
SAMPLE_RATE = 16000
DEFAULT_THRESHOLD = 0.7


# MeetRec passes its UI language (MEETREC_LANGUAGE: "ru" or "en"); messages and the marker lines
# in the transcript follow it. Russian when unset.
ENGLISH = os.environ.get("MEETREC_LANGUAGE", "ru").startswith("en")


def tr(russian, english):
    return english if ENGLISH else russian


def emit(event, **data):
    print(json.dumps({"event": event, **data}, ensure_ascii=False), flush=True)


def log(message):
    print(message, file=sys.stderr, flush=True)


class _Throttle:
    """Emits a progress event only when the value moved by at least 1 %."""

    def __init__(self, stage):
        self.stage = stage
        self.last = -1.0

    def __call__(self, value):
        value = max(0.0, min(1.0, value))
        if value - self.last >= 0.01 or value >= 1.0 > self.last:
            self.last = value
            emit("progress", stage=self.stage, value=round(value, 3))


class _AsrProgress:
    """Stand-in for tqdm inside mlx_whisper.transcribe: reports decoded frames as progress."""

    def __init__(self, total=None, **_):
        self.total = total or 1
        self.done = 0
        self.report = _Throttle("asr")

    def __enter__(self):
        self.report(0.0)
        return self

    def __exit__(self, *_):
        self.report(1.0)

    def update(self, n=1):
        self.done += n
        self.report(self.done / self.total)


class _SilentProgress(_AsrProgress):
    """For the user's short microphone pieces: they take seconds, the progress bar is the rest."""

    def __init__(self, total=None, **_):
        super().__init__(total)
        self.report = lambda value: None


def _diarization_hook():
    report = _Throttle("diarization")
    weights = {"segmentation": (0.0, 0.35), "embeddings": (0.35, 0.6)}

    def hook(step_name, step_artifact, file=None, total=None, completed=None):
        if step_name in weights and total:
            start, span = weights[step_name]
            report(start + span * (completed or 0) / total)
        elif step_name == "discrete_diarization":
            report(0.97)

    return hook, report


def fail(code, message):
    emit("error", code=code, message=message)
    sys.exit(1)


# ── Audio ────────────────────────────────────────────────────────────────────────────────────────

def audio_streams(recording):
    """Audio streams in file order, each as True when it is the default (played) one."""
    result = subprocess.run(
        ["ffprobe", "-v", "error", "-select_streams", "a", "-show_entries", "stream=index:stream_disposition=default",
         "-of", "csv=p=0", str(recording)],
        capture_output=True, text=True, check=True,
    )
    return [line.split(",")[-1].strip() == "1" for line in result.stdout.split()]


def stream_roles(streams):
    """Positions of the microphone and system audio among the audio streams, as far as known.

    MeetRec writes [system, microphone]; after a recording it puts a mix of both first, the only
    default stream: [mix, microphone, system]. A single stream (one source was off) is unknown."""
    if len(streams) >= 3 and not all(streams):
        separate = [i for i, default in enumerate(streams) if not default]
        if len(separate) >= 2:
            return {"microphone": separate[0], "system": separate[1]}
    if len(streams) == 2:
        return {"system": 0, "microphone": 1}
    return {}


def extract_audio(recording, wav):
    """Mono 16 kHz WAV of everyone, plus the microphone and system audio on their own when the file
    has them apart (`{"microphone": path, "system": path}`), to tell the user from the other side.

    The mix MeetRec adds for players is not used: the raw tracks are mixed here without the gain."""
    streams = audio_streams(recording)
    if not streams:
        fail("no_audio", tr("В записи нет звука", "The recording has no audio"))
    roles = stream_roles(streams)
    sources = [roles["microphone"], roles["system"]] if roles else list(range(len(streams)))
    command = ["ffmpeg", "-v", "error", "-y", "-i", str(recording), "-vn"]
    if len(sources) > 1:
        inputs = "".join(f"[0:a:{i}]" for i in sources)
        command += ["-filter_complex", f"{inputs}amix=inputs={len(sources)}:normalize=0[a]", "-map", "[a]"]
    else:
        command += ["-map", f"0:a:{sources[0]}"]
    command += ["-ac", "1", "-ar", str(SAMPLE_RATE), str(wav)]
    log(f"ffmpeg: {len(streams)} audio stream(s), using {sources} {roles or ''} → {wav}")
    subprocess.run(command, check=True)
    separate = {}
    for role, position in roles.items():
        path = wav.with_name(f"{role}.wav")
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", str(recording), "-vn", "-map", f"0:a:{position}",
                        "-ac", "1", "-ar", str(SAMPLE_RATE), str(path)], check=True)
        separate[role] = path
    return separate


def frame_levels(path, frame=0.05):
    """Loudness (dB) of each `frame` seconds of a WAV."""
    import numpy as np

    audio = load_audio(path)
    size = int(SAMPLE_RATE * frame)
    count = len(audio) // size
    frames = audio[: count * size].reshape(count, size)
    return (20 * np.log10(np.sqrt((frames ** 2).mean(axis=1)) + 1e-9)).tolist()


def load_audio(path):
    import librosa

    audio, _ = librosa.load(path, sr=SAMPLE_RATE)
    return audio


# ── The user's own track ──────────────────────────────────────────────────────────────────────────
# With headphones the microphone hears only the user and the system audio only the other side, so
# the two are transcribed apart: the user's speech (a few minutes of a meeting) in pieces, everyone
# else with diarization. No guessing who said what, also when people speak at once. Through the
# Mac's speakers the microphone hears the others too (ScreenCaptureKit gives the raw microphone):
# then the mixed way with per-word guessing is used.

ECHO_LIMIT = 0.25


def echo_ratio(microphone_db, system_db, speech=-40.0, heard=-45.0):
    """Share of the other side's speech that is also heard in the microphone: near 0 with headphones
    (only when the user talks at the same time), high through speakers (echo)."""
    count = min(len(microphone_db), len(system_db))
    talking = [i for i in range(count) if system_db[i] > speech]
    if not talking:
        return 0.0
    return sum(1 for i in talking if microphone_db[i] > heard) / len(talking)


def speech_chunks(microphone_db, frame=0.05, threshold=-45.0, gap=1.5, pad=0.3, min_speech=0.3):
    """(start, end) seconds of the user's speech in the microphone track: loud frames, joined over
    pauses shorter than `gap`, `pad` added at both ends so no word is cut; pieces with less than
    `min_speech` of sound (a cough, a click) are left out."""
    chunks = []
    for i, level in enumerate(microphone_db):
        if level <= threshold:
            continue
        start, end = i * frame, (i + 1) * frame
        if chunks and start - chunks[-1][1] <= gap:
            chunks[-1][1] = end
            chunks[-1][2] += frame
        else:
            chunks.append([start, end, frame])
    total = len(microphone_db) * frame
    return [(max(start - pad, 0.0), min(end + pad, total)) for start, end, voiced in chunks if voiced >= min_speech]


# ── Engines ──────────────────────────────────────────────────────────────────────────────────────

def asr_helper():
    """MeetRecASR: next to MeetRec's executable (`Contents/MacOS`), this script being in
    `Contents/Resources`; `MEETREC_ASR` points elsewhere (a development build)."""
    path = os.environ.get("MEETREC_ASR") or str(Path(__file__).resolve().parent.parent / "MacOS" / "MeetRecASR")
    if not os.access(path, os.X_OK):
        fail("no_asr", tr(f"Не найден MeetRecASR: {path}", f"MeetRecASR not found: {path}"))
    return path


def run_asr_helper(arguments, report=None):
    """Runs MeetRecASR, forwards its progress to `report`; its last JSON line."""
    process = subprocess.Popen([asr_helper(), *arguments], stdout=subprocess.PIPE, text=True)
    last = {}
    for line in process.stdout:
        try:
            last = json.loads(line)
        except ValueError:
            continue
        if "progress" in last and report:
            report(last["progress"])
    process.wait()
    if "error" in last or process.returncode:
        raise RuntimeError(f"MeetRecASR: {last.get('error', f'exit {process.returncode}')}")
    return last


FILLERS = {"uh", "um", "uhm", "umm", "erm", "eh", "ah", "э", "ээ", "эм", "эээ"}


def is_filler(text):
    """Hesitations Parakeet writes down ("uh", "um", "эм"); Whisper left them out."""
    return re.sub(r"[^\w]+", "", text.lower()) in FILLERS


def parakeet_words(wav_path, report=None):
    """Words of a WAV with Parakeet: [{"start", "end", "text"}], without hesitations."""
    return without_fillers(run_asr_helper(["transcribe", str(wav_path)], report)["words"])


def without_fillers(raw):
    """MeetRecASR's [text, start, end, confidence] as words, hesitations left out (a sentence end or
    comma they carried goes to the word before), and "<unk>": a character missing from Parakeet's
    vocabulary, mostly quotes («сохранить»)."""
    words = []
    for text, start, end, _ in raw:
        text = text.replace("<unk>", "")
        if not text:
            continue
        if is_filler(text):
            ending = re.sub(r"^[\w'’-]+", "", text)
            if words and ending and not re.search(r"[.,?!…]$", words[-1]["text"]):
                words[-1]["text"] += ending
            continue
        words.append({"start": start, "end": end, "text": text})
    return words


def phrases(words, pause=0.8, longest=30.0):
    """Parakeet's words in phrases, as Whisper's segments: a new one after a sentence end or a pause."""
    segments = []
    for word in words:
        last = segments[-1] if segments else None
        if last is None or word["start"] - last["end"] > pause or word["start"] - last["start"] > longest \
                or re.search(r"[.?!…]$", last["words"][-1]["text"].strip()):
            segments.append({"start": word["start"], "end": word["end"], "words": []})
            last = segments[-1]
        last["words"].append({**word, "text": " " + word["text"]})
        last["end"] = word["end"]
    for s in segments:
        s["text"] = "".join(w["text"] for w in s["words"]).strip()
    return segments


def guess_language(segments):
    """Parakeet does not say which language it heard: "ru" when most letters are Cyrillic, else "en"."""
    text = " ".join(s["text"] for s in segments)
    cyrillic = sum(1 for c in text if "а" <= c.lower() <= "я" or c.lower() == "ё")
    latin = sum(1 for c in text if "a" <= c.lower() <= "z")
    return "ru" if cyrillic > latin else "en"


def run_parakeet(wav_path):
    t0 = time.time()
    segments = phrases(parakeet_words(wav_path, _Throttle("asr")))
    return {"language": guess_language(segments), "segments": without_loops(segments), "seconds": time.time() - t0}


def run_asr(wav_path, language, engine="parakeet"):
    if engine == "parakeet":
        return run_parakeet(wav_path)
    import mlx_whisper

    # `mlx_whisper.transcribe` is shadowed by the function of the same name; patch the module's tqdm
    # so decoding reports progress events instead of drawing a terminal bar.
    sys.modules["mlx_whisper.transcribe"].tqdm.tqdm = _AsrProgress
    t0 = time.time()
    audio = load_audio(wav_path)
    result = mlx_whisper.transcribe(
        audio,
        path_or_hf_repo=ASR_MODEL,
        # Words with their times: one Whisper segment often holds several people ("Hi. Hi, Dima.
        # Hi."), so speakers are assigned per word (`build_lines`).
        word_timestamps=True,
        condition_on_previous_text=False,
        language=language or None,
    )
    language = language or result.get("language")
    segments = without_loops(retry_other_languages(retry_loops([
        {"start": s["start"], "end": s["end"], "text": s["text"].strip(), "logprob": s.get("avg_logprob", 0.0),
         "words": [{"start": w["start"], "end": w["end"], "text": w["word"]} for w in s.get("words", [])]}
        for s in result["segments"]
        if s["text"].strip()
    ], audio, language), audio, language))
    return {"language": result.get("language"), "segments": segments, "seconds": time.time() - t0}


JOIN_PAUSE = 2.0  # long enough that Whisper's word times (±0.5 s) tell the pieces apart


def joined_chunks(chunks, silence=JOIN_PAUSE):
    """Where each piece goes when the pieces are put one after another with `silence` between them:
    (start in the recording, start in the joined audio, length)."""
    places, at = [], 0.0
    for start, end in chunks:
        places.append((start, at, end - start))
        at += end - start + silence
    return places


def piece_of(t, places):
    """Index of the piece a time in the joined audio belongs to; in a pause, the nearer piece (Whisper
    lets a word start or end a little inside the pause)."""
    for index, (_, joined, length) in enumerate(places):
        if t < joined + length:
            if index > 0 and t < joined:
                previous_end = places[index - 1][1] + places[index - 1][2]
                return index - 1 if t - previous_end < joined - t else index
            return index
    return len(places) - 1


def recording_time(t, places, index=None):
    """A time in the joined audio back in the recording (in piece `index`, else the nearest one)."""
    if not places:
        return t
    start, joined, length = places[piece_of(t, places) if index is None else index]
    return start + min(max(t - joined, 0.0), length)


def split_by_piece(segments, places):
    """One phrase per piece of the user's speech, times back in the recording. Whisper joins
    neighbouring pieces into one phrase ("Hi." at 0:05 and "Okay, thank you." at 0:50), so a phrase is
    cut where its words change piece; and it splits one piece into several ("Okay." "Okay." "Okay."),
    so those are joined again, and someone else's words said at that moment cannot get between them."""
    groups = []
    for s in segments:
        words = s.get("words") or [{"start": s["start"], "end": s["end"], "word": s["text"]}]
        for w in words:
            index = piece_of((w["start"] + w["end"]) / 2, places)
            if not groups or groups[-1][0] != index:
                groups.append((index, []))
            groups[-1][1].append({"start": recording_time(w["start"], places, index),
                                  "end": recording_time(w["end"], places, index), "text": w["word"]})
    return [{"start": group[0]["start"], "end": group[-1]["end"],
             "text": " ".join("".join(w["text"] for w in group).split()), "words": group} for _, group in groups]


def run_chunks_asr(wav_path, chunks, language, engine="parakeet"):
    """Recognises the user's pieces of the microphone track, put one after another with short pauses:
    one pass (the engine hears the context, the language is found from the user's own speech), times
    mapped back to the recording."""
    import numpy as np

    t0 = time.time()
    audio = load_audio(wav_path)
    places = joined_chunks(chunks)
    pause = np.zeros(int(JOIN_PAUSE * SAMPLE_RATE), dtype=audio.dtype)
    pieces = []
    for start, end in chunks:
        pieces += [audio[int(start * SAMPLE_RATE):int(end * SAMPLE_RATE)], pause]
    if not pieces:
        return {"segments": [], "language": None, "seconds": 0.0}
    if engine == "parakeet":
        import soundfile

        joined = Path(wav_path).with_name("microphone-joined.wav")
        soundfile.write(joined, np.concatenate(pieces), SAMPLE_RATE)
        found = phrases(parakeet_words(joined))
        segments = without_loops(split_by_piece(
            [{**s, "words": [{**w, "word": w["text"]} for w in s["words"]]} for s in found], places))
        for s in segments:
            log(f"microphone [{format_time(s['start'])}]: {s['text']}")
        return {"segments": segments, "language": guess_language(found), "seconds": time.time() - t0}
    import mlx_whisper

    sys.modules["mlx_whisper.transcribe"].tqdm.tqdm = _SilentProgress
    result = mlx_whisper.transcribe(
        np.concatenate(pieces),
        path_or_hf_repo=ASR_MODEL,
        word_timestamps=True,
        condition_on_previous_text=False,
        language=language or None,
    )
    # Whisper invents text in noise ("Thank you."); it says so itself.
    kept = []
    for s in result["segments"]:
        if s["text"].strip() and s.get("no_speech_prob", 0.0) <= 0.6:
            kept.append(s)
        elif s["text"].strip():
            log(f"microphone: left out (no speech {s.get('no_speech_prob', 0.0):.0%}): {s['text'].strip()}")
    segments = without_loops(split_by_piece(kept, places))
    for s in segments:
        log(f"microphone [{format_time(s['start'])}]: {s['text']}")
    return {"segments": segments, "language": result.get("language"), "seconds": time.time() - t0}


MAX_REPEAT = 5  # "Okay. Okay. Okay." is speech; the same word more times in a row is Whisper looping


def _word_key(text):
    return re.sub(r"[\W_]+", "", text.lower())


def _looping_word(text):
    return re.search(r"(.{1,4}?)\1{8,}", text.strip()) is not None


def has_loop(segment):
    """The same word more than `MAX_REPEAT` times in a row, or a word that is one short piece repeated."""
    words = segment.get("words") or []
    run = 1
    for previous, word in zip(words, words[1:]):
        same = _word_key(word["text"]) and _word_key(word["text"]) == _word_key(previous["text"])
        run = run + 1 if same else 1
        if run > MAX_REPEAT:
            return True
    return any(_looping_word(word["text"]) for word in words)


def _stretch(segment, audio):
    """The segment's own stretch of audio, with half a second to spare: (start, end) in seconds."""
    return max(segment["start"] - 0.5, 0.0), min(segment["end"] + 0.5, len(audio) / SAMPLE_RATE)


def recognise_stretch(audio, start, end, language, **options):
    """Recognises audio[start:end] again; segments in recording time, and the language used."""
    import mlx_whisper

    sys.modules["mlx_whisper.transcribe"].tqdm.tqdm = _SilentProgress
    again = mlx_whisper.transcribe(
        audio[int(start * SAMPLE_RATE):int(end * SAMPLE_RATE)],
        path_or_hf_repo=ASR_MODEL,
        word_timestamps=True,
        condition_on_previous_text=False,
        language=language or None,
        **options,
    )
    return [{"start": start + n["start"], "end": start + n["end"], "text": n["text"].strip(), "logprob": n.get("avg_logprob", 0.0),
             "words": [{"start": start + w["start"], "end": start + w["end"], "text": w["word"]} for w in n.get("words", [])]}
            for n in again["segments"] if n["text"].strip()], again.get("language")


def stretch_languages(audio, start, end):
    """Whisper's language guess for audio[start:end] (its first 30 s): [(language, probability)],
    most likely first."""
    import mlx.core as mx
    from mlx_whisper.audio import N_FRAMES, N_SAMPLES, log_mel_spectrogram, pad_or_trim

    model = sys.modules["mlx_whisper.transcribe"].ModelHolder.get_model(ASR_MODEL, mx.float16)
    mel = log_mel_spectrogram(audio[int(start * SAMPLE_RATE):int(end * SAMPLE_RATE)], n_mels=model.dims.n_mels, padding=N_SAMPLES)
    _, probs = model.detect_language(pad_or_trim(mel, N_FRAMES, axis=-2).astype(mx.float16))
    return sorted(probs.items(), key=lambda item: -item[1])


def retry_loops(segments, audio, language):
    """Whisper loops at random (the same audio recognised again is usually fine): a segment that loops
    is recognised once more, its own stretch of audio with some randomness (temperature), and replaced
    when the new text does not loop. Otherwise `without_loops` leaves the loop out."""
    result = []
    for s in segments:
        if not has_loop(s):
            result.append(s)
            continue
        start, end = _stretch(s, audio)
        new, _ = recognise_stretch(audio, start, end, language, temperature=(0.2, 0.4, 0.6, 0.8))
        if new and not any(has_loop(n) for n in new):
            log(f"Whisper looped at {format_time(s['start'])}; recognised again: {' '.join(n['text'] for n in new)[:120]}")
            result += new
        else:
            log(f"Whisper looped at {format_time(s['start'])} and again on a retry; the loop is left out")
            result.append(s)
    return result


def _script(char):
    """The writing system of a letter: "LATIN", "CYRILLIC", "CJK" (Chinese, Japanese and Korean
    together), "ARABIC"…"""
    name = unicodedata.name(char, "")
    if name.startswith(("CJK", "HIRAGANA", "KATAKANA", "HANGUL")):
        return "CJK"
    return name.split(" ")[0]


def has_script_mix(segment):
    """Whisper writes speech in a language other than the one it recognises as gibberish in several
    writing systems ("Г찰� тренировка… strongly transmагает"). Russian with English terms ("RFID",
    "QR-код") is not a mix; a word that mixes writing systems is, and so is a third one besides Latin
    and Cyrillic, or CJK/Arabic/… next to either."""
    scripts = set()
    for word in re.findall(r"[^\W\d_]+", segment["text"]):
        own = {_script(c) for c in word}
        if len(own) > 1:
            return True
        scripts |= own
    return len(scripts) > 1 and not scripts <= {"LATIN", "CYRILLIC"}


UNSURE = -1.0  # Whisper's own threshold (avg_logprob): below it a window is decoded again with temperature


def unclear_passages(segments, gap=5.0):
    """Runs of segments (first, last index) Whisper may have got wrong: segments in mixed writing
    systems or unsure ones, less than `gap` s apart. Whisper cuts speech in another language into
    pieces, some mixed, some just wrong ("address 1?") or dots, and a piece of a second or two is too
    short to tell its language."""
    passages, i = [], 0
    unclear = [has_script_mix(s) or s.get("logprob", 0.0) < UNSURE for s in segments]
    while i < len(segments):
        j = i
        if unclear[i]:
            while j + 1 < len(segments) and unclear[j + 1] and segments[j + 1]["start"] - segments[j]["end"] < gap:
                j += 1
            passages.append((i, j))
        i = j + 1
    return passages


def _confidence(segments):
    """Whisper's own confidence in a result: avg_logprob weighted by duration."""
    total = sum(s["end"] - s["start"] for s in segments)
    return sum(s.get("logprob", 0.0) * (s["end"] - s["start"]) for s in segments) / total if total else -math.inf


OTHER_LANGUAGE = 0.5  # an unsure passage is recognised again when Whisper hears another language there this surely
MIN_PASSAGE = 3.0  # seconds: shorter unsure passages without mixed writing are left alone


def retry_other_languages(segments, audio, language):
    """Speech in another language (a colleague in the room, a few words in German) comes out as
    gibberish in the recording's language, often in mixed writing systems ("Г찰� тренировка…
    strongly transmагает"). An unclear passage (`unclear_passages`) with mixed writing, or a longer
    unsure one where Whisper hears another language, is recognised once more in each language Whisper
    hears there (the two likeliest, at least 10 %), and replaced by the result Whisper is surest of
    among those that are not mixed. Whisper made to recognise German as English translates it
    instead, with less confidence. Without such a result the passage stays as it was."""
    result, done = [], 0
    for first, last in unclear_passages(segments):
        old = segments[first:last + 1]
        mixed = any(has_script_mix(s) for s in old)
        if not mixed and old[-1]["end"] - old[0]["start"] < MIN_PASSAGE:
            log(f"Unsure passage at {format_time(old[0]['start'])}–{format_time(old[-1]['end'])}: too short to check")
            continue
        start, end = _stretch({"start": old[0]["start"], "end": old[-1]["end"]}, audio)
        guesses = [(lang, p) for lang, p in stretch_languages(audio, start, end) if p >= 0.1][:2]
        heard = ", ".join(f"{lang} {p:.0%}" for lang, p in guesses)
        where = (f"{'Mixed scripts' if mixed else 'Unsure passage'} at {format_time(old[0]['start'])}–"
                 f"{format_time(old[-1]['end'])} ({language}; heard {heard})")
        if not mixed and (not guesses or guesses[0][0] == language or guesses[0][1] < OTHER_LANGUAGE):
            log(f"{where}: left as it is")
            continue
        result += segments[done:first]
        done = last + 1
        tries = []
        for lang, _ in guesses:
            new, _ = recognise_stretch(audio, start, end, lang)
            if new and not any(has_script_mix(n) for n in new):
                tries.append((_confidence(new), lang, new))
        if tries:
            confidence, lang, new = max(tries, key=lambda t: t[0])
            log(f"{where}; recognised again in {lang} (confidence {confidence:.2f}, "
                f"{', '.join(f'{l} {c:.2f}' for c, l, _ in tries)}): {' '.join(n['text'] for n in new)[:160]}")
            result += new
        else:
            log(f"{where}; kept as it was: {' '.join(s['text'] for s in old)[:80]}")
            result += old
    return result + segments[done:]


def without_loops(segments):
    """Whisper sometimes loops on unclear audio and writes one word hundreds of times ("dot dot dot…",
    "1,1,1,1…"). Runs of the same word longer than `MAX_REPEAT`, and words that are one short piece
    repeated, are left out (and logged); the rest of the segment stays."""
    key = _word_key
    result = []
    for s in segments:
        words = s.get("words") or []
        if not words:
            result.append(s)
            continue
        kept, i = [], 0
        while i < len(words):
            j = i
            while j + 1 < len(words) and key(words[j + 1]["text"]) == key(words[i]["text"]) and key(words[i]["text"]):
                j += 1
            run = words[i:j + 1]
            if len(run) > MAX_REPEAT:
                log(f"Left out a Whisper loop at {format_time(run[0]['start'])}: {run[0]['text'].strip()!r} × {len(run)}")
            else:
                for w in run:
                    if _looping_word(w["text"]):
                        log(f"Left out a looping word at {format_time(w['start'])}: {w['text'].strip()[:30]!r}…")
                    else:
                        kept.append(w)
            i = j + 1
        if kept:
            result.append({**s, "start": kept[0]["start"], "end": kept[-1]["end"],
                           "text": " ".join("".join(w["text"] for w in kept).split()), "words": kept})
    return result


def load_pipeline():
    import torch
    from pyannote.audio import Pipeline

    try:
        pipeline = Pipeline.from_pretrained(DIARIZATION_MODEL)
    except Exception as error:  # gated repo, missing token, network
        text = f"{type(error).__name__}: {error}"
        if "Gated" in text or "403" in text or "401" in text or "token" in text.lower():
            fail("gated", tr("Нет доступа к модели pyannote: нужен вход в Hugging Face и принятые условия модели "
                             "pyannote/speaker-diarization-community-1",
                             "No access to the pyannote model: log in to Hugging Face and accept the conditions of "
                             "pyannote/speaker-diarization-community-1"))
        raise
    if pipeline is None:
        fail("gated", tr("Модель pyannote не загрузилась: проверьте токен Hugging Face",
                         "The pyannote model did not load: check your Hugging Face token"))
    if torch.backends.mps.is_available():
        pipeline.to(torch.device("mps"))
    return pipeline


def run_diarization(wav_path):
    import torch

    t0 = time.time()
    pipeline = load_pipeline()
    audio = load_audio(wav_path)
    hook, report = _diarization_hook()
    output = pipeline({"waveform": torch.from_numpy(audio).unsqueeze(0), "sample_rate": SAMPLE_RATE}, hook=hook)
    report(1.0)
    annotation = output.exclusive_speaker_diarization
    labels = annotation.labels()
    turns = [{"start": t.start, "end": t.end, "speaker": spk} for t, _, spk in annotation.itertracks(yield_label=True)]
    embeddings = {label: output.speaker_embeddings[i].tolist() for i, label in enumerate(labels)}
    return {"turns": turns, "embeddings": embeddings, "seconds": time.time() - t0}


# ── Speakers ─────────────────────────────────────────────────────────────────────────────────────

def cosine(a, b):
    dot = sum(x * y for x, y in zip(a, b))
    norm = math.sqrt(sum(x * x for x in a) * sum(y * y for y in b))
    return dot / norm if norm else 0.0


def load_speakers(path):
    if path and Path(path).exists():
        return json.loads(Path(path).read_text(encoding="utf-8"))
    return {}


def match_speakers(embeddings, references, threshold):
    names, scores = {}, {}
    for label, embedding in embeddings.items():
        best_name, best_score = None, -1.0
        for name, samples in references.items():
            score = max(cosine(embedding, sample) for sample in samples)
            if score > best_score:
                best_name, best_score = name, score
        scores[label] = {"name": best_name, "score": round(best_score, 3)}
        if best_name and best_score >= threshold:
            names[label] = best_name
    unknown = sorted(label for label in embeddings if label not in names)
    for i, label in enumerate(unknown, 1):
        names[label] = f"Speaker {i}"
    return names, scores


def microphone_frames(start, end, microphone_db, system_db, frame=0.05, margin=6.0, floor=-50.0):
    """(frames, frames heard through the user's microphone) between start and end: sound clearly
    louder in the microphone track than in the system audio."""
    first, last = int(start / frame), min(int(end / frame), len(microphone_db), len(system_db))
    mic = sum(1 for i in range(first, last) if microphone_db[i] > floor and microphone_db[i] > system_db[i] + margin)
    return max(last - first, 0), mic


def microphone_shares(turns, microphone_db, system_db, frame=0.05):
    """For each diarized speaker: the share of their speaking time that comes through the user's
    microphone, and their seconds of speech."""
    stats = {}
    for turn in turns:
        total, mic = microphone_frames(turn["start"], turn["end"], microphone_db, system_db, frame)
        before = stats.get(turn["speaker"], (0, 0))
        stats[turn["speaker"]] = (before[0] + total, before[1] + mic)
    return {label: (mic / total if total else 0.0, total * frame) for label, (total, mic) in stats.items()}


def spoken_into_microphone(segment, levels, min_share=0.6):
    """A recognised phrase heard mostly through the user's microphone: the user said it, even when
    diarization put it with someone else (the Teams echo test plays the user's voice back)."""
    total, mic = microphone_frames(segment["start"], segment["end"], *levels)
    return total > 0 and mic / total >= min_share


def word_spoken_into_microphone(word, levels, frame=0.05, margin=6.0, floor=-50.0, min_share=0.6):
    """A word heard mostly through the user's microphone. Whisper gives a word more time than the
    sound itself (a short "Hi" gets 0.7 s), so only frames where anything is heard count."""
    microphone_db, system_db = levels
    first, last = int(word["start"] / frame), min(int(word["end"] / frame), len(microphone_db), len(system_db))
    audible = mic = 0
    for i in range(first, last):
        if max(microphone_db[i], system_db[i]) > floor:
            audible += 1
            if microphone_db[i] > floor and microphone_db[i] > system_db[i] + margin:
                mic += 1
    return mic >= 2 and mic / audible >= min_share


def name_microphone_speakers(names, shares, me, min_share=0.6, min_seconds=1.0):
    """Speakers heard through the user's microphone are the user, whatever their voice matched.
    Anyone else who matched the user's voice becomes an unnamed speaker. Returns new names and the
    labels taken as the user."""
    mine = {label for label, (share, seconds) in shares.items() if share >= min_share and seconds >= min_seconds}
    if not me or not mine:
        return names, set()
    result = dict(names)
    taken = {name for name in names.values() if name.startswith("Speaker ")}
    number = 1
    for label in sorted(names):
        if label in mine:
            result[label] = me
        elif names[label] == me:
            while f"Speaker {number}" in taken:
                number += 1
            result[label] = f"Speaker {number}"
            taken.add(result[label])
    return result, mine


def merge_other_side(names, speaking, me):
    """A one-on-one call (a lesson): everyone who is not the user is the one other person, even when
    diarization split them (a voice changes when the connection gets worse). They take the name of
    whoever of them was recognised by voice, else of the one who spoke most; the user stays as is."""
    others = sorted((label for label in names if not (me and names[label] == me)),
                    key=lambda label: speaking.get(label, 0.0), reverse=True)
    if len(others) < 2:
        return names
    known = [label for label in others if not names[label].startswith("Speaker ")]
    name = names[known[0]] if known else "Speaker 1"
    return {label: (name if label in others else value) for label, value in names.items()}


def assign_speaker(segment, turns):
    best, overlap = None, 0.0
    for turn in turns:
        value = min(segment["end"], turn["end"]) - max(segment["start"], turn["start"])
        if value > overlap:
            best, overlap = turn["speaker"], value
    return best


def format_time(seconds):
    seconds = int(seconds)
    return f"{seconds // 3600:02d}:{seconds % 3600 // 60:02d}:{seconds % 60:02d}"


def word_names(segment, label, turns, names, me=None, levels=None):
    """[start, name, text, mine, segment] for each word of a segment. A word heard mostly through the
    microphone is the user's (mine); otherwise it goes to the diarized speaker it overlaps most, else
    the segment's."""
    words = segment.get("words") or [{"start": segment["start"], "end": segment["end"], "text": segment["text"]}]
    result = []
    for word in words:
        mine = bool(me and levels and word_spoken_into_microphone(word, levels))
        word_label = assign_speaker(word, turns) or label
        result.append([word["start"], me if mine or word_label is None else names[word_label], word["text"], mine,
                       id(segment)])
    return result


def speaker_runs(words):
    """Consecutive words of one speaker."""
    runs = []
    for word in words:
        if runs and runs[-1][0][1] == word[1]:
            runs[-1].append(word)
        else:
            runs.append([word])
    return runs


def smooth_short_runs(words, max_words=2):
    """Diarization at word level makes slips at the edges of turns; one or two words not from the
    microphone and not a sentence of their own (a reply "Yes." between two sentences of someone else
    stays) are moved:
    - between two runs of the same speaker, back to them ("Julius: ok but are / Dima: you finished /
      Julius: in this branch?");
    - after a finished sentence and before someone else's words that go on the sentence (lower
      case, same Whisper segment), to them: the next speaker's first word left with the previous one
      ("Julius: …reinfolgen. / Falk: Das / Julius: ist ja praktisch…")."""
    def ends_sentence(text):
        return text.strip().endswith((".", "?", "!", "…"))

    def movable(run):
        return len(run) <= max_words and not any(word[3] for word in run) and not ends_sentence(run[-1][2])

    runs = speaker_runs(words)
    for i in range(1, len(runs) - 1):
        run, before, after = runs[i], runs[i - 1], runs[i + 1]
        if movable(run) and before[-1][1] == after[0][1] != run[0][1] and not ends_sentence(before[-1][2]):
            for word in run:
                word[1] = before[-1][1]
    runs = speaker_runs(words)
    for i in range(1, len(runs) - 1):
        run, before, after = runs[i], runs[i - 1], runs[i + 1]
        if movable(run) and ends_sentence(before[-1][2]) and after[0][2].strip()[:1].islower() \
                and run[-1][4] == after[0][4]:
            for word in run:
                word[1] = after[0][1]
    return words


def build_lines(segments, turns, names, me=None, levels=None):
    """Transcript lines, a speaker's words joined until someone else speaks; with the user's name and
    the microphone/system levels, words spoken into the microphone are the user's."""
    words, dropped = [], 0
    for segment in segments:
        label = assign_speaker(segment, turns)
        if label is None and not (me and levels and spoken_into_microphone(segment, levels)):
            dropped += 1  # Whisper hallucinations in silence ("Thank you.")
            continue
        words += word_names(segment, label, turns, names, me, levels)
    return join_lines(smooth_short_runs(words)), dropped


def build_split_lines(segments, my_segments, turns, names, me):
    """Transcript lines when the user's microphone track was transcribed apart (`my_segments`): the
    other side's words get their diarized speakers, the user's words are the user's, and both are
    put in order of time."""
    words, dropped = [], 0
    for segment in segments:
        label = assign_speaker(segment, turns)
        if label is None:
            dropped += 1  # Whisper hallucinations in silence ("Thank you.")
            continue
        words += word_names(segment, label, turns, names)
    # A phrase of the user stays whole: the other side's words said at the same moment (everyone's
    # "bye") follow it instead of cutting it in two.
    spans = [(segment["start"], segment["end"]) for segment in my_segments]

    def key(word):
        if word[3]:
            return (word[4], 0, word[0])
        inside = next((start for start, end in spans if start <= word[0] < end), None)
        return (inside, 1, word[0]) if inside is not None else (word[0], 1, word[0])

    for segment in my_segments:
        mine = segment.get("words") or [{"start": segment["start"], "end": segment["end"], "text": segment["text"]}]
        words += [[word["start"], me, word["text"], True, segment["start"]] for word in mine]
    words.sort(key=key)
    return join_lines(smooth_short_runs(words)), dropped


def join_lines(words):
    """A speaker's words joined into one line until someone else speaks."""
    lines = []
    for start, name, text, *_ in words:
        if lines and lines[-1][1] == name:
            lines[-1][2] += " " + text
        else:
            lines.append([start, name, text])
    # A line starts with a capital: a phrase cut by a pause goes on in lower case ("then I have to…").
    return [(start, f"[{format_time(start)}] {name}: {capitalized(' '.join(text.split()))}") for start, name, text in lines]


def capitalized(text):
    return text[:1].upper() + text[1:]


def without_me(names, me):
    """The other side's speakers: whoever matched the user's voice there (the Teams echo test plays
    it back) becomes an unnamed speaker."""
    if not me:
        return names
    result, taken, number = dict(names), set(names.values()), 1
    for label in sorted(names):
        if names[label] == me:
            while f"Speaker {number}" in taken:
                number += 1
            result[label] = f"Speaker {number}"
            taken.add(result[label])
    return result


PAUSE_NOTE = "Пауза"  # RecorderModel.pauseNote: where a paused recording was joined up


def companion(recording, name):
    """A file of the recording: `name` in its own folder (`<stem>/<stem>.mov`), or `<stem>.<name>`
    next to a recording of the older flat layout (RecordingFiles.companion in MeetRec)."""
    if recording.parent.name == recording.stem:
        return recording.parent / name
    return recording.with_name(f"{recording.stem}.{name}")


def load_markers(recording):
    """Moments marked during recording (`markers.json` of the recording) as (seconds, note), note
    "Пауза" for a cut pause and None for the user's own markers."""
    path = companion(recording, "markers.json")
    if not path.exists():
        return []
    try:
        return sorted(((float(m["time"]), m.get("note")) for m in json.loads(path.read_text(encoding="utf-8"))),
                      key=lambda marker: marker[0])
    except (ValueError, KeyError, TypeError) as error:
        log(f"Ignoring unreadable markers file {path}: {error}")
        return []


MUTE_JOIN = 10.0  # mutes closer than this are one ("mute, say a word, mute again")
MUTE_MIN = 5.0    # shorter mutes (a cough) are left out


def load_mutes(recording, total=None, speech=()):
    """When the microphone was muted (`mutes.json` of the recording, seconds of the file),
    joined when close together (not over the user's `speech` times) and without the short ones, as
    markers (start, ("mute", end))."""
    path = companion(recording, "mutes.json")
    if not path.exists():
        return []
    try:
        spans = sorted((float(m["start"]), float(m["end"]) if m.get("end") is not None else total)
                       for m in json.loads(path.read_text(encoding="utf-8")))
    except (ValueError, KeyError, TypeError) as error:
        log(f"Ignoring unreadable mutes file {path}: {error}")
        return []
    return [(start, ("mute", end)) for start, end in merge_mutes(spans, speech=speech)]


def merge_mutes(spans, join=MUTE_JOIN, shortest=MUTE_MIN, speech=()):
    """(start, end) spans joined over gaps shorter than `join` in which the user did not speak (unmuted
    for a moment to say "Okay"), then those shorter than `shortest` dropped; an end of None (still
    muted when the file ended) is kept as is."""
    merged = []
    for start, end in spans:
        if merged and merged[-1][1] is not None and start - merged[-1][1] < join \
                and not any(merged[-1][1] <= t <= start for t in speech):
            merged[-1][1] = end if end is None else max(end, merged[-1][1])
        else:
            merged.append([start, end])
    return [(start, end) for start, end in merged if end is None or end - start >= shortest]


def marker_line(marker):
    """ "⭐ [00:12:34] Отметка", "⏸ [00:12:34] Пауза" or "🔇 [00:12:34–00:13:10] Микрофон выключен";
    a marker is seconds or (seconds, note)."""
    time, note = marker if isinstance(marker, tuple) else (marker, None)
    if isinstance(note, tuple) and note[0] == "mute":
        until = f"–{format_time(note[1])}" if note[1] is not None else ""
        return f"🔇 [{format_time(time)}{until}] {tr('Микрофон выключен', 'Microphone muted')}"
    if note == PAUSE_NOTE:
        return f"⏸ [{format_time(time)}] {tr(PAUSE_NOTE, 'Pause')}"
    return f"⭐ [{format_time(time)}] {tr('Отметка', 'Marker')}"


def insert_markers(timed_lines, markers):
    """Puts a marker line before the first replica that starts at or after each marker."""
    def key(marker):
        return marker[0] if isinstance(marker, tuple) else marker

    result, pending = [], sorted(markers, key=key)
    for start, text in timed_lines:
        while pending and key(pending[0]) <= start:
            result.append(marker_line(pending.pop(0)))
        result.append(text)
    result.extend(marker_line(m) for m in pending)
    return result


# ── Commands ─────────────────────────────────────────────────────────────────────────────────────

def download(args):
    from huggingface_hub import snapshot_download

    emit("phase", name=tr("Скачивание модели распознавания речи", "Downloading the speech recognition model"))
    t0 = time.time()
    if args.engine == "parakeet":
        run_asr_helper(["download"], _Throttle("download"))
    else:
        snapshot_download(ASR_MODEL)
    log(f"ASR model ready in {time.time() - t0:.0f}s")
    emit("phase", name=tr("Скачивание модели разбивки по ролям", "Downloading the speaker diarization model"))
    t0 = time.time()
    load_pipeline()
    log(f"Diarization model ready in {time.time() - t0:.0f}s")
    emit("done", message=tr("Модели готовы", "Models ready"))


def transcribe(args):
    recording = Path(args.recording).expanduser()
    if not recording.exists():
        fail("not_found", tr(f"Запись не найдена: {recording}", f"Recording not found: {recording}"))
    output = Path(args.output)
    t0 = time.time()
    with tempfile.TemporaryDirectory() as tmp:
        wav = Path(tmp) / "audio.wav"
        emit("phase", name=tr("Извлечение звука", "Extracting audio"))
        separate = extract_audio(recording, wav)
        levels = None
        if not args.no_diarization and args.me and len(separate) == 2:
            levels = (frame_levels(separate["microphone"]), frame_levels(separate["system"]))
        # The user's track apart (headphones), else the mixed way (speakers, one track, no name).
        chunks = None
        if levels and not args.mixed:
            echo = echo_ratio(*levels)
            if echo <= ECHO_LIMIT:
                chunks = speech_chunks(levels[0])
                log(f"Microphone apart: echo {echo:.0%}, {len(chunks)} piece(s), "
                    f"{sum(end - start for start, end in chunks) / 60:.1f} min of the user's speech")
            else:
                log(f"Microphone hears the other side (echo {echo:.0%} > {ECHO_LIMIT:.0%}, speakers?): mixed transcription")
        my_asr = None
        if args.no_diarization:
            emit("phase", name=tr("Распознавание речи", "Recognizing speech"))
            asr = run_asr(str(wav), args.language, args.engine)
            diarization = None
        else:
            emit("phase", name=tr("Распознавание речи и разбивка по ролям", "Recognizing speech and speakers"))
            # One after the other, each in a fresh process: the GPU busy with one model at a time keeps
            # the Mac cooler (and quieter) at the cost of a longer run; nothing waits for the transcript.
            others = str(separate["system"]) if chunks is not None else str(wav)
            with ProcessPoolExecutor(max_workers=1) as pool:
                asr = pool.submit(run_asr, others, args.language, args.engine).result()
            if chunks is not None:
                with ProcessPoolExecutor(max_workers=1) as pool:
                    my_asr = pool.submit(run_chunks_asr, str(separate["microphone"]), chunks, args.language,
                                         args.engine).result()
            with ProcessPoolExecutor(max_workers=1) as pool:
                diarization = pool.submit(run_diarization, others).result()

    emit("phase", name=tr("Сохранение", "Saving"))
    speakers_summary = []
    if diarization:
        names, scores = match_speakers(diarization["embeddings"], load_speakers(args.speakers), args.threshold)
        if my_asr is not None:
            names = without_me(names, args.me)
        elif levels:
            shares = microphone_shares(diarization["turns"], *levels)
            names, mine = name_microphone_speakers(names, shares, args.me)
            for label, (share, seconds) in sorted(shares.items()):
                scores[label]["microphone"] = round(share, 2)
                log(f"{label}: {share:.0%} of {seconds:.0f}s through the microphone{' → ' + args.me if label in mine else ''}")
        speaking = {}
        for turn in diarization["turns"]:
            speaking[turn["speaker"]] = speaking.get(turn["speaker"], 0.0) + turn["end"] - turn["start"]
        if args.one_other:
            merged = merge_other_side(names, speaking, args.me)
            if merged != names:
                log(f"One other person: {', '.join(sorted(l for l in names if merged[l] != names[l]))} → {merged}")
            names = merged
        if my_asr is not None:
            lines, dropped = build_split_lines(asr["segments"], my_asr["segments"], diarization["turns"], names, args.me)
        else:
            lines, dropped = build_lines(asr["segments"], diarization["turns"], names, args.me, levels)
        engine = f"{ENGINES[args.engine]} + pyannote community-1"
        if my_asr is not None:
            mine_seconds = sum(end - start for start, end in chunks)
            speakers_summary.append({"label": "microphone", "name": args.me, "minutes": round(mine_seconds / 60, 1),
                                     "best": args.me, "score": 1.0})
            log(f"microphone: {args.me} ({mine_seconds:.0f}s in {len(chunks)} pieces, "
                f"{len(my_asr['segments'])} phrase(s), language {my_asr['language']}, {my_asr['seconds']:.0f}s)")
        for label in sorted(speaking, key=speaking.get, reverse=True):
            match = scores[label]
            speakers_summary.append({"label": label, "name": names[label], "minutes": round(speaking[label] / 60, 1),
                                     "best": match["name"], "score": match["score"]})
            log(f"{label}: {names[label]} ({speaking[label] / 60:.1f} min; best {match['name']} {match['score']})")
        run_file = Path(args.run_file) if args.run_file else \
            Path(args.runs_dir) / f"{recording.stem}.json" if args.runs_dir else None
        if run_file:
            run_file.parent.mkdir(parents=True, exist_ok=True)
            run_file.write_text(
                json.dumps({"recording": recording.name, "names": names, "scores": scores, **diarization,
                            "microphoneApart": my_asr is not None}),
                encoding="utf-8")
    else:
        lines = [(s["start"], f"[{format_time(s['start'])}] {s['text']}") for s in asr["segments"]]
        dropped = 0
        engine = ENGINES[args.engine]

    markers = load_markers(recording)
    mutes = load_mutes(recording, speech=[s["start"] for s in my_asr["segments"]] if my_asr else ())
    lines = insert_markers(lines, markers + mutes)
    if markers:
        log(f"Inserted {len(markers)} marker(s)")
    if mutes:
        log(f"Inserted {len(mutes)} microphone mute(s)")
    header = [
        f"# Transcription: {recording.name}",
        f"- Date: {datetime.now().strftime('%d %b %Y at %H:%M:%S')}",
        f"- Engine: {engine}",
        f"- Language: {asr['language']}",
    ]
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text("\n".join(header) + "\n\n" + "\n\n".join(lines) + "\n", encoding="utf-8")
    timing = f"ASR {asr['seconds']:.0f}s" + (f" + microphone {my_asr['seconds']:.0f}s" if my_asr else "") \
        + (f", diarization {diarization['seconds']:.0f}s" if diarization else "")
    log(f"Transcript {output}: language {asr['language']}, {len(lines)} lines, dropped {dropped}, {timing}, "
        f"total {time.time() - t0:.0f}s")
    emit("done", output=str(output), language=asr["language"], lines=len(lines) - len(markers) - len(mutes), dropped=dropped,
         seconds=round(time.time() - t0), speakers=speakers_summary)


def enroll_sample(args):
    """Stores the voice in a short solo recording as a reference embedding for `name`."""
    wav = Path(args.wav)
    if not wav.exists():
        fail("not_found", tr(f"Файл образца не найден: {wav}", f"Sample file not found: {wav}"))
    emit("phase", name=tr("Анализ образца голоса", "Analyzing the voice sample"))
    diarization = run_diarization(str(wav))
    if not diarization["turns"]:
        fail("no_speech", tr("В образце не найдена речь. Говорите громче или ближе к микрофону.",
                               "No speech found in the sample. Speak louder or closer to the microphone."))
    speaking = {}
    for turn in diarization["turns"]:
        speaking[turn["speaker"]] = speaking.get(turn["speaker"], 0.0) + turn["end"] - turn["start"]
    label = max(speaking, key=speaking.get)
    if speaking[label] < 5:
        fail("too_short", tr(f"Слишком мало речи в образце ({speaking[label]:.0f} с). Нужно хотя бы 10 секунд.",
                                f"Too little speech in the sample ({speaking[label]:.0f} s). At least 10 seconds are needed."))
    speakers_file = Path(args.speakers)
    references = load_speakers(speakers_file)
    references.setdefault(args.name, []).append(diarization["embeddings"][label])
    speakers_file.parent.mkdir(parents=True, exist_ok=True)
    speakers_file.write_text(json.dumps(references), encoding="utf-8")
    log(f"Enrolled {args.name}: {speaking[label]:.0f}s of speech, now {len(references[args.name])} sample(s)")
    emit("done", name=args.name, samples=len(references[args.name]), speech_seconds=round(speaking[label]))


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)

    d = commands.add_parser("download")
    d.add_argument("--engine", choices=sorted(ENGINES), default="parakeet")
    d.set_defaults(handler=download)

    t = commands.add_parser("transcribe")
    t.add_argument("recording")
    t.add_argument("--output", required=True)
    t.add_argument("--engine", choices=sorted(ENGINES), default="parakeet",
                   help="speech recognition: Parakeet Ultra (MeetRecASR) or mlx-whisper")
    t.add_argument("--no-diarization", action="store_true")
    t.add_argument("--language", default="")
    t.add_argument("--speakers")
    t.add_argument("--runs-dir")
    t.add_argument("--run-file", help="where the speakers of this run go (MeetRec: run.json in the recording's folder)")
    t.add_argument("--threshold", type=float, default=DEFAULT_THRESHOLD)
    t.add_argument("--me", default="", help="the user's name: whoever speaks into the microphone track")
    t.add_argument("--one-other", action="store_true", help="a one-on-one call: everyone but the user is one person")
    t.add_argument("--mixed", action="store_true",
                   help="transcribe both tracks together even with headphones (the way before the microphone apart)")
    t.set_defaults(handler=transcribe)

    e = commands.add_parser("enroll-sample")
    e.add_argument("wav")
    e.add_argument("--name", required=True)
    e.add_argument("--speakers", required=True)
    e.set_defaults(handler=enroll_sample)

    args = parser.parse_args()
    try:
        args.handler(args)
    except SystemExit:
        raise
    except Exception as error:
        import traceback

        traceback.print_exc()
        fail("exception", f"{type(error).__name__}: {error}")


if __name__ == "__main__":
    main()
