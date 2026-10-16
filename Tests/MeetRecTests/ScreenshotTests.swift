import Carbon
import XCTest
@testable import MeetRec

/// Screenshot coordinates and files: a wrong flip captures the wrong part of the screen, a lost DPI
/// makes pasted shots twice as large.
final class ScreenshotTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("MeetRecTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func image(width: Int, height: Int) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    func testSelectionFlipsToTopLeftOrigin() {
        // Dragged from bottom right to top left on a 1000-point-high screen.
        let rect = AreaSelection.displayRect(CGRect(x: 300, y: 700, width: -200, height: -100), viewHeight: 1000)
        XCTAssertEqual(rect, CGRect(x: 100, y: 300, width: 200, height: 100))
    }

    func testWindowRectsMapOntoEachScreen() {
        // Main screen 1512×982 at the origin; an external 2560×1440 to its right, tops aligned.
        let main = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let external = CGRect(x: 1512, y: -458, width: 2560, height: 1440)
        let window = CGRect(x: 1612, y: 100, width: 800, height: 600) // global, top-left origin
        XCTAssertNil(FrozenScreen.viewRect(ofGlobal: window, screenFrame: main, mainHeight: 982))
        XCTAssertEqual(FrozenScreen.viewRect(ofGlobal: window, screenFrame: external, mainHeight: 982),
                       CGRect(x: 100, y: 740, width: 800, height: 600))
    }

    func testBlurReadsOnlyItsAreaInSquares() throws {
        let source = try image(width: 400, height: 300)
        let blur = Annotation(kind: .blur, start: CGPoint(x: 10, y: 20), end: CGPoint(x: 110, y: 70), color: 0, blur: 8)
        let blocks = try XCTUnwrap(AnnotationDrawing.pixelated(blur, source: source, scale: 2))
        XCTAssertEqual(blocks.rect, CGRect(x: 10, y: 20, width: 100, height: 50))
        // 16-pixel squares: 100 / 16 → 7 columns, 50 / 16 → 4 rows.
        XCTAssertEqual(blocks.image.width, 7)
        XCTAssertEqual(blocks.image.height, 4)
    }

    func testOCRRegionIsNormalisedFromBottomLeft() {
        let region = ScreenshotFiles.normalizedRegion(CGRect(x: 0, y: 0, width: 50, height: 25), width: 200, height: 100)
        XCTAssertEqual(region, CGRect(x: 0, y: 0.75, width: 0.25, height: 0.25))
        let outside = ScreenshotFiles.normalizedRegion(CGRect(x: 150, y: 50, width: 100, height: 100), width: 200, height: 100)
        XCTAssertEqual(outside, CGRect(x: 0.75, y: 0, width: 0.25, height: 0.5))
    }

    func testLineWord() {
        XCTAssertEqual([1, 2, 5, 11, 21, 22, 25, 112].map(Screenshotter.lineWord),
                       ["строка", "строки", "строк", "строк", "строка", "строки", "строк", "строк"])
    }

    func testSaveKeepsScaleAndTimestampName() throws {
        let date = ISO8601DateFormatter().date(from: "2026-10-16T10:03:22Z")!
        let shot = try image(width: 40, height: 20)
        let first = try ScreenshotFiles.save(shot, scale: 2, in: folder, date: date)
        let second = try ScreenshotFiles.save(shot, scale: 2, in: folder, date: date)
        XCTAssertEqual(first.lastPathComponent, RecordingFiles.timestamp(date) + ".png")
        XCTAssertEqual(second.lastPathComponent, RecordingFiles.timestamp(date) + " (2).png")

        let loaded = try XCTUnwrap(ScreenshotFiles.load(first))
        XCTAssertEqual(loaded.scale, 2)
        XCTAssertEqual(loaded.image.width, 40)
        XCTAssertEqual(loaded.image.height, 20)
    }

    func testKeyComboText() {
        XCTAssertEqual(KeyCombo.screenshotDefault.text, "⇧⌘4")
        let combo = KeyCombo(keyCode: kVK_ANSI_S, modifiers: KeyCombo.carbonModifiers([.control, .option, .command]),
                             label: KeyCombo.label(keyCode: kVK_ANSI_S, characters: "s"))
        XCTAssertEqual(combo.text, "⌃⌥⌘S")
        XCTAssertEqual(KeyCombo.label(keyCode: kVK_F5, characters: "\u{F708}"), "F5")
        XCTAssertFalse(KeyCombo.isUsable([.shift]))
        XCTAssertTrue(KeyCombo.isUsable([.shift, .option]))
    }

    func testAutoFormatKeepsFlatPicturesPNGAndEditsKeepTheirFormat() throws {
        let flat = try image(width: 200, height: 100)
        XCTAssertEqual(try ScreenshotFiles.encode(flat, scale: 2, auto: true).1, "png")
        let jpeg = folder.appendingPathComponent("photo.jpg")
        try ScreenshotFiles.write(flat, scale: 2, to: jpeg)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(jpeg as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, "public.jpeg")
        XCTAssertEqual(ScreenshotFiles.load(jpeg)?.scale, 2)
    }

    func testListOrderFollowsTheNameNotTheFileDate() throws {
        let shot = try image(width: 4, height: 4)
        let old = try ScreenshotFiles.save(shot, scale: 1, in: folder, date: Date(timeIntervalSince1970: 0))
        _ = try ScreenshotFiles.save(shot, scale: 1, in: folder, date: Date(timeIntervalSince1970: 600))
        // Editing the old one rewrites it: a fresh creation date.
        try ScreenshotFiles.write(shot, scale: 1, to: old)
        XCTAssertNotEqual(ScreenshotFiles.list(in: folder).items.first?.url, old)
    }

    func testListNewestFirstAndCountsAll() throws {
        let shot = try image(width: 4, height: 4)
        for minute in 0..<7 {
            let url = try ScreenshotFiles.save(shot, scale: 1, in: folder, date: Date(timeIntervalSince1970: Double(minute) * 60))
            try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: Double(minute) * 60)], ofItemAtPath: url.path)
        }
        FileManager.default.createFile(atPath: folder.appendingPathComponent("notes.txt").path, contents: Data())
        let list = ScreenshotFiles.list(in: folder)
        XCTAssertEqual(list.total, 7)
        XCTAssertEqual(list.items.count, ScreenshotFiles.panelLimit)
        XCTAssertEqual(list.items.first?.date, Date(timeIntervalSince1970: 360))
    }
}

