import Foundation

/// Moves recordings of the older flat layout (`<stem>.mov` with `<stem>.md`, `<stem>.markers.json`,
/// `<stem>.mutes.json` next to it, the run in Application Support) into their own folders
/// (`<stem>/<stem>.mov`, see RecordingFiles). Runs at launch; each move is a rename on the same
/// volume, so it is instant and copies nothing. Only names that start with a timestamp are moved;
/// anything that would collide is left where it is. Every move is logged ("from → to"), so it can be
/// undone by hand.
enum RecordingsMigration {
    struct Move: Equatable {
        let from: URL
        let to: URL
    }

    /// Moves every flat recording in `library`; returns the moved videos.
    @discardableResult
    static func run(in library: URL, runsDir: URL = SpeakerNaming.runsDir) -> [Move] {
        let manager = FileManager.default
        let names = (try? manager.contentsOfDirectory(atPath: library.path)) ?? []
        var moves: [Move] = []
        var skipped = 0
        for name in names.sorted() where !name.hasPrefix(".") {
            let video = library.appendingPathComponent(name)
            guard ["mov", "mp4"].contains(video.pathExtension.lowercased()) else { continue }
            let stem = video.deletingPathExtension().lastPathComponent
            guard stem.range(of: "^" + RecordingFiles.timestampPattern, options: .regularExpression) != nil else {
                Log.debug("Migration: left \(name) flat (no timestamp first)", "files")
                skipped += 1
                continue
            }
            if let move = moveIntoFolder(video, stem: stem, runsDir: runsDir) {
                moves.append(move)
            } else {
                skipped += 1
            }
        }
        if !moves.isEmpty {
            Log.info("Migration: \(moves.count) recording(s) moved into their own folders, \(skipped) left as they were", "files")
        }
        return moves
    }

    /// `<stem>.mov` and its files into `<stem>/`: transcripts keep their names, markers and mutes
    /// become `markers.json` and `mutes.json`, the run file `run.json`. The video moves last, so an
    /// interrupted move is finished by the next run (the folder then has its files but no video).
    private static func moveIntoFolder(_ video: URL, stem: String, runsDir: URL) -> Move? {
        let manager = FileManager.default
        let folder = video.deletingLastPathComponent().appendingPathComponent(stem, isDirectory: true)
        var isDirectory: ObjCBool = false
        if manager.fileExists(atPath: folder.path, isDirectory: &isDirectory), !isDirectory.boolValue {
            Log.warning("Migration: left \(video.lastPathComponent) flat (a file named \(stem) is in the way)", "files")
            return nil
        }
        var plan: [(URL, URL)] = RecordingFiles.companions(of: video).map { file in
            let rest = String(file.lastPathComponent.dropFirst(stem.count))
            switch rest {
            case ".markers.json": return (file, folder.appendingPathComponent("markers.json"))
            case ".mutes.json": return (file, folder.appendingPathComponent("mutes.json"))
            default: return (file, folder.appendingPathComponent(file.lastPathComponent))
            }
        }
        let run = runsDir.appendingPathComponent(stem).appendingPathExtension("json")
        if manager.fileExists(atPath: run.path) { plan.append((run, folder.appendingPathComponent("run.json"))) }
        let target = folder.appendingPathComponent(video.lastPathComponent)
        plan.append((video, target))
        if let taken = plan.first(where: { manager.fileExists(atPath: $0.1.path) }) {
            Log.warning("Migration: left \(video.lastPathComponent) flat (\(taken.1.lastPathComponent) is already in its folder)", "files")
            return nil
        }
        do {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            for (from, to) in plan {
                try manager.moveItem(at: from, to: to)
                Log.info("Migration: \(from.path) → \(to.path)", "files")
            }
        } catch {
            Log.error("Migration of \(video.lastPathComponent) stopped: \(Log.describe(error))")
            return nil
        }
        return Move(from: video, to: target)
    }
}
