import XCTest
import SwiftData
import SwiftUI
@testable import OwlLuna

/// Search text in its own table: finding notebooks without loading it, coming over from the first index schema, and matching every word or quoted phrase.
@MainActor
final class SearchIndexTests: XCTestCase {
    private var container: ModelContainer?
    private let paper = PageDefaults(template: .grid, paperColor: .white, pageSize: .letter)

    private func makeStore() throws -> LibraryStore {
        let schema = LibraryIndex.schema
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        self.container = container
        return LibraryStore(root: temporaryRoot(self), context: container.mainContext)
    }

    private func makeNotebook(_ title: String, pages: Int = 1, in store: LibraryStore) async throws -> NotebookManifest {
        let manifest = NotebookManifest(title: title, defaults: paper, pages: (0..<pages).map { _ in paper.newPage() })
        try await NotebookPackage(root: store.root, id: manifest.id).create(manifest)
        store.index(manifest)
        return manifest
    }

    /// Writes each page's text as recognition does, then indexes the notebook's text.
    private func write(_ texts: [String], in manifest: NotebookManifest, store: LibraryStore) async throws {
        let package = NotebookPackage(root: store.root, id: manifest.id)
        for (page, text) in zip(manifest.pages, texts) { try await package.writeText("#ink:none\n" + text, pageID: page.id) }
        store.updateSearchText(LibraryIndex.searchText(in: package.textDirectory), for: manifest.id)
    }

    private func found(_ query: String) throws -> Set<UUID> {
        LibraryIndex.notebookIDs(matching: query, in: ModelContext(try XCTUnwrap(container)))
    }

    func testNotebooksAreFoundByTitleOrByTheirText() async throws {
        let store = try makeStore()
        let physics = try await makeNotebook("Physics", in: store), cooking = try await makeNotebook("Recipes", in: store)
        store.updateSearchText("momentum and inertia", for: physics.id)
        store.updateSearchText("Sourdough starter, day three", for: cooking.id)
        let context = ModelContext(try XCTUnwrap(container))
        XCTAssertEqual(LibraryIndex.notebookIDs(matching: "inertia", in: context), [physics.id])
        XCTAssertEqual(LibraryIndex.notebookIDs(matching: "SOURDOUGH", in: context), [cooking.id], "case doesn't matter")
        XCTAssertEqual(LibraryIndex.notebookIDs(matching: "recipes", in: context), [cooking.id], "titles still match")
        XCTAssertEqual(LibraryIndex.notebookIDs(matching: "s", in: context), [physics.id, cooking.id])
        XCTAssertTrue(LibraryIndex.notebookIDs(matching: "zebra", in: context).isEmpty)
    }

    func testSearchTextIsOneRowPerNotebook() async throws {
        let store = try makeStore()
        let manifest = try await makeNotebook("Physics", in: store)
        let context = try XCTUnwrap(container).mainContext
        store.updateSearchText("momentum", for: manifest.id)
        let version = store.searchVersion
        store.updateSearchText("momentum", for: manifest.id)
        XCTAssertEqual(store.searchVersion, version, "the same text again changes nothing, so a search isn't redone")
        store.updateSearchText("momentum and inertia", for: manifest.id)
        XCTAssertEqual(store.searchVersion, version + 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<NotebookSearchText>()), 1)
        XCTAssertEqual(store.searchText(for: manifest.id), "momentum and inertia")

