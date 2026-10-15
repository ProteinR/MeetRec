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

- Optional meeting auto-recording: starts when Microsoft Teams holds the microphone for 5 s, opens the
  panel so it is visible, and stops 15 s after Teams releases the mic (never stops manual recordings).

- During a recording: ⭐ markers (⌃⌥⌘M or the panel button) saved to `<recording>.markers.json` and
  inserted into the transcript; switching to a single window (others and notifications left out),
  falling back to the whole screen if that window closes.
- Disk space guard: no start below 1 GB free, warning below 3 GB, automatic clean stop below 500 MB.
- File names get the meeting title (recorded window or Teams meeting window) before the timestamp,
  which always stays at the end: `Weekly sync 2026-10-16 14-03-22.mov`. The recordings list can
  rename (keeping the timestamp), move to Trash, re-transcribe (new `name (2).md`, old kept) and search
  names and transcript text. Renames and deletes take the `.md` and `.markers.json` files along.
- Launch at login (`SMAppService`) toggle; Teams' "Microsoft Teams Audio" loopback is hidden from
  the microphone list.

- Teams auto-recordings are tagged on the video file (extended attribute
  `com.dmemruk.MeetRec.meetingApp = teams`, set at start; survives renames and Trash). After
  transcription their transcript is also copied to the "meeting transcripts" folder (setting
  `meetingTranscriptsFolder`, here inventire-workspace `docs/meetings`) as `<video name>.md`: only
  recordings of 2+ minutes, never overwriting an existing file (it may hold a Meeting Summary), and a
  failed copy only warns. Log line `Transcript copied: <src> → <dst>`. Manual recordings are never
  copied; their transcript stays only next to the video.

- Safety while recording: the Mac and displays are kept awake; a warning (notification with
  "Записывать «монитор»" / "Игнорировать", and a banner in the panel) when the Teams meeting window is
  not on the recorded display for 10 s; alerts when the file stops growing for 30 s, the picture is
  completely black for 30 s, or the whole Mac's CPU stays above 90 % for a minute. The panel shows
  system CPU and MeetRec's own CPU/memory; the log gets a `Load:` line every 30 s (idle: every 10 min).
- "Встреча идёт, а запись не ведётся": the detector also runs with auto-recording off and reminds
  once per meeting (also after a failed auto-start or a manual stop mid-meeting), with a start button.
- Permissions (screen, microphone) are checked at launch and every 30 min, with a notification.
- Crash watchdog (`Watchdog.swift`): a `running` flag file plus a launchd agent
  `~/Library/LaunchAgents/com.dmemruk.MeetRec.watchdog.plist` that reopens MeetRec within ~10 s if
  it died. `recording.json` remembers the file being written; after a crash the file is reported and
  transcribed, a manual recording continues in a new file (a meeting one is restarted by the
  detector), but not after a second crash within 3 minutes. Quitting while recording finishes the
  file first; `install.sh` quits gracefully so the watchdog does not relaunch the old copy.

- Naming speakers after the fact: "Подписать спикеров…" in a recording's menu lists the diarized
  speakers (`runs/<recording>.json`: names, scores, turns, voice embeddings), with their first words
  and closest known voice. A name given there adds that speaker's embedding to `speakers.json` (new
  person or extra sample) and renames them in the transcript, joining neighbouring lines; the meetings
  copy is updated only if it is still identical to the transcript. The run file follows renames.

Planned next: more calling apps (Telegram, Zoom, Google Meet in browsers) once checked for false positives.

Principles: small, native (Swift, ScreenCaptureKit, no Electron, no third-party Swift packages),
dependable over feature-rich. Prefer fewer features, and never risk losing a recording.

## How it works

- `MeetRec/MeetRecApp.swift` + `MenuPanel.swift`: `AppDelegate` owns an `NSStatusItem` and a
  borderless, transparent, fixed-size panel window; the visible card (blur, corners, shadow) is drawn
  by SwiftUI (`PanelCard`) and hugs the content, so accordion sections (`CollapsibleSection`: Video,
  Transcription, Recordings; one open at a time) animate their height smoothly. Do not make the window
  follow SwiftUI's size again: that caused jumps and, with Auto Layout, a launch crash. Clicking the
  item or reopening the app shows the panel; clicks outside (including the transparent part, which is
  click-through), Esc or ⌘W close it. If Ice hides the item (it moves hidden items off screen), the
  panel opens at the top right. `NSPopover` was dropped: anchored to a fake view it misplaced its arrow.
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
- `MeetRec/MeetingDetector.swift` + `MeetingSettings.swift`: polls CoreAudio process objects once a
  second (`kAudioHardwarePropertyProcessObjectList`, `kAudioProcessPropertyIsRunningInput`,
  `kAudioProcessPropertyBundleID`; macOS 14.4+, no permission) to see which apps capture a microphone.
  Apps are matched by bundle ID prefix (`MeetingApp.all`; Teams audio comes from
  `com.microsoft.teams2.helper`/`.modulehost`). Only `supported` apps can be enabled; the others are
  listed when installed, marked "скоро". This is the same signal other meeting recorders use (the app
  holding the microphone); calendar-based detection was considered less reliable for start/end.
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
