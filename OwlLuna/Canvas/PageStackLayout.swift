import UIKit

/// Page frames in page points, stacked vertically and centred on the widest page. A whiteboard has no size to
/// stack: among the pages it is a card, and once opened it is laid out alone, with every other page put away.
struct PageStackLayout {
    static let margin: CGFloat = 16

    private(set) var frames: [CGRect] = []
    private(set) var size = CGSize(width: 1, height: 1)
    /// The whiteboard that is open, in place of the stack.
    let solo: Int?

    init(pages: [NotebookPage] = [], solo: Int? = nil) {
        self.solo = solo.flatMap { pages.indices.contains($0) && pages[$0].isBoard ? $0 : nil }
        if let solo = self.solo {
            frames = pages.indices.map { $0 == solo ? CGRect(origin: .zero, size: Whiteboard.size) : .zero }
            size = Whiteboard.size
            return
        }
        let sheet = Self.sheetWidth(pages)
        let width = sheet + Self.margin * 2
        var y = Self.margin
        frames = pages.map { page in
            let size = page.isBoard ? CGSize(width: sheet, height: (sheet * Whiteboard.shownSize.height / Whiteboard.shownSize.width).rounded()) : page.size
            defer { y += size.height + Self.margin }
            return CGRect(x: ((width - size.width) / 2).rounded(), y: y, width: size.width, height: size.height)
        }
        size = CGSize(width: width, height: max(y, 1))
    }

    /// The widest page that has a width; a whiteboard counts as a Letter page when there is none.
    static func sheetWidth(_ pages: [NotebookPage]) -> CGFloat {
        pages.lazy.filter { !$0.isBoard }.map(\.size.width).max() ?? Whiteboard.sheet.width
    }

    /// Whether the page is on show at its own size: the open whiteboard, or any page but a whiteboard in the stack.
    func isLaidOut(_ index: Int, in pages: [NotebookPage]) -> Bool {
        guard pages.indices.contains(index), frames.indices.contains(index) else { return false }
        return solo.map { $0 == index } ?? !pages[index].isBoard
    }

    /// The page at `y`, counting the gap below a page as part of it.
    func pageIndex(atY y: CGFloat) -> Int {
        if let solo { return solo }
        guard !frames.isEmpty else { return 0 }
        var low = 0, high = frames.count - 1
        while low < high {
            let mid = (low + high) / 2
            if frames[mid].maxY + Self.margin / 2 < y { low = mid + 1 } else { high = mid }
        }
        return low
    }

    func range(from top: CGFloat, to bottom: CGFloat) -> ClosedRange<Int>? {
        if let solo { return solo...solo }
        guard !frames.isEmpty else { return nil }
        let first = pageIndex(atY: top)
        var last = first
        while last + 1 < frames.count, frames[last + 1].minY <= bottom { last += 1 }
        return first...last
    }
}

extension CGRect {
    /// The rectangle with its origin and size multiplied by `scale`.
    func scaled(by scale: CGFloat) -> CGRect {
        CGRect(x: minX * scale, y: minY * scale, width: width * scale, height: height * scale)
    }
}
