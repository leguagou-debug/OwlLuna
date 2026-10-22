import SwiftUI

enum LibraryScope: Hashable {
    case all, favorites, trash
    case folder(UUID)
    /// Everything carrying one tag.
    case tag(String)
    /// A saved filter, by its ID.
    case smart(UUID)

    /// The folder a folder scope shows, while it is still there.
    func folder(in folders: [FolderRecord]) -> FolderRecord? {
        if case .folder(let id) = self { return folders.first { $0.id == id } }
        return nil
    }
}

enum LibrarySortOrder: String, CaseIterable, Identifiable {
    case opened, modified, created, title
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .opened: String(localized: "Last Opened")
        case .modified: String(localized: "Date Modified")
        case .created: String(localized: "Date Created")
        case .title: String(localized: "Title")
        }
    }

    /// Turned round, a sort puts the oldest first, or Z.
    func summary(reversed: Bool = false) -> String {
        switch (self, reversed) {
        case (.opened, false): String(localized: "last opened first")
        case (.opened, true): String(localized: "least recently opened first")
        case (.modified, false): String(localized: "recently edited first")
        case (.modified, true): String(localized: "least recently edited first")
        case (.created, false): String(localized: "newest first")
        case (.created, true): String(localized: "oldest first")
        case (.title, false): String(localized: "A to Z")
        case (.title, true): String(localized: "Z to A")
        }
    }

    func directionName(reversed: Bool) -> String {
        switch (self, reversed) {
        case (.title, false): String(localized: "A to Z")
        case (.title, true): String(localized: "Z to A")
        case (_, false): String(localized: "Newest First")
        case (_, true): String(localized: "Oldest First")
        }
    }
}

/// The notebooks as covers on shelves, or as rows in columns.
enum LibraryLayout: String, CaseIterable, Identifiable {
    case shelf, list
    var id: String { rawValue }

    var displayName: String { self == .shelf ? String(localized: "Shelf") : String(localized: "List") }
    var symbol: String { self == .shelf ? "square.grid.2x2" : "list.bullet" }
}

enum LibraryGrouping: String, CaseIterable, Identifiable {
    case recency, folder
    var id: String { rawValue }
    var displayName: String { self == .recency ? String(localized: "Recency") : String(localized: "Folder") }
}

