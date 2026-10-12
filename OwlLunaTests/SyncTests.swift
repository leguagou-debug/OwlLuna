import XCTest
import PencilKit
@testable import OwlLuna

/// Two devices and the synced copy between them, played out with three folders.
final class SyncTests: XCTestCase {
    private let paper = PageDefaults(template: .grid, paperColor: .white, pageSize: .letter)
    private var cloud: CloudFolder!
    private var a: StorageRoot!
    private var b: StorageRoot!

    override func setUp() {
        super.setUp()
        a = temporaryRoot(self)
        b = temporaryRoot(self)
        cloud = CloudFolder(url: temporaryRoot(self).url)
    }

    @discardableResult
    private func makeNotebook(_ title: String, on root: StorageRoot, strokes: Int = 1) async throws -> NotebookManifest {
        let manifest = NotebookManifest(title: title, defaults: paper, pages: [paper.newPage(), paper.newPage()])
        let package = NotebookPackage(root: root, id: manifest.id)
        try await package.create(manifest)
        let ink = PKDrawing(strokes: (0..<strokes).map { stroke(from: CGPoint(x: 40, y: 40 + CGFloat($0) * 30), to: CGPoint(x: 200, y: 60 + CGFloat($0) * 30)) })
        let receipt = try await package.write(SaveSnapshot(manifest: manifest, ink: [manifest.pages[0].id: ink]))
        try await package.writeThumbnail(Data([1, 2, 3]), pageID: manifest.pages[0].id, key: "cache")
        return receipt.manifest
    }

    /// An edit as the editor would save it: more ink, a later modification date, perhaps a new title.
    private func edit(_ id: UUID, on root: StorageRoot, title: String? = nil, strokes: Int, after seconds: TimeInterval) async throws {
        let package = NotebookPackage(root: root, id: id)
        var manifest = try await package.readManifest().manifest
        manifest.modifiedAt = manifest.modifiedAt.addingTimeInterval(seconds)
        if let title { manifest.title = title }
        let ink = PKDrawing(strokes: (0..<strokes).map { stroke(from: CGPoint(x: 40, y: 40 + CGFloat($0) * 30), to: CGPoint(x: 200, y: 60 + CGFloat($0) * 30)) })
        _ = try await package.write(SaveSnapshot(manifest: manifest, ink: [manifest.pages[0].id: ink]))
    }

    private func strokes(_ manifest: NotebookManifest, on root: StorageRoot) async -> Int {
        guard case .ink(let drawing, _) = await NotebookPackage(root: root, id: manifest.id).readInk(manifest.pages[0].id) else { return 0 }
        return drawing.strokes.count
    }

    private func titles(on root: StorageRoot) async -> [String] {
        var result: [String] = []
        for id in root.packageIDs() { if let title = try? await NotebookPackage(root: root, id: id).readManifest().manifest.title { result.append(title) } }
        return result.sorted()
    }

    @discardableResult
    private func sync(_ root: StorageRoot, busy: Set<UUID> = []) async throws -> SyncReport {
        try await LibrarySync.run(root: root, cloud: cloud, busy: busy)
    }

