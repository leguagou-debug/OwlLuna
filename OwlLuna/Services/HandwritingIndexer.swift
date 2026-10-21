import UIKit
import PDFKit
import Vision
import PencilKit
import os

/// Recognises handwriting page by page, off the main thread. A page is only re-read when its saved ink hash
/// changes, and an edit cancels any recognition still running for that page.
actor HandwritingIndexer {
    static let shared = HandwritingIndexer()

    private var running: [UUID: (token: UUID, task: Task<Void, Never>)] = [:]
    private let signposter = OSSignposter(subsystem: "com.owais.OwlLuna", category: "ocr")

    struct Job: Sendable {
        let package: NotebookPackage
        let pages: [NotebookPage]
    }

    /// Queues recognition for pages whose text is missing or older than their ink. Returns the notebook's full text.
    /// A page already being read by another job is awaited rather than read twice.
    @discardableResult
    func index(_ job: Job) async -> String {
        let pdf = OpenPDF()
        for page in job.pages {
            guard !Task.isCancelled,
                  FileManager.default.fileExists(atPath: job.package.manifestURL.path(percentEncoded: false)) else { break }
            if let existing = running[page.id] { await existing.task.value }
            if await isCurrent(page, in: job.package) { continue }
            if let existing = running[page.id] {
                await existing.task.value
                if await isCurrent(page, in: job.package) { continue }
            }
            let token = UUID()
            let task = Task(priority: .utility) { await recognize(page, in: job.package, pdf: pdf) }
            running[page.id] = (token, task)
            await task.value
            if running[page.id]?.token == token { running[page.id] = nil }
        }
        return LibraryIndex.searchText(in: job.package.textDirectory)
    }

    func cancel(page: UUID) {
        running[page]?.task.cancel()
        running[page] = nil
    }

    private func isCurrent(_ page: NotebookPage, in package: NotebookPackage) async -> Bool {
        guard let text = await package.readText(page.id) else { return page.inkHash == nil && !page.hasPDFText && !page.hasPicture && page.typedText.isEmpty }
        return text.hasPrefix(Self.header(for: page))
    }

    /// Typed text joins the stamp only on pages that have some, so pages read before text boxes existed stay current.
    /// A scan or photo page is marked too, so one stamped before its picture was read is read again. So is a PDF page, for
    /// those that are pictures of pages.
    nonisolated static func header(for page: NotebookPage) -> String {
        stamp(for: page, mark: page.hasPicture ? "+img" : page.hasPDFText ? "+pdf" : "")
    }

    private nonisolated static func stamp(for page: NotebookPage, mark: String) -> String {
        let typed = page.typedText
        guard !typed.isEmpty else { return "#ink:\(page.inkHash ?? "none")\(mark)\n" }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in typed.utf8 { hash = (hash ^ UInt64(byte)) &* 0x0100_0000_01b3 }
        return "#ink:\(page.inkHash ?? "none")+\(String(hash, radix: 16))\(mark)\n"
    }

    /// Rendering and Vision run off the actor, so an edit's `cancel(page:)` gets through while they work.
    /// A PDF page with next to no text of its own is a picture of a page, and is read as a scan is.
    private nonisolated func recognize(_ page: NotebookPage, in package: NotebookPackage, pdf: OpenPDF) async {
        let interval = signposter.beginInterval("OCR page")
        defer { signposter.endInterval("OCR page", interval) }
        var chunks: [String] = []
        if page.hasPDFText, case .pdf(let file, let index) = page.background, let sheet = pdf.page(index, of: package.assetURL(file)) {
            let text = sheet.string
            if PDFText.isPicture(withText: text), let picture = PDFText.picture(of: sheet) {
                guard !Task.isCancelled, let lines = Self.recognizeText(in: picture) else { return }
                chunks += lines
            } else if let text {
                // Stamped before PDF pages were marked: that reading still holds, since the page has text of its own.
                let earlier = Self.stamp(for: page, mark: "")
                if let read = await package.readText(page.id), read.hasPrefix(earlier) {
                    guard !Task.isCancelled else { return }
                    try? await package.writeText(Self.header(for: page) + read.dropFirst(earlier.count), pageID: page.id)
                    return
                }
                chunks.append(text)
            }
        }
        if page.hasPicture, case .image(let file) = page.background, let picture = UIImage(contentsOfFile: package.assetURL(file).path(percentEncoded: false)) {
            guard !Task.isCancelled, let lines = Self.recognizeText(in: picture) else { return }
            chunks += lines
        }
        let typed = page.typedText
        if !typed.isEmpty { chunks.append(typed) }
        if page.inkHash != nil, case .ink(let drawing, _) = await package.readInk(page.id), !drawing.strokes.isEmpty {
            guard !Task.isCancelled else { return }
            let piece = Whiteboard.whole(page, ink: drawing)
            let image = PageRenderer.image(of: piece, ink: drawing, assets: package.assetsDirectory, width: Whiteboard.readingWidth(for: piece), includeBackground: false)
            guard !Task.isCancelled, let lines = Self.recognizeText(in: image) else { return }
            chunks += lines
        }
        guard !Task.isCancelled else { return }
        try? await package.writeText(Self.header(for: page) + chunks.joined(separator: "\n"), pageID: page.id)
    }

    /// Nil when Vision fails, so the page isn't stamped as read and is tried again next time.
    nonisolated static func recognizeText(in image: UIImage) -> [String]? {
        guard let cgImage = image.cgImage else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        do { try VNImageRequestHandler(cgImage: cgImage).perform([request]) } catch { return nil }
        return request.results?.compactMap { $0.topCandidates(1).first?.string } ?? []
    }
}

/// The PDF a job last read a page of, kept open for the pages after it. A job reads one page at a time.
private final class OpenPDF: @unchecked Sendable {
    private var file: URL?
    private var document: PDFDocument?

    func page(_ index: Int, of file: URL) -> PDFPage? {
        if file != self.file { (self.file, document) = (file, PDFDocument(url: file)) }
        return document?.page(at: index)
    }
}

extension NotebookPage {
    /// The user's own paper is left unread, as a template is: its printed words are on every page that uses it.
    var hasPDFText: Bool {
        if case .pdf = background, paperID == nil { return true }
        return false
    }

    /// A scanned sheet or a photo fills the page: its printed words are read for search.
    var hasPicture: Bool {
        if case .image = background, paperID == nil { return true }
        return false
    }
}
