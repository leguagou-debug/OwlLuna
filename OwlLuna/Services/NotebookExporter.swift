import UIKit
import SwiftUI
import PencilKit
import AVFoundation
import os

/// Writes a notebook as a PDF: vector backgrounds (templates, the original PDF pages, photos) with the ink
/// on top, clipped to each page. Runs off the main thread and reports progress; cancellable between pages.
enum NotebookExporter {
    private static let signposter = OSSignposter(subsystem: "com.owais.OwlLuna", category: "export")

    /// How a PDF is made: with the paper or without, how finely what can't be drawn as shapes goes in, and whether the words
    /// read from handwriting and pictures lie under them as text. A text export is plain or Markdown.
    struct Options: Sendable, Equatable {
        enum Quality: Sendable, Equatable { case smaller, sharper }

        var paper = true
        var quality = Quality.sharper
        var searchable = true
        var markdown = false

        /// Pixels a point for the inks with a grain and the highlighter.
        var inkScale: CGFloat { quality == .sharper ? 3 : 1.5 }
        /// Photos and scans go in no finer than this, or as they are.
        var pictureLimit: CGFloat? { quality == .sharper ? nil : 1.5 }
    }

    struct Input: Sendable {
        var title: String
        var pages: [NotebookPage]
        var inMemoryInk: [UUID: PKDrawing]
        var package: NotebookPackage
        var recordings: [RecordingEntry] = []
        /// The whole notebook when `pages` is some of it, so links and bookmarks keep the numbers their pages have in it.
        var notebook: [NotebookPage]?

        var allPages: [NotebookPage] { notebook ?? pages }
        var numbers: [UUID: Int] { Dictionary(allPages.enumerated().map { ($1.id, $0 + 1) }, uniquingKeysWith: { first, _ in first }) }
    }

    /// The open document, with its unsaved ink, if the notebook is being edited, otherwise its saved pages.
    @MainActor
    static func input(for id: UUID, root: StorageRoot) async throws -> Input {
        if let document = DocumentRegistry.shared.document(for: id) { return Input(document: document) }
        let package = NotebookPackage(root: root, id: id)
        let manifest = try await package.readManifest().manifest
        return Input(title: manifest.title, pages: manifest.pages, inMemoryInk: [:], package: package, recordings: manifest.recordings)
    }

