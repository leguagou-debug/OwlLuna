import Foundation
import SwiftData

/// The first index schema, kept only so a store written by it can be migrated. Each record carried its notebook's
/// whole search text, so every library query loaded it.
enum LibraryIndexSchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] { [NotebookRecord.self, FolderRecord.self] }

    @Model
    final class NotebookRecord {
        @Attribute(.unique) var id: UUID = UUID()
        var title: String = ""
        var createdAt: Date = Date()
        var modifiedAt: Date = Date()
        var lastOpenedAt: Date?
        var pageCount: Int = 0
        var currentPage: Int = 0
        var isFavorite: Bool = false
        var deletedAt: Date?
        var folder: FolderRecord?
        var searchText: String = ""
        var coverStyleRaw: String = CoverStyle.cloth.rawValue
        var clothRaw: String = ClothColor.slate.rawValue
        var inksRaw: String = "teal,blue"
        var coverSeed: Int = 0
        var firstPageID: UUID?
        var firstPageInkHash: String?
        var firstPageThumbKey: String?
        var firstPageIsPDF: Bool = false
        var isReadOnly: Bool = false
        var issueCount: Int = 0
        var indexedAt: Date = Date.distantPast

        init(id: UUID) { self.id = id }
    }

    @Model
    final class FolderRecord {
        @Attribute(.unique) var id: UUID = UUID()
        var name: String = ""
        var clothRaw: String = ClothColor.slate.rawValue
        var createdAt: Date = Date()
        var sortIndex: Int = 0
        @Relationship(deleteRule: .nullify, inverse: \LibraryIndexSchemaV1.NotebookRecord.folder)
        var notebooks: [NotebookRecord]? = []

        init(id: UUID) { self.id = id }
    }
}

/// The second index schema, kept so a store written by it can be migrated. Its folders were a flat list.
enum LibraryIndexSchemaV2: VersionedSchema {
    static let versionIdentifier = Schema.Version(2, 0, 0)
    static var models: [any PersistentModel.Type] { [NotebookRecord.self, FolderRecord.self, NotebookSearchText.self] }

    @Model
    final class NotebookRecord {
        @Attribute(.unique) var id: UUID = UUID()
        var title: String = ""
        var createdAt: Date = Date()
        var modifiedAt: Date = Date()
        var lastOpenedAt: Date?
        var pageCount: Int = 0
        var currentPage: Int = 0
        var isFavorite: Bool = false
        var deletedAt: Date?
        var folder: FolderRecord?
        var coverStyleRaw: String = CoverStyle.cloth.rawValue
        var clothRaw: String = ClothColor.slate.rawValue
        var inksRaw: String = "teal,blue"
        var coverSeed: Int = 0
        var firstPageID: UUID?
        var firstPageInkHash: String?
        var firstPageThumbKey: String?
        var firstPageIsPDF: Bool = false
        var isReadOnly: Bool = false
        var issueCount: Int = 0
        var indexedAt: Date = Date.distantPast

        init(id: UUID) { self.id = id }
    }

    @Model
    final class FolderRecord {
        @Attribute(.unique) var id: UUID = UUID()
        var name: String = ""
        var clothRaw: String = ClothColor.slate.rawValue
        var createdAt: Date = Date()
        var sortIndex: Int = 0
        @Relationship(deleteRule: .nullify, inverse: \LibraryIndexSchemaV2.NotebookRecord.folder)
        var notebooks: [NotebookRecord]? = []

        init(id: UUID) { self.id = id }
    }

    /// Everything recognised, typed or read from PDFs in one notebook. Deliberately not a relationship of the record.
    @Model
    final class NotebookSearchText {
        @Attribute(.unique) var notebookID: UUID = UUID()
        var text: String = ""

        init(notebookID: UUID, text: String) {
            self.notebookID = notebookID
            self.text = text
        }
    }
}

