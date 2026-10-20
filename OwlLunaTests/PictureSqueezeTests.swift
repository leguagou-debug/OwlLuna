import XCTest
@testable import OwlLuna

/// Squeezing a picture from a side grip, while its corner handle and a pinch keep its proportions.
@MainActor
final class PictureSqueezeTests: XCTestCase {
    private let paper = PageDefaults(template: .blank, paperColor: .white, pageSize: .letter)
    private let limit: CGFloat = 1200

    private func picture(_ size: CGSize = CGSize(width: 400, height: 200), rotation: CGFloat = 0) -> PageItem {
        PageItem(content: .image(file: "board.png"), center: CGPoint(x: 300, y: 400), size: size, rotation: rotation)
    }

    /// The middle of one side of an item, on the page.
    private func middle(of side: ItemSelectionView.Side, _ item: PageItem) -> CGPoint {
        let (x, y): (CGFloat, CGFloat) = switch side {
        case .top: (0, -item.size.height / 2)
        case .left: (-item.size.width / 2, 0)
        case .bottom: (0, item.size.height / 2)
        case .right: (item.size.width / 2, 0)
        }
        return CGPoint(x: item.center.x + x * cos(item.rotation) - y * sin(item.rotation), y: item.center.y + x * sin(item.rotation) + y * cos(item.rotation))
    }

    private func assertSamePlace(_ a: CGPoint, _ b: CGPoint, _ message: String = "", line: UInt = #line) {
        XCTAssertEqual(a.x, b.x, accuracy: 0.001, message, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: 0.001, message, line: line)
    }

    private func opposite(_ side: ItemSelectionView.Side) -> ItemSelectionView.Side {
        switch side {
        case .top: .bottom
        case .left: .right
        case .bottom: .top
        case .right: .left
        }
    }

    func testEachSideSqueezesThePictureAndTheOppositeSideStaysPut() {
        for rotation in [0, 0.4, .pi / 2] as [CGFloat] {
            let placed = picture(rotation: rotation)
            for side in ItemSelectionView.Side.allCases {
                let wide = side == .left || side == .right
                let out = ItemSelectionView.stretched(placed, side: side, by: 100, limit: limit)
                XCTAssertEqual(out.size, wide ? CGSize(width: 500, height: 200) : CGSize(width: 400, height: 300), "\(side) at \(rotation)")
                assertSamePlace(middle(of: opposite(side), out), middle(of: opposite(side), placed), "\(side) at \(rotation): the other side holds")
                XCTAssertEqual(out.rotation, rotation)
                let squeezed = ItemSelectionView.stretched(placed, side: side, by: -100, limit: limit)
                XCTAssertEqual(squeezed.size, wide ? CGSize(width: 300, height: 200) : CGSize(width: 400, height: 100))
                assertSamePlace(middle(of: opposite(side), squeezed), middle(of: opposite(side), placed))
            }
        }
    }

    func testASqueezeStopsAtAFingertipAndAtTheLimit() {
        let placed = picture()
        XCTAssertEqual(ItemSelectionView.stretched(placed, side: .left, by: -1000, limit: limit).size.width, PageItem.minimumSide)
        XCTAssertEqual(ItemSelectionView.stretched(placed, side: .top, by: -1000, limit: limit).size.height, PageItem.minimumSide)
        XCTAssertEqual(ItemSelectionView.stretched(placed, side: .right, by: 5000, limit: limit).size.width, limit)
    }

    func testASqueezeSettlesOnThePicturesOwnProportions() {
        let placed = picture()
        XCTAssertEqual(ItemSelectionView.stretched(placed, side: .right, by: 10, limit: limit, natural: 2).size.width, 400, "2.05 is within 3% of 2")
        XCTAssertEqual(ItemSelectionView.stretched(placed, side: .right, by: 20, limit: limit, natural: 2).size.width, 420)
        let squeezed = picture(CGSize(width: 300, height: 200))
        XCTAssertEqual(ItemSelectionView.stretched(squeezed, side: .left, by: 95, limit: limit, natural: 2).size.width, 400)
        XCTAssertEqual(ItemSelectionView.stretched(squeezed, side: .bottom, by: -48, limit: limit, natural: 2).size.height, 150, "height settles too")
        XCTAssertEqual(ItemSelectionView.stretched(squeezed, side: .right, by: 95, limit: limit).size.width, 395, "nothing to settle on before the file is read")
    }

    func testTheCornerAndAPinchKeepASqueezedPicturesProportions() {
        let squeezed = ItemSelectionView.stretched(picture(), side: .bottom, by: 100, limit: limit)
        let larger = squeezed.scaled(by: 1.5, limit: limit)
        XCTAssertEqual(larger.size.width / larger.size.height, squeezed.size.width / squeezed.size.height, accuracy: 0.0001)
        XCTAssertEqual(larger.size.width, 600, accuracy: 0.001)
    }

    func testACropKeepsTheSqueeze() {
        let squeezed = ItemSelectionView.stretched(picture(), side: .right, by: 100, limit: limit)
        let cropped = squeezed.cropped(to: CGRect(x: 0.5, y: 0, width: 0.5, height: 1))
        XCTAssertEqual(cropped.size, CGSize(width: 250, height: 200))
        XCTAssertEqual(cropped.cropped(to: nil).size, squeezed.size, "the whole picture comes back squeezed")
    }

