import XCTest
import SwiftData
@testable import OwlLuna

/// Locked notebooks: the flag in the manifest and the index, who may open one, how the lock reaches another device,
/// and what the widgets, Siri and a backup are told.
@MainActor
final class LockTests: XCTestCase {
    private var container: ModelContainer?
    private let paper = PageDefaults(template: .narrowRuled, paperColor: .white, pageSize: .letter)

    private func makeStore() throws -> LibraryStore {
        let schema = LibraryIndex.schema
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        self.container = container
        return LibraryStore(root: temporaryRoot(self), context: container.mainContext)
    }

    private func makeNotebook(_ title: String, in store: LibraryStore, opened: Date? = nil) async throws -> NotebookRecord {
        var manifest = NotebookManifest(title: title, defaults: paper, pages: [paper.newPage()])
        manifest.library.lastOpenedAt = opened
        try await NotebookPackage(root: store.root, id: manifest.id).create(manifest)
        store.index(manifest)
        return try XCTUnwrap(store.record(manifest.id))
    }

    func testTheLockIsKeptInTheManifest() throws {
        var manifest = NotebookManifest(title: "Diary", defaults: paper, pages: [paper.newPage()])
        XCTAssertFalse(manifest.library.isLocked)
        XCTAssertNil(manifest.library.extra["locked"], "an unlocked notebook's manifest says nothing about locks")
        manifest.library.isLocked = true
        let decoded = try ManifestCodec.decode(ManifestCodec.encode(manifest), fallbackID: manifest.id, fallbackDate: .now).manifest
        XCTAssertTrue(decoded.library.isLocked)
        manifest.library.isLocked = false
        XCTAssertEqual(try ManifestCodec.decode(ManifestCodec.encode(manifest), fallbackID: manifest.id, fallbackDate: .now).manifest.library.isLocked, false)
    }

