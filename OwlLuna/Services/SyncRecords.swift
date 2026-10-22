import Foundation

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
        modifiedAt = json?["modifiedAt"]?.dateValue
        trashStamp = json?["trashStamp"]?.dateValue
        confirmed = json?["confirmed"]?.boolValue ?? false
        markedAt = json?["markedAt"]?.dateValue
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
        self = SyncState(account: account)
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
            if let id = UUID(uuidString: key), let date = value.dateValue { state.notebooks[id] = date }
        }
        for (key, value) in json["trashStamps"]?.objectValue ?? [:] {
            if let id = UUID(uuidString: key), let date = value.dateValue { state.trashStamps[id] = date }
        }
        state.folders = Set(json["folders"]?.arrayValue?.compactMap { $0.uuidValue } ?? [])
        state.folderList = json["folderList"]?.stringValue
        state.smartShelves = Set(json["smartShelves"]?.arrayValue?.compactMap { $0.uuidValue } ?? [])
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
            self = error.underlying.isOutOfSpace ? .noRoom : .coordination(error.underlying.localizedDescription)
        } else if (error as NSError).isOutOfSpace {
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
