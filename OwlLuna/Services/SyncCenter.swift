import Foundation
import Observation
import CryptoKit
import os

/// Runs the library's sync with iCloud: finds the container, decides when to sync, and tells the library what changed.
/// Nothing is copied until it has been allowed once on this device, and it is unavailable in a build without the
/// iCloud capability.
@MainActor
@Observable
final class SyncCenter {
    enum Availability: Equatable {
        case checking
        case unavailable(String)
        case available
    }

    /// What has to be answered before anything is copied.
    enum Question: Equatable {
        /// This device has never synced.
        case firstSync
        /// The Apple Account signed in isn't the one this library was last synced with.
        case accountChanged
    }

    private(set) var availability = Availability.checking
    private(set) var question: Question?
    private(set) var isSyncing = false
    private(set) var lastSynced: Date?
    private(set) var lastError: String?
    private(set) var lastReport: SyncReport?
    /// The switch in Settings. It can be set while iCloud is unavailable, and takes effect once it isn't.
    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            defaults.set(isEnabled, forKey: SettingsKey.syncsWithICloud)
            guard isEnabled else {
                // Turning sync off is an answer to whatever was being asked.
                question = nil
                return halt()
            }
            Task {
                await review()
                schedule(after: .zero)
            }
        }
    }

    @ObservationIgnored private let root: StorageRoot
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let hadSynced: Bool
    @ObservationIgnored private var cloud: CloudFolder?
    @ObservationIgnored private var account: String?
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var query: NSMetadataQuery?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var identityObserver: NSObjectProtocol?
    @ObservationIgnored private var wantsAnotherPass = false
    @ObservationIgnored private var running: Task<SyncReport, Error>?
    @ObservationIgnored private var reviewing = 0
    @ObservationIgnored private let log = Logger(subsystem: "com.owais.OwlLuna", category: "sync")
    /// Called after a sync that changed the library on this device, so the index can be brought up to date.
    @ObservationIgnored var onLibraryChanged: (@MainActor (SyncReport) async -> Void)?
    /// Called after every pass that finished, once the library has heard what it changed.
    @ObservationIgnored var onSynced: (@MainActor () -> Void)?
    /// A pass takes each notebook in hand just before it touches it, and lets it go after. One that is open in an
    /// editor can't be taken, and is left for next time.
    @ObservationIgnored var take: @MainActor (UUID) -> Bool = { _ in true }
    @ObservationIgnored var release: @MainActor (UUID) -> Void = { _ in }

    init(root: StorageRoot, defaults: UserDefaults = .standard) {
        self.root = root
        self.defaults = defaults
        // A device that synced before there was a question to answer has already been syncing: it carries on.
        hadSynced = FileManager.default.fileExists(atPath: SyncState.file(root).path(percentEncoded: false))
        isEnabled = defaults.object(forKey: SettingsKey.syncsWithICloud) == nil ? hadSynced : defaults.bool(forKey: SettingsKey.syncsWithICloud)
    }

    private var isDecided: Bool { hadSynced || defaults.object(forKey: SettingsKey.syncsWithICloud) != nil }

    /// Whether a pass may run: sync is on, the copy is found, and nothing is being asked or worked out.
    var canSync: Bool { isEnabled && question == nil && availability == .available && reviewing == 0 && cloud != nil }

    /// A marker for an Apple Account: a digest of the token iPadOS gives the app for it. It tells one account from
    /// another and nothing else.
    nonisolated static func marker(for token: (any NSCoding & NSCopying & NSObjectProtocol)?) -> String? {
        guard let token else { return nil }
        let data = (token as? NSData).map { $0 as Data } ?? (try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: false))
        return data.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
    }

    /// Finds where the synced copy lives. A test can stand a plain folder in for iCloud with `-cloudFolder <name>`,
    /// and a name in for the account with `-cloudAccount <name>`.
    func resolve() async {
        #if DEBUG
        if let name = LaunchOptions.value("-cloudFolder") {
            let url = URL.applicationSupportDirectory.appending(path: "UITesting/cloud-\(name)", directoryHint: .isDirectory)
            if LaunchOptions.arguments.contains("-resetCloud") { try? FileManager.default.removeItem(at: url) }
            return await use(CloudFolder(url: url), account: LaunchOptions.value("-cloudAccount"))
        }
        #endif
        let signedOut = String(localized: "iCloud isn't available. Sign in to iCloud and turn on iCloud Drive in Settings; this copy of OwlLuna also has to be built with the iCloud capability.")
        // A test's storage root never syncs with real iCloud.
        guard LaunchOptions.value("-storageRoot") == nil else { return leave(signedOut) }
        if identityObserver == nil {
            identityObserver = NotificationCenter.default.addObserver(forName: .NSUbiquityIdentityDidChange, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.identityChanged() }
            }
        }
        guard let token = FileManager.default.ubiquityIdentityToken else { return leave(signedOut) }
        let container = await Task.detached(priority: .utility) { FileManager.default.url(forUbiquityContainerIdentifier: nil) }.value
        guard let container else {
            return leave(String(localized: "This copy of OwlLuna was built without the iCloud capability, so it can't sync."))
        }
        await use(CloudFolder(url: container.appending(path: "Sync", directoryHint: .isDirectory), isUbiquitous: true), account: Self.marker(for: token))
    }

    /// The synced copy has been found. What has to be asked first is worked out before sync is said to be
    /// available, so no pass touches the copy in between.
    func use(_ cloud: CloudFolder, account: String?) async {
        if cloud != self.cloud || account != self.account { halt() }
        availability = .checking
        self.cloud = cloud
        self.account = account
        await review()
        availability = .available
        if canSync { startWatching() }
    }

    private func leave(_ reason: String) {
        halt()
        cloud = nil
        account = nil
        question = nil
        availability = .unavailable(reason)
    }

    /// Signing out of iCloud, or in with another account, moves the container out from under the app. Nothing
    /// syncs until the account now signed in has been looked at.
    private func identityChanged() {
        halt()
        cloud = nil
        availability = .checking
        Task {
            await resolve()
            await syncNow()
        }
    }

    /// Works out what has to be asked. No pass starts while it does.
    private func review() async {
        guard cloud != nil else { return }
        reviewing += 1
        defer { reviewing -= 1 }
        let root = root
        let known = await Task.detached(priority: .utility) { SyncState.read(root).account }.value
        // Another account only matters while sync is on: with it off nothing is copied, and a refusal stands.
        if isEnabled, let account, let known, known != account {
            question = .accountChanged
        } else if !isDecided {
            question = .firstSync
        } else {
            question = nil
        }
    }

    /// The answer to `question`. Saying no turns sync off; turning it on again in Settings asks again while another
    /// account is still signed in.
    func answer(_ allowed: Bool) async {
        guard let asked = question else { return }
        guard allowed else {
            question = nil
            if isEnabled { isEnabled = false } else { defaults.set(false, forKey: SettingsKey.syncsWithICloud) }
            return
        }
        if asked == .accountChanged {
            // Only the marker moves. Whether what was agreed still holds is for the copy's own ID to say.
            let root = root, account = account
            await Task.detached(priority: .utility) {
                var state = SyncState.read(root)
                state.account = account
                try? state.write(root)
            }.value
        }
        question = nil
        if isEnabled {
            startWatching()
            await syncNow()
        } else {
            isEnabled = true
        }
    }

    /// Syncs a little later, so a burst of changes becomes one sync.
    func schedule(after delay: Duration = .seconds(4)) {
        guard canSync else { return }
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.syncNow()
        }
    }

    func syncNow() async {
        guard canSync else { return }
        guard !isSyncing else { wantsAnotherPass = true; return }
        isSyncing = true
        defer { isSyncing = false }
        repeat {
            wantsAnotherPass = false
            do {
                // A second pass uploads the copies a conflict left behind.
                guard var report = try await pass() else { break }
                if !report.conflictCopies.isEmpty, let again = try await pass() { report.pushed += again.pushed }
                lastReport = report
                lastSynced = .now
                lastError = nil
                if report.changedHere { await onLibraryChanged?(report) }
                onSynced?()
            } catch is CancellationError {
                // Stopped part-way because sync was turned off or the copy moved. Whoever stopped it decides what follows.
            } catch SyncError.accountChanged {
                identityChanged()
            } catch {
                lastError = error.localizedDescription
                log.error("sync failed: \(error.localizedDescription)")
            }
        } while wantsAnotherPass
        if canSync { startWatching() }
    }

    /// One pass, or nil when sync may no longer run. That is asked before every pass, since the account may have
    /// changed or sync been turned off during the one before, and a ubiquitous pass asks the account again as it goes.
    private func pass() async throws -> SyncReport? {
        guard canSync, let cloud else { return nil }
        let root = root, account = account, take = take, release = release
        let signedIn: @Sendable () -> String? = { SyncCenter.marker(for: FileManager.default.ubiquityIdentityToken) }
        let task = Task.detached(priority: .utility) {
            try await LibrarySync.run(root: root, cloud: cloud, account: account, take: { await take($0) }, release: { await release($0) },
                                      signedIn: cloud.isUbiquitous ? signedIn : nil)
        }
        running = task
        defer { running = nil }
        return try await task.value
    }

    /// Notebooks arriving from another device show up as changes to the container's files.
    private func startWatching() {
        guard query == nil, cloud?.isUbiquitous == true else { return }
        let query = NSMetadataQuery()
        query.searchScopes = [NSMetadataQueryUbiquitousDataScope]
        query.predicate = NSPredicate(format: "%K == %@", NSMetadataItemFSNameKey, "manifest.json")
        for name in [Notification.Name.NSMetadataQueryDidUpdate, .NSMetadataQueryDidFinishGathering] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: query, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.schedule() }
            })
        }
        query.start()
        self.query = query
    }

    /// Stops watching the container, and a pass that is part-way.
    private func halt() {
        pending?.cancel()
        running?.cancel()
        query?.stop()
        query = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }
}

