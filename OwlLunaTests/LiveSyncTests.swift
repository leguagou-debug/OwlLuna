import XCTest
import SwiftData
import os
@testable import OwlLuna

/// What syncs while a notebook is open on two devices, how far a sync has got, and the smart shelves and pens,
/// which travel apart from the notebooks.
@MainActor
final class LiveSyncTests: XCTestCase {
    private let paper = PageDefaults(template: .grid, paperColor: .white, pageSize: .letter)
    private var cloud: CloudFolder!
    private var a: StorageRoot!
    private var b: StorageRoot!
    private var defaults: UserDefaults!
    private var containers: [ModelContainer] = []

    override func setUp() async throws {
        try await super.setUp()
        a = temporaryRoot(self)
        b = temporaryRoot(self)
        cloud = CloudFolder(url: temporaryRoot(self).url)
        let suite = "owlluna-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
    }

    private func makeNotebook(_ title: String, on root: StorageRoot) async throws -> UUID {
        let manifest = NotebookManifest(title: title, defaults: paper, pages: [paper.newPage()])
        try await NotebookPackage(root: root, id: manifest.id).create(manifest)
        return manifest.id
    }

    /// One notebook both devices hold alike.
    private func shared(_ title: String) async throws -> UUID {
        let id = try await makeNotebook(title, on: a)
        _ = try await LibrarySync.run(root: a, cloud: cloud)
        _ = try await LibrarySync.run(root: b, cloud: cloud)
        return id
    }

    /// A save as an editor makes one: a new title, and pages dated `seconds` after they were.
    private func write(_ id: UUID, on root: StorageRoot, title: String, after seconds: TimeInterval) async throws {
        _ = try await NotebookPackage(root: root, id: id).updateManifest {
            $0.title = title
            $0.modifiedAt = $0.modifiedAt.addingTimeInterval(seconds)
        }
    }

    private func title(_ id: UUID, on root: StorageRoot) async throws -> String {
        try await NotebookPackage(root: root, id: id).readManifest().manifest.title
    }

    private func titles(on root: StorageRoot) async -> [String] {
        var result: [String] = []
        for id in root.packageIDs() { if let title = try? await title(id, on: root) { result.append(title) } }
        return result.sorted()
    }

    // MARK: A notebook open on two devices

    func testAnOpenNotebookIsSentWhileTheSyncedCopyHoldsWhatBothAgreedOn() async throws {
        let id = try await shared("Physics"), a = a!
        try await write(id, on: a, title: "Physics, written on A", after: 10)
        let held = OSAllocatedUnfairLock(initialState: [UUID]()), released = OSAllocatedUnfairLock(initialState: [UUID]())
        let outcome = try await LibrarySync.pushNewer(id, root: a, cloud: cloud, timeout: .zero, hold: { taken in
            held.withLock { $0.append(taken) }
            return NotebookPackage(root: a, id: taken)
        }, release: { id in released.withLock { $0.append(id) } })
        XCTAssertEqual(outcome.sent, .sent)
        XCTAssertEqual(held.withLock { $0 }, [id])
        XCTAssertEqual(released.withLock { $0 }, [id], "it is let go of once it is sent")

        let arrived = try await LibrarySync.pullNewer(id, root: b, cloud: cloud, timeout: .zero)
        XCTAssertEqual(arrived, .pulled, "the other device takes it in place")
        let there = try await title(id, on: b)
        XCTAssertEqual(there, "Physics, written on A")

        let again = try await LibrarySync.pushNewer(id, root: a, cloud: cloud, timeout: .zero, hold: { _ in
            XCTFail("nothing new is taken in hand")
            return nil
        })
        XCTAssertEqual(again.sent, .none)
        let pass = try await LibrarySync.run(root: a, cloud: cloud)
        XCTAssertEqual(pass.pushed, [], "what was sent is agreed on")
        XCTAssertEqual(pass.conflictCopies, [])
    }

