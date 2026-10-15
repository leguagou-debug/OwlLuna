import XCTest
import PencilKit
@testable import OwlLuna

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
        try await LibrarySync.run(root: root, cloud: cloud, take: { !busy.contains($0) })
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

    func testADeleteDoesNotRemoveWritingAnotherDeviceAlreadySynced() async throws {
        let notes = try await makeNotebook("Notes", on: a)
        try await sync(a)
        try await sync(b)

        try await edit(notes.id, on: b, title: "Notes, written in", strokes: 4, after: 60)
        try await sync(b)
        try FileManager.default.removeItem(at: a.package(notes.id))
        let report = try await sync(a)
        XCTAssertEqual(report.removedThere, [], "the synced copy changed since this device last saw it, so the delete doesn't carry")
        XCTAssertEqual(report.pulled, [notes.id], "and the newer writing comes here instead")
        XCTAssertFalse(FileManager.default.fileExists(atPath: cloud.tombstone(notes.id).path(percentEncoded: false)))
        let arrived = await strokes(notes, on: a)
        XCTAssertEqual(arrived, 4)

        let other = try await sync(b)
        XCTAssertEqual(other, SyncReport(), "nothing is removed on the device that wrote it")
        let onB = await titles(on: b)
        XCTAssertEqual(onB, ["Notes, written in"])
    }

    func testAMarkerLeftBesideANotebookWrittenInSinceIsClearedAway() async throws {
        let notes = try await makeNotebook("Notes", on: a)
        try await sync(a)
        try await sync(b)
        // A delete on another device that got as far as its marker and no further.
        try Data().write(to: cloud.tombstone(notes.id))
        try await edit(notes.id, on: b, strokes: 4, after: 60)
        let report = try await sync(b)
        XCTAssertEqual(report.pushed, [notes.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: cloud.tombstone(notes.id).path(percentEncoded: false)), "writing wins, so the marker goes")

        let fresh = temporaryRoot(self)
        let arrived = try await LibrarySync.run(root: fresh, cloud: cloud)
        XCTAssertEqual(arrived.pulled, [notes.id], "and a device new to the library receives the notebook rather than finishing the delete")
        try await sync(a)
        try await settled()
        XCTAssertEqual(b.packageIDs(), [notes.id])
    }

    // MARK: A delete made on a view of iCloud that was behind

    private func marked(_ id: UUID) -> Bool {
        FileManager.default.fileExists(atPath: cloud.tombstone(id).path(percentEncoded: false))
    }

    /// One device's own view of the synced copy as it stands now, which hears nothing more from iCloud.
    private func staleView() throws -> CloudFolder {
        let url = temporaryRoot(self).url.appending(path: "view", directoryHint: .isDirectory)
        try FileManager.default.copyItem(at: cloud.url, to: url)
        return CloudFolder(url: url)
    }

    /// A delete made on such a view reaches the synced copy: its marker always, and the removal when that is what iCloud keeps.
    private func deliverDelete(of id: UUID, from view: CloudFolder, removing: Bool) throws {
        try? FileManager.default.removeItem(at: cloud.tombstone(id))
        try FileManager.default.copyItem(at: view.tombstone(id), to: cloud.tombstone(id))
        if removing { try FileManager.default.removeItem(at: cloud.package(id)) }
    }

    /// Two devices in step, then written in on the second and synced, then deleted on the first before it heard of that.
    private func deletedBeforeSyncedWritingArrived() async throws -> (notes: NotebookManifest, view: CloudFolder) {
        let notes = try await makeNotebook("Notes", on: a)
        try await sync(a)
        try await sync(b)
        let view = try staleView()
        try await edit(notes.id, on: b, title: "Notes, written in", strokes: 4, after: 60)
        try await sync(b)
        try FileManager.default.removeItem(at: a.package(notes.id))
        let deleting = try await LibrarySync.run(root: a, cloud: view)
        XCTAssertEqual(deleting.removedThere, [notes.id])
        return (notes, view)
    }

    func testADeleteMadeBeforeSyncedWritingArrivedDoesNotRemoveIt() async throws {
        let (notes, view) = try await deletedBeforeSyncedWritingArrived()
        try deliverDelete(of: notes.id, from: view, removing: true)

        let report = try await sync(b)
        XCTAssertEqual(report.removedHere, [], "the marker is for a version from before this writing")
        XCTAssertEqual(report.pushed, [notes.id], "so the writing goes back up")
        XCTAssertFalse(marked(notes.id))
        let kept = await strokes(notes, on: b)
        XCTAssertEqual(kept, 4)

        let back = try await sync(a)
        XCTAssertEqual(back.pulled, [notes.id], "and comes back to the device that deleted the older version")
        let onA = await titles(on: a)
        XCTAssertEqual(onA, ["Notes, written in"])
        try await settled()
    }

    func testAMarkerForAnOlderVersionDoesNotRemoveTheNewerOneBesideIt() async throws {
        let (notes, view) = try await deletedBeforeSyncedWritingArrived()
        // iCloud keeps the upload, so the marker sits beside the newer version.
        try deliverDelete(of: notes.id, from: view, removing: false)
        let inStep = try await sync(b)
        XCTAssertEqual(inStep, SyncReport())
        XCTAssertFalse(marked(notes.id), "a marker for another version is cleared, in step or not")

        try deliverDelete(of: notes.id, from: view, removing: false)
        let fresh = temporaryRoot(self)
        let arrived = try await LibrarySync.run(root: fresh, cloud: cloud)
        XCTAssertEqual(arrived.pulled, [notes.id], "a device new to the library receives the notebook rather than finishing that delete")
        XCTAssertTrue(isSynced(notes.id))

        try deliverDelete(of: notes.id, from: view, removing: false)
        let back = try await sync(a)
        XCTAssertEqual(back.pulled, [notes.id], "and so does the device that deleted the older version")
        XCTAssertTrue(isSynced(notes.id))
        XCTAssertFalse(marked(notes.id))
        let count = await strokes(notes, on: a)
        XCTAssertEqual(count, 4)
        try await settled()
    }

    func testADeleteThatGotAsFarAsItsMarkerIsFinishedByTheNextDevice() async throws {
        let notes = try await makeNotebook("Notes", on: a)
        try await sync(a)
        try await sync(b)
        let view = try staleView()
        try FileManager.default.removeItem(at: a.package(notes.id))
        _ = try await LibrarySync.run(root: a, cloud: view)
        try deliverDelete(of: notes.id, from: view, removing: false)

        let inStep = try await sync(b)
        XCTAssertEqual(inStep, SyncReport())
        XCTAssertTrue(marked(notes.id), "a marker for the version beside it stands")
        let fresh = temporaryRoot(self)
        let arrived = try await LibrarySync.run(root: fresh, cloud: cloud)
        XCTAssertEqual(arrived.pulled, [])
        XCTAssertFalse(isSynced(notes.id), "and a device that never had the notebook finishes the delete")
        let report = try await sync(b)
        XCTAssertEqual(report.removedHere, [notes.id])
    }

    func testAnEmptyMarkerFromAnOlderBuildStillCarriesADelete() async throws {
        let old = try await makeNotebook("Old", on: a), kept = try await makeNotebook("Kept", on: a)
        try await sync(a)
        try await sync(b)
        for id in [old.id, kept.id] {
            try Data().write(to: cloud.tombstone(id))
            try FileManager.default.removeItem(at: cloud.package(id))
        }
        try await edit(kept.id, on: b, strokes: 4, after: 60)
        let report = try await sync(b)
        XCTAssertEqual(report.removedHere, [old.id])
        XCTAssertEqual(report.pushed, [kept.id])
    }

    /// A notebook in Recently Deleted on both devices, put there 40 days ago, and in step.
    private func longDeleted() async throws -> NotebookManifest {
        let notes = try await makeNotebook("Notes", on: a, strokes: 2)
        try await sync(a)
        try await sync(b)
        let longAgo = Date.now.addingTimeInterval(-40 * 86_400)
        try await file(notes.id, on: a, at: longAgo) { $0.deletedAt = longAgo }
        try await sync(a)
        try await sync(b)
        try await settled()
        return notes
    }

    func testARestoreTheDeletingDeviceHadNotReceivedIsKept() async throws {
        let notes = try await longDeleted()
        // Taken back out on the second device, which hasn't synced since.
        try await file(notes.id, on: b, at: .now) { $0.deletedAt = nil }
        // Its 30 days are up on the first, which removes it for good and carries that over.
        try FileManager.default.removeItem(at: a.package(notes.id))
        let purged = try await sync(a)
        XCTAssertEqual(purged.removedThere, [notes.id])

        let report = try await sync(b)
        XCTAssertEqual(report.removedHere, [], "a restore the deleting device never heard of is kept, as writing would be")
        XCTAssertEqual(report.pushed, [notes.id])
        XCTAssertFalse(marked(notes.id))
        let back = try await sync(a)
        XCTAssertEqual(back.pulled, [notes.id])
        for root in [a!, b!] {
            let state = try await library(notes.id, on: root)
            XCTAssertNil(state.deletedAt)
            let count = await strokes(notes, on: root)
            XCTAssertEqual(count, 2)
        }
        try await settled()
    }

    func testADeleteDoesNotCarryOverARestoreAlreadyInTheSyncedCopy() async throws {
        let notes = try await longDeleted()
        try await file(notes.id, on: b, at: .now) { $0.deletedAt = nil }
        let restored = try await sync(b)
        XCTAssertEqual(restored.stateSent, [notes.id])
        // The first device's 30 days ran out on what it knew before that restore reached it.
        try FileManager.default.removeItem(at: a.package(notes.id))

        let report = try await sync(a)
        XCTAssertEqual(report.removedThere, [], "the notebook was taken back out since this device last saw it, so the delete doesn't carry")
        XCTAssertEqual(report.pulled, [notes.id])
        XCTAssertFalse(marked(notes.id))
        let state = try await library(notes.id, on: a)
        XCTAssertNil(state.deletedAt)
        let other = try await sync(b)
        XCTAssertEqual(other, SyncReport(), "and nothing is removed on the device that restored it")
        XCTAssertEqual(b.packageIDs(), [notes.id])
    }

    func testADeleteForGoodFromRecentlyDeletedStillCarriesOver() async throws {
        let synced = try await longDeleted(), unsynced = try await makeNotebook("Unsynced", on: a)
        try await sync(a)
        try await sync(b)
        // One went into Recently Deleted on both devices; the other is deleted for good before that was ever synced.
        try await file(unsynced.id, on: a, at: .now) { $0.deletedAt = .now }
        for id in [synced.id, unsynced.id] { try FileManager.default.removeItem(at: a.package(id)) }
        let report = try await sync(a)
        XCTAssertEqual(Set(report.removedThere), [synced.id, unsynced.id])
        let other = try await sync(b)
        XCTAssertEqual(Set(other.removedHere), [synced.id, unsynced.id])
        XCTAssertEqual(b.packageIDs(), [])
    }

    // MARK: A pass and what changes while it runs

    private func sorted(_ manifests: [NotebookManifest]) -> [UUID] { manifests.map(\.id).sorted { $0.uuidString < $1.uuidString } }

    private func isSynced(_ id: UUID) -> Bool {
        FileManager.default.fileExists(atPath: cloud.package(id).appending(path: "manifest.json").path(percentEncoded: false))
    }

    func testEachNotebookIsAskedForWhenItsTurnComes() async throws {
        let ids = sorted([try await makeNotebook("One", on: a), try await makeNotebook("Two", on: a), try await makeNotebook("Three", on: a)])
        // The last one is opened in an editor while the pass is busy with the first, and is open by the time that is done.
        let open = Shared<Set<UUID>>([]), log = Shared<[String]>([]), released = Shared<[UUID]>([])
        let report = try await LibrarySync.run(root: a, cloud: cloud, take: { id in
            log.value.append("take \(id)")
            return !open.value.contains(id)
        }, release: { id in
            log.value.append("release \(id)")
            released.value.append(id)
            if id == ids[0] { open.value.insert(ids[2]) }
        })
        XCTAssertEqual(log.value, ["take \(ids[0])", "release \(ids[0])", "take \(ids[1])", "release \(ids[1])", "take \(ids[2])"],
                       "each in its turn, not all as the pass begins")
        XCTAssertEqual(report.pushed, [ids[0], ids[1]])
        XCTAssertEqual(report.waiting, [ids[2]], "so one opened since is still left alone")
        XCTAssertFalse(isSynced(ids[2]))
        XCTAssertEqual(released.value, [ids[0], ids[1]], "and what was taken is handed back")
    }

    func testAPassStopsWhenAnotherAccountSignsInPartWay() async throws {
        let ids = sorted([try await makeNotebook("One", on: a), try await makeNotebook("Two", on: a), try await makeNotebook("Three", on: a)])
        let signedIn = Shared<String?>("one"), released = Shared<[UUID]>([])
        do {
            _ = try await LibrarySync.run(root: a, cloud: cloud, account: "one", take: { id in
                if id == ids[0] { signedIn.value = "two" }
                return true
            }, release: { released.value.append($0) }, signedIn: { signedIn.value })
            XCTFail("the container now belongs to another account")
        } catch {
            let stopped = error as? StoppedPass
            XCTAssertEqual(stopped?.reason as? SyncError, .accountChanged)
            XCTAssertEqual(stopped?.report.pushed, [ids[0]], "what the pass did before it stopped is handed back")
        }
        XCTAssertTrue(isSynced(ids[0]), "the notebook in hand is finished")
        XCTAssertEqual(released.value, [ids[0]])
        XCTAssertFalse(isSynced(ids[1]) || isSynced(ids[2]), "and nothing more is copied")
        let state = SyncState.read(a)
        XCTAssertEqual(Array(state.notebooks.keys), [ids[0]], "what was sent is kept as agreed")
        XCTAssertEqual(state.copy, try String(contentsOf: cloud.copyFile, encoding: .utf8), "with the copy the pass began with, and no other account's")
        XCTAssertEqual(state.account, "one", "and whose copy that was is kept, so the other account is asked about")
    }

    func testAPassThatIsCancelledStopsBeforeTheNextNotebook() async throws {
        let ids = sorted([try await makeNotebook("One", on: a), try await makeNotebook("Two", on: a)])
        let pass = Shared<Task<SyncReport, Error>?>(nil), cloud = cloud!, a = a!
        let task = Task.detached {
            try await LibrarySync.run(root: a, cloud: cloud, take: { id in
                if id == ids[0] { pass.value?.cancel() }
                return true
            })
        }
        pass.value = task
        do {
            _ = try await task.value
            XCTFail("a cancelled pass doesn't finish")
        } catch {
            XCTAssertTrue((error as? StoppedPass)?.reason is CancellationError)
        }
        XCTAssertFalse(isSynced(ids[1]))
    }

    func testAPassStoppedPartWayRemembersWhatItDid() async throws {
        let ids = sorted([try await makeNotebook("One", on: a), try await makeNotebook("Two", on: a)])
        try await sync(a)
        let signedIn = Shared<String?>("one")
        do {
            _ = try await LibrarySync.run(root: b, cloud: cloud, account: "one", take: { id in
                if id == ids[0] { signedIn.value = "two" }
                return true
            }, signedIn: { signedIn.value })
            XCTFail("the container now belongs to another account")
        } catch {
            XCTAssertEqual((error as? StoppedPass)?.report.pulled, [ids[0]])
        }
        XCTAssertEqual(b.packageIDs(), [ids[0]], "the first notebook arrived before the pass stopped")
        XCTAssertNotNil(SyncState.read(b).notebooks[ids[0]], "and is kept as agreed, though the pass never reached its end")

        // Deleted here afterwards, it is a delete and not a notebook this device has yet to receive.
        try FileManager.default.removeItem(at: b.package(ids[0]))
        let report = try await LibrarySync.run(root: b, cloud: cloud, account: "one")
        XCTAssertEqual(report.removedThere, [ids[0]])
        XCTAssertEqual(report.pulled, [ids[1]])
    }

    func testAConflictInAPassThatWasStoppedIsNotCopiedTwice() async throws {
        let notes = try await makeNotebook("Notes", on: a), other = try await makeNotebook("Other", on: a)
        try await sync(a)
        try await sync(b)
        try await edit(notes.id, on: a, strokes: 7, after: 120)
        try await edit(notes.id, on: b, strokes: 3, after: 60)
        try await sync(a)
        // The copy is made, the newer version can't be pulled yet, and then the pass is stopped before its end.
        let ink = try inkFile(of: notes.id)
        try permit(0o000, ink)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: ink.path(percentEncoded: false)) }
        let last = sorted([notes, other])[1], signedIn = Shared<String?>(nil)
        do {
            _ = try await LibrarySync.run(root: b, cloud: cloud, release: { if $0 == last { signedIn.value = "another" } }, signedIn: { signedIn.value })
            XCTFail("the container now belongs to another account")
        } catch {
            XCTAssertEqual((error as? StoppedPass)?.report.conflictCopies.count, 1)
        }
        XCTAssertEqual(b.packageIDs().count, 3)

        try permit(0o644, ink)
        let report = try await sync(b)
        XCTAssertEqual(report.conflictCopies, [], "the copy made by the pass that was stopped is the only one")
        XCTAssertEqual(report.pulled, [notes.id])
        XCTAssertEqual(b.packageIDs().count, 3)
        let onB = try await shelf(b)
        XCTAssertEqual(onB, ["Notes": 7, "Notes (conflicted copy)": 3, "Other": 1])
    }

    func testAPassThatHasToWaitForTheFoldersCopiesNothing() async throws {
        try fill(a)
        try await sync(a)
        try await sync(b)
        let new = try await makeNotebook("New", on: b)
        let foldersFile = cloud.foldersFile
        try permit(0o000, foldersFile)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: foldersFile.path(percentEncoded: false)) }
        do {
            try await sync(b)
            XCTFail("folders that can't be read yet aren't merged")
        } catch {
            XCTAssertEqual(error as? SyncError, .stillArriving)
        }
        XCTAssertFalse(isSynced(new.id), "a pass that can't reach its end sends nothing")

        // Deleted before the folders arrive, the notebook doesn't come back from the synced copy.
        try FileManager.default.removeItem(at: b.package(new.id))
        try permit(0o644, foldersFile)
        let report = try await sync(b)
        XCTAssertEqual(report.pulled, [])
        XCTAssertEqual(b.packageIDs(), [])
    }

    // MARK: An upload cut short

    private func firstInk(of id: UUID, on root: StorageRoot) throws -> URL {
        let ink = root.package(id).appending(path: "ink", directoryHint: .isDirectory)
        return try XCTUnwrap(FileManager.default.contentsOfDirectory(at: ink, includingPropertiesForKeys: nil).first)
    }

    /// The synced copy as a pass killed part-way through an upload left it: the pages, and no manifest.
    private func cutShortUpload(of id: UUID, from root: StorageRoot) throws {
        try FileManager.default.createDirectory(at: cloud.library, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: root.package(id), to: cloud.package(id))
        for name in ["manifest.json", "thumbs"] { try FileManager.default.removeItem(at: cloud.package(id).appending(path: name)) }
    }

    func testAnUploadCutShortIsSentAgain() async throws {
        let notes = try await makeNotebook("Notes", on: a, strokes: 2)
        try cutShortUpload(of: notes.id, from: a)
        let report = try await sync(a)
        XCTAssertEqual(report.waiting, [], "a package with no manifest, and none on its way, isn't waited on for ever")
        XCTAssertEqual(report.pushed, [notes.id])
        let arrived = try await sync(b)
        XCTAssertEqual(arrived.pulled, [notes.id])
        let count = await strokes(notes, on: b)
        XCTAssertEqual(count, 2)
        try await settled()
    }

    func testAPackageWhoseManifestIsStillOnItsWayIsWaitedFor() async throws {
        let notes = try await makeNotebook("Notes", on: a, strokes: 2)
        try cutShortUpload(of: notes.id, from: a)
        try Data().write(to: cloud.package(notes.id).appending(path: ".manifest.json.icloud"))
        let report = try await sync(a)
        XCTAssertEqual(report.waiting, [notes.id])
        XCTAssertEqual(report.pushed, [], "nothing is copied over a notebook whose manifest iCloud hasn't brought down yet")
    }

    func testAFailedUploadLeavesNothingUnderTheNotebooksName() async throws {
        let notes = try await makeNotebook("Notes", on: a, strokes: 2)
        let ink = try firstInk(of: notes.id, on: a)
        try permit(0o000, ink)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: ink.path(percentEncoded: false)) }
        let failed = try await sync(a)
        XCTAssertEqual(failed.waiting, [notes.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: cloud.package(notes.id).path(percentEncoded: false)),
                       "a notebook new to the synced copy appears there whole or not at all")
        let other = try await sync(b)
        XCTAssertEqual(other, SyncReport(), "so no other device is left waiting on it")

        try permit(0o644, ink)
        let report = try await sync(a)
        XCTAssertEqual(report.pushed, [notes.id])
        let arrived = try await sync(b)
        XCTAssertEqual(arrived.pulled, [notes.id])
        try await settled()
    }

    func testAnUploadLeftBehindByAQuitIsClearedAwayOnceItIsOld() async throws {
        let notes = try await makeNotebook("Notes", on: a)
        try await sync(a)
        // Two uploads cut short: one from hours ago, and one that may be another device's, still under way.
        let old = cloud.upload(UUID()), recent = cloud.upload(UUID())
        for url in [old, recent] { try FileManager.default.copyItem(at: a.package(notes.id), to: url) }
        try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(-7200)], ofItemAtPath: old.path(percentEncoded: false))

        let report = try await sync(b)
        XCTAssertEqual(report.pulled, [notes.id], "neither is taken for a notebook")
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path(percentEncoded: false)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recent.path(percentEncoded: false)))
    }

    // MARK: A conflict that can't be finished

    private func permit(_ mode: Int, _ url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path(percentEncoded: false))
    }

    private func inkFile(of id: UUID) throws -> URL {
        let ink = cloud.package(id).appending(path: "ink", directoryHint: .isDirectory)
        return try XCTUnwrap(FileManager.default.contentsOfDirectory(at: ink, includingPropertiesForKeys: nil).first)
    }

    /// Every notebook on the device is whole and named by its own ID: the titles, and how much is written in each.
    private func shelf(_ root: StorageRoot, file: StaticString = #filePath, line: UInt = #line) async throws -> [String: Int] {
        var result: [String: Int] = [:]
        for id in root.packageIDs() {
            let manifest = try await NotebookPackage(root: root, id: id).readManifest().manifest
            XCTAssertEqual(manifest.id, id, "a notebook is never left under another's ID", file: file, line: line)
            result[manifest.title] = await strokes(manifest, on: root)
        }
        return result
    }

    func testTheNewerVersionInTheSyncedCopyWinsAConflict() async throws {
        let notes = try await makeNotebook("Notes", on: a)
        try await sync(a)
        try await sync(b)

        try await edit(notes.id, on: a, strokes: 7, after: 120)
        try await edit(notes.id, on: b, strokes: 3, after: 60)
        try await sync(a)
        let report = try await sync(b)
        XCTAssertEqual(report.conflictCopies.count, 1)
        XCTAssertEqual(report.pulled, [notes.id], "the newer version comes in under the notebook's ID")
        let onB = try await shelf(b)
        XCTAssertEqual(onB, ["Notes": 7, "Notes (conflicted copy)": 3], "and what was written here is kept beside it")

        try await sync(b)
        try await sync(a)
        let onA = try await shelf(a)
        XCTAssertEqual(onA, ["Notes": 7, "Notes (conflicted copy)": 3])
        try await settled()
    }

    func testAConflictWhosePullFailsLeavesTheNotebookInItsPlace() async throws {
        let notes = try await makeNotebook("Notes", on: a)
        try await sync(a)
        try await sync(b)

        try await edit(notes.id, on: a, strokes: 7, after: 120)
        try await edit(notes.id, on: b, strokes: 3, after: 60)
        try await sync(a)
        // The newer version is in the synced copy, but one of its pages can't be read.
        let ink = try inkFile(of: notes.id)
        try permit(0o000, ink)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: ink.path(percentEncoded: false)) }

        let failed = try await sync(b)
        XCTAssertEqual(failed.waiting, [notes.id])
        XCTAssertEqual(failed.pulled, [])
        let kept = try await shelf(b)
        XCTAssertEqual(kept["Notes"], 3, "the notebook is still where it was, with what was written here")

        try permit(0o644, ink)
        let report = try await sync(b)
        XCTAssertEqual(report.pulled, [notes.id])
        XCTAssertEqual(report.removedThere, [], "a pull that failed is never taken for a delete")
        XCTAssertEqual(report.conflictCopies, [], "the copy was made by the pass that failed, and isn't made again")
        XCTAssertEqual(b.packageIDs().count, 2)
        let onB = try await shelf(b)
        XCTAssertEqual(onB, ["Notes": 7, "Notes (conflicted copy)": 3], "one copy is kept, however often it had to try")
        try await sync(b)
        try await sync(a)
        let onA = try await shelf(a)
        XCTAssertEqual(onA, ["Notes": 7, "Notes (conflicted copy)": 3])
    }

    func testAConflictWhosePushFailsLeavesNoHalfMadeCopy() async throws {
        let notes = try await makeNotebook("Notes", on: a)
        try await sync(a)
        try await sync(b)

        try await edit(notes.id, on: a, strokes: 3, after: 60)
        try await edit(notes.id, on: b, strokes: 7, after: 120)
        try await sync(a)
        // The older version is in the synced copy, where its manifest can't be replaced.
        let synced = cloud.package(notes.id)
        try permit(0o555, synced)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: synced.path(percentEncoded: false)) }

        let failed = try await sync(b)
        XCTAssertEqual(failed.waiting, [notes.id])
        XCTAssertEqual(failed.pushed, [])
        let kept = try await shelf(b)
        XCTAssertEqual(kept["Notes"], 7)
        XCTAssertEqual(kept.filter { $0.key != "Notes" }, ["Notes (conflicted copy)": 3], "the older version is kept whole before anything is sent over it")

        try permit(0o755, synced)
        let report = try await sync(b)
        XCTAssertTrue(report.pushed.contains(notes.id))
        XCTAssertEqual(report.conflictCopies, [], "and it isn't copied a second time")
        try await sync(a)
        let onA = try await shelf(a)
        XCTAssertEqual(onA, ["Notes": 7, "Notes (conflicted copy)": 3])
        try await settled()
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

        // Locked on the device with the newer pages: the copy is made from the other's files, which never had the lock.
        try await file(diary.id, on: b, at: .now) { $0.isLocked = true }
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

    private func syncedLibrary(_ id: UUID) throws -> LibraryState {
        try ManifestCodec.decode(Data(contentsOf: cloud.package(id).appending(path: "manifest.json")), fallbackID: id).manifest.library
    }

    func testAStampInTheSyncedCopyNeverMovesBackwards() async throws {
        let diary = try await makeNotebook("Diary", on: a), c = temporaryRoot(self)
        let locked = Date.now, relocked = locked.addingTimeInterval(60)
        try await file(diary.id, on: a, at: locked) { $0.isLocked = true }
        try await sync(a)
        try await sync(b)
        _ = try await LibrarySync.run(root: c, cloud: cloud)

        // Unlocked on a third device that then stays out of reach, and on the second, which locks it again afterwards.
        try await file(diary.id, on: c, at: locked.addingTimeInterval(30)) { $0.isLocked = false }
        try await file(diary.id, on: b, at: locked.addingTimeInterval(40)) { $0.isLocked = false }
        try await file(diary.id, on: b, at: relocked) {
            $0.isLocked = true
            $0.isFavorite = true
        }
        try await sync(b)
        XCTAssertEqual(try XCTUnwrap(syncedLibrary(diary.id).changedAt(.locked)).timeIntervalSince(relocked), 0, accuracy: 0.001)

        // The first device still has the lock under its first stamp, and changes something else.
        try await file(diary.id, on: a, at: relocked.addingTimeInterval(60)) { $0.tags = ["private"] }
        let report = try await sync(a)
        XCTAssertEqual(report.stateSent, [diary.id])
        XCTAssertEqual(try XCTUnwrap(syncedLibrary(diary.id).changedAt(.locked)).timeIntervalSince(relocked), 0, accuracy: 0.001,
                       "sending the tags doesn't put the lock's stamp back")

        _ = try await LibrarySync.run(root: c, cloud: cloud)
        try await sync(a)
        try await sync(b)
        for root in [a!, b!, c] {
            let state = try await library(diary.id, on: root)
            XCTAssertTrue(state.isLocked, "so an unlock from before the lock was put back doesn't take it off")
            XCTAssertEqual(state.tags, ["private"])
        }
    }

    func testWritingTheDeletingDeviceHadNotSeenComesOutOfRecentlyDeleted() async throws {
        let notes = try await makeNotebook("Notes", on: a), unread = try await makeNotebook("Unread", on: a)
        try await sync(a)
        try await sync(b)

        let trashed = Date.now
        for id in [notes.id, unread.id] { try await file(id, on: a, at: trashed) { $0.deletedAt = trashed } }
        try await sync(a)
        // Written in on a device that hasn't heard it was deleted.
        try await edit(notes.id, on: b, strokes: 4, after: 60)
        let report = try await sync(b)
        XCTAssertEqual(report.pushed, [notes.id])
        XCTAssertEqual(report.stateReceived, [unread.id], "a notebook nobody wrote in follows into Recently Deleted")
        let written = try await library(notes.id, on: b), untouched = try await library(unread.id, on: b)
        XCTAssertNil(written.deletedAt, "one just written in doesn't: writing wins, as it does over a permanent delete")
        XCTAssertNotNil(untouched.deletedAt)

        let back = try await sync(a)
        XCTAssertEqual(back.pulled, [notes.id])
        let restored = try await library(notes.id, on: a)
        XCTAssertNil(restored.deletedAt, "and it comes back out on the device that deleted it")
        let count = await strokes(notes, on: a)
        XCTAssertEqual(count, 4)
        try await settled()

        // Deleted again by a device that has the writing, it stays deleted.
        let again = Date.now.addingTimeInterval(120)
        try await file(notes.id, on: a, at: again) { $0.deletedAt = again }
        try await sync(a)
        try await sync(b)
        let gone = try await library(notes.id, on: b)
        XCTAssertNotNil(gone.deletedAt)
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
        XCTAssertEqual(report.removedHere, [old.id], "a notebook deleted on the other device still goes: its marker says so")
        XCTAssertEqual(FolderFile.read(a).folders.map(\.name), ["Science"], "a folder is kept, since the copy could as well have been erased and filled again")
        XCTAssertEqual(SyncState.read(a).copy, SyncState.read(b).copy)
        try await sync(b)
        XCTAssertEqual(FolderFile.read(b).folders.map(\.name), ["Science"])
    }

    func testAnErasedCopyDeletesNothingOnADeviceFromBeforeCopiesWereNamed() async throws {
        let physics = try await makeNotebook("Physics", on: a)
        try fill(a)
        try await sync(a)
        // As an older build left the device, and then the copy in iCloud was erased.
        var state = SyncState.read(a)
        state.copy = nil
        try state.write(a)
        try FileManager.default.removeItem(at: cloud.url)

        let report = try await sync(a)
        XCTAssertTrue(report.startedAgain, "an empty copy that was never named isn't the one this device agreed with")
        XCTAssertEqual(report.pushed, [physics.id])
        XCTAssertEqual(FolderFile.read(a).folders.map(\.name), ["Science"], "so its folders")
        XCTAssertEqual(stickers(in: a.stickers), ["cat.png"], "and stickers were never deleted")
        XCTAssertEqual(stickers(in: cloud.stickers), ["cat.png"])
    }

    func testACopyRefilledByAnotherDeviceDeletesNothingOnADeviceFromBeforeCopiesWereNamed() async throws {
        try fill(a)
        try await sync(a)
        try await sync(b)
        try fill(a, folder: "Art", sticker: "dog.png")
        try await sync(a)
        // As an older build left the first device. Then the copy was erased, and the second filled it again first.
        var state = SyncState.read(a)
        state.copy = nil
        try state.write(a)
        try FileManager.default.removeItem(at: cloud.url)
        try await sync(b)
        XCTAssertEqual(stickers(in: cloud.stickers), ["cat.png"])

        try await sync(a)
        XCTAssertEqual(FolderFile.read(a).folders.map(\.name).sorted(), ["Art", "Science"], "a folder missing from a copy this device never agreed with was not deleted")
        XCTAssertEqual(stickers(in: a.stickers), ["cat.png", "dog.png"])
        try await sync(b)
        XCTAssertEqual(FolderFile.read(b).folders.map(\.name).sorted(), ["Art", "Science"])
        XCTAssertEqual(stickers(in: b.stickers), ["cat.png", "dog.png"])
    }

    func testAFreshStartIsSavedBeforeTheCopyIsNamed() async throws {
        try await makeNotebook("Physics", on: a)
        try fill(a)
        try await sync(a)
        var state = SyncState.read(a)
        state.copy = nil
        try state.write(a)
        // The copy was erased, and this pass gets no further than trying to name the new one.
        try FileManager.default.removeItem(at: cloud.url)
        for directory in [cloud.library, cloud.tombstones] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        let container = cloud.url
        try permit(0o555, container)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: container.path(percentEncoded: false)) }
        do {
            try await sync(a)
            XCTFail("the copy can't be named")
        } catch {}
        XCTAssertFalse(SyncState.read(a).holdsAnything, "what was agreed with the erased copy is forgotten before the new one has a name to be taken for it")
    }

    func testAFileStillOnItsWayDownIsWaitedForAndNotTakenAsMissing() async throws {
        try await makeNotebook("Physics", on: a)
        try fill(a)
        try await sync(a)
        try await sync(b)
        // iCloud lists a file it hasn't downloaded as ".<name>.icloud", with nothing under the name itself.
        for file in [cloud.copyFile, cloud.foldersFile] {
            let placeholder = file.deletingLastPathComponent().appending(path: ".\(file.lastPathComponent).icloud")
            try FileManager.default.moveItem(at: file, to: placeholder)
            do {
                try await sync(b)
                XCTFail("\(file.lastPathComponent) hasn't arrived")
            } catch {
                XCTAssertEqual(error as? SyncError, .stillArriving)
            }
            try FileManager.default.moveItem(at: placeholder, to: file)
        }
        XCTAssertEqual(FolderFile.read(b).folders.map(\.name), ["Science"], "a folder isn't deleted because its list was still coming down")
        let report = try await sync(b)
        XCTAssertEqual(report, SyncReport(), "and the copy is still the one this device knew")
    }

    func testACopyIDThatCannotBeReadIsWaitedForAndNotReplaced() async throws {
        try await makeNotebook("Physics", on: a)
        try await sync(a)
        try await sync(b)
        let name = try String(contentsOf: cloud.copyFile, encoding: .utf8)
        let copyFile = cloud.copyFile
        try permit(0o000, copyFile)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: copyFile.path(percentEncoded: false)) }

        do {
            try await sync(a)
            XCTFail("a copy whose name can't be read yet isn't synced with")
        } catch {
            XCTAssertEqual(error as? SyncError, .stillArriving)
        }
        try permit(0o644, copyFile)
        XCTAssertEqual(try String(contentsOf: copyFile, encoding: .utf8), name, "and it isn't given a new name, which every device would take for another copy")
        let report = try await sync(b)
        XCTAssertFalse(report.startedAgain)
    }

    func testFoldersThatCannotBeReadAreWaitedForAndNotTakenAsDeleted() async throws {
        try fill(a)
        try await sync(a)
        try await sync(b)
        let foldersFile = cloud.foldersFile
        try permit(0o000, foldersFile)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: foldersFile.path(percentEncoded: false)) }

        do {
            try await sync(b)
            XCTFail("folders that can't be read yet aren't merged")
        } catch {
            XCTAssertEqual(error as? SyncError, .stillArriving)
        }
        XCTAssertEqual(FolderFile.read(b).folders.map(\.name), ["Science"], "a folder isn't deleted here because its list couldn't be read")
        try permit(0o644, foldersFile)
        try await sync(b)
        try await sync(a)
        XCTAssertEqual(FolderFile.read(a).folders.map(\.name), ["Science"])
    }

    func testAPullInterruptedByAQuitIsClearedAway() async throws {
        let physics = try await makeNotebook("Physics", on: a)
        try await sync(a)
        let stray = b.arriving.appending(path: "\(physics.id.uuidString)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: b.arriving, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: cloud.package(physics.id), to: stray)

        LibrarySync.sweepArriving(root: b)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: b.arriving.path(percentEncoded: false)), [])
        let report = try await sync(b)
        XCTAssertEqual(report.pulled, [physics.id], "and the next pull has somewhere to assemble")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: b.arriving.path(percentEncoded: false)), [])
    }

    func testTheLaunchSweepLeavesAPullThatIsUnderWay() async throws {
        let physics = try await makeNotebook("Physics", on: a)
        try await sync(a)
        try await sync(b)
        try await edit(physics.id, on: a, strokes: 3, after: 60)
        try await sync(a)
        let fileManager = FileManager.default
        let leftOver = b.arriving.appending(path: "\(UUID().uuidString)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: leftOver, withIntermediateDirectories: true)
        try await Task.sleep(for: .milliseconds(50))
        let launched = Date.now
        try await Task.sleep(for: .milliseconds(50))

        // Another writer holds the synced notebook, so b's pull stops with its copy half-assembled in Arriving.
        let held = Shared(false), released = Shared(false)
        addTeardownBlock { released.value = true }
        let synced = cloud.package(physics.id)
        Thread.detachNewThread {
            NSFileCoordinator().coordinate(writingItemAt: synced, options: .forMerging, error: nil) { _ in
                held.value = true
                while !released.value { Thread.sleep(forTimeInterval: 0.005) }
            }
        }
        func waitUntil(_ condition: () -> Bool) async throws {
            let deadline = Date.now.addingTimeInterval(10)
            while !condition(), Date.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        }
        try await waitUntil { held.value }
        let device: StorageRoot = b, remote: CloudFolder = cloud
        let pulling = Task.detached { try await LibrarySync.run(root: device, cloud: remote) }
        func arriving() -> [String] { (try? fileManager.contentsOfDirectory(atPath: device.arriving.path(percentEncoded: false))) ?? [] }
        try await waitUntil { arriving().count == 2 }
        let underWay = arriving().filter { $0 != leftOver.lastPathComponent }
        XCTAssertEqual(underWay.count, 1, "the pull has begun")

        LibraryStore.sweepDeleted(root: device)
        LibrarySync.sweepArriving(root: device, untouchedSince: launched)
        LibraryStore.sweepUnfinished(root: device, untouchedSince: launched)
        XCTAssertEqual(arriving(), underWay, "only what a quit left before launch goes")
        XCTAssertEqual(device.packageIDs(), [physics.id])
        released.value = true
        let report = try await pulling.value
        XCTAssertEqual(report.pulled, [physics.id])
        let pulledStrokes = await strokes(physics, on: device)
        XCTAssertEqual(pulledStrokes, 3)
        XCTAssertEqual(arriving(), [])
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
