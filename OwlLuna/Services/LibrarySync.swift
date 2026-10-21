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
    var papers: URL { url.appending(path: "Papers", directoryHint: .isDirectory) }
    var tombstones: URL { url.appending(path: "Deleted", directoryHint: .isDirectory) }
    var foldersFile: URL { library.appending(path: "folders.json") }
    var smartShelvesFile: URL { library.appending(path: "smart-shelves.json") }
    /// The pens in the tray, which every device shares.
    var pensFile: URL { url.appending(path: "pens.json") }
    /// A random ID naming this synced copy, so a device can tell an erased or different copy from the one it knows.
    var copyFile: URL { url.appending(path: "copy-id") }

    func package(_ id: UUID) -> URL {
        library.appending(path: "\(id.uuidString).\(StorageRoot.packageExtension)", directoryHint: .isDirectory)
    }

    func tombstone(_ id: UUID) -> URL { tombstones.appending(path: id.uuidString) }

    static let uploadExtension = "uploading"

    /// Where a notebook new to the synced copy is assembled before it is moved into place. No listing takes it for a notebook.
    func upload(_ id: UUID) -> URL {
        library.appending(path: "\(id.uuidString)-\(UUID().uuidString).\(Self.uploadExtension)", directoryHint: .isDirectory)
    }
}

/// How a pass asks iCloud for files and gives them back. A test stands in for iCloud here.
struct CloudAccess: Sendable {
    /// Asks for files to be brought down and waits for them, up to the limit. Returns those still not on the device.
    var fetch: @Sendable (_ files: [URL], _ limit: Duration) async -> [URL]
    /// Takes a file's copy off the device once iCloud holds all of it. True when it did.
    var evict: @Sendable (URL) -> Bool
    /// Whether iCloud has a newer version of a file than the one on the device, still to come down.
    var isBehind: @Sendable (URL) -> Bool = { _ in false }

    static func live(_ cloud: CloudFolder) -> CloudAccess {
        guard cloud.isUbiquitous else { return CloudAccess(fetch: { files, _ in files.filter(CloudFiles.isPending) }, evict: { _ in false }) }
        return CloudAccess(fetch: { await CloudFiles.download($0, within: $1) }, evict: CloudFiles.evict, isBehind: CloudFiles.isBehind)
    }
}

/// What a delete marker says was deleted: the notebook's page date, and when it was last moved into or out of
/// Recently Deleted. A marker from an older build is empty and says neither.
struct DeleteMarker: Sendable, Equatable {
    var modifiedAt: Date?
    var trashStamp: Date?
    /// The delete was held back with others and then let go, so another device doesn't hold it again.
    var confirmed = false
    /// When the marker was written. Nil from an older build, whose marker goes by its file's date.
    var markedAt: Date?

    /// How long a marker is kept once the notebook is gone from the synced copy and the device. A pass that finds no
    /// marker never deletes: a device that comes back with the notebook after that sends it up again whole, so all a
    /// longer life buys is fewer notebooks coming back. A year is four times the longest Recently Deleted.
    static let keptForDays = 365

    init(modifiedAt: Date? = nil, trashStamp: Date? = nil, confirmed: Bool = false, markedAt: Date? = nil) {
        self.modifiedAt = modifiedAt
        self.trashStamp = trashStamp
        self.confirmed = confirmed
        self.markedAt = markedAt
    }

    init(_ data: Data) {
        let json = try? JSONValue.parse(data)
        modifiedAt = json?["modifiedAt"]?.stringValue.flatMap(ManifestCodec.parseDate)
        trashStamp = json?["trashStamp"]?.stringValue.flatMap(ManifestCodec.parseDate)
        confirmed = json?["confirmed"]?.boolValue ?? false
        markedAt = json?["markedAt"]?.stringValue.flatMap(ManifestCodec.parseDate)
    }

    func encoded() throws -> Data {
        var values: [String: JSONValue] = [:]
        if let modifiedAt { values["modifiedAt"] = ManifestCodec.encodeDate(modifiedAt) }
        if let trashStamp { values["trashStamp"] = ManifestCodec.encodeDate(trashStamp) }
        if confirmed { values["confirmed"] = .bool(true) }
        if let markedAt { values["markedAt"] = ManifestCodec.encodeDate(markedAt) }
        return try JSONValue.object(values).serialized()
    }

    /// Whether the marker is for this version of a notebook: the same pages, and not taken back out of Recently
    /// Deleted since. Nil for a marker that doesn't say.
    func covers(_ notebook: (modifiedAt: Date, library: LibraryState)) -> Bool? {
        guard let modifiedAt else { return nil }
        return abs(notebook.modifiedAt.timeIntervalSince(modifiedAt)) < 0.002 && !notebook.library.wasRestored(since: trashStamp)
    }
}

/// What this device and the synced copy agreed on last time, kept on the device. It is what tells a notebook that was
/// deleted elsewhere from one that was never uploaded, and a change made here from one made there.
struct SyncState: Sendable, Equatable {
    /// Each notebook's modification date when it was last in step.
    var notebooks: [UUID: Date] = [:]
    /// Each notebook's Recently Deleted stamp at that time, which tells a restore made elsewhere since from none.
    var trashStamps: [UUID: Date] = [:]
    var folders: Set<UUID> = []
    /// Which folder list `folders` was agreed with. Nil from before lists were named, or with no list yet.
    var folderList: String?
    var smartShelves: Set<UUID> = []
    /// Which smart shelf list `smartShelves` was agreed with.
    var shelfList: String?
    var stickers: Set<String> = []
    var papers: Set<String> = []
    /// Which synced copy all of that was agreed with.
    var copy: String?
    /// A marker for the Apple Account it was synced under. It says nothing about the account but whether it is the same one.
    var account: String?

    static func file(_ root: StorageRoot) -> URL { root.url.appending(path: "sync-state.json") }

    var holdsAnything: Bool { !notebooks.isEmpty || !folders.isEmpty || !smartShelves.isEmpty || !stickers.isEmpty || !papers.isEmpty }

    /// Nothing is agreed any more, so the next pass only adds: what is missing on either side is copied, never deleted.
    mutating func startAgain() {
        notebooks = [:]
        trashStamps = [:]
        folders = []
        folderList = nil
        smartShelves = []
        shelfList = nil
        stickers = []
        papers = []
        copy = nil
    }

    mutating func agree(on id: UUID, _ notebook: (modifiedAt: Date, library: LibraryState)) {
        notebooks[id] = notebook.modifiedAt
        trashStamps[id] = notebook.library.changedAt(.deleted)
    }

    mutating func forget(_ id: UUID) {
        notebooks[id] = nil
        trashStamps[id] = nil
    }

