import AppKit
import SwiftUI

/// A horizontal row of tiles of one width for the panel ("Записи", "Скриншоты"). Only the tiles in
/// view and one on each side exist, so thousands of files cost no more than a screenful. When the
/// last tile comes into view, `onReachEnd` asks for the next page.
///
/// Plain SwiftUI views moved by an offset, not a `ScrollView`: that is an AppKit scroll view, which
/// did not follow the page's slide and fade when coming back from the settings (the rows stood in
/// place while the rest slid in). Scrolling: a horizontal swipe or tilt wheel, and a vertical wheel
/// or swipe too (the main page itself does not scroll).
struct HorizontalStrip<Item: Identifiable, Tile: View>: View {
    let items: [Item]
    let tileWidth: CGFloat
    var spacing: CGFloat = 8
    var onReachEnd: () -> Void = {}
    @ViewBuilder var tile: (Item) -> Tile

    @State private var offset: CGFloat = 0
    /// Known from the first frame: a row made anew (back from the settings) that started at 0 drew
    /// two tiles, measured itself a frame later and added the rest mid-slide, where they stood still
    /// while the page slid in around them.
    @State private var width: CGFloat = StripLimit.lastWidth
    @State private var wheelMonitor: Any?
    /// How far the row can go, for the wheel monitor (it outlives this copy of the view).
    @State private var limit = StripLimit()

    private var step: CGFloat { tileWidth + spacing }
    private var contentWidth: CGFloat { max(0, CGFloat(items.count) * step - spacing) }
    private var maxOffset: CGFloat { max(0, contentWidth - width) }

    /// The tiles at least partly in view, and one more on each side.
    private var visible: Range<Int> {
        guard !items.isEmpty, step > 0 else { return 0..<0 }
        let first = max(0, Int(floor(offset / step)) - 1)
        let last = min(items.count, Int(ceil((offset + max(width, step)) / step)) + 1)
        return first..<max(first, last)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(visible, id: \.self) { index in
                tile(items[index])
                    .frame(width: tileWidth, alignment: .topLeading)
                    .offset(x: CGFloat(index) * step - offset)
                    .id(items[index].id)
                    // Tiles scrolled into view are simply there; no fade of their own.
                    .transition(.identity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        .contentShape(Rectangle())
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { new in
            width = new
            if new > 0 { StripLimit.lastWidth = new }
        }
        .onHover { inside in inside ? startWheel() : stopWheel() }
        .onDisappear(perform: stopWheel)
        .onChange(of: items.first?.id) { offset = 0 }
        .onChange(of: maxOffset, initial: true) {
            limit.value = maxOffset
            offset = min(offset, maxOffset)
        }
        .onChange(of: visible.upperBound) { checkEnd() }
        .onChange(of: width) { checkEnd() }
    }

    private func checkEnd() {
        if !items.isEmpty, visible.upperBound >= items.count { onReachEnd() }
    }

    private func startWheel() {
        guard wheelMonitor == nil else { return }
        let offset = $offset, limit = limit
        wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
            // Sideways as it is; up/down turned sideways (down or towards you goes on to older ones).
            let delta = abs(dx) >= abs(dy) ? dx : dy
            guard delta != 0, limit.value > 0 else { return event }
            // A mouse wheel gives lines, a trackpad points.
            let points = event.hasPreciseScrollingDeltas ? delta : delta * 12
            offset.wrappedValue = min(max(offset.wrappedValue - points, 0), limit.value)
            return nil
        }
    }

    private func stopWheel() {
        if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor) }
        wheelMonitor = nil
    }
}

final class StripLimit {
    var value: CGFloat = 0
    /// The rows' width last measured (both rows are as wide as the panel's content); before the
    /// first measurement, about that.
    @MainActor static var lastWidth: CGFloat = 410
}

/// Small dark label on a picture: duration, markers, transcript state.
struct TileBadge<Label: View>: View {
    @ViewBuilder var label: () -> Label

    var body: some View {
        label()
            .font(.system(size: 10, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 3).fill(.black.opacity(0.62)))
    }
}