    /// Streams pages to disk one at a time: each page's ink is read, drawn and released before the next,
    /// so memory stays flat however long the notebook is.
    static func export(_ input: Input, options: Options = Options(), progress: @escaping @Sendable (Double) async -> Void) async throws -> URL {
        let interval = signposter.beginInterval("Export", "\(input.pages.count) pages")
        defer { signposter.endInterval("Export", interval) }
        let directory = try ExportFolder.make(.export)
        var written = false
        defer { if !written { try? FileManager.default.removeItem(at: directory) } }
        let url = directory.appending(path: fileName(input.title, extension: "pdf"))
        try Task.checkCancellation()

        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [kCGPDFContextTitle as String: input.title, kCGPDFContextCreator as String: "OwlLuna"]
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: input.pages.first?.shownSize ?? PageSize.letter.points), format: format)
        let assets = input.package.assetsDirectory
        let count = Double(max(input.pages.count, 1))
        let outline = outline(for: input.pages, numbers: input.numbers)
        let links = LinkTitles(pages: input.allPages)
        let linked = linkedPages(in: input.pages)
        try PageRenderer.$pictureLimit.withValue(options.pictureLimit) {
            try renderer.writePDF(to: url) { context in
                if let outline { CGPDFContextSetOutline(context.cgContext, outline as CFDictionary) }
                for (index, page) in input.pages.enumerated() {
                    if Task.isCancelled { return }
                    autoreleasepool {
                        let unsaved = input.inMemoryInk[page.id]
                        let ink = unsaved ?? savedInk(page, in: input.package)
                        // A whiteboard goes out as one sheet, as large as what is on it.
                        let page = Whiteboard.whole(page, ink: ink)
                        let bounds = CGRect(origin: .zero, size: page.size)
                        context.beginPage(withBounds: bounds, pageInfo: [:])
                        PageRenderer.drawBackground(page, assets: assets, in: context.cgContext, size: page.size, links: links, paper: options.paper)
                        // Destinations are placed in the PDF's own space, which runs up the page.
                        if linked.contains(page.id) { context.addDestination(withName: page.id.uuidString, at: CGPoint(x: 0, y: page.size.height)) }
                        if page.hasItems {
                            for item in page.items {
                                guard let link = item.link else { continue }
                                let box = item.boundingBox
                                let area = CGRect(x: box.minX, y: page.size.height - box.maxY, width: box.width, height: box.height)
                                if let target = link.target {
                                    if linked.contains(target) { context.setDestinationWithName(target.uuidString, for: area) }
                                } else if let url = link.externalURL {
                                    context.setURL(url, for: area)
                                }
                            }
                        }
                        if options.searchable {
                            PageWords.draw(PageWords.read(page, ink: ink, package: input.package, unsaved: unsaved != nil), in: context.cgContext)
                        }
                        if !ink.strokes.isEmpty {
                            InkVectors.draw(ink, from: page.inkRect, in: context.cgContext, size: page.size, style: inkStyle(for: page, options: options))
                        }
                        PageRenderer.drawOverInk(page, assets: assets, in: context.cgContext, size: page.size)
                    }
                    let fraction = Double(index + 1) / count
                    Task { await progress(fraction) }
                }
            }
        }
        try Task.checkCancellation()
        written = true
        await progress(1)
        return url
    }

    /// Ink is drawn as it is on its paper; without the paper, as on white.
    static func inkStyle(for page: NotebookPage, options: Options) -> InkVectors.Style {
        let dark = options.paper && page.effectivePaperColor.isDark
        return InkVectors.Style(appearance: options.paper ? page.effectivePaperColor.inkAppearance : .light, multipliesHighlighter: !dark,
                                pictureScale: options.inkScale)
    }

    /// Under the file system's 255 bytes for a name, with room for the " 2" a copy saved beside it is given.
    static let nameLimit = 240

    /// The title as a file name ending in `number` and `extension`, cut at a whole character to fit `nameLimit`,
    /// counted decomposed as some file systems store it.
    static func fileName(_ title: String, number: String = "", extension ext: String) -> String {
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined(separator: "-")
        let tail = "\(number).\(ext)", room = nameLimit - bytes(tail)
        var name = "", used = 0
        for character in cleaned {
            let size = bytes(String(character))
            guard used + size <= room else { break }
            name.append(character)
            used += size
        }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return (name.isEmpty ? String(localized: "Untitled") : name) + tail
    }

    private static func bytes(_ text: String) -> Int { text.decomposedStringWithCanonicalMapping.utf8.count }

    /// Writes each page as a PNG, twice the page's size in points, numbered in page order.
    static func exportImages(_ input: Input, options: Options = Options(), progress: @escaping @Sendable (Double) async -> Void) async throws -> [URL] {
        let interval = signposter.beginInterval("Export", "\(input.pages.count) images")
        defer { signposter.endInterval("Export", interval) }
        let directory = try ExportFolder.make(.export)
        var written = false
        defer { if !written { try? FileManager.default.removeItem(at: directory) } }
        let assets = input.package.assetsDirectory, links = LinkTitles(pages: input.allPages)
        let digits = String(input.pages.count).count, count = Double(max(input.pages.count, 1))
        var urls: [URL] = []
        for (index, page) in input.pages.enumerated() {
            try Task.checkCancellation()
            let number = input.pages.count == 1 ? "" : " " + String(repeating: "0", count: digits - String(index + 1).count) + String(index + 1)
            let url = directory.appending(path: fileName(input.title, number: number, extension: "png"))
            let ink = input.inMemoryInk[page.id] ?? savedInk(page, in: input.package)
            let data = autoreleasepool {
                let page = Whiteboard.whole(page, ink: ink)
                return PageRenderer.image(of: page, ink: ink, assets: assets, width: page.size.width, scale: Whiteboard.scale(for: page.size, wanted: 2), links: links,
                                          paper: options.paper).pngData()
            }
            guard let data else { throw ImportError.unreadable }
            try data.write(to: url, options: .atomic)
            urls.append(url)
            await progress(Double(index + 1) / count)
        }
        written = true
        return urls
    }

    /// The words of each page, read first where they haven't been yet: plain text, or Markdown with a heading for the notebook
    /// and one for each page that has words.
    static func exportText(_ input: Input, markdown: Bool, progress: @escaping @Sendable (Double) async -> Void) async throws -> URL {
        let directory = try ExportFolder.make(.export)
        var written = false
        defer { if !written { try? FileManager.default.removeItem(at: directory) } }
        let url = directory.appending(path: fileName(input.title, extension: markdown ? "md" : "txt"))
        let numbers = input.numbers, count = Double(max(input.pages.count, 1))
        var parts = [markdown ? "# " + input.title : input.title]
        for (index, page) in input.pages.enumerated() {
            try Task.checkCancellation()
            await HandwritingIndexer.shared.index(HandwritingIndexer.Job(package: input.package, pages: [page]))
            let words = StudyGuide.body(ofPageText: await input.package.readText(page.id) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !words.isEmpty { parts.append((markdown ? "## " : "") + page.bookmarkTitle(number: numbers[page.id] ?? index + 1) + "\n\n" + words) }
            await progress(Double(index + 1) / count)
        }
        try Task.checkCancellation()
        try Data((parts.joined(separator: "\n\n") + "\n").utf8).write(to: url, options: .atomic)
        written = true
        return url
    }

    /// The pages that links on other pages open, so those links still work in the exported PDF.
    static func linkedPages(in pages: [NotebookPage]) -> Set<UUID> {
        let ids = Set(pages.map(\.id))
        var linked = Set<UUID>()
        for page in pages where page.hasItems {
            for item in page.items { if let target = item.link?.target, ids.contains(target) { linked.insert(target) } }
        }
        return linked
    }

    /// Bookmarks become the PDF's outline, so they show in any reader's sidebar.
    static func outline(for pages: [NotebookPage], numbers: [UUID: Int] = [:]) -> [String: Any]? {
        let children: [[String: Any]] = pages.enumerated().compactMap { index, page in
            guard page.bookmark != nil else { return nil }
            return [kCGPDFOutlineTitle as String: page.bookmarkTitle(number: numbers[page.id] ?? index + 1), kCGPDFOutlineDestination as String: index + 1]
        }
        return children.isEmpty ? nil : [kCGPDFOutlineChildren as String: children]
    }

    /// Reads a page's saved ink directly: writes are atomic, so reading outside the package actor is safe.
    /// A file that can't be decoded exports as a blank page; the editor sets it aside when the page is opened.
    static func savedInk(_ page: NotebookPage, in package: NotebookPackage) -> PKDrawing {
        guard let data = try? Data(contentsOf: package.inkURL(page.id)) else { return PKDrawing() }
        return (try? NotebookPackage.decodeInk(data)) ?? PKDrawing()
    }
}

