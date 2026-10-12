import Foundation
import os

/// The synced copy of the library: the app's iCloud container on a device, or any folder in tests.
/// The library the app works in always stays on the device; syncing copies whole notebooks to and from this folder.
struct CloudFolder: Sendable, Hashable {
    let url: URL
    /// True for a real iCloud container, whose files may still need downloading before they can be read.
    var isUbiquitous = false

    var library: URL { url.appending(path: "Library", directoryHint: .isDirectory) }
    var stickers: URL { url.appending(path: "Stickers", directoryHint: .isDirectory) }
    var tombstones: URL { url.appending(path: "Deleted", directoryHint: .isDirectory) }
    var foldersFile: URL { library.appending(path: "folders.json") }
    /// A random ID naming this synced copy, so a device can tell an erased or different copy from the one it knows.
    var copyFile: URL { url.appending(path: "copy-id") }

    func package(_ id: UUID) -> URL {
        library.appending(path: "\(id.uuidString).\(StorageRoot.packageExtension)", directoryHint: .isDirectory)
    }

    func tombstone(_ id: UUID) -> URL { tombstones.appending(path: id.uuidString) }
}

/// What this device and the synced copy agreed on last time, kept on the device. It is what tells a notebook that was
/// deleted elsewhere from one that was never uploaded, and a change made here from one made there.
struct SyncState: Sendable, Equatable {
    /// Each notebook's modification date when it was last in step.
    var notebooks: [UUID: Date] = [:]
    var folders: Set<UUID> = []
    var stickers: Set<String> = []
    /// Which synced copy all of that was agreed with.
    var copy: String?
    /// A marker for the Apple Account it was synced under. It says nothing about the account but whether it is the same one.
    var account: String?

    static func file(_ root: StorageRoot) -> URL { root.url.appending(path: "sync-state.json") }

    var holdsAnything: Bool { !notebooks.isEmpty || !folders.isEmpty || !stickers.isEmpty }

    /// Nothing is agreed any more, so the next pass only adds: what is missing on either side is copied, never deleted.
    mutating func startAgain() {
        notebooks = [:]
        folders = []
        stickers = []
        copy = nil
    }

