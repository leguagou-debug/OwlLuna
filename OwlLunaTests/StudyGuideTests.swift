import XCTest
#if canImport(FoundationModels)
import FoundationModels
#endif
@testable import OwlLuna

/// Study guides: how notes are cut into pieces the model can take, and how the pieces' answers are put together.
@MainActor
final class StudyGuideTests: XCTestCase {
    /// Answers with the notes' own lines, and counts how it was asked.
    private final class Recorder: StudyModel, @unchecked Sendable {
        private let lock = NSLock()
        private var asked: [String] = []
        var limit = Int.max
        var prompts: [String] { lock.withLock { asked } }

        func keyPoints(in text: String, atMost limit: Int) async throws -> [String] {
            lock.withLock { asked.append(text) }
            if text.count > self.limit { throw StudyGuideError.tooLong }
            return Array(text.split(separator: "\n").map { String($0).replacingOccurrences(of: "- ", with: "") }.prefix(limit))
        }

        func questions(about text: String, count: Int) async throws -> [QuizItem] {
            lock.withLock { asked.append(text) }
            if text.count > self.limit { throw StudyGuideError.tooLong }
            return text.split(separator: "\n").prefix(count).map { QuizItem(question: "What about \($0)?", answer: String($0)) }
        }
    }

    /// Answers with the notes' own lines, from its `held`th question on only once let go, and counts how often it was asked.
    private final class Held: StudyModel, @unchecked Sendable {
        private let lock = NSLock()
        private let held: Int, limit: Int
        private var asked = 0, released = false
        private var waiting: CheckedContinuation<Void, Never>?
        var calls: Int { lock.withLock { asked } }

        init(holding held: Int, limit: Int = .max) {
            self.held = held
            self.limit = limit
        }

        func keyPoints(in text: String, atMost limit: Int) async throws -> [String] {
            try await answer(text)
            return Array(text.split(separator: "\n").map(String.init).prefix(limit))
        }

        func questions(about text: String, count: Int) async throws -> [QuizItem] {
            try await answer(text)
            return text.split(separator: "\n").prefix(count).map { QuizItem(question: "What about \($0)?", answer: String($0)) }
        }

        func letGo() {
            lock.withLock { released = true; return waiting.take() }?.resume()
        }

        private func answer(_ text: String) async throws {
            if lock.withLock({ asked += 1; return asked }) >= held {
                await withCheckedContinuation { wait in
                    lock.withLock { if released { wait.resume() } else { waiting = wait } }
                }
            }
            if text.count > limit { throw StudyGuideError.tooLong }
        }
    }

    /// Writes points about 710 characters long, so a piece's points fill more than a piece again.
    private final class Wordy: StudyModel, @unchecked Sendable {
        private let lock = NSLock()
        private var asked = 0
        var calls: Int { lock.withLock { asked } }

        func keyPoints(in text: String, atMost limit: Int) async throws -> [String] {
            let call = lock.withLock { asked += 1; return asked }
            return (0..<limit).map { "Point \(call).\($0) " + String(repeating: "word ", count: 140) }
        }

        func questions(about text: String, count: Int) async throws -> [QuizItem] { [] }
    }

    private func notes(_ lines: Int) -> String {
        (1...lines).map { "Fact number \($0) is that cells divide by mitosis in stage \($0)." }.joined(separator: "\n")
    }

    /// A notebook with each of `texts` typed on a page of its own.
    private func notebook(_ texts: [String]) async throws -> NotebookDocument {
        let root = temporaryRoot(self)
        let paper = PageDefaults(template: .blank, paperColor: .white, pageSize: .letter)
        let pages = texts.map { text in
            var page = paper.newPage()
            page.items = [PageItem(content: .text(TextBox(string: text)), center: CGPoint(x: 200, y: 200), size: CGSize(width: 240, height: 40))]
            return page
        }
        let manifest = NotebookManifest(title: "Biology", defaults: paper, pages: pages)
        try await NotebookPackage(root: root, id: manifest.id).create(manifest)
        return try await NotebookDocument.open(manifest.id, root: root)
    }