/// The words for what sync asks, in the library's notice and in Settings.
enum SyncQuestion {
    static func title(_ question: SyncCenter.Question) -> String {
        switch question {
        case .firstSync: String(localized: "Keep a copy of your notebooks in iCloud?")
        case .accountChanged: String(localized: "A different Apple Account is signed in")
        }
    }

    static func message(_ question: SyncCenter.Question) -> String {
        switch question {
        case .firstSync:
            String(localized: "OwlLuna can copy every notebook, folder and sticker to your private iCloud storage, so your other devices have them. Nothing is copied until you choose to, and Settings › iCloud in OwlLuna can change it later.")
        case .accountChanged: accountChangedMessage
        }
    }

    static var accountChangedMessage: String {
        String(localized: "This iPad's notebooks were last synced with another account's iCloud. Syncing with this account copies them to its iCloud storage and brings in the notebooks it holds.")
    }

    static func allow(_ question: SyncCenter.Question) -> String {
        switch question {
        case .firstSync: String(localized: "Sync with iCloud")
        case .accountChanged: String(localized: "Sync with This Account")
        }
    }

    static func refuse(_ question: SyncCenter.Question) -> String {
        switch question {
        case .firstSync: String(localized: "Not Now")
        case .accountChanged: String(localized: "Turn Off Sync")
        }
    }
}

extension SyncReport {
    /// "3 notebooks sent, 1 received." for the Settings row. A notebook whose lock or folder alone was carried counts too.
    var summary: String {
        var parts: [String] = []
        let sent = Set(pushed).union(stateSent).count, received = Set(pulled).union(stateReceived).count
        let deletions = removedHere.count + removedThere.count
        if sent > 0 { parts.append(String(localized: "\(sent) notebooks sent")) }
        if received > 0 { parts.append(String(localized: "\(received) notebooks received")) }
        if deletions > 0 { parts.append(String(localized: "\(deletions) deletions carried over")) }
        if conflictCopies.count > 0 { parts.append(String(localized: "\(conflictCopies.count) conflicted copies kept")) }
        if waiting.count > 0 { parts.append(String(localized: "\(waiting.count) notebooks waiting until they're closed")) }
        return parts.isEmpty ? String(localized: "Everything is up to date") : parts.joined(separator: ", ")
    }
}
