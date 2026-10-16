import AppKit
import AVFoundation
import SwiftUI

/// "Как я выгляжу": a small floating window with the mirrored camera picture, to check yourself before
/// a meeting without opening Photo Booth. Nothing is recorded or saved; the camera runs only while the
/// window is open.
@MainActor
final class CameraMirror: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = CameraMirror()
    static let cameraKey = "mirrorCameraID"

    @Published private(set) var cameras: [AVCaptureDevice] = []
    @Published private(set) var currentID: String?
    @Published private(set) var denied = false
    @Published private(set) var noCamera = false

    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.dmemruk.MeetRec.mirror")
    private var window: NSWindow?

    var isShown: Bool { window?.isVisible == true }

    func toggle() {
        if isShown { close() } else { show() }
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let size = NSSize(width: 360, height: 270)
        let window = MirrorWindow(contentRect: NSRect(origin: .zero, size: size),
                                  styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
        // A titled window with its title bar hidden: macOS gives it the normal resize edges (a
        // borderless one only has a strip of a pixel or two, and moving by background fought with it).
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = true
        }
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.backgroundColor = .black
        window.isMovableByWindowBackground = true
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.contentAspectRatio = NSSize(width: 4, height: 3)
        window.minSize = NSSize(width: 200, height: 150)
        window.sharingType = MenuBarStyle.hideFromSharing ? .none : .readOnly
        window.delegate = self
        let hosting = NSHostingView(rootView: MirrorView(mirror: self))
        // By default the hosting view pins the window to SwiftUI's size, so dragging an edge did
        // nothing; the window owns its size here (min size and aspect ratio above).
        hosting.sizingOptions = []
        window.contentView = hosting
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            window.setFrameOrigin(NSPoint(x: visible.maxX - size.width - 20, y: visible.maxY - size.height - 20))
        }
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        Log.info("Camera mirror opened")
        startCamera()
    }

    func close() {
        window?.close()
    }

    func select(_ id: String) {
        UserDefaults.standard.set(id, forKey: Self.cameraKey)
        startCamera()
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        let session = session
        sessionQueue.async { session.stopRunning() }
        window = nil
        Log.info("Camera mirror closed")
    }

    // MARK: - Camera

    private func startCamera() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            denied = false
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                Task { @MainActor in
                    Log.info("Camera access \(granted ? "granted" : "denied")")
                    if granted { self.startCamera() } else { self.denied = true }
                }
            }
            return
        default:
            denied = true
            Log.warning("Camera mirror: no camera access")
            return
        }

        cameras = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera], mediaType: .video, position: .unspecified
        ).devices
        let saved = UserDefaults.standard.string(forKey: Self.cameraKey)
        guard let device = cameras.first(where: { $0.uniqueID == saved }) ?? AVCaptureDevice.default(for: .video) ?? cameras.first else {
            currentID = nil
            noCamera = true
            Log.warning("Camera mirror: no camera found")
            return
        }
        currentID = device.uniqueID
        noCamera = false
        Log.info("Camera mirror: \(device.localizedName) (\(device.uniqueID))")

        let session = session
        sessionQueue.async {
            session.beginConfiguration()
            session.sessionPreset = .high
            session.inputs.forEach { session.removeInput($0) }
            if let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
                session.addInput(input)
            } else {
                Log.error("Camera mirror: cannot use \(device.localizedName)")
            }
            session.commitConfiguration()
            if !session.isRunning { session.startRunning() }
        }
    }
}

/// Esc closes the mirror.
private final class MirrorWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) { close() }
}

private struct MirrorView: View {
    @ObservedObject var mirror: CameraMirror
    @State private var hovering = false

    var body: some View {
        ZStack {
            Color.black
            if mirror.denied {
                VStack(spacing: 8) {
                    Image(systemName: "video.slash").font(.title2)
                    Text("Нет доступа к камере").font(.callout)
                    Button("Открыть настройки") { mirror.openPrivacySettings() }
                }
                .foregroundStyle(.white)
            } else if mirror.noCamera {
                Text("Камера не найдена").foregroundStyle(.white.opacity(0.7))
            } else {
                // Mirrored, like a mirror and like the self view in calls.
                CameraPreview(session: mirror.session).scaleEffect(x: -1, y: 1)
            }
        }
        .overlay(alignment: .bottom) {
            HStack {
                if mirror.cameras.count > 1 {
                    Menu {
                        ForEach(mirror.cameras, id: \.uniqueID) { camera in
                            Button {
                                mirror.select(camera.uniqueID)
                            } label: {
                                if camera.uniqueID == mirror.currentID {
                                    Label(camera.localizedName, systemImage: "checkmark")
                                } else {
                                    Text(camera.localizedName)
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "camera.fill")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Камера")
                }
                Spacer()
                Button { mirror.close() } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                }
                .buttonStyle(.plain)
                .help("Закрыть (Esc)")
            }
            .foregroundStyle(.white)
            .padding(8)
            .shadow(color: .black.opacity(0.6), radius: 3)
            .opacity(hovering ? 1 : 0)
        }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        // The picture also fills the hidden title bar's area, otherwise a black strip stays on top.
        .ignoresSafeArea()
    }
}

/// The live camera picture.
private struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        view.layer = layer
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
