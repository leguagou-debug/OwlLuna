import XCTest
import PencilKit
@testable import OwlLuna

/// The Shapes shortcut: the strip over the tray, the shape a drag gives, and what is saved of it.
@MainActor
final class ShapeStripTests: XCTestCase {
    private func freshDefaults() throws -> UserDefaults {
        let suite = "ShapeStripTests-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        return try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    func testADragGivesTheShapeInItsBoxWhicheverWayItGoes() {
        XCTAssertEqual(ShapeKind.line.shape(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 110, y: 12)),
                       .line(CGPoint(x: 10, y: 11), CGPoint(x: 110, y: 11)), "a line dragged nearly level is made level")
        XCTAssertEqual(ShapeKind.line.shape(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 60, y: 90)), .line(CGPoint(x: 10, y: 10), CGPoint(x: 60, y: 90)))
        XCTAssertEqual(ShapeKind.circle.shape(from: CGPoint(x: 100, y: 100), to: .zero),
                       .ellipse(center: CGPoint(x: 50, y: 50), radii: CGSize(width: 50, height: 50), rotation: 0))
        XCTAssertEqual(ShapeKind.circle.shape(from: .zero, to: CGPoint(x: 200, y: 100)),
                       .ellipse(center: CGPoint(x: 100, y: 50), radii: CGSize(width: 100, height: 50), rotation: 0), "a long box gives an ellipse")
        XCTAssertEqual(ShapeKind.circle.shape(from: .zero, to: CGPoint(x: 100, y: 92)),
                       .ellipse(center: CGPoint(x: 50, y: 46), radii: CGSize(width: 48, height: 48), rotation: 0), "a nearly square one a circle")
        XCTAssertEqual(ShapeKind.rectangle.shape(from: CGPoint(x: 40, y: 10), to: CGPoint(x: 0, y: 50)),
                       .polygon([CGPoint(x: 0, y: 10), CGPoint(x: 40, y: 10), CGPoint(x: 40, y: 50), CGPoint(x: 0, y: 50)]))
        XCTAssertEqual(ShapeKind.triangle.shape(from: CGPoint(x: 60, y: 40), to: .zero),
                       .polygon([CGPoint(x: 30, y: 0), CGPoint(x: 60, y: 40), CGPoint(x: 0, y: 40)]), "a triangle stands on the box's foot")
    }

    func testAShapeIsDrawnInThePensInkAndReadsAsItself() throws {
        let tool = PKInkingTool(.monoline, color: ToolPreset.uiColor(0x2747_B8FF), width: 4)
        let drawn: [(ShapeKind, String)] = [(.line, "line"), (.circle, "circle"), (.rectangle, "rectangle"), (.triangle, "triangle")]
        for (kind, name) in drawn {
            let start = CGPoint(x: 100, y: 80), end = CGPoint(x: 260, y: 200)
            let stroke = ShapeSnap.stroke(kind.shape(from: start, to: end), tool: tool, startingNear: start)
            XCTAssertEqual(stroke.ink.inkType, .monoline)
            XCTAssertEqual(ToolPreset.bytes(of: stroke.ink.color), 0x2747_B8FF, "in the pen's colour")
            XCTAssertEqual(try XCTUnwrap(stroke.path.first).size.width, 4, accuracy: 0.01, "as wide as the pen")
            let bounds = PKDrawing(strokes: [stroke]).bounds
            XCTAssertEqual(bounds.minX, 100, accuracy: 4, name)
            XCTAssertEqual(bounds.maxX, 260, accuracy: 4, name)
            XCTAssertEqual(bounds.minY, 80, accuracy: 4, name)
            XCTAssertEqual(bounds.maxY, 200, accuracy: 4, name)
            // Draw and hold would leave it as it is.
            let points = stroke.path.interpolatedPoints(by: .distance(3)).map(\.location)
            XCTAssertEqual(ShapeRecognizer.recognize(points)?.displayName, name == "circle" ? "ellipse" : name)
        }
    }

    func testTheStripComesOutWithTheLastShapeAndAPen() throws {
        let defaults = try freshDefaults()
        let toolbox = Toolbox(defaults: defaults)
        let pens = toolbox.shelf.usable
        XCTAssertNil(toolbox.shape)
        toolbox.take(.pen(pens[2].id))
        toolbox.take(.eraser)
        toolbox.setShapesOut(true)
        XCTAssertEqual(toolbox.shape, .circle, "it comes out with a circle the first time")
        XCTAssertEqual(toolbox.choice, .pen(pens[2].id), "and the pen last in hand, since a shape is drawn in ink")

        toolbox.pick(.triangle)
        toolbox.take(.pen(pens[1].id))
        XCTAssertEqual(toolbox.shape, .triangle, "another pen draws the shape in its ink")
        toolbox.setShapesOut(false)
        XCTAssertNil(toolbox.shape)
        toolbox.setShapesOut(true)
        XCTAssertEqual(toolbox.shape, .triangle, "and it comes back with the shape last picked")

        toolbox.take(.lasso)
        XCTAssertNil(toolbox.shape, "the lasso puts it away")
        toolbox.pick(.line)
        XCTAssertEqual(toolbox.shape, .line)
        XCTAssertNotNil(toolbox.pen)
        toolbox.isRulerActive = true
        XCTAssertNil(toolbox.shape, "the ruler and the shapes both take the drags, so one puts the other away")
        toolbox.setShapesOut(true)
        XCTAssertFalse(toolbox.isRulerActive)

        toolbox.setExtra(.shapes, shown: true)
        toolbox.setExtra(.shapes, shown: false)
        XCTAssertNil(toolbox.shape, "taken off the tray, it is put away")
        toolbox.setShapesOut(true)
        XCTAssertNil(Toolbox(defaults: defaults).shape, "like the ruler, it is put away between launches")
    }

    /// An older build reads the saved shortcuts as names and leaves out the ones it doesn't know.
    func testAnOlderBuildKeepsItsOwnToolsBesideASavedShapesShortcut() throws {
        let defaults = try freshDefaults()
        let toolbox = Toolbox(defaults: defaults)
        toolbox.setExtra(.shapes, shown: true)
        toolbox.setExtra(.ruler, shown: true)
        toolbox.take(.eraser)
        toolbox.setEraser(Eraser(kind: .part, width: 30))

        struct Older: Decodable {
            var choice: ToolChoice?
            var eraser: Eraser?
            var extras: [String]?
        }
        let known: Set = ["picture", "text", "sticker", "link", "tape", "ruler", "zoomWindow", "typing"]
        let data = try XCTUnwrap(defaults.data(forKey: SettingsKey.toolbox))
        let older = try JSONDecoder().decode(Older.self, from: data)
        XCTAssertEqual(older.extras, ["picture", "text", "ruler", "shapes"])
        XCTAssertEqual(older.extras?.filter(known.contains), ["picture", "text", "ruler"])
        XCTAssertEqual(older.choice, .eraser)
        XCTAssertEqual(older.eraser, Eraser(kind: .part, width: 30))
    }

    func testShortcutsALaterBuildSavedAreKept() throws {
        let defaults = try freshDefaults()
        defaults.set(Data(#"{"extras":["picture","stamp"]}"#.utf8), forKey: SettingsKey.toolbox)
        let toolbox = Toolbox(defaults: defaults)
        XCTAssertEqual(toolbox.extras, [.picture])
        toolbox.setExtra(.shapes, shown: true)
        let saved = try JSONSerialization.jsonObject(with: XCTUnwrap(defaults.data(forKey: SettingsKey.toolbox))) as? [String: Any]
        XCTAssertEqual(saved?["extras"] as? [String], ["picture", "shapes", "stamp"])
    }
}