    func testLockingReachesTheIndexAndTheFile() async throws {
        let store = try makeStore()
        let record = try await makeNotebook("Diary", in: store)
        XCTAssertFalse(record.isLocked)
        store.setLocked(true, for: [record])
        XCTAssertTrue(record.isLocked)
        let package = NotebookPackage(root: store.root, id: record.id)
        for _ in 0..<50 {
            if (try? await package.readManifest().manifest.library.isLocked) == true { break }
            try await Task.sleep(for: .milliseconds(40))
        }
        let saved = try await package.readManifest().manifest
        XCTAssertTrue(saved.library.isLocked)

        let fresh = try ModelContainer(for: LibraryIndex.schema, configurations: ModelConfiguration(schema: LibraryIndex.schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        await LibraryIndex.refresh(root: store.root, context: fresh.mainContext)
        XCTAssertEqual(try fresh.mainContext.fetch(FetchDescriptor<NotebookRecord>()).map(\.isLocked), [true], "a rebuilt index reads the lock back")
    }

    private func saved(_ id: UUID, in store: LibraryStore, when done: (NotebookManifest) -> Bool) async throws -> NotebookManifest {
        let package = NotebookPackage(root: store.root, id: id)
        for _ in 0..<100 {
            if let manifest = try? await package.readManifest().manifest, done(manifest) { return manifest }
            try await Task.sleep(for: .milliseconds(30))
        }
        return try await package.readManifest().manifest
    }

    func testLockingStampsTheNotebookWithoutDatingIt() async throws {
        let store = try makeStore()
        let record = try await makeNotebook("Diary", in: store)
        let before = try await NotebookPackage(root: store.root, id: record.id).readManifest().manifest
        XCTAssertNil(before.library.changedAt(.locked))

        store.setLocked(true, for: [record])
        let locked = try await saved(record.id, in: store) { $0.library.isLocked }
        let stamp = try XCTUnwrap(locked.library.changedAt(.locked), "the change is stamped, which is what sync carries")
        XCTAssertEqual(stamp.timeIntervalSinceNow, 0, accuracy: 5)
        XCTAssertNil(locked.library.changedAt(.favorite), "and only what changed is")
        XCTAssertEqual(locked.modifiedAt, before.modifiedAt, "the lock isn't an edit: the notebook keeps its place by date")

        let open = NotebookDocument(package: NotebookPackage(root: store.root, id: record.id), load: ManifestLoad(manifest: before))
        open.updateLibraryState { $0.isFavorite = true }
        XCTAssertNotNil(open.manifest.library.changedAt(.favorite), "an open notebook's change is stamped as well")
        XCTAssertEqual(open.manifest.modifiedAt, before.modifiedAt)
        _ = await open.flush()
    }

    func testTwoChangesMadeTogetherBothReachTheFile() async throws {
        let store = try makeStore()
        for index in 0..<8 {
            let record = try await makeNotebook("Diary \(index)", in: store)
            store.setFavorite(true, for: [record])
            store.setLocked(true, for: [record])
            let manifest = try await saved(record.id, in: store) { $0.library.isLocked && $0.library.isFavorite }
            XCTAssertTrue(manifest.library.isFavorite && manifest.library.isLocked, "one write doesn't overwrite the other")
        }
    }

    func testALockReachesAnotherDeviceAtTheNextSync() async throws {
        let store = try makeStore()
        let diary = try await makeNotebook("Diary", in: store, opened: .now)
        let cloud = CloudFolder(url: temporaryRoot(self).url), other = temporaryRoot(self)
        _ = try await LibrarySync.run(root: store.root, cloud: cloud)
        _ = try await LibrarySync.run(root: other, cloud: cloud)

        store.setLocked(true, for: [diary])
        _ = try await saved(diary.id, in: store) { $0.library.isLocked }
        let sent = try await LibrarySync.run(root: store.root, cloud: cloud)
        XCTAssertEqual(sent.stateSent, [diary.id])
        let received = try await LibrarySync.run(root: other, cloud: cloud)
        XCTAssertTrue(received.changedHere)

        let container = try ModelContainer(for: LibraryIndex.schema, configurations: ModelConfiguration(schema: LibraryIndex.schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let there = LibraryStore(root: other, context: container.mainContext)
        await there.reloadFromDisk()
        XCTAssertEqual(there.record(diary.id)?.isLocked, true, "the other device asks before opening it")
        XCTAssertEqual(SpotlightIndexer.entries(there.notebooks()), [], "and neither Spotlight")
        XCTAssertNil(WidgetBridge.snapshot(library: there, activity: WritingActivity(root: other)).notebook, "nor the widgets are told of it")
    }

    func testACoverChangedFromTheLibraryDatesTheNotebook() async throws {
        let store = try makeStore()
        let record = try await makeNotebook("Diary", in: store)
        let before = try await NotebookPackage(root: store.root, id: record.id).readManifest().manifest
        var cover = before.cover
        cover.clothRaw = before.cover.clothRaw == ClothColor.plum.rawValue ? ClothColor.moss.rawValue : ClothColor.plum.rawValue
        try await Task.sleep(for: .milliseconds(20))
        store.setCover(cover, for: record)
        let changed = try await saved(record.id, in: store) { $0.cover == cover }
        XCTAssertEqual(changed.cover, cover)
        XCTAssertGreaterThan(changed.modifiedAt, before.modifiedAt, "a cover is part of the notebook, so sync sends it like a rename")
    }

    func testSiriIsNotOfferedALockedNotebook() async throws {
        let store = try makeStore()
        let diary = try await makeNotebook("Diary", in: store)
        let biology = try await makeNotebook("Biology diagrams", in: store)
        store.setLocked(true, for: [diary])
        XCTAssertEqual(NotebookQuery.offered(store.notebooks()).map(\.id), [biology.id])
        XCTAssertEqual(NotebookQuery.offered(store.notebooks(), matching: "di").map(\.id), [biology.id], "nor found by name")
    }

    func testABackupOfALockedLibraryAsksFirst() async throws {
        let store = try makeStore()
        let diary = try await makeNotebook("Diary", in: store)
        XCTAssertFalse(store.hasLockedNotebooks)
        store.setLocked(true, for: [diary])
        XCTAssertTrue(store.hasLockedNotebooks)
        store.moveToTrash([diary])
        XCTAssertTrue(store.hasLockedNotebooks, "a backup holds Recently Deleted too")
    }

    func testAnIndexFromBeforeLocksIsMigrated() async throws {
        let root = temporaryRoot(self)
        try FileManager.default.createDirectory(at: root.url, withIntermediateDirectories: true)
        var manifest = NotebookManifest(title: "Diary", defaults: paper, pages: [paper.newPage()])
        manifest.library.isLocked = true
        try await NotebookPackage(root: root, id: manifest.id).create(manifest)

        try autoreleasepool {
            let old = Schema(versionedSchema: LibraryIndexSchemaV3.self)
            let container = try ModelContainer(for: old, configurations: ModelConfiguration(schema: old, url: root.indexStore, cloudKitDatabase: .none))
            let record = LibraryIndexSchemaV3.NotebookRecord(id: manifest.id)
            record.title = "Diary"
            record.indexedAt = .distantFuture
            container.mainContext.insert(record)
            try container.mainContext.save()
        }

        let (container, recovered) = LibraryIndex.makeContainer(root: root)
        XCTAssertFalse(recovered, "the old index is migrated, not set aside")
        let context = container.mainContext
        XCTAssertEqual(try context.fetch(FetchDescriptor<NotebookRecord>()).map(\.isLocked), [false], "the lock starts off")
        await LibraryIndex.refresh(root: root, context: context, full: true)
        XCTAssertEqual(try context.fetch(FetchDescriptor<NotebookRecord>()).map(\.isLocked), [true], "and the first refresh reads it from the manifest")
    }

    func testANotebookStaysOpenOnlyUntilItIsLockedAgain() async {
        let lock = NotebookLock()
        let id = UUID()
        lock.authenticator = ScriptedAuthenticator(passes: 0)
        let refused = await lock.unlock(id, title: "Diary")
        XCTAssertFalse(refused)
        XCTAssertFalse(lock.isUnlocked(id))

        lock.authenticator = ScriptedAuthenticator(passes: 1)
        let allowed = await lock.unlock(id, title: "Diary")
        XCTAssertTrue(allowed)
        XCTAssertTrue(lock.isUnlocked(id))
        let again = await lock.unlock(id, title: "Diary")
        XCTAssertTrue(again, "an open notebook isn't asked about twice")

        lock.lock(id)
        XCTAssertFalse(lock.isUnlocked(id))
        let afterwards = await lock.unlock(id, title: "Diary")
        XCTAssertFalse(afterwards, "closed, it asks again")
    }

    func testALockedNotebookNeverReachesTheWidgets() async throws {
        let store = try makeStore()
        let diary = try await makeNotebook("Diary", in: store, opened: .now)
        let biology = try await makeNotebook("Biology", in: store, opened: Date.now.addingTimeInterval(-3600))
        let activity = WritingActivity(root: store.root)
        XCTAssertEqual(WidgetBridge.snapshot(library: store, activity: activity).notebook?.title, "Diary")
        store.setLocked(true, for: [diary])
        XCTAssertEqual(WidgetBridge.snapshot(library: store, activity: activity).notebook?.title, "Biology", "the widget moves on to the last notebook that isn't locked")
        XCTAssertEqual(store.lastOpenedNotebook?.id, diary.id, "Continue Writing still goes to it, and asks first")
        store.setLocked(true, for: [biology])
        XCTAssertNil(WidgetBridge.snapshot(library: store, activity: activity).notebook)
        XCTAssertTrue(diary.accessibilityDescription.contains("locked"))
    }
}
