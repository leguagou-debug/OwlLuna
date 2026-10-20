import AVFoundation
import Observation
import UIKit

/// How fast recordings play. One speed for every notebook, kept from one playback to the next.
enum PlaybackSpeed {
    static let choices: [Double] = [0.75, 1, 1.25, 1.5, 2]

    static func saved(in defaults: UserDefaults) -> Double {
        let speed = defaults.double(forKey: SettingsKey.playbackSpeed)
        return choices.contains(speed) ? speed : 1
    }

    static func label(_ speed: Double) -> String {
        speed.formatted(.number.precision(.fractionLength(0...2))) + "×"
    }
}

/// Why a recording ended without Stop, told in the editor when the iPad is back in hand.
enum RecordingStop: Sendable {
    case locked, coverClosed, interrupted, failed, quit

    func message(at seconds: TimeInterval) -> String {
        let time = Self.clock(seconds)
        return switch self {
        case .locked: String(localized: "Recording stopped at \(time) when the notebook locked.")
        case .coverClosed: String(localized: "Recording stopped at \(time) when the iPad's cover was closed.")
        case .interrupted: String(localized: "Recording stopped at \(time) when another app needed the microphone.")
        case .failed: String(localized: "Recording stopped at \(time) because the audio couldn't be written. What came before is kept.")
        case .quit: String(localized: "Recording stopped at \(time) when OwlLuna quit. What came before is kept.")
        }
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let whole = seconds.isFinite ? Int(max(seconds, 0)) : 0
        return Duration.seconds(whole).formatted(.time(pattern: whole >= 3600 ? .hourMinuteSecond : .minuteSecond))
    }
}

/// A recording carries on with the iPad locked or another app in front, but nothing is recorded behind a notebook's lock.
enum BackgroundRecording {
    /// The stop due as the notebook's window moves or its lock changes; nil while the recording carries on.
    static func stop(locked: Bool, inBackground: Bool) -> RecordingStop? {
        locked && inBackground ? .locked : nil
    }

    /// Only a recording the iPad locking would stop keeps it awake; any other would just drain the battery.
    static func keepsAwake(locked: Bool) -> Bool { locked }
}

/// Records and plays audio attached to a notebook. Files go into the package's `assets/`; entries into the manifest.
@MainActor
@Observable
final class NotebookRecorder: NSObject {
    private(set) var isRecording = false
    /// Whole seconds recorded, all the record button shows, so it is redrawn once a second.
    private(set) var elapsed: TimeInterval = 0
    private(set) var playingID: UUID?
    /// How far into the recording playback is, and whether it is waiting there.
    private(set) var currentTime: TimeInterval = 0
    private(set) var isPaused = false
    private(set) var speed: Double
    var errorMessage: String?
    /// Called as playback moves, about ten times a second, and when it is moved by hand.
    @ObservationIgnored var onPlaybackTime: ((TimeInterval) -> Void)?
    @ObservationIgnored private var holdsAtEnd = false
    @ObservationIgnored private var inkedPages: Set<UUID> = []

    @ObservationIgnored private let document: NotebookDocument
    @ObservationIgnored var defaults: UserDefaults
    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var player: AVAudioPlayer?
    /// The entry for the recording being made, already in the manifest as unfinished.
    @ObservationIgnored private var unfinished: RecordingEntry?
    /// The recording being started, until it is. Stopping clears it, so a start overtaken by a close gives up.
    @ObservationIgnored private var startingRecording: UUID?
    @ObservationIgnored private var isInBackground = false
    @ObservationIgnored private var timer: Timer?
    /// The playback being started, until its player exists. Stopping playback clears it, so a start that was
    /// overtaken while the audio session switched gives up.
    @ObservationIgnored private var startingPlayback: UUID?
    private static var sessionChange: Task<Void, Error>?
    /// How far each transcription under way has got, by recording.
    private(set) var transcribing: [UUID: Double] = [:]
    @ObservationIgnored var transcriber: any SpeechTranscribing = Transcription.transcriber
    /// Called once a transcript has been written or removed, so search can pick it up.
    @ObservationIgnored var onTranscriptChange: (() -> Void)?
    @ObservationIgnored private var transcriptTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var transcripts: [String: Transcript] = [:]

