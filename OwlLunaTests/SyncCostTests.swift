import XCTest
import PencilKit
@testable import OwlLuna

/// iCloud as these tests play it, on the one folder both devices share: a file taken off the device leaves a
/// placeholder and is kept aside, and asking for it brings it back.
private final class StandInCloud: @unchecked Sendable {
    private let lock = NSLock()
    private let aside: URL
    private var kept: [String: URL] = [:]
    private var askedFor: [URL] = []
    private var evictedFiles: [URL] = []
    private var uploaded = true
    private var withheld: @Sendable (URL) -> Bool = { _ in false }
    /// Told of each request, with its limit, before anything comes down.
    var onFetch: (@Sendable ([URL], Duration) -> Void)?

    init(aside: URL) { self.aside = aside }

    var access: CloudAccess {
        CloudAccess(fetch: { [self] files, limit in fetch(files, limit) }, evict: { [self] in evict($0) })
    }

    var asked: [URL] { lock.withLock { askedFor } }
    var evicted: [URL] { lock.withLock { evictedFiles } }
    func setUploaded(_ value: Bool) { lock.withLock { uploaded = value } }
    /// Files that don't come down when asked for, as with no network.
    func withhold(_ rule: @escaping @Sendable (URL) -> Bool) { lock.withLock { withheld = rule } }
    func forgetAsked() { lock.withLock { askedFor = [] } }

    private static func key(_ url: URL) -> String { url.resolvingSymlinksInPath().path(percentEncoded: false) }
    private static func placeholder(_ url: URL) -> URL { url.deletingLastPathComponent().appending(path: ".\(url.lastPathComponent).icloud") }

    private func takeOff(_ url: URL) throws {
        let store = aside.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: aside, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: url, to: store)
        try Data().write(to: Self.placeholder(url))
        kept[Self.key(url)] = store
    }

    private func evict(_ url: URL) -> Bool {
        lock.withLock {
            guard uploaded, FileManager.default.fileExists(atPath: url.path(percentEncoded: false)), (try? takeOff(url)) != nil else { return false }
            evictedFiles.append(url)
            return true
        }
    }

    /// Every file in the folder off the device, as on an iPad that hasn't downloaded any of them.
    func evictAll(_ folder: URL) throws {
        let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey])?.compactMap { $0 as? URL } ?? []
        try lock.withLock {
            for url in files where CloudFiles.placeholderTarget(url.lastPathComponent) == nil
                && (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                try takeOff(url)
            }
        }
    }

    private func fetch(_ files: [URL], _ limit: Duration) -> [URL] {
        onFetch?(files, limit)
        return lock.withLock {
            askedFor += files
            return files.filter { url in
                guard FileManager.default.fileExists(atPath: Self.placeholder(url).path(percentEncoded: false)) else { return false }
                guard !withheld(url), let store = kept.removeValue(forKey: Self.key(url)) else { return true }
                try? FileManager.default.removeItem(at: Self.placeholder(url))
                return (try? FileManager.default.moveItem(at: store, to: url)) == nil
            }
        }
    }
}

/// What a pass downloads, keeps on the device and sends: only what it needs, and never at the cost of a notebook.
final class SyncCostTests: XCTestCase {
    private let paper = PageDefaults(template: .grid, paperColor: .white, pageSize: .letter)
    private var cloud: CloudFolder!
    private var a: StorageRoot!
    private var b: StorageRoot!
    private var icloud: StandInCloud!

    override func setUp() {
        super.setUp()
        a = temporaryRoot(self)
        b = temporaryRoot(self)
        cloud = CloudFolder(url: temporaryRoot(self).url)
        icloud = StandInCloud(aside: temporaryRoot(self).url)
    }

    private func drawing(_ strokes: Int) -> PKDrawing {
        PKDrawing(strokes: (0..<strokes).map { stroke(from: CGPoint(x: 40, y: 40 + CGFloat($0) * 30), to: CGPoint(x: 200, y: 60 + CGFloat($0) * 30)) })
    }