@MainActor
@Observable
final class ExportJob: Identifiable {
    enum State: Equatable { case choosing, running, finished([URL]), failed(String), cancelled }
    /// One PDF, a PNG for every page, a film of one page being written, or the words as text.
    enum Format: Sendable { case pdf, images, timelapse, text }
    /// The PDF zipped with the notebook's recordings, once that has been asked for.
    enum Bundle: Equatable { case making, made(URL), failed(String) }

    let id = UUID()
    let format: Format
    /// The first page's width over its height, for showing a film of it.
    let shape: CGFloat
    /// Locked notebooks left out of an export of several, because nobody unlocked them.
    let skipped: Int
    private(set) var progress: Double = 0
    private(set) var state: State
    var options = NotebookExporter.Options()
    /// The pages chosen, by their place in the notebook. Only an export of one notebook chooses.
    var range: ClosedRange<Int>
    /// The page open in the editor when the export was asked for.
    let currentPage: Int?
    /// It asked what to export before it started.
    let asks: Bool
    /// The recordings that can go with a single notebook's PDF; none for any other export.
    let recordingCount: Int
    private(set) var includesRecordings = false
    private(set) var bundle: Bundle?
    @ObservationIgnored private var inputs: [NotebookExporter.Input]
    @ObservationIgnored private let refresh: (@MainActor () async -> NotebookExporter.Input?)?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var withRecordings: NotebookExporter.Input?
    @ObservationIgnored private var bundling: Task<Void, Never>?

