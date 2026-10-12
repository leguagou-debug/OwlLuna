import XCTest
import PencilKit
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

        center.isEnabled = true
        for _ in 0..<100 where center.question == nil { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(center.question, .accountChanged)
        await center.syncNow()
        XCTAssertFalse(synced(mine, in: other))
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