/// Editor marks as objects: bending, picking by click, reshaping, step numbers.
final class AnnotationGeometryTests: XCTestCase {
    private func arrow(bend: CGPoint? = nil) -> Annotation {
        Annotation(kind: .arrow, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 100, y: 0), color: 0, bend: bend)
    }

    func testBentArrowPassesThroughItsHandle() {
        let bent = arrow(bend: CGPoint(x: 30, y: 40))
        let middle = AnnotationGeometry.point(bent, at: 0.5)
        XCTAssertEqual(middle.x, 30, accuracy: 0.001)
        XCTAssertEqual(middle.y, 40, accuracy: 0.001)
        XCTAssertEqual(AnnotationGeometry.point(bent, at: 0), CGPoint(x: 0, y: 0))
        XCTAssertEqual(AnnotationGeometry.point(bent, at: 1), CGPoint(x: 100, y: 0))
    }

    func testBendSnapsBackToStraight() {
        let bent = AnnotationGeometry.reshaped(arrow(), .bend, to: CGPoint(x: 50, y: 30), tolerance: 5)
        XCTAssertEqual(bent.bend, CGPoint(x: 50, y: 30))
        let straight = AnnotationGeometry.reshaped(bent, .bend, to: CGPoint(x: 60, y: 2), tolerance: 5)
        XCTAssertNil(straight.bend)
    }

    func testArrowIsPickedAlongItsCurveOnly() {
        let bent = arrow(bend: CGPoint(x: 50, y: 40))
        XCTAssertTrue(AnnotationGeometry.hits(bent, CGPoint(x: 50, y: 41), tolerance: 4, scale: 1))
        XCTAssertFalse(AnnotationGeometry.hits(bent, CGPoint(x: 50, y: 0), tolerance: 4, scale: 1))
    }

    func testFrameIsPickedByItsBorderNotInside() {
        let frame = Annotation(kind: .rectangle, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 200, y: 100), color: 0)
        XCTAssertTrue(AnnotationGeometry.hits(frame, CGPoint(x: 1, y: 50), tolerance: 4, scale: 1))
        XCTAssertFalse(AnnotationGeometry.hits(frame, CGPoint(x: 100, y: 50), tolerance: 4, scale: 1))
        let blur = Annotation(kind: .blur, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 200, y: 100), color: 0)
        XCTAssertTrue(AnnotationGeometry.hits(blur, CGPoint(x: 100, y: 50), tolerance: 4, scale: 1))
    }

    func testCornerDragKeepsOppositeCorner() {
        let frame = Annotation(kind: .rectangle, start: CGPoint(x: 10, y: 10), end: CGPoint(x: 110, y: 60), color: 0)
        // Corner 2 is the bottom right; the top left stays.
        let resized = AnnotationGeometry.reshaped(frame, .corner(2), to: CGPoint(x: 150, y: 90), tolerance: 4)
        XCTAssertEqual(resized.rect, CGRect(x: 10, y: 10, width: 140, height: 80))
    }

    func testMoveTakesTheBendAlong() {
        let moved = AnnotationGeometry.translated(arrow(bend: CGPoint(x: 50, y: 20)), by: CGSize(width: 5, height: -5))
        XCTAssertEqual(moved.start, CGPoint(x: 5, y: -5))
        XCTAssertEqual(moved.end, CGPoint(x: 105, y: -5))
        XCTAssertEqual(moved.bend, CGPoint(x: 55, y: 15))
    }

    @MainActor
    func testUndoRedo() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 10, height: 10, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let document = EditorDocument(url: URL(fileURLWithPath: "/tmp/none.png"), image: try XCTUnwrap(context.makeImage()), scale: 1)
        document.add(arrow())
        document.add(arrow())
        document.undo()
        XCTAssertEqual(document.annotations.count, 1)
        document.redo()
        XCTAssertEqual(document.annotations.count, 2)
        document.undo()
        document.add(arrow(bend: CGPoint(x: 1, y: 1)))
        document.redo() // a new change drops what could be redone
        XCTAssertEqual(document.annotations.count, 2)
    }

    func testStepsRenumberAfterDelete() {
        let steps = (1...3).map { Annotation(kind: .step($0), start: .zero, end: .zero, color: 0) }
        let marks = [steps[0], arrow(), steps[2]]
        let numbers = AnnotationGeometry.renumbered(marks).compactMap { mark -> Int? in
            if case .step(let n) = mark.kind { return n } else { return nil }
        }
        XCTAssertEqual(numbers, [1, 2])
    }
}
