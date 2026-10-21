import Foundation

/// A saved filter: everything tagged with any, or all, of its tags.
struct SmartShelf: Sendable, Hashable, Identifiable {
    var id: UUID
    var name: String
    var tags: [String]
    /// "any" or "all". A kind this build doesn't know is kept and read as "any".
    var matchRaw: String
    var createdAt: Date
    /// When its name, tags or way of matching last changed, which settles a shelf changed on two devices. Nil from an older build.
    var changedAt: Date?
    var extra: [String: JSONValue] = [:]
    var undecoded: [String: UndecodedField] = [:]

    init(id: UUID = UUID(), name: String, tags: [String], match: TagRule.Match = .any, createdAt: Date = .now) {
        self.id = id
        self.name = name
        self.tags = Tags.merged(tags)
        self.matchRaw = match.rawValue
        self.createdAt = createdAt
    }

    var match: TagRule.Match {
        get { TagRule.Match(rawValue: matchRaw) ?? .any }
        set { matchRaw = newValue.rawValue }
    }

    var rule: TagRule { TagRule(tags: tags, match: match) }

    /// The same shelf, whenever it was stamped.
    func isUnchanged(from other: SmartShelf) -> Bool {
        var other = other
        other.changedAt = changedAt
        return self == other
    }
}

/// `Library/smart-shelves.json`, the saved filters. Read as tolerantly as `folders.json`.
struct SmartShelfFile: Sendable, Hashable {
    var shelves: [SmartShelf] = []
    var opaque: [JSONValue] = []
    /// Names the list in the synced copy, as `FolderFile.listID` does the folders'.
    var listID: String?
    var extra: [String: JSONValue] = [:]

    static func read(_ root: StorageRoot) -> SmartShelfFile {
        guard let data = try? Data(contentsOf: root.smartShelvesFile) else { return SmartShelfFile() }
        guard let file = SmartShelfFile(data) else {
            _ = try? Quarantine.move(root.smartShelvesFile)
            return SmartShelfFile()
        }
        return file
    }

    /// Nil for data that isn't a list of shelves.
    init?(_ data: Data) {
        guard var object = (try? JSONValue.parse(data))?.objectValue, object["shelves"].map({ $0.arrayValue != nil }) ?? true else { return nil }
        let values = object.removeValue(forKey: "shelves")?.arrayValue ?? []
        listID = object.removeValue(forKey: "listID")?.stringValue
        extra = object
        for raw in values {
            guard let object = raw.objectValue,
                  let id = object["id"]?.stringValue.flatMap(UUID.init(uuidString:)),
                  let name = object["name"]?.stringValue else {
                opaque.append(raw)
                continue
            }
            var reader = ObjectReader(object)
            _ = reader.take("id")
            _ = reader.take("name")
            let tags = reader.value("tags", default: [], encode: { .array($0.map(JSONValue.string)) }) { raw in
                raw.arrayValue.flatMap { values in
                    let names = values.compactMap(\.stringValue)
                    return names.count == values.count ? names : nil
                }
            }
            var shelf = SmartShelf(id: id, name: name, tags: tags, createdAt: reader.date("createdAt", default: .now))
            shelf.matchRaw = reader.string("match", default: TagRule.Match.any.rawValue)
            shelf.changedAt = reader.optionalDate("changedAt")
            shelf.extra = reader.remaining
            shelf.undecoded = reader.undecoded
            shelves.append(shelf)
        }
    }

    init(shelves: [SmartShelf] = [], opaque: [JSONValue] = [], listID: String? = nil, extra: [String: JSONValue] = [:]) {
        self.shelves = shelves
        self.opaque = opaque
        self.listID = listID
        self.extra = extra
    }

    func encoded() throws -> Data {
        let encoded = shelves.map { shelf -> JSONValue in
            var writer = ObjectWriter(base: shelf.extra, undecoded: shelf.undecoded)
            writer.set("id", .string(shelf.id.uuidString))
            writer.set("name", .string(shelf.name))
            writer.set("tags", .array(shelf.tags.map(JSONValue.string)))
            writer.set("match", .string(shelf.matchRaw))
            writer.set("createdAt", ManifestCodec.encodeDate(shelf.createdAt))
            if let changedAt = shelf.changedAt { writer.set("changedAt", ManifestCodec.encodeDate(changedAt)) }
            return .object(writer.values)
        }
        var object = extra
        object["shelves"] = .array(encoded + opaque)
        if let listID { object["listID"] = .string(listID) }
        return try JSONValue.object(object).serialized()
    }

    /// Takes the changes the app made between `before` and `after`, stamping the shelves it changed. A shelf it didn't
    /// touch stays as the file has it, so one a sync brought in or changed meanwhile isn't lost.
    mutating func apply(from before: [SmartShelf], to after: [SmartShelf], at date: Date) {
        let previous = Dictionary(before.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let inFile = Dictionary(shelves.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let kept = Set(after.map(\.id))
        var result: [SmartShelf] = []
        for shelf in after {
            if let old = previous[shelf.id], shelf.isUnchanged(from: old) {
                if let current = inFile[shelf.id] { result.append(current) }
            } else {
                var changed = shelf
                changed.changedAt = max(date, (inFile[shelf.id]?.changedAt ?? .distantPast).addingTimeInterval(0.001))
                result.append(changed)
            }
        }
        result += shelves.filter { previous[$0.id] == nil && !kept.contains($0.id) }
        shelves = result
    }

    func write(_ root: StorageRoot) throws {
        try FileManager.default.createDirectory(at: root.library, withIntermediateDirectories: true)
        try encoded().write(to: root.smartShelvesFile, options: .atomic)
    }
}
