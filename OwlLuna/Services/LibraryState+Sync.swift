import Foundation

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

    /// Takes each item another copy changed after this one, so a copy that missed a change never writes it back.
    mutating func takeLaterChanges(from other: LibraryState) {
        for filing in Filing.allCases {
            // Dates are kept to the millisecond.
            guard let theirs = other.changedAt(filing), theirs.timeIntervalSince(changedAt(filing) ?? .distantPast) > 0.0005 else { continue }
            take(filing, from: other)
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
