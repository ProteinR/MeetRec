# MeetRec: agent guide

## What this is and why

MeetRec is a personal macOS menu bar app for recording the screen during meetings and turning the
recordings into transcripts. It was written to replace **OBS**, which the owner used for exactly one
thing: pressing "record" in a meeting to capture the screen, the microphone and the other people's
voices. For that job OBS was the wrong tool:

- **Heavy for the task.** About 440 MB installed, a virtual camera system extension, scenes, sources,
  encoders and streaming settings, of which only "Start Recording" was ever used.
- **Manual.** Open OBS, check the scene, start, remember to stop. Nothing tells you mid-meeting that
  the microphone went silent or the wrong device is recording.
- **Large files.** 143 recordings took 12 GB; a mostly static screen at a few frames per second needs
  far less.
- **Not connected to transcription.** Recordings were transcribed afterwards by hand with the
  `transcribe-meeting` skill in inventire-workspace (and `transcribe-lesson` in the English project).

Typical recordings: Microsoft Teams work meetings, English lessons in Chrome, Telegram calls and other
calls in the browser. Video is always needed. The external monitor is usually the one to record.

What MeetRec does instead:

- One menu bar icon and a small dropdown panel: start/stop button, global hotkey ⌃⌥⌘R, display picker
  (auto prefers the external monitor), system audio and microphone toggles, microphone picker, FPS,
  resolution and codec.
- Live recording status: microphone and system audio level meters with the actual device name,
  screen and file state; a ⚠️ in the menu bar when a source stops delivering.
- Crash-safe fragmented `.mov` with separate tracks for video, system audio and microphone; around
  0.5 GB per hour at 1440p HEVC.
- Optional local transcription after each recording (mlx-whisper + pyannote, nothing leaves the Mac),
  speaker names from enrolled voices including the owner's own voice sample, and a recordings list
  showing which videos are transcribed or how far a running transcription is.
- Detailed logs, so problems in a long meeting can be traced afterwards.

Planned next: start and stop recording automatically when a Microsoft Teams call starts and ends.

Principles: small, native (Swift, ScreenCaptureKit, no Electron, no third-party Swift packages),
dependable over feature-rich. Prefer fewer features, and never risk losing a recording.

## How it works

- `MeetRec/MeetRecApp.swift` + `MenuPanel.swift`: `AppDelegate` owns an `NSStatusItem` and a
  borderless panel hosting `ContentView`. Clicking the item or opening the app again (Finder,
  Spotlight) shows the panel; clicking outside, Esc or ⌘W closes it. If Ice hides the item (it moves
  hidden items off screen), the panel opens at the top right under the menu bar. `NSPopover` was
  dropped on purpose: anchored to a fake view it drew its arrow in the wrong place whenever the content
  changed height. There is no standalone window.
- `MeetRec/RecorderModel.swift`: settings (`@AppStorage`), device lists, permissions, start/stop,
  global hotkey ⌃⌥⌘R, system event logging (sleep/wake/lock, device changes).
- `MeetRec/ScreenRecorder.swift`: ScreenCaptureKit (`SCStream` with `.screen`, `.audio`,
  `.microphone` outputs) → `AVAssetWriter` writing a **fragmented** `.mov` (5 s fragments: a crash
  loses seconds, not the file). Tracks: H.264/HEVC video, system audio (AAC stereo), microphone (AAC
  mono) kept separate for transcription. Idle (unchanged) frames are skipped, so frame rate is variable.
- `MeetRec/Log.swift`: logs to `~/Library/Logs/MeetRec/meetrec.log` (rotated at 5 MB) and the unified
  log, subsystem `com.dmemruk.MeetRec`. Stats every 10 s, verified track info after each recording.
  Read this log first when something goes wrong.
- `MeetRec/HotKey.swift`: Carbon global hotkey (no Accessibility permission needed).
- `MeetRec/RecordingHealth.swift`: live status while recording (mic/system levels, screen, file);
  red "no signal" turns the menu bar icon into ⚠️.
- Transcription (`Transcriber.swift`, `TranscriptionViews.swift`, `VoiceSampleRecorder.swift`,
  `Resources/transcribe.py`): after a recording, optionally runs the bundled helper with `uv run`
  (mlx-whisper large-v3-turbo + pyannote speaker-diarization-community-1, adapted from
  inventire-workspace `.agents/skills/transcribe-meeting`). Both audio tracks are mixed before
  recognition. Transcript: `<recording>.md` next to the video, never overwritten. Models: the shared
  Hugging Face cache `~/.cache/huggingface/hub` (pyannote is gated: needs an HF token and accepted
  conditions). Voices: `~/Library/Application Support/MeetRec/speakers.json`, seeded once as a copy of
  `~/.local/share/inventire-meetings/speakers.json`; "record voice sample" enrolls the user's own voice
  under "Моё имя". The helper talks JSON lines on stdout; its stderr goes to the MeetRec log.

## Build and install

Requires Xcode and XcodeGen. `project.yml` is the source of truth; the `.xcodeproj` and
`Info.plist` are generated and git-ignored.

```bash
./scripts/install.sh   # build Release, re-sign, install to ~/Applications, relaunch
```

## Signing and permissions (important)

There is no Apple Developer account. Xcode builds ad-hoc; `install.sh` then re-signs with the local
self-signed certificate **"dmemruk Local Code Signing"** from the login keychain. macOS ties Screen
Recording and Microphone permissions to the signature's designated requirement; with this
certificate it is the certificate itself, so permissions survive rebuilds. With plain ad-hoc
signing every rebuild looks like a new app and permissions are lost.

If permissions get stuck (granted in System Settings but the app keeps asking):

```bash
tccutil reset ScreenCapture com.dmemruk.MeetRec
tccutil reset Microphone com.dmemruk.MeetRec
```

then launch, grant again, and relaunch after granting Screen Recording.

## Rules

- Do not add an App Sandbox, hardened runtime or a team id: the local signing setup depends on it.
- Never reinstall while a recording is running (`install.sh` kills the app): check the log's last
  "Recording state" line first.
- Swift 5 language mode; target macOS 15+ (needed for microphone capture in ScreenCaptureKit).
- The icon is generated by `scripts/make-icon.swift`; re-run it instead of editing PNGs.