    func testAnOpenNotebookWrittenInOnBothIsNotSentOverTheOther() async throws {
        let id = try await shared("Physics"), a = a!, b = b!
        try await write(id, on: a, title: "Written on A", after: 10)
        _ = try await LibrarySync.pushNewer(id, root: a, cloud: cloud, timeout: .zero, hold: { NotebookPackage(root: a, id: $0) })
        try await write(id, on: b, title: "Written on B", after: 20)
        let outcome = try await LibrarySync.pushNewer(id, root: b, cloud: cloud, timeout: .zero, hold: { _ in
            XCTFail("nothing is taken in hand")
            return nil
        })
        XCTAssertEqual(outcome.sent, .waiting, "a newer version is waiting")
        let pulled = try await LibrarySync.pullNewer(id, root: a, cloud: cloud, timeout: .zero)
        XCTAssertEqual(pulled, .none)
        let synced = try await title(id, on: a)
        XCTAssertEqual(synced, "Written on A", "and nothing went over A's")
    }

    func testKeepBothKeepsTheOlderAsACopyAndLeavesTheNewerOpenHere() async throws {
        let id = try await shared("Physics"), b = b!
        try await write(id, on: a, title: "Written on A", after: 10)
        _ = try await LibrarySync.run(root: a, cloud: cloud)
        try await write(id, on: b, title: "Written on B", after: 20)
        let replacing = OSAllocatedUnfairLock(initialState: [Bool]())
        let kept = try await LibrarySync.keepBoth(id, root: b, cloud: cloud, timeout: .zero, take: { id, replaces in
            replacing.withLock { $0.append(replaces) }
            return NotebookPackage(root: b, id: id)
        })
        let copy = try XCTUnwrap(kept)
        XCTAssertFalse(copy.pulled, "B's is the newer")
        XCTAssertEqual(replacing.withLock { $0 }, [false], "so its editor keeps it, and its writes wait while it is sent")
        let here = try await title(id, on: b), theCopy = try await title(copy.copy, on: b)
        XCTAssertEqual(here, "Written on B")
        XCTAssertEqual(theCopy, "Written on A (conflicted copy)")

        _ = try await LibrarySync.run(root: b, cloud: cloud)
        let there = try await LibrarySync.run(root: a, cloud: cloud)
        XCTAssertEqual(Set(there.pulled), [id, copy.copy])
        XCTAssertEqual(there.conflictCopies, [], "the conflict was settled once")
        let onA = await titles(on: a)
        XCTAssertEqual(onA, ["Written on A (conflicted copy)", "Written on B"])
    }

    func testKeepBothBringsInTheNewerFromTheOtherDevice() async throws {
        let id = try await shared("Physics"), b = b!
        try await write(id, on: b, title: "Written on B", after: 5)
        try await write(id, on: a, title: "Written on A", after: 20)
        _ = try await LibrarySync.run(root: a, cloud: cloud)
        let replacing = OSAllocatedUnfairLock(initialState: [Bool]())
        let kept = try await LibrarySync.keepBoth(id, root: b, cloud: cloud, timeout: .zero, take: { id, replaces in
            replacing.withLock { $0.append(replaces) }
            return NotebookPackage(root: b, id: id)
        })
        let copy = try XCTUnwrap(kept)
        XCTAssertTrue(copy.pulled)
        XCTAssertEqual(replacing.withLock { $0 }, [true], "the editor gives way to the newer version")
        let onB = await titles(on: b)
        XCTAssertEqual(onB, ["Written on A", "Written on B (conflicted copy)"])
        let pass = try await LibrarySync.run(root: b, cloud: cloud)
        XCTAssertEqual(pass.pushed, [copy.copy], "only the copy is still to go up")
        XCTAssertEqual(pass.conflictCopies, [])
    }

    func testKeepBothDoesNothingWithOnlyOneVersionChanged() async throws {
        let id = try await shared("Physics")
        try await write(id, on: b, title: "Written on B", after: 5)
        let kept = try await LibrarySync.keepBoth(id, root: b, cloud: cloud, timeout: .zero, take: { _, _ in
            XCTFail("nothing is taken in hand")
            return nil
        })
        XCTAssertNil(kept)
        let onB = await titles(on: b)
        XCTAssertEqual(onB, ["Written on B"])
    }

    // MARK: The sync center with notebooks open

    private func makeCenter(on root: StorageRoot) -> SyncCenter {
        defaults.set(true, forKey: SettingsKey.syncsWithICloud)
        let center = SyncCenter(root: root, defaults: defaults), registry = DocumentRegistry.shared
        center.take = { registry.take($0) }
        center.release = { registry.release($0) }
        center.editors = registry
        return center
    }

