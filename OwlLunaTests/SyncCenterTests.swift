import XCTest
import PencilKit
import SwiftData
@testable import OwlLuna

/// What sync asks before it copies anything: once on a device that has never synced, and again when the Apple Account changes.
@MainActor
final class SyncCenterTests: XCTestCase {
    private let paper = PageDefaults(template: .grid, paperColor: .white, pageSize: .letter)
    private var root: StorageRoot!
    private var cloud: CloudFolder!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        root = temporaryRoot(self)
        cloud = CloudFolder(url: temporaryRoot(self).url)
        let suite = "owlluna-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
    }

    @discardableResult
    private func makeNotebook(_ title: String, on root: StorageRoot) async throws -> UUID {
        let manifest = NotebookManifest(title: title, defaults: paper, pages: [paper.newPage()])
        try await NotebookPackage(root: root, id: manifest.id).create(manifest)
        return manifest.id
    }

    private func synced(_ id: UUID, in cloud: CloudFolder) -> Bool {
        FileManager.default.fileExists(atPath: cloud.package(id).appending(path: "manifest.json").path(percentEncoded: false))
    }

    func testNothingIsCopiedUntilTheFirstSyncIsAllowed() async throws {
        let id = try await makeNotebook("Physics", on: root)
        let center = SyncCenter(root: root, defaults: defaults)
        XCTAssertFalse(center.isEnabled, "a device that has never synced doesn't start by itself")
        XCTAssertNil(center.question, "and isn't asked while iCloud is out of reach")

        await center.use(cloud, account: "one")
        XCTAssertEqual(center.question, .firstSync)
        await center.syncNow()
        XCTAssertFalse(synced(id, in: cloud))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cloud.library.path(percentEncoded: false)), "the copy isn't touched while the question stands")

        await center.answer(true)
        XCTAssertNil(center.question)
        XCTAssertTrue(center.isEnabled)
        await center.syncNow()
        XCTAssertTrue(synced(id, in: cloud))
        XCTAssertEqual(defaults.object(forKey: SettingsKey.syncsWithICloud) as? Bool, true)
        XCTAssertEqual(SyncState.read(root).account, "one")

        let relaunched = SyncCenter(root: root, defaults: defaults)
        await relaunched.use(cloud, account: "one")
        XCTAssertTrue(relaunched.isEnabled)
        XCTAssertNil(relaunched.question, "it is asked once")
    }

    func testSayingNotNowLeavesSyncOffAndIsNotAskedAgain() async throws {
        let id = try await makeNotebook("Physics", on: root)
        let center = SyncCenter(root: root, defaults: defaults)
        await center.use(cloud, account: "one")
        await center.answer(false)
        XCTAssertNil(center.question)
        XCTAssertFalse(center.isEnabled)
        await center.syncNow()
        XCTAssertFalse(synced(id, in: cloud))

        let relaunched = SyncCenter(root: root, defaults: defaults)
        await relaunched.use(cloud, account: "one")
        XCTAssertNil(relaunched.question)
        XCTAssertFalse(relaunched.isEnabled)
    }

    func testTheSwitchCanBeSetBeforeICloudIsAvailable() async throws {
        let center = SyncCenter(root: root, defaults: defaults)
        XCTAssertEqual(center.availability, .checking)
        center.isEnabled = true
        center.isEnabled = false
        XCTAssertEqual(defaults.object(forKey: SettingsKey.syncsWithICloud) as? Bool, false)

        let id = try await makeNotebook("Physics", on: root)
        let later = SyncCenter(root: root, defaults: defaults)
        await later.use(cloud, account: "one")
        XCTAssertNil(later.question, "turned off beforehand, it neither asks nor starts when iCloud appears")
        await later.syncNow()
        XCTAssertFalse(synced(id, in: cloud))

        later.isEnabled = true
        await later.syncNow()
        XCTAssertTrue(synced(id, in: cloud), "turning the switch on is the answer")
    }

    func testADeviceAlreadySyncingCarriesOnUnasked() async throws {
        let id = try await makeNotebook("Physics", on: root)
        // An earlier build synced without asking and stored nothing about the choice.
        try SyncState().write(root)
        let center = SyncCenter(root: root, defaults: defaults)
        XCTAssertTrue(center.isEnabled)
        await center.use(cloud, account: "one")
        XCTAssertNil(center.question)
        await center.syncNow()
        XCTAssertTrue(synced(id, in: cloud))
    }

    func testAnotherAppleAccountStopsSyncUntilItIsAllowed() async throws {
        let mine = try await makeNotebook("Mine", on: root)
        var folders = FolderFile()
        folders.folders = [FolderEntry(id: UUID(), name: "Science", clothRaw: "jade", createdAt: .now, sortIndex: 0)]
        try folders.write(root)
        defaults.set(true, forKey: SettingsKey.syncsWithICloud)
        let first = SyncCenter(root: root, defaults: defaults)
        await first.use(cloud, account: "one")
        await first.syncNow()
        XCTAssertTrue(synced(mine, in: cloud))

        let other = CloudFolder(url: temporaryRoot(self).url)
        let center = SyncCenter(root: root, defaults: defaults)
        await center.use(other, account: "two")
        XCTAssertEqual(center.question, .accountChanged)
        await center.syncNow()
        XCTAssertFalse(synced(mine, in: other), "nothing goes to the other account's iCloud unasked")
        XCTAssertFalse(FileManager.default.fileExists(atPath: other.library.path(percentEncoded: false)))

        await center.answer(true)
        XCTAssertNil(center.question)
        XCTAssertTrue(synced(mine, in: other))
        XCTAssertEqual(center.lastReport?.startedAgain, true)
        XCTAssertEqual(FolderFile.read(root).folders.map(\.name), ["Science"], "and nothing synced under the first account is deleted")
        XCTAssertEqual(SyncState.read(root).account, "two")
    }

    func testRefusingAnotherAccountTurnsSyncOffAndAsksAgainWhenTurnedOn() async throws {
        let mine = try await makeNotebook("Mine", on: root)
        defaults.set(true, forKey: SettingsKey.syncsWithICloud)
        _ = try await LibrarySync.run(root: root, cloud: cloud, account: "one")

        let other = CloudFolder(url: temporaryRoot(self).url)
        let center = SyncCenter(root: root, defaults: defaults)
        await center.use(other, account: "two")
        await center.answer(false)
        XCTAssertFalse(center.isEnabled)
        XCTAssertNil(center.question)

        let relaunched = SyncCenter(root: root, defaults: defaults)
        await relaunched.use(other, account: "two")
        XCTAssertFalse(relaunched.isEnabled)
        XCTAssertNil(relaunched.question, "with sync off there is nothing to ask at the next launch: the refusal stands")

        center.isEnabled = true
        for _ in 0..<100 where center.question == nil { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(center.question, .accountChanged)
        await center.syncNow()
        XCTAssertFalse(synced(mine, in: other))
    }

    func testTurningSyncOffInSettingsAnswersTheQuestion() async throws {
        try await makeNotebook("Mine", on: root)
        defaults.set(true, forKey: SettingsKey.syncsWithICloud)
        _ = try await LibrarySync.run(root: root, cloud: cloud, account: "one")

        let other = CloudFolder(url: temporaryRoot(self).url)
        let center = SyncCenter(root: root, defaults: defaults)
        await center.use(other, account: "two")
        XCTAssertEqual(center.question, .accountChanged)
        center.isEnabled = false
        XCTAssertNil(center.question, "the switch is an answer too, so the notice doesn't stay up")
    }

    func testNoPassSlipsInWhileTheQuestionIsBeingWorkedOut() async throws {
        let mine = try await makeNotebook("Mine", on: root)
        defaults.set(true, forKey: SettingsKey.syncsWithICloud)
        _ = try await LibrarySync.run(root: root, cloud: cloud, account: "one")

        let other = CloudFolder(url: temporaryRoot(self).url)
        let center = SyncCenter(root: root, defaults: defaults)
        let found = Task { await center.use(other, account: "two") }
        // A sync asked for by something else, arriving once the copy is found and before the question is known.
        for _ in 0..<100_000 where center.availability == .checking && center.question == nil { await Task.yield() }
        await center.syncNow()
        await found.value
        XCTAssertEqual(center.question, .accountChanged)
        XCTAssertFalse(synced(mine, in: other), "nothing goes to the other account's iCloud before it has been asked about")
    }

    // MARK: What changes while a pass runs

    /// Two notebooks in step with the synced copy and then written in on another device, in the order a pass takes them.
    private func twoNotebooksWrittenInElsewhere(account: String? = nil) async throws -> (first: UUID, second: UUID) {
        let ids = [try await makeNotebook("One", on: root), try await makeNotebook("Two", on: root)].sorted { $0.uuidString < $1.uuidString }
        let there = temporaryRoot(self)
        _ = try await LibrarySync.run(root: root, cloud: cloud, account: account)
        _ = try await LibrarySync.run(root: there, cloud: cloud, account: account)
        for id in ids {
            _ = try await NotebookPackage(root: there, id: id).updateManifest {
                $0.title += ", written in"
                $0.modifiedAt = $0.modifiedAt.addingTimeInterval(60)
            }
        }
        _ = try await LibrarySync.run(root: there, cloud: cloud, account: account)
        defaults.set(true, forKey: SettingsKey.syncsWithICloud)
        return (ids[0], ids[1])
    }

    private func isWrittenIn(_ id: UUID) async throws -> Bool {
        try await NotebookPackage(root: root, id: id).readManifest().manifest.title.hasSuffix(", written in")
    }

    func testANotebookOpenedAfterThePassBeganIsLeftAlone() async throws {
        let (first, second) = try await twoNotebooksWrittenInElsewhere()
        let center = SyncCenter(root: root, defaults: defaults), registry = DocumentRegistry.shared
        let document = try await NotebookDocument.open(second, root: root)
        addTeardownBlock { @MainActor in registry.unregister(second, document: document) }
        // Wired as the app does. The second notebook is opened in an editor while the first pass is busy with the first.
        var opened = false
        center.take = { registry.take($0) }
        center.release = { id in
            registry.release(id)
            if id == first, !opened {
                registry.register(document, scene: nil)
                opened = true
            }
        }
        await center.use(cloud, account: nil)
        await center.syncNow()
        XCTAssertEqual(center.lastReport?.pulled, [first])
        XCTAssertEqual(center.lastReport?.waiting, [second], "it is asked about when its turn comes, not when the pass began")
        let untouched = try await isWrittenIn(second)
        XCTAssertFalse(untouched, "so nothing is copied over a notebook under its open editor")

        registry.unregister(second, document: document)
        await center.syncNow()
        XCTAssertEqual(center.lastReport?.pulled, [second], "and it syncs once it is closed")
    }

    func testOpeningANotebookWaitsWhileASyncHasItInHand() async throws {
        let (first, _) = try await twoNotebooksWrittenInElsewhere()
        let center = SyncCenter(root: root, defaults: defaults), registry = DocumentRegistry.shared, root = root!
        var opening: Task<NotebookDocument, Error>?
        // Tapped open just as the pass takes the notebook in hand.
        center.take = { id in
            let taken = registry.take(id)
            if id == first { opening = Task { try await registry.open(first, root: root, scene: nil) { _ in } } }
            return taken
        }
        center.release = { registry.release($0) }
        await center.use(cloud, account: nil)
        await center.syncNow()
        let document = try await XCTUnwrap(opening).value
        addTeardownBlock { @MainActor in registry.unregister(first, document: document) }
        XCTAssertEqual(center.lastReport?.pulled.contains(first), true)
        XCTAssertTrue(document.title.hasSuffix(", written in"), "the editor opens what the sync brought in, not the files it was replacing")
        XCTAssertFalse(registry.take(first), "and once it is open a sync can't take it")
    }

    func testTurningSyncOffStopsAPassPartWay() async throws {
        let (first, second) = try await twoNotebooksWrittenInElsewhere()
        let center = SyncCenter(root: root, defaults: defaults)
        var finished = 0
        center.onSynced = { finished += 1 }
        center.take = { [weak center] id in
            if id == first { center?.isEnabled = false }
            return true
        }
        await center.use(cloud, account: nil)
        await center.syncNow()
        let inHand = try await isWrittenIn(first), next = try await isWrittenIn(second)
        XCTAssertTrue(inHand, "the notebook in hand is finished")
        XCTAssertFalse(next, "and the pass goes no further")
        XCTAssertNil(center.lastError, "being stopped isn't a failure")
        XCTAssertEqual(finished, 0)
    }

    func testAPassUnderWayStopsWhenAnotherAccountSignsIn() async throws {
        let (first, second) = try await twoNotebooksWrittenInElsewhere(account: "one")
        let other = CloudFolder(url: temporaryRoot(self).url)
        let center = SyncCenter(root: root, defaults: defaults)
        var change: Task<Void, Never>?
        center.take = { [weak center] id in
            if id == first { change = Task { await center?.use(other, account: "two") } }
            return true
        }
        await center.use(cloud, account: "one")
        await center.syncNow()
        await change?.value
        XCTAssertEqual(center.question, .accountChanged)
        let next = try await isWrittenIn(second)
        XCTAssertFalse(next, "the pass begun under the first account stops while the question is asked")
        XCTAssertFalse(FileManager.default.fileExists(atPath: other.library.path(percentEncoded: false)), "and nothing reaches the other account's iCloud unasked")
        await center.syncNow()
        XCTAssertFalse(FileManager.default.fileExists(atPath: other.library.path(percentEncoded: false)))
    }

    // MARK: Recently Deleted and the launch sync

    private var container: ModelContainer?

    private func makeStore() throws -> LibraryStore {
        let container = try ModelContainer(for: LibraryIndex.schema, configurations: ModelConfiguration(schema: LibraryIndex.schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        self.container = container
        return LibraryStore(root: root, context: container.mainContext)
    }

    private func file(_ id: UUID, on root: StorageRoot, deletedAt: Date?, stamped: Date) async throws {
        _ = try await NotebookPackage(root: root, id: id).updateManifest {
            $0.library.deletedAt = deletedAt
            $0.library.setChangedAt(stamped, for: .deleted)
        }
    }

    func testTheThirtyDaysAreCountedAfterTheLaunchSync() async throws {
        let store = try makeStore(), there = temporaryRoot(self)
        let restored = try await makeNotebook("Restored", on: root), written = try await makeNotebook("Written in", on: root)
        let expired = try await makeNotebook("Expired", on: root)
        _ = try await LibrarySync.run(root: root, cloud: cloud)
        _ = try await LibrarySync.run(root: there, cloud: cloud)
        // Deleted here long ago, and this device hasn't been opened since.
        let longAgo = Date.now.addingTimeInterval(-40 * 86_400)
        for id in [restored, written, expired] { try await file(id, on: root, deletedAt: longAgo, stamped: longAgo) }
        _ = try await LibrarySync.run(root: root, cloud: cloud)
        // On the other device one is written in before it hears of that, and one is taken back out afterwards.
        _ = try await NotebookPackage(root: there, id: written).updateManifest { $0.modifiedAt = $0.modifiedAt.addingTimeInterval(60) }
        _ = try await LibrarySync.run(root: there, cloud: cloud)
        try await file(restored, on: there, deletedAt: nil, stamped: .now)
        _ = try await LibrarySync.run(root: there, cloud: cloud)

        await store.reloadFromDisk()
        XCTAssertEqual(store.record(restored)?.isTrashed, true)
        defaults.set(true, forKey: SettingsKey.syncsWithICloud)
        let center = SyncCenter(root: root, defaults: defaults)
        // Wired as the app does at launch: the library hears what the sync changed, then Recently Deleted is emptied.
        center.onLibraryChanged = { _ in await store.reloadFromDisk() }
        center.onSynced = { store.purgeExpiredTrash() }
        await center.use(cloud, account: nil)
        await center.syncNow()
        XCTAssertEqual(store.record(restored)?.isTrashed, false, "a notebook restored on another device is heard of before its 30 days are counted here")
        XCTAssertEqual(store.record(written)?.isTrashed, false, "and so is one written in there")
        XCTAssertNil(store.record(expired), "one that nobody wanted back still goes")

        await center.syncNow()
        let report = try await LibrarySync.run(root: there, cloud: cloud)
        XCTAssertEqual(report.removedHere, [expired])
        XCTAssertEqual(Set(there.packageIDs()), [restored, written], "nothing wanted is removed from the device that wanted it")
    }

    func testOnlyAPassThatFinishedIsFollowedUp() async throws {
        try await makeNotebook("Physics", on: root)
        _ = try await LibrarySync.run(root: root, cloud: cloud)
        defaults.set(true, forKey: SettingsKey.syncsWithICloud)
        let center = SyncCenter(root: root, defaults: defaults), copyFile = cloud.copyFile.path(percentEncoded: false)
        var finished = 0
        center.onSynced = { finished += 1 }
        await center.use(cloud, account: nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: copyFile)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: copyFile) }
        await center.syncNow()
        XCTAssertNotNil(center.lastError)
        XCTAssertEqual(finished, 0, "a sync that couldn't reach the copy has heard nothing from the other devices")

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: copyFile)
        await center.syncNow()
        XCTAssertNil(center.lastError)
        XCTAssertEqual(finished, 1)
    }

    func testALockThatArrivesTellsTheLibrary() async throws {
        let id = try await makeNotebook("Diary", on: root)
        defaults.set(true, forKey: SettingsKey.syncsWithICloud)
        let there = temporaryRoot(self)
        _ = try await LibrarySync.run(root: there, cloud: cloud)
        let center = SyncCenter(root: root, defaults: defaults)
        var reports: [SyncReport] = []
        center.onLibraryChanged = { reports.append($0) }
        await center.use(cloud, account: nil)
        await center.syncNow()
        _ = try await LibrarySync.run(root: there, cloud: cloud)
        XCTAssertEqual(reports, [], "sending changes nothing here")

        _ = try await NotebookPackage(root: there, id: id).updateManifest {
            $0.library.isLocked = true
            $0.library.setChangedAt(.now, for: .locked)
        }
        _ = try await LibrarySync.run(root: there, cloud: cloud)
        await center.syncNow()
        XCTAssertEqual(reports.map(\.stateReceived), [[id]], "the hook that refreshes the index, Spotlight and the widgets runs for a lock alone")
        XCTAssertEqual(center.lastReport?.summary, "1 notebook received")
    }

    func testAnAccountsMarkerSaysOnlyWhetherItIsTheSame() {
        let one = SyncCenter.marker(for: Data([1, 2, 3]) as NSData), again = SyncCenter.marker(for: Data([1, 2, 3]) as NSData)
        let two = SyncCenter.marker(for: Data([1, 2, 4]) as NSData)
        XCTAssertEqual(one, again)
        XCTAssertNotEqual(one, two)
        XCTAssertEqual(one?.count, 64, "a digest, not the token")
        XCTAssertNil(SyncCenter.marker(for: nil))
        XCTAssertEqual(SyncCenter.marker(for: "account" as NSString), SyncCenter.marker(for: "account" as NSString), "a token of another kind is archived first")
    }
}
