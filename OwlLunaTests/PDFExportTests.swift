import XCTest
import PDFKit
import PencilKit
@testable import OwlLuna

/// Exporting a PDF: ink as shapes, the highlighter multiplied in, some of the pages, no paper, words that can be found, and text.
@MainActor
final class PDFExportTests: XCTestCase {
    private let paper = PageDefaults(template: .blank, paperColor: .white, pageSize: .letter)

    private func package(_ pages: [NotebookPage], ink: [UUID: PKDrawing] = [:]) async throws -> NotebookPackage {
        let root = temporaryRoot(self), id = UUID()
        let package = NotebookPackage(root: root, id: id)
        let manifest = NotebookManifest(id: id, title: "Export", defaults: paper, pages: pages)
        try await package.create(manifest)
        if !ink.isEmpty { _ = try await package.write(SaveSnapshot(manifest: manifest, ink: ink)) }
        return package
    }

    private func export(_ pages: [NotebookPage], ink: [UUID: PKDrawing] = [:], options: NotebookExporter.Options = .init()) async throws -> URL {
        let package = try await package(pages, ink: ink)
        return try await NotebookExporter.export(.init(title: "Export", pages: pages, inMemoryInk: [:], package: package), options: options) { _ in }
    }

    /// A line of loops that thickens and thins, like quick handwriting.
    private func scribble(_ ink: PKInk.InkType, color: UIColor = .black, origin: CGPoint, widths: ClosedRange<CGFloat>, azimuth: CGFloat = 0.6) -> PKStroke {
        let points = (0..<60).map { i -> PKStrokePoint in
            let t = Double(i) / 59, angle = t * 8 * .pi
            let width = widths.lowerBound + (widths.upperBound - widths.lowerBound) * CGFloat(0.5 + 0.5 * sin(t * 7))
            return PKStrokePoint(location: CGPoint(x: origin.x + CGFloat(t * 220 + cos(angle) * 9), y: origin.y + CGFloat(sin(angle) * 14 + sin(t * 5) * 6)),
                                 timeOffset: t, size: CGSize(width: width, height: width), opacity: 1, force: 1, azimuth: azimuth + CGFloat(t), altitude: 1)
        }
        return PKStroke(ink: PKInk(ink, color: color), path: PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: 1_790_000_000)))
    }

    /// Grey levels of something drawn on white in a top-left-origin context.
    private struct Gray {
        let width: Int, height: Int, scale: CGFloat
        var values: [UInt8]

        init(_ size: CGSize, scale: CGFloat, _ draw: (CGContext) -> Void) {
            let format = UIGraphicsImageRendererFormat()
            format.scale = scale
            format.opaque = true
            let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
                UIColor.white.setFill()
                context.fill(CGRect(origin: .zero, size: size))
                draw(context.cgContext)
            }.cgImage!
            (width, height, self.scale) = (image.width, image.height, scale)
            values = [UInt8](repeating: 0, count: width * height)
            let (w, h) = (width, height)
            values.withUnsafeMutableBytes { buffer in
                CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                          bitmapInfo: 0)!.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
        }

        init(pdf url: URL, page index: Int, scale: CGFloat = 2) throws {
            let page = try XCTUnwrap(CGPDFDocument(url as CFURL)?.page(at: index + 1))
            let size = page.getBoxRect(.mediaBox).size
            self.init(size, scale: scale) { PageRenderer.drawPDFPage(page, in: $0, size: size) }
        }

        func luminance(at point: CGPoint) -> CGFloat {
            CGFloat(values[Int(point.y * scale) * width + Int(point.x * scale)]) / 255
        }

        func darkest(in rect: CGRect) -> CGFloat {
            let rows = Int(rect.minY * scale)..<Int(rect.maxY * scale), columns = Int(rect.minX * scale)..<Int(rect.maxX * scale)
            return CGFloat(rows.flatMap { y in columns.map { values[y * width + $0] } }.min() ?? 255) / 255
        }

        /// The mean difference where either has ink, and the share of those pixels that differ by more than a quarter.
        func difference(to other: Gray) -> (mean: Double, bad: Double) {
            var inked = 0, sum = 0, bad = 0
            for i in 0..<min(values.count, other.values.count) where values[i] < 250 || other.values[i] < 250 {
                let d = abs(Int(values[i]) - Int(other.values[i]))
                inked += 1
                sum += d
                if d > 64 { bad += 1 }
            }
            return (Double(sum) / Double(max(inked, 1)), Double(bad) / Double(max(inked, 1)))
        }
    }

    func testPenFinelinerAndFountainPenAreDrawnAsShapesThatMatchPencilKit() {
        var moved = scribble(.pen, origin: .zero, widths: 3...6)
        moved.transform = CGAffineTransform(translationX: 40, y: 70).rotated(by: 0.25)
        let base = scribble(.pen, origin: CGPoint(x: 30, y: 60), widths: 3...6)
        let cases: [(String, PKStroke)] = [
            ("pen", scribble(.pen, origin: CGPoint(x: 30, y: 60), widths: 2.6...7)),
            ("thick pen", scribble(.pen, origin: CGPoint(x: 30, y: 60), widths: 8...16)),
            ("fineliner", scribble(.monoline, origin: CGPoint(x: 30, y: 60), widths: 3.5...3.5)),
            ("fountain pen", scribble(.fountainPen, origin: CGPoint(x: 30, y: 60), widths: 4...9)),
            ("see-through blue", scribble(.pen, color: UIColor(red: 0.1, green: 0.3, blue: 0.9, alpha: 0.5), origin: CGPoint(x: 30, y: 60), widths: 3...7)),
            ("moved and turned", moved),
            ("partly erased", PKStroke(ink: base.ink, path: base.path, transform: .identity, mask: UIBezierPath(rect: CGRect(x: 0, y: 0, width: 140, height: 120)))),
        ]
        let size = CGSize(width: 300, height: 120), rect = CGRect(origin: .zero, size: size)
        for (name, stroke) in cases {
            XCTAssertNotNil(InkVectors.nib(for: stroke), name)
            let drawing = PKDrawing(strokes: [stroke])
            var picture: UIImage?
            UITraitCollection(userInterfaceStyle: .light).performAsCurrent { picture = drawing.image(from: rect, scale: 3) }
            let pencilKit = Gray(size, scale: 3) { _ in picture?.draw(in: rect) }
            let shapes = Gray(size, scale: 3) { InkVectors.draw(drawing, from: rect, in: $0, size: size) }
            let difference = pencilKit.difference(to: shapes)
            XCTAssertLessThan(difference.mean, 12, name)
            XCTAssertLessThan(difference.bad, 0.03, "\(name): only the edges of the ink may differ")
        }
        XCTAssertNil(InkVectors.nib(for: scribble(.pencil, origin: .zero, widths: 3...5)), "pencil has a grain")
        XCTAssertNil(InkVectors.nib(for: scribble(.marker, origin: .zero, widths: 14...14)), "the highlighter has a soft edge")
        let faint = (0..<4).map { PKStrokePoint(location: CGPoint(x: CGFloat($0) * 10, y: 0), timeOffset: 0, size: CGSize(width: 4, height: 4), opacity: 0.5,
                                                 force: 1, azimuth: 0, altitude: 1) }
        XCTAssertNil(InkVectors.nib(for: PKStroke(ink: PKInk(.fountainPen, color: .black), path: PKStrokePath(controlPoints: faint, creationDate: .now))))
    }

    func testInkGoesInAsShapesAndLooksAsItDoesOnScreen() async throws {
        let page = paper.newPage()
        let strokes = (0..<12).map { scribble(.pen, origin: CGPoint(x: 60, y: 80 + CGFloat($0) * 50), widths: 2.8...4) }
        let drawing = PKDrawing(strokes: strokes)
        let url = try await export([page], ink: [page.id: drawing])
        let data = try Data(contentsOf: url)
        XCTAssertNil(data.range(of: Data("/Subtype /Image".utf8)), "no picture of the ink")
        let exported = try Gray(pdf: url, page: 0)
        let screen = Gray(page.size, scale: 2) { _ in
            PageRenderer.image(of: page, ink: drawing, assets: URL(filePath: NSTemporaryDirectory()), width: page.size.width, scale: 2)
                .draw(in: CGRect(origin: .zero, size: page.size))
        }
        XCTAssertLessThan(exported.difference(to: screen).bad, 0.04)
    }

    func testHighlighterIsMultipliedOverWhatIsUnderIt() async throws {
        let page = paper.newPage()
        let line = PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: (0..<10).map {
            PKStrokePoint(location: CGPoint(x: 100 + CGFloat($0) * 30, y: 200), timeOffset: Double($0), size: CGSize(width: 3.5, height: 3.5), opacity: 1, force: 1,
                          azimuth: 0, altitude: 1)
        }, creationDate: .now))
        let highlight = PKStroke(ink: PKInk(.marker, color: UIColor(red: 0.91, green: 0.69, blue: 0.14, alpha: 1)), path: PKStrokePath(controlPoints: (0..<10).map {
            PKStrokePoint(location: CGPoint(x: 120 + CGFloat($0) * 30, y: 200), timeOffset: Double($0), size: CGSize(width: 20, height: 20), opacity: 1, force: 1,
                          azimuth: .pi / 2, altitude: 1)
        }, creationDate: .now))
        let url = try await export([page], ink: [page.id: PKDrawing(strokes: [line, highlight])])
        let exported = try Gray(pdf: url, page: 0)
        XCTAssertLessThan(exported.luminance(at: CGPoint(x: 250, y: 200)), 0.25, "the line still shows through the highlighter")
        XCTAssertGreaterThan(exported.luminance(at: CGPoint(x: 250, y: 195)), 0.5, "beside it the highlighter is yellow, not dark")
        XCTAssertLessThan(exported.luminance(at: CGPoint(x: 250, y: 195)), 0.9)
    }

    func testHighlighterIsMultipliedOverInkAndPDFTextInThumbnailsAndImages() async throws {
        let root = temporaryRoot(self), id = UUID()
        let package = NotebookPackage(root: root, id: id)
        try await package.create(NotebookManifest(id: id, title: "Highlight", defaults: paper, pages: []))
        let size = PageSize.letter.points
        let printed = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: size)).pdfData { context in
            context.beginPage()
            ("Osmosis" as NSString).draw(at: CGPoint(x: 100, y: 280), withAttributes: [.font: UIFont.systemFont(ofSize: 48, weight: .black)])
        }
        let page = NotebookPage(background: .pdf(file: try await package.writeAsset(printed, ext: "pdf"), index: 0), paperColor: .white, size: size)
        let yellow = PKInk(.marker, color: UIColor(red: 0.91, green: 0.69, blue: 0.14, alpha: 1))
        let drawing = PKDrawing(strokes: [stroke(from: CGPoint(x: 100, y: 200), to: CGPoint(x: 400, y: 200), width: 5),
                                          PKStroke(ink: yellow, path: stroke(from: CGPoint(x: 120, y: 200), to: CGPoint(x: 380, y: 200), width: 30).path),
                                          PKStroke(ink: yellow, path: stroke(from: CGPoint(x: 90, y: 312), to: CGPoint(x: 330, y: 312), width: 30).path)])
        let input = NotebookExporter.Input(title: "Highlight", pages: [page], inMemoryInk: [page.id: drawing], package: package)
        let urls = try await NotebookExporter.exportImages(input) { _ in }
        let exported = try XCTUnwrap(urls.first)
        let pictures = [("thumbnail", PageThumbnailer.render(page: page, ink: drawing, assets: package.assetsDirectory)),
                        ("image", try XCTUnwrap(UIImage(contentsOfFile: exported.path(percentEncoded: false)))),
                        ("reader", PageRenderer.image(of: page, ink: drawing, assets: package.assetsDirectory, width: Whiteboard.readingWidth(for: page),
                                                      includeBackground: false))]
        for (name, picture) in pictures {
            let gray = Gray(size, scale: 2) { _ in picture.draw(in: CGRect(origin: .zero, size: size)) }
            XCTAssertLessThan(gray.darkest(in: CGRect(x: 240, y: 196, width: 20, height: 8)), 0.35, "\(name): the pen line shows through the highlighter")
            XCTAssertGreaterThan(gray.luminance(at: CGPoint(x: 320, y: 312)), 0.5, "\(name): over bare paper the highlighter is yellow, not dark")
            XCTAssertLessThan(gray.luminance(at: CGPoint(x: 320, y: 312)), 0.9, name)
            guard name != "reader" else { continue }
            XCTAssertLessThan(gray.darkest(in: CGRect(x: 110, y: 308, width: 190, height: 8)), 0.35, "\(name): so does the PDF's text")
        }

        let charcoal = NotebookPage.template(.blank, color: .charcoal, size: .letter)
        let dark = Gray(size, scale: 1) { _ in PageRenderer.image(of: charcoal, ink: drawing, assets: package.assetsDirectory, width: size.width).draw(at: .zero) }
        XCTAssertGreaterThan(dark.luminance(at: CGPoint(x: 320, y: 312)), 0.5, "on dark paper the highlighter isn't multiplied into it")
    }

    func testSomePagesGoOutWithTheNumbersTheyHaveInTheNotebook() async throws {
        var pages = (0..<4).map { _ in paper.newPage() }
        pages[2].bookmark = ""
        let package = try await package(pages)
        let input = NotebookExporter.Input(title: "Export", pages: pages, inMemoryInk: [:], package: package).narrowed(to: 1...2)
        XCTAssertEqual(input.pages.map(\.id), [pages[1].id, pages[2].id])
        let url = try await NotebookExporter.export(input) { _ in }
        let document = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertEqual(document.pageCount, 2)
        XCTAssertEqual(document.outlineRoot?.child(at: 0)?.label, "Page 3", "the bookmark keeps its page's number")
        XCTAssertEqual(input.narrowed(to: 0...3).pages.count, 4)
    }

    func testWithoutPaperThePageHasNoColourOrRulingAndInkIsDarkOnWhite() async throws {
        let grid = NotebookPage.template(.grid, color: .yellow, size: .letter)
        let chalk = NotebookPage.template(.blank, color: .chalkboard, size: .letter)
        let ink = PKDrawing(strokes: [stroke(from: CGPoint(x: 100, y: 300), to: CGPoint(x: 400, y: 300), width: 10)])
        var options = NotebookExporter.Options()
        let with = try await export([grid, chalk], ink: [chalk.id: ink], options: options)
        options.paper = false
        let without = try await export([grid, chalk], ink: [chalk.id: ink], options: options)
        let ruled = try Gray(pdf: with, page: 0), plain = try Gray(pdf: without, page: 0)
        let down = stride(from: 100, to: 700, by: 0.5).map { CGPoint(x: 301, y: CGFloat($0)) }
        let tones = down.map(ruled.luminance(at:))
        XCTAssertGreaterThan((tones.max() ?? 0) - (tones.min() ?? 0), 0.05, "the grid is drawn with paper")
        XCTAssertLessThan(tones.max() ?? 1, 0.97, "on yellow")
        XCTAssertGreaterThan(down.map(plain.luminance(at:)).min() ?? 0, 0.97, "without it the page is white")
        XCTAssertLessThan(try Gray(pdf: with, page: 1).luminance(at: CGPoint(x: 250, y: 500)), 0.3, "a chalkboard is dark with its paper")
        let bare = try Gray(pdf: without, page: 1)
        XCTAssertGreaterThan(bare.luminance(at: CGPoint(x: 250, y: 500)), 0.97)
        XCTAssertLessThan(bare.luminance(at: CGPoint(x: 250, y: 300)), 0.3, "and its chalk-white ink is dark without it")
    }

    func testHandwritingCanBeFoundAndSelectedInThePDF() async throws {
        let page = paper.newPage()
        let ink = PKDrawing(strokes: BlockLetters.strokes("HELLO", origin: CGPoint(x: 150, y: 160)))
        let url = try await export([page], ink: [page.id: ink])
        let document = try XCTUnwrap(PDFDocument(url: url))
        let found = document.findString("hello", withOptions: .caseInsensitive)
        try XCTSkipIf(found.isEmpty && (document.page(at: 0)?.string ?? "").isEmpty, "text recognition isn't available on this simulator")
        XCTAssertEqual(found.count, 1)
        let box = try XCTUnwrap(found.first?.bounds(for: try XCTUnwrap(document.page(at: 0))))
        let onPage = CGRect(x: box.minX, y: page.size.height - box.maxY, width: box.width, height: box.height)
        XCTAssertTrue(onPage.intersects(ink.bounds), "\(onPage) should lie over \(ink.bounds)")
        XCTAssertEqual(onPage.midY, ink.bounds.midY, accuracy: 20)
        XCTAssertEqual(onPage.midX, ink.bounds.midX, accuracy: 30)

        var options = NotebookExporter.Options()
        options.searchable = false
        let plainURL = try await export([page], ink: [page.id: ink], options: options)
        let plain = try XCTUnwrap(PDFDocument(url: plainURL))
        XCTAssertTrue(plain.findString("hello", withOptions: .caseInsensitive).isEmpty)
    }

    func testAScanIsSearchableAndSmallerFileShrinksIt() async throws {
        let root = temporaryRoot(self), id = UUID()
        let package = NotebookPackage(root: root, id: id)
        let size = CGSize(width: 2400, height: 3100)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let jpeg = UIGraphicsImageRenderer(size: size, format: format).jpegData(withCompressionQuality: 0.82) { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            var seed: UInt64 = 7
            for y in stride(from: 0, to: 3100, by: 6) {
                for x in stride(from: 0, to: 2400, by: 6) {
                    seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                    UIColor(white: 0.82 + CGFloat(seed >> 59) / 160, alpha: 1).setFill()
                    context.fill(CGRect(x: x, y: y, width: 6, height: 6))
                }
            }
            ("Mitochondria" as NSString).draw(at: CGPoint(x: 300, y: 600), withAttributes: [.font: UIFont.systemFont(ofSize: 160, weight: .bold)])
        }
        try await package.create(NotebookManifest(id: id, title: "Scan", defaults: paper, pages: []))
        let file = try await package.writeAsset(jpeg, ext: "jpg")
        let page = NotebookPage(background: .image(file: file), paperColor: .white, size: PageSize.letter.points)
        let input = NotebookExporter.Input(title: "Scan", pages: [page], inMemoryInk: [:], package: package)
        let sharp = try await NotebookExporter.export(input) { _ in }
        let document = try XCTUnwrap(PDFDocument(url: sharp))
        try XCTSkipIf((document.page(at: 0)?.string ?? "").isEmpty, "text recognition isn't available on this simulator")
        XCTAssertFalse(document.findString("mitochondria", withOptions: .caseInsensitive).isEmpty)
        let sharpSize = try XCTUnwrap(try sharp.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        try FileManager.default.removeItem(at: sharp.deletingLastPathComponent())
        var options = NotebookExporter.Options()
        options.quality = .smaller
        let small = try await NotebookExporter.export(input, options: options) { _ in }
        let smallSize = try XCTUnwrap(try small.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        XCTAssertLessThan(Double(smallSize), Double(sharpSize) * 0.6, "\(smallSize) against \(sharpSize)")
    }

    func testNotebookAsTextHasEachPagesWords() async throws {
        var pages = (0..<3).map { _ in paper.newPage() }
        pages[0].items = [PageItem(content: .text(TextBox(string: "Cell walls")), center: CGPoint(x: 200, y: 200), size: CGSize(width: 200, height: 40))]
        pages[2].items = [PageItem(content: .text(TextBox(string: "Osmosis")), center: CGPoint(x: 200, y: 200), size: CGSize(width: 200, height: 40))]
        pages[2].bookmark = "Water"
        let package = try await package(pages)
        let input = NotebookExporter.Input(title: "Biology", pages: pages, inMemoryInk: [:], package: package)
        let plainURL = try await NotebookExporter.exportText(input, markdown: false) { _ in }
        let plain = try String(contentsOf: plainURL, encoding: .utf8)
        XCTAssertEqual(plain, "Biology\n\nPage 1\n\nCell walls\n\nWater\n\nOsmosis\n", "a page with no words is left out")
        let markdownURL = try await NotebookExporter.exportText(input.narrowed(to: 2...2), markdown: true) { _ in }
        XCTAssertEqual(markdownURL.pathExtension, "md")
        XCTAssertEqual(try String(contentsOf: markdownURL, encoding: .utf8), "# Biology\n\n## Water\n\nOsmosis\n")
    }

    func testAnExportThatAsksWaitsAndTakesTheChosenPages() async throws {
        let pages = (0..<3).map { _ in paper.newPage() }
        let package = try await package(pages)
        let job = ExportJob(inputs: [.init(title: "Export", pages: pages, inMemoryInk: [:], package: package)], choosing: true, current: 2, thisPage: true)
        XCTAssertEqual(job.state, .choosing)
        XCTAssertEqual(job.range, 2...2)
        XCTAssertTrue(job.choosesPages)
        job.range = 0...1
        job.options.paper = false
        job.start()
        let deadline = Date().addingTimeInterval(20)
        while job.state == .running, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        guard case .finished(let urls) = job.state, let url = urls.first else { return XCTFail("export ended as \(job.state)") }
        XCTAssertEqual(PDFDocument(url: url)?.pageCount, 2)
        job.close()
    }
}