    /// `pages` narrows the export to some of the notebook's pages. `choosing` asks first which of them: all, or with `thisPage`
    /// the page `current`, which it can always come back to.
    convenience init(document: NotebookDocument, format: Format = .pdf, pages: [NotebookPage]? = nil, choosing: Bool = false, current: Int? = nil,
                     thisPage: Bool = false) {
        let input = NotebookExporter.Input(document: document, pages: pages)
        let ids = Set(input.pages.map(\.id))
        // Words are read from what is saved, so the text waits for the editor's ink to be written.
        var refresh: (@MainActor () async -> NotebookExporter.Input?)?
        if format == .text {
            refresh = { [weak document] () async -> NotebookExporter.Input? in
                guard let document else { return nil }
                _ = await document.flush()
                let kept: [NotebookPage]? = pages == nil ? nil : document.pages.filter { ids.contains($0.id) }
                return NotebookExporter.Input(document: document, pages: kept)
            }
        }
        self.init(inputs: [input], format: format, choosing: choosing, current: current, thisPage: thisPage, refresh: refresh)
    }

    /// Exports from the library: the open document, with its unsaved ink, if the notebook is being edited, otherwise the saved pages.
    static func forNotebook(_ id: UUID, root: StorageRoot, format: Format = .pdf, choosing: Bool = false) async throws -> ExportJob {
        if format == .text, let document = DocumentRegistry.shared.document(for: id) { _ = await document.flush() }
        return ExportJob(inputs: [try await NotebookExporter.input(for: id, root: root)], format: format, choosing: choosing)
    }

    /// A PDF of each notebook. Locked ones go in once whoever is holding the iPad has shown it is theirs, asked once
    /// for all of them; otherwise they are left out, and the sheet says so.
    static func pdfs(of records: [NotebookRecord], root: StorageRoot, choosing: Bool = false) async throws -> ExportJob {
        let locked = records.filter(\.isLocked)
        var ids = records.map(\.id)
        if !locked.isEmpty {
            let lock = NotebookLock.shared
            let reason = locked.count == 1 ? String(localized: "Export “\(locked[0].title)”") : String(localized: "Export \(locked.count) locked notebooks")
            let unlocked = lock.isAvailable ? await lock.confirm(reason) : false
            if !unlocked { ids = records.filter { !$0.isLocked }.map(\.id) }
        }
        var inputs: [NotebookExporter.Input] = []
        for id in ids { inputs.append(try await NotebookExporter.input(for: id, root: root)) }
        return ExportJob(inputs: inputs, skipped: records.count - ids.count, choosing: choosing)
    }

    convenience init(input: NotebookExporter.Input, format: Format = .pdf) {
        self.init(inputs: [input], format: format)
    }