    static func read(_ root: StorageRoot) -> SyncState {
        guard let data = try? Data(contentsOf: file(root)), let json = try? JSONValue.parse(data) else { return SyncState() }
        var state = SyncState()
        for (key, value) in json["notebooks"]?.objectValue ?? [:] {
            if let id = UUID(uuidString: key), let date = value.stringValue.flatMap(ManifestCodec.parseDate) { state.notebooks[id] = date }
        }
        state.folders = Set(json["folders"]?.arrayValue?.compactMap { $0.stringValue.flatMap(UUID.init(uuidString:)) } ?? [])
        state.stickers = Set(json["stickers"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        state.copy = json["copy"]?.stringValue
        state.account = json["account"]?.stringValue
        return state
    }

    func write(_ root: StorageRoot) throws {
        var values: [String: JSONValue] = [
            "notebooks": .object(Dictionary(uniqueKeysWithValues: notebooks.map { ($0.key.uuidString, ManifestCodec.encodeDate($0.value)) })),
            "folders": .array(folders.map { .string($0.uuidString) }.sorted { ($0.stringValue ?? "") < ($1.stringValue ?? "") }),
            "stickers": .array(stickers.sorted().map(JSONValue.string)),
        ]
        if let copy { values["copy"] = .string(copy) }
        if let account { values["account"] = .string(account) }
        try JSONValue.object(values).serialized().write(to: Self.file(root), options: .atomic)
    }
}

struct SyncReport: Sendable, Equatable {
    /// Notebooks sent to the synced copy, and notebooks brought in from it.
    var pushed: [UUID] = []
    var pulled: [UUID] = []
    /// Notebooks removed here because they were deleted on another device, and removed from the synced copy because they were deleted here.
    var removedHere: [UUID] = []
    var removedThere: [UUID] = []
    /// Notebooks changed on two devices since they last agreed: the older version was kept as a copy under this new ID.
    var conflictCopies: [UUID] = []
    /// Notebooks left for next time because they are open here or still arriving.
    var waiting: [UUID] = []
    /// Notebooks whose lock, favourite, folder, tags or Recently Deleted date was brought in or sent, their pages untouched.
    var stateReceived: [UUID] = []
    var stateSent: [UUID] = []
    var foldersChanged = false
    var stickersChanged = false
    /// The synced copy wasn't the one this device knew (erased, or another account's), so nothing was taken as deleted.
    var startedAgain = false

    var changedHere: Bool {
        !pulled.isEmpty || !removedHere.isEmpty || !conflictCopies.isEmpty || !stateReceived.isEmpty || foldersChanged || stickersChanged
    }
}

enum SyncError: LocalizedError {
    case stillArriving
    /// The Apple Account signed in is no longer the one the pass began with. `SyncCenter` looks again; it is never shown.
    case accountChanged

    var errorDescription: String? {
        switch self {
        case .stillArriving: String(localized: "iCloud is still downloading your library. Sync will try again shortly.")
        case .accountChanged: nil
        }
    }
}

extension LibraryState {
    /// Whether two copies file the notebook alike: favourite, lock, folder, tags and Recently Deleted.
    func agrees(with other: LibraryState) -> Bool {
        Filing.allCases.allSatisfy { files($0, like: other) }
    }

    /// Whether this copy lacks something `wanted` holds: an item filed differently, or stamped later.
    func trails(_ wanted: LibraryState) -> Bool {
        Filing.allCases.contains { !files($0, like: wanted) || (changedAt($0) ?? .distantPast) < (wanted.changedAt($0) ?? .distantPast) }
    }

    private mutating func take(_ filing: Filing, from other: LibraryState) {
        switch filing {
        case .favorite: isFavorite = other.isFavorite
        case .locked: isLocked = other.isLocked
        case .folder: folderID = other.folderID
        case .tags: tags = other.tags
        case .deleted: deletedAt = other.deletedAt
        }
        setChangedAt(other.changedAt(filing), for: filing)
    }

    /// Takes on how another copy files the notebook. Where it was left off reading stays this copy's own, and an
    /// item both file alike keeps the later stamp, so a stamp never moves backwards.
    mutating func adopt(_ other: LibraryState) {
        for filing in Filing.allCases {
            if !files(filing, like: other) {
                take(filing, from: other)
            } else if let theirs = other.changedAt(filing), theirs > (changedAt(filing) ?? .distantPast) {
                setChangedAt(theirs, for: filing)
            }
        }
    }

    /// What both copies should hold, settled one item at a time: whichever was changed last, or this device's when
    /// neither says. A lock from before changes were stamped is kept whichever side has it, and pages `written` in
    /// unseen by whoever deleted a notebook take it back out of Recently Deleted. Nil when neither copy lacks anything.
    static func settled(here: LibraryState, there: LibraryState, written: (here: Bool, there: Bool) = (false, false), now: Date) -> LibraryState? {
        var result = here
        for filing in Filing.allCases {
            let hereAt = here.changedAt(filing), thereAt = there.changedAt(filing)
            guard !here.files(filing, like: there) else {
                if let thereAt, thereAt > (hereAt ?? .distantPast) { result.setChangedAt(thereAt, for: filing) }
                continue
            }
            var takesThere = (thereAt ?? .distantPast) > (hereAt ?? .distantPast)
            if filing == .locked, hereAt == nil, thereAt == nil { takesThere = there.isLocked }
            let kept = takesThere ? there : here, other = takesThere ? here : there
            if filing == .deleted, kept.deletedAt != nil, other.deletedAt == nil, takesThere ? written.here : written.there {
                // Stamped after the delete it overrules, so every device takes the same answer.
                result.deletedAt = nil
                result.setChangedAt(max(now, (kept.changedAt(.deleted) ?? .distantPast).addingTimeInterval(0.001)), for: .deleted)
                continue
            }
            if takesThere { result.take(filing, from: there) }
            // A tie is stamped now, so the other devices take this answer and don't each give their own.
            if hereAt == thereAt { result.setChangedAt(now, for: filing) }
        }
        return here.trails(result) || there.trails(result) ? result : nil
    }
}

/// Brings this device's library and the synced copy into step, one notebook at a time. Nothing is merged inside a
/// notebook: the newer version wins, and when both sides changed since they last agreed the older is kept as a copy,
/// so a sync never loses writing.
enum LibrarySync {
    private static let log = Logger(subsystem: "com.owais.OwlLuna", category: "sync")

    /// When a notebook was last changed, read straight from its manifest.
    static func stamp(ofPackage url: URL) -> Date? { glance(ofPackage: url)?.modifiedAt }

    /// The two things a pass decides on, from one read of the manifest: when the pages changed, and how the notebook is filed.
    private static func glance(ofPackage url: URL) -> (modifiedAt: Date, library: LibraryState)? {
        guard let data = try? Data(contentsOf: url.appending(path: "manifest.json")), let json = try? JSONValue.parse(data),
              let modifiedAt = json["modifiedAt"]?.stringValue.flatMap(ManifestCodec.parseDate) else { return nil }
        return (modifiedAt, ManifestCodec.decodeLibrary(json["library"]?.objectValue ?? [:]))
    }

    /// Rewrites how a notebook is filed and nothing else. Returns false for a manifest this version mustn't write.
    private static func refile(_ id: UUID, as library: LibraryState, inPackage url: URL) throws -> Bool {
        let manifestURL = url.appending(path: "manifest.json")
        var manifest = try ManifestCodec.decode(Data(contentsOf: manifestURL), fallbackID: id).manifest
        guard !manifest.isNewerThanSupported else { return false }
        manifest.library.adopt(library)
        try ManifestCodec.encode(manifest).write(to: manifestURL, options: .atomic)
        return true
    }

    /// A file in the synced copy, nil when there is none. One that is there but can't be read yet, or is still on
    /// its way down from iCloud, is waited for and never taken as missing.
    private static func contents(of url: URL) throws -> Data? {
        let fileManager = FileManager.default
        let placeholder = url.deletingLastPathComponent().appending(path: ".\(url.lastPathComponent).icloud")
        guard !fileManager.fileExists(atPath: placeholder.path(percentEncoded: false)) else { throw SyncError.stillArriving }
        guard fileManager.fileExists(atPath: url.path(percentEncoded: false)) else { return nil }
        guard let data = try? Data(contentsOf: url) else { throw SyncError.stillArriving }
        return data
    }

    /// The synced copy's ID, nil when it has none.
    private static func copyID(in cloud: CloudFolder) throws -> String? {
        guard let data = try contents(of: cloud.copyFile) else { return nil }
        let id = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return id.isEmpty ? nil : id
    }

    /// Whether the synced copy holds nothing at all: no notebooks, folders, stickers or deletions.
    private static func isEmpty(_ cloud: CloudFolder) -> Bool {
        [cloud.library, cloud.stickers, cloud.tombstones].allSatisfy {
            ((try? FileManager.default.contentsOfDirectory(atPath: $0.path(percentEncoded: false))) ?? []).isEmpty
        }
    }

    /// Finishes a pull interrupted by the app quitting, which left its half-assembled notebook beside the library.
    static func sweepArriving(root: StorageRoot) {
        try? FileManager.default.removeItem(at: root.arriving)
    }

    private static func same(_ a: Date?, _ b: Date?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        return abs(a.timeIntervalSince(b)) < 0.002
    }

    private static func packageIDs(in directory: URL) -> Set<UUID> {
        let contents = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return Set(contents.compactMap { url -> UUID? in
            // A notebook that hasn't been downloaded yet is listed as ".<name>.icloud".
            var name = url.lastPathComponent
            if name.hasPrefix("."), name.hasSuffix(".icloud") { name = String(name.dropFirst().dropLast(7)) }
            guard name.hasSuffix(".\(StorageRoot.packageExtension)") else { return nil }
            return UUID(uuidString: String(name.dropLast(StorageRoot.packageExtension.count + 1)))
        })
    }

    /// `take` asks for a notebook just before it is handled, so one opened in an editor since the pass began is still
    /// left alone, and `release` hands it back. `account` marks the Apple Account the synced copy belongs to, kept with
    /// what was agreed; `signedIn`, when given, says which is signed in now, and the pass stops once that isn't it.
    static func run(root: StorageRoot, cloud: CloudFolder, account: String? = nil, now: Date = .now,
                    take: @Sendable (UUID) async -> Bool = { _ in true }, release: @Sendable (UUID) async -> Void = { _ in },
                    signedIn: (@Sendable () -> String?)? = nil) async throws -> SyncReport {
        let fileManager = FileManager.default
        func checkStillWanted() throws {
            try Task.checkCancellation()
            if let signedIn, signedIn() != account { throw SyncError.accountChanged }
        }
        try checkStillWanted()
        for directory in [root.library, cloud.library, cloud.tombstones] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        if cloud.isUbiquitous { await CloudFiles.download(cloud.url) }
        try checkStillWanted()
        var state = SyncState.read(root)
        var report = SyncReport()
        if let account, state.account != account {
            // Kept before anything is copied, so a pass that is cut short still knows whose copy it began with.
            state.account = account
            try state.write(root)
        }
        // What was agreed holds only for the copy it was agreed with. With an erased copy, or another account's,
        // something missing there was never deleted: this pass starts again and only adds.
        let copy = try copyID(in: cloud)
        if let known = state.copy {
            if known != copy {
                state.startAgain()
                report.startedAgain = true
            }
        } else if copy == nil, state.holdsAnything, isEmpty(cloud) {
            // A state from before copies were named can only tell an erased copy by its being empty.
            state.startAgain()
            report.startedAgain = true
        }
        if let copy {
            state.copy = copy
        } else {
            let made = UUID().uuidString
            try coordinated(writing: cloud.copyFile) { try Data(made.utf8).write(to: $0, options: .atomic) }
            state.copy = made
        }
        let here = Set(root.packageIDs()), there = packageIDs(in: cloud.library)
        let deleted = Set(((try? fileManager.contentsOfDirectory(atPath: cloud.tombstones.path(percentEncoded: false))) ?? []).compactMap(UUID.init(uuidString:)))

        for id in here.union(there).union(state.notebooks.keys).sorted(by: { $0.uuidString < $1.uuidString }) {
            try checkStillWanted()
            guard await take(id) else { report.waiting.append(id); continue }
            notebook: do {
                let isHere = here.contains(id), isThere = there.contains(id)
                let local = isHere ? glance(ofPackage: root.package(id)) : nil
                let remote = isThere ? glance(ofPackage: cloud.package(id)) : nil
                let agreed = state.notebooks[id]
                if (isHere && local == nil) || (isThere && remote == nil) {
                    // A manifest that can't be read yet (still arriving, or damaged) is never copied over a good one.
                    report.waiting.append(id)
                    break notebook
                }
                switch (local, remote) {
                case (let local?, let remote?):
                    // The pages go by their date. How the notebook is filed is settled apart from them, so a pull
                    // never takes a lock off and a favourite never counts as an edit.
                    let inStep = same(local.modifiedAt, remote.modifiedAt)
                    let unchangedHere = inStep || (agreed != nil && same(local.modifiedAt, agreed))
                    let unchangedThere = inStep || (agreed != nil && same(remote.modifiedAt, agreed))
                    let wanted = LibraryState.settled(here: local.library, there: remote.library, written: (!unchangedHere, !unchangedThere), now: now)
                    var hereHolds = local.library, thereHolds = remote.library
                    // Written in on either side, it is no longer deleted: a marker left beside it would mislead a new device.
                    if !inStep, deleted.contains(id) { try? fileManager.removeItem(at: cloud.tombstone(id)) }
                    if inStep {
                        state.notebooks[id] = local.modifiedAt
                    } else if unchangedHere {
                        try pull(id, from: cloud, into: root, filedAs: wanted)
                        hereHolds = wanted ?? remote.library
                        state.notebooks[id] = remote.modifiedAt
                        report.pulled.append(id)
                    } else if unchangedThere {
                        try push(id, from: root, to: cloud)
                        thereHolds = local.library
                        state.notebooks[id] = local.modifiedAt
                        report.pushed.append(id)
                    } else {
                        // Both sides changed. The older version is kept as a notebook of its own first; once that is
                        // done the newer goes through like any other change, and can be tried again if it fails.
                        let remoteIsNewer = remote.modifiedAt > local.modifiedAt
                        let copy = try keepCopy(of: id, fromSyncedCopy: !remoteIsNewer, locked: local.library.isLocked || remote.library.isLocked,
                                                root: root, cloud: cloud)
                        report.conflictCopies.append(copy)
                        state.notebooks[id] = remoteIsNewer ? local.modifiedAt : remote.modifiedAt
                        if remoteIsNewer {
                            try pull(id, from: cloud, into: root, filedAs: wanted)
                            hereHolds = wanted ?? remote.library
                            state.notebooks[id] = remote.modifiedAt
                            report.pulled.append(id)
                        } else {
                            try push(id, from: root, to: cloud)
                            thereHolds = local.library
                            state.notebooks[id] = local.modifiedAt
                            report.pushed.append(id)
                        }
                    }
                    if let wanted {
                        // A stamp raised with nothing filed differently isn't a change worth reporting.
                        if hereHolds.trails(wanted), try refile(id, as: wanted, inPackage: root.package(id)), !hereHolds.agrees(with: wanted) {
                            report.stateReceived.append(id)
                        }
                        if thereHolds.trails(wanted) {
                            var sent = false
                            try coordinated(writing: cloud.package(id)) { sent = try refile(id, as: wanted, inPackage: $0) }
                            if sent, !thereHolds.agrees(with: wanted) { report.stateSent.append(id) }
                        }
                    }
                case (let local?, nil):
                    if deleted.contains(id), agreed != nil, same(local.modifiedAt, agreed) {
                        try remove(root.package(id), root: root)
                        state.notebooks[id] = nil
                        report.removedHere.append(id)
                    } else {
                        // New here, or changed here after it was deleted elsewhere: writing wins over a delete.
                        try? fileManager.removeItem(at: cloud.tombstone(id))
                        try push(id, from: root, to: cloud)
                        state.notebooks[id] = local.modifiedAt
                        report.pushed.append(id)
                    }
                case (nil, let remote?):
                    if let agreed, same(remote.modifiedAt, agreed) {
                        // It was here and in step, it's gone, and nobody has written in it since: it was deleted on this device.
                        try Data().write(to: cloud.tombstone(id))
                        try coordinated(writing: cloud.package(id)) { try fileManager.removeItem(at: $0) }
                        state.notebooks[id] = nil
                        report.removedThere.append(id)
                    } else if agreed == nil, deleted.contains(id) {
                        try coordinated(writing: cloud.package(id)) { try fileManager.removeItem(at: $0) }
                    } else {
                        // New there, or written in there since this device last saw it: writing wins over a delete.
                        try? fileManager.removeItem(at: cloud.tombstone(id))
                        try pull(id, from: cloud, into: root)
                        state.notebooks[id] = remote.modifiedAt
                        report.pulled.append(id)
                    }
                case (nil, nil):
                    state.notebooks[id] = nil
                }
            } catch {
                log.error("sync of \(id) failed: \(error.localizedDescription)")
                report.waiting.append(id)
            }
            await release(id)
        }

        try checkStillWanted()
        report.foldersChanged = try syncFolders(root: root, cloud: cloud, state: &state)
        report.stickersChanged = try syncStickers(root: root, cloud: cloud, state: &state)
        try state.write(root)
        return report
    }

    // MARK: Copying notebooks

    /// Thumbnails are made again where they're needed, and a file set aside as damaged stays on the device it was found on.
    private static func travels(_ relative: String) -> Bool {
        !relative.hasPrefix("thumbs/") && relative != "thumbs" && !relative.contains(".corrupt")
    }

    private static func files(in package: URL) -> [String: URL] {
        var result: [String: URL] = [:]
        let base = package.standardizedFileURL.path(percentEncoded: false)
        let enumerator = FileManager.default.enumerator(at: package, includingPropertiesForKeys: [.isRegularFileKey])
        while let url = enumerator?.nextObject() as? URL {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let relative = String(url.standardizedFileURL.path(percentEncoded: false).dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if travels(relative) { result[relative] = url }
        }
        return result
    }

    /// A copy keeps its original's modification date, so a file of the same size written at the same instant is the
    /// same file. The manifests are small and decide everything, so they are always copied.
    private static func unchanged(_ relative: String, _ a: URL, _ b: URL) -> Bool {
        guard !relative.hasPrefix("manifest") else { return false }
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        guard let first = try? a.resourceValues(forKeys: keys), let second = try? b.resourceValues(forKeys: keys),
              let written = first.contentModificationDate, let copied = second.contentModificationDate else { return false }
        return first.fileSize == second.fileSize && abs(written.timeIntervalSince(copied)) < 0.000_002
    }

    /// Makes `destination` hold what `source` holds: files that differ are copied, files that are gone are removed,
    /// and the manifest goes last so a reader never sees it name ink that hasn't arrived.
    private static func mirror(_ source: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        let wanted = files(in: source), present = files(in: destination)
        for (relative, url) in wanted.sorted(by: { ($0.key == "manifest.json" ? 1 : 0, $0.key) < ($1.key == "manifest.json" ? 1 : 0, $1.key) }) {
            let target = destination.appending(path: relative)
            if let existing = present[relative], unchanged(relative, url, existing) { continue }
            try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let staged = target.deletingLastPathComponent().appending(path: ".\(UUID().uuidString).part")
            try fileManager.copyItem(at: url, to: staged)
            _ = try fileManager.replaceItemAt(target, withItemAt: staged)
        }
        for (relative, url) in present where wanted[relative] == nil { try? fileManager.removeItem(at: url) }
    }

    private static func coordinated(writing url: URL, _ work: (URL) throws -> Void) throws {
        var coordinationError: NSError?
        var failure: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forMerging, error: &coordinationError) { granted in
            do { try work(granted) } catch { failure = error }
        }
        if let error = coordinationError ?? failure { throw error }
    }

    private static func coordinated(reading url: URL, _ work: (URL) throws -> Void) throws {
        var coordinationError: NSError?
        var failure: Error?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { granted in
            do { try work(granted) } catch { failure = error }
        }
        if let error = coordinationError ?? failure { throw error }
    }

    private static func push(_ id: UUID, from root: StorageRoot, to cloud: CloudFolder) throws {
        try coordinated(writing: cloud.package(id)) { try mirror(root.package(id), to: $0) }
    }

    /// The notebook is assembled beside the library and swapped in whole, so a pull that stops halfway changes nothing.
    /// `library` is how it should be filed once here, when that isn't how the synced copy files it.
    private static func pull(_ id: UUID, from cloud: CloudFolder, into root: StorageRoot, filedAs library: LibraryState? = nil) throws {
        let fileManager = FileManager.default
        let staging = root.arriving.appending(path: "\(id.uuidString)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: staging.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }
        let target = root.package(id)
        if fileManager.fileExists(atPath: target.path(percentEncoded: false)) {
            // Starting from what is here means only the pages that changed are copied.
            try fileManager.copyItem(at: target, to: staging)
        }
        try coordinated(reading: cloud.package(id)) { try mirror($0, to: staging) }
        guard stamp(ofPackage: staging) != nil else { throw PackageError.unreadable }
        if let library { _ = try refile(id, as: library, inPackage: staging) }
        try? fileManager.removeItem(at: staging.appending(path: "thumbs"))
        try fileManager.setAttributes([.modificationDate: Date.now], ofItemAtPath: staging.appending(path: "manifest.json").path(percentEncoded: false))
        if fileManager.fileExists(atPath: target.path(percentEncoded: false)) {
            _ = try fileManager.replaceItemAt(target, withItemAt: staging)
        } else {
            try fileManager.moveItem(at: staging, to: target)
        }
    }

    private static func remove(_ package: URL, root: StorageRoot) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: root.deleting, withIntermediateDirectories: true)
        let tombstone = root.deleting.appending(path: "\(package.deletingPathExtension().lastPathComponent)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.moveItem(at: package, to: tombstone)
        try? fileManager.removeItem(at: tombstone)
    }

    /// The older version in a conflict is kept here as a notebook of its own, which the next pass uploads like any new
    /// one. It is assembled beside the library and moved in whole, so a copy is never left half-made. Returns its ID.
    /// A notebook locked on either side has a locked copy.
    private static func keepCopy(of id: UUID, fromSyncedCopy: Bool, locked: Bool, root: StorageRoot, cloud: CloudFolder) throws -> UUID {
        let fileManager = FileManager.default
        let copy = UUID()
        let staging = root.arriving.appending(path: "\(copy.uuidString)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: root.arriving, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }
        if fromSyncedCopy {
            try coordinated(reading: cloud.package(id)) { try mirror($0, to: staging) }
        } else {
            try fileManager.copyItem(at: root.package(id), to: staging)
        }
        let manifestURL = staging.appending(path: "manifest.json")
        var manifest = try ManifestCodec.decode(Data(contentsOf: manifestURL), fallbackID: id).manifest
        guard !manifest.isNewerThanSupported else { throw PackageError.readOnly }
        manifest.id = copy
        manifest.title = String(localized: "\(manifest.title) (conflicted copy)")
        manifest.library.isFavorite = false
        if locked { manifest.library.isLocked = true }
        try ManifestCodec.encode(manifest).write(to: manifestURL, options: .atomic)
        try fileManager.moveItem(at: staging, to: root.package(copy))
        return copy
    }

    // MARK: Folders and stickers

    /// A three-way merge on which folders exist: one added on either side is kept, one deleted on either side goes.
    /// For a folder both sides have, the copy from the more recently written file is used.
    private static func syncFolders(root: StorageRoot, cloud: CloudFolder, state: inout SyncState) throws -> Bool {
        let local = FolderFile.read(root)
        var remote = FolderFile()
        if let data = try contents(of: cloud.foldersFile) {
            let scratch = StorageRoot(url: FileManager.default.temporaryDirectory.appending(path: "folders-\(UUID().uuidString)", directoryHint: .isDirectory))
            try FileManager.default.createDirectory(at: scratch.library, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: scratch.url) }
            try data.write(to: scratch.foldersFile)
            remote = FolderFile.read(scratch)
        }
        func modified(_ url: URL) -> Date { (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast }
        let localIsNewer = modified(root.foldersFile) >= modified(cloud.foldersFile)
        let localByID = Dictionary(local.folders.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let remoteByID = Dictionary(remote.folders.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var merged: [FolderEntry] = []
        for id in (localIsNewer ? local.folders + remote.folders : remote.folders + local.folders).map(\.id) where !merged.contains(where: { $0.id == id }) {
            let wasAgreed = state.folders.contains(id)
            switch (localByID[id], remoteByID[id]) {
            case (let here?, let there?): merged.append(localIsNewer ? here : there)
            case (let here?, nil): if !wasAgreed { merged.append(here) }
            case (nil, let there?): if !wasAgreed { merged.append(there) }
            case (nil, nil): break
            }
        }
        let ids = Set(merged.map(\.id))
        merged = merged.map { entry in
            var entry = entry
            if let parent = entry.parentID, !ids.contains(parent) { entry.parentID = nil }
            return entry
        }
        state.folders = ids
        var changedHere = false
        if merged != local.folders {
            var file = local
            file.folders = merged
            try file.write(root)
            changedHere = true
        }
        if merged != remote.folders {
            var file = remote
            file.folders = merged
            let scratch = StorageRoot(url: FileManager.default.temporaryDirectory.appending(path: "folders-\(UUID().uuidString)", directoryHint: .isDirectory))
            defer { try? FileManager.default.removeItem(at: scratch.url) }
            try file.write(scratch)
            let data = try Data(contentsOf: scratch.foldersFile)
            try coordinated(writing: cloud.foldersFile) { try data.write(to: $0, options: .atomic) }
        }
        return changedHere
    }

    private static func syncStickers(root: StorageRoot, cloud: CloudFolder, state: inout SyncState) throws -> Bool {
        let fileManager = FileManager.default
        func names(_ directory: URL) -> Set<String> {
            Set(((try? fileManager.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []).filter { $0.hasSuffix(".png") })
        }
        let here = names(root.stickers), there = names(cloud.stickers)
        var changedHere = false
        for name in here.union(there) {
            let agreed = state.stickers.contains(name)
            switch (here.contains(name), there.contains(name)) {
            case (true, false):
                if agreed {
                    try? fileManager.removeItem(at: root.stickers.appending(path: name))
                    changedHere = true
                } else {
                    try fileManager.createDirectory(at: cloud.stickers, withIntermediateDirectories: true)
                    try coordinated(writing: cloud.stickers.appending(path: name)) { try fileManager.copyItem(at: root.stickers.appending(path: name), to: $0) }
                }
            case (false, true):
                if agreed {
                    try coordinated(writing: cloud.stickers.appending(path: name)) { try fileManager.removeItem(at: $0) }
                } else {
                    try fileManager.createDirectory(at: root.stickers, withIntermediateDirectories: true)
                    try fileManager.copyItem(at: cloud.stickers.appending(path: name), to: root.stickers.appending(path: name))
                    changedHere = true
                }
            default:
                break
            }
        }
        state.stickers = names(root.stickers).intersection(names(cloud.stickers))
        return changedHere
    }
}

/// Getting files in an iCloud container onto the device before they are read. Not used for a plain folder.
enum CloudFiles {
    /// Asks for everything under `url` to be downloaded and waits, up to `timeout`, for it to arrive.
    static func download(_ url: URL, timeout: Duration = .seconds(60)) async {
        let fileManager = FileManager.default
        func pending() -> [URL] {
            var result: [URL] = []
            let keys: [URLResourceKey] = [.ubiquitousItemDownloadingStatusKey, .isDirectoryKey]
            let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: keys, options: [])
            while let item = enumerator?.nextObject() as? URL {
                let name = item.lastPathComponent
                if name.hasPrefix("."), name.hasSuffix(".icloud") {
                    result.append(item.deletingLastPathComponent().appending(path: String(name.dropFirst().dropLast(7))))
                } else if let status = (try? item.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?.ubiquitousItemDownloadingStatus,
                          status == .notDownloaded {
                    result.append(item)
                }
            }
            return result
        }
        let deadline = ContinuousClock.now + timeout
        var waiting = pending()
        while !waiting.isEmpty, ContinuousClock.now < deadline, !Task.isCancelled {
            for item in waiting { try? fileManager.startDownloadingUbiquitousItem(at: item) }
            try? await Task.sleep(for: .milliseconds(500))
            waiting = pending()
        }
    }
}