    func testTextAndTapeOnlyGetWider() {
        let box = TextBox(string: "A line long enough to wrap when the box is narrow")
        let text = PageItem(content: .text(box), center: CGPoint(x: 200, y: 200), size: CGSize(width: 300, height: box.height(width: 300)))
        let narrow = ItemSelectionView.stretched(text, side: .right, by: -150, limit: limit)
        XCTAssertEqual(narrow.size.width, 150)
        XCTAssertEqual(narrow.size.height, box.height(width: 150), "the text wraps again")
        XCTAssertGreaterThan(narrow.size.height, text.size.height)
        assertSamePlace(CGPoint(x: narrow.center.x - 75, y: narrow.center.y - narrow.size.height / 2),
                        CGPoint(x: text.center.x - 150, y: text.center.y - text.size.height / 2), "and grows downwards from its top left")
        let tape = PageItem(content: .tape(.mustard), center: CGPoint(x: 200, y: 200), size: CGSize(width: 200, height: 30))
        XCTAssertEqual(ItemSelectionView.stretched(tape, side: .right, by: 100, limit: limit).size, CGSize(width: 300, height: 30))
    }

    // MARK: In the editor

    /// 40 by 20 pixels, so the picture's own proportions are 2 to 1.
    private func board() -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: 40, height: 20), format: format).pngData { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        }
    }

    private func pause(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    func testTheGripsSqueezeAPictureForVoiceOverAsOneUndoStepEach() async throws {
        let root = temporaryRoot(self)
        let manifest = NotebookManifest(title: "Squeeze", defaults: paper, pages: [paper.newPage()])
        try await NotebookPackage(root: root, id: manifest.id).create(manifest)
        let document = try await NotebookDocument.open(manifest.id, root: root)
        let file = try await document.package.writeAsset(board(), ext: "png")
        let box = TextBox(string: "Notes")
        let placed = PageItem(content: .image(file: file), center: CGPoint(x: 306, y: 396), size: CGSize(width: 400, height: 200))
        let text = PageItem(content: .text(box), center: CGPoint(x: 306, y: 100), size: CGSize(width: 200, height: box.height(width: 200)))
        let sticker = PageItem(content: .sticker(Sticker.star.rawValue), center: CGPoint(x: 306, y: 650), size: CGSize(width: 100, height: 100))
        document.undoManager.groupsByEvent = false
        document.undoManager.beginUndoGrouping()
        document.updateItems(onPage: document.pages[0].id, actionName: "Add to Page") { $0 += [placed, text, sticker] }
        document.undoManager.endUndoGrouping()
        let pageID = document.pages[0].id
        let session = EditorSession(document: document)
        let controller = PageStackController(session: session)
        session.canvas = controller
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 834, height: 1194)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        addTeardownBlock { @MainActor in window.isHidden = true }
        controller.view.layoutIfNeeded()
        for _ in 0..<100 where controller.canvas(forPage: 0)?.isLoaded != true { await pause(0.05) }

        func grips() -> [UIView] {
            var views: [UIView] = [window], found: [UIView] = []
            while !views.isEmpty {
                let view = views.removeFirst()
                if view.superview is ItemSelectionView, view.accessibilityIdentifier?.hasPrefix("page.grip.") == true, !view.isHidden { found.append(view) }
                views += view.subviews
            }
            return found
        }
        func grip(_ label: String) throws -> UIView { try XCTUnwrap(grips().first { $0.accessibilityLabel == label && $0.isAccessibilityElement }) }
        func step(_ change: () -> Void) {
            document.undoManager.beginUndoGrouping()
            change()
            document.undoManager.endUndoGrouping()
        }
        func current() throws -> PageItem { try XCTUnwrap(document.pages[0].items.first { $0.id == placed.id }) }

        controller.select(ItemSelection(pageID: pageID, itemID: text.id))
        XCTAssertEqual(grips().count, 1, "a text box keeps its one width grip")
        controller.select(ItemSelection(pageID: pageID, itemID: sticker.id))
        XCTAssertEqual(grips().count, 0, "a drawn sticker is never squeezed")
        controller.select(ItemSelection(pageID: pageID, itemID: placed.id))
        XCTAssertEqual(grips().count, 4, "a picture has a grip on each side")
        XCTAssertEqual(grips().filter(\.isAccessibilityElement).compactMap(\.accessibilityLabel).sorted(), ["Change height", "Change width"],
                       "VoiceOver hears one for each way it can be squeezed")

        XCTAssertEqual(try grip("Change width").accessibilityValue, "400 pt")
        step { try? grip("Change width").accessibilityIncrement() }
        XCTAssertEqual(document.undoManager.undoActionName, "Arrange")
        let wider = try current()
        XCTAssertEqual(wider.size, CGSize(width: 440, height: 200))
        assertSamePlace(middle(of: .left, wider), middle(of: .left, placed), "the left side holds")
        XCTAssertEqual(try grip("Change width").accessibilityValue, "440 pt")

        func shown() -> PageItemView? {
            var views: [UIView] = [window]
            while !views.isEmpty {
                let view = views.removeFirst()
                if let item = view as? PageItemView, item.item.id == placed.id { return item }
                views += view.subviews
            }
            return nil
        }
        for _ in 0..<100 where shown()?.naturalAspect == nil { await pause(0.05) }
        XCTAssertEqual(try XCTUnwrap(shown()?.naturalAspect), 2, accuracy: 0.0001)
        step { try? grip("Change width").accessibilityDecrement() }
        XCTAssertEqual(try current().size, CGSize(width: 400, height: 200), "396 pt settles back on the picture's own 2 to 1")

        step { try? grip("Change height").accessibilityDecrement() }
        let shorter = try current()
        XCTAssertEqual(shorter.size, CGSize(width: 400, height: 180))
        assertSamePlace(middle(of: .top, shorter), middle(of: .top, placed), "the top holds")

        document.undoManager.undo()
        XCTAssertEqual(try current().size, CGSize(width: 400, height: 200))
        document.undoManager.undo()
        document.undoManager.undo()
        XCTAssertEqual(try current().size, placed.size)
        assertSamePlace(try current().center, placed.center, "back where it was placed")
    }
}
