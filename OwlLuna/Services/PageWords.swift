import UIKit
import PencilKit
import CoreText

/// The words read from a page's handwriting, from the photo or scan it is, and from pictures placed on it, where they lie
/// on it: a PDF carries them as text no one sees, which a reader can still find and select.
enum PageWords {
    struct Word: Sendable, Equatable {
        var text: String
        /// The foot of the word, from where it starts to where it ends, in page points.
        var start: CGPoint
        var end: CGPoint
        var height: CGFloat
    }

    /// Read as find reads them, the whole page at once and each placed picture on its own. A page whose saved words are still
    /// its own and say it has none isn't read.
    static func read(_ page: NotebookPage, ink: PKDrawing, package: NotebookPackage, unsaved: Bool) -> [Word] {
        var picture: URL?
        if case .image(let file) = page.background { picture = package.assetURL(file) }
        let placed = page.placedPictures
        guard !ink.strokes.isEmpty || picture != nil || !placed.isEmpty else { return [] }
        if !unsaved, let saved = try? String(contentsOf: package.textURL(page.id), encoding: .utf8), saved.hasPrefix(HandwritingIndexer.header(for: page)),
           StudyGuide.body(ofPageText: saved).allSatisfy(\.isWhitespace) { return [] }
        var words: [Word] = []
        if let picture, let image = UIImage(contentsOfFile: picture.path(percentEncoded: false)), let lines = NotebookFind.read(image) {
            words += self.words(in: lines, size: page.size)
        }
        words += self.words(onPictures: placed, of: page, package: package)
        if !ink.strokes.isEmpty {
            let image = PageRenderer.image(of: page, ink: ink, assets: package.assetsDirectory, width: Whiteboard.readingWidth(for: page), includeBackground: false)
            words += self.words(in: NotebookFind.read(image) ?? [], size: page.size)
        }
        return words
    }

    /// Each placed picture is read as it shows, cropped, once for each file and crop, and its words are taken through its
    /// size, turn and centre to where they lie. One whose kept reading found nothing isn't read again.
    private static func words(onPictures items: [PageItem], of page: NotebookPage, package: NotebookPackage) -> [Word] {
        guard !items.isEmpty else { return [] }
        let kept = (try? Data(contentsOf: package.pictureTextURL(page.id))).flatMap { try? JSONDecoder().decode([String: [String]].self, from: $0) } ?? [:]
        var read: [String: [RecognizedLine]] = [:], words: [Word] = []
        for item in items {
            guard let file = item.assetFile, let key = item.readingKey, kept[key] != [] else { continue }
            if read[key] == nil {
                read[key] = PageItemRenderer.image(file, assets: package.assetsDirectory, crop: item.crop, cached: false)
                    .flatMap { NotebookFind.read(UIImage(cgImage: $0)) } ?? []
            }
            let place = item.placement
            words += self.words(in: read[key] ?? [], size: item.size).map {
                Word(text: $0.text, start: $0.start.applying(place), end: $0.end.applying(place), height: $0.height)
            }
        }
        return words
    }

    /// The image read filled `size`, the page's or a placed picture's, so each box is a fraction of it, measured from the bottom.
    static func words(in lines: [RecognizedLine], size: CGSize) -> [Word] {
        var words: [Word] = []
        for line in lines {
            let string = line.text.string
            var ranges: [Range<String.Index>] = [], index = string.startIndex
            while let start = string[index...].firstIndex(where: { !$0.isWhitespace }) {
                let end = string[start...].firstIndex(where: \.isWhitespace) ?? string.endIndex
                ranges.append(start..<end)
                index = end
            }
            func onPage(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x * size.width, y: (1 - point.y) * size.height) }
            for (number, range) in ranges.enumerated() {
                guard let box = try? line.text.boundingBox(for: range) else { continue }
                let start = onPage(box.bottomLeft), end = onPage(box.bottomRight), top = onPage(box.topLeft)
                words.append(Word(text: String(string[range]) + (number < ranges.count - 1 ? " " : ""), start: start, end: end,
                                  height: hypot(top.x - start.x, top.y - start.y)))
            }
        }
        return words
    }

    /// Each word is set as tall as the writing, stretched to its length along its slope, and never painted.
    static func draw(_ words: [Word], in ctx: CGContext) {
        guard !words.isEmpty else { return }
        let unit = CTFontCreateWithName("Helvetica" as CFString, 1, nil)
        let reach = CTFontGetAscent(unit) + CTFontGetDescent(unit)
        ctx.saveGState()
        ctx.setTextDrawingMode(.invisible)
        for word in words {
            let length = hypot(word.end.x - word.start.x, word.end.y - word.start.y)
            guard length > 0.5, word.height > 0.5 else { continue }
            let font = CTFontCreateWithName("Helvetica" as CFString, word.height / reach, nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: word.text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]))
            let bare = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil) - CTLineGetTrailingWhitespaceWidth(line))
            guard bare > 0 else { continue }
            ctx.saveGState()
            ctx.translateBy(x: word.start.x, y: word.start.y)
            ctx.rotate(by: atan2(word.end.y - word.start.y, word.end.x - word.start.x))
            ctx.scaleBy(x: length / bare, y: -1)
            ctx.textMatrix = .identity
            ctx.textPosition = CGPoint(x: 0, y: CTFontGetDescent(font))
            CTLineDraw(line, ctx)
            ctx.restoreGState()
        }
        ctx.restoreGState()
    }
}
