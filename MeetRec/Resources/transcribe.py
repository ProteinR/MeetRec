# /// script
# requires-python = ">=3.12,<3.13"
# dependencies = [
#     "mlx-whisper==0.4.3",
#     "pyannote.audio==4.0.7",
#     "librosa==0.11.0",
# ]
# ///
"""MeetRec transcription helper: mlx-whisper large-v3-turbo + pyannote speaker diarization.

Adapted from inventire-workspace .agents/skills/transcribe-meeting. Runs locally on Apple Silicon;
the only network access is the model download from Hugging Face.

Talks to the app through JSON lines on stdout: {"event": "phase"|"progress"|"done"|"error", ...}.
Human-readable diagnostics go to stderr, which the app writes to its log.

Commands:
  download                         fetch both models (and build the uv environment)
  transcribe <recording> --output <md> [--no-diarization] [--language xx] [--speakers file] [--me Name] [--one-other]
  enroll-sample <wav> --name <Name> --speakers <file>
"""
import argparse
import json
import math
import subprocess
import sys
import tempfile
import time
from concurrent.futures import ProcessPoolExecutor
from datetime import datetime
from pathlib import Path

ASR_MODEL = "mlx-community/whisper-large-v3-turbo"
DIARIZATION_MODEL = "pyannote/speaker-diarization-community-1"
ENGINE = "mlx-whisper large-v3-turbo"
SAMPLE_RATE = 16000
DEFAULT_THRESHOLD = 0.7


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
        fail("no_audio", "В записи нет звука")
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


# ── Engines ──────────────────────────────────────────────────────────────────────────────────────

def run_asr(wav_path, language):
    import mlx_whisper

    # `mlx_whisper.transcribe` is shadowed by the function of the same name; patch the module's tqdm
    # so decoding reports progress events instead of drawing a terminal bar.
    sys.modules["mlx_whisper.transcribe"].tqdm.tqdm = _AsrProgress
    t0 = time.time()
    result = mlx_whisper.transcribe(
        load_audio(wav_path),
        path_or_hf_repo=ASR_MODEL,
        word_timestamps=False,
        condition_on_previous_text=False,
        language=language or None,
    )
    segments = [
        {"start": s["start"], "end": s["end"], "text": s["text"].strip()}
        for s in result["segments"]
        if s["text"].strip()
    ]
    return {"language": result.get("language"), "segments": segments, "seconds": time.time() - t0}


def load_pipeline():
    import torch
    from pyannote.audio import Pipeline

    try:
        pipeline = Pipeline.from_pretrained(DIARIZATION_MODEL)
    except Exception as error:  # gated repo, missing token, network
        text = f"{type(error).__name__}: {error}"
        if "Gated" in text or "403" in text or "401" in text or "token" in text.lower():
            fail("gated", "Нет доступа к модели pyannote: нужен вход в Hugging Face и принятые условия модели "
                          "pyannote/speaker-diarization-community-1")
        raise
    if pipeline is None:
        fail("gated", "Модель pyannote не загрузилась: проверьте токен Hugging Face")
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


def build_lines(segments, turns, names, me=None, levels=None):
    """Transcript lines; with the user's name and the microphone/system levels, phrases spoken into
    the microphone are the user's."""
    lines, previous, dropped = [], object(), 0
    for segment in segments:
        label = assign_speaker(segment, turns)
        mine = bool(me and levels and spoken_into_microphone(segment, levels))
        if label is None and not mine:
            dropped += 1  # Whisper hallucinations in silence ("Thank you.")
            continue
        name = me if mine else names[label]
        if lines and name == previous:
            lines[-1][2] += " " + segment["text"]
        else:
            lines.append([segment["start"], name, segment["text"]])
            previous = name
    return [(start, f"[{format_time(start)}] {name}: {text}") for start, name, text in lines], dropped


def load_markers(recording):
    """Moments marked during recording (`<name>.markers.json` next to the video), as seconds."""
    path = recording.with_name(recording.stem + ".markers.json")
    if not path.exists():
        return []
    try:
        return sorted(float(m["time"]) for m in json.loads(path.read_text(encoding="utf-8")))
    except (ValueError, KeyError, TypeError) as error:
        log(f"Ignoring unreadable markers file {path}: {error}")
        return []


def insert_markers(timed_lines, markers):
    """Puts a "⭐" line before the first replica that starts at or after each marker."""
    result, pending = [], list(markers)
    for start, text in timed_lines:
        while pending and pending[0] <= start:
            result.append(f"⭐ [{format_time(pending.pop(0))}] Отметка")
        result.append(text)
    result.extend(f"⭐ [{format_time(m)}] Отметка" for m in pending)
    return result


# ── Commands ─────────────────────────────────────────────────────────────────────────────────────

