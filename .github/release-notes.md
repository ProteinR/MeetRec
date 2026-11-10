**Install:** download `MeetRec-*.dmg`, open it and drag MeetRec to Applications. MeetRec is not
notarized (no Apple Developer account), so macOS blocks the first launch: open it once, then
System Settings → Privacy & Security → "Open Anyway". Or in Terminal:

```bash
xattr -dr com.apple.quarantine /Applications/MeetRec.app
```

macOS 15+, Apple Silicon. Transcription also needs `uv` and a Hugging Face token (README →
"Transcription setup"). Updates are signed with the same certificate, so Screen Recording and
Microphone permissions are kept.

**Установка:** скачайте `MeetRec-*.dmg`, откройте и перетащите MeetRec в «Программы». Приложение
не нотаризовано, поэтому при первом запуске macOS его заблокирует: откройте его один раз, затем
«Системные настройки → Конфиденциальность и безопасность → Всё равно открыть» (или команда выше).