/// The third index schema, kept so a store written by it can be migrated. Its notebooks had no lock.
enum LibraryIndexSchemaV3: VersionedSchema {
    static let versionIdentifier = Schema.Version(3, 0, 0)
    static var models: [any PersistentModel.Type] { [NotebookRecord.self, FolderRecord.self, NotebookSearchText.self] }

    @Model
    final class NotebookRecord {
        @Attribute(.unique) var id: UUID = UUID()
        var title: String = ""
        var createdAt: Date = Date()
        var modifiedAt: Date = Date()
        var lastOpenedAt: Date?
        var pageCount: Int = 0
        var currentPage: Int = 0
        var isFavorite: Bool = false
        var deletedAt: Date?
        var folder: FolderRecord?
        var coverStyleRaw: String = CoverStyle.cloth.rawValue
        var clothRaw: String = ClothColor.slate.rawValue
        var inksRaw: String = "teal,blue"
        var coverSeed: Int = 0
        var firstPageID: UUID?
        var firstPageInkHash: String?
        var firstPageThumbKey: String?
        var firstPageIsPDF: Bool = false
        var isReadOnly: Bool = false
        var issueCount: Int = 0
        var indexedAt: Date = Date.distantPast

        init(id: UUID) { self.id = id }
    }

    @Model
    final class FolderRecord {
        @Attribute(.unique) var id: UUID = UUID()
        var name: String = ""
        var clothRaw: String = ClothColor.slate.rawValue
        var createdAt: Date = Date()
        var sortIndex: Int = 0
        var parentID: UUID?
        @Relationship(deleteRule: .nullify, inverse: \LibraryIndexSchemaV3.NotebookRecord.folder)
        var notebooks: [NotebookRecord]? = []

        init(id: UUID) { self.id = id }
    }

    /// Everything recognised, typed or read from PDFs in one notebook. Deliberately not a relationship of the record.
    @Model
    final class NotebookSearchText {
        @Attribute(.unique) var notebookID: UUID = UUID()
        var text: String = ""

        init(notebookID: UUID, text: String) {
            self.notebookID = notebookID
            self.text = text
        }
    }
}

/// The fourth index schema, kept so a store written by it can be migrated. Its notebooks had no tags.
enum LibraryIndexSchemaV4: VersionedSchema {
    static let versionIdentifier = Schema.Version(4, 0, 0)
    static var models: [any PersistentModel.Type] { [NotebookRecord.self, FolderRecord.self, NotebookSearchText.self] }

    @Model
    final class NotebookRecord {
        @Attribute(.unique) var id: UUID = UUID()
        var title: String = ""
        var createdAt: Date = Date()
        var modifiedAt: Date = Date()
        var lastOpenedAt: Date?
        var pageCount: Int = 0
        var currentPage: Int = 0
        var isFavorite: Bool = false
        var deletedAt: Date?
        var folder: FolderRecord?
        var coverStyleRaw: String = CoverStyle.cloth.rawValue
        var clothRaw: String = ClothColor.slate.rawValue
        var inksRaw: String = "teal,blue"
        var coverSeed: Int = 0
        var firstPageID: UUID?
        var firstPageInkHash: String?
        var firstPageThumbKey: String?
        var firstPageIsPDF: Bool = false
        var isReadOnly: Bool = false
        var issueCount: Int = 0
        var indexedAt: Date = Date.distantPast
        var isLocked: Bool = false

        init(id: UUID) { self.id = id }
    }

    @Model
    final class FolderRecord {
        @Attribute(.unique) var id: UUID = UUID()
        var name: String = ""
        var clothRaw: String = ClothColor.slate.rawValue
        var createdAt: Date = Date()
        var sortIndex: Int = 0
        var parentID: UUID?
        @Relationship(deleteRule: .nullify, inverse: \LibraryIndexSchemaV4.NotebookRecord.folder)
        var notebooks: [NotebookRecord]? = []

        init(id: UUID) { self.id = id }
    }

    /// Everything recognised, typed or read from PDFs in one notebook. Deliberately not a relationship of the record.
    @Model
    final class NotebookSearchText {
        @Attribute(.unique) var notebookID: UUID = UUID()
        var text: String = ""