def download(args):
    from huggingface_hub import snapshot_download

    emit("phase", name="Скачивание модели распознавания речи")
    t0 = time.time()
    snapshot_download(ASR_MODEL)
    log(f"ASR model ready in {time.time() - t0:.0f}s")
    emit("phase", name="Скачивание модели разбивки по ролям")
    t0 = time.time()
    load_pipeline()
    log(f"Diarization model ready in {time.time() - t0:.0f}s")
    emit("done", message="Модели готовы")


def transcribe(args):
    recording = Path(args.recording).expanduser()
    if not recording.exists():
        fail("not_found", f"Запись не найдена: {recording}")
    output = Path(args.output)
    t0 = time.time()
    with tempfile.TemporaryDirectory() as tmp:
        wav = Path(tmp) / "audio.wav"
        emit("phase", name="Извлечение звука")
        separate = extract_audio(recording, wav)
        levels = None
        if not args.no_diarization and args.me and len(separate) == 2:
            levels = (frame_levels(separate["microphone"]), frame_levels(separate["system"]))
        if args.no_diarization:
            emit("phase", name="Распознавание речи")
            asr = run_asr(str(wav), args.language)
            diarization = None
        else:
            emit("phase", name="Распознавание речи и разбивка по ролям")
            with ProcessPoolExecutor(max_workers=2) as pool:
                asr_future = pool.submit(run_asr, str(wav), args.language)
                diarization_future = pool.submit(run_diarization, str(wav))
                asr, diarization = asr_future.result(), diarization_future.result()

    emit("phase", name="Сохранение")
    speakers_summary = []
    if diarization:
        names, scores = match_speakers(diarization["embeddings"], load_speakers(args.speakers), args.threshold)
        if levels:
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
        lines, dropped = build_lines(asr["segments"], diarization["turns"], names, args.me, levels)
        engine = f"{ENGINE} + pyannote community-1"
        for label in sorted(speaking, key=speaking.get, reverse=True):
            match = scores[label]
            speakers_summary.append({"label": label, "name": names[label], "minutes": round(speaking[label] / 60, 1),
                                     "best": match["name"], "score": match["score"]})
            log(f"{label}: {names[label]} ({speaking[label] / 60:.1f} min; best {match['name']} {match['score']})")
        if args.runs_dir:
            runs = Path(args.runs_dir)
            runs.mkdir(parents=True, exist_ok=True)
            (runs / f"{recording.stem}.json").write_text(
                json.dumps({"recording": recording.name, "names": names, "scores": scores, **diarization}),
                encoding="utf-8")
    else:
        lines = [(s["start"], f"[{format_time(s['start'])}] {s['text']}") for s in asr["segments"]]
        dropped = 0
        engine = ENGINE

    markers = load_markers(recording)
    lines = insert_markers(lines, markers)
    if markers:
        log(f"Inserted {len(markers)} marker(s)")
    header = [
        f"# Transcription: {recording.name}",
        f"- Date: {datetime.now().strftime('%d %b %Y at %H:%M:%S')}",
        f"- Engine: {engine}",
        f"- Language: {asr['language']}",
    ]
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text("\n".join(header) + "\n\n" + "\n\n".join(lines) + "\n", encoding="utf-8")
    timing = f"ASR {asr['seconds']:.0f}s" + (f", diarization {diarization['seconds']:.0f}s" if diarization else "")
    log(f"Transcript {output}: language {asr['language']}, {len(lines)} lines, dropped {dropped}, {timing}, "
        f"total {time.time() - t0:.0f}s")
    emit("done", output=str(output), language=asr["language"], lines=len(lines) - len(markers), dropped=dropped,
         seconds=round(time.time() - t0), speakers=speakers_summary)


def enroll_sample(args):
    """Stores the voice in a short solo recording as a reference embedding for `name`."""
    wav = Path(args.wav)
    if not wav.exists():
        fail("not_found", f"Файл образца не найден: {wav}")
    emit("phase", name="Анализ образца голоса")
    diarization = run_diarization(str(wav))
    if not diarization["turns"]:
        fail("no_speech", "В образце не найдена речь. Говорите громче или ближе к микрофону.")
    speaking = {}
    for turn in diarization["turns"]:
        speaking[turn["speaker"]] = speaking.get(turn["speaker"], 0.0) + turn["end"] - turn["start"]
    label = max(speaking, key=speaking.get)
    if speaking[label] < 5:
        fail("too_short", f"Слишком мало речи в образце ({speaking[label]:.0f} с). Нужно хотя бы 10 секунд.")
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

    commands.add_parser("download").set_defaults(handler=download)

    t = commands.add_parser("transcribe")
    t.add_argument("recording")
    t.add_argument("--output", required=True)
    t.add_argument("--no-diarization", action="store_true")
    t.add_argument("--language", default="")
    t.add_argument("--speakers")
    t.add_argument("--runs-dir")
    t.add_argument("--threshold", type=float, default=DEFAULT_THRESHOLD)
    t.add_argument("--me", default="", help="the user's name: whoever speaks into the microphone track")
    t.add_argument("--one-other", action="store_true", help="a one-on-one call: everyone but the user is one person")
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