    static func read(_ root: StorageRoot) -> SyncState {
        guard let data = try? Data(contentsOf: file(root)), let json = try? JSONValue.parse(data) else { return SyncState() }
        var state = SyncState()
        for (key, value) in json["notebooks"]?.objectValue ?? [:] {
            if let id = UUID(uuidString: key), let date = value.stringValue.flatMap(ManifestCodec.parseDate) { state.notebooks[id] = date }
        }
        for (key, value) in json["trashStamps"]?.objectValue ?? [:] {
            if let id = UUID(uuidString: key), let date = value.stringValue.flatMap(ManifestCodec.parseDate) { state.trashStamps[id] = date }
        }
        state.folders = Set(json["folders"]?.arrayValue?.compactMap { $0.stringValue.flatMap(UUID.init(uuidString:)) } ?? [])
        state.folderList = json["folderList"]?.stringValue
        state.smartShelves = Set(json["smartShelves"]?.arrayValue?.compactMap { $0.stringValue.flatMap(UUID.init(uuidString:)) } ?? [])
        state.shelfList = json["shelfList"]?.stringValue
        state.stickers = Set(json["stickers"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        state.papers = Set(json["papers"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        state.copy = json["copy"]?.stringValue
        state.account = json["account"]?.stringValue
        return state
    }

    func write(_ root: StorageRoot) throws {
        var values: [String: JSONValue] = [
            "notebooks": .object(Dictionary(uniqueKeysWithValues: notebooks.map { ($0.key.uuidString, ManifestCodec.encodeDate($0.value)) })),
            "trashStamps": .object(Dictionary(uniqueKeysWithValues: trashStamps.map { ($0.key.uuidString, ManifestCodec.encodeDate($0.value)) })),
            "folders": .array(folders.map { .string($0.uuidString) }.sorted { ($0.stringValue ?? "") < ($1.stringValue ?? "") }),
            "stickers": .array(stickers.sorted().map(JSONValue.string)),
            "papers": .array(papers.sorted().map(JSONValue.string)),
        ]
        if let folderList { values["folderList"] = .string(folderList) }
        if !smartShelves.isEmpty { values["smartShelves"] = .array(smartShelves.map(\.uuidString).sorted().map(JSONValue.string)) }
        if let shelfList { values["shelfList"] = .string(shelfList) }
        if let copy { values["copy"] = .string(copy) }
        if let account { values["account"] = .string(account) }
        try JSONValue.object(values).serialized().write(to: Self.file(root), options: .atomic)
    }
}

struct SyncReport: Sendable, Equatable {
    /// Notebooks sent to the synced copy, and notebooks brought in from it.
    var pushed: [UUID] = []
    var pulled: [UUID] = []
    /// Notebooks taken out of the library here because they were deleted on another device: into Recently Deleted, or
    /// for good when they were in it already. And notebooks removed from the synced copy because they were deleted here.
    var removedHere: [UUID] = []
    var removedThere: [UUID] = []
    /// Notebooks changed on two devices since they last agreed: the older version was kept as a copy under this new ID.
    var conflictCopies: [UUID] = []
    /// Notebooks left for next time: busy here (open, opening, saving, a change waiting), or not all down from iCloud yet.
    var open: [UUID] = []
    var arriving: [UUID] = []
    /// Notebooks that couldn't be copied, each with why. Every pass tries them again.
    var failed: [SyncFailure] = []
    /// Notebooks gone from one side that weren't taken as deleted, since too many went at once.
    var held: [UUID] = []
    /// The synced copy's folder list is there and can't be read, so the folders were left as they are on both sides.
    var foldersUnreadable = false
    /// Notebooks whose lock, favourite, folder, tags, Recently Deleted date or journal mark was brought in or sent, their pages untouched.
    var stateReceived: [UUID] = []
    var stateSent: [UUID] = []
    /// Notebooks whose flashcards took cards, answers or deletions from the other side.
    var cardsReceived: [UUID] = []
    var cardsSent: [UUID] = []
    var foldersChanged = false
    var shelvesChanged = false
    /// The pens another device changed last, for this one to take; and whether this device's went up.
    var pensReceived: SyncedPens?
    var pensSent = false
    var stickersChanged = false
    var papersChanged = false
    /// The synced copy wasn't the one this device knew (erased, or another account's), so nothing was taken as deleted.
    var startedAgain = false

    /// Every notebook the pass left as it was.
    var waiting: [UUID] { open + arriving + failed.map(\.id) + held }

    var changedHere: Bool {
        !pulled.isEmpty || !removedHere.isEmpty || !conflictCopies.isEmpty || !stateReceived.isEmpty || !cardsReceived.isEmpty || foldersChanged || shelvesChanged || pensReceived != nil || stickersChanged || papersChanged
    }

    /// Adds what the pass run straight after this one did. What is left is what that pass left.
    mutating func add(_ next: SyncReport) {
        pushed += next.pushed
        pulled += next.pulled
        removedHere += next.removedHere
        removedThere += next.removedThere
        conflictCopies += next.conflictCopies
        open = next.open
        arriving = next.arriving
        failed = next.failed
        held = next.held
        foldersUnreadable = next.foldersUnreadable
        stateReceived += next.stateReceived
        stateSent += next.stateSent
        cardsReceived += next.cardsReceived
        cardsSent += next.cardsSent
        foldersChanged = foldersChanged || next.foldersChanged
        shelvesChanged = shelvesChanged || next.shelvesChanged
        pensReceived = next.pensReceived ?? pensReceived
        pensSent = pensSent || next.pensSent
        stickersChanged = stickersChanged || next.stickersChanged
        papersChanged = papersChanged || next.papersChanged
        startedAgain = startedAgain || next.startedAgain
    }
}

/// How far a pass has got through the notebooks it copies, adds or deletes.
struct SyncProgress: Sendable, Equatable {
    var done = 0
    var total = 0
}

/// What a pass did with the folders, or the smart shelves: whether it changed them here, and which both sides now
/// have, in which list.
struct FolderPass: Sendable, Equatable {
    var changedHere: Bool
    var agreed: Set<UUID>
    var list: String?
    /// The synced list can't be read: nothing was written, and what was agreed stands.
    var unreadableThere = false
}

/// A notebook a pass couldn't copy, and why.
struct SyncFailure: Sendable, Hashable {
    enum Reason: Sendable, Hashable {
        /// There is no room left on this device.
        case noRoom
        /// Its manifest is there and won't read: the copy in iCloud, or the one here.
        case unreadable(inICloud: Bool)
        /// Saved by a newer version of OwlLuna, which this one mustn't change.
        case newerVersion
        /// iCloud Drive wouldn't hand over the files.
        case coordination(String)
        case other(String)
    }

    let id: UUID
    let reason: Reason
}

extension SyncFailure.Reason {
    init(_ error: any Error) {
        if let error = error as? CoordinationError {
            self = Self.isOutOfSpace(error.underlying) ? .noRoom : .coordination(error.underlying.localizedDescription)
        } else if Self.isOutOfSpace(error as NSError) {
            self = .noRoom
        } else if error as? PackageError == .readOnly {
            self = .newerVersion
        } else if error as? PackageError == .unreadable {
            // Only a pull finds a manifest it can't read, in what it brought down from iCloud.
            self = .unreadable(inICloud: true)
        } else {
            self = .other(error.localizedDescription)
        }
    }

    private static func isOutOfSpace(_ error: NSError) -> Bool {
        (error.domain == NSCocoaErrorDomain && error.code == NSFileWriteOutOfSpaceError)
            || (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOSPC))
            || (error.userInfo[NSUnderlyingErrorKey] as? NSError).map(isOutOfSpace) == true
    }
}

/// What a file coordinator said when it wouldn't let the synced copy's files be read or written.
struct CoordinationError: Error {
    let underlying: NSError
}

/// A pass that stopped part-way: what it had done by then, which is kept as agreed, and why it stopped.
struct StoppedPass: Error {
    let report: SyncReport
    let reason: any Error
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
    /// Whether two copies file the notebook alike: favourite, lock, folder, tags, Recently Deleted and the journal mark.
    func agrees(with other: LibraryState) -> Bool {
        Filing.allCases.allSatisfy { files($0, like: other) }
    }

    /// Whether the notebook was taken back out of Recently Deleted after `stamp`, which is all a delete made then knew of.
    func wasRestored(since stamp: Date?) -> Bool {
        guard deletedAt == nil, let changed = changedAt(.deleted) else { return false }
        return changed.timeIntervalSince(stamp ?? .distantPast) > 0.0005
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
        case .journal: isJournal = other.isJournal
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
                result.setChangedAt(stamp(after: kept.changedAt(.deleted), at: now), for: .deleted)
                continue
            }
            if takesThere { result.take(filing, from: there) }
            // A tie is stamped now, so the other devices take this answer and don't each give their own.
            if hereAt == thereAt { result.stampChange(filing, at: now) }
        }
        return here.trails(result) || there.trails(result) ? result : nil
    }
}

/// Brings this device's library and the synced copy into step, one notebook at a time. Pages aren't merged: the newer
/// version wins, and when both sides changed since they last agreed the older is kept as a copy, so a sync never loses
/// writing. Flashcards are merged card by card, apart from the pages.
enum LibrarySync {
    private static let log = Logger(subsystem: "com.owais.OwlLuna", category: "sync")

    /// When a notebook was last changed, read straight from its manifest.
    static func stamp(ofPackage url: URL) -> Date? { glance(ofPackage: url)?.modifiedAt }

    /// How a notebook is filed, read straight from its manifest.
    static func filing(ofPackage url: URL) -> LibraryState? { glance(ofPackage: url)?.library }

    /// The two things a pass decides on, from one read of the manifest: when the pages changed, and how the notebook is filed.
    private static func glance(ofPackage url: URL) -> (modifiedAt: Date, library: LibraryState)? {
        guard let data = try? Data(contentsOf: url.appending(path: "manifest.json")), let json = try? JSONValue.parse(data),
              let modifiedAt = json["modifiedAt"]?.stringValue.flatMap(ManifestCodec.parseDate) else { return nil }
        return (modifiedAt, ManifestCodec.decodeLibrary(json["library"]?.objectValue ?? [:]))
    }

