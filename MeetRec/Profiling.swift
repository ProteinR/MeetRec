import AppKit

/// Profiling runs started from the command line (as in Genius Switcher and MXCtl). Install with
/// `PROFILE=1 scripts/install.sh` so `leaks`/`heap`/`xctrace` can attach, then e.g.
/// `open -a ~/Applications/MeetRec.app --args --stress-test`. Footprint lines go to the log
/// (category `profile`); `scripts/profile.py` measures CPU and wake-ups from outside meanwhile.
///
/// - `--profile-recording <seconds>`: a manual recording of that length (footprint every minute),
///   then the file is moved to the Trash; no transcription.
/// - `--camera-test`: "Как я выгляжу" opened and closed three times.
/// - `--stress-test`: three rounds of the panel (10 times, settings every other time), the
///   screenshot selection (3 times, cancelled), freezing the screens (5 times) and the screenshot
///   editor (5 times). Growing every
///   round = a leak; growing once and then flat = caches.
@MainActor
enum Profiling {
    /// A profiling run is going: its recordings are not transcribed.
    static private(set) var isActive = false

    static func start(delegate: AppDelegate) {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--profile-recording") {
            let seconds = arguments.dropFirst(index + 1).first.flatMap(Double.init) ?? 300
            isActive = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { MainActor.assumeIsolated { record(seconds) } }
        }
        if arguments.contains("--camera-test") {
            isActive = true
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(5))
                await cameraTest()
            }
        }
        if arguments.contains("--stress-test") {
            isActive = true
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(5))
                await stress(delegate)
            }
        }
    }

    // MARK: - Recording

    private static func record(_ seconds: Double) {
        let model = RecorderModel.shared
        log("Profile recording (\(Int(seconds)) s) start")
        model.start()
        Task { @MainActor in
            let began = Date()
            while Date().timeIntervalSince(began) < seconds {
                try? await Task.sleep(for: .seconds(60))
                log("Profile recording at \(Int(Date().timeIntervalSince(began))) s")
            }
            model.stop(reason: "профилирование")
            while model.isRecording || model.isBusy { try? await Task.sleep(for: .milliseconds(200)) }
            log("Profile recording stopped")
            if let file = model.lastFile {
                for companion in RecordingFiles.companions(of: file) + [file] {
                    try? FileManager.default.trashItem(at: companion, resultingItemURL: nil)
                }
                Log.info("Profile recording moved to the Trash: \(file.lastPathComponent)", "profile")
            }
            try? await Task.sleep(for: .seconds(30))
            log("Profile recording, 30 s later")
        }
    }

    // MARK: - Stress

    private static func stress(_ delegate: AppDelegate) async {
        log("Stress test start")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MeetRec Stress", isDirectory: true)
        for round in 1...3 {
            for index in 0..<10 {
                delegate.showPanel()
                if index % 2 == 1 { RecorderModel.shared.requestSettings() }
                try? await Task.sleep(for: .seconds(1.2))
                delegate.panel.close()
                try? await Task.sleep(for: .seconds(0.5))
            }
            for _ in 0..<3 {
                Screenshotter.shared.captureArea()
                try? await Task.sleep(for: .seconds(1.5))
                Screenshotter.shared.cancelSelection()
                try? await Task.sleep(for: .seconds(1))
            }
            var shot: URL?
            for _ in 0..<5 {
                if let screen = try? await FrozenScreen.captureAll().first, shot == nil {
                    shot = try? ScreenshotFiles.save(screen.image, scale: screen.scale, in: folder)
                }
                try? await Task.sleep(for: .seconds(0.5))
            }
            if let shot {
                for _ in 0..<5 {
                    ScreenshotEditor.open(shot)
                    try? await Task.sleep(for: .seconds(1.5))
                    NSApp.windows.first { $0.representedURL == shot && $0.isVisible }?.performClose(nil)
                    try? await Task.sleep(for: .seconds(1))
                }
            }
            ScreenshotFiles.releaseFreedMemory()
            try? await Task.sleep(for: .seconds(5))
            log("Stress round \(round)")
        }
        try? FileManager.default.removeItem(at: folder)
        log("Stress test done")
    }

    // MARK: - Camera

    /// "Как я выгляжу" opened for 5 s and closed, three times (the camera light comes on).
    private static func cameraTest() async {
        log("Camera test start")
        for round in 1...3 {
            CameraMirror.shared.show()
            try? await Task.sleep(for: .seconds(5))
            log("Camera open \(round)")
            CameraMirror.shared.close()
            try? await Task.sleep(for: .seconds(5))
            ScreenshotFiles.releaseFreedMemory()
            log("Camera closed \(round)")
        }
    }

    // MARK: - Footprint

    private static func log(_ what: String) {
        Log.info("\(what): footprint \(footprintMB()) MB", "profile")
    }

    /// The memory footprint, as Activity Monitor shows it.
    static func footprintMB() -> String {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? String(format: "%.1f", Double(info.phys_footprint) / 1_048_576) : "?"
    }
}
