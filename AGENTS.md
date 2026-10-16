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
  0.5 GB per hour at 1440p HEVC. After the stop the file gets a mixed audio track first
  (`ChapterWriter.finish` + `AudioMixer`, one copy together with the chapters): audio layout
  1 — mix (the only enabled/default track), 2 — microphone, 3 — system audio, one alternate group.
  Players that play one track (IINA, VLC, browsers, messengers) play both sides; QuickTime does not
  double them. In the mix the microphone is raised once per recording to the other side's speech
  level (ScreenCaptureKit gives the raw mic, the call app's side comes processed and ~10 dB louder),
  max +18 dB, soft limiter; the separate tracks stay as recorded. On failure the file stays as written.
- Optional local transcription after each recording (mlx-whisper + pyannote, nothing leaves the Mac),
  speaker names from enrolled voices including the owner's own voice sample, and a recordings list
  showing which videos are transcribed or how far a running transcription is.
- Detailed logs, so problems in a long meeting can be traced afterwards.

- Optional meeting auto-recording: starts when Microsoft Teams holds the microphone for 5 s, opens the
  panel so it is visible, and stops 15 s after Teams releases the mic (never stops manual recordings).

- During a recording: ⭐ markers (⌃⌥⌘M or the panel button) saved to `<recording>.markers.json` and
  inserted into the transcript; switching to a single window (others and notifications left out; the window alone is scaled to
  fill the frame, `desktopIndependentWindow` + `scalesToFit`),
  falling back to the whole screen if that window closes.
- Disk space guard: no start below 1 GB free, warning below 3 GB, automatic clean stop below 500 MB.
- File names get the Teams meeting window's title (only that; browser tabs and other windows are
  ignored, and so are Teams' tiny/hidden helper windows like the 1×1 "Teams NRC"; the log lists the
  Teams windows at launch and with each title) after the timestamp,
  which always comes first so Finder sorts by time: `2026-10-16 14-03-22 Weekly sync.mov`. The
  recordings list can rename (keeping the timestamp first), move to Trash, re-transcribe (new `name (2).md`, old kept) and search
  names and transcript text. Renames and deletes take the `.md` and `.markers.json` files along.
- Monitor choice is an accordion section on the main page titled with the display to be recorded;
  opened, it shows live thumbnails of all displays (refreshed every 2 s, `DisplayPreview.swift`),
  the one to be recorded framed in red, an "Авто" switch, and a red frame around that whole screen
  (`DisplayHighlight`, click-through) so the choice is visible on the monitor itself. The same frame
  blinks softly three times on the recorded screen when any recording starts or switches screens
  (not in the discreet style).
- "Как я выгляжу" (person icon next to the gear, or the quick menu): a floating mirrored camera
  window (`CameraMirror.swift`) to check yourself before a meeting; camera picker on hover, Esc or ✕
  closes it and stops the camera. Nothing is recorded.
- Launch at login (`SMAppService`) toggle; Teams' "Microsoft Teams Audio" loopback is hidden from
  the microphone list.

- Teams auto-recordings are tagged on the video file (extended attribute
  `com.dmemruk.MeetRec.meetingApp = teams`, set at start; survives renames and Trash). After
  transcription their transcript is also copied by the copy rules ("app → folder", any number,
  setting `transcriptCopyRules`; here Teams → inventire-workspace `docs/meetings`) as `<video name>.md`: only
  recordings of 2+ minutes, never overwriting an existing file (it may hold a Meeting Summary), and a
  failed copy only warns. Log line `Transcript copied: <src> → <dst>`. Manual recordings are never
  copied; their transcript stays only next to the video.

- Safety while recording: the Mac and displays are kept awake. In the first 30 s the Teams meeting
  window must show up on the recorded display once; if it was only seen on another monitor, one
  silent warning ("Записывать «монитор»" / "Оставить как есть"); later moves and minimising (screen
  sharing) are ignored. Silent alerts when the file stops growing or the picture is black for 30 s,
  or the microphone gives dead silence (not even room noise) for a minute (once per recording);
  the other side being silent and high CPU are never alerted (CPU is only logged). The panel shows
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

- Words: Teams = "встреча", browser/Telegram = "звонок"; "Запись сохранена"; "транскрипт" for the
  result, "транскрибация" for the process. Alerts during a recording have no sound; "hide from screen
  sharing" is on by default; the island only shows on a notched main screen.
- "Значок в меню": the menu bar look while recording (red icon + timer / red icon only / discreet:
  monochrome icon, filled while recording, no timer, no auto-opening of the panel), and "Прятать
  MeetRec при показе экрана" (`sharingType = .none` on the status item and panel windows; whether a
  calling app honours it is not verified yet). macOS's own mic/screen-recording indicators cannot be
  hidden.

- Recording island (`NotchIsland.swift`): Mac apps cannot start Live Activities, so MeetRec draws its
  own Dynamic-Island-style window on the main screen while recording: around the notch if that
  screen has one, else a floating capsule under the menu bar. Red dot + timer; hover expands it with
  level meters, marker and stop. The window is resized between states so its transparent parts never
  block clicks. Off in the discreet style; follows "hide from screen sharing".

- Calls in a browser (Chrome, Safari, Arc, Edge, Firefox, Yandex, Brave, Opera, Vivaldi) and in
  Telegram are "ask-first" apps (`MeetingApp.asks`): they also hold the mic for dictation or voice
  messages, so after 10 s (browser) / 15 s (Telegram) the panel and a notification ask "Похоже, идёт
  звонок… Записать?". "Записать" starts a meeting recording (tagged with the app id, auto-stops when
  the call ends); "Не сейчас" is silent for the rest of that call.

