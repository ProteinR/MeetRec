import AppKit
import SwiftUI

/// The toast after a screenshot, like Shottr's thumbnail: the shot itself fills the card, and only
/// with the pointer on it the actions show over it (copy, edit, text, image search, Finder).
/// Several shots in a row stack in a column, newest on top (`RecorderModel.shotToasts`). The
/// ✕ and the line with the time left are the toast's own (`ToastView`). Dragging the picture drops
/// the file into a chat or an upload field; a click on it edits it.
struct ScreenshotToastCard: View {
    let toast: Toast
    let image: NSImage
    let file: URL
    let onDrag: (ToastView.DragState) -> Void
    @EnvironmentObject private var model: RecorderModel
    @State private var hovering = false
    /// Copied from here (or by itself after the shot): the button says so instead of offering it.
    @State private var copiedHere = false
    /// The image search service under the pointer, named next to the icons.
    @State private var searchHover: String?

    /// The same for every shot, so a column of them lines up; the shot is fitted inside it.
    static let pictureSize = CGSize(width: 280, height: 170)

    private var copied: Bool { toast.copied || copiedHere }

    var body: some View {
        let size = Self.pictureSize
        ZStack {
            Color.black.opacity(0.18)
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
        }
        .frame(width: size.width, height: size.height)
        .overlay(FileDragSource(file: file, image: image,
                                onClick: {
                                    model.dismissShot(toast.id)
                                    ScreenshotEditor.open(file)
                                },
                                onBegin: { onDrag(.began) },
                                onEnd: { onDrag(.ended(dropped: $0)) }))
        .overlay { if hovering { actions } }
        .overlay(alignment: .bottomLeading) { if !hovering { status.padding(6) } }
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }

    /// What happened to the shot, quietly, while the pointer is elsewhere.
    @ViewBuilder private var status: some View {
        let problem = toast.detail
        HStack(spacing: 4) {
            Image(systemName: problem == nil ? "checkmark" : "exclamationmark.triangle.fill")
                .font(.system(size: 9, weight: .bold))
            Text(problem ?? toast.title).font(.caption2.weight(.semibold)).lineLimit(1)
        }
        .foregroundStyle(problem == nil ? Color.primary : Color.orange)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(.regularMaterial))
        .allowsHitTesting(false)
    }

    private var actions: some View {
        ZStack {
            Color.black.opacity(0.35).allowsHitTesting(false)
            VStack(spacing: 5) {
                ScreenshotToastPill(icon: copied ? "checkmark" : "doc.on.doc",
                                    title: copied ? String(localized: "Скопировано") : String(localized: "Копировать")) {
                    Screenshotter.shared.copy(file)
                    copiedHere = true
                }
                // Spelled out: a bare pencil in a corner was neither noticed nor understood.
                ScreenshotToastPill(icon: "pencil.and.outline", title: String(localized: "Редактировать")) {
                    model.dismissShot(toast.id)
                    ScreenshotEditor.open(file)
                }
                ScreenshotToastPill(icon: "text.viewfinder", title: String(localized: "Текст")) {
                    model.dismissShot(toast.id)
                    Screenshotter.shared.recognizeText(file)
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            if toast.saved {
                ScreenshotToastCorner(icon: "folder", label: String(localized: "Показать в Finder")) {
                    model.dismissShot(toast.id)
                    NSWorkspace.shared.activateFileViewerSelecting([file])
                }
                .padding(6)
            }
        }
        .overlay(alignment: .bottomTrailing) { search.padding(6) }
    }

    /// The enabled image search services; the one under the pointer is named above them (the toast
    /// is never key, so `.help` does not show).
    private var search: some View {
        VStack(alignment: .trailing, spacing: 4) {
            if let searchHover {
                Text(searchHover)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(.regularMaterial))
            }
            HStack(spacing: 6) {
                ImageSearchButtons(iconSize: 15, onHover: { searchHover = $0?.name }) { ImageSearch.search(file, with: $0) }
                    .buttonStyle(.borderless)
            }
            .padding(.horizontal, 7)
            .frame(height: 26)
            .background(Capsule().fill(.regularMaterial))
        }
    }
}

/// A big action in the middle of the shot, like Shottr's "Copy" / "Save".
private struct ScreenshotToastPill: View {
    let icon: String
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold))
                Text(title).font(.callout.weight(.semibold))
            }
            .frame(minWidth: 132)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(Capsule().fill(.thickMaterial))
            .overlay(Capsule().strokeBorder(Color.white.opacity(hovering ? 0.5 : 0.2), lineWidth: 0.5))
            .scaleEffect(hovering ? 1.04 : 1)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .accessibilityLabel(title)
    }
}

/// A small round action in a corner of the shot.
private struct ScreenshotToastCorner: View {
    let icon: String
    let label: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 26, height: 26)
                .background(Circle().fill(.thickMaterial))
                .overlay(Circle().strokeBorder(Color.white.opacity(hovering ? 0.5 : 0.2), lineWidth: 0.5))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(label)
    }
}
