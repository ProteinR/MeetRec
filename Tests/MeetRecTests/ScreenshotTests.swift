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

    @MainActor
    func testOnlyTheTitleBarTakesAWindow() {
        // View coordinates, y up; the front window overlaps the back one's title bar.
        let front = CGRect(x: 100, y: 100, width: 400, height: 300)  // title bar y 368…400
        let back = CGRect(x: 300, y: 200, width: 400, height: 300)   // title bar y 468…500
        let windows = [front, back]
        XCTAssertEqual(AreaSelector.window(at: CGPoint(x: 200, y: 390), in: windows), front)
        XCTAssertNil(AreaSelector.window(at: CGPoint(x: 200, y: 250), in: windows))  // inside, below the bar
        XCTAssertEqual(AreaSelector.window(at: CGPoint(x: 600, y: 480), in: windows), back)
        XCTAssertNil(AreaSelector.window(at: CGPoint(x: 450, y: 380), in: [CGRect(x: 0, y: 0, width: 10, height: 10)] + [back]))
        XCTAssertNil(AreaSelector.window(at: CGPoint(x: 50, y: 50), in: windows))  // desktop
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
        XCTAssertEqual(ShortcutAction.screenshot.defaultCombo?.text, "⇧⌘4")
        XCTAssertEqual(ShortcutAction.text.defaultCombo?.text, "⇧⌘2")
        XCTAssertEqual(ShortcutAction.record.defaultCombo?.text, "⌃⌥⌘R")
        XCTAssertEqual(ShortcutAction.marker.defaultCombo?.text, "⌃⌥⌘M")
        XCTAssertNil(ShortcutAction.pause.defaultCombo)
        XCTAssertEqual(ShortcutAction.screenshot.defaultCombo?.menuKey.key, "4")
        XCTAssertEqual(ShortcutAction.screenshot.defaultCombo?.menuKey.modifiers, [.command, .shift])
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

    func testEditingAnOldShotKeepsItsPlace() throws {
        let shot = try image(width: 4, height: 4)
        let old = try ScreenshotFiles.save(shot, scale: 1, in: folder, date: Date(timeIntervalSince1970: 0))
        try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: old.path)
        // A Shottr file, named differently, taken later.
        let shottr = folder.appendingPathComponent("SCR-20261016-abc.png")
        try ScreenshotFiles.write(shot, scale: 1, to: shottr)
        try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: 600)], ofItemAtPath: shottr.path)
        // Editing the old one rewrites the file; its creation date stays.
        try ScreenshotFiles.write(shot, scale: 1, to: old)
        XCTAssertEqual(ScreenshotFiles.list(in: folder).items.map(\.url.lastPathComponent),
                       [shottr.lastPathComponent, old.lastPathComponent])
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

    /// Google shows its results only to the session that uploaded the picture, so the browser posts
    /// it from this page: the whole picture, to the given form field.
    @MainActor
    func testBrowserUploadPageHoldsThePicture() throws {
        let png = try XCTUnwrap(ScreenshotFiles.png(image(width: 8, height: 8), scale: 1))
        let form = URL(string: "https://lens.google.com/v3/upload?hl=ru&st=1")!
        let page = try ImageSearch.writeUploadPage(png, to: form, field: "encoded_image")
        defer { try? FileManager.default.removeItem(at: page) }
        let html = try String(contentsOf: page, encoding: .utf8)
        XCTAssertTrue(html.contains(#"action="https://lens.google.com/v3/upload?hl=ru&amp;st=1""#))
        XCTAssertTrue(html.contains(#"name="encoded_image""#))
        XCTAssertTrue(html.contains(png.base64EncodedString()))
        XCTAssertTrue(html.contains("form.submit()"))
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

    /// Crop works as in Photoshop: a frame, Enter cuts to it, a second crop cuts the shown part,
    /// undo and "Вернуть всё" bring the picture back.
    @MainActor
    func testCropFrameAppliesAndUndoes() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let document = EditorDocument(url: URL(fileURLWithPath: "/tmp/crop-test.png"), image: image, scale: 2)
        XCTAssertEqual(document.visibleRect, CGRect(x: 0, y: 0, width: 400, height: 300))

        document.pendingCrop = CGRect(x: 10.4, y: 20, width: 200, height: 100)
        document.applyPendingCrop()
        XCTAssertNil(document.pendingCrop)
        XCTAssertEqual(document.visibleRect, CGRect(x: 10, y: 20, width: 201, height: 100))

        // Only inside what is shown.
        document.pendingCrop = CGRect(x: 0, y: 0, width: 100, height: 60)
        document.applyPendingCrop()
        XCTAssertEqual(document.visibleRect, CGRect(x: 10, y: 20, width: 90, height: 40))

        // A tiny frame (a click) changes nothing.
        document.pendingCrop = CGRect(x: 30, y: 30, width: 2, height: 2)
        document.applyPendingCrop()
        XCTAssertEqual(document.visibleRect, CGRect(x: 10, y: 20, width: 90, height: 40))

        document.undo()
        XCTAssertEqual(document.visibleRect, CGRect(x: 10, y: 20, width: 201, height: 100))
        document.resetCrop()
        XCTAssertEqual(document.visibleRect, CGRect(x: 0, y: 0, width: 400, height: 300))
        document.undo()
        XCTAssertEqual(document.crop, CGRect(x: 10, y: 20, width: 201, height: 100))
    }

    /// A window shot's margin can be changed in the editor: the picture is cut again, marks stay on
    /// the window, undo brings the margin back, and the screen's edge limits the wallpaper.
    @MainActor
    func testWindowShotMarginMovesMarks() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        let full = try XCTUnwrap(context.makeImage())
        let shot = WindowShot(full: full, window: CGRect(x: 100, y: 80, width: 200, height: 140), scale: 2)
        XCTAssertEqual(shot.rect(margin: 12), CGRect(x: 76, y: 56, width: 248, height: 188))
        XCTAssertEqual(shot.rect(margin: 80), CGRect(x: 0, y: 0, width: 400, height: 300))

        let image = try XCTUnwrap(shot.image(margin: 12))
        // Rounded outer corners: transparent in the corner, opaque inside.
        XCTAssertEqual(try alpha(of: image, x: 0, y: 0), 0)
        XCTAssertEqual(try alpha(of: image, x: image.width / 2, y: image.height / 2), 255)
        let document = EditorDocument(url: URL(fileURLWithPath: "/tmp/window.png"), image: image, scale: 2,
                                      windowShot: (shot, 12))
        XCTAssertNotNil(document.windowShot)
        document.add(Annotation(kind: .rectangle, start: CGPoint(x: 10, y: 10), end: CGPoint(x: 20, y: 20), color: 0))

        document.setMargin(20, record: true)
        XCTAssertEqual(document.imageSize, CGSize(width: 280, height: 220))
        XCTAssertEqual(document.annotations.first?.start, CGPoint(x: 26, y: 26))

        document.undo()
        XCTAssertEqual(document.margin, 12)
        XCTAssertEqual(document.imageSize, CGSize(width: 248, height: 188))
        XCTAssertEqual(document.annotations.first?.start, CGPoint(x: 10, y: 10))

        // A file that no longer matches the shot (cropped, edited) gets no slider.
        let other = EditorDocument(url: URL(fileURLWithPath: "/tmp/window.png"), image: full, scale: 2, windowShot: (shot, 12))
        XCTAssertNil(other.windowShot)
    }

    private func alpha(of image: CGImage, x: Int, y: Int) throws -> UInt8 {
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return pixel[3]
    }
}
