# MeetRec settings reference

Every setting MeetRec has is a key in its user defaults (domain `com.dmemruk.MeetRec`), so a
script or an AI agent can set MeetRec up without clicking through the panel. Everything here can
also be changed in the app (gear → three tabs); this file is for doing it from the terminal.

## How to change a setting

Quit MeetRec first (it may write its in-memory values back), change the keys, start it again.
Never quit it while it is recording: check the log's last `Recording state` line
(`~/Library/Logs/MeetRec/meetrec.log`) or the menu bar icon.

```bash
osascript -e 'tell application id "com.dmemruk.MeetRec" to quit'
defaults write com.dmemruk.MeetRec fps -int 10
defaults write com.dmemruk.MeetRec codec hevc
open ~/Applications/MeetRec.app
```

Read everything at once: `defaults read com.dmemruk.MeetRec`. Remove a key to go back to the
default: `defaults delete com.dmemruk.MeetRec <key>`. Types matter: use `-int`, `-float`, `-bool`
as in the tables; JSON values need `-string` (else `defaults` reads `[...]` as its own array
syntax and fails), plain strings need no flag.

## Recording

| Key | Type | Default | Meaning |
|---|---|---|---|
| `folder` | string | `~/Movies/MeetRec` | Where recordings go (absolute path); each recording gets its own folder there. |
| `displayID` | int | `0` | Display to record: `0` = auto (prefers an external monitor), else a `CGDirectDisplayID`. |
| `fps` | int | `15` | Frame rate: 5, 10, 15, 30 or 60. Idle frames are skipped anyway. |
| `resolution` | string | `p1080` | `native`, `p1440`, `p1080`, `p720` (maximum height). |
| `codec` | string | `h264` | `h264` or `hevc` (smaller files). |
| `systemAudio` | bool | `true` | Record the other side (system audio). |
| `microphone` | bool | `true` | Record the microphone. |
| `microphoneID` | string | empty | CoreAudio device UID of a fixed microphone; empty = follow the system default and the call app. |
| `crashWatchdog` | bool | `true` | Relaunch MeetRec if it crashes (launchd agent). |

## Language

| Key | Type | Default | Meaning |
|---|---|---|---|
| `AppleLanguages` | array | not set | MeetRec's own language: `(en)` or `(ru)`; not set = as the system. Applied at launch. |

```bash
defaults write com.dmemruk.MeetRec AppleLanguages -array en
defaults delete com.dmemruk.MeetRec AppleLanguages   # back to the system's language
```

## Meetings and calls

| Key | Type | Default | Meaning |
|---|---|---|---|
| `meetingDetection` | bool | `false` | Watch which apps use the microphone and start/stop by itself. |
| `meetingApps` | string | `teams` | Comma-separated apps to watch: `teams`, `telegram`, `browser` (supported); `zoom`, `slack`, `webex`, `facetime`, `discord` are listed but not supported yet. |
| `meetingAppModes` | string | empty | Per app `id:auto` (record with a countdown) or `id:ask` (ask "Записать?"), comma-separated, e.g. `teams:auto,browser:ask`. Without an entry Teams records, browser and Telegram ask. |
| `browserAutoRules` | JSON string | empty | Browser tabs to record without asking, see below. |

`browserAutoRules` is a JSON array:

```json
[{"id": "6F1C2B9E-3D4A-4E5F-8A7B-1C2D3E4F5A6B", "keyword": "Vimbox, Skysmart", "title": "Skyeng", "oneOther": true}]
```

- `id`: any UUID (keep it stable: copy rules and file tags refer to it).
- `keyword`: text looked for in the active tab's window title, case-insensitive; several variants
  separated by commas.
- `title`: put into the file name after the timestamp (`2026-10-17 14-03-22 Skyeng.mov`); empty
  keeps just the date.
- `oneOther` (optional): a one-on-one call; everyone except you is one speaker in the transcript.