    /// Two pages with ink on the first, and a third that is a picture when `picture`. Returns it, with the picture's file name.
    @discardableResult
    private nonisolated(nonsending) func makeNotebook(_ title: String, on root: StorageRoot, picture: Bool = false, strokes: Int = 1,
                                                     id: UUID? = nil) async throws -> (manifest: NotebookManifest, picture: String?) {
        var manifest = NotebookManifest(title: title, defaults: paper, pages: [paper.newPage(), paper.newPage()])
        if let id { manifest.id = id }
        let package = NotebookPackage(root: root, id: manifest.id)
        try await package.create(manifest)
        var name: String?
        if picture {
            name = try await package.writeAsset(Data(repeating: 7, count: 4096), ext: "png")
            manifest.pages.append(NotebookPage(background: .image(file: name!), paperColor: .white, size: PageSize.letter.points))
        }
        let receipt = try await package.write(SaveSnapshot(manifest: manifest, ink: [manifest.pages[0].id: drawing(strokes)]))
        return (receipt.manifest, name)
    }

    /// An edit as the editor saves it: ink on one page, and a later date.
    private nonisolated(nonsending) func edit(_ id: UUID, on root: StorageRoot, page: Int, strokes: Int, after seconds: TimeInterval) async throws {
        let package = NotebookPackage(root: root, id: id)
        var manifest = try await package.readManifest().manifest
        manifest.modifiedAt = manifest.modifiedAt.addingTimeInterval(seconds)
        _ = try await package.write(SaveSnapshot(manifest: manifest, ink: [manifest.pages[page].id: drawing(strokes)]))
    }

    private nonisolated(nonsending) func strokes(_ id: UUID, on root: StorageRoot, page: Int) async throws -> Int {
        let package = NotebookPackage(root: root, id: id)
        let manifest = try await package.readManifest().manifest
        guard case .ink(let drawing, _) = await package.readInk(manifest.pages[page].id) else { return 0 }
        return drawing.strokes.count
    }

