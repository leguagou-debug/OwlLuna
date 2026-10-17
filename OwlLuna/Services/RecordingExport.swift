import Foundation

/// A recording and what was said in it as files of their own: shared from its row, or zipped beside a notebook's PDF.
enum RecordingExport {
    /// The audio under the recording's name. Within one volume the copy is a clone, so a long lecture costs no room.
    static func copyAudio(of recording: RecordingEntry, from package: NotebookPackage, named name: String, number: String = "",
                          into folder: URL) throws -> URL {
        let ext = URL(filePath: recording.file).pathExtension
        let url = folder.appending(path: fileName(name, number: number, extension: ext.isEmpty ? "m4a" : ext))
        try FileManager.default.copyItem(at: package.assetURL(recording.file), to: url)
        return url
    }

    static func write(_ transcript: Transcript, named name: String, number: String = "", into folder: URL) throws -> URL {
        let url = folder.appending(path: fileName(name, number: number, extension: "txt"))
        try Data((transcript.fileText + "\n").utf8).write(to: url, options: .atomic)
        return url
    }

    /// What its files are called: its title, or when it began with the time as 9.30, as an export turns a colon into a dash.
    static func fileStem(of recording: RecordingEntry) -> String {
        recording.title ?? recording.name.replacingOccurrences(of: ":", with: ".")
    }

    /// Each recording's file stem, and the number that keeps it apart from an earlier one named alike.
    static func names(for recordings: [RecordingEntry]) -> [UUID: (name: String, number: String)] {
        var taken = Set<String>(), result: [UUID: (name: String, number: String)] = [:]
        for recording in recordings {
            let stem = fileStem(of: recording)
            var copy = 1, number = ""
            // File systems mostly ignore case, so "Lecture" and "lecture" would land on one file.
            while !taken.insert(fileName(stem, number: number, extension: "").lowercased()).inserted {
                copy += 1
                number = " \(copy)"
            }
            result[recording.id] = (stem, number)
        }
        return result
    }

    /// The narrow space some languages put before AM or PM reads as a plain one in a file name.
    static func fileName(_ name: String, number: String = "", extension ext: String) -> String {
        NotebookExporter.fileName(name.replacingOccurrences(of: "\u{202F}", with: " "), number: number, extension: ext)
    }

    /// Zips `folder` into `destination`, with the folder itself at the top of the zip.
    static func zip(_ folder: URL, to destination: URL) throws {
        var coordination: NSError?, failure: Error?
        NSFileCoordinator().coordinate(readingItemAt: folder, options: .forUploading, error: &coordination) { zipped in
            do { try FileManager.default.moveItem(at: zipped, to: destination) } catch { failure = error }
        }
        if let error = coordination ?? failure { throw error }
    }
}

extension NotebookExporter {
    /// The PDF with the notebook's recordings and their transcripts, zipped beside it in its export folder. One zip
    /// goes through every share, Mail and Messages included, where a folder would not.
    static func bundle(_ pdf: URL, with input: Input) throws -> URL {
        let folder = pdf.deletingLastPathComponent(), stem = pdf.deletingPathExtension().lastPathComponent
        let staging = folder.appending(path: stem, directoryHint: .isDirectory)
        let recordings = staging.appending(path: String(localized: "Recordings"), directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: staging)
        // One level at a time, so an export folder discarded meanwhile isn't made again.
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: false)
        try FileManager.default.copyItem(at: pdf, to: staging.appending(path: pdf.lastPathComponent))
        let names = RecordingExport.names(for: input.recordings)
        for recording in input.recordings {
            try Task.checkCancellation()
            let name = names[recording.id] ?? (RecordingExport.fileStem(of: recording), "")
            _ = try RecordingExport.copyAudio(of: recording, from: input.package, named: name.name, number: name.number, into: recordings)
            if let file = recording.transcriptFile, let transcript = input.package.readTranscript(file), !transcript.isEmpty {
                _ = try RecordingExport.write(transcript, named: name.name, number: name.number, into: recordings)
            }
        }
        try Task.checkCancellation()
        let zip = folder.appending(path: fileName(stem, extension: "zip"))
        try? FileManager.default.removeItem(at: zip)
        try RecordingExport.zip(staging, to: zip)
        return zip
    }
}