- Browser rules (`browserAutoRules`): text in a browser window title (active tab) → record without
  asking, with an optional file title, e.g. "Vimbox" → "Skyeng" for English lessons. Such recordings
  also get the xattr `com.dmemruk.MeetRec.rule = <rule id>`, and copy rules can target a browser
  rule (`rule:<id>`), so e.g. Skyeng lessons are copied to their own folder.
- Settings live on a separate page behind the gear (general: folder, log, launch at login,
  watchdog; video; transcription incl. copy rules; meetings incl. browser rules; menu bar look with
  a preview). The main page keeps the daily things: no transcription block (progress is per recording in
  the list, cancel in its right-click menu) no Quit button (it is in the item's right-click menu) and no folder row (the folder
  button is next to the search field in "Записи").

- UX rules: the panel opens only by the user (click on the item / island / a notification, or a
  manual launch; not at login or a watchdog relaunch). Live moments (recording started, call
  question, recording saved) are a small toast under the menu bar item (`Toast.swift`) that never
  takes keyboard focus; start/saved fold away by themselves, a question waits for an answer or the
  end of the call. Problems (silent mic, disk, cut recording, permissions) are macOS notifications.
  After Start in the panel the button morphs and the panel fades out. A stop of any kind
  while the panel is open fades the whole panel out at once (`foldPanelNotification`, layout frozen
  meanwhile) without waiting for the file; the "Запись сохранена" toast gives the result. The panel then keeps a notice for the last
  recording (`LastRecordingNotice`): saved with start–end time and duration, and its transcript state
  (percent while running, "Транскрипт готов" opens it, retry on failure).
  No markers while stopping. Right click on the item
  opens a quick menu; ⌘, opens settings.

- Microphone follows the call (`AudioDevices.swift`): CoreAudio process objects tell which input
  device the call app captures from (`kAudioProcessPropertyDevices`, input scope only). In "По
  умолчанию" mode a meeting recording starts with that device and switches mid-recording
  (`SCStream.updateConfiguration`) when the call or the system default changes and stays for two
  checks (~6 s); a microphone chosen by hand (in settings or during the recording) is never changed,
  only suggested once per device. The live status has a microphone menu.
- Microphone level preview in the panel (`MicrophoneMonitor.swift`) runs while the panel is open, but a
  Bluetooth microphone is opened only by "Проверить": opening AirPods' mic switches them to the
  headset profile, and a Bluetooth mouse then stutters (the cursor jumped on every panel open).

- Countdown before an automatic recording (Teams, browser rules; not in the discreet style): from
  "the app took the mic" to the start, grey seconds next to the menu bar icon and a panel banner
  "Через N с начну записывать…" with "Записать сейчас" / "Не записывать" (skips this meeting only).

- Countdown before the automatic stop (the app released the mic, 15 s): grey seconds after the
  timer ("34:12 · 9") and a panel banner with "Остановить сейчас" / "Продолжить запись" (then it
  keeps running like a manual recording). Taking the mic again cancels it.
- Each meeting app has a mode in settings, "Записывать" (record by itself, with the countdown) or
  "Спрашивать" (the "Записать?" question); defaults: Teams records, browser and Telegram ask
  (`meetingAppModes`, `RecorderModel.asks(_:)`). Browser site rules show while the browser asks.

- Markers become chapters: after a recording with markers stops, `ChapterWriter` copies the file
  without re-encoding (reader → writer, ~1 s per minute) adding a 3GPP text track associated with the
  video as its chapter list ("Начало", "⭐ 1 · 12:34"…), checks the copy (tracks, duration, chapters),
  then replaces the original and restores the xattr tags; on any failure the original stays. The
  recordings list shows "⭐ N"; each time opens the video in QuickTime at that moment (AppleScript,
  `QuickTimeOpener`); older recordings have "Добавить отметки в видео как главы".

- Switching what is recorded mid-recording (another monitor, a window, back) fades through black in the video: `ScreenRecorder`
  writes darkened copies of the last frame (0.35 s out, black until the new screen's first frame,
  0.45 s in; a static screen sends no frames of its own) and never writes a frame older than the last.
- Monitor unplugged mid-recording: the capture switches to the remaining screen in the same file
  (`preservesAspectRatio`: fitted, never cropped — the OBS failure mode was a fixed 4K canvas and a
  source bound to a missing display). If capture stopped anyway, the part is saved and transcribed
  and a new recording continues on the available screen as the same kind (auto meeting / rule), at
  most once per 2 minutes.

Planned next: Zoom and other apps once checked for false positives. Later: an own viewer window in
MeetRec (video, the list of markers and the transcript side by side; clicking a line or a marker jumps
there) instead of handing markers to QuickTime.

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
  recognition. The helper finds them by the default flag ([mix, mic, system] or
  older [system, mic]; the player mix is not used). Whoever speaks into the microphone is the user
  (`--me`, "Моё имя"): a phrase heard mostly through the microphone track is theirs, and a diarized
  speaker with ≥60% of speech there gets the name, whatever the voice match says; voice samples name
  only the other side. The run file records each speaker's microphone share. Transcript: `<recording>.md` next to the video, never overwritten. Models: the shared
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

## Tests

```bash
xcodebuild test -project MeetRec.xcodeproj -scheme MeetRec -destination 'platform=macOS' -derivedDataPath build/dd-test
rm -rf build/dd-test/Build/Products/Debug/MeetRec.app   # else it shows up as a second MeetRec in Launchpad
python3 -m unittest discover -s Tests   # transcribe.py helpers, no models needed
```

`Tests/MeetRecTests` covers file names and companions, tags, transcript speaker renaming, meeting
apps and rules, and the health tracker. The app is the test host but starts empty under XCTest
(`AppDelegate.isRunningTests`: no watchdog, hot keys or detector) and logs to a temporary folder.

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
