import AVFoundation

/// A notebook's recorder, as the app's one audio session sees it.
@MainActor
protocol AudioSessionUser: AnyObject {
    /// Another notebook began recording, and whatever plays here would be recorded with it.
    func giveWayToRecording()
}

/// The audio session every window shares: one recording at a time, never switched away from it, let go once nothing records or plays.
@MainActor
final class AudioSessionOwner {
    enum Use: Equatable, Sendable { case idle, playback, recording }

    static let shared = AudioSessionOwner()

    private struct Holder { weak var user: (any AudioSessionUser)? }

    private var recorder = Holder()
    private var players: [ObjectIdentifier: Holder] = [:]
    private var applied = Use.idle
    private var lastChange: Task<Void, Error>?
    private let apply: @Sendable (Use) throws -> Void

    init(apply: @escaping @Sendable (Use) throws -> Void = AudioSessionOwner.configure) {
        self.apply = apply
    }

    var use: Use {
        if recorder.user != nil { return .recording }
        return players.values.contains { $0.user != nil } ? .playback : .idle
    }

    func isRecording(_ user: AnyObject) -> Bool { recorder.user === user }
    func isPlaying(_ user: AnyObject) -> Bool { players[ObjectIdentifier(user)]?.user === user }

    /// False while another notebook is recording.
    func claimRecording(for user: any AudioSessionUser) async throws -> Bool {
        if let other = recorder.user, other !== user { return false }
        recorder = Holder(user: user)
        let change = change(force: true)
        for other in players.values.compactMap(\.user) where other !== user { other.giveWayToRecording() }
        do {
            try await change?.value
        } catch {
            releaseRecording(by: user)
            throw error
        }
        return true
    }

    func releaseRecording(by user: AnyObject) {
        guard recorder.user === user else { return }
        recorder = Holder()
        change()
    }

    /// False while another notebook is recording: the sound would go into that recording.
    func claimPlayback(for user: any AudioSessionUser) async throws -> Bool {
        if let other = recorder.user, other !== user { return false }
        players[ObjectIdentifier(user)] = Holder(user: user)
        do {
            try await change(force: use == .playback)?.value
        } catch {
            releasePlayback(by: user)
            throw error
        }
        return true
    }

    func releasePlayback(by user: AnyObject) {
        guard players.removeValue(forKey: ObjectIdentifier(user)) != nil else { return }
        change()
    }

    /// Lets go for users that are gone without saying so, so the session never outlives what took it.
    func refresh() {
        players = players.filter { $0.value.user != nil }
        change()
    }

    func settled() async {
        _ = await lastChange?.result
    }

    /// Switching the session can block while the audio hardware answers, so it is done off the main thread, in the order asked for.
    @discardableResult
    private func change(force: Bool = false) -> Task<Void, Error>? {
        let use = use
        guard force || use != applied else { return nil }
        applied = use
        let previous = lastChange, apply = apply
        let task = Task.detached(priority: .userInitiated) {
            _ = await previous?.result
            try apply(use)
        }
        lastChange = task
        return task
    }

    nonisolated static func configure(_ use: Use) throws {
        let session = AVAudioSession.sharedInstance()
        switch use {
        case .recording:
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)
        case .playback:
            try session.setCategory(.playback)
            try session.setActive(true)
        case .idle:
            try session.setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}
