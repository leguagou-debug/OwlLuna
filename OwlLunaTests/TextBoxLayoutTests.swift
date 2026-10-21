import XCTest
import UIKit
@testable import OwlLuna

/// Text laid out by TextKit at a width, from the top left, as boxes are measured and drawn.
private struct TextLayout {
    let manager = NSLayoutManager()
    let container: NSTextContainer
    let storage: NSTextStorage

    init(_ text: NSAttributedString, width: CGFloat) {
        storage = NSTextStorage(attributedString: text)
        container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
    }

    var lines: [CGRect] {
        var rects: [CGRect] = [], glyph = 0
        while glyph < manager.numberOfGlyphs {
            var range = NSRange()
            rects.append(manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &range))
            glyph = max(NSMaxRange(range), glyph + 1)
        }
        return rects
    }

    func rect(ofCharacter index: Int) -> CGRect {
        let glyph = manager.glyphIndexForCharacter(at: index)
        return manager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
    }

    func line(ofCharacter index: Int) -> CGRect {
        manager.lineFragmentRect(forGlyphAt: manager.glyphIndexForCharacter(at: index), effectiveRange: nil)
    }
}

@MainActor
final class TextBoxLayoutTests: XCTestCase {
    private let width: CGFloat = 240
    private let longFirstWord = "Phenolphthalein indicator\nRinse burette"

    private func height(_ text: NSAttributedString, width: CGFloat, font: UIFont) -> CGFloat {
        let bounds = text.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading],
                                       context: nil)
        return max(bounds.height, font.lineHeight).rounded(.up)
    }

    /// Where each line of a box starts in its text.
    private func lineStarts(_ box: TextBox) -> [Int] {
        var offset = 0
        return box.lines.map { line in
            defer { offset += (line as NSString).length + 1 }
            return offset
        }
    }

    func testAnItemWhoseFirstWordOutrunsItsLineIsDrawnOnTheLinesItIsTypedOn() {
        for list in TextBox.List.allCases {
            let box = TextBox(string: longFirstWord, fontSize: 34, list: list)
            let typed = box.editingText(scale: 1, onDark: false), layout = TextLayout(typed, width: width)
            let indent = layout.rect(ofCharacter: 0).minX
            XCTAssertGreaterThan(("Phenolphthalein" as NSString).size(withAttributes: [.font: box.font()]).width, width - indent,
                                 "\(list): the first word is wider than the room beside its marker")
            let lines = layout.lines
            XCTAssertGreaterThan(lines.count, box.lines.count, "\(list): the first word wraps")
            let drawn = box.height(width: width)
            XCTAssertEqual(Int((drawn / lines[0].height).rounded()), lines.count, "\(list) is drawn on as many lines as it is typed on")
            XCTAssertEqual(drawn, height(typed, width: width, font: box.font()), accuracy: 0.5, "\(list) is as tall drawn as typed")
        }
    }

    func testAChecklistsBoxesStayOnTheirLinesBesideALongFirstWord() {
        var box = TextBox(string: longFirstWord, fontSize: 34, list: .check)
        box.checked = [0]
        let starts = lineStarts(box)
        for scale in [1, 1.5, 2.25] as [CGFloat] {
            let layout = TextLayout(box.editingText(scale: scale, onDark: false), width: width * scale)
            let boxes = box.checkboxes(width: width * scale, scale: scale)
            XCTAssertEqual(boxes.map(\.line), [0, 1], "at \(scale)×")
            for (line, rect) in boxes {
                let typed = layout.line(ofCharacter: starts[line])
                XCTAssertTrue(typed.minY < rect.midY && rect.midY < typed.maxY, "at \(scale)×: line \(line)'s box sits on the line its words start on")
                XCTAssertLessThan(rect.maxX, layout.rect(ofCharacter: starts[line]).minX, "at \(scale)×: line \(line)'s words start after its box")
            }
        }
    }

    func testATypedTabStopsWhereThePageDoesAtAnyZoom() throws {
        let box = TextBox(string: "Mass\tgrams")
        let word = ("Mass\t" as NSString).length
        let onPage = TextLayout(box.editingText(scale: 1, onDark: false), width: width).rect(ofCharacter: word).minX
        XCTAssertGreaterThan(onPage, ("Mass" as NSString).size(withAttributes: [.font: box.font()]).width, "the tab moves the word on")
        let stops = NSParagraphStyle.default.tabStops
        for scale in [1, 1.5, 2, 2.25] as [CGFloat] {
            let typed = box.editingText(scale: scale, onDark: false)
            let x = TextLayout(typed, width: width * scale).rect(ofCharacter: word).minX / scale
            XCTAssertEqual(x, onPage, accuracy: 0.5, "at \(scale)×, the words after a tab start where the page draws them")
            let style = try XCTUnwrap(typed.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
            XCTAssertEqual(style.tabStops.map(\.location), stops.map { $0.location * scale }, "at \(scale)×, the page's tab stops are enlarged with the type")
            XCTAssertEqual(style.tabStops.map(\.alignment), stops.map(\.alignment))
        }
    }
}