    func testAnOpenNotebookWithNothingUnsavedTakesTheNewerVersionAfterAnyPass() async throws {
        let id = try await shared("Physics"), registry = DocumentRegistry.shared
        let center = makeCenter(on: b)
        let document = try await registry.open(id, root: b, scene: nil) { _ in }
        addTeardownBlock { @MainActor in registry.unregister(id, document: document) }
        document.noteOpened()
        try await write(id, on: a, title: "Written on A", after: 10)
        _ = try await LibrarySync.run(root: a, cloud: cloud)
        let reopen = expectation(forNotification: .owlLunaReopenNotebook, object: nil) { ($0.object as? UUID) == id }
        await center.use(cloud, account: nil)
        await center.syncNow()
        await fulfillment(of: [reopen], timeout: 2)
        XCTAssertEqual(center.lastReport?.open, [id], "the pass leaves the open notebook alone")
        XCTAssertTrue(document.isSetAside, "and the catch-up after it takes the newer version in place")
        let here = try await title(id, on: b)
        XCTAssertEqual(here, "Written on A")
    }

    func testWritingInAnOpenNotebookIsSentAndKeepBothSettlesAConflict() async throws {
        let id = try await shared("Physics"), registry = DocumentRegistry.shared
        let center = makeCenter(on: b)
        await center.use(cloud, account: nil)
        let document = try await registry.open(id, root: b, scene: nil) { _ in }
        addTeardownBlock { @MainActor in registry.unregister(id, document: document) }
        document.rename("Written on B")
        await document.flush()
        await center.sendOpen(id)
        _ = try await LibrarySync.run(root: a, cloud: cloud)
        let onA = try await title(id, on: a)
        XCTAssertEqual(onA, "Written on B", "sent while it is open")

        try await write(id, on: a, title: "Written on A", after: 30)
        _ = try await LibrarySync.run(root: a, cloud: cloud)
        document.rename("Written on B again")
        await document.flush()
        await center.sendOpen(id)
        XCTAssertEqual(document.notices.map(\.kind), [.newerVersion])

        let kept = await center.keepBoth(id)
        XCTAssertTrue(kept)
        XCTAssertTrue(document.isSetAside, "A's is the newer, so the editor opens it")
        XCTAssertEqual(center.news.conflictCopies.count, 1, "and the library says a copy was kept")
        let onB = await titles(on: b)
        XCTAssertEqual(onB, ["Written on A", "Written on B again (conflicted copy)"])
        let fresh = try await registry.open(id, root: b, scene: nil) { _ in }
        addTeardownBlock { @MainActor in registry.unregister(id, document: fresh) }
        XCTAssertEqual(fresh.notices.map(\.kind), [.keptCopy], "the editor that opens it says where the other went")
        XCTAssertTrue(fresh.notices.first?.message.contains("Written on B again (conflicted copy)") == true)
    }

    func testAnOpenNotebookWaitingToBeSentGoesAtOnceWhenTheAppLeavesTheFront() async throws {
        let id = try await shared("Physics"), registry = DocumentRegistry.shared
        let center = makeCenter(on: b)
        await center.use(cloud, account: nil)
        let document = try await registry.open(id, root: b, scene: nil) { _ in }
        addTeardownBlock { @MainActor in registry.unregister(id, document: document) }
        document.rename("Written on B")
        await document.flush()
        center.sendSoon(id)
        XCTAssertTrue(center.hasWaitingSends, "it waits for writing to pause")
        await center.sendWaiting()
        XCTAssertFalse(center.hasWaitingSends)
        _ = try await LibrarySync.run(root: a, cloud: cloud)
        let onA = try await title(id, on: a)
        XCTAssertEqual(onA, "Written on B", "and is sent without waiting")
    }

    // MARK: Progress

    func testAPassSaysHowManyNotebooksItMovesAndHowFarItHasGot() async throws {
        for title in ["One", "Two", "Three"] { _ = try await makeNotebook(title, on: a) }
        let steps = OSAllocatedUnfairLock(initialState: [SyncProgress]())
        _ = try await LibrarySync.run(root: a, cloud: cloud, progress: { step in steps.withLock { $0.append(step) } })
        XCTAssertEqual(steps.withLock { $0 }, (0...3).map { SyncProgress(done: $0, total: 3) })
        steps.withLock { $0 = [] }
        _ = try await LibrarySync.run(root: a, cloud: cloud, progress: { step in steps.withLock { $0.append(step) } })
        XCTAssertEqual(steps.withLock { $0 }, [SyncProgress(done: 0, total: 0)], "with nothing to move there is nothing to count")
    }

