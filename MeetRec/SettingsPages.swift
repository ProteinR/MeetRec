import AppKit
import SwiftUI

/// The settings: a list of sections on the first page, each opening as its own page (like System
/// Settings), so nothing unfolds in place and the card's height changes only between pages.
enum SettingsPage: String, CaseIterable, Identifiable {
    case general, video, meetings, transcription, appearance, screenshots, shortcuts

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: String(localized: "Основные")
        case .video: String(localized: "Видео")
        case .meetings: String(localized: "Встречи и звонки")
        case .transcription: String(localized: "Транскрибация")
        case .appearance: String(localized: "Вид во время записи")
        case .screenshots: String(localized: "Скриншоты")
        case .shortcuts: String(localized: "Клавиши")
        }
    }

    var icon: String {
        switch self {
        case .general: "gearshape.fill"
        case .video: "video.fill"
        case .meetings: "person.2.wave.2.fill"
        case .transcription: "text.bubble.fill"
        case .appearance: "menubar.rectangle"
        case .screenshots: "camera.viewfinder"
        case .shortcuts: "keyboard.fill"
        }
    }

    /// The icon's tile, as in System Settings: each section its own colour.
    var tint: Color {
        switch self {
        case .general: .gray
        case .video: .red
        case .meetings: .green
        case .transcription: .purple
        case .appearance: .blue
        case .screenshots: .teal
        case .shortcuts: .gray
        }
    }

    /// The list's groups: recording first, then screenshots and shortcuts.
    static let groups: [[SettingsPage]] = [[.general, .video, .meetings, .transcription, .appearance], [.screenshots, .shortcuts]]
}

/// A section's row in the settings list: coloured icon, title, a one-line summary, chevron.
struct SettingsRow: View {
    let page: SettingsPage
    let summary: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                SettingsIcon(page: page)
                VStack(alignment: .leading, spacing: 1) {
                    Text(page.title).font(.callout.weight(.medium))
                    if !summary.isEmpty {
                        Text(summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.primary.opacity(hovering ? 0.06 : 0))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

struct SettingsIcon: View {
    let page: SettingsPage

    var body: some View {
        Image(systemName: page.icon)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 24, height: 24)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(page.tint.gradient))
    }
}

/// Rows in one rounded card with hairlines between them.
struct SettingsGroup<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            content()
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
    }
}

/// Makes the enclosing `NSScrollView` draw its scroller over the content: with a mouse attached
/// macOS uses legacy scrollers, which take ~15 pt from the width, so the page jumped narrower and
/// back whenever it started or stopped needing to scroll.
struct OverlayScrollers: NSViewRepresentable {
    func makeNSView(context: Context) -> ProbeView { ProbeView() }
    func updateNSView(_ view: ProbeView, context: Context) { view.apply() }

    final class ProbeView: NSView {
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
            guard observer == nil else { return }
            // The system sets the style again when a mouse is plugged in or the preference changes.
            observer = NotificationCenter.default.addObserver(forName: NSScroller.preferredScrollerStyleDidChangeNotification,
                                                              object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.apply() }
            }
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }

        func apply() {
            DispatchQueue.main.async { [weak self] in
                guard let scrollView = self?.enclosingScrollView, scrollView.scrollerStyle != .overlay else { return }
                scrollView.scrollerStyle = .overlay
                scrollView.autohidesScrollers = true
            }
        }
    }
}
