import XCTest
import PencilKit
@testable import OwlLuna

/// Recordings by name, played faster or slower, shared on their own and exported with the notebook's PDF.
@MainActor
final class RecordingsTests: XCTestCase {
    private let paper = PageDefaults(template: .blank, paperColor: .white, pageSize: .letter)
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func recording(_ file: String = "talk.wav", at offset: TimeInterval = 0, duration: TimeInterval = 20) -> RecordingEntry {
        var entry = RecordingEntry(id: UUID(), file: file, createdAt: start.addingTimeInterval(offset + duration), duration: duration)
        entry.startedAt = start.addingTimeInterval(offset)
        return entry
    }

    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) async {
        let deadline = Date.now.addingTimeInterval(timeout)
        while !condition(), Date.now < deadline { try? await Task.sleep(for: .milliseconds(20)) }
    }

    private func defaults() -> UserDefaults {
        let name = "recordings-tests-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        return UserDefaults(suiteName: name)!
    }

    /// A notebook with silent recordings in its assets, opened.
    private func notebook(_ title: String = "Talk", recordings: [RecordingEntry], ink: [Int: PKDrawing] = [:]) async throws -> NotebookDocument {
        let root = temporaryRoot(self)
        var manifest = NotebookManifest(title: title, defaults: paper, pages: [paper.newPage(), paper.newPage()])
        let package = NotebookPackage(root: root, id: manifest.id)
        try await package.create(manifest)
        try FileManager.default.createDirectory(at: package.assetsDirectory, withIntermediateDirectories: true)
        for entry in recordings { try ReplaySeed.silence(seconds: entry.duration).write(to: package.assetURL(entry.file)) }
        manifest.recordings = recordings.map {
            var entry = $0
            entry.inkedPages = manifest.pages.map(\.id)
            return entry
        }
        var drawings: [UUID: PKDrawing] = [:]
        for (index, drawing) in ink { drawings[manifest.pages[index].id] = drawing }
        _ = try await package.write(SaveSnapshot(manifest: manifest, ink: drawings))
        return try await NotebookDocument.open(manifest.id, root: root)
    }

    private func script() -> Transcript {
        Transcript(locale: "en-US", words: [
            .init(text: "Today", start: 1, duration: 0.3), .init(text: "we", start: 1.4, duration: 0.2), .init(text: "begin.", start: 1.7, duration: 0.4),
            .init(text: "Cells", start: 5.2, duration: 0.4), .init(text: "divide.", start: 5.7, duration: 0.5),
        ])
    }

    // MARK: Names

    func testANameIsKeptInTheManifestAndAnOlderBuildWritesItBack() throws {
        var entry = recording()
        entry.title = "Cell biology"
        let encoded = ManifestCodec.encodeRecording(entry)
        XCTAssertEqual(encoded.objectValue?["title"], .string("Cell biology"), "kept beside the entry's other keys")
        XCTAssertEqual(ManifestCodec.decodeRecording(encoded)?.name, "Cell biology")

        // An older build reads the name as a key it doesn't know and writes it back with whatever it changed.
        var older = try XCTUnwrap(ManifestCodec.decodeRecording(encoded))
        older.extra["transcript"] = .string("words.json")
        older.duration = 21
        let rewritten = ManifestCodec.encodeRecording(older)
        XCTAssertEqual(rewritten.objectValue?["title"], .string("Cell biology"))
        XCTAssertEqual(rewritten.objectValue?["duration"], .number(21))

        var manifest = NotebookManifest(title: "Biology", defaults: paper, pages: [paper.newPage()])
        manifest.recordings = [entry, recording("plain.m4a", at: 60)]
        let reread = try ManifestCodec.decode(ManifestCodec.encode(manifest), fallbackID: UUID()).manifest
        XCTAssertEqual(reread.recordings.map(\.title), ["Cell biology", nil])
        XCTAssertEqual(try ManifestCodec.encode(reread), try ManifestCodec.encode(manifest), "the whole manifest round-trips unchanged")

        let odd = try XCTUnwrap(ManifestCodec.decodeRecording(.object(["id": .string(UUID().uuidString), "file": .string("a.m4a"),
                                                                     "createdAt": ManifestCodec.encodeDate(start),
                                                                     "title": .object(["en": .string("Cells")])])))
        XCTAssertNil(odd.title, "a name in a shape a newer build might use is not read as one")
        XCTAssertEqual(ManifestCodec.encodeRecording(odd).objectValue?["title"], .object(["en": .string("Cells")]), "and is written back as it was")

        entry.title = ""
        XCTAssertNil(entry.title)
        XCTAssertNil(ManifestCodec.encodeRecording(entry).objectValue?["title"], "an empty name is no name")
    }

    func testAnUnnamedRecordingIsCalledByWhenItBeganAndKeepsThatName() async throws {
        let first = recording("a.wav"), second = recording("b.wav", at: 3600), third = recording("c.wav", at: 7200)
        let document = try await notebook(recordings: [first, second, third])
        let names = document.manifest.recordings.map(\.name)
        XCTAssertEqual(names, [first, second, third].map { $0.startedAt.formatted(date: .abbreviated, time: .shortened) })
        XCTAssertEqual(Set(names).count, 3)

        document.removeRecording(first.id)
        XCTAssertEqual(document.manifest.recordings.map(\.name), Array(names.dropFirst()), "deleting one renames none of the others")

        document.renameRecording(third.id, to: "  Mitosis  ")
        XCTAssertEqual(document.manifest.recordings.last?.name, "Mitosis", "trimmed")
        XCTAssertEqual(document.undoManager.undoActionName, "Rename Recording")
        document.undoManager.undo()
        XCTAssertNil(document.manifest.recordings.last?.title, "one undo takes the name off")
        XCTAssertEqual(document.manifest.recordings.last?.name, names[2])
        document.undoManager.redo()
        XCTAssertEqual(document.manifest.recordings.last?.title, "Mitosis")
        document.renameRecording(third.id, to: " ")
        XCTAssertEqual(document.manifest.recordings.last?.name, names[2], "nothing typed goes back to when it began")
        document.undoManager.undo()
        XCTAssertEqual(document.manifest.recordings.last?.title, "Mitosis")

        var alike = [recording("x.wav"), recording("y.wav", at: 60), recording("z.m4a", at: 120)]
        alike[0].title = "Lecture"
        alike[1].title = "lecture"
        alike[2].title = "Lecture: Part 1"
        let files = RecordingExport.names(for: alike)
        XCTAssertEqual(alike.map { files[$0.id]?.number }, ["", " 2", ""], "named alike, the later one is numbered so neither file replaces the other")
    }

    // MARK: Speed

    func testPlaybackSpeedIsAppliedAndTheReplayKeepsToTheSoundAtTwice() async throws {
        let entry = recording(duration: 30)
        let ink = PKDrawing(strokes: [2, 6, 10, 14, 18, 22].enumerated().map { ReplaySeed.stroke(y: 100 + CGFloat($0) * 60, at: start.addingTimeInterval($1)) })
        let document = try await notebook(recordings: [entry], ink: [0: ink])
        let session = EditorSession(document: document)
        let store = defaults()
        session.recorder.defaults = store
        let controller = PageStackController(session: session)
        session.canvas = controller
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 834, height: 1194)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        addTeardownBlock { @MainActor in window.isHidden = true }
        controller.view.layoutIfNeeded()
        for _ in 0..<100 where !(controller.canvas(forPage: 0)?.isLoaded ?? false) { try await Task.sleep(for: .milliseconds(50)) }

        XCTAssertEqual(PlaybackSpeed.saved(in: store), 1, "a recording plays as it was made until another speed is chosen")
        session.recorder.setSpeed(2)
        session.recorder.setSpeed(3)
        XCTAssertEqual(session.recorder.speed, 2, "only the speeds offered are taken")
        XCTAssertEqual(store.double(forKey: SettingsKey.playbackSpeed), 2)
        let began = await session.beginReplay(document.manifest.recordings[0])
        XCTAssertTrue(began)
        XCTAssertEqual(session.recorder.playerRate, 2, "the player plays at the speed chosen")
        let timeline = try XCTUnwrap(session.replay), page = document.pages[0].id
        let canvas = try XCTUnwrap(controller.canvas(forPage: 0))
        func shows(_ time: TimeInterval) -> Bool {
            canvas.drawing.strokes.map { $0.ink.color.cgColor.alpha < 0.5 }
                == ReplayInk.drawing(ink, pending: timeline.pending(onPage: page, at: time)).strokes.map { $0.ink.color.cgColor.alpha < 0.5 }
        }

        session.seekReplay(to: 9)
        XCTAssertEqual(session.recorder.currentTime, 9, accuracy: 0.01, "a seek lands on the recording's own time at any speed")
        XCTAssertTrue(shows(9))
        let from = session.recorder.currentTime, wall = Date.now
        try await Task.sleep(for: .milliseconds(1200))
        let moved = session.recorder.currentTime - from, took = Date.now.timeIntervalSince(wall)
        if moved > 0 {
            XCTAssertGreaterThan(moved / took, 1.6, "the sound runs at twice its speed: \(moved) s in \(took) s")
            XCTAssertLessThan(moved / took, 2.4)
        }
        XCTAssertTrue(shows(session.recorder.currentTime), "the ink is where the sound is, at \(session.recorder.currentTime) s")

        session.scrubReplay(to: 4)
        XCTAssertTrue(shows(4))
        session.seekReplay(to: 4)
        XCTAssertEqual(session.recorder.currentTime, 4, accuracy: 0.01)
        XCTAssertEqual(session.recorder.playerRate, 2, "seeking keeps the speed")
        session.recorder.pause()
        session.recorder.resume()
        XCTAssertEqual(session.recorder.playerRate, 2, "and so do pausing and going on")

        session.recorder.setSpeed(0.75)
        XCTAssertEqual(session.recorder.playerRate, 0.75, "a change while playing takes at once")
        session.enter(.writing)
        XCTAssertEqual(PlaybackSpeed.saved(in: store), 0.75, "the speed is kept for the next playback")
        XCTAssertEqual(PlaybackSpeed.label(1.5), 1.5.formatted(.number.precision(.fractionLength(0...2))) + "×")
        XCTAssertEqual(PlaybackScrubber.step(in: 30), 3)
        XCTAssertEqual(PlaybackScrubber.step(in: 3600), 10)
    }

    // MARK: Sharing

    func testATranscriptFileHasItsTimesWhenTheWordsCameWithThem() throws {
        let timed = script()
        XCTAssertEqual(timed.fileText, "[0:01] Today we begin.\n[0:05] Cells divide.")
        var untimed = timed
        untimed.untimed = true
        XCTAssertEqual(untimed.fileText, timed.text, "words spread over the recording go as Copy Transcript gives them, without made-up times")
        XCTAssertEqual(untimed.fileText, "Today we begin.\nCells divide.")
        let long = Transcript(locale: "en-US", words: [.init(text: "Late.", start: 3723, duration: 0.5)])
        XCTAssertEqual(long.fileText, "[1:02:03] Late.")

        let decoded = try JSONDecoder().decode(Transcript.self, from: JSONEncoder().encode(untimed))
        XCTAssertEqual(decoded.untimed, true)
        let older = try JSONDecoder().decode(Transcript.self, from: Data(#"{"locale":"en-US","words":[{"t":"Hi.","s":1,"d":0.2}]}"#.utf8))
        XCTAssertNil(older.untimed, "a transcript from before is taken to have its times")
    }

    func testARecordingAndItsTranscriptAreSharedAsFilesNamedAfterIt() async throws {
        var named = recording(duration: 4)
        named.title = "Week 3: Cells"
        let document = try await notebook(recordings: [named, recording("quiet.wav", at: 600, duration: 2)])
        let recorder = NotebookRecorder(document: document, defaults: defaults())
        let file = try await document.package.writeTranscript(script(), recordingID: named.id)
        document.setTranscript(file, forRecording: named.id)
        let entry = try XCTUnwrap(recorder.recordings.first)

        let audio = try await shared(.audio, of: entry, by: recorder)
        XCTAssertEqual(audio.map(\.lastPathComponent), ["Week 3- Cells.wav"])
        XCTAssertTrue(audio[0].deletingLastPathComponent().lastPathComponent.hasPrefix("export-"), "in an export folder of its own")
        XCTAssertEqual(try Data(contentsOf: audio[0]), try Data(contentsOf: document.package.assetURL(entry.file)))

        let text = try await shared(.transcript, of: entry, by: recorder)
        XCTAssertEqual(text.map(\.lastPathComponent), ["Week 3- Cells.txt"])
        XCTAssertEqual(try String(contentsOf: text[0], encoding: .utf8), "[0:01] Today we begin.\n[0:05] Cells divide.\n")
        let quiet = try XCTUnwrap(recorder.recordings.last)
        let none = try await recorder.files(sharing: .transcript, of: quiet)
        XCTAssertNil(none, "nothing to share before it is transcribed")
        let dated = try await shared(.audio, of: quiet, by: recorder)
        let stem = quiet.startedAt.formatted(date: .abbreviated, time: .shortened).replacingOccurrences(of: ":", with: ".")
        XCTAssertEqual(dated[0].lastPathComponent, stem.replacingOccurrences(of: "\u{202F}", with: " ") + ".wav", "named for when it began, the time written with a point")

        for url in audio + text + dated {
            ExportFolder.discard([url])
            await waitUntil { !FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path(percentEncoded: false)) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path(percentEncoded: false)), "cleaned up as exports are")
        }
    }

    private func shared(_ part: NotebookRecorder.Part, of entry: RecordingEntry, by recorder: NotebookRecorder,
                        file: StaticString = #filePath, line: UInt = #line) async throws -> [URL] {
        let urls = try await recorder.files(sharing: part, of: entry)
        return try XCTUnwrap(urls, file: file, line: line)
    }

    func testALockedNotebookIsUnlockedBeforeItsRecordingsAreShared() async throws {
        let document = try await notebook(recordings: [recording(duration: 2)])
        document.updateLibraryState { $0.isLocked = true }
        let recorder = NotebookRecorder(document: document, defaults: defaults())
        let lock = NotebookLock.shared, usual = lock.authenticator
        addTeardownBlock { @MainActor in
            lock.authenticator = usual
            lock.lock(document.id)
        }
        lock.lock(document.id)
        lock.authenticator = ScriptedAuthenticator(passes: 0)
        let refused = try await recorder.files(sharing: .audio, of: recorder.recordings[0])
        XCTAssertNil(refused, "nothing is written while it stays locked")
        lock.authenticator = ScriptedAuthenticator(passes: 1)
        let shared = try await recorder.files(sharing: .audio, of: recorder.recordings[0])
        XCTAssertEqual(shared?.count, 1)
        XCTAssertTrue(lock.isUnlocked(document.id))
        ExportFolder.discard(shared ?? [])
    }

    // MARK: Export

    func testAnExportedPDFTakesTheRecordingsOnlyWhenAsked() async throws {
        var lecture = recording("lecture.wav", duration: 3)
        lecture.title = "Lecture"
        let other = recording("other.m4a", at: 900, duration: 2)
        let document = try await notebook("Biology", recordings: [lecture, other])
        let file = try await document.package.writeTranscript(script(), recordingID: lecture.id)
        document.setTranscript(file, forRecording: lecture.id)

        let job = ExportJob(document: document)
        await waitUntil(10) { if case .finished = job.state { true } else { false } }
        guard case .finished(let urls) = job.state, let pdf = urls.first else { return XCTFail("\(job.state)") }
        XCTAssertEqual(job.recordingCount, 2)
        XCTAssertFalse(job.includesRecordings, "off unless asked")
        XCTAssertEqual(job.shared, [pdf])

        job.includeRecordings(true)
        XCTAssertEqual(job.bundle, .making)
        XCTAssertEqual(job.shared, [], "nothing to share until the zip is made")
        await waitUntil(10) { if case .made = job.bundle { true } else { false } }
        guard case .made(let zip) = job.bundle else { return XCTFail("\(String(describing: job.bundle))") }
        XCTAssertEqual(job.shared, [zip])
        XCTAssertEqual(zip.lastPathComponent, "Biology.zip")
        XCTAssertEqual(zip.deletingLastPathComponent(), pdf.deletingLastPathComponent(), "in the export's own folder")
        let folder = try FileManager.default.contentsOfDirectory(atPath: pdf.deletingLastPathComponent().path(percentEncoded: false))
        XCTAssertEqual(Set(folder), ["Biology.pdf", "Biology.zip"], "nothing else is left beside them")
        let otherFile = RecordingExport.fileName(RecordingExport.fileStem(of: other), extension: "m4a")
        XCTAssertEqual(try zipEntries(zip), ["Biology/Biology.pdf", "Biology/Recordings/Lecture.txt", "Biology/Recordings/Lecture.wav",
                                             "Biology/Recordings/\(otherFile)"])

        job.includeRecordings(false)
        XCTAssertEqual(job.shared, [pdf], "turned off, the PDF goes alone")
        job.includeRecordings(true)
        XCTAssertEqual(job.shared, [zip], "and the zip already made is used again")

        job.close()
        let gone = pdf.deletingLastPathComponent().path(percentEncoded: false)
        await waitUntil { !FileManager.default.fileExists(atPath: gone) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: gone), "closing the sheet takes the zip with the PDF")

        let images = ExportJob(document: document, format: .images)
        XCTAssertEqual(images.recordingCount, 0, "only a PDF takes them")
        images.close()
    }

    /// The names in a zip's central directory, its folders left out.
    private func zipEntries(_ url: URL) throws -> [String] {
        let data = try Data(contentsOf: url)
        func number(_ offset: Int, _ size: Int) -> Int {
            (0..<size).reduce(0) { $0 | Int(data[data.startIndex + offset + $1]) << (8 * $1) }
        }
        let end = try XCTUnwrap(stride(from: data.count - 22, through: 0, by: -1).first { number($0, 4) == 0x0605_4b50 })
        var offset = number(end + 16, 4), names: [String] = []
        for _ in 0..<number(end + 10, 2) {
            XCTAssertEqual(number(offset, 4), 0x0201_4b50)
            let length = number(offset + 28, 2), extra = number(offset + 30, 2), comment = number(offset + 32, 2)
            let name = String(decoding: data[(data.startIndex + offset + 46)..<(data.startIndex + offset + 46 + length)], as: UTF8.self)
            if !name.hasSuffix("/") { names.append(name) }
            offset += 46 + length + extra + comment
        }
        return names.sorted()
    }
}
