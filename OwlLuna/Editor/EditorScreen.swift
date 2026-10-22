import SwiftUI
import SwiftData

/// Opens a notebook's document and hosts the editor. One per notebook across windows: a second gives way.
struct EditorScreen: View {
    let notebookID: UUID
    var initialPageID: UUID?
    let sceneID: String?
    /// Asked before closing; returning false leaves the editor open.
    var beforeClose: (() async -> Bool)?
    let onClose: () -> Void

    @Environment(LibraryStore.self) private var store
    @Environment(WritingActivity.self) private var activity
    @Environment(AppModel.self) private var app: AppModel?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.editorPane) private var pane
    @Environment(EditorWindow.self) private var window: EditorWindow?
    @State private var document: NotebookDocument?
    @State private var failure: String?
    @State private var isClosing = false
    @State private var unsavedReason: String?
    @State private var lock = NotebookLock.shared
    @State private var askedToUnlock = false
    /// The page on show when a sync set the document aside, which the newer version opens at.
    @State private var reopenAt: UUID?

    /// A locked notebook is covered until it is unlocked, and whenever the app isn't in front, so it never shows in the app switcher.
    private func isCovered(_ document: NotebookDocument) -> Bool {
        document.manifest.library.isLocked && (!lock.isUnlocked(notebookID) || scenePhase != .active)
    }

    var body: some View {
        ZStack {
            Color.desk.ignoresSafeArea()
            if let document {
                let covered = isCovered(document)
                EditorView(document: document, initialPageID: reopenAt ?? initialPageID, isCovered: covered, close: close)
                    .id(ObjectIdentifier(document))
                    .disabled(covered)
                    .accessibilityHidden(covered)
                if covered {
                    LockedNotebookView(title: document.title, closeTitle: pane == .secondary ? "Close" : "Back to Library", unlock: { unlock(document) }) {
                        if pane != .secondary { window?.closing = .library }
                        close()
                    }
                        .task(id: scenePhase) {
                            guard scenePhase == .active, !askedToUnlock, !lock.isUnlocked(notebookID) else { return }
                            askedToUnlock = true
                            unlock(document)
                        }
                }
            } else if let failure {
                EmptyShelf(title: String(localized: "This notebook couldn't be opened"), message: failure) {
                    Button("Back to Library", action: onClose).buttonStyle(.owlLuna(.primary))
                }
            } else {
                ProgressView().controlSize(.large)
            }
        }
        .task(id: notebookID) { await open() }
        .onChange(of: scenePhase) { _, phase in
            document?.recorder?.noteWindow(inBackground: phase == .background)
            guard phase == .background else { return }
            lock.lock(notebookID)
            askedToUnlock = false
        }
        .onDisappear { lock.lock(notebookID) }
        .onReceive(NotificationCenter.default.publisher(for: UIScene.didDisconnectNotification)) { note in
            guard (note.object as? UIScene)?.session.persistentIdentifier == sceneID else { return }
            closeWithWindow()
        }
        .onReceive(NotificationCenter.default.publisher(for: .owlLunaCloseEditor)) { note in
            guard (note.object as? UUID) == notebookID else { return }
            guard let document else { return onClose() }
            document.recorder?.shutdown()
            close()
        }
        .onReceive(NotificationCenter.default.publisher(for: .owlLunaReopenNotebook)) { note in
            guard (note.object as? UUID) == notebookID, let document, document.isSetAside, !isClosing else { return }
            let page = document.manifest.library.currentPage
            reopenAt = document.pages.indices.contains(page) ? document.pages[page].id : nil
            self.document = nil
            Task { await open() }
        }
        .notice("Your latest changes aren't saved yet", isPresented: Binding(isPresent: $unsavedReason),
                message: Text("OwlLuna couldn't write to this device: \(unsavedReason ?? ""). If you close now, it keeps trying in the background, but changes that haven't been saved are lost if the app quits first.")) {
            Button("Keep Editing", role: .cancel) {}
            Button("Close Anyway", role: .destructive) { closeWhileSaving() }
            Button("Try Again") { close() }
        }
    }

    private func unlock(_ document: NotebookDocument) {
        Task { await lock.unlock(notebookID, title: document.title) }
    }

    private func open() async {
        // One editor writes each notebook: a pane that would be a second gives way, and the window that has the notebook comes forward.
        if let window, window.isOpenElsewhere(notebookID) {
            // A pane the window has already turned from closes nothing.
            guard (pane == .secondary ? window.beside?.id : window.selected) == notebookID else { return }
            _ = window.goesToItsWindow(notebookID, page: initialPageID)
            if pane != .secondary { window.closing = .tab }
            return onClose()
        }
        do {
            let sync = app?.sync
            let opened = try await DocumentRegistry.shared.open(notebookID, root: store.root, scene: sceneID) { [weak store, weak activity, weak sync] document in
                let id = document.id
                document.onSaved = { manifest in store?.index(manifest) }
                document.onWritten = { sync?.sendSoon(id) }
                document.onInkSaved = { pages, date in activity?.record(notebook: id, pages: pages, at: date) }
                store?.reapplyChangesInFlight(to: document)
            }
            opened.noteOpened()
            document = opened
            // A tab's document stays open behind the bar; one that came with a tab moved beside is this pane's to hold from here.
            if pane == .secondary { window?.release(notebookID) } else { window?.keep(opened) }
        } catch {
            failure = error.localizedDescription
        }
    }

    /// Waits for imports, then saves. The editor only goes away once everything is on disk, or the user
    /// chooses to close while saving keeps failing.
    private func close() {
        guard let document, !isClosing else { return }
        isClosing = true
        Task {
            if let beforeClose, !(await beforeClose()) {
                isClosing = false
                return
            }
            await document.finishPendingWork()
            guard await document.flush() else {
                isClosing = false
                if pane != .secondary { window?.isLeaving = false }
                unsavedReason = document.saveFailureReason ?? String(localized: "the save didn't finish")
                return
            }
            await document.collectGarbage()
            store.index(document.manifest)
            DocumentRegistry.shared.unregister(notebookID, document: document)
            onClose()
            store.indexHandwriting(package: document.package, pages: document.pages)
        }
    }

    /// The window went away with the editor still open: no UI to ask with, so save, and keep retrying if that fails.
    private func closeWithWindow() {
        guard let document, !isClosing else { return }
        isClosing = true
        Task { await Self.putAway(document, store: store, because: .windowClosed) }
    }

    /// Saves and closes a document without an editor to ask with: a tab behind the bar, or a window that went away.
    /// One that can't be saved is kept, and retried, until it can.
    static func putAway(_ document: NotebookDocument, store: LibraryStore, because reason: RecordingStop? = nil) async {
        // One a sync set aside has nothing to save, and the files are the newer version's now.
        guard !document.isSetAside else { return }
        document.recorder?.shutdown(because: reason)
        if reason != nil, let notice = document.notices.last(where: { $0.kind == .recordingStopped }) {
            DocumentRegistry.shared.noteRecordingStopped(notice.message, in: document.id)
        }
        await document.finishPendingWork()
        if await document.flush() {
            await document.collectGarbage()
            store.index(document.manifest)
            store.indexHandwriting(package: document.package, pages: document.pages)
            DocumentRegistry.shared.unregister(document.id, document: document)
        } else {
            keepUntilSaved(document, store: store)
        }
    }

    private func closeWhileSaving() {
        guard let document else { return onClose() }
        Self.keepUntilSaved(document, store: store)
        onClose()
    }

    /// Keeps trying to save a document no editor holds, and indexes it once it is saved.
    private static func keepUntilSaved(_ document: NotebookDocument, store: LibraryStore) {
        DocumentRegistry.shared.keepUntilSaved(document) { [weak store] in
            store?.index(document.manifest)
            store?.indexHandwriting(package: document.package, pages: document.pages)
            Task { await document.collectGarbage() }
        }
    }
}