        init(notebookID: UUID, text: String) {
            self.notebookID = notebookID
            self.text = text
        }
    }
}

/// The fifth index schema, kept so a store written by it can be migrated. Its notebooks didn't keep their manifest's date.
enum LibraryIndexSchemaV5: VersionedSchema {
    static let versionIdentifier = Schema.Version(5, 0, 0)
    static var models: [any PersistentModel.Type] { [NotebookRecord.self, FolderRecord.self, NotebookSearchText.self] }

    @Model
    final class NotebookRecord {
        @Attribute(.unique) var id: UUID = UUID()
        var title: String = ""
        var createdAt: Date = Date()
        var modifiedAt: Date = Date()
        var lastOpenedAt: Date?
        var pageCount: Int = 0
        var currentPage: Int = 0
        var isFavorite: Bool = false
        var deletedAt: Date?
        var folder: FolderRecord?
        var coverStyleRaw: String = CoverStyle.cloth.rawValue
        var clothRaw: String = ClothColor.slate.rawValue
        var inksRaw: String = "teal,blue"
        var coverSeed: Int = 0
        var firstPageID: UUID?
        var firstPageInkHash: String?
        var firstPageThumbKey: String?
        var firstPageIsPDF: Bool = false
        var isReadOnly: Bool = false
        var issueCount: Int = 0
        var indexedAt: Date = Date.distantPast
        var isLocked: Bool = false
        /// The notebook's tags, one to a line.
        var tagsRaw: String = ""
        /// Every tag on any of its pages, one to a line.
        var pageTagsRaw: String = ""

        init(id: UUID) { self.id = id }
    }

    @Model
    final class FolderRecord {
        @Attribute(.unique) var id: UUID = UUID()
        var name: String = ""
        var clothRaw: String = ClothColor.slate.rawValue
        var createdAt: Date = Date()
        var sortIndex: Int = 0
        var parentID: UUID?
        @Relationship(deleteRule: .nullify, inverse: \LibraryIndexSchemaV5.NotebookRecord.folder)
        var notebooks: [NotebookRecord]? = []

        init(id: UUID) { self.id = id }
    }

    /// Everything recognised, typed or read from PDFs in one notebook. Deliberately not a relationship of the record.
    @Model
    final class NotebookSearchText {
        @Attribute(.unique) var notebookID: UUID = UUID()
        var text: String = ""

        init(notebookID: UUID, text: String) {
            self.notebookID = notebookID
            self.text = text
        }
    }
}

/// V1 to V2 drops the record's search text and adds the empty table; the next refresh reads the text back from the packages.
/// V2 to V3 gives folders a parent, which the same refresh fills in from `folders.json`.
/// V3 to V4 adds the lock, which starts off: the first refresh afterwards reads every manifest for it.
/// V4 to V5 adds the tags, which start empty and are read by that same first refresh.
/// V5 to V6 adds the manifest's date, which starts empty, so that first refresh reads every manifest once more, and with it the journal mark.
enum LibraryIndexMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [LibraryIndexSchemaV1.self, LibraryIndexSchemaV2.self, LibraryIndexSchemaV3.self, LibraryIndexSchemaV4.self,
         LibraryIndexSchemaV5.self, LibraryIndexSchemaV6.self]
    }
    static var stages: [MigrationStage] {
        [.lightweight(fromVersion: LibraryIndexSchemaV1.self, toVersion: LibraryIndexSchemaV2.self),
         .lightweight(fromVersion: LibraryIndexSchemaV2.self, toVersion: LibraryIndexSchemaV3.self),
         .lightweight(fromVersion: LibraryIndexSchemaV3.self, toVersion: LibraryIndexSchemaV4.self),
         .lightweight(fromVersion: LibraryIndexSchemaV4.self, toVersion: LibraryIndexSchemaV5.self),
         .lightweight(fromVersion: LibraryIndexSchemaV5.self, toVersion: LibraryIndexSchemaV6.self)]
    }
}
