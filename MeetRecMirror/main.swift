import AppKit

// "Как я выгляжу" in its own process, started by MeetRec (see `Mirror`). No Dock icon; it ends
// when the window closes, when MeetRec ends it, or when MeetRec itself is gone.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let mirror = Mirror(hideFromSharing: CommandLine.arguments.contains("--hide-from-sharing"))
    let parent = DispatchSource.makeProcessSource(identifier: getppid(), eventMask: .exit, queue: .main)
    parent.setEventHandler { exit(0) }
    parent.resume()
    mirror.show()
    withExtendedLifetime((mirror, parent)) { app.run() }
}
