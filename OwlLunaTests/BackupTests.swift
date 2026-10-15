import XCTest
import SwiftData
import PencilKit
@testable import OwlLuna

/// Backing up the whole library into one file, restoring it without replacing anything, and exporting pages as images.
@MainActor
final class BackupTests: XCTestCase {
    private var containers: [ModelContainer] = []
    private let paper = PageDefaults(template: .grid, paperColor: .white, pageSize: .letter)

    private func makeStore() throws -> LibraryStore {
        let schema = LibraryIndex.schema
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        containers.append(container)
        return LibraryStore(root: temporaryRoot(self), context: container.mainContext)
    }

    private func makeNotebook(_ title: String, in store: LibraryStore, folder: FolderRecord? = nil, pages: Int = 2) async throws -> NotebookManifest {
        var manifest = NotebookManifest(title: title, defaults: paper, pages: (0..<pages).map { _ in paper.newPage() })
        manifest.library.folderID = folder?.id
        let package = NotebookPackage(root: store.root, id: manifest.id)
        try await package.create(manifest)
        let ink = PKDrawing(strokes: [stroke(from: CGPoint(x: 40, y: 40), to: CGPoint(x: 200, y: 90))])
        let receipt = try await package.write(SaveSnapshot(manifest: manifest, ink: [manifest.pages[0].id: ink]))
        try await package.writeText("#ink:none\nmomentum", pageID: manifest.pages[0].id)
        try await package.writeThumbnail(Data([1, 2, 3]), pageID: manifest.pages[0].id, key: "cache")
        store.index(receipt.manifest)
        return receipt.manifest
    }

