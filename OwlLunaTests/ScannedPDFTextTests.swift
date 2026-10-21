import XCTest
import PDFKit
@testable import OwlLuna

/// Selecting the words on a PDF page that is a picture of a page, and a highlighter snapping to them, from what the
/// recogniser read off it.
final class ScannedPDFTextTests: XCTestCase {
    /// As tall as a sample sheet is for a letter page's width.
    private let size = CGSize(width: 612, height: 866)
    /// The sample sheet is 1,240 px wide: "QUARTERLY REPORT" in 84 pt type 160 px down, then "Revenue grew in the
    /// north." and "Costs held steady." in 56 pt type 340 and 450 px down, all 120 px in.
    private let scale: CGFloat = 612 / 1240

    private func makePDF(size: CGSize, _ draw: (CGRect) -> Void) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "scannedtext-\(UUID().uuidString).pdf")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        try UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: size)).writePDF(to: url) { context in
            context.beginPage()
            draw(context.pdfContextBounds)
        }
        return url
    }

    /// A reader that has read the scanned page, or a skip where text can't be recognised.
    private func readScan() async throws -> (reader: PDFTextReader, url: URL, all: TextSelection) {
        let sheet = DocumentScan.samples()[0]
        let url = try makePDF(size: size) { sheet.draw(in: $0) }
        let reader = PDFTextReader()
        let all = await reader.select(.everything, file: url, index: 0, pageSize: size)
        try XCTSkipIf(all == nil, "text recognition isn't available on this simulator")
        return (reader, url, try XCTUnwrap(all))
    }

    func testAScannedPageIsSelectedFromWhatWasReadOffIt() async throws {
        let (reader, url, all) = try await readScan()
        func select(_ request: PDFTextReader.Request) async -> TextSelection? {
            await reader.select(request, file: url, index: 0, pageSize: size)
        }
        XCTAssertEqual(all.lines.count, 3, "read as \(all.text)")
        XCTAssertEqual(all.text.components(separatedBy: "\n").count, 3, "a line of text for each line on the page")
        XCTAssertTrue(all.text.localizedCaseInsensitiveContains("quarterly report"))
        XCTAssertTrue(all.text.hasSuffix("Costs held steady."), "in reading order: \(all.text)")
        let page = CGRect(origin: .zero, size: size)
        XCTAssertTrue(all.lines.allSatisfy { page.contains($0) })

        let selected = await select(.range(from: CGPoint(x: 64, y: 187), to: CGPoint(x: 500, y: 187)))
        let one = try XCTUnwrap(selected)
        XCTAssertEqual(one.text, "Revenue grew in the north.")
        XCTAssertEqual(one.lines.count, 1)
        let line = try XCTUnwrap(one.lines.first)
        XCTAssertEqual(line.minX, 120 * scale, accuracy: 4, "where the line is printed, in page points")
        XCTAssertEqual(line.midY, 374 * scale, accuracy: 8)
        XCTAssertLessThan(line.height, 40)

        // From the "g" of "grew" to the last letter of "Costs", letter by letter.
        let across = await select(.range(from: CGPoint(x: 170, y: 190), to: CGPoint(x: 119, y: 240)))
        let span = try XCTUnwrap(across)
        XCTAssertEqual(span.text, "grew in the north.\nCosts")
        XCTAssertEqual(span.lines.count, 2)
        XCTAssertEqual(span.lines[0].maxX, line.maxX, accuracy: 0.5, "to the end of the first line")
        XCTAssertEqual(span.lines[1].minX, all.lines[2].minX, accuracy: 0.5, "from the start of the next")
        let backwards = await select(.range(from: CGPoint(x: 119, y: 240), to: CGPoint(x: 170, y: 190)))
        XCTAssertEqual(backwards, span, "dragged back up the page, it selects the same text")

        let below = await select(.range(from: CGPoint(x: 20, y: 240), to: CGPoint(x: 600, y: 800)))
        XCTAssertEqual(below?.text, "Costs held steady.", "from the margin beside the last line to the foot of the page")
    }

    func testATapSelectsAScannedWordAndNothingOffTheText() async throws {
        let (reader, url, _) = try await readScan()
        func word(_ x: CGFloat, _ y: CGFloat) async -> String? {
            await reader.select(.word(at: CGPoint(x: x, y: y)), file: url, index: 0, pageSize: size)?.text
        }
        let first = await word(80, 105)
        XCTAssertEqual(first, "QUARTERLY")
        let grew = await word(194, 187)
        XCTAssertEqual(grew, "grew")
        let north = await word(330, 187)
        XCTAssertEqual(north, "north", "the full stop after it isn't part of the word")
        let none = await word(400, 500)
        XCTAssertNil(none)
    }

    /// A stroke the way a hand draws a highlighter along a line: left to right, never quite level.
    private func wobble(from start: CGFloat, to end: CGFloat, y: CGFloat) -> [CGPoint] {
        stride(from: start, through: end, by: 6).map { CGPoint(x: $0, y: y + 2.5 * sin($0 / 15)) }
    }

    func testAHighlighterDrawnAlongAScannedLineIsGivenThatLine() async throws {
        let (reader, url, all) = try await readScan()
        func line(under points: [CGPoint]) async -> CGRect? {
            await reader.line(under: points, file: url, index: 0, pageSize: size)
        }
        let whole = all.lines[1]
        let along = await line(under: wobble(from: 40, to: 420, y: 189))
        let snapped = try XCTUnwrap(along)
        XCTAssertEqual(snapped.minY, whole.minY, accuracy: 0.5, "as tall as the line of text")
        XCTAssertEqual(snapped.height, whole.height, accuracy: 0.5)
        XCTAssertEqual(snapped.minX, whole.minX, accuracy: 1, "and no wider than its words, however far the stroke ran on")
        XCTAssertEqual(snapped.maxX, whole.maxX, accuracy: 1)

        let word = await reader.select(.word(at: CGPoint(x: 194, y: 187)), file: url, index: 0, pageSize: size)
        let grew = try XCTUnwrap(word?.lines.first)
        let over = await line(under: wobble(from: 160, to: 230, y: 188))
        let part = try XCTUnwrap(over)
        XCTAssertEqual(part.minX, grew.minX, accuracy: 1, "a stroke over one word takes that word")
        XCTAssertEqual(part.maxX, grew.maxX, accuracy: 1)

        let empty = await line(under: wobble(from: 60, to: 320, y: 500))
        XCTAssertNil(empty, "nothing is printed there")
        let down = await line(under: stride(from: CGFloat(170), through: 260, by: 6).map { CGPoint(x: 100, y: $0) })
        XCTAssertNil(down, "down the page")
    }

    func testAPrintedPageIsStillSelectedFromItsOwnText() async throws {
        let printed = "Photosynthesis turns light, water and carbon dioxide into sugar."
        let url = try makePDF(size: PageSize.letter.points) { _ in
            (printed as NSString).draw(at: CGPoint(x: 72, y: 72), withAttributes: [.font: UIFont.systemFont(ofSize: 14)])
        }
        let all = await PDFTextReader().select(.everything, file: url, index: 0, pageSize: PageSize.letter.points)
        XCTAssertEqual(all?.text, printed)
    }
}