    func testUploadsAreCountedFromWhenTheyBegan() async throws {
        let ids = [UUID(), UUID(), UUID()]
        let center = makeCenter(on: b)
        let uploads = OSAllocatedUnfairLock(initialState: CloudUploads(pending: Set(ids)))
        center.readUploads = { _ in uploads.withLock { $0 } }
        await center.use(cloud, account: nil)
        await center.syncNow()
        XCTAssertEqual(center.uploadCount, SyncProgress(done: 0, total: 3))
        XCTAssertTrue(center.isUploading(ids[0]))
        XCTAssertNil(center.status, "the count says it, not the status line")

        uploads.withLock { $0 = CloudUploads(pending: [ids[2]]) }
        await center.syncNow()
        XCTAssertEqual(center.uploadCount, SyncProgress(done: 2, total: 3))
        XCTAssertFalse(center.isUploading(ids[0]))

        uploads.withLock { $0 = CloudUploads(pending: [ids[2]], problem: .full) }
        await center.syncNow()
        XCTAssertNil(center.uploadCount, "nothing is counted while iCloud is full")

        uploads.withLock { $0 = CloudUploads() }
        await center.syncNow()
        XCTAssertNil(center.uploading)
        uploads.withLock { $0 = CloudUploads(pending: [ids[0]]) }
        await center.syncNow()
        XCTAssertEqual(center.uploading, SyncProgress(done: 0, total: 1), "a new batch starts afresh")
        XCTAssertNil(center.uploadCount, "and one notebook isn't counted")
    }

    // MARK: Smart shelves

    private func shelfNames(on root: StorageRoot) -> [String] { SmartShelfFile.read(root).shelves.map(\.name) }

    /// Changes the shelves as the library saves them.
    private func change(_ root: StorageRoot, at date: Date = .now, _ change: (inout [SmartShelf]) -> Void) throws {
        var file = SmartShelfFile.read(root)
        var after = file.shelves
        change(&after)
        file.apply(from: file.shelves, to: after, at: date)
        try file.write(root)
    }

    func testSmartShelvesFollowFromOneDeviceToTheOther() async throws {
        try change(a) { $0 += [SmartShelf(name: "Revision", tags: ["exam"]), SmartShelf(name: "Labs", tags: ["lab"])] }
        let sent = try await LibrarySync.run(root: a, cloud: cloud)
        XCTAssertFalse(sent.shelvesChanged)
        let arrived = try await LibrarySync.run(root: b, cloud: cloud)
        XCTAssertTrue(arrived.shelvesChanged)
        XCTAssertTrue(arrived.changedHere, "so the library reads them again")
        XCTAssertEqual(shelfNames(on: b), ["Revision", "Labs"])

        let labs = try XCTUnwrap(SmartShelfFile.read(b).shelves.last?.id)
        try change(b) { $0[0].name = "Finals" }
        try change(a) { $0.removeAll { $0.id == labs } }
        _ = try await LibrarySync.run(root: a, cloud: cloud)
        _ = try await LibrarySync.run(root: b, cloud: cloud)
        _ = try await LibrarySync.run(root: a, cloud: cloud)
        XCTAssertEqual(shelfNames(on: a), ["Finals"], "a rename on one and a delete on the other both carry over")
        XCTAssertEqual(shelfNames(on: b), ["Finals"])
    }

    func testAShelfChangedOnBothTakesTheLaterChange() async throws {
        try change(a) { $0 = [SmartShelf(name: "Revision", tags: ["exam"])] }
        _ = try await LibrarySync.run(root: a, cloud: cloud)
        _ = try await LibrarySync.run(root: b, cloud: cloud)
        try change(b, at: .now.addingTimeInterval(60)) { $0[0].tags = ["exam", "lab"] }
        try change(a, at: .now.addingTimeInterval(30)) { $0[0].name = "Older" }
        _ = try await LibrarySync.run(root: b, cloud: cloud)
        _ = try await LibrarySync.run(root: a, cloud: cloud)
        _ = try await LibrarySync.run(root: b, cloud: cloud)
        for root in [a!, b!] {
            XCTAssertEqual(SmartShelfFile.read(root).shelves.map(\.rule), [TagRule(tags: ["exam", "lab"])])
            XCTAssertEqual(shelfNames(on: root), ["Revision"])
        }
    }