```bash
defaults write com.dmemruk.MeetRec browserAutoRules -string '[{"id":"6F1C2B9E-3D4A-4E5F-8A7B-1C2D3E4F5A6B","keyword":"meet.google.com","title":"Google Meet"}]'
```

## Transcription

Needs `uv` and a Hugging Face token with the pyannote conditions accepted (see README).

| Key | Type | Default | Meaning |
|---|---|---|---|
| `transcribeAfterRecording` | bool | `false` | Transcribe every recording when it stops. |
| `diarization` | bool | `true` | Tell speakers apart (pyannote). |
| `transcriptionLanguage` | string | empty | Empty = detect; or `en`, `ru`, `de`. |
| `myName` | string | your first name | Your name in transcripts: whoever speaks into the microphone. |
| `transcriptCopyRules` | JSON string | empty | Also copy transcripts of meeting recordings to folders, see below. |

`transcriptCopyRules` is a JSON array; `app` is a meeting app id (`teams`, `telegram`, `browser`)
or `rule:<browser rule id>`:

```json
[{"id": "0B7E4A61-5C2D-4F3E-9A8B-7C6D5E4F3A2B", "app": "teams", "folder": "/Users/me/notes/meetings"}]
```

Only recordings of 2+ minutes are copied, an existing file is never overwritten, manual recordings
are never copied. Known voices live in `~/Library/Application Support/MeetRec/speakers.json`
(name → list of voice embeddings); add names through the app ("Подписать спикеров…").

## Look while recording

| Key | Type | Default | Meaning |
|---|---|---|---|
| `menuBarStyle` | string | `full` | `full` (red icon + timer), `icon` (red icon only), `discreet` (monochrome, no timer, no auto-opening panel, no island). |
| `hideFromScreenSharing` | bool | `true` | Hide MeetRec's windows from screen sharing. |
| `notchIsland` | bool | `true` | Recording island at the notch / under the menu bar. |

## Screenshots

| Key | Type | Default | Meaning |
|---|---|---|---|
| `screenshotFolder` | string | empty | Empty = `~/Pictures/screenshots`. |
| `screenshotFormat` | string | `auto` | `auto` (JPEG when much smaller, e.g. photos) or `png`. |
| `screenshotCopy` | bool | `true` | Copy to the clipboard. |
| `screenshotSave` | bool | `true` | Save to the folder. |
| `screenshotToast` | bool | `true` | Show the preview toast. |
| `screenshotSound` | bool | `true` | Shutter sound. |
| `screenshotWindowMargin` | float | `12` | Wallpaper around a window shot, points. |
| `imageSearchProviders` | string | `google` | Comma-separated image search buttons: `google`, `yandex`, `tineye`, `bing`, `pimeyes`, `facecheck`, `search4faces`. |

## Shortcuts

Actions: `record` (⌃⌥⌘R), `marker` (⌃⌥⌘M), `pause` (none), `screenshot` (⇧⌘4), `text` (OCR, ⇧⌘2).
Each has four keys:

| Key | Type | Meaning |
|---|---|---|
| `<action>HotKey` | bool | On/off. |
| `<action>KeyCode` | int | Carbon virtual key code (`kVK_ANSI_R` = 15); `-1` = no shortcut. |
| `<action>KeyModifiers` | int | Carbon mask, sum of: ⌘ 256, ⇧ 512, ⌥ 2048, ⌃ 4096. |
| `<action>KeyLabel` | string | The key as shown, e.g. `R`. |

Pause on ⌃⌥⌘P:

```bash
defaults write com.dmemruk.MeetRec pauseKeyCode -int 35
defaults write com.dmemruk.MeetRec pauseKeyModifiers -int 6400
defaults write com.dmemruk.MeetRec pauseKeyLabel P
defaults write com.dmemruk.MeetRec pauseHotKey -bool true
```

## Internal (do not edit)

`lastRecording`, `lastCrashRecovery`, `settingsTab` and launch-at-login (managed by macOS through
`SMAppService`) are state, not settings.