    @discardableResult
    private nonisolated(nonsending) func sync(_ root: StorageRoot, now: Date = .now, busy: Set<UUID> = []) async throws -> SyncReport {
        try await LibrarySync.run(root: root, cloud: cloud, now: now, access: icloud.access, take: { !busy.contains($0) })
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) }
    private func isEvicted(_ url: URL) -> Bool { !exists(url) && exists(url.deletingLastPathComponent().appending(path: ".\(url.lastPathComponent).icloud")) }

    private func ink(_ manifest: NotebookManifest, page: Int) -> URL { cloud.package(manifest.id).appending(path: manifest.pages[page].inkFile) }

    /// The small files every pass looks at, which aren't a notebook's pages.
    private func isDeciding(_ url: URL) -> Bool {
        ["manifest.json", "cards.json", "copy-id", "folders.json", "smart-shelves.json", "pens.json"].contains(url.lastPathComponent)
            || [cloud.tombstones, cloud.stickers].contains { $0.lastPathComponent == url.deletingLastPathComponent().lastPathComponent }
    }

    // MARK: The manifests first, and only what a pull lacks

    func testAPassBringsDownTheManifestsAndOnlyWhatANotebookItPullsLacks() async throws {
        let (pictured, picture) = try await makeNotebook("Pictured", on: a, picture: true, strokes: 2)
        let plain = try await makeNotebook("Plain", on: a).manifest
        try await sync(a)
        try await sync(b)
        try await edit(pictured.id, on: a, page: 1, strokes: 4, after: 60)
        try await sync(a)
        // B's copy of the synced copy as iPadOS keeps it: nothing downloaded that B hasn't asked for.
        try icloud.evictAll(cloud.url)
        icloud.forgetAsked()

        let report = try await sync(b)
        XCTAssertEqual(report.pulled, [pictured.id])
        let pages = Set(icloud.asked.filter { !isDeciding($0) }.map(\.lastPathComponent)).sorted()
        XCTAssertEqual(pages, ["\(pictured.pages[1].id.uuidString).pkdrawing", "manifest.prev.json"],
                       "of the pages only the one written on comes down: the picture and the page B has already are taken from B")
        let pulledInk = try await strokes(pictured.id, on: b, page: 1), keptInk = try await strokes(pictured.id, on: b, page: 0)
        XCTAssertEqual(pulledInk, 4)
        XCTAssertEqual(keptInk, 2)
        XCTAssertTrue(exists(b.package(pictured.id).appending(path: "assets/\(try XCTUnwrap(picture))")), "the picture is still there")
        XCTAssertTrue(isEvicted(ink(pictured, page: 0)) && isEvicted(ink(plain, page: 0)), "and what B didn't need stays in iCloud")
        let after = try await sync(b)
        XCTAssertEqual(after, SyncReport())
    }

    func testANotebookStillComingDownDoesNotHoldUpWhatThisDeviceSends() async throws {
        // Named so that, taken in order of ID, the one coming down would go first.
        let coming = try await makeNotebook("Coming", on: a, id: UUID(uuidString: "00000000-0000-4000-8000-000000000000")).manifest
        try await sync(a)
        try await sync(b)
        try await edit(coming.id, on: a, page: 1, strokes: 3, after: 60)
        try await sync(a)
        try icloud.evictAll(cloud.url)
        icloud.withhold { $0.pathExtension == "pkdrawing" }
        let mine = try await makeNotebook("Mine", on: b, id: UUID(uuidString: "FFFFFFFF-FFFF-4FFF-BFFF-FFFFFFFFFFFF")).manifest
        let cloud = cloud!, sentFirst = Shared<Bool?>(nil)
        icloud.onFetch = { files, limit in
            guard limit > .zero, files.contains(where: { $0.pathExtension == "pkdrawing" && $0.path().contains(coming.id.uuidString) }) else { return }
            sentFirst.value = FileManager.default.fileExists(atPath: cloud.package(mine.id).appending(path: "manifest.json").path(percentEncoded: false))
        }

        let early = try await sync(b)
        XCTAssertEqual(early.pushed, [mine.id])
        XCTAssertEqual(early.arriving, [coming.id], "a notebook whose pages haven't come is left for later")
        XCTAssertEqual(sentFirst.value, true, "and waited for after what B sends has gone")
        let waitedInk = try await strokes(coming.id, on: b, page: 1)
        XCTAssertEqual(waitedInk, 0)

        icloud.withhold { _ in false }
        let later = try await sync(b)
        XCTAssertEqual(later.pulled, [coming.id])
        let arrivedInk = try await strokes(coming.id, on: b, page: 1)
        XCTAssertEqual(arrivedInk, 3)
    }

    func testADownloadStopsWaitingOnceNothingHasArrivedForAWhile() async throws {
        try await makeNotebook("Notes", on: a)
        try await sync(a)
        let file = try XCTUnwrap(LibrarySync.deciding(in: cloud).first { $0.lastPathComponent == "manifest.json" })
        try FileManager.default.moveItem(at: file, to: file.deletingLastPathComponent().appending(path: ".manifest.json.icloud"))
        let started = ContinuousClock.now
        let left = await CloudFiles.download([file, cloud.copyFile], within: .seconds(30), quiet: .milliseconds(300))
        XCTAssertEqual(left, [file], "what is on the device isn't waited for")
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(5), "with nothing arriving, as with no network, it gives up long before its limit")
    }

    // MARK: Taken off the device after a pass that worked

    func testAPassThatWorkedTakesPicturesOffTheDeviceOnceICloudHasThem() async throws {
        let (notes, picture) = try await makeNotebook("Pictured", on: a, picture: true)
        let asset = cloud.package(notes.id).appending(path: "assets/\(try XCTUnwrap(picture))")
        icloud.setUploaded(false)
        try await sync(a)
        XCTAssertEqual(icloud.evicted, [], "nothing goes before iCloud has it")
        icloud.setUploaded(true)
        try await sync(a)
        XCTAssertEqual(icloud.evicted.map(\.lastPathComponent), [asset.lastPathComponent])
        XCTAssertTrue(isEvicted(asset))
        for kept in ["manifest.json", notes.pages[0].inkFile] {
            XCTAssertTrue(exists(cloud.package(notes.id).appending(path: kept)), "\(kept) stays, as every later push compares it")
        }

        try await edit(notes.id, on: a, page: 1, strokes: 2, after: 60)
        // Not yet uploaded, so a copy sent again would still be on the device after the pass.
        icloud.setUploaded(false)
        let sent = try await sync(a)
        XCTAssertEqual(sent.pushed, [notes.id])
        XCTAssertTrue(isEvicted(asset), "a push doesn't send the picture again")
        icloud.setUploaded(true)
        icloud.forgetAsked()
        let received = try await sync(b)
        XCTAssertEqual(received.pulled, [notes.id])
        XCTAssertTrue(icloud.asked.contains { $0.lastPathComponent == asset.lastPathComponent }, "a device without it brings it down")
        XCTAssertTrue(exists(b.package(notes.id).appending(path: "assets/\(asset.lastPathComponent)")))
        let pulledInk = try await strokes(notes.id, on: b, page: 1)
        XCTAssertEqual(pulledInk, 2)
    }

    func testAPassThatStopsOrANotebookLeftWaitingKeepsItsFilesOnTheDevice() async throws {
        let (open, openPicture) = try await makeNotebook("Open", on: a, picture: true)
        let (shut, shutPicture) = try await makeNotebook("Shut", on: a, picture: true)
        do {
            _ = try await LibrarySync.run(root: a, cloud: cloud, access: icloud.access, holdingFolders: { _ in throw CocoaError(.fileWriteUnknown) })
            XCTFail("the folders failing stops the pass")
        } catch is StoppedPass {}
        XCTAssertEqual(icloud.evicted, [], "a pass that stopped evicts nothing")

        try await edit(open.id, on: a, page: 1, strokes: 2, after: 60)
        let report = try await sync(a, busy: [open.id])
        XCTAssertEqual(report.open, [open.id])
        XCTAssertEqual(icloud.evicted.map(\.lastPathComponent), [try XCTUnwrap(shutPicture)], "only the notebook in step is evicted")
        XCTAssertTrue(exists(cloud.package(open.id).appending(path: "assets/\(try XCTUnwrap(openPicture))")))
        _ = shut
    }

    // MARK: Compared by size and hash

    func testAFileWhoseDateICloudChangedIsNotSentAgain() async throws {
        let notes = try await makeNotebook("Notes", on: a, strokes: 3).manifest
        try await sync(a)
        let file = ink(notes, page: 0)
        let whole = Date(timeIntervalSinceReferenceDate: (try XCTUnwrap(file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)).timeIntervalSinceReferenceDate.rounded(.down))
        try FileManager.default.setAttributes([.modificationDate: whole], ofItemAtPath: file.path(percentEncoded: false))

        try await edit(notes.id, on: a, page: 1, strokes: 2, after: 60)
        let report = try await sync(a)
        XCTAssertEqual(report.pushed, [notes.id])
        var fresh = file
        fresh.removeAllCachedResourceValues()
        XCTAssertEqual(try fresh.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, whole,
                       "a page with the same bytes isn't copied again because its date was kept to the second")
    }

    func testAFileOfTheSameSizeAndDateWithOtherBytesIsSent() async throws {
        let notes = try await makeNotebook("Notes", on: a, strokes: 3).manifest
        try await sync(a)
        let file = ink(notes, page: 0), local = a.package(notes.id).appending(path: notes.pages[0].inkFile)
        let mine = try Data(contentsOf: local)
        try Data(mine.map { ~$0 }).write(to: file)
        let date = try XCTUnwrap(local.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path(percentEncoded: false))

        try await edit(notes.id, on: a, page: 1, strokes: 2, after: 60)
        try await sync(a)
        XCTAssertEqual(try Data(contentsOf: file), mine, "the same size and date don't make two files the same")
        let report = try await sync(b)
        XCTAssertEqual(report.pulled, [notes.id])
        let pulled = try await strokes(notes.id, on: b, page: 0)
        XCTAssertEqual(pulled, 3)
    }

    // MARK: Delete markers that run out

    private func marker(_ id: UUID) -> URL { cloud.tombstone(id) }

    func testADeleteMarkerGoesAYearAfterTheNotebookLeftEveryDevice() async throws {
        let notes = try await makeNotebook("Gone", on: a).manifest
        try await sync(a)
        try await sync(b)
        try FileManager.default.removeItem(at: a.package(notes.id))
        try await sync(a)
        let written = DeleteMarker(try Data(contentsOf: marker(notes.id)))
        XCTAssertNotNil(written.markedAt, "a marker says when it was written")
        try await sync(b)
        try FileManager.default.removeItem(at: b.package(notes.id))
        try await sync(b)

        let day: TimeInterval = 86_400
        try await sync(a, now: .now.addingTimeInterval(364 * day))
        XCTAssertTrue(exists(marker(notes.id)), "kept for a year")
        try await sync(a, now: .now.addingTimeInterval(366 * day))
        XCTAssertFalse(exists(marker(notes.id)), "and no longer")
    }

    func testAMarkerIsKeptWhileItsNotebookIsStillOnThisDevice() async throws {
        let notes = try await makeNotebook("Kept", on: a).manifest
        try await sync(a)
        let old = Date.now.addingTimeInterval(-800 * 86_400)
        // Beside the version it was made for, as when iCloud kept an upload over the delete.
        try DeleteMarker(modifiedAt: notes.modifiedAt, markedAt: old).encoded().write(to: marker(notes.id))
        try await sync(a)
        XCTAssertTrue(exists(marker(notes.id)))
    }

    func testAMarkerFromAnOlderBuildGoesByItsFileDate() async throws {
        try await makeNotebook("Notes", on: a)
        try await sync(a)
        let old = UUID(), recent = UUID()
        for id in [old, recent] { try Data().write(to: marker(id)) }
        try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(-400 * 86_400)], ofItemAtPath: marker(old).path(percentEncoded: false))
        try await sync(a)
        XCTAssertFalse(exists(marker(old)))
        XCTAssertTrue(exists(marker(recent)))
    }

    func testADeviceBackAfterItsMarkerWentSendsTheNotebookUpWhole() async throws {
        let notes = try await makeNotebook("Away", on: a, strokes: 2).manifest
        try await sync(a)
        try await sync(b)
        // B goes away for over a year. Meanwhile A deletes the notebook for good, and its marker runs out.
        try FileManager.default.removeItem(at: a.package(notes.id))
        try await sync(a)
        let later = Date.now.addingTimeInterval(400 * 86_400)
        try await sync(a, now: later)
        XCTAssertFalse(exists(marker(notes.id)))

        let back = try await sync(b, now: later)
        XCTAssertEqual(back.pushed, [notes.id], "with no marker B can't tell it was deleted, so it keeps it and sends it up")
        XCTAssertEqual(back.removedHere, [])
        let returned = try await sync(a, now: later)
        XCTAssertEqual(returned.pulled, [notes.id])
        let onA = try await strokes(notes.id, on: a, page: 0), onB = try await strokes(notes.id, on: b, page: 0)
        XCTAssertEqual(onA, 2, "it comes back whole, so nothing is lost")
        XCTAssertEqual(onB, 2)
    }
}

/// Something a test changes while a pass is running.
private final class Shared<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