    func testANotebookWrittenOnOneDeviceArrivesOnTheOther() async throws {
        let physics = try await makeNotebook("Physics", on: a, strokes: 2)
        let first = try await sync(a)
        XCTAssertEqual(first.pushed, [physics.id])
        XCTAssertFalse(first.changedHere)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cloud.package(physics.id).appending(path: "thumbs").path(percentEncoded: false)), "thumbnails don't travel")

        let second = try await sync(b)
        XCTAssertEqual(second.pulled, [physics.id])
        XCTAssertTrue(second.changedHere)
        let arrived = try await NotebookPackage(root: b, id: physics.id).readManifest()
        XCTAssertEqual(arrived.manifest.title, "Physics")
        XCTAssertTrue(arrived.recoveredPageIDs.isEmpty && arrived.quarantined.isEmpty, "the notebook arrives whole")
        let count = await strokes(physics, on: b)
        XCTAssertEqual(count, 2)

        let againA = try await sync(a), againB = try await sync(b)
        XCTAssertEqual(againA, SyncReport(), "with nothing changed, a sync does nothing")
        XCTAssertEqual(againB, SyncReport())

        try await edit(physics.id, on: b, title: "Physics II", strokes: 5, after: 60)
        let pushed = try await sync(b)
        XCTAssertEqual(pushed.pushed, [physics.id])
        let pulled = try await sync(a)
        XCTAssertEqual(pulled.pulled, [physics.id])
        let edited = await strokes(physics, on: a)
        XCTAssertEqual(edited, 5, "an edit made on the second device comes back to the first")
        let names = await titles(on: a)
        XCTAssertEqual(names, ["Physics II"])
    }

    func testNotebooksChangedOnBothDevicesAreBothKept() async throws {
        let notes = try await makeNotebook("Notes", on: a)
        try await sync(a)
        try await sync(b)

        try await edit(notes.id, on: a, strokes: 3, after: 60)
        try await edit(notes.id, on: b, strokes: 7, after: 120)
        try await sync(a)
        let report = try await sync(b)
        XCTAssertEqual(report.conflictCopies.count, 1)
        XCTAssertEqual(report.pushed, [notes.id], "the newer version keeps the notebook's place")
        let onB = await titles(on: b)
        XCTAssertEqual(onB, ["Notes", "Notes (conflicted copy)"])
        let winner = await strokes(notes, on: b)
        XCTAssertEqual(winner, 7)

        try await sync(b)
        let last = try await sync(a)
        XCTAssertEqual(Set(last.pulled).count, 2, "the first device receives the newer version and the copy of its own")
        let onA = await titles(on: a)
        XCTAssertEqual(onA, ["Notes", "Notes (conflicted copy)"])
        let newer = await strokes(notes, on: a)
        XCTAssertEqual(newer, 7)
        var copyStrokes = 0
        for id in a.packageIDs() where id != notes.id {
            let manifest = try await NotebookPackage(root: a, id: id).readManifest().manifest
            XCTAssertEqual(manifest.id, id, "the copy is a notebook of its own")
            copyStrokes = await strokes(manifest, on: a)
        }
        XCTAssertEqual(copyStrokes, 3, "nothing written on either device is lost")
        let settledA = try await sync(a), settledB = try await sync(b)
        XCTAssertEqual(settledA, SyncReport())
        XCTAssertEqual(settledB, SyncReport())
    }

    func testADeleteCarriesOverUnlessTheNotebookWasWrittenInSince() async throws {
        let old = try await makeNotebook("Old", on: a), kept = try await makeNotebook("Kept", on: a)
        try await sync(a)
        try await sync(b)

        try FileManager.default.removeItem(at: a.package(old.id))
        try FileManager.default.removeItem(at: a.package(kept.id))
        let removed = try await sync(a)
        XCTAssertEqual(Set(removed.removedThere), [old.id, kept.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: cloud.tombstone(old.id).path(percentEncoded: false)))

        try await edit(kept.id, on: b, title: "Kept and written in", strokes: 4, after: 60)
        let report = try await sync(b)
        XCTAssertEqual(report.removedHere, [old.id], "a notebook deleted elsewhere and untouched here goes")
        XCTAssertEqual(report.pushed, [kept.id], "one written in since is kept: writing wins over a delete")
        let onB = await titles(on: b)
        XCTAssertEqual(onB, ["Kept and written in"])

        let back = try await sync(a)
        XCTAssertEqual(back.pulled, [kept.id])
        let onA = await titles(on: a)
        XCTAssertEqual(onA, ["Kept and written in"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.package(old.id).path(percentEncoded: false)), "and the deleted one doesn't come back")
    }

    func testAnOpenNotebookAndAHalfArrivedOneAreLeftForLater() async throws {
        let open = try await makeNotebook("Open", on: a)
        let busy = try await sync(a, busy: [open.id])
        XCTAssertEqual(busy.waiting, [open.id])
        XCTAssertTrue(busy.pushed.isEmpty)
        try await sync(a)
        try await sync(b)

        try await edit(open.id, on: a, strokes: 6, after: 60)
        try await sync(a)
        let manifest = cloud.package(open.id).appending(path: "manifest.json")
        let whole = try Data(contentsOf: manifest)
        try Data("{".utf8).write(to: manifest)
        let report = try await sync(b)
        XCTAssertEqual(report.waiting, [open.id], "a manifest that can't be read yet is waited for")
        let untouched = await strokes(open, on: b)
        XCTAssertEqual(untouched, 1)
        try whole.write(to: manifest)
        let later = try await sync(b)
        XCTAssertEqual(later.pulled, [open.id])
    }

    func testFoldersAndStickersFollow() async throws {
        let science = FolderEntry(id: UUID(), name: "Science", clothRaw: "jade", createdAt: .now, sortIndex: 0)
        let labs = FolderEntry(id: UUID(), name: "Labs", clothRaw: "moss", createdAt: .now, sortIndex: 1, parentID: science.id)
        var file = FolderFile()
        file.folders = [science, labs]
        try file.write(a)
        try FileManager.default.createDirectory(at: a.stickers, withIntermediateDirectories: true)
        try Data([1]).write(to: a.stickers.appending(path: "cat.png"))
        try await sync(a)
        let first = try await sync(b)
        XCTAssertTrue(first.foldersChanged && first.stickersChanged)
        XCTAssertEqual(FolderFile.read(b).folders.map(\.name), ["Science", "Labs"])
        XCTAssertEqual(FolderFile.read(b).folders.last?.parentID, science.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: b.stickers.appending(path: "cat.png").path(percentEncoded: false)))

        var changed = FolderFile.read(b)
        changed.folders.removeAll { $0.id == labs.id }
        changed.folders.append(FolderEntry(id: UUID(), name: "Art", clothRaw: "rose", createdAt: .now, sortIndex: 2))
        try changed.write(b)
        try FileManager.default.removeItem(at: b.stickers.appending(path: "cat.png"))
        try Data([2]).write(to: b.stickers.appending(path: "dog.png"))
        try await sync(b)
        try await sync(a)
        XCTAssertEqual(FolderFile.read(a).folders.map(\.name).sorted(), ["Art", "Science"], "a folder deleted on one device goes from the other, and a new one arrives")
        let stickers = try FileManager.default.contentsOfDirectory(atPath: a.stickers.path(percentEncoded: false))
        XCTAssertEqual(stickers, ["dog.png"])
    }

    // MARK: How a notebook is filed

    private func library(_ id: UUID, on root: StorageRoot) async throws -> LibraryState {
        try await NotebookPackage(root: root, id: id).readManifest().manifest.library
    }

    /// A library change as `LibraryStore` writes it: what changed is stamped, and the notebook's own date left alone.
    /// With no date it is as an older build wrote it, unstamped.
    private func file(_ id: UUID, on root: StorageRoot, at date: Date?, _ change: @escaping @Sendable (inout LibraryState) -> Void) async throws {
        _ = try await NotebookPackage(root: root, id: id).updateManifest {
            let before = $0.library
            change(&$0.library)
            if let date { $0.library.stamp(changesSince: before, at: date) }
        }
    }

    private func settled(file: StaticString = #filePath, line: UInt = #line) async throws {
        let onA = try await sync(a), onB = try await sync(b)
        XCTAssertEqual(onA, SyncReport(), file: file, line: line)
        XCTAssertEqual(onB, SyncReport(), file: file, line: line)
    }

    func testFilingReachesTheOtherDeviceWithoutAnEdit() async throws {
        let diary = try await makeNotebook("Diary", on: a, strokes: 2), folder = UUID()
        try await sync(a)
        try await sync(b)
        _ = try await NotebookPackage(root: b, id: diary.id).updateManifest { $0.library.currentPage = 1 }
        let trashed = Date.now
        try await file(diary.id, on: a, at: .now) {
            $0.isLocked = true
            $0.isFavorite = true
            $0.tags = ["secret"]
            $0.folderID = folder
            $0.deletedAt = trashed
        }

        let sent = try await sync(a)
        XCTAssertEqual(sent.stateSent, [diary.id], "the lock goes at the next sync, with no edit to carry it")
        XCTAssertEqual(sent.pushed, [], "and the pages aren't sent again")
        XCTAssertFalse(sent.changedHere)
        let received = try await sync(b)
        XCTAssertEqual(received.stateReceived, [diary.id])
        XCTAssertEqual(received.pulled, [])
        XCTAssertTrue(received.changedHere, "which is what has the index, Spotlight and the widgets brought up to date")

        let arrived = try await NotebookPackage(root: b, id: diary.id).readManifest().manifest
        XCTAssertTrue(arrived.library.isLocked && arrived.library.isFavorite)
        XCTAssertEqual(arrived.library.tags, ["secret"])
        XCTAssertEqual(arrived.library.folderID, folder)
        XCTAssertEqual(try XCTUnwrap(arrived.library.deletedAt).timeIntervalSince(trashed), 0, accuracy: 0.001)
        XCTAssertEqual(arrived.library.currentPage, 1, "where this device left off reading stays its own")
        XCTAssertEqual(arrived.modifiedAt.timeIntervalSince(diary.modifiedAt), 0, accuracy: 0.001, "and the notebook isn't dated by it")
        let count = await strokes(diary, on: b)
        XCTAssertEqual(count, 2)
        try await settled()
    }

    func testAPullKeepsALockSetHere() async throws {
        let diary = try await makeNotebook("Diary", on: a)
        try await sync(a)
        try await sync(b)

        try await file(diary.id, on: a, at: .now) { $0.isLocked = true }
        try await edit(diary.id, on: b, strokes: 5, after: 60)
        try await sync(b)
        let report = try await sync(a)
        XCTAssertEqual(report.pulled, [diary.id])
        XCTAssertEqual(report.stateSent, [diary.id])
        XCTAssertEqual(report.conflictCopies, [])
        let here = try await library(diary.id, on: a)
        XCTAssertTrue(here.isLocked, "newer pages from a device that never had the lock don't take it off")
        let count = await strokes(diary, on: a)
        XCTAssertEqual(count, 5)

        let back = try await sync(b)
        XCTAssertEqual(back.stateReceived, [diary.id])
        let there = try await library(diary.id, on: b)
        XCTAssertTrue(there.isLocked, "and the lock reaches that device")
        try await settled()
    }

    func testEachPartOfTheFilingGoesByItsOwnDate() async throws {
        let notes = try await makeNotebook("Notes", on: a)
        try await sync(a)
        try await sync(b)

        // Locked here first; the other device, which hasn't heard of the lock, changes other things afterwards.
        let earlier = Date.now, later = earlier.addingTimeInterval(30), shelf = UUID(), drawer = UUID()
        try await file(notes.id, on: a, at: earlier) {
            $0.isLocked = true
            $0.folderID = shelf
        }
        try await file(notes.id, on: b, at: later) {
            $0.isFavorite = true
            $0.folderID = drawer
        }
        try await sync(b)
        let report = try await sync(a)
        XCTAssertEqual(report.stateSent, [notes.id])
        XCTAssertEqual(report.stateReceived, [notes.id])
        try await sync(b)
        for root in [a!, b!] {
            let state = try await library(notes.id, on: root)
            XCTAssertTrue(state.isLocked, "a later favourite made elsewhere doesn't take the lock off")
            XCTAssertTrue(state.isFavorite)
            XCTAssertEqual(state.folderID, drawer, "where both devices moved it, the later move stands")
        }
        try await settled()

        try await file(notes.id, on: b, at: later.addingTimeInterval(30)) { $0.isLocked = false }
        try await sync(b)
        try await sync(a)
        let unlocked = try await library(notes.id, on: a)
        XCTAssertFalse(unlocked.isLocked, "only a later unlock does")
        XCTAssertTrue(unlocked.isFavorite)
    }

    func testALockFromBeforeChangesWereStampedIsNeverDropped() async throws {
        let diary = try await makeNotebook("Diary", on: a), journal = try await makeNotebook("Journal", on: a)
        try await sync(a)
        try await sync(b)
        // Locked by a build that neither stamped nor sent it.
        try await file(diary.id, on: a, at: nil) { $0.isLocked = true }
        try await file(journal.id, on: a, at: nil) { $0.isLocked = true }
        try await file(diary.id, on: b, at: .now) { $0.isFavorite = true }
        try await sync(b)

        let report = try await sync(a)
        XCTAssertEqual(Set(report.stateSent), [diary.id, journal.id], "the unsent lock goes up, and the newer favourite doesn't cost the other its lock")
        XCTAssertEqual(report.stateReceived, [diary.id])
        let here = try await library(diary.id, on: a)
        XCTAssertTrue(here.isLocked && here.isFavorite)
        try await sync(b)
        for id in [diary.id, journal.id] {
            let there = try await library(id, on: b)
            XCTAssertTrue(there.isLocked)
        }
        try await settled()

        try await file(journal.id, on: b, at: Date.now.addingTimeInterval(1)) { $0.isLocked = false }
        try await sync(b)
        try await sync(a)
        let journalHere = try await library(journal.id, on: a)
        XCTAssertFalse(journalHere.isLocked, "and taking such a lock off still carries over")
    }

    func testAConflictedCopyOfALockedNotebookIsLocked() async throws {
        let diary = try await makeNotebook("Diary", on: a)
        try await sync(a)
        try await sync(b)

        try await file(diary.id, on: a, at: .now) { $0.isLocked = true }
        try await edit(diary.id, on: a, strokes: 3, after: 60)
        try await edit(diary.id, on: b, strokes: 7, after: 120)
        try await sync(a)
        let report = try await sync(b)
        XCTAssertEqual(report.conflictCopies.count, 1)
        XCTAssertEqual(report.pushed, [diary.id], "the newer pages keep the notebook's place")
        for id in b.packageIDs() {
            let state = try await library(id, on: b)
            XCTAssertTrue(state.isLocked, "the notebook and the copy kept beside it are both locked")
        }
        try await sync(b)
        try await sync(a)
        for id in a.packageIDs() {
            let state = try await library(id, on: a)
            XCTAssertTrue(state.isLocked)
        }
        XCTAssertEqual(a.packageIDs().count, 2)
        try await settled()
    }

    // MARK: A synced copy that isn't the one this device knew

    private func fill(_ root: StorageRoot, folder: String = "Science", sticker: String = "cat.png") throws {
        var file = FolderFile.read(root)
        file.folders.append(FolderEntry(id: UUID(), name: folder, clothRaw: "jade", createdAt: .now, sortIndex: file.folders.count))
        try file.write(root)
        try FileManager.default.createDirectory(at: root.stickers, withIntermediateDirectories: true)
        try Data([1]).write(to: root.stickers.appending(path: sticker))
    }

    private func stickers(in directory: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []).sorted()
    }

    func testAnErasedCopyIsFilledAgainAndNothingIsDeleted() async throws {
        let physics = try await makeNotebook("Physics", on: a)
        try fill(a)
        let first = try await sync(a)
        XCTAssertFalse(first.startedAgain)
        try FileManager.default.removeItem(at: cloud.url)

        let report = try await sync(a)
        XCTAssertTrue(report.startedAgain)
        XCTAssertEqual(report.pushed, [physics.id])
        XCTAssertFalse(report.changedHere)
        XCTAssertEqual(FolderFile.read(a).folders.map(\.name), ["Science"], "a folder missing from an erased copy was never deleted")
        XCTAssertEqual(stickers(in: a.stickers), ["cat.png"])
        XCTAssertEqual(stickers(in: cloud.stickers), ["cat.png"], "and the copy is filled again")
        let again = try await sync(a)
        XCTAssertEqual(again, SyncReport())
    }

    func testACopyRefilledByAnotherDeviceDeletesNothingHere() async throws {
        try fill(a)
        try await sync(a)
        try await sync(b)
        // Made here and synced, but the other device never saw them before the copy was erased.
        try fill(b, folder: "Art", sticker: "dog.png")
        try await sync(b)
        try FileManager.default.removeItem(at: cloud.url)
        try await sync(a)
        XCTAssertEqual(stickers(in: cloud.stickers), ["cat.png"])

        let report = try await sync(b)
        XCTAssertTrue(report.startedAgain, "the copy is not the one this device agreed with")
        XCTAssertEqual(FolderFile.read(b).folders.map(\.name).sorted(), ["Art", "Science"])
        XCTAssertEqual(stickers(in: b.stickers), ["cat.png", "dog.png"])
        try await sync(a)
        XCTAssertEqual(FolderFile.read(a).folders.map(\.name).sorted(), ["Art", "Science"])
        XCTAssertEqual(stickers(in: a.stickers), ["cat.png", "dog.png"])
    }

    func testAnotherAccountsCopyIsOnlyAddedTo() async throws {
        let mine = try await makeNotebook("Mine", on: a)
        try fill(a)
        _ = try await LibrarySync.run(root: a, cloud: cloud, account: "one")
        XCTAssertEqual(SyncState.read(a).account, "one")
        XCTAssertEqual(SyncState.read(a).copy, try String(contentsOf: cloud.copyFile, encoding: .utf8))

        let other = CloudFolder(url: temporaryRoot(self).url)
        let theirs = try await makeNotebook("Theirs", on: b)
        _ = try await LibrarySync.run(root: b, cloud: other, account: "two")

        let report = try await LibrarySync.run(root: a, cloud: other, account: "two")
        XCTAssertTrue(report.startedAgain)
        XCTAssertEqual(report.pushed, [mine.id])
        XCTAssertEqual(report.pulled, [theirs.id])
        XCTAssertEqual(FolderFile.read(a).folders.map(\.name), ["Science"], "nothing synced under the first account is taken as deleted")
        XCTAssertEqual(stickers(in: a.stickers), ["cat.png"])
        XCTAssertEqual(SyncState.read(a).account, "two")
    }

    func testADeviceThatSyncedBeforeCopiesWereNamedKeepsWhatItAgreed() async throws {
        let old = try await makeNotebook("Old", on: a)
        try fill(a)
        try await sync(a)
        try await sync(b)
        // As an older build left things: no name on the copy, none in either device's state.
        try FileManager.default.removeItem(at: cloud.copyFile)
        for root in [a!, b!] {
            var state = SyncState.read(root)
            state.copy = nil
            try state.write(root)
        }

        try FileManager.default.removeItem(at: b.package(old.id))
        var folders = FolderFile.read(b)
        folders.folders = []
        try folders.write(b)
        let removed = try await sync(b)
        XCTAssertFalse(removed.startedAgain)
        XCTAssertEqual(removed.removedThere, [old.id])
        let report = try await sync(a)
        XCTAssertFalse(report.startedAgain)
        XCTAssertEqual(report.removedHere, [old.id], "deletions made on the other device still carry over")
        XCTAssertEqual(FolderFile.read(a).folders, [])
        XCTAssertEqual(SyncState.read(a).copy, SyncState.read(b).copy)
    }

    func testAPullInterruptedByAQuitIsClearedAway() async throws {
        let physics = try await makeNotebook("Physics", on: a)
        try await sync(a)
        let stray = b.arriving.appending(path: "\(physics.id.uuidString)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: b.arriving, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: cloud.package(physics.id), to: stray)

        LibrarySync.sweepArriving(root: b)
        XCTAssertFalse(FileManager.default.fileExists(atPath: b.arriving.path(percentEncoded: false)))
        let report = try await sync(b)
        XCTAssertEqual(report.pulled, [physics.id], "and the next pull has somewhere to assemble")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: b.arriving.path(percentEncoded: false)), [])
    }

    func testADateIsTheSameHoweverOftenItIsRewritten() throws {
        for millisecond in 0..<1000 {
            let written = "2026-10-12T08:47:02.\(String(format: "%03d", millisecond))"
            var date = try XCTUnwrap(ManifestCodec.parseDate(written))
            for _ in 0..<5 { date = try XCTUnwrap(ManifestCodec.encodeDate(date).stringValue.flatMap(ManifestCodec.parseDate)) }
            XCTAssertEqual(ManifestCodec.encodeDate(date).stringValue, written)
        }
        let between = try XCTUnwrap(ManifestCodec.parseDate("2026-10-12T08:47:02.409")).addingTimeInterval(0.0006)
        XCTAssertEqual(ManifestCodec.encodeDate(between).stringValue, "2026-10-12T08:47:02.410", "a date is written to the nearest millisecond")
    }

    func testAPackageUnderTheOldNameInTheSyncedCopyIsLeftAlone() async throws {
        let physics = try await makeNotebook("Physics", on: a)
        try await sync(a)
        let synced = cloud.package(physics.id)
        try FileManager.default.moveItem(at: synced, to: synced.deletingPathExtension().appendingPathExtension(StorageRoot.legacyPackageExtension))

        let report = try await sync(b)
        XCTAssertEqual(report, SyncReport(), "a name the app never writes to the synced copy is neither pulled nor deleted")
        XCTAssertEqual(b.packageIDs(), [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cloud.library.path(percentEncoded: false)).filter { $0.hasSuffix(".\(StorageRoot.legacyPackageExtension)") }.count, 1)
    }
}
