import AVFoundation
import AudioToolbox

/// A recording's sound on disk: made as ADTS, whose frames each carry a header so a cut-off file still plays, then copied into an `.m4a`.
enum RecordingFile {
    static let recordingExtension = "aac"

    static var settings: [String: Any] {
        [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1, AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue]
    }

    /// The finished file and how long it plays, or nil when nothing playable was written.
    static func finish(_ url: URL) -> (url: URL, duration: TimeInterval)? {
        if url.pathExtension == recordingExtension {
            let target = url.deletingPathExtension().appendingPathExtension("m4a")
            if (try? remux(url, to: target)) != nil, let duration = duration(of: target) { return (target, duration) }
            try? FileManager.default.removeItem(at: target)
        }
        return duration(of: url).map { (url, $0) }
    }

    static func duration(of url: URL) -> TimeInterval? {
        guard let file = try? AVAudioFile(forReading: url), file.length > 0, file.fileFormat.sampleRate > 0 else { return nil }
        return Double(file.length) / file.fileFormat.sampleRate
    }

    /// Copies the AAC packets as they are, so nothing is encoded again; a last frame cut short is left out.
    static func remux(_ source: URL, to target: URL) throws {
        func check(_ status: OSStatus) throws {
            if status != noErr { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        }
        var opened: AudioFileID?
        try check(AudioFileOpenURL(source as CFURL, .readPermission, kAudioFileAAC_ADTSType, &opened))
        guard let input = opened else { throw CocoaError(.fileReadCorruptFile) }
        defer { AudioFileClose(input) }
        var format = AudioStreamBasicDescription(), size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioFileGetProperty(input, kAudioFilePropertyDataFormat, &size, &format))
        var created: AudioFileID?
        try check(AudioFileCreateWithURL(target as CFURL, kAudioFileM4AType, &format, .eraseFile, &created))
        guard let output = created else { throw CocoaError(.fileWriteUnknown) }
        defer { AudioFileClose(output) }
        var cookieSize: UInt32 = 0
        if AudioFileGetPropertyInfo(input, kAudioFilePropertyMagicCookieData, &cookieSize, nil) == noErr, cookieSize > 0 {
            var cookie = [UInt8](repeating: 0, count: Int(cookieSize))
            try check(AudioFileGetProperty(input, kAudioFilePropertyMagicCookieData, &cookieSize, &cookie))
            try check(AudioFileSetProperty(output, kAudioFilePropertyMagicCookieData, cookieSize, cookie))
        }
        var largest: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        _ = AudioFileGetProperty(input, kAudioFilePropertyPacketSizeUpperBound, &size, &largest)
        let batch: UInt32 = 256
        var bytes = [UInt8](repeating: 0, count: Int(max(largest, 8192) * batch))
        var packets = [AudioStreamPacketDescription](repeating: AudioStreamPacketDescription(), count: Int(batch))
        var next: Int64 = 0
        while true {
            var byteCount = UInt32(bytes.count), count = batch
            let status = AudioFileReadPacketData(input, false, &byteCount, &packets, next, &count, &bytes)
            if status != noErr, status != kAudioFileEndOfFileError {
                if next > 0 { break }
                try check(status)
            }
            if count == 0 { break }
            try check(AudioFileWritePackets(output, false, byteCount, packets, next, &count, bytes))
            next += Int64(count)
        }
        guard next > 0 else { throw CocoaError(.fileReadCorruptFile) }
    }
}