    func testASmartShelfListInICloudThatCantBeReadGivesWayToThisDevices() async throws {
        try change(a) { $0 = [SmartShelf(name: "Revision", tags: ["exam"])] }
        _ = try await LibrarySync.run(root: a, cloud: cloud)
        let named = try XCTUnwrap(SmartShelfFile(Data(contentsOf: cloud.smartShelvesFile))?.listID)
        try Data("[1, 2]".utf8).write(to: cloud.smartShelvesFile)
        _ = try await LibrarySync.run(root: a, cloud: cloud)
        let replaced = try XCTUnwrap(SmartShelfFile(Data(contentsOf: cloud.smartShelvesFile)))
        XCTAssertEqual(replaced.shelves.map(\.name), ["Revision"])
        XCTAssertNotEqual(replaced.listID, named, "under a new name, so no device takes a shelf missing from it as deleted")
        let aside = a.library.appending(path: "icloud-smart-shelves.json.corrupt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: aside.path(percentEncoded: false)), "the damaged one is kept aside")
        _ = try await LibrarySync.run(root: b, cloud: cloud)
        XCTAssertEqual(shelfNames(on: b), ["Revision"])
    }

    func testSmartShelvesHereThatCantBeReadAreNeitherSentNorTakenAsDeleted() async throws {
        try change(a) { $0 = [SmartShelf(name: "Revision", tags: ["exam"])] }
        _ = try await LibrarySync.run(root: a, cloud: cloud)
        _ = try await LibrarySync.run(root: b, cloud: cloud)
        try Data("[1, 2]".utf8).write(to: a.smartShelvesFile)
        let pass = try await LibrarySync.run(root: a, cloud: cloud)
        XCTAssertFalse(pass.shelvesChanged)
        XCTAssertEqual(try Data(contentsOf: a.smartShelvesFile), Data("[1, 2]".utf8), "left where it is")
        _ = try await LibrarySync.run(root: b, cloud: cloud)
        XCTAssertEqual(shelfNames(on: b), ["Revision"])
    }

    func testSavingSmartShelvesKeepsOnesASyncBroughtIn() async throws {
        let container = try ModelContainer(for: LibraryIndex.schema, configurations: ModelConfiguration(schema: LibraryIndex.schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        containers.append(container)
        let store = LibraryStore(root: a, context: container.mainContext, defaults: defaults)
        var saves = 0
        store.onShelvesSaved = { saves += 1 }
        let revision = try XCTUnwrap(store.createSmartShelf(name: "Revision", tags: ["exam"], match: .any))
        await store.finishWritingShelves()
        XCTAssertEqual(saves, 1, "a sync hears of it")
        try change(a) { $0.append(SmartShelf(name: "Labs", tags: ["lab"])) }
        store.updateSmartShelf(revision.id, name: "Finals", tags: ["exam"], match: .any)
        await store.finishWritingShelves()
        let saved = SmartShelfFile.read(a).shelves
        XCTAssertEqual(saved.map(\.name), ["Finals", "Labs"], "the one a sync brought in meanwhile stays")
        XCTAssertNotNil(saved.first?.changedAt, "and the change is stamped")
        await store.loadSmartShelves()
        XCTAssertEqual(store.smartShelves.map(\.name), ["Finals", "Labs"])
    }

    // MARK: Pens

    /// Stamped to the second, as a stamp read back from iCloud is to the millisecond.
    private func pens(_ colors: [UInt32], at date: Date?) -> SyncedPens {
        SyncedPens(presets: colors.map { ToolPreset(ink: .pen, color: $0, width: 2.7) },
                   changedAt: date.map { Date(timeIntervalSinceReferenceDate: $0.timeIntervalSinceReferenceDate.rounded()) })
    }

    func testThePensChangedLastGoEverywhere() async throws {
        let older = pens([0x1B22_30FF, 0xC945_2FFF], at: .now), newer = pens([0x2F8F_4EFF], at: .now.addingTimeInterval(60))
        let sent = try await LibrarySync.run(root: b, cloud: cloud, pens: newer)
        XCTAssertTrue(sent.pensSent)
        XCTAssertNil(sent.pensReceived)
        let received = try await LibrarySync.run(root: a, cloud: cloud, pens: older)
        XCTAssertEqual(received.pensReceived, newer)
        XCTAssertFalse(received.pensSent)
        XCTAssertTrue(received.changedHere)
        let settled = try await LibrarySync.run(root: a, cloud: cloud, pens: newer)
        XCTAssertNil(settled.pensReceived)
        XCTAssertFalse(settled.pensSent)

        let changed = pens([0x7A3E_9DFF], at: .now.addingTimeInterval(120))
        let up = try await LibrarySync.run(root: a, cloud: cloud, pens: changed)
        XCTAssertTrue(up.pensSent)
        let down = try await LibrarySync.run(root: b, cloud: cloud, pens: newer)
        XCTAssertEqual(down.pensReceived, changed)
    }

    func testPensNeverChangedGiveWayAndTwoUnchangedSetsArePutTogetherOnce() async throws {
        let mine = pens([0x7A3E_9DFF, 0x2F8F_4EFF], at: .now)
        _ = try await LibrarySync.run(root: b, cloud: cloud, pens: mine)
        let fresh = try await LibrarySync.run(root: a, cloud: cloud, pens: SyncedPens(presets: ToolShelf.starters, changedAt: nil))
        XCTAssertEqual(fresh.pensReceived, mine, "a tray as it started takes the pens another device chose")

        let other = CloudFolder(url: temporaryRoot(self).url)
        let red = pens([0x1B22_30FF, 0xC945_2FFF], at: nil), green = pens([0xC945_2FFF, 0x2F8F_4EFF], at: nil)
        _ = try await LibrarySync.run(root: a, cloud: other, pens: red)
        let met = try await LibrarySync.run(root: b, cloud: other, pens: green)
        let together = try XCTUnwrap(met.pensReceived)
        XCTAssertEqual(together.presets.map(\.color), [0x1B22_30FF, 0xC945_2FFF, 0x2F8F_4EFF], "each device's pens are kept")
        XCTAssertNotNil(together.changedAt)
        XCTAssertTrue(met.pensSent)
        let back = try await LibrarySync.run(root: a, cloud: other, pens: red)
        XCTAssertEqual(back.pensReceived, together)
        XCTAssertFalse(back.pensSent, "and nothing goes back and forth after")
    }

    func testPensFromAnotherDeviceAreTakenUnlessChangedHereSince() {
        let toolbox = Toolbox(defaults: defaults)
        var changes = 0
        toolbox.shelf.onChanged = { changes += 1 }
        let read = toolbox.shelf.synced
        XCTAssertNil(read.changedAt)
        toolbox.take(.pen(toolbox.shelf.usable[1].id))
        let arriving = SyncedPens(presets: [ToolPreset(ink: .pen, color: 0x2F8F_4EFF, width: 2), ToolPreset(ink: .marker, color: 0xFFD4_26FF, width: 20)],
                                  changedAt: .now)
        toolbox.takePens(arriving, since: read.changedAt)
        XCTAssertEqual(toolbox.shelf.presets, arriving.presets)
        XCTAssertEqual(toolbox.pen?.id, arriving.presets[1].id, "the pen in hand gives way to the one in its place")
        XCTAssertEqual(changes, 0, "pens taken from another device aren't sent back")
        XCTAssertEqual(Toolbox(defaults: defaults).shelf.synced, arriving, "they last, stamped as they came")

        let before = toolbox.shelf.synced
        toolbox.addPen()
        XCTAssertEqual(changes, 1)
        XCTAssertGreaterThan(toolbox.shelf.changedAt ?? .distantPast, arriving.changedAt ?? .now, "a change here is stamped")
        toolbox.takePens(pens([0x7A3E_9DFF], at: .now), since: before.changedAt)
        XCTAssertEqual(toolbox.shelf.usable.count, 3, "pens changed here since the sync read them stay, to go up next time")
    }

    func testTheSyncCenterHandsOverPensFromAnotherDevice() async throws {
        let center = makeCenter(on: b)
        let mine = pens([0x1B22_30FF], at: .now), theirs = pens([0x2F8F_4EFF], at: .now.addingTimeInterval(60))
        center.pens = { mine }
        var arrived: [(SyncedPens, Date?)] = []
        center.onPensArrived = { arrived.append(($0, $1)) }
        _ = try await LibrarySync.run(root: a, cloud: cloud, pens: theirs)
        await center.use(cloud, account: nil)
        await center.syncNow()
        XCTAssertEqual(arrived.map(\.0), [theirs])
        XCTAssertEqual(arrived.first?.1, mine.changedAt, "with the stamp the pass read, so a change made meanwhile isn't lost")
    }
}
