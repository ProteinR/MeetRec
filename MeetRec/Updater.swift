import AppKit
import Security
import SwiftUI

/// Updates from GitHub Releases with one button (as in the owner's subtitle translator).
///
/// - Checks `releases/latest` of the repository a minute after launch and every 6 hours (setting
///   `checkForUpdates`), or on "Проверить" in settings. Nothing but that request leaves the Mac.
/// - "Обновить" downloads the release's `.zip`, unpacks it next to the app (same volume), and
///   installs it only if it is MeetRec, of the announced version, newer, and **signed with the same
///   certificate as the running copy** (its designated requirement): a replaced download, or a
///   release signed differently, is refused, and macOS keeps the Screen Recording / Microphone
///   permissions because the signature stays the same.
/// - The old app is swapped for the new one in place, MeetRec quits as usual (the watchdog flag is
///   removed, so the crash watchdog does not reopen anything) and a small shell waits for this
///   process to end and opens the new copy.
/// - Never while recording, saving a recording or transcribing: the button waits.
/// - Only a copy signed with the release certificate installs updates; one built from source
///   (`install.sh`, another certificate) is told to update the way it was built.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    static let repository = "ProteinR/MeetRec"
    /// The certificate `.github/workflows/release.yml` signs releases with.
    static let releaseCertificate = "MeetRec Release Signing"
    static let checkInterval: TimeInterval = 6 * 3600

    struct Release: Equatable {
        var version: String
        var page: URL
        var archive: URL
    }

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(Release)
        case downloading(Release)
        case installing(Release)
        case failed(String)
    }

    /// Why this copy cannot replace itself; nil when it can.
    enum Blocker: Equatable {
        /// Signed with another certificate (built from source) or not signed with a certificate.
        case notReleaseBuild
        /// Run from the disk image, a translocated copy or a folder MeetRec cannot write to.
        case location

        var message: String {
            switch self {
            case .notReleaseBuild:
                String(localized: "Эта копия собрана не из релиза — обновите её так же, как собирали (scripts/install.sh).")
            case .location:
                String(localized: "Переместите MeetRec в «Программы» и откройте оттуда — тогда он сможет обновляться.")
            }
        }
    }

    @AppStorage("checkForUpdates") var automatic = true {
        didSet { scheduleChecks() }
    }
    /// A version the user closed the panel banner for; a newer one shows it again.
    @AppStorage("dismissedUpdateVersion") var dismissedVersion = ""

    @Published private(set) var state: State = .idle
    /// The newest release seen, kept while downloading or after a failed install.
    @Published private(set) var latest: Release?
    @Published private(set) var lastCheck: Date?
    let blocker: Blocker?
    let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"

    private var timer: Timer?

    private init() {
        blocker = Self.findBlocker()
    }

    /// Call once at launch.
    func start() {
        Log.info("Updates: version \(currentVersion), automatic check \(automatic ? "on" : "off"), "
            + (blocker.map { "can't self-update (\($0))" } ?? "can self-update"), "update")
        scheduleChecks()
    }

    private func scheduleChecks() {
        timer?.invalidate()
        timer = nil
        guard automatic else { return }
        // Not right at launch: after boot or wake the network may not be up yet.
        let first = lastCheck.map { max(60, Self.checkInterval - Date().timeIntervalSince($0)) } ?? 60
        timer = Timer.scheduledTimer(withTimeInterval: first, repeats: false) { [weak self] _ in
            Task { @MainActor in
                await self?.check()
                self?.scheduleChecks()
            }
        }
    }

    /// A release newer than this copy, unless the user closed its banner.
    var bannerRelease: Release? {
        switch state {
        case .available(let release): release.version == dismissedVersion ? nil : release
        case .downloading(let release), .installing(let release): release
        case .failed: latest.flatMap { Self.isNewer($0.version, than: currentVersion) ? $0 : nil }
        default: nil
        }
    }

    var isInstalling: Bool {
        switch state {
        case .downloading, .installing: true
        default: false
        }
    }

    func check(userInitiated: Bool = false) async {
        guard !isInstalling, state != .checking else { return }
        let previous = state
        state = .checking
        do {
            let release = try await Self.fetchLatest()
            lastCheck = Date()
            latest = release
            if Self.isNewer(release.version, than: currentVersion) {
                if case .available(let shown) = previous, shown == release {} else {
                    Log.info("Updates: \(release.version) is available (this is \(currentVersion))", "update")
                }
                state = .available(release)
                if userInitiated { dismissedVersion = "" }
            } else {
                state = .upToDate
                Log.info("Updates: \(currentVersion) is the latest (GitHub has \(release.version))", "update")
            }
        } catch {
            Log.warning("Updates: check failed: \(Log.describe(error))", "update")
            // A failed background check is not worth a red line in settings.
            state = userInitiated ? .failed(Self.message(error)) : (latest.map { Self.isNewer($0.version, than: currentVersion) ? .available($0) : .upToDate } ?? .idle)
        }
    }

    /// Recording, saving or transcribing: an update would cut it.
    static func busyReason(model: RecorderModel, transcriber: Transcriber) -> String? {
        if model.isRecording || model.isBusy { return String(localized: "Обновлю после записи") }
        if case .running = transcriber.job { return String(localized: "Обновлю после транскрибации") }
        if !transcriber.queue.isEmpty { return String(localized: "Обновлю после транскрибации") }
        return nil
    }

    func install() {
        guard let release = latest, blocker == nil, !isInstalling,
              Self.busyReason(model: RecorderModel.shared, transcriber: Transcriber.shared) == nil else { return }
        state = .downloading(release)
        Task {
            do {
                let (app, work) = try await Self.download(release)
                defer { try? FileManager.default.removeItem(at: work) }
                state = .installing(release)
                try Self.replaceRunningApp(with: app, backupIn: work)
                Log.info("Updates: installed \(release.version) over \(currentVersion), relaunching", "update")
                Self.relaunch()
            } catch {
                Log.error("Updates: installing \(release.version) failed: \(Log.describe(error))", "update")
                state = .failed(Self.message(error))
            }
        }
    }

    // MARK: - GitHub

    struct UpdateError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static func message(_ error: Error) -> String {
        (error as? UpdateError)?.message ?? error.localizedDescription
    }

    private static func fetchLatest() async throws -> Release {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("MeetRec", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { throw UpdateError(message: String(localized: "На GitHub ещё нет релизов")) }
        guard status == 200 else { throw UpdateError(message: String(localized: "GitHub ответил \(status)")) }
        guard let release = parseRelease(data) else {
            throw UpdateError(message: String(localized: "В последнем релизе нет архива MeetRec"))
        }
        return release
    }

    /// The `releases/latest` answer: tag `vX.Y.Z` and the `MeetRec-X.Y.Z.zip` asset.
    nonisolated static func parseRelease(_ data: Data) -> Release? {
        struct Answer: Decodable {
            struct Asset: Decodable {
                let name: String
                let browser_download_url: URL
            }
            let tag_name: String
            let html_url: URL
            let draft: Bool?
            let prerelease: Bool?
            let assets: [Asset]
        }
        guard let answer = try? JSONDecoder().decode(Answer.self, from: data),
              answer.draft != true, answer.prerelease != true else { return nil }
        let version = answer.tag_name.hasPrefix("v") ? String(answer.tag_name.dropFirst()) : answer.tag_name
        guard let zip = answer.assets.first(where: { $0.name == "MeetRec-\(version).zip" })
                ?? answer.assets.first(where: { $0.name.lowercased().hasSuffix(".zip") }) else { return nil }
        return Release(version: version, page: answer.html_url, archive: zip.browser_download_url)
    }

    /// Compares "0.10.1" with "0.11.0" part by part; missing parts are 0.
    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        let parts = { (version: String) in
            version.trimmingCharacters(in: CharacterSet(charactersIn: "v")).split(separator: ".").map { Int($0) ?? 0 }
        }
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: - Installing

    /// Downloads and unpacks the release next to the running app, then checks it. Returns the new
    /// app and the temporary folder it is in.
    private static func download(_ release: Release) async throws -> (app: URL, work: URL) {
        let installed = Bundle.main.bundleURL
        // Same volume as the app, so the swap is a rename; removed after the install or a failure.
        let work = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                               appropriateFor: installed, create: true)
        Log.info("Updates: downloading \(release.archive.absoluteString)", "update")
        var request = URLRequest(url: release.archive)
        request.setValue("MeetRec", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 120
        do {
            return (try await unpack(request, release: release, into: work), work)
        } catch {
            try? FileManager.default.removeItem(at: work)
            throw error
        }
    }

    private static func unpack(_ request: URLRequest, release: Release, into work: URL) async throws -> URL {
        let installed = Bundle.main.bundleURL
        let (file, response) = try await URLSession.shared.download(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw UpdateError(message: String(localized: "Не удалось скачать обновление: GitHub ответил \(status)"))
        }
        let zip = work.appendingPathComponent("MeetRec.zip")
        try FileManager.default.moveItem(at: file, to: zip)
        let unpacked = work.appendingPathComponent("unpacked")
        let unzip = try await run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path])
        guard unzip.status == 0 else {
            throw UpdateError(message: String(localized: "Архив обновления не распаковался: \(unzip.output)"))
        }
        let app = unpacked.appendingPathComponent(installed.lastPathComponent)
        let fallback = unpacked.appendingPathComponent("MeetRec.app")
        let candidate = FileManager.default.fileExists(atPath: app.path) ? app : fallback
        try verify(candidate, release: release)
        // Downloaded by MeetRec itself, so normally not quarantined; never let a stray flag stop the relaunch.
        _ = try? await run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", candidate.path])
        return candidate
    }

    /// The new app must be MeetRec, of the release's version, newer, and signed like this copy.
    private static func verify(_ app: URL, release: Release) throws {
        guard let bundle = Bundle(url: app), let info = bundle.infoDictionary else {
            throw UpdateError(message: String(localized: "В архиве обновления нет MeetRec.app"))
        }
        guard info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier else {
            throw UpdateError(message: String(localized: "В архиве обновления другое приложение"))
        }
        let version = info["CFBundleShortVersionString"] as? String ?? ""
        guard version == release.version else {
            throw UpdateError(message: String(localized: "В архиве версия \(version), а не \(release.version)"))
        }
        let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        guard isNewer(version, than: current) else {
            throw UpdateError(message: String(localized: "Версия \(version) не новее установленной"))
        }
        var own: SecCode?
        var ownStatic: SecStaticCode?
        var requirement: SecRequirement?
        var newCode: SecStaticCode?
        guard SecCodeCopySelf([], &own) == errSecSuccess, let own,
              SecCodeCopyStaticCode(own, [], &ownStatic) == errSecSuccess, let ownStatic,
              SecCodeCopyDesignatedRequirement(ownStatic, [], &requirement) == errSecSuccess, let requirement,
              SecStaticCodeCreateWithPath(app as CFURL, [], &newCode) == errSecSuccess, let newCode else {
            throw UpdateError(message: String(localized: "Не удалось проверить подпись обновления"))
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        let result = SecStaticCodeCheckValidity(newCode, flags, requirement)
        guard result == errSecSuccess else {
            Log.error("Updates: signature check of \(app.path) failed (\(result))", "update")
            throw UpdateError(message: String(localized: "Обновление подписано не тем сертификатом — не устанавливаю"))
        }
        Log.info("Updates: \(version) verified (bundle id, version, signature)", "update")
    }

    /// Swaps the app on disk; the running process keeps working from the files it has open.
    private static func replaceRunningApp(with app: URL, backupIn work: URL) throws {
        let installed = Bundle.main.bundleURL
        let backup = work.appendingPathComponent("previous.app")
        try FileManager.default.moveItem(at: installed, to: backup)
        do {
            try FileManager.default.moveItem(at: app, to: installed)
        } catch {
            try? FileManager.default.moveItem(at: backup, to: installed)
            throw UpdateError(message: String(localized: "Не удалось заменить приложение: \(error.localizedDescription)"))
        }
        // So Finder and `open` see the new version at once.
        let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: lsregister)
        process.arguments = ["-f", installed.path]
        try? process.run()
    }

    /// Quits as usual and opens the (new) app at the same path once this process is gone.
    private static func relaunch() {
        let script = "while /bin/kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$0\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, Bundle.main.bundlePath]
        do {
            try process.run()
        } catch {
            Log.error("Updates: could not schedule the relaunch: \(Log.describe(error))", "update")
        }
        NSApp.terminate(nil)
    }

    private static func run(_ tool: String, _ arguments: [String]) async throws -> (status: Int32, output: String) {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            process.standardOutput = pipe
            process.standardError = pipe
            process.terminationHandler = { process in
                let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                continuation.resume(returning: (process.terminationStatus, output.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }

    // MARK: - Can this copy update itself?

    private static func findBlocker() -> Blocker? {
        guard signingCertificate() == releaseCertificate else { return .notReleaseBuild }
        return locationBlocks(Bundle.main.bundleURL) ? .location : nil
    }

    /// A translocated copy, the disk image, or a folder MeetRec cannot write to.
    nonisolated static func locationBlocks(_ app: URL, writable: (String) -> Bool = FileManager.default.isWritableFile) -> Bool {
        let path = app.path
        if path.contains("/AppTranslocation/") || path.hasPrefix("/Volumes/") { return true }
        return !writable(app.deletingLastPathComponent().path) || !writable(path)
    }

    /// Common name of the certificate this copy is signed with; nil when ad-hoc.
    private static func signingCertificate() -> String? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let certificates = (info as NSDictionary?)?[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = certificates.first else { return nil }
        return SecCertificateCopySubjectSummary(leaf) as String?
    }
}
