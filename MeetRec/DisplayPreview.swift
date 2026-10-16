import AppKit
import ScreenCaptureKit
import SwiftUI

/// A small, regularly refreshed picture of the display that would be recorded, so it is obvious
/// before starting which monitor "Авто" resolves to. Runs only while the panel is open and nothing is
/// being recorded; never asks for permission (without Screen Recording access it just shows nothing).
@MainActor
final class DisplayPreview: ObservableObject {
    @Published private(set) var image: CGImage?
    @Published private(set) var displayID: CGDirectDisplayID?

    private var task: Task<Void, Never>?

    func start(displayID: CGDirectDisplayID) {
        if task != nil, self.displayID == displayID { return }
        stop()
        if self.displayID != displayID { image = nil }
        self.displayID = displayID
        guard CGPreflightScreenCaptureAccess() else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                let image = await Self.capture(displayID: displayID)
                guard !Task.isCancelled, let self else { return }
                if let image { self.image = image }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private static func capture(displayID: CGDirectDisplayID) async -> CGImage? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else { return nil }
            // Without MeetRec's own windows, like the recording itself (the panel is on top otherwise).
            let ownApp = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
            let filter = SCContentFilter(display: display, excludingApplications: ownApp, exceptingWindows: [])
            let config = SCStreamConfiguration()
            let width = 320
            config.width = width
            config.height = max(1, Int(Double(width) * Double(display.height) / Double(max(display.width, 1))))
            config.showsCursor = false
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            Log.debug("Display preview failed: \(Log.describe(error))")
            return nil
        }
    }
}

/// Thumbnail of the display to be recorded with its name.
struct DisplayPreviewRow: View {
    let display: DisplayInfo
    let isAuto: Bool
    @ObservedObject var preview: DisplayPreview

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.08))
                if let image = preview.image, preview.displayID == display.id {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                        .transition(.opacity)
                } else {
                    Image(systemName: "display").foregroundStyle(.tertiary)
                }
            }
            .frame(width: 112, height: 63)
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(0.15)))
            .animation(.easeOut(duration: 0.2), value: preview.image != nil)
            VStack(alignment: .leading, spacing: 2) {
                Text("Будет записан").font(.caption).foregroundStyle(.secondary)
                Text(display.name).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
    }

    private var detail: String {
        let kind = display.isBuiltIn ? "встроенный экран" : "внешний монитор"
        if !CGPreflightScreenCaptureAccess() { return "\(kind) · нет доступа к записи экрана" }
        return isAuto ? "\(kind) · «Авто» выбирает внешний, если подключён" : kind
    }
}