    /// Each notebook is written in turn into a folder of its own. Unless `choosing`, it starts at once.
    init(inputs: [NotebookExporter.Input], format: Format = .pdf, skipped: Int = 0, choosing: Bool = false, current: Int? = nil, thisPage: Bool = false,
         refresh: (@MainActor () async -> NotebookExporter.Input?)? = nil) {
        self.format = format
        self.skipped = skipped
        self.inputs = inputs
        self.refresh = refresh
        let count = inputs.count == 1 ? inputs[0].allPages.count : 0
        currentPage = current.map { min(max($0, 0), max(count - 1, 0)) }
        range = thisPage ? currentPage.map { $0...$0 } ?? 0...0 : 0...max(count - 1, 0)
        state = choosing ? .choosing : .running
        asks = choosing
        recordingCount = format == .pdf && inputs.count == 1 && skipped == 0 ? inputs[0].recordings.count : 0
        shape = inputs.first?.pages.first.map { $0.size.width / max($0.size.height, 1) } ?? 0.77
        if !choosing { run() }
    }

    var isSeveral: Bool { inputs.count + skipped > 1 }

    /// The notebook's pages, when one notebook is being exported.
    var pages: [NotebookPage] { inputs.count == 1 ? inputs[0].allPages : [] }
    var package: NotebookPackage? { inputs.count == 1 ? inputs[0].package : nil }
    var choosesPages: Bool { inputs.count == 1 && pages.count > 1 }

    /// Goes ahead with what was chosen.
    func start() {
        guard state == .choosing else { return }
        if choosesPages { inputs = [inputs[0].narrowed(to: range)] }
        state = .running
        run()
    }

    private func run() {
        let format = format, options = options, refresh = refresh, range = range, narrows = choosesPages, prepared = inputs
        let count = Double(max(prepared.count, 1))
        if recordingCount > 0, let input = prepared.first, input.pages.count == input.allPages.count { withRecordings = input }
        task = Task { [weak self] in
            var inputs = prepared
            if let refresh, let fresh = await refresh() { inputs = [narrows ? fresh.narrowed(to: range) : fresh] }
            let chosen = inputs
            let report: @Sendable (Int, Double) async -> Void = { index, value in
                await MainActor.run { self?.progress = max(self?.progress ?? 0, (Double(index) + value) / count) }
            }
            let work = Task.detached(priority: .userInitiated) { () throws -> [URL] in
                var urls: [URL] = []
                do {
                    for (index, input) in chosen.enumerated() {
                        let progress: @Sendable (Double) async -> Void = { await report(index, $0) }
                        switch format {
                        case .pdf: urls.append(try await NotebookExporter.export(input, options: options, progress: progress))
                        case .images: urls += try await NotebookExporter.exportImages(input, options: options, progress: progress)
                        case .timelapse: urls.append(try await InkTimelapse.export(input, progress: progress))
                        case .text: urls.append(try await NotebookExporter.exportText(input, markdown: options.markdown, progress: progress))
                        }
                    }
                } catch {
                    let written = urls
                    await MainActor.run { ExportFolder.discard(written) }
                    throw error
                }
                return urls
            }
            do {
                let urls = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                if let self, state == .running { state = .finished(urls) } else { ExportFolder.discard(urls) }
            } catch is CancellationError {
                self?.state = .cancelled
            } catch {
                self?.state = .failed(error.localizedDescription)
            }
        }
    }

    /// What Share hands over: the PDF, or the zip that holds it with the recordings once they are included.
    var shared: [URL] {
        guard case .finished(let urls) = state else { return [] }
        if includesRecordings { if case .made(let zip) = bundle { return [zip] } else { return [] } }
        return urls
    }

    /// The recordings go with a PDF of the whole notebook.
    var offersRecordings: Bool { withRecordings != nil }

    /// Off until asked for each time: recordings of people talking only leave with the notes when someone means them to.
    func includeRecordings(_ include: Bool) {
        includesRecordings = include
        guard include, bundling == nil, case .finished(let urls) = state, let pdf = urls.first, let input = withRecordings else { return }
        bundle = .making
        bundling = Task { [weak self] in
            let work = Task.detached(priority: .userInitiated) { try NotebookExporter.bundle(pdf, with: input) }
            do {
                let zip = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                self?.bundle = .made(zip)
            } catch is CancellationError {
                self?.bundle = nil
            } catch {
                self?.bundle = .failed(error.localizedDescription)
                self?.bundling = nil
            }
        }
    }

