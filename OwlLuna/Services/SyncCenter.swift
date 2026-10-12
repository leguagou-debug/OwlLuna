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
            guard isEnabled else { return stopWatching() }
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
    @ObservationIgnored private let log = Logger(subsystem: "com.owais.OwlLuna", category: "sync")
    /// Called after a sync that changed the library on this device, so the index can be brought up to date.
    @ObservationIgnored var onLibraryChanged: (@MainActor (SyncReport) async -> Void)?
    /// The notebooks open in an editor, which a sync leaves alone.
    @ObservationIgnored var busy: @MainActor () -> Set<UUID> = { [] }

    init(root: StorageRoot, defaults: UserDefaults = .standard) {
        self.root = root
        self.defaults = defaults
        // A device that synced before there was a question to answer has already been syncing: it carries on.
        hadSynced = FileManager.default.fileExists(atPath: SyncState.file(root).path(percentEncoded: false))
        isEnabled = defaults.object(forKey: SettingsKey.syncsWithICloud) == nil ? hadSynced : defaults.bool(forKey: SettingsKey.syncsWithICloud)
    }

    private var isDecided: Bool { hadSynced || defaults.object(forKey: SettingsKey.syncsWithICloud) != nil }

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

    /// The synced copy has been found. Anything that has to be asked first is asked before it is touched.
    func use(_ cloud: CloudFolder, account: String?) async {
        self.cloud = cloud
        self.account = account
        availability = .available
        await review()
        if isEnabled, question == nil { startWatching() }
    }

    private func leave(_ reason: String) {
        stopWatching()
        cloud = nil
        account = nil
        question = nil
        availability = .unavailable(reason)
    }

    /// Signing out of iCloud, or in with another account, moves the container out from under the app.
    private func identityChanged() {
        stopWatching()
        cloud = nil
        Task {
            await resolve()
            await syncNow()
        }
    }

    private func review() async {
        guard availability == .available else { return }
        let root = root
        let known = await Task.detached(priority: .utility) { SyncState.read(root).account }.value
        if let account, let known, known != account {
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
        guard isEnabled, question == nil, availability == .available else { return }
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.syncNow()
        }
    }

    func syncNow() async {
        guard isEnabled, question == nil, availability == .available, let cloud else { return }
        guard !isSyncing else { wantsAnotherPass = true; return }
        isSyncing = true
        defer { isSyncing = false }
        repeat {
            wantsAnotherPass = false
            let root = root, busy = busy(), account = account
            do {
                // A second pass uploads the copies a conflict left behind.
                var report = try await Task.detached(priority: .utility) { try await LibrarySync.run(root: root, cloud: cloud, busy: busy, account: account) }.value
                if !report.conflictCopies.isEmpty {
                    let again = try await Task.detached(priority: .utility) { try await LibrarySync.run(root: root, cloud: cloud, busy: busy, account: account) }.value
                    report.pushed += again.pushed
                }
                lastReport = report
                lastSynced = .now
                lastError = nil
                if report.changedHere { await onLibraryChanged?(report) }
            } catch {
                lastError = error.localizedDescription
                log.error("sync failed: \(error.localizedDescription)")
            }
        } while wantsAnotherPass
        if query == nil, cloud.isUbiquitous { startWatching() }
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

    private func stopWatching() {
        pending?.cancel()
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
            String(localized: "OwlLuna can copy every notebook, folder and sticker to your private iCloud storage, so your other devices have them. Nothing is copied until you choose to, and Settings › iCloud can change it later.")
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
