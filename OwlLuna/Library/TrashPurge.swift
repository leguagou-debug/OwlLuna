import Foundation

/// Recently Deleted loses what is past its 30 days once a launch, and after a sync when there is one to wait
/// for: a notebook restored on another device has to arrive before it is counted as still deleted here.
@MainActor
final class TrashPurge {
    private let library: LibraryStore
    private let sync: SyncCenter
    private var isDue = true

    init(library: LibraryStore, sync: SyncCenter) {
        self.library = library
        self.sync = sync
        sync.onSynced = { [weak self] in await self?.empty(skipping: $0.waiting) }
    }

    /// Called at launch, once the first sync has been tried.
    func launchSyncTried() async {
        // While iCloud is still being looked for, a pass may be about to follow.
        while sync.availability == .checking { try? await Task.sleep(for: .milliseconds(50)) }
        // With nothing to sync with there is nothing to wait for.
        if !sync.canSync { await empty() }
    }

    /// Notebooks the sync left waiting are kept: it couldn't tell whether another device restored them.
    private func empty(skipping waiting: [UUID] = []) async {
        guard isDue else { return }
        isDue = false
        await library.purgeExpiredTrash(skipping: Set(waiting))
    }
}