    func cancel() {
        task?.cancel()
        state = .cancelled
    }

    /// Its sheet has closed: a running export stops, and the files go once nothing is sharing or printing them.
    func close() {
        if state == .running || state == .choosing { cancel() }
        bundling?.cancel()
        if case .finished(let urls) = state { ExportFolder.discard(urls) }
    }
}

struct ExportSheet: View {
    let job: ExportJob
    @Environment(\.dismiss) private var dismiss
    @State private var sharing = false

    var body: some View {
        NavigationStack {
            Group {
                if job.state == .choosing {
                    ExportChoices(job: job) { dismiss() }
                } else {
                    progressAndResult
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.surface)
            .navigationTitle(title)
            .barGround(.surface)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if job.state != .choosing {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }.buttonStyle(.owlLuna(.secondary, inBar: true))
                    }
                    .boardBackground()
                }
            }
        }
        .presentationDetents(job.asks || job.format == .timelapse ? [.large] : [.medium])
        .presentationBackground(Color.surface)
        .onDisappear { job.close() }
    }

    private var title: Text {
        switch job.format {
        case .pdf: job.isSeveral ? Text("Export PDFs") : Text("Export PDF")
        case .images: Text("Export Images")
        case .timelapse: Text("Export Video")
        case .text: Text("Export Text")
        }
    }

    private var progressAndResult: some View {
        VStack(spacing: Space.x5) {
            switch job.state {
            case .choosing:
                EmptyView()
            case .running:
                ProgressView(value: job.progress) { Text("Exporting…") } currentValueLabel: {
                    Text(job.progress, format: .percent.precision(.fractionLength(0)))
                }
                Button("Cancel", role: .cancel) { job.cancel(); dismiss() }
                    .buttonStyle(.owlLuna)
            case .finished(let urls):
                if job.format == .timelapse, let url = urls.first {
                    LoopingVideo(url: url)
                        .aspectRatio(job.shape, contentMode: .fit)
                        .frame(maxHeight: 420)
                        .overlay { Rectangle().strokeBorder(Color.hairline, lineWidth: 1) }
                        .accessibilityElement()
                        .accessibilityLabel(Text("The page being written, playing over and over"))
                        .accessibilityAddTraits(.isImage)
                        .accessibilityIdentifier("export.preview")
                }
                if !urls.isEmpty {
                    Label(readyText(urls.count), systemImage: "checkmark.circle").font(.headline)
                        .accessibilityIdentifier("export.ready")
                    if job.offersRecordings { recordingsToggle }
                    HStack(spacing: Space.x3) {
                        Button { sharing = true } label: { Label("Share", systemImage: "square.and.arrow.up") }
                            .prominentButton()
                            .disabled(job.shared.isEmpty)
                            .accessibilityIdentifier("export.share")
                        if job.format == .pdf || job.format == .images {
                            Button { print(urls) } label: { Label(String(localized: "export.print", defaultValue: "Print"), systemImage: "printer") }
                                .buttonStyle(.owlLuna)
                        }
                    }
                    .sheet(isPresented: $sharing) { ShareSheet(items: job.shared).presentationCornerRadius(Radius.sheet) }
                }
                if job.skipped > 0 {
                    Label(String(localized: "\(job.skipped) locked notebooks were left out. Unlock them to export them."), systemImage: "lock")
                        .font(.subheadline)
                        .foregroundStyle(Color.textSecondary)
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("export.skipped")
                }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle")
            case .cancelled:
                Text("Export cancelled.")
            }
        }
        .padding(Space.x8)
    }

    private var recordingsToggle: some View {
        VStack(alignment: .leading, spacing: Space.x2) {
            Toggle(isOn: Binding(get: { job.includesRecordings }, set: { job.includeRecordings($0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Include Recordings").foregroundStyle(Color.ink)
                    Text(job.recordingCount == 1 ? String(localized: "The recording and any transcript go in a zip with the PDF.")
                                                 : String(localized: "The \(job.recordingCount) recordings and any transcripts go in a zip with the PDF."))
                        .font(.footnote)
                        .foregroundStyle(Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.owlLuna)
            .accessibilityIdentifier("export.recordings")
            if job.includesRecordings {
                switch job.bundle {
                case .making?: ProgressView { Text("Adding recordings…").font(.footnote).foregroundStyle(Color.textSecondary) }
                case .failed(let message)?: Label(message, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(Color.tomato)
                default: EmptyView()
                }
            }
        }
        .frame(maxWidth: 380)
    }

    private func readyText(_ count: Int) -> String {
        switch job.format {
        case .pdf: count == 1 ? String(localized: "Your PDF is ready.") : String(localized: "Your \(count) PDFs are ready.")
        case .images: count == 1 ? String(localized: "Your image is ready.") : String(localized: "Your \(count) images are ready.")
        case .timelapse: String(localized: "Your video is ready.")
        case .text: String(localized: "Your text is ready.")
        }
    }

    private func print(_ urls: [URL]) {
        guard let first = urls.first else { return }
        let controller = UIPrintInteractionController.shared
        let info = UIPrintInfo.printInfo()
        info.jobName = first.deletingPathExtension().lastPathComponent
        info.outputType = .general
        controller.printInfo = info
        if urls.count == 1 { controller.printingItem = first } else { controller.printingItems = urls }
        ExportFolder.beginReading(urls)
        if !controller.present(animated: true, completionHandler: { _, _, _ in ExportFolder.endReading(urls) }) { ExportFolder.endReading(urls) }
    }
}

extension NotebookExporter.Input {
    /// `pages` narrows the export to some of the notebook's pages; nil takes them all.
    @MainActor
    init(document: NotebookDocument, pages: [NotebookPage]? = nil) {
        let chosen = pages ?? document.pages
        var inMemory: [UUID: PKDrawing] = [:]
        for page in chosen { if let ink = document.loadedInk(page.id) { inMemory[page.id] = ink } }
        self.init(title: document.title, pages: chosen, inMemoryInk: inMemory, package: document.package, recordings: document.manifest.recordings,
                  notebook: pages == nil ? nil : document.pages)
    }

    /// The pages `range` of the notebook takes, by their place in it.
    func narrowed(to range: ClosedRange<Int>) -> Self {
        let all = allPages
        let range = range.clamped(to: 0...max(all.count - 1, 0))
        guard !all.isEmpty, range != 0...(all.count - 1) || notebook != nil else { return self }
        var copy = self
        copy.pages = Array(all[range])
        copy.notebook = all
        copy.inMemoryInk = inMemoryInk.filter { id, _ in copy.pages.contains { $0.id == id } }
        return copy
    }
}

/// A film playing silently over and over, without controls: the preview of an exported time-lapse.
struct LoopingVideo: UIViewRepresentable {
    let url: URL

    final class PlayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var looper: AVPlayerLooper?
    }

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        let player = AVQueuePlayer()
        player.isMuted = true
        view.looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        (view.layer as? AVPlayerLayer)?.player = player
        (view.layer as? AVPlayerLayer)?.videoGravity = .resizeAspect
        player.play()
        return view
    }

    func updateUIView(_ view: PlayerView, context: Context) {}

    static func dismantleUIView(_ view: PlayerView, coordinator: ()) {
        (view.layer as? AVPlayerLayer)?.player?.pause()
        view.looper = nil
    }
}

/// The files shared stay in their export folder until what was chosen has finished: shared, saved or cancelled.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        let files = items.compactMap { $0 as? URL }.filter(\.isFileURL)
        ExportFolder.beginReading(files)
        controller.completionWithItemsHandler = { _, _, _, _ in ExportFolder.endReading(files) }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