    func testNotesAreCutBetweenLinesAndALongLineBetweenWords() {
        let chunks = StudyGuide.chunks(of: notes(10), limit: 200)
        XCTAssertEqual(chunks.count, 4)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 200 })
        XCTAssertEqual(chunks.joined(separator: "\n"), notes(10), "nothing is lost and nothing is cut mid-line")

        let long = Array(repeating: "word", count: 100).joined(separator: " ")
        let pieces = StudyGuide.chunks(of: long, limit: 120)
        XCTAssertTrue(pieces.allSatisfy { $0.count <= 120 && !$0.hasPrefix(" ") && !$0.hasSuffix("wor") })
        XCTAssertEqual(pieces.joined(separator: " "), long)
        XCTAssertEqual(StudyGuide.chunks(of: " \n\n  \n"), [])
    }

    func testThePageStampIsNotPartOfTheNotes() {
        XCTAssertEqual(StudyGuide.body(ofPageText: "#ink:abc123+img\nHello\nthere"), "Hello\nthere")
        XCTAssertEqual(StudyGuide.body(ofPageText: "#ink:none"), "")
        XCTAssertEqual(StudyGuide.body(ofPageText: "No stamp"), "No stamp")
    }

    func testAShortNotebookIsSummarisedInOneGo() async throws {
        let model = Recorder()
        let points = try await StudyGuide.summary(of: notes(4) + "\n" + notes(1), using: model, limit: 7)
        XCTAssertEqual(model.prompts.count, 1)
        XCTAssertEqual(points.count, 4, "a point said twice is kept once")
    }

    func testALongNotebookIsReadInPiecesAndThenBoiledDown() async throws {
        let model = Recorder()
        let text = notes(150)
        var progress: [Double] = []
        let points = try await StudyGuide.summary(of: text, using: model, limit: 6) { progress.append($0) }
        let pieces = StudyGuide.chunks(of: text).count
        XCTAssertGreaterThan(pieces, 2)
        XCTAssertEqual(model.prompts.count, pieces + 1, "each piece, then one pass over their points")
        XCTAssertTrue(model.prompts.allSatisfy { $0.count <= StudyGuide.chunkLimit })
        XCTAssertEqual(points.count, 6)
        XCTAssertEqual(progress.last, 1)
        XCTAssertEqual(progress, progress.sorted())
    }

    func testAVeryLongNotebookIsSummarisedFromPiecesSpreadThroughIt() async throws {
        let model = Recorder()
        let text = notes(2000)
        let chunks = StudyGuide.chunks(of: text)
        XCTAssertGreaterThan(chunks.count, StudyGuide.summaryPieces)
        let points = try await StudyGuide.summary(of: text, using: model, limit: 6)
        let read = model.prompts.filter { !$0.hasPrefix("- ") }
        let places = read.compactMap { chunks.firstIndex(of: $0) }
        XCTAssertEqual(read.count, StudyGuide.summaryPieces, "no more pieces than the limit are read")
        XCTAssertEqual(places.count, read.count)
        XCTAssertEqual(places, places.sorted())
        XCTAssertEqual(places.first, 0)
        XCTAssertEqual(places.last, chunks.count - 1, "the end of the notes is read too")
        XCTAssertLessThanOrEqual(model.prompts.count - read.count, 4, "then their points are boiled down")
        XCTAssertEqual(points.count, 6)
    }

    func testPointsThatNeverGetShorterAreBoiledDownOnlyAFewTimes() async throws {
        let model = Wordy()
        let points = try await StudyGuide.summary(of: notes(2000), using: model)
        XCTAssertEqual(points.count, 7)
        XCTAssertLessThanOrEqual(model.calls, StudyGuide.summaryPieces * 3)
    }

    func testCancellingARunStopsAskingTheModel() async throws {
        let text = notes(150), short = notes(10)
        let last = StudyGuide.chunks(of: text).count
        let runs: [(held: Int, limit: Int, write: @Sendable (any StudyModel) async throws -> Void)] = [
            (1, .max, { _ = try await StudyGuide.summary(of: text, using: $0) }),
            (last, .max, { _ = try await StudyGuide.summary(of: text, using: $0) }),
            (1, .max, { _ = try await StudyGuide.quiz(of: text, using: $0) }),
            (2, 400, { _ = try await StudyGuide.quiz(of: short, using: $0) }),
        ]
        for (held, limit, write) in runs {
            let model = Held(holding: held, limit: limit)
            let run = Task { try await write(model) }
            let deadline = ContinuousClock.now + .seconds(5)
            while model.calls < held, .now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertEqual(model.calls, held, "the run gets as far as the held question")
            run.cancel()
            model.letGo()
            do {
                try await run.value
                XCTFail("a cancelled run doesn't finish")
            } catch {
                XCTAssertTrue(error is CancellationError)
            }
            XCTAssertEqual(model.calls, held, "no next piece, boil-down or other half is asked once the run is cancelled")
        }
    }

    func testAPieceTheModelFindsTooLongIsReadInHalves() async throws {
        let model = Recorder()
        model.limit = 400
        let points = try await StudyGuide.summary(of: notes(10), using: model, limit: 6)
        XCTAssertGreaterThanOrEqual(model.prompts.count, 3, "the whole, then smaller pieces of it")
        XCTAssertTrue(model.prompts.dropFirst().allSatisfy { $0.count <= 400 })
        XCTAssertEqual(points.count, 6)
        XCTAssertTrue(model.prompts.dropFirst().contains { $0.contains("number 10 ") }, "the last piece was read too")
        model.limit = 10
        do {
            _ = try await StudyGuide.summary(of: notes(10), using: model)
            XCTFail("notes that can't be cut small enough are refused")
        } catch {
            XCTAssertEqual(error as? StudyGuideError, .tooLong)
        }
    }

    func testTooLittleWritingIsNotGuessedAt() async {
        for text in ["", "HELLO", "   \n "] {
            do {
                _ = try await StudyGuide.summary(of: text, using: Recorder())
                XCTFail("nothing to summarise in \(text.debugDescription)")
            } catch {
                XCTAssertEqual(error as? StudyGuideError, .nothingToRead)
            }
        }
    }

    func testQuestionsAreSpreadOverTheNotesAndNeverRepeated() async throws {
        let model = Recorder()
        let text = notes(150)
        let items = try await StudyGuide.quiz(of: text, using: model, count: 8)
        XCTAssertEqual(items.count, 8)
        XCTAssertEqual(Set(items.map(\.question)).count, 8)
        XCTAssertTrue(items.contains { $0.answer.contains("Fact number 1 ") })
        XCTAssertTrue(items.contains { ($0.answer.split(separator: " ").dropFirst(2).first.flatMap { Int($0) } ?? 0) > 100 }, "the end of the notes is asked about too")

        let repeated = try await StudyGuide.quiz(of: notes(1) + "\n" + notes(1) + "\n" + notes(2), using: Recorder(), count: 8)
        XCTAssertEqual(repeated.count, 2)
    }

    func testTheScriptedModelAnswersFromTheNotes() async throws {
        let model = ScriptedStudyModel()
        let points = try await StudyGuide.summary(of: "Mitochondria make ATP for the cell.\nRibosomes build proteins.", using: model)
        XCTAssertEqual(points, ["Mitochondria make ATP for the cell.", "Ribosomes build proteins."])
        XCTAssertEqual(StudyGuide.listed(points), "• Mitochondria make ATP for the cell.\n• Ribosomes build proteins.")
        let quiz = try await StudyGuide.quiz(of: "Mitochondria make ATP for the cell.\nRibosomes build proteins.", using: model)
        XCTAssertEqual(quiz.map(\.question), ["What do the notes say about Mitochondria make?", "What do the notes say about Ribosomes build?"])
    }

    /// Why the machine's model can't answer even a plain request, if it can't. CI's simulators report a model and then fail every request.
    private func modelFault() async -> String? {
        #if canImport(FoundationModels)
        if #available(iOS 26, *) {
            do {
                _ = try await LanguageModelSession().respond(to: "Reply with the one word yes.")
                return nil
            } catch {
                return String(describing: error)
            }
        }
        #endif
        return "no model"
    }

    func testTheModelOnThisMachineWritesAboutNotes() async throws {
        guard StudyGuide.status == .ready, let model = StudyGuide.model() else {
            throw XCTSkip("no on-device language model here: \(StudyGuide.status)")
        }
        if let fault = await modelFault() {
            throw XCTSkip("the language model here is reported ready but answers nothing: \(fault)")
        }
        let notes = """
            Mitochondria make ATP, the cell's energy.
            Ribosomes build proteins from amino acids.
            The nucleus holds the cell's DNA.
            Chloroplasts turn light into sugar in plants.
            """
        let points = try await StudyGuide.summary(of: notes, using: model, limit: 4)
        XCTAssertFalse(points.isEmpty)
        XCTAssertLessThanOrEqual(points.count, 4)
        let quiz = try await StudyGuide.quiz(of: notes, using: model, count: 3)
        XCTAssertFalse(quiz.isEmpty)
        print("STUDY MODEL points: \(points)\nquiz: \(quiz.map { "\($0.question) -> \($0.answer)" })")
    }

    func testAStudyGuideReadsTypedTextAndHandwritingFromThePages() async throws {
        let document = try await notebook(["Mitochondria make ATP.", "Ribosomes build proteins."])
        let whole = try await StudyGuide.text(for: .notebook, in: document)
        XCTAssertEqual(whole, "Mitochondria make ATP.\n\nRibosomes build proteins.")
        let page = try await StudyGuide.text(for: .page(document.pages[1].id), in: document)
        XCTAssertEqual(page, "Ribosomes build proteins.")
        let recording = try await StudyGuide.text(for: .recording(UUID()), in: document)
        XCTAssertEqual(recording, "")
    }

    func testReadingThePagesMovesTheProgressAPageAtATime() async throws {
        let document = try await notebook((1...4).map { "Fact \($0) about cells." })
        var progress: [Double] = []
        _ = try await StudyGuide.text(for: .notebook, in: document) { progress.append($0) }
        XCTAssertEqual(progress, [0, 0.25, 0.5, 0.75, 1])
    }

    func testACancelledGuideStopsReadingThePages() async throws {
        let document = try await notebook(["Mitochondria make ATP.", "Ribosomes build proteins."])
        let run = Task { try await StudyGuide.text(for: .notebook, in: document) }
        run.cancel()
        do {
            _ = try await run.value
            XCTFail("a cancelled guide doesn't go on to read the pages")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        for page in document.pages {
            let read = await document.package.readText(page.id)
            XCTAssertNil(read, "the indexer stopped before reading a page")
        }
    }
}
