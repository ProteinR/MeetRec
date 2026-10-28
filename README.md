# MeetRec — meeting recorder for Mac with local transcription

**English** | [Русский](README.ru.md)

**MeetRec** is a free, open-source macOS menu bar app that **records meetings and calls** — the
screen, your microphone and the other side's audio — and **transcribes them on your Mac** with
Parakeet and speaker diarization. No bot joins your call and nothing is uploaded. It also takes
**screenshots with annotations and OCR**, Shottr-style.

It started as a lightweight **OBS alternative** (13 MB, ~40 MB of memory) for one job: pressing "record" in Microsoft Teams,
Google Meet, Zoom (in a browser) or Telegram calls, without scenes, sources and encoder settings.

**English and Russian.** MeetRec follows the system language; another one can be chosen in Settings →
Recording → Language. Translations to other languages are
welcome (`MeetRec/Localizable.xcstrings`).

<p align="center">
  <img src="docs/images/recordings.png" width="420" alt="MeetRec menu bar panel: start button, microphone and system audio, recordings with transcripts and markers">
  <img src="docs/images/settings-meetings.png" width="420" alt="Meeting detection settings: Teams records automatically, Telegram and browser ask first, browser tab rules">
</p>

<p align="center">
  <img src="docs/images/editor.gif" width="760" alt="Screenshot editor: arrow, rectangle, numbered steps and blur">
</p>

## Features

- **One click or ⌃⌥⌘R** to record the screen, microphone and system audio into a crash-safe
  fragmented `.mov` (separate tracks plus a mixed one; ~0.5 GB/hour at 1440p HEVC).
- **Automatic meeting recording**: starts when Microsoft Teams takes the microphone and stops when
  it lets go; calls in browsers and Telegram ask first; browser tab rules record known calls
  without asking.
- **Live status**: level meters for both sides, ⚠️ in the menu bar when a source goes silent, disk
  space guard, crash watchdog.
- **Markers, pause and chapters**: ⭐ markers become chapters in the video and lines in the
  transcript; pause works like in OBS.
- **Local transcription** with speaker names (Parakeet Ultra on the Neural Engine + pyannote,
  nothing leaves the Mac; Whisper as an option):
  your own speech is found through the microphone track, other voices are recognised from enrolled
  samples.
- **Screenshots** (⇧⌘4) with a frozen screen, window shots on wallpaper, an annotation editor
  (arrows, boxes, steps, blur, crop), OCR (⇧⌘2) and reverse image search.
- Window recording, display picker with live thumbnails, a recording island at the notch, a camera
  mirror to check yourself before a call.

## Lightweight by design

Measured on the same Mac (Apple Silicon, macOS 26), same job: the built-in display at 2216×1440,
HEVC, 15 fps, microphone and system audio; OBS with the window minimized to the tray. Memory is the
footprint Activity Monitor shows, CPU is % of one core averaged over 60 s
(`scripts/profile.py`, details in [PROFILING.md](PROFILING.md)).

| | MeetRec 0.7.0 | OBS Studio 32.2.2 |
|---|---|---|
| App size | **13 MB** | 438 MB + a virtual camera system extension |
| Idle: memory | **41 MB** | 193 MB |
| Idle: CPU | **0.1%** | 7.3% |
| Recording: memory | **36–50 MB** | 339 MB |
| Recording: CPU | **12%** | 21% |
| Idle wake-ups | 0.1/s | 1/s (+124/s in the camera extension) |

MeetRec does nothing between meetings: no preview, no scene rendering. While recording, unchanged
frames are skipped and video is encoded in hardware; most of the remaining CPU is AAC encoding of
the two audio tracks and receiving frames from ScreenCaptureKit. The camera mirror runs in its own
process, so its 200–350 MB leave with its window. Transcription runs after the recording at
background priority, one model at a time.

## How it compares

MeetRec is small and does one thing end to end: a video of the meeting, both sides' audio and a
local transcript with names. If you need something else, the others below are good at it.

| | MeetRec | OBS Studio | Otter.ai | Granola | MacWhisper |
|---|---|---|---|---|---|
| Records the screen (video) | ✅ | ✅ | — | — | — |
| Records your mic and the other side | ✅ separate tracks | ✅ with setup | ✅ | ✅ | ✅ |
| Starts and stops with the meeting | ✅ Teams, browser, Telegram | — | ✅ (calendar bot) | Asks, stops by itself | ✅ |
| Joins the call as a bot | No | No | Yes (OtterPilot) | No | No |
| Transcription | On your Mac | — | Cloud | Cloud | On your Mac |
| Speaker names | ✅ from voice samples | — | ✅ | ✅ | ✅ (Pro) |
| AI summaries | — | — | ✅ | ✅ | ✅ (your API key) |
| Screenshots, annotations, OCR | ✅ | — | — | — | — |
| Price / source | Free, MIT | Free, GPL | Subscription | Subscription | Paid |