        store.updateSearchText("orphan", for: UUID())
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<NotebookSearchText>()), 1, "no row for a notebook the library doesn't have")

        let record = try XCTUnwrap(store.record(manifest.id))
        store.moveToTrash([record])
        store.deletePermanently([record])
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<NotebookSearchText>()), 0, "deleting the notebook deletes its text")
    }

    func testAnIndexFromTheFirstSchemaMigratesAndFindsItsTextAgain() async throws {
        let root = temporaryRoot(self)
        try FileManager.default.createDirectory(at: root.url, withIntermediateDirectories: true)
        let manifest = NotebookManifest(title: "Physics", defaults: paper, pages: [paper.newPage()])
        let package = NotebookPackage(root: root, id: manifest.id)
        try await package.create(manifest)
        try await package.writeText("#ink:none\nmomentum and inertia", pageID: manifest.pages[0].id)

        try autoreleasepool {
            let old = Schema(versionedSchema: LibraryIndexSchemaV1.self)
            let container = try ModelContainer(for: old, configurations: ModelConfiguration(schema: old, url: root.indexStore, cloudKitDatabase: .none))
            let record = LibraryIndexSchemaV1.NotebookRecord(id: manifest.id)
            record.title = "Physics"
            record.searchText = "momentum and inertia"
            record.isFavorite = true
            record.indexedAt = .distantFuture
            container.mainContext.insert(record)
            try container.mainContext.save()
        }

        let (container, recovered) = LibraryIndex.makeContainer(root: root)
        XCTAssertFalse(recovered, "the old index is migrated, not set aside")
        let context = container.mainContext
        let records = try context.fetch(FetchDescriptor<NotebookRecord>())
        XCTAssertEqual(records.map(\.title), ["Physics"])
        XCTAssertEqual(records.first?.isFavorite, true, "what the record knew comes across")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<NotebookSearchText>()), 0)

        await LibraryIndex.refresh(root: root, context: context)
        XCTAssertEqual(LibraryIndex.notebookIDs(matching: "inertia", in: ModelContext(container)), [manifest.id],
                       "the text is read back from the notebook, though its manifest hasn't changed")
        await LibraryIndex.refresh(root: root, context: context)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<NotebookSearchText>()), 1)

        try FileManager.default.removeItem(at: root.package(manifest.id))
        await LibraryIndex.refresh(root: root, context: context)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<NotebookSearchText>()), 0, "a notebook removed from disk takes its text with it")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<NotebookRecord>()), 0)
    }

    func testWordsSplitAcrossLinesAreFound() async throws {
        let store = try makeStore()
        let biology = try await makeNotebook("Biology", pages: 2, in: store), notes = try await makeNotebook("Notes", pages: 2, in: store)
        try await write(["Today: the cell\nmembrane  keeps\n\nwater out", "nothing here"], in: biology, store: store)
        try await write(["membrane first, and it ends with a cell", "membrane again, ending in a cell"], in: notes, store: store)
        XCTAssertTrue(store.searchText(for: biology.id).contains("Today: the cell membrane keeps water out"), "a page's lines are kept as one")
        XCTAssertTrue(store.searchText(for: notes.id).contains("cell\nmembrane"), "whichever page comes first")
        XCTAssertEqual(try found("\"cell membrane\""), [biology.id], "but a phrase isn't found across two pages")
        XCTAssertEqual(try found("\"membrane keeps water\""), [biology.id])
        XCTAssertEqual(try found("cell membrane"), [biology.id, notes.id])

        let hits = await PageSearch.hits(for: "\"cell membrane\"", in: [biology.id, notes.id], root: store.root)
        XCTAssertEqual(hits.pages[biology.id]?.map(\.index), [0])
        XCTAssertEqual(hits.pages[biology.id]?.first?.snippet, "Today: the cell membrane keeps water out", "on one line")
        XCTAssertNil(hits.pages[notes.id])
    }

    func testWordsAreFoundInAnyOrder() async throws {
        let store = try makeStore()
        let biology = try await makeNotebook("Biology", in: store), recipes = try await makeNotebook("Recipes", in: store)
        try await write(["The cell membrane is a barrier"], in: biology, store: store)
        try await write(["A cell of honeycomb"], in: recipes, store: store)
        XCTAssertEqual(try found("membrane cell"), [biology.id])
        XCTAssertEqual(try found("CELL"), [biology.id, recipes.id])
        XCTAssertTrue(try found("membrane zebra").isEmpty, "every word is needed")

        let hits = await PageSearch.hits(for: "barrier cell", in: [biology.id, recipes.id], root: store.root)
        XCTAssertEqual(hits.pages[biology.id]?.first?.snippet, "The cell membrane is a barrier")
        XCTAssertNil(hits.pages[recipes.id])
    }

    func testPunctuationAndRepeatsInAQueryAreLeftOut() async throws {
        let store = try makeStore()
        let biology = try await makeNotebook("Biology", in: store)
        try await write(["What is osmosis"], in: biology, store: store)
        XCTAssertEqual(try found("What is osmosis?"), [biology.id])
        XCTAssertEqual(SearchQuery("What is osmosis? …").terms, ["What", "is", "osmosis"])
        XCTAssertEqual(SearchQuery("Cell cell CÉLL membrane").terms, ["Cell", "membrane"], "a word given twice is looked for once")
        for nothing in ["\"", "\"\"", "“", "“ ”", "? !"] {
            XCTAssertTrue(SearchQuery(nothing).isEmpty, "\(nothing) is no search at all")
        }
    }

    func testATagWithASpaceIsSearchedAsOneTerm() async throws {
        let store = try makeStore()
        let biology = try await makeNotebook("Biology", in: store), physics = try await makeNotebook("Physics", in: store)
        store.setTags(["term 1"], for: [try XCTUnwrap(store.record(biology.id))])
        store.setTags(["term 2"], for: [try XCTUnwrap(store.record(physics.id))])
        try await write(["chapter 1"], in: physics, store: store)
        XCTAssertEqual(SearchQuery("#term 1").terms, ["#term 1"])
        XCTAssertEqual(try found("#term 1"), [biology.id], "not a notebook tagged term 2 with a 1 in its text")
        XCTAssertEqual(try found("# term 1"), [biology.id])
        XCTAssertEqual(try found("#TERM"), [biology.id, physics.id])
    }

    func testAQuotedPhraseMustStayTogether() async throws {
        let store = try makeStore()
        let lecture = try await makeNotebook("Lecture", in: store), lab = try await makeNotebook("Lab", in: store)
        try await write(["the cell\nmembrane holds"], in: lecture, store: store)
        try await write(["a membrane around the cell"], in: lab, store: store)
        XCTAssertEqual(try found("cell membrane"), [lecture.id, lab.id], "unquoted, the words may be anywhere")
        XCTAssertEqual(try found("\"cell membrane\""), [lecture.id])
        XCTAssertEqual(try found("“cell membrane”"), [lecture.id], "with the quotes the iPad keyboard types")
        XCTAssertTrue(try found("“membrane cell”").isEmpty)
        XCTAssertEqual(try found("holds “cell   membrane"), [lecture.id], "a quote still being typed")
        XCTAssertEqual(SearchQuery("holds “cell \n membrane” \"\" around").terms, ["holds", "cell membrane", "around"])

        let hits = await PageSearch.hits(for: "“cell membrane”", in: [lecture.id, lab.id], root: store.root)
        XCTAssertEqual(Set(hits.pages.keys), [lecture.id])
    }

    func testTermsMayBeSpreadOverTheTitleAndTheText() async throws {
        let store = try makeStore()
        let biology = try await makeNotebook("Biology", in: store), physics = try await makeNotebook("Physics", in: store)
        try await write(["the cell membrane"], in: biology, store: store)
        try await write(["a membrane on a drum"], in: physics, store: store)
        XCTAssertEqual(try found("biology membrane"), [biology.id])
        XCTAssertEqual(try found("membrane"), [biology.id, physics.id])
        XCTAssertTrue(try found("biology drum").isEmpty, "every term is somewhere in the one notebook")

        let hits = await PageSearch.hits(for: "biology membrane", in: [biology.id], root: store.root)
        XCTAssertTrue(hits.pages.isEmpty, "a page is listed only when it holds every term itself")
    }

    func testANotebookWithMoreMatchingPagesThanAreListedSaysHowManyMore() async throws {
        let store = try makeStore()
        let biology = try await makeNotebook("Biology", pages: 20, in: store)
        var physics = try await makeNotebook("Physics", pages: 12, in: store)
        try await write((0..<20).map { $0.isMultiple(of: 4) ? "nothing here" : "the cell\nmembrane, page \($0)" }, in: biology, store: store)
        try await write((0..<12).map { "membrane of a cell, number \($0)" }, in: physics, store: store)
        let package = NotebookPackage(root: store.root, id: physics.id)
        for said in ["a cell membrane, said aloud", "no match in this one", "the membrane again, and the cell"] {
            var recording = RecordingEntry(id: UUID(), file: "talk.wav", createdAt: .now, duration: 20)
            recording.transcriptFile = "talk.json"
            physics.recordings.append(recording)
            try said.write(to: package.transcriptTextURL(recording.id), atomically: true, encoding: .utf8)
        }
        try await package.writeManifest(physics)

        let hits = await PageSearch.hits(for: "membrane cell", in: [biology.id, physics.id], root: store.root)
        XCTAssertEqual(hits.pages[biology.id]?.map(\.index), [1, 2, 3, 5, 6, 7, 9, 10])
        XCTAssertEqual(hits.more[biology.id], 7, "the 15 matching pages are all counted")
        XCTAssertEqual(hits.pages[physics.id]?.count, 8)
        XCTAssertEqual(hits.more[physics.id], 6, "the pages and the transcripts that don't fit")

        let capped = await PageSearch.hits(for: "membrane cell", in: [biology.id, physics.id], root: store.root, limit: 10)
        XCTAssertEqual(capped.pages[physics.id]?.count, 2, "the cap on all the cards still holds")
        XCTAssertEqual(capped.more[physics.id], 12, "and the rest of that notebook's matches are counted")

        let one = await PageSearch.hits(for: "\"page 5\"", in: [biology.id], root: store.root)
        XCTAssertEqual(one.pages[biology.id]?.map(\.index), [5])
        XCTAssertNil(one.more[biology.id], "nothing more to say when every match is listed")
    }

    func testEveryTermIsHighlighted() {
        func marked(_ snippet: String, _ query: String) -> [String] {
            let text = PageSearch.highlighted(snippet, query: query)
            return text.runs.filter { $0[AttributeScopes.SwiftUIAttributes.BackgroundColorAttribute.self] != nil }.map { String(text[$0.range].characters) }
        }
        XCTAssertEqual(marked("The cell membrane keeps the cell whole", "membrane cell"), ["cell", "membrane", "cell"])
        XCTAssertEqual(marked("The cell membrane keeps the cell whole", "“cell membrane”"), ["cell membrane"], "a phrase is marked only where it stays together")
        XCTAssertEqual(marked("A cell is wrapped in a cell membrane", "cell membrane"), ["cell", "cell membrane"], "the whole query in one band")
        XCTAssertEqual(marked("Café and cafe", "CAFE"), ["Café", "cafe"])
        XCTAssertEqual(marked("Two cells divide", "cell"), ["cell"], "the start of a longer word")
        XCTAssertEqual(marked("The membrane is a barrier", "a membrane"), ["membrane", "a"], "not the a inside other words")
    }

    func testASnippetShowsTheWholeQueryOrElseItsLongestTerm() {
        let cell = "#ink:none\nA cell is the smallest unit of life. Every one is wrapped in a cell\nmembrane that keeps it whole."
        XCTAssertEqual(PageSearch.snippet(in: cell, for: "cell membrane", radius: 12), "…rapped in a cell membrane that keeps…")
        let krebs = "#ink:none\nThe first stage is glycolysis; then the cycle named after Krebs runs in the matrix."
        XCTAssertEqual(PageSearch.snippet(in: krebs, for: "the krebs cycle", radius: 12), "…named after Krebs runs in the…")
        XCTAssertEqual(PageSearch.snippet(in: "#ink:none\nthe cell\nmembrane", for: "“cell membrane”"), "the cell membrane")
    }

    func testTextIndexedWithLineBreaksIsRewrittenOnOneLine() async throws {
        let store = try makeStore()
        let biology = try await makeNotebook("Biology", in: store)
        try await NotebookPackage(root: store.root, id: biology.id).writeText("#ink:none\nthe cell\nmembrane", pageID: biology.pages[0].id)
        store.updateSearchText("the cell\nmembrane", for: biology.id)
        XCTAssertTrue(try found("\"cell membrane\"").isEmpty, "as an older build kept it")
        XCTAssertGreaterThanOrEqual(LibraryIndex.schemaNumber, 8, "so the launch after the update reads every notebook again")

        await LibraryIndex.refresh(root: store.root, context: store.context, full: true)
        XCTAssertEqual(store.searchText(for: biology.id), "the cell membrane")
        XCTAssertEqual(try found("\"cell membrane\""), [biology.id])
    }
}