    init(document: NotebookDocument, defaults: UserDefaults = .standard) {
        self.document = document
        self.defaults = defaults
        speed = PlaybackSpeed.saved(in: defaults)
        super.init()
        document.recorder = self
        NotificationCenter.default.addObserver(self, selector: #selector(sessionInterrupted), name: AVAudioSession.interruptionNotification, object: nil)
    }

    deinit {
        Task { @MainActor in IdleTimer.shared.refresh() }
    }

    /// iPadOS took the microphone away (a call, another app's sound, a cover closing): what was recorded is saved there.
    @objc private nonisolated func sessionInterrupted(_ notification: Notification) {
        let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
        guard raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:)) == .began else { return }
        let reason = (notification.userInfo?[AVAudioSessionInterruptionReasonKey] as? UInt).flatMap(AVAudioSession.InterruptionReason.init(rawValue:))
        let stop: RecordingStop = reason == .builtInMicMuted ? .coverClosed : .interrupted
        Task { @MainActor in self.stopRecording(because: stop) }
    }

    var recordings: [RecordingEntry] { document.manifest.recordings }
    var isReadOnly: Bool { document.isReadOnly }

    /// A page was written on. While recording, the entry remembers which, so a replay knows where to look.
    func noteInk(onPage pageID: UUID) {
        if isRecording { inkedPages.insert(pageID) }
    }

    /// The editor's window went to the background, the iPad locking or another app coming to the front, or came back.
    func noteWindow(inBackground: Bool) {
        isInBackground = inBackground
        keepToTheLock()
    }

    func noteLockChanged() {
        keepToTheLock()
    }

    /// Behind a notebook's lock a recording stops and playback waits; until then the recording keeps the iPad awake.
    private func keepToTheLock() {
        let locked = document.manifest.library.isLocked
        if let stop = BackgroundRecording.stop(locked: locked, inBackground: isInBackground) {
            stopRecording(because: stop)
            pause()
        }
        IdleTimer.shared.hold(isRecording && BackgroundRecording.keepsAwake(locked: locked), by: self)
    }

    func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    func startRecording() {
        guard !document.isReadOnly else { return }
        let request = UUID()
        startingRecording = request
        Task {
            guard await AVAudioApplication.requestRecordPermission() else {
                errorMessage = String(localized: "Microphone access is off. Turn it on in Settings › Privacy & Security › Microphone.")
                return
            }
            do {
                guard startingRecording == request else { return }
                stopPlayback()
                try await Self.changeSession {
                    try $0.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
                    try $0.setActive(true)
                }.value
                if document.isSetAside { startingRecording = nil }
                guard startingRecording == request, recorder == nil else {
                    if startingRecording == nil, recorder == nil { Self.changeSession { try $0.setActive(false, options: .notifyOthersOnDeactivation) } }
                    return
                }
                startingRecording = nil
                stopPlayback()
                try FileManager.default.createDirectory(at: document.package.assetsDirectory, withIntermediateDirectories: true)
                let (recorder, file) = try makeRecorder()
                recorder.delegate = self
                self.recorder = recorder
                var entry = RecordingEntry(id: UUID(), file: file, createdAt: .now, duration: 0)
                entry.startedAt = entry.createdAt
                unfinished = entry
                document.beginRecording(entry)
                inkedPages = []
                isRecording = true
                elapsed = 0
                startTimer()
                keepToTheLock()
            } catch {
                errorMessage = String(localized: "Recording couldn't start: \(error.localizedDescription)")
            }
        }
    }

    /// Records to a file a cut-off recording can be read back from, or to an `.m4a` as before if that can't be made.
    private func makeRecorder() throws -> (AVAudioRecorder, String) {
        let file = "\(UUID().uuidString).\(RecordingFile.recordingExtension)"
        if let recorder = try? AVAudioRecorder(url: document.package.assetURL(file), settings: RecordingFile.settings), recorder.record() {
            return (recorder, file)
        }
        let fallback = "\(UUID().uuidString).m4a"
        let recorder = try AVAudioRecorder(url: document.package.assetURL(fallback), settings: RecordingFile.settings)
        guard recorder.record() else { throw ImportError.unreadable }
        return (recorder, fallback)
    }

    /// Stops and keeps what was recorded. A `reason` is for a stop the user didn't ask for, which the editor then tells them about.
    func stopRecording(because reason: RecordingStop? = nil) {
        startingRecording = nil
        guard let recorder, var entry = unfinished else { return }
        let duration = recorder.isRecording ? recorder.currentTime : elapsed
        recorder.delegate = nil
        recorder.stop()
        self.recorder = nil
        unfinished = nil
        isRecording = false
        stopTimer()
        IdleTimer.shared.hold(false, by: self)
        entry.createdAt = .now
        entry.duration = duration
        entry.inkedPages = Array(inkedPages)
        if let reason { document.noteRecordingStopped(reason.message(at: duration)) }
        document.finishRecording(entry)
        saveStoppedRecording()
        Self.changeSession { try $0.setActive(false, options: .notifyOthersOnDeactivation) }
    }

    /// Letting go of the audio session lets iPadOS suspend an app in the background, so the recording is saved under a background task.
    private func saveStoppedRecording() {
        let document = document
        var task = UIBackgroundTaskIdentifier.invalid
        task = UIApplication.shared.beginBackgroundTask(withName: "Save recording") {
            UIApplication.shared.endBackgroundTask(task)
            task = .invalid
        }
        Task {
            await document.finishPendingWork()
            await document.flush()
            if task != .invalid { UIApplication.shared.endBackgroundTask(task) }
        }
    }

    fileprivate func recorderStopped(_ id: ObjectIdentifier, because reason: RecordingStop) {
        guard let recorder, ObjectIdentifier(recorder) == id else { return }
        stopRecording(because: reason)
    }

    /// Switching the shared audio session can block while the audio hardware answers, so it is done off the main
    /// thread, one change at a time and in the order asked for.
    @discardableResult
    private static func changeSession(_ change: @escaping @Sendable (AVAudioSession) throws -> Void) -> Task<Void, Error> {
        let previous = sessionChange
        let task = Task.detached(priority: .userInitiated) {
            _ = await previous?.result
            try change(AVAudioSession.sharedInstance())
        }
        sessionChange = task
        return task
    }

    /// A player wakes the audio session itself as it gets ready to play, so that is done off the main thread too.
    @concurrent
    private nonisolated static func readyPlayer(for url: URL) async throws -> AVAudioPlayer {
        let player = try AVAudioPlayer(contentsOf: url)
        // A player only takes a rate if it was asked to before getting ready.
        player.enableRate = true
        player.prepareToPlay()
        return player
    }

    /// Playback would switch the shared audio session away from recording, so it waits until recording stops.
    func togglePlayback(_ recording: RecordingEntry) {
        if playingID == recording.id { return stopPlayback() }
        Task { await start(recording) }
    }

    @discardableResult
    private func start(_ recording: RecordingEntry) async -> Bool {
        guard !isRecording else { return false }
        stopPlayback()
        let request = UUID()
        startingPlayback = request
        do {
            try await Self.changeSession {
                try $0.setCategory(.playback)
                try $0.setActive(true)
            }.value
            let player = try await Self.readyPlayer(for: document.package.assetURL(recording.file))
            guard startingPlayback == request, !isRecording else { return false }
            startingPlayback = nil
            player.delegate = self
            speed = PlaybackSpeed.saved(in: defaults)
            player.rate = Float(speed)
            player.play()
            self.player = player
            playingID = recording.id
            startTimer()
            return true
        } catch {
            if startingPlayback == request { startingPlayback = nil }
            errorMessage = String(localized: "This recording couldn't be played.")
            return false
        }
    }

    /// Plays a recording from its start and stays on it when it ends, for replaying it with its ink.
    func beginReplay(_ recording: RecordingEntry) async -> Bool {
        guard await start(recording) else { return false }
        holdsAtEnd = true
        return true
    }

    func pause() {
        guard let player, !isPaused else { return }
        player.pause()
        isPaused = true
        report(player.currentTime)
    }

    func resume() {
        guard let player, isPaused else { return }
        if currentTime >= player.duration - 0.05 { player.currentTime = 0 }
        player.play()
        isPaused = false
    }

    /// Playback goes on at `speed` from where it is; the position stays in the recording's own time.
    func setSpeed(_ speed: Double) {
        guard PlaybackSpeed.choices.contains(speed) else { return }
        self.speed = speed
        player?.rate = Float(speed)
        defaults.set(speed, forKey: SettingsKey.playbackSpeed)
    }

    /// The rate the sound is playing at, nil when nothing is.
    var playerRate: Float? { player?.rate }

    func seek(to time: TimeInterval) {
        guard let player else { return }
        let target = min(max(time, 0), player.duration)
        player.currentTime = min(target, max(player.duration - 0.01, 0))
        report(target)
    }

    private func report(_ time: TimeInterval) {
        currentTime = time
        onPlaybackTime?(time)
    }

    func stopPlayback() {
        player?.stop()
        player = nil
        startingPlayback = nil
        playingID = nil
        currentTime = 0
        isPaused = false
        holdsAtEnd = false
        if !isRecording { stopTimer() }
    }

    fileprivate func playbackFinished() {
        guard holdsAtEnd, let player else { return stopPlayback() }
        isPaused = true
        report(player.duration)
    }

    /// Removes the entry; the audio file is cleaned up with the package's other unreferenced assets.
    func delete(_ recording: RecordingEntry) {
        if playingID == recording.id { stopPlayback() }
        cancelTranscription(recording.id)
        document.removeRecording(recording.id)
        guard recording.transcriptFile != nil else { return }
        let package = document.package, id = recording.id
        Task { [weak self] in
            await package.removeTranscriptText(id)
            self?.onTranscriptChange?()
        }
    }

    /// Nothing, or only spaces, takes it back to being named after when it began.
    func rename(_ recording: RecordingEntry, to title: String) {
        document.renameRecording(recording.id, to: title)
    }

    enum Part: Sendable { case audio, transcript }

    /// Writes the recording, or what was said in it, into an export folder of its own for sharing. A locked notebook
    /// has to be unlocked first; nil when it stays locked or there is no transcript.
    func files(sharing part: Part, of recording: RecordingEntry) async throws -> [URL]? {
        if document.manifest.library.isLocked, !(await NotebookLock.shared.unlock(document.id, title: document.title)) { return nil }
        let transcript = part == .transcript ? transcript(for: recording) : nil
        guard part == .audio || transcript?.isEmpty == false else { return nil }
        let package = document.package, name = RecordingExport.fileStem(of: recording)
        return try await Task.detached(priority: .userInitiated) {
            let folder = try ExportFolder.make(.export)
            do {
                if let transcript { return [try RecordingExport.write(transcript, named: name, into: folder)] }
                return [try RecordingExport.copyAudio(of: recording, from: package, named: name, into: folder)]
            } catch {
                try? FileManager.default.removeItem(at: folder)
                throw error
            }
        }.value
    }

    func shutdown() {
        stopRecording()
        stopPlayback()
        for id in Array(transcriptTasks.keys) { cancelTranscription(id) }
    }

    // MARK: Transcripts

    func transcript(for recording: RecordingEntry) -> Transcript? {
        guard let file = recording.transcriptFile else { return nil }
        if let held = transcripts[file] { return held }
        let read = document.package.readTranscript(file)
        transcripts[file] = read
        return read
    }

    /// Writes down what was said, on the device. The result replaces any transcript the recording already has.
    func transcribe(_ recording: RecordingEntry, locale: Locale) {
        guard !document.isReadOnly, transcriptTasks[recording.id] == nil else { return }
        let id = recording.id, url = document.package.assetURL(recording.file), transcriber = transcriber
        transcribing[id] = 0
        transcriptTasks[id] = Task { [weak self] in
            do {
                let transcript = try await transcriber.transcribe(url, locale: locale) { fraction in
                    Task { @MainActor in
                        guard let self, let current = self.transcribing[id] else { return }
                        self.transcribing[id] = max(current, fraction)
                    }
                }
                try Task.checkCancellation()
                guard let self else { return }
                let file = try await self.document.package.writeTranscript(transcript, recordingID: id)
                self.transcripts[file] = transcript
                self.document.setTranscript(file, forRecording: id)
                self.onTranscriptChange?()
            } catch is CancellationError {
            } catch {
                self?.errorMessage = error.localizedDescription
            }
            self?.transcribing[id] = nil
            self?.transcriptTasks[id] = nil
        }
    }

    func cancelTranscription(_ id: UUID) {
        transcriptTasks[id]?.cancel()
        transcriptTasks[id] = nil
        transcribing[id] = nil
    }

    func removeTranscript(_ recording: RecordingEntry) {
        guard !document.isReadOnly, recording.transcriptFile != nil else { return }
        document.setTranscript(nil, forRecording: recording.id)
        let package = document.package, id = recording.id
        Task { [weak self] in
            await package.removeTranscriptText(id)
            self?.onTranscriptChange?()
        }
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: player == nil ? 0.25 : 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        if let recorder, recorder.isRecording { elapsed = recorder.currentTime.rounded(.down) }
        if let player, player.isPlaying { report(player.currentTime) }
    }
}

extension NotebookRecorder: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.playbackFinished() }
    }
}

extension NotebookRecorder: AVAudioRecorderDelegate {
    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        let id = ObjectIdentifier(recorder)
        Task { @MainActor in self.recorderStopped(id, because: .failed) }
    }

    /// Only a stop the recorder came to by itself reaches here: `stopRecording` lets go of the delegate first.
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        let id = ObjectIdentifier(recorder)
        Task { @MainActor in self.recorderStopped(id, because: flag ? .interrupted : .failed) }
    }
}
