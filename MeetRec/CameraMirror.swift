import Foundation

/// "Как я выгляжу": the mirror window runs in its own small process (`MeetRecMirror` next to
/// MeetRec's executable), so the camera's memory (200–350 MB while open, ~70 MB of fragmented pages
/// left behind afterwards) goes back to macOS the moment the window closes. Its messages go to the log.
@MainActor
final class CameraMirror {
    static let shared = CameraMirror()

    private var process: Process?

    var isShown: Bool { process?.isRunning == true }

    func toggle() {
        if isShown { close() } else { show() }
    }

    func show() {
        guard !isShown else { return }
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/MeetRecMirror")
        let process = Process()
        process.executableURL = helper
        process.arguments = MenuBarStyle.hideFromSharing ? ["--hide-from-sharing"] : []
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                Log.info("Camera mirror: \(line)")
            }
        }
        process.terminationHandler = { [weak self] ended in
            Task { @MainActor in
                if self?.process === ended { self?.process = nil }
                Log.info("Camera mirror closed")
            }
        }
        do {
            try process.run()
            self.process = process
            Log.info("Camera mirror opened (pid \(process.processIdentifier))")
        } catch {
            Log.error("Camera mirror did not start: \(Log.describe(error))")
        }
    }

    func close() {
        process?.terminate()
    }
}