Compared with the screenshot apps: like **Shottr** and **CleanShot X**, MeetRec freezes the screen,
captures an area or a window on its wallpaper, and annotates (arrows, boxes, numbered steps, blur,
crop) with OCR and reverse image search. It has no scrolling capture, cloud upload or video
annotations; those apps are the better choice if you need them.

<sub>Based on the vendors' public descriptions as of October 2026; corrections welcome.</sub>

<details>
<summary>More screenshots</summary>

<p align="center">
  <img src="docs/images/screenshots-section.png" width="420" alt="Recent screenshots in the panel with Screenshot and OCR buttons">
  <img src="docs/images/settings-screenshots.png" width="420" alt="Screenshot settings: clipboard, folder, format, wallpaper margin, image search services">
  <img src="docs/images/settings-shortcuts.png" width="420" alt="Shortcut settings for recording, markers, pause, screenshot and OCR">
</p>
</details>

## Requirements

- macOS 15 or later, Apple Silicon (transcription uses MLX).
- Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).
- For transcription: [uv](https://docs.astral.sh/uv/) (`brew install uv`) and a Hugging Face
  account (below).

## Build and install

```bash
git clone https://github.com/ProteinR/MeetRec.git
cd MeetRec
./scripts/install.sh
```

This builds a Release copy, signs it, installs it to `~/Applications/MeetRec.app` and starts it.
On first start macOS asks for Screen Recording and Microphone access; start MeetRec again after
granting Screen Recording.

### Signing (keeps permissions across rebuilds)

There are no signed binary releases (no Apple Developer account). Without a stable signature every
rebuild looks like a new app to macOS and the permissions have to be granted again. To avoid that,
create a self-signed code signing certificate once:

1. Keychain Access → Certificate Assistant → Create a Certificate…
2. Name: `MeetRec Local Code Signing`, Identity Type: Self-Signed Root, Certificate Type: Code
   Signing.

`install.sh` finds it by that name (or set `MEETREC_SIGN_IDENTITY` to another one). Without it the
app is ad-hoc signed and still works.

If permissions get stuck (granted but the app keeps asking):

```bash
tccutil reset ScreenCapture com.dmemruk.MeetRec
tccutil reset Microphone com.dmemruk.MeetRec
```

### Transcription setup

1. Accept the conditions of
   [pyannote/speaker-diarization-community-1](https://huggingface.co/pyannote/speaker-diarization-community-1)
   on Hugging Face.
2. Log in once in the terminal: `uvx --from huggingface_hub hf auth login` (stores the token in `~/.cache/huggingface`).
3. In MeetRec: Settings → Recording → Transcription → Download models (~2 GB, once).

Everything then runs locally at background priority.

## Configuring with scripts or AI agents

All settings are user defaults; [SETTINGS.md](SETTINGS.md) lists every key, its values and the
JSON formats (browser rules, transcript copy rules, shortcuts), so an agent can set MeetRec up with
`defaults write`. [AGENTS.md](AGENTS.md) describes how the app works for agents changing the code.

## Tests

```bash
xcodegen generate
xcodebuild test -project MeetRec.xcodeproj -scheme MeetRec -destination 'platform=macOS' -derivedDataPath build/dd-test
python3 -m unittest discover -s Tests
```

## FAQ

**Does MeetRec work with Zoom, Google Meet or Slack huddles?** Calls in a browser (Chrome, Safari,
Arc, Edge, Firefox, Brave and others) are detected and MeetRec asks whether to record; a tab rule
can record a site without asking. Microsoft Teams and Telegram desktop apps are detected too. The
Zoom, Slack, Webex and FaceTime apps are not detected yet, but you can always start a recording by
hand (⌃⌥⌘R).

**Is anything sent to the cloud?** No. Recording and transcription run on your Mac; the only network
access is the one-time model download from Hugging Face (and image search, when you click it).

**Which Macs?** macOS 15 or later; transcription needs Apple Silicon (MLX). It is built and used on
Apple Silicon only.

## Notes

- Image search buttons use the services' public upload pages (no official APIs) and may break
  when a site changes. Only Google Lens is on by default; others can be turned on in settings.
- Recording other people may require their consent where you live. MeetRec does not notify
  participants.

## License

[MIT](LICENSE)

