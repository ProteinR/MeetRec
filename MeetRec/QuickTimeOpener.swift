import AppKit

/// Opens a recording in QuickTime Player at a given moment (a marker). Uses AppleScript, so macOS
/// asks once for permission to control QuickTime Player; without it the video just opens.
enum QuickTimeOpener {
    static func open(_ video: URL, at seconds: Double) {
        let path = video.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
        tell application "QuickTime Player"
            activate
            set theDocument to open POSIX file "\(path)"
            set current time of theDocument to \(String(format: "%.2f", seconds))
        end tell
        """
        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&error)
            if let error {
                Log.warning("QuickTime could not jump to \(Int(seconds)) s in \(video.lastPathComponent): \(error)", "files")
                DispatchQueue.main.async { NSWorkspace.shared.open(video) }
            } else {
                Log.info("Opened \(video.lastPathComponent) in QuickTime at \(Int(seconds)) s", "files")
            }
        }
    }
}