    /// Whether the synced copy, taken over this device's, would drop a recording cut off here that only this device can take up.
    private static func losesRecording(_ id: UUID, root: StorageRoot, cloud: CloudFolder) -> Bool {
        func unfinished(in package: URL) -> [RecordingEntry] {
            guard let data = try? Data(contentsOf: package.appending(path: "manifest.json")),
                  let manifest = try? ManifestCodec.decode(data, fallbackID: id).manifest else { return [] }
            return manifest.unfinishedRecordings
        }
        let here = unfinished(in: root.package(id))
        guard !here.isEmpty else { return false }
        let device = root.deviceID
        let mine = here.filter { $0.device == device }
        guard !mine.isEmpty else { return false }
        let there = Set(unfinished(in: cloud.package(id)).map(\.id))
        return mine.contains { !there.contains($0.id) }
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

    /// Whether a file is in the synced copy, on the device or only in iCloud.
    private static func isListed(_ url: URL) -> Bool {
        let placeholder = url.deletingLastPathComponent().appending(path: ".\(url.lastPathComponent).icloud")
        return [url, placeholder].contains { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
    }

    /// Whether a file is in the synced copy. One still on its way down from iCloud is waited for.
    private static func isPresent(_ url: URL) throws -> Bool {
        let fileManager = FileManager.default
        let placeholder = url.deletingLastPathComponent().appending(path: ".\(url.lastPathComponent).icloud")
        guard !fileManager.fileExists(atPath: placeholder.path(percentEncoded: false)) else { throw SyncError.stillArriving }
        return fileManager.fileExists(atPath: url.path(percentEncoded: false))
    }

    /// A file in the synced copy, nil when there is none. One that is there but can't be read yet, or is still on
    /// its way down from iCloud, is waited for and never taken as missing.
    private static func contents(of url: URL) throws -> Data? {
        guard try isPresent(url) else { return nil }
        guard let data = try? Data(contentsOf: url) else { throw SyncError.stillArriving }
        return data
    }

    /// Whether a file in the synced copy is all there, downloaded, and still can't be read as a manifest.
    private static func isDamaged(_ url: URL) -> Bool {
        let placeholder = url.deletingLastPathComponent().appending(path: ".\(url.lastPathComponent).icloud")
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: placeholder.path(percentEncoded: false)),
              fileManager.fileExists(atPath: url.path(percentEncoded: false)) else { return false }
        let status = (try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?.ubiquitousItemDownloadingStatus
        return status == nil || status == .current
    }

    /// The synced copy's ID, nil when it has none.
    private static func copyID(in cloud: CloudFolder) throws -> String? {
        guard let data = try contents(of: cloud.copyFile) else { return nil }
        let id = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return id.isEmpty ? nil : id
    }

    /// Whether the synced copy holds nothing at all: no notebooks, folders, stickers, papers or deletions.
    private static func isEmpty(_ cloud: CloudFolder) -> Bool {
        [cloud.library, cloud.stickers, cloud.papers, cloud.tombstones].allSatisfy {
            ((try? FileManager.default.contentsOfDirectory(atPath: $0.path(percentEncoded: false))) ?? []).isEmpty
        }
    }

    /// Clears away pulls and new notebooks a quit left half-assembled beside the library. One touched since `cutoff` is still under way.
    static func sweepArriving(root: StorageRoot, untouchedSince cutoff: Date = .now) {
        let fileManager = FileManager.default
        for url in (try? fileManager.contentsOfDirectory(at: root.arriving, includingPropertiesForKeys: [.attributeModificationDateKey])) ?? [] {
            let touched = (try? url.resourceValues(forKeys: [.attributeModificationDateKey]))?.attributeModificationDate ?? .distantPast
            if touched < cutoff { try? fileManager.removeItem(at: url) }
        }
    }

    /// Clears away uploads a quit cut short. One begun within the hour may be another device's, still under way.
    private static func sweepUploads(in cloud: CloudFolder, now: Date) {
        let fileManager = FileManager.default
        let contents = (try? fileManager.contentsOfDirectory(at: cloud.library, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for url in contents where url.pathExtension == CloudFolder.uploadExtension {
            let begun = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if now.timeIntervalSince(begun) > 3600 { try? coordinated(writing: url) { try fileManager.removeItem(at: $0) } }
        }
    }

    /// Whether a synced package was left by an upload cut short: it has no manifest, and none is on its way down.
    private static func isCutShort(_ package: URL) -> Bool {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: package.path(percentEncoded: false), isDirectory: &isDirectory), isDirectory.boolValue else { return false }
        return !["manifest.json", ".manifest.json.icloud"].contains { fileManager.fileExists(atPath: package.appending(path: $0).path(percentEncoded: false)) }
    }

    private static func same(_ a: Date?, _ b: Date?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        return abs(a.timeIntervalSince(b)) < 0.002
    }

    private static func packageIDs(in directory: URL) throws -> Set<UUID> {
        let contents = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        return Set(contents.compactMap { url -> UUID? in
            // A notebook that hasn't been downloaded yet is listed as ".<name>.icloud".
            var name = url.lastPathComponent
            if name.hasPrefix("."), name.hasSuffix(".icloud") { name = String(name.dropFirst().dropLast(7)) }
            guard name.hasSuffix(".\(StorageRoot.packageExtension)") else { return nil }
            return UUID(uuidString: String(name.dropLast(StorageRoot.packageExtension.count + 1)))
        })
    }

    /// More notebooks than this gone in one pass, or most of a library when more than one is, looks like something gone
    /// wrong rather than deletes. Notebooks in Recently Deleted don't count.
    static let deletesAtOnce = 3

    static func isTooManyToDelete(_ count: Int, of library: Int) -> Bool {
        count > deletesAtOnce || (count > 1 && count * 2 > library)
    }

    /// Whether a notebook gone from here was deleted here: it was here and in step, and nobody has written in it or restored it since.
    private static func wasDeletedHere(_ remote: (modifiedAt: Date, library: LibraryState), agreed: Date?, trashStamp: Date?) -> Bool {
        guard let agreed else { return false }
        return same(remote.modifiedAt, agreed) && !remote.library.wasRestored(since: trashStamp)
    }

    /// Whether a marker carries a delete to the notebook here: it is for this version, and not over a restore made since.
    private static func carries(_ marker: DeleteMarker?, to local: (modifiedAt: Date, library: LibraryState), agreed: Date?) -> Bool {
        guard let marker, agreed != nil else { return false }
        return marker.covers(local) ?? same(local.modifiedAt, agreed)
    }

    /// Whether a notebook gone from here only ran out of this device's Recently Deleted, and is in the synced copy's,
    /// unchanged, from a time another device may still be keeping it.
    private static func expiredOnlyHere(_ id: UUID, _ remote: (modifiedAt: Date, library: LibraryState), agreed: Date?,
                                        expired: ExpiredTrash, now: Date) -> Bool {
        guard expired.notebooks[id] != nil, let agreed, same(remote.modifiedAt, agreed), let trashed = remote.library.deletedAt else { return false }
        return ExpiredTrash.mayBeKeptElsewhere(deletedAt: trashed, now: now)
    }

    /// Whether the notebook here went into Recently Deleted after the one the marker's delete knew of: for that delete, or since.
    private static func isTrashedSince(_ local: LibraryState, _ marker: DeleteMarker?) -> Bool {
        guard local.deletedAt != nil, let stamp = local.changedAt(.deleted) else { return false }
        return stamp.timeIntervalSince(marker?.trashStamp ?? .distantPast) > 0.0005
    }

    /// `take` asks for a notebook just before it is handled, so one opened in an editor since the pass began is still
    /// left alone, and `release` hands it back. `account` marks the Apple Account the synced copy belongs to, kept with
    /// what was agreed; `signedIn`, when given, says which is signed in now, and the pass stops once that isn't it.
    /// `keeping` are notebooks a pass held back that are wanted after all: nothing is taken as deleted for them, so
    /// they come back wherever they're gone. `lettingGo` are ones whose deletes were meant: they aren't held again,
    /// and go as a single delete would. The folders are settled inside `holdingFolders`, which a library uses to
    /// keep its own folder writes from interleaving with the pass's. `replacingFolders` puts this device's folders
    /// in place of a synced list that can't be read. `access` is how files are brought down and evicted. The smart
    /// shelves are settled inside `holdingShelves`, as the folders are, and `pens` are this device's, settled last.
    /// `progress` hears how many notebooks are to be copied, added or deleted, and how many are done.
    static func run(root: StorageRoot, cloud: CloudFolder, account: String? = nil, now: Date = .now, keeping: Set<UUID> = [], lettingGo: Set<UUID> = [],
                    replacingFolders: Bool = false, access: CloudAccess? = nil,
                    take: @Sendable (UUID) async -> Bool = { _ in true }, release: @Sendable (UUID) async -> Void = { _ in },
                    holdingFolders: @Sendable (@escaping @Sendable () throws -> FolderPass?) async throws -> FolderPass? = { try $0() },
                    signedIn: (@Sendable () -> String?)? = nil, pens: SyncedPens? = nil,
                    holdingShelves: @Sendable (@escaping @Sendable () throws -> FolderPass?) async throws -> FolderPass? = { try $0() },
                    progress: @Sendable (SyncProgress) -> Void = { _ in }) async throws -> SyncReport {
        let fileManager = FileManager.default, access = access ?? .live(cloud)
        func checkStillWanted() throws {
            try Task.checkCancellation()
            if let signedIn, signedIn() != account { throw SyncError.accountChanged }
        }
        try checkStillWanted()
        for directory in [root.library, cloud.library, cloud.tombstones] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        // Only the small files a pass decides on come down first. A notebook's pages wait until it is to be pulled.
        _ = await access.fetch(deciding(in: cloud), .seconds(60))
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
        // Looked at before anything is copied, so a pass that has to wait for the folders changes nothing.
        _ = try contents(of: cloud.foldersFile)
        if let known = state.copy {
            if known != copy {
                state.startAgain()
                report.startedAgain = true
            }
        } else if copy == nil, state.holdsAnything, isEmpty(cloud) {
            // A state from before copies were named can only tell an erased copy by its being empty.
            state.startAgain()
            report.startedAgain = true
        } else if copy != nil {
            // Nor can it tell a copy erased and filled again by another device, where a missing folder, sticker or paper was never deleted.
            state.folders = []
            state.smartShelves = []
            state.stickers = []
            state.papers = []
        }
        if let copy {
            state.copy = copy
        } else {
            // The fresh start is saved first: once the copy has a name, a state without one is taken to have agreed with it.
            if report.startedAgain { try state.write(root) }
            let made = UUID().uuidString
            try coordinated(writing: cloud.copyFile) { try Data(made.utf8).write(to: $0, options: .atomic) }
            state.copy = made
        }
        for id in keeping { state.forget(id) }
        sweepUploads(in: cloud, now: now)
        let here = Set(try root.listPackageIDs()), there = try packageIDs(in: cloud.library)
        // Read after the packages are listed: it is written before an expired one goes.
        let expired = ExpiredTrash.read(root)
        // A marker still on its way down is listed too, so it is waited for rather than taken as missing.
        let deleted = Set(((try? fileManager.contentsOfDirectory(atPath: cloud.tombstones.path(percentEncoded: false))) ?? [])
            .compactMap { UUID(uuidString: CloudFiles.placeholderTarget($0) ?? $0) })
        func deleteMarker(_ id: UUID) throws -> DeleteMarker? {
            guard deleted.contains(id), let data = try contents(of: cloud.tombstone(id)) else { return nil }
            return DeleteMarker(data)
        }
        // Counted before anything is touched: notebooks out of Recently Deleted that this pass would take out of the
        // library, less those already let go here or on the device that marked them.
        var vanishing: [UUID] = []
        for (id, agreed) in state.notebooks where !lettingGo.contains(id) {
            switch (here.contains(id), there.contains(id)) {
            case (false, true):
                if let remote = glance(ofPackage: cloud.package(id)), remote.library.deletedAt == nil,
                   wasDeletedHere(remote, agreed: agreed, trashStamp: state.trashStamps[id]) { vanishing.append(id) }
            case (true, false):
                if let local = glance(ofPackage: root.package(id)), local.library.deletedAt == nil,
                   let marker = try? deleteMarker(id), !marker.confirmed, carries(marker, to: local, agreed: agreed) { vanishing.append(id) }
            default:
                break
            }
        }
        let held = isTooManyToDelete(vanishing.count, of: here.union(there).count) ? Set(vanishing) : []

        // What has to come down before a notebook can be settled: the pages of one changed there, or the clippings
        // its cards there name. All of it is asked for now, so it comes down together, and those notebooks go last,
        // so a wait for them never holds up what this device sends.
        var needs: [UUID: [URL]] = [:]
        var moving = here.subtracting(there).subtracting(held)
        for id in there.subtracting(held) {
            guard let remote = glance(ofPackage: cloud.package(id)) else { continue }
            let local = here.contains(id) ? glance(ofPackage: root.package(id)) : nil
            if !same(remote.modifiedAt, local?.modifiedAt) { moving.insert(id) }
            if !same(remote.modifiedAt, local?.modifiedAt), !same(remote.modifiedAt, state.notebooks[id]) {
                needs[id] = needed(id, root: root, cloud: cloud)
            } else if local != nil {
                needs[id] = clippingsNeeded(id, root: root, cloud: cloud)
            }
            if needs[id]?.isEmpty == true { needs[id] = nil }
        }
        if !needs.isEmpty { _ = await access.fetch(needs.values.flatMap { $0 }, .zero) }
        // Notebooks both sides hold alike when the pass is done, whose pictures and recordings can then leave the device.
        var alike: [UUID] = []
        var done = 0
        progress(SyncProgress(done: 0, total: moving.count))

        do {
            func turn(_ id: UUID) -> (Int, String) { (needs[id] == nil ? 0 : 1, id.uuidString) }
            for id in here.union(there).union(state.notebooks.keys).sorted(by: { turn($0) < turn($1) }) {
                defer {
                    if moving.contains(id) {
                        done += 1
                        progress(SyncProgress(done: done, total: moving.count))
                    }
                }
                try checkStillWanted()
                if held.contains(id) {
                    report.held.append(id)
                    continue
                }
                // Waited for before the notebook is taken, so opening it isn't held up meanwhile. A version iCloud is
                // still bringing down is read once all of it has arrived, not part-way.
                if let wanted = needs[id], !(await access.fetch(wanted, .seconds(60))).isEmpty {
                    report.arriving.append(id)
                    continue
                }
                guard await take(id) else { report.open.append(id); continue }
                notebook: do {
                    let isHere = here.contains(id)
                    let local = isHere ? glance(ofPackage: root.package(id)) : nil
                    // An upload cut short left a package no device can read. With the notebook here, it is sent again.
                    let isThere = there.contains(id) && !(local != nil && isCutShort(cloud.package(id)))
                    let remote = isThere ? glance(ofPackage: cloud.package(id)) : nil
                    let agreed = state.notebooks[id]
                    if (isHere && local == nil) || (isThere && remote == nil) {
                        // One still on its way down is waited for, one that is there and won't read is damaged: neither goes over a good one.
                        if isHere && local == nil {
                            report.failed.append(SyncFailure(id: id, reason: .unreadable(inICloud: false)))
                        } else if isDamaged(cloud.package(id).appending(path: "manifest.json")) {
                            report.failed.append(SyncFailure(id: id, reason: .unreadable(inICloud: true)))
                        } else {
                            report.arriving.append(id)
                        }
                        break notebook
                    }
                    switch (local, remote) {
                    case (let local?, let remote?):
                        // Cards first, so whichever way the pages go they carry every card from both sides.
                        let cards = try settleCards(id, root: root, cloud: cloud)
                        if cards.here { report.cardsReceived.append(id) }
                        if cards.there { report.cardsSent.append(id) }
                        // The pages go by their date. How the notebook is filed is settled apart from them, so a pull
                        // never takes a lock off and a favourite never counts as an edit.
                        let inStep = same(local.modifiedAt, remote.modifiedAt)
                        let unchangedHere = inStep || (agreed != nil && same(local.modifiedAt, agreed) && !losesRecording(id, root: root, cloud: cloud))
                        let unchangedThere = inStep || (agreed != nil && same(remote.modifiedAt, agreed))
                        let wanted = LibraryState.settled(here: local.library, there: remote.library, written: (!unchangedHere, !unchangedThere), now: now)
                        var hereHolds = local.library, thereHolds = remote.library
                        // A marker beside a version it wasn't made for would mislead a new device: writing or a restore overrules it.
                        if let marker = try deleteMarker(id), !inStep || marker.covers((remote.modifiedAt, wanted ?? remote.library)) == false {
                            try? fileManager.removeItem(at: cloud.tombstone(id))
                        }
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
                            // Saved at once, so a pass cut short from here on doesn't find the conflict again and copy it twice.
                            try state.write(root)
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
                        state.trashStamps[id] = (wanted ?? remote.library).changedAt(.deleted)
                        alike.append(id)
                    case (let local?, nil):
                        // A marker carries a delete only to the version it was made for, and not over a restore made since.
                        let marker = try deleteMarker(id)
                        if carries(marker, to: local, agreed: agreed) {
                            if local.library.deletedAt == nil {
                                // Out of Recently Deleted here, it goes in there rather than for good. Stamped after the
                                // delete, so the next pass leaves it be.
                                var trashed = local.library
                                trashed.deletedAt = now
                                trashed.setChangedAt(LibraryState.stamp(after: marker?.trashStamp, at: now), for: .deleted)
                                guard try refile(id, as: trashed, inPackage: root.package(id)) else { throw PackageError.readOnly }
                                report.removedHere.append(id)
                            } else if !isTrashedSince(local.library, marker) {
                                try remove(root.package(id), root: root)
                                state.forget(id)
                                report.removedHere.append(id)
                            }
                        } else {
                            // New here, or changed here after it was deleted elsewhere: writing wins over a delete.
                            try? fileManager.removeItem(at: cloud.tombstone(id))
                            try push(id, from: root, to: cloud)
                            state.agree(on: id, local)
                            report.pushed.append(id)
                            alike.append(id)
                        }
                    case (nil, let remote?) where expiredOnlyHere(id, remote, agreed: agreed, expired: expired, now: now):
                        // Another device may keep Recently Deleted longer, and still have it there.
                        break
                    case (nil, let remote?):
                        if let agreed, same(remote.modifiedAt, agreed), !remote.library.wasRestored(since: state.trashStamps[id]) {
                            // It was here and in step, it's gone, and nobody has written in it or restored it since: it was deleted on this device.
                            try DeleteMarker(modifiedAt: remote.modifiedAt, trashStamp: remote.library.changedAt(.deleted), confirmed: lettingGo.contains(id), markedAt: now)
                                .encoded().write(to: cloud.tombstone(id), options: .atomic)
                            try coordinated(writing: cloud.package(id)) { try fileManager.removeItem(at: $0) }
                            state.forget(id)
                            report.removedThere.append(id)
                        } else if agreed == nil, let marker = try deleteMarker(id), marker.covers(remote) ?? true {
                            try coordinated(writing: cloud.package(id)) { try fileManager.removeItem(at: $0) }
                        } else {
                            // New there, or written in or restored there since this device last saw it: that wins over a delete.
                            try? fileManager.removeItem(at: cloud.tombstone(id))
                            try pull(id, from: cloud, into: root)
                            state.agree(on: id, remote)
                            report.pulled.append(id)
                            alike.append(id)
                        }
                    case (nil, nil):
                        state.forget(id)
                    }
                } catch SyncError.stillArriving {
                    report.arriving.append(id)
                } catch {
                    log.error("sync of \(id) failed: \(error.localizedDescription)")
                    report.failed.append(SyncFailure(id: id, reason: SyncFailure.Reason(error)))
                }
                await release(id)
            }
            expireMarkers(deleted.subtracting(here).subtracting(there), in: cloud, now: now)

            try checkStillWanted()
            let agreedFolders = state.folders, agreedList = state.folderList
            if let folders = try await holdingFolders({
                try syncFolders(root: root, cloud: cloud, agreed: agreedFolders, list: agreedList, replacing: replacingFolders)
            }) {
                report.foldersChanged = folders.changedHere
                report.foldersUnreadable = folders.unreadableThere
                state.folders = folders.agreed
                state.folderList = folders.list
            }
            let agreedShelves = state.smartShelves, shelfList = state.shelfList
            if let shelves = try await holdingShelves({ try syncSmartShelves(root: root, cloud: cloud, agreed: agreedShelves, list: shelfList) }) {
                report.shelvesChanged = shelves.changedHere
                state.smartShelves = shelves.agreed
                state.shelfList = shelves.list
            }
            if let pens {
                let settled = try syncPens(pens, cloud: cloud, now: now)
                report.pensReceived = settled.received
                report.pensSent = settled.sent
            }
            report.stickersChanged = try syncShelf(here: root.stickers, there: cloud.stickers, agreed: &state.stickers) { $0.hasSuffix(".png") }
            report.papersChanged = try syncShelf(here: root.papers, there: cloud.papers, agreed: &state.papers) {
                PaperShelf.extensions.contains(($0 as NSString).pathExtension)
            }
        } catch {
            // What was done before the pass stopped is kept as agreed, and handed back so the library hears of it.
            try? state.write(root)
            throw StoppedPass(report: report, reason: error)
        }
        try state.write(root)
        evictAssets(of: alike, in: cloud, access: access)
        return report
    }

    /// Takes the synced copy's pictures, PDFs, recordings and transcripts off the device, for notebooks a pass that
    /// worked left in step, once iCloud has them. A pass never reads them again: each is named once and never written
    /// again, so one of the same name here is the same file. Ink, manifests, cards and text stay, as every later push
    /// compares them with what is here.
    private static func evictAssets(of ids: [UUID], in cloud: CloudFolder, access: CloudAccess) {
        let fileManager = FileManager.default
        var evicted = 0
        for id in ids {
            let assets = cloud.package(id).appending(path: "assets", directoryHint: .isDirectory)
            for name in (try? fileManager.contentsOfDirectory(atPath: assets.path(percentEncoded: false))) ?? [] where CloudFiles.placeholderTarget(name) == nil {
                if access.evict(assets.appending(path: name)) { evicted += 1 }
            }
        }
        if evicted > 0 { log.notice("took \(evicted) files off the device") }
    }

    /// Clears away markers for notebooks gone from the synced copy and this device, once they are older than
    /// `DeleteMarker.keptForDays`. One still on its way down is left for a later pass.
    private static func expireMarkers(_ ids: Set<UUID>, in cloud: CloudFolder, now: Date) {
        let cutoff = TrashLength.cutoff(DeleteMarker.keptForDays, now: now)
        for id in ids {
            let url = cloud.tombstone(id)
            guard let data = try? contents(of: url) else { continue }
            let written = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            guard let marked = DeleteMarker(data).markedAt ?? written, marked < cutoff else { continue }
            do {
                try coordinated(writing: url) { try FileManager.default.removeItem(at: $0) }
            } catch {
                log.error("marker for \(id) couldn't be cleared: \(error.localizedDescription)")
            }
        }
    }

    // MARK: Copying notebooks

    /// Thumbnails are made again where they're needed, and a file set aside as damaged stays on the device it was found on.
    private static func travels(_ relative: String) -> Bool {
        !relative.hasPrefix("thumbs/") && relative != "thumbs" && !relative.contains(".corrupt")
    }

    private static func path(of url: URL, in package: URL) -> String {
        let base = package.standardizedFileURL.path(percentEncoded: false)
        return String(url.standardizedFileURL.path(percentEncoded: false).dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// Takes thumbnails and files set aside as damaged out of a package assembled from this device's.
    private static func leaveBehind(in package: URL) {
        let items = FileManager.default.enumerator(at: package, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        for url in items where !travels(path(of: url, in: package)) { try? FileManager.default.removeItem(at: url) }
    }

    /// A file iCloud hasn't brought down yet is listed under its real name, at its placeholder.
    private static func files(in package: URL) -> [String: URL] {
        var result: [String: URL] = [:]
        let enumerator = FileManager.default.enumerator(at: package, includingPropertiesForKeys: [.isRegularFileKey])
        while let url = enumerator?.nextObject() as? URL {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            var relative = path(of: url, in: package)
            if let name = CloudFiles.placeholderTarget(url.lastPathComponent) {
                relative = String(relative.dropLast(url.lastPathComponent.count)) + name
                if result[relative] != nil { continue }
            }
            if travels(relative) { result[relative] = url }
        }
        return result
    }

    /// Whether a file's bytes are on the device as iCloud last had them: not a placeholder, and not an older version.
    private static func isOnDevice(_ url: URL) -> Bool {
        guard CloudFiles.placeholderTarget(url.lastPathComponent) == nil else { return false }
        let status = (try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?.ubiquitousItemDownloadingStatus
        return status == nil || status == .current
    }

    private static func digest(_ url: URL) -> String? {
        (try? Data(contentsOf: url, options: .mappedIfSafe)).map(NotebookPackage.hash)
    }

    private static func size(_ url: URL) -> Int? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
    }

    /// Each page's ink file and the hash its manifest gives it.
    private static func inkHashes(ofPackage url: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: url.appending(path: "manifest.json")),
              let manifest = try? ManifestCodec.decode(data, fallbackID: UUID()).manifest else { return [:] }
        return Dictionary(manifest.pages.compactMap { page in page.inkHash.map { (page.inkFile, $0) } }, uniquingKeysWith: { first, _ in first })
    }

    /// Whether `destination` already holds what `source` does. Two files on the device are the same when their sizes
    /// and hashes are. A picture, PDF, recording, transcript or clipping is named once and never written again, so one
    /// of the same name is the same file even when either is only in iCloud. Ink not on the device is the same when
    /// what `destination` holds is what `hash`, from the source's manifest, says. The manifests decide everything, so
    /// they are always copied.
    private static func same(_ relative: String, _ source: URL, _ destination: URL, hash: String? = nil) -> Bool {
        guard !relative.hasPrefix("manifest") else { return false }
        let sourceHere = isOnDevice(source), destinationHere = isOnDevice(destination)
        if relative.hasPrefix("assets/") || relative.hasPrefix("cards/") {
            return !(sourceHere && destinationHere) || size(source) == size(destination)
        }
        guard destinationHere else { return false }
        if sourceHere { return size(source) == size(destination) && digest(source) == digest(destination) }
        return hash != nil && digest(destination) == hash
    }

    /// What has to come down from a notebook in the synced copy before this device can take it: every file not on
    /// the device that isn't the same as the one here.
    private static func needed(_ id: UUID, root: StorageRoot, cloud: CloudFolder) -> [URL] {
        let source = cloud.package(id), here = root.package(id), hashes = inkHashes(ofPackage: source)
        return files(in: source).compactMap { relative, url in
            guard !isOnDevice(url) else { return nil }
            let local = here.appending(path: relative)
            if FileManager.default.fileExists(atPath: local.path(percentEncoded: false)), same(relative, url, local, hash: hashes[relative]) { return nil }
            return source.appending(path: relative)
        }.sorted { $0.path < $1.path }
    }

    /// The clippings a notebook's cards there name that aren't here and aren't on the device, when its cards differ.
    private static func clippingsNeeded(_ id: UUID, root: StorageRoot, cloud: CloudFolder) -> [URL] {
        let source = cloud.package(id), here = root.package(id)
        guard let data = try? Data(contentsOf: CardFiles.file(in: source)), data != (try? Data(contentsOf: CardFiles.file(in: here))),
              let deck = CardFiles.deck(from: data) else { return [] }
        return deck.clippings.sorted().map { CardFiles.imageURL($0, in: source) }.filter { url in
            CloudFiles.isPending(url) && !FileManager.default.fileExists(atPath: CardFiles.imageURL(url.lastPathComponent, in: here).path(percentEncoded: false))
        }
    }

    /// The files a pass decides on: the copy's name, the folder list, the delete markers, stickers and papers, and each
    /// notebook's manifest and cards, all of them small.
    static func deciding(in cloud: CloudFolder) -> [URL] {
        let fileManager = FileManager.default
        func listed(_ directory: URL) -> [URL] {
            ((try? fileManager.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []).map {
                directory.appending(path: CloudFiles.placeholderTarget($0) ?? $0)
            }
        }
        var files = [cloud.copyFile, cloud.foldersFile, cloud.smartShelvesFile, cloud.pensFile] + listed(cloud.tombstones) + listed(cloud.stickers) + listed(cloud.papers)
        for package in listed(cloud.library) where package.pathExtension == StorageRoot.packageExtension {
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: package.path(percentEncoded: false), isDirectory: &isDirectory), isDirectory.boolValue {
                files += [package.appending(path: "manifest.json"), CardFiles.file(in: package)]
            } else {
                // Listed as one item, it can only come down whole.
                files.append(package)
            }
        }
        return files
    }

    /// Makes `destination` hold what `source` holds: files that differ are copied, files that are gone are removed
    /// unless `kept`, and the manifest goes last so a reader never sees it name ink that hasn't arrived. `hashes` are
    /// the source manifest's for its ink, when the source is the synced copy.
    private static func mirror(_ source: URL, to destination: URL, hashes: [String: String] = [:], keeping kept: (String) -> Bool = { _ in false }) throws {
        let wanted = files(in: source), present = files(in: destination)
        var redated = 0
        for (relative, url) in wanted.sorted(by: { ($0.key == "manifest.json" ? 1 : 0, $0.key) < ($1.key == "manifest.json" ? 1 : 0, $1.key) }) {
            if let existing = present[relative], same(relative, url, existing, hash: hashes[relative]) {
                if let a = modified(url), let b = modified(existing), abs(a.timeIntervalSince(b)) >= 0.000_002 { redated += 1 }
                continue
            }
            guard CloudFiles.placeholderTarget(url.lastPathComponent) == nil else { throw SyncError.stillArriving }
            try copy(url, over: destination.appending(path: relative))
        }
        for (relative, url) in present where wanted[relative] == nil && !kept(relative) { try? FileManager.default.removeItem(at: url) }
        // What a real device says of the dates iCloud keeps: a date-only check would have copied these again.
        if redated > 0 { log.notice("\(redated) files were the same but dated differently") }
    }

    private static func modified(_ url: URL) -> Date? {
        guard isOnDevice(url) else { return nil }
        return (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// Copies one file over another, through a temporary name, so a reader never finds half of it.
    private static func copy(_ source: URL, over target: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staged = target.deletingLastPathComponent().appending(path: ".\(UUID().uuidString).part")
        try fileManager.copyItem(at: source, to: staged)
        _ = try fileManager.replaceItemAt(target, withItemAt: staged)
    }

    private static func coordinated(writing url: URL, _ work: (URL) throws -> Void) throws {
        var coordinationError: NSError?
        var failure: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forMerging, error: &coordinationError) { granted in
            do { try work(granted) } catch { failure = error }
        }
        if let coordinationError { throw CoordinationError(underlying: coordinationError) }
        if let failure { throw failure }
    }

    private static func coordinated(reading url: URL, _ work: (URL) throws -> Void) throws {
        var coordinationError: NSError?
        var failure: Error?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { granted in
            do { try work(granted) } catch { failure = error }
        }
        if let coordinationError { throw CoordinationError(underlying: coordinationError) }
        if let failure { throw failure }
    }

    /// A notebook new to the synced copy is assembled under another name and moved in whole, so an upload cut
    /// short never leaves a package without its manifest for every device to wait on.
    private static func push(_ id: UUID, from root: StorageRoot, to cloud: CloudFolder) throws {
        let fileManager = FileManager.default, target = cloud.package(id)
        guard !fileManager.fileExists(atPath: target.path(percentEncoded: false)) else {
            return try coordinated(writing: target) { try mirror(root.package(id), to: $0) }
        }
        let staging = cloud.upload(id)
        do {
            try coordinated(writing: staging) { try mirror(root.package(id), to: $0) }
            try coordinated(writing: target) { try fileManager.moveItem(at: staging, to: $0) }
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
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
        // A clipping made here for a card not yet written stays; the cards file clears away ones no card names.
        try coordinated(reading: cloud.package(id)) { try mirror($0, to: staging, hashes: inkHashes(ofPackage: $0), keeping: { $0.hasPrefix("cards/") }) }
        guard stamp(ofPackage: staging) != nil else { throw PackageError.unreadable }
        guard isWhole(staging) else { throw SyncError.stillArriving }
        if let library { _ = try refile(id, as: library, inPackage: staging) }
        try? fileManager.removeItem(at: staging.appending(path: "thumbs"))
        try fileManager.setAttributes([.modificationDate: Date.now], ofItemAtPath: staging.appending(path: "manifest.json").path(percentEncoded: false))
        if fileManager.fileExists(atPath: target.path(percentEncoded: false)) {
            _ = try fileManager.replaceItemAt(target, withItemAt: staging)
        } else {
            try fileManager.moveItem(at: staging, to: target)
        }
    }

    /// What a pull of one notebook found: nothing newer in the synced copy (or nothing it can settle alone, which a pass
    /// does), the newer version brought in, or a newer version left there because this device wrote in it too or `take` said no.
    enum Newer: Sendable, Equatable { case none, pulled, waiting }

    /// Brings one notebook's newer version in without a whole pass, when nothing was written in it here since the two
    /// last agreed. iCloud has up to `timeout` to bring down its manifest and then what differs; `take` is asked just
    /// before it is swapped in.
    static func pullNewer(_ id: UUID, root: StorageRoot, cloud: CloudFolder, timeout: Duration, now: Date = .now, access: CloudAccess? = nil,
                          take: @Sendable (UUID) async -> Bool = { _ in true }, release: @Sendable (UUID) async -> Void = { _ in }) async throws -> Newer {
        try Task.checkCancellation()
        let package = cloud.package(id), access = access ?? .live(cloud), deadline = ContinuousClock.now + timeout
        _ = await access.fetch([cloud.copyFile, cloud.tombstone(id), package.appending(path: "manifest.json"), CardFiles.file(in: package)], timeout)
        var state = SyncState.read(root)
        // One never agreed on, a copy this device doesn't know, or a delete marker is for a pass to settle.
        guard let agreed = state.notebooks[id], let known = state.copy, try copyID(in: cloud) == known, !(try isPresent(cloud.tombstone(id))),
              let local = glance(ofPackage: root.package(id)), let remote = glance(ofPackage: package),
              !same(remote.modifiedAt, agreed), !same(remote.modifiedAt, local.modifiedAt) else { return .none }
        guard same(local.modifiedAt, agreed), !losesRecording(id, root: root, cloud: cloud) else { return .waiting }
        let wanted = needed(id, root: root, cloud: cloud)
        if !wanted.isEmpty, !(await access.fetch(wanted, max(deadline - ContinuousClock.now, .zero))).isEmpty { return .none }
        guard await take(id) else { return .waiting }
        do {
            // Saved here while it was being taken: a pass keeps both.
            guard let taken = glance(ofPackage: root.package(id)), same(taken.modifiedAt, agreed) else {
                await release(id)
                return .waiting
            }
            _ = try settleCards(id, root: root, cloud: cloud)
            let wanted = LibraryState.settled(here: taken.library, there: remote.library, written: (false, true), now: now)
            try pull(id, from: cloud, into: root, filedAs: wanted)
            state.notebooks[id] = remote.modifiedAt
            state.trashStamps[id] = (wanted ?? remote.library).changedAt(.deleted)
            try state.write(root)
        } catch SyncError.stillArriving {
            await release(id)
            return .none
        } catch {
            await release(id)
            throw error
        }
        await release(id)
        return .pulled
    }

    /// What sending an open notebook found: nothing new here to send, or nothing it can settle alone (a pass does once
    /// the notebook closes); the pages sent; or the synced copy written in since the two last agreed as well.
    enum Sent: Sendable, Equatable { case none, sent, waiting }

    /// Sends one notebook written in here while it is open, when the synced copy still holds the version both last
    /// agreed on, so another device with it open can take it in place. `hold` gives the package to copy from, whose
    /// own writes wait while it is copied, so what goes up is one save, whole; nil when it can't be taken now.
    /// Returns what it found, and whether the notebook's cards took something from the synced copy's.
    static func pushNewer(_ id: UUID, root: StorageRoot, cloud: CloudFolder, timeout: Duration, now: Date = .now, access: CloudAccess? = nil,
                          hold: @Sendable (UUID) async -> NotebookPackage?, release: @Sendable (UUID) async -> Void = { _ in }) async throws -> (sent: Sent, cardsReceived: Bool) {
        try Task.checkCancellation()
        let package = cloud.package(id), access = access ?? .live(cloud), manifest = package.appending(path: "manifest.json")
        _ = await access.fetch([cloud.copyFile, cloud.tombstone(id), manifest, CardFiles.file(in: package)], timeout)
        let state = SyncState.read(root)
        // One never agreed on, a copy this device doesn't know, a delete marker or a version still coming down is for a pass.
        guard let agreed = state.notebooks[id], let known = state.copy, try copyID(in: cloud) == known, !(try isPresent(cloud.tombstone(id))),
              let local = glance(ofPackage: root.package(id)), let remote = glance(ofPackage: package),
              !same(local.modifiedAt, agreed), !access.isBehind(manifest) else { return (.none, false) }
        guard same(remote.modifiedAt, agreed) else { return (same(remote.modifiedAt, local.modifiedAt) ? .none : .waiting, false) }
        // Filing another device changed would be written over by the open notebook's own: that waits for a pass.
        if let wanted = LibraryState.settled(here: local.library, there: remote.library, written: (true, false), now: now), local.library.trails(wanted) {
            return (.none, false)
        }
        guard let held = await hold(id) else { return (.none, false) }
        do {
            let cards = try settleCards(id, root: root, cloud: cloud)
            let sent = try await held.hold { () throws -> (modifiedAt: Date, deleted: Date?)? in
                guard let taken = glance(ofPackage: root.package(id)), !same(taken.modifiedAt, agreed),
                      let there = glance(ofPackage: package), same(there.modifiedAt, agreed), !losesRecording(id, root: root, cloud: cloud) else { return nil }
                try push(id, from: root, to: cloud)
                return (taken.modifiedAt, taken.library.changedAt(.deleted))
            }
            if let sent {
                var state = SyncState.read(root)
                state.notebooks[id] = sent.modifiedAt
                state.trashStamps[id] = sent.deleted
                try state.write(root)
            }
            await release(id)
            return (sent == nil ? .none : .sent, cards.here)
        } catch {
            await release(id)
            throw error
        }
    }

    /// Keeps both versions of a notebook written in here and on another device, while it is open, as a pass would
    /// once it closed: the older is kept as a conflicted copy and the newer stays under the notebook's ID everywhere.
    /// `take` is told whether the files here are to be replaced, when the synced copy's version is the newer: the
    /// editor then gives way to it. Otherwise this device's is sent, its writes waiting meanwhile. Returns the copy and
    /// whether the newer version was brought in; nil when there are no longer two versions, or the synced copy's
    /// hasn't all come down within `timeout`.
    static func keepBoth(_ id: UUID, root: StorageRoot, cloud: CloudFolder, timeout: Duration, now: Date = .now, access: CloudAccess? = nil,
                         take: @Sendable (UUID, _ replacing: Bool) async -> NotebookPackage?,
                         release: @Sendable (UUID) async -> Void = { _ in }) async throws -> (copy: UUID, pulled: Bool)? {
        try Task.checkCancellation()
        let package = cloud.package(id), access = access ?? .live(cloud), deadline = ContinuousClock.now + timeout
        _ = await access.fetch([cloud.copyFile, cloud.tombstone(id), package.appending(path: "manifest.json"), CardFiles.file(in: package)], timeout)
        let state = SyncState.read(root)
        guard let agreed = state.notebooks[id], let known = state.copy, try copyID(in: cloud) == known, !(try isPresent(cloud.tombstone(id))),
              let local = glance(ofPackage: root.package(id)), let remote = glance(ofPackage: package),
              !same(local.modifiedAt, agreed), !same(remote.modifiedAt, agreed), !same(local.modifiedAt, remote.modifiedAt) else { return nil }
        let wanted = needed(id, root: root, cloud: cloud)
        if !wanted.isEmpty, !(await access.fetch(wanted, max(deadline - ContinuousClock.now, .zero))).isEmpty { return nil }
        let remoteIsNewer = remote.modifiedAt > local.modifiedAt
        guard let held = await take(id, remoteIsNewer) else { return nil }
        do {
            _ = try settleCards(id, root: root, cloud: cloud)
            let copy = try await held.hold { () throws -> UUID? in
                guard let here = glance(ofPackage: root.package(id)), let there = glance(ofPackage: package),
                      !same(here.modifiedAt, agreed), !same(there.modifiedAt, agreed), !same(here.modifiedAt, there.modifiedAt) else { return nil }
                var state = SyncState.read(root)
                let copy = try keepCopy(of: id, fromSyncedCopy: !remoteIsNewer, locked: here.library.isLocked || there.library.isLocked, root: root, cloud: cloud)
                state.notebooks[id] = remoteIsNewer ? here.modifiedAt : there.modifiedAt
                try state.write(root)
                let filing = LibraryState.settled(here: here.library, there: there.library, written: (true, true), now: now)
                var thereHolds = there.library
                if remoteIsNewer {
                    try pull(id, from: cloud, into: root, filedAs: filing)
                    state.notebooks[id] = there.modifiedAt
                } else {
                    // The open notebook writes its own filing back, so what this device lacks comes in once it closes.
                    try push(id, from: root, to: cloud)
                    thereHolds = here.library
                    state.notebooks[id] = here.modifiedAt
                }
                if let filing, thereHolds.trails(filing) {
                    try coordinated(writing: package) { _ = try refile(id, as: filing, inPackage: $0) }
                }
                state.trashStamps[id] = (filing ?? there.library).changedAt(.deleted)
                try state.write(root)
                return copy
            }
            await release(id)
            return copy.map { ($0, remoteIsNewer) }
        } catch {
            await release(id)
            throw error
        }
    }

    /// Whether a package holds each page's ink as its manifest hashes it, and every asset it names: iCloud may bring the manifest down first.
    private static func isWhole(_ package: URL) -> Bool {
        let fileManager = FileManager.default
        func exists(_ relative: String) -> Bool { fileManager.fileExists(atPath: package.appending(path: relative).path(percentEncoded: false)) }
        guard let data = try? Data(contentsOf: package.appending(path: "manifest.json")),
              let manifest = try? ManifestCodec.decode(data, fallbackID: UUID()).manifest else { return true }
        for page in manifest.pages {
            guard let hash = page.inkHash else {
                if exists(page.inkFile) { return false }
                continue
            }
            guard let ink = try? Data(contentsOf: package.appending(path: page.inkFile), options: .mappedIfSafe), NotebookPackage.hash(ink) == hash else { return false }
        }
        let assets = manifest.pages.compactMap(\.background.assetFile) + manifest.unfinishedRecordings.map(\.file)
            + manifest.recordings.flatMap { [$0.file] + [$0.transcriptFile].compactMap { $0 } }
        return assets.allSatisfy { exists("assets/\($0)") }
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
            // Made from what is here where the two are the same, so only what differs comes down.
            try fileManager.copyItem(at: root.package(id), to: staging)
            try coordinated(reading: cloud.package(id)) { try mirror($0, to: staging, hashes: inkHashes(ofPackage: $0)) }
            leaveBehind(in: staging)
            guard isWhole(staging) else { throw SyncError.stillArriving }
        } else {
            try fileManager.copyItem(at: root.package(id), to: staging)
        }
        let manifestURL = staging.appending(path: "manifest.json")
        var manifest = try ManifestCodec.decode(Data(contentsOf: manifestURL), fallbackID: id).manifest
        guard !manifest.isNewerThanSupported else { throw PackageError.readOnly }
        manifest.id = copy
        manifest.title = String(localized: "\(manifest.title) (conflicted copy)")
        manifest.library.isFavorite = false
        manifest.library.isJournal = false
        if locked { manifest.library.isLocked = true }
        try ManifestCodec.encode(manifest).write(to: manifestURL, options: .atomic)
        try CardFiles.renew(in: staging)
        try fileManager.moveItem(at: staging, to: root.package(copy))
        return copy
    }

    // MARK: Flashcards

    /// A notebook's cards are settled one at a time and apart from its pages, so cards made or answered on either side
    /// are all kept, and a card deleted on one stays deleted. Clippings go before the cards that name them. A file this
    /// version can't read or mustn't write is left to go with its pages. Returns which sides took something.
    private static func settleCards(_ id: UUID, root: StorageRoot, cloud: CloudFolder) throws -> (here: Bool, there: Bool) {
        let fileManager = FileManager.default
        let herePackage = root.package(id), therePackage = cloud.package(id)
        let hereFile = CardFiles.file(in: herePackage), thereFile = CardFiles.file(in: therePackage)
        let hereData = fileManager.fileExists(atPath: hereFile.path(percentEncoded: false)) ? try Data(contentsOf: hereFile) : nil
        let thereData = try contents(of: thereFile)
        guard hereData != thereData else { return (false, false) }
        func deck(_ data: Data?) -> CardFiles.Deck? {
            guard let data else { return CardFiles.Deck() }
            return CardFiles.deck(from: data).flatMap { $0.isReadOnly ? nil : $0 }
        }
        guard let here = deck(hereData), let there = deck(thereData) else { return (false, false) }
        let merged = here.merged(with: there)
        let changesHere = merged != here, changesThere = merged != there
        if changesHere {
            try coordinated(reading: therePackage) { package in
                for name in merged.clippings where !fileManager.fileExists(atPath: CardFiles.imageURL(name, in: herePackage).path(percentEncoded: false)) {
                    if try isPresent(CardFiles.imageURL(name, in: package)) { try copy(CardFiles.imageURL(name, in: package), over: CardFiles.imageURL(name, in: herePackage)) }
                }
            }
            if changesThere {
                try CardFiles.write(merged, to: herePackage)
            } else {
                try coordinated(reading: thereFile) { try copy($0, over: hereFile) }
            }
        }
        if changesThere {
            try coordinated(writing: therePackage) { package in
                // One iCloud has taken off the device is still there.
                for name in merged.clippings where !isListed(CardFiles.imageURL(name, in: package)) {
                    let clipping = CardFiles.imageURL(name, in: herePackage)
                    if fileManager.fileExists(atPath: clipping.path(percentEncoded: false)) { try copy(clipping, over: CardFiles.imageURL(name, in: package)) }
                }
                try copy(hereFile, over: CardFiles.file(in: package))
            }
        }
        return (changesHere, changesThere)
    }

    // MARK: Folders and stickers

    /// A three-way merge on which folders exist: one added on either side is kept, one deleted on either side goes.
    /// A folder both sides have is settled field by field, each by when it was last changed. Either list being there
    /// and unreadable is waited for: nothing is written, and nothing is taken as deleted. Nil when it is this one.
    /// `replacing` puts a new list made from this device's folders in place of a synced one that can't be read,
    /// and keeps the damaged one aside here.
    private static func syncFolders(root: StorageRoot, cloud: CloudFolder, agreed: Set<UUID>, list: String?, replacing: Bool) throws -> FolderPass? {
        let local: FolderFile
        do {
            local = try FolderFile.load(root) ?? FolderFile()
        } catch {
            log.error("folders here can't be read: \(error.localizedDescription)")
            return nil
        }
        var remote = FolderFile(), isThere = false, replaced = false
        if let data = try contents(of: cloud.foldersFile) {
            isThere = true
            if let file = FolderFile(data) {
                remote = file
            } else if replacing {
                let aside = root.library.appending(path: "icloud-folders.json")
                try data.write(to: aside, options: .atomic)
                try Quarantine.move(aside)
                replaced = true
            } else {
                // Not written over unasked: a folder only that list holds would then be taken as deleted on every other device.
                log.error("folders in the synced copy can't be read")
                return FolderPass(changedHere: false, agreed: agreed, list: list, unreadableThere: true)
            }
        }
        // A list other than the one agreed with, made again or named since, says nothing of what was deleted: this pass only adds.
        let agreed = !replaced && remote.listID == list ? agreed : []
        func modified(_ url: URL) -> Date { (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast }
        let localIsNewer = modified(root.foldersFile) >= modified(cloud.foldersFile)
        let localByID = Dictionary(local.folders.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let remoteByID = Dictionary(remote.folders.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var merged: [FolderEntry] = []
        for id in (localIsNewer ? local.folders + remote.folders : remote.folders + local.folders).map(\.id) where !merged.contains(where: { $0.id == id }) {
            let wasAgreed = agreed.contains(id)
            switch (localByID[id], remoteByID[id]) {
            case (let here?, let there?): merged.append(localIsNewer ? .settled(newer: here, older: there) : .settled(newer: there, older: here))
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
        var changedHere = false
        if merged != local.folders {
            var file = local
            file.folders = merged
            try file.write(root)
            changedHere = true
        }
        if merged != remote.folders || (remote.listID == nil && (isThere || !merged.isEmpty)) {
            var file = remote
            file.folders = merged
            file.listID = file.listID ?? UUID().uuidString
            let data = try file.encoded()
            try coordinated(writing: cloud.foldersFile) { try data.write(to: $0, options: .atomic) }
            remote = file
        }
        return FolderPass(changedHere: changedHere, agreed: ids, list: remote.listID)
    }

    /// The smart shelves are merged as the folders are: an add or a delete on either side carries over, and a shelf
    /// both sides have takes whichever was changed last. Either side without a list, or a list made again, only adds.
    /// A list in iCloud that can't be read gives way to this device's under a new name, the damaged one kept aside
    /// here, and every other device adds its own to it. Nil when this device's can't be read, or iCloud's is on its way.
    private static func syncSmartShelves(root: StorageRoot, cloud: CloudFolder, agreed: Set<UUID>, list: String?) throws -> FolderPass? {
        var local = SmartShelfFile(), isHere = false
        if let data = try? Data(contentsOf: root.smartShelvesFile) {
            guard let file = SmartShelfFile(data) else {
                log.error("smart shelves here can't be read")
                return nil
            }
            local = file
            isHere = true
        }
        var remote = SmartShelfFile(), isThere = false, replaced = false
        let data: Data?
        do { data = try contents(of: cloud.smartShelvesFile) } catch SyncError.stillArriving { return nil }
        if let data {
            if let file = SmartShelfFile(data) {
                remote = file
                isThere = true
            } else {
                log.error("smart shelves in the synced copy can't be read; this device's take their place")
                let aside = root.library.appending(path: "icloud-smart-shelves.json")
                try data.write(to: aside, options: .atomic)
                try Quarantine.move(aside)
                replaced = true
            }
        }
        let agreed = isHere && isThere && remote.listID == list ? agreed : []
        func modified(_ url: URL) -> Date { (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast }
        let localIsNewer = modified(root.smartShelvesFile) >= modified(cloud.smartShelvesFile)
        let localByID = Dictionary(local.shelves.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let remoteByID = Dictionary(remote.shelves.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var merged: [SmartShelf] = []
        for id in (localIsNewer ? local.shelves + remote.shelves : remote.shelves + local.shelves).map(\.id) where !merged.contains(where: { $0.id == id }) {
            switch (localByID[id], remoteByID[id]) {
            case (let here?, let there?):
                let hereAt = here.changedAt ?? .distantPast, thereAt = there.changedAt ?? .distantPast
                merged.append(hereAt == thereAt ? (localIsNewer ? here : there) : hereAt > thereAt ? here : there)
            case (let here?, nil): if !agreed.contains(id) { merged.append(here) }
            case (nil, let there?): if !agreed.contains(id) { merged.append(there) }
            case (nil, nil): break
            }
        }
        var changedHere = false
        if merged != local.shelves {
            var file = local
            file.shelves = merged
            try file.write(root)
            changedHere = true
        }
        if merged != remote.shelves || replaced || (remote.listID == nil && (isThere || !merged.isEmpty)) {
            var file = remote
            file.shelves = merged
            if replaced || file.listID == nil { file.listID = UUID().uuidString }
            let data = try file.encoded()
            try coordinated(writing: cloud.smartShelvesFile) { try data.write(to: $0, options: .atomic) }
            remote = file
        }
        return FolderPass(changedHere: changedHere, agreed: Set(merged.map(\.id)), list: remote.listID)
    }

    /// The pens in the tray go as one list, and the list changed last wins. Pens never changed since changes were
    /// stamped give way to ones that were, and where neither side's were, the two are put together once, unless one
    /// side still has the pens a tray starts with. Returns the pens this device is to take, and whether its own went up.
    private static func syncPens(_ here: SyncedPens, cloud: CloudFolder, now: Date) throws -> (received: SyncedPens?, sent: Bool) {
        var extra: [String: JSONValue] = [:], there: SyncedPens?
        if let data = try contents(of: cloud.pensFile), var object = (try? JSONValue.parse(data))?.objectValue {
            let entries = object.removeValue(forKey: "pens")?.arrayValue ?? []
            let changedAt = object.removeValue(forKey: "changedAt")?.stringValue.flatMap(ManifestCodec.parseDate)
            extra = object
            let presets = entries.compactMap { entry in (try? entry.serialized(pretty: false)).flatMap { try? JSONDecoder().decode(ToolPreset.self, from: $0) } }
            if presets.contains(where: { $0.inkType != nil }) { there = SyncedPens(presets: presets, changedAt: changedAt) }
        }
        // A stamp is kept to the millisecond, so one read back is the same stamp.
        func alike(_ x: SyncedPens, _ y: SyncedPens) -> Bool { x.presets == y.presets && same(x.changedAt, y.changedAt) }
        func send(_ pens: SyncedPens) throws -> (received: SyncedPens?, sent: Bool) {
            var object = extra
            object["pens"] = .array(try pens.presets.map { try JSONValue.parse(JSONEncoder().encode($0)) })
            object["changedAt"] = pens.changedAt.map(ManifestCodec.encodeDate)
            let data = try JSONValue.object(object).serialized()
            try coordinated(writing: cloud.pensFile) { try data.write(to: $0, options: .atomic) }
            var written = pens
            written.changedAt = pens.changedAt.flatMap { ManifestCodec.encodeDate($0).stringValue }.flatMap(ManifestCodec.parseDate)
            return (alike(written, here) ? nil : written, true)
        }
        guard let there else { return try send(here) }
        guard !alike(here, there) else { return (nil, false) }
        switch (here.changedAt, there.changedAt) {
        case (let hereAt?, let thereAt?):
            return hereAt > thereAt && !same(hereAt, thereAt) ? try send(here) : (there, false)
        case (_?, nil):
            return try send(here)
        case (nil, let thereAt):
            let merged = SyncedPens.merged(there.presets, here.presets)
            if here.isAsItStarted || merged == there.presets { return (there, false) }
            if thereAt == nil, there.isAsItStarted { return try send(SyncedPens(presets: here.presets, changedAt: now)) }
            return try send(SyncedPens(presets: merged, changedAt: now))
        }
    }

    /// Stickers and papers: files that are only ever added or deleted whole, never changed.
    private static func syncShelf(here local: URL, there remote: URL, agreed: inout Set<String>, accepting accepts: (String) -> Bool) throws -> Bool {
        let fileManager = FileManager.default
        // A file iCloud has evicted, or not brought down yet, is still there, listed as ".<name>.icloud".
        func names(_ directory: URL) -> Set<String> {
            Set(((try? fileManager.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []).map { CloudFiles.placeholderTarget($0) ?? $0 }.filter(accepts))
        }
        func placeholder(_ name: String) -> URL? {
            let url = remote.appending(path: ".\(name).icloud")
            return fileManager.fileExists(atPath: url.path(percentEncoded: false)) ? url : nil
        }
        let here = names(local), there = names(remote)
        var changedHere = false
        for name in here.union(there) {
            let wasAgreed = agreed.contains(name)
            switch (here.contains(name), there.contains(name)) {
            case (true, false):
                if wasAgreed {
                    try? fileManager.removeItem(at: local.appending(path: name))
                    changedHere = true
                } else {
                    try fileManager.createDirectory(at: remote, withIntermediateDirectories: true)
                    try coordinated(writing: remote.appending(path: name)) { try fileManager.copyItem(at: local.appending(path: name), to: $0) }
                }
            case (false, true):
                if wasAgreed {
                    try coordinated(writing: placeholder(name) ?? remote.appending(path: name)) { try fileManager.removeItem(at: $0) }
                } else if placeholder(name) == nil {
                    try fileManager.createDirectory(at: local, withIntermediateDirectories: true)
                    try fileManager.copyItem(at: remote.appending(path: name), to: local.appending(path: name))
                    changedHere = true
                }
            default:
                break
            }
        }
        agreed = names(local).intersection(names(remote))
        return changedHere
    }
}

/// Getting files in an iCloud container onto the device before they are read.
enum CloudFiles {
    /// The real name of a file iCloud lists as ".<name>.icloud" until it is downloaded, nil for any other file.
    static func placeholderTarget(_ name: String) -> String? {
        name.hasPrefix(".") && name.hasSuffix(".icloud") && name.count > 8 ? String(name.dropFirst().dropLast(7)) : nil
    }

    /// Whether a file in an iCloud container isn't on the device yet: a placeholder, or an item iCloud says isn't downloaded.
    static func isPending(_ url: URL) -> Bool {
        let placeholder = url.deletingLastPathComponent().appending(path: ".\(url.lastPathComponent).icloud")
        if FileManager.default.fileExists(atPath: placeholder.path(percentEncoded: false)) { return true }
        return values(url, [.ubiquitousItemDownloadingStatusKey])?.ubiquitousItemDownloadingStatus == .notDownloaded
    }

    /// Read afresh each time, as a URL keeps what it was told.
    private static func values(_ url: URL, _ keys: Set<URLResourceKey>) -> URLResourceValues? {
        var url = url
        url.removeAllCachedResourceValues()
        return try? url.resourceValues(forKeys: keys)
    }

    /// Asks for files to be downloaded, an older version too, and waits up to `limit` for those not on the device.
    /// It stops sooner once nothing has come for `quiet`, or iCloud has given a reason for each, as it does with no
    /// network, so a pass isn't held up for what can't come. Returns what hadn't arrived.
    static func download(_ files: [URL], within limit: Duration, quiet: Duration = .seconds(10)) async -> [URL] {
        let clock = ContinuousClock(), deadline = clock.now + limit
        for file in files where isPending(file) || downloadingStatus(file) == .downloaded {
            try? FileManager.default.startDownloadingUbiquitousItem(at: file)
        }
        var waiting = files.filter(isPending), lastArrival = clock.now
        while !waiting.isEmpty, clock.now < deadline, clock.now - lastArrival < quiet, !Task.isCancelled, !waiting.allSatisfy(cannotDownload) {
            try? await Task.sleep(for: .milliseconds(500))
            for file in waiting { try? FileManager.default.startDownloadingUbiquitousItem(at: file) }
            let still = waiting.filter(isPending)
            if still.count < waiting.count { lastArrival = clock.now }
            waiting = still
        }
        return waiting
    }

    /// Whether iCloud has a newer version of a file on the device than the one here.
    static func isBehind(_ url: URL) -> Bool {
        downloadingStatus(url) == .downloaded
    }

    private static func downloadingStatus(_ url: URL) -> URLUbiquitousItemDownloadingStatus? {
        values(url, [.ubiquitousItemDownloadingStatusKey])?.ubiquitousItemDownloadingStatus
    }

    private static func cannotDownload(_ url: URL) -> Bool {
        values(url, [.ubiquitousItemDownloadingErrorKey])?.ubiquitousItemDownloadingError != nil
    }

    /// Takes a file's copy off the device, once iCloud has all of it and nothing more is on its way up.
    static func evict(_ url: URL) -> Bool {
        let keys: Set<URLResourceKey> = [.ubiquitousItemIsUploadedKey, .ubiquitousItemIsUploadingKey]
        guard let state = values(url, keys), state.ubiquitousItemIsUploaded == true, state.ubiquitousItemIsUploading != true else { return false }
        do {
            try FileManager.default.evictUbiquitousItem(at: url)
            return true
        } catch {
            Logger(subsystem: "com.owais.OwlLuna", category: "sync").error("couldn't evict \(url.lastPathComponent): \(error.localizedDescription)")
            return false
        }
    }
}