    func testABackupBringsTheWholeLibraryBack() async throws {
        let store = try makeStore()
        let science = try XCTUnwrap(store.createFolder(name: "Science", cloth: .jade))
        let physics = try XCTUnwrap(store.createFolder(name: "Physics", cloth: .moss, parent: science))
        let notes = try await makeNotebook("Mechanics", in: store, folder: physics)
        let loose = try await makeNotebook("Recipes", in: store)
        await store.finishWritingShelves()
        try FileManager.default.createDirectory(at: store.root.stickers, withIntermediateDirectories: true)
        try Data([9, 9]).write(to: store.root.stickers.appending(path: "mine.png"))

        let backup = try await store.makeBackup()
        addTeardownBlock { try? FileManager.default.removeItem(at: backup.deletingLastPathComponent()) }
        XCTAssertEqual(backup.pathExtension, LibraryBackup.fileExtension)
        XCTAssertGreaterThan(try XCTUnwrap(try backup.resourceValues(forKeys: [.fileSizeKey]).fileSize), 0)

        let fresh = try makeStore()
        let summary = try await fresh.restoreBackup(from: backup)
        XCTAssertEqual(summary.added, 2)
        XCTAssertEqual(summary.folders, 2)
        XCTAssertEqual(summary.stickers, 1)
        XCTAssertEqual(summary.copies + summary.unchanged + summary.unreadable, 0)

        let restored = try XCTUnwrap(fresh.record(notes.id))
        XCTAssertEqual(restored.title, "Mechanics")
        XCTAssertEqual(restored.folder?.id, physics.id, "a notebook goes back on its shelf")
        XCTAssertEqual(fresh.folderTree().path(of: physics.id), "Science › Physics", "and the shelf back inside its folder")
        XCTAssertNotNil(fresh.record(loose.id))
        let package = NotebookPackage(root: fresh.root, id: notes.id)
        guard case .ink(let ink, _) = await package.readInk(notes.pages[0].id) else { return XCTFail("the ink didn't come back") }
        XCTAssertEqual(ink.strokes.count, 1)
        XCTAssertEqual(LibraryIndex.notebookIDs(matching: "momentum", in: fresh.context).contains(notes.id), true, "recognised text is restored and searchable")
        XCTAssertFalse(FileManager.default.fileExists(atPath: package.thumbURL(notes.pages[0].id, key: "cache").path(percentEncoded: false)),
                       "thumbnails are left out of a backup")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.root.stickers.appending(path: "mine.png").path(percentEncoded: false)))

        let again = try await fresh.restoreBackup(from: backup)
        XCTAssertEqual(again.unchanged, 2, "restoring the same backup twice adds nothing")
        XCTAssertTrue(again.isEmpty)
        XCTAssertEqual(try fresh.context.fetchCount(FetchDescriptor<NotebookRecord>()), 2)
    }

    func testRestoringNeverReplacesANotebook() async throws {
        let store = try makeStore()
        let notes = try await makeNotebook("Mechanics", in: store)
        let backup = try await store.makeBackup()
        addTeardownBlock { try? FileManager.default.removeItem(at: backup.deletingLastPathComponent()) }

        let changed = try await NotebookPackage(root: store.root, id: notes.id).updateManifest { manifest in
            manifest.title = "Mechanics, revised"
            manifest.modifiedAt = manifest.modifiedAt.addingTimeInterval(120)
            manifest.pages.append(manifest.defaults.newPage())
        }
        store.index(changed)

        let summary = try await store.restoreBackup(from: backup)
        XCTAssertEqual(summary.copies, 1)
        XCTAssertEqual(summary.added, 0)
        let records = try store.context.fetch(FetchDescriptor<NotebookRecord>(sortBy: [SortDescriptor(\.title)]))
        XCTAssertEqual(records.map(\.title), ["Mechanics (from backup)", "Mechanics, revised"])
        XCTAssertEqual(store.record(notes.id)?.pageCount, 3, "the notebook in the library is untouched")
        let copy = try XCTUnwrap(records.first)
        XCTAssertNotEqual(copy.id, notes.id)
        XCTAssertEqual(copy.pageCount, 2)
        let manifest = try await NotebookPackage(root: store.root, id: copy.id).readManifest().manifest
        XCTAssertEqual(manifest.id, copy.id, "the copy is a notebook of its own")
        XCTAssertTrue(summary.message.contains("copy"), summary.message)
    }

    func testANotebookTheBackupHadInRecentlyDeletedGetsAnother30DaysThere() async throws {
        let store = try makeStore()
        let binned = try await makeNotebook("Old Lab", in: store)
        let kept = try await makeNotebook("Mechanics", in: store)
        let binnedAt = Date.now.addingTimeInterval(-100 * 86_400)
        let stamped = try await NotebookPackage(root: store.root, id: binned.id).updateManifest { manifest in
            manifest.library.deletedAt = binnedAt
            manifest.library.setChangedAt(binnedAt, for: .deleted)
        }
        store.index(stamped)
        let backup = try LibraryBackup.create(root: store.root)
        addTeardownBlock { try? FileManager.default.removeItem(at: backup.deletingLastPathComponent()) }

        let fresh = try makeStore()
        let summary = try await fresh.restoreBackup(from: backup)
        XCTAssertEqual(summary.added, 2)
        XCTAssertEqual(summary.trashed, 1)
        XCTAssertTrue(summary.message.contains("Recently Deleted"), summary.message)
        let restored = try XCTUnwrap(fresh.record(binned.id))
        XCTAssertTrue(restored.isTrashed, "it goes back to Recently Deleted")
        XCTAssertGreaterThan(try XCTUnwrap(restored.deletedAt), Date.now.addingTimeInterval(-60), "dated from the restore")
        XCTAssertNil(fresh.record(kept.id)?.deletedAt)
        await fresh.purgeExpiredTrash()
        XCTAssertNotNil(fresh.record(binned.id), "so the next launch doesn't delete it for good")

        let library = try await NotebookPackage(root: fresh.root, id: binned.id).readManifest().manifest.library
        XCTAssertEqual(try XCTUnwrap(library.changedAt(.deleted)).timeIntervalSince(binnedAt), 0, accuracy: 0.002, "the old stamp stays")
        var stale = library
        stale.deletedAt = binnedAt
        XCTAssertEqual(LibraryState.settled(here: library, there: stale, now: .now)?.deletedAt, library.deletedAt, "a copy with the old date gives way")
        var restoredElsewhere = library
        restoredElsewhere.deletedAt = nil
        restoredElsewhere.setChangedAt(binnedAt.addingTimeInterval(30 * 86_400), for: .deleted)
        XCTAssertNil(try XCTUnwrap(LibraryState.settled(here: library, there: restoredElsewhere, now: .now)).deletedAt,
                     "a restore made since on another device still wins")
    }

    func testARestoreEndedPartWayNeverLeavesANotebookUnderTheWrongID() async throws {
        let store = try makeStore()
        let notes = try await makeNotebook("Mechanics", in: store)
        let binned = try await makeNotebook("Old Lab", in: store)
        _ = try await NotebookPackage(root: store.root, id: binned.id).updateManifest { $0.library.deletedAt = Date.now.addingTimeInterval(-100 * 86_400) }
        let backup = try LibraryBackup.create(root: store.root)
        addTeardownBlock { try? FileManager.default.removeItem(at: backup.deletingLastPathComponent()) }
        _ = try await NotebookPackage(root: store.root, id: notes.id).updateManifest { manifest in
            manifest.modifiedAt = manifest.modifiedAt.addingTimeInterval(120)
            manifest.pages.append(manifest.defaults.newPage())
        }
        try FileManager.default.removeItem(at: store.root.package(binned.id))

        let root = store.root, quits = temporaryRoot(self).url
        let summary = try await LibraryBackup.restore(from: backup, into: root, beforeRewrite: { package in
            // The app is ended here, with a notebook out of the backup and its manifest not yet rewritten: this is what the next launch finds.
            XCTAssertFalse(package.url.path(percentEncoded: false).hasPrefix(root.library.path(percentEncoded: false)))
            try FileManager.default.copyItem(at: root.url, to: quits.appending(path: UUID().uuidString, directoryHint: .isDirectory))
        })
        XCTAssertEqual(summary.copies, 1)
        XCTAssertEqual(summary.trashed, 1)
        XCTAssertEqual(root.packageIDs().count, 3)

        let snapshots = try FileManager.default.contentsOfDirectory(at: quits, includingPropertiesForKeys: nil)
        XCTAssertEqual(snapshots.count, 2, "one for the copy and one for the notebook going back to Recently Deleted")
        for snapshot in snapshots.map({ StorageRoot(url: $0) }) {
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: snapshot.arriving.path(percentEncoded: false)).count, 1,
                           "the notebook waits in Arriving")
            LibrarySync.sweepArriving(root: snapshot, untouchedSince: .now)
            LibraryStore.sweepUnfinished(root: snapshot, untouchedSince: .now)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: snapshot.arriving.path(percentEncoded: false)), [])
            XCTAssertTrue(snapshot.packageIDs().contains(notes.id))
            for id in snapshot.packageIDs() {
                let manifest = try await NotebookPackage(root: snapshot, id: id).readManifest().manifest
                XCTAssertEqual(manifest.id, id, "no notebook in the library carries another one's ID")
                XCTAssertGreaterThan(manifest.library.deletedAt ?? .now, Date.now.addingTimeInterval(-30 * 86_400), "or 30 days that are already over")
            }
        }
    }

    func testABackupFromTheOldAppRestoresUnderTheNewName() async throws {
        let store = try makeStore()
        let notes = try await makeNotebook("Mechanics", in: store)
        let package = store.root.package(notes.id)
        try FileManager.default.moveItem(at: package, to: package.deletingPathExtension().appendingPathExtension(StorageRoot.legacyPackageExtension))
        let backup = try LibraryBackup.create(root: store.root)
        addTeardownBlock { try? FileManager.default.removeItem(at: backup.deletingLastPathComponent()) }

        let fresh = try makeStore()
        let summary = try await fresh.restoreBackup(from: backup)
        XCTAssertEqual(summary.added, 1)
        XCTAssertEqual(summary.copies + summary.unchanged + summary.unreadable, 0)
        XCTAssertEqual(fresh.root.packageIDs(), [notes.id])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fresh.root.library.path(percentEncoded: false)).filter { $0.hasSuffix(".\(StorageRoot.legacyPackageExtension)") }, [],
                       "nothing keeps the old name")
        XCTAssertEqual(fresh.record(notes.id)?.title, "Mechanics")
        let restored = NotebookPackage(root: fresh.root, id: notes.id)
        guard case .ink(let ink, _) = await restored.readInk(notes.pages[0].id) else { return XCTFail("the ink didn't come back") }
        XCTAssertEqual(ink.strokes.count, 1)
        XCTAssertTrue(LibraryIndex.notebookIDs(matching: "momentum", in: fresh.context).contains(notes.id), "recognised text is restored and searchable")

        let again = try await fresh.restoreBackup(from: backup)
        XCTAssertEqual(again.unchanged, 1, "restoring the same backup twice adds nothing")
    }

    func testAFileThatIsNotABackupChangesNothing() async throws {
        let store = try makeStore()
        _ = try await makeNotebook("Mechanics", in: store)
        let junk = FileManager.default.temporaryDirectory.appending(path: "junk-\(UUID().uuidString).owllunabackup")
        try Data("not an archive".utf8).write(to: junk)
        addTeardownBlock { try? FileManager.default.removeItem(at: junk) }
        do {
            _ = try await store.restoreBackup(from: junk)
            XCTFail("a file that isn't a backup was accepted")
        } catch {
            XCTAssertEqual(error.localizedDescription, LibraryBackup.Failure.notABackup.localizedDescription)
        }
        XCTAssertEqual(try store.context.fetchCount(FetchDescriptor<NotebookRecord>()), 1)
    }

    func testPagesExportAsImages() async throws {
        let store = try makeStore()
        let manifest = try await makeNotebook("Lab: 1/2", in: store, pages: 3)
        let job = try await ExportJob.forNotebook(manifest.id, root: store.root, format: .images)
        let deadline = Date().addingTimeInterval(30)
        while case .running = job.state, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        guard case .finished(let urls) = job.state else { return XCTFail("export ended as \(job.state)") }
        addTeardownBlock { if let first = urls.first { try? FileManager.default.removeItem(at: first.deletingLastPathComponent()) } }
        XCTAssertEqual(urls.map(\.lastPathComponent), ["Lab- 1-2 1.png", "Lab- 1-2 2.png", "Lab- 1-2 3.png"])
        let image = try XCTUnwrap(UIImage(contentsOfFile: urls[0].path(percentEncoded: false)))
        XCTAssertEqual(image.cgImage?.width, 1224, "twice the page's 612 points")
        XCTAssertEqual(image.cgImage?.height, 1584)
        XCTAssertEqual(job.progress, 1)
    }
}
