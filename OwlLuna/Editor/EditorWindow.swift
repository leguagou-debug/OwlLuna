import SwiftUI

/// Where a link to another notebook was followed from, so the notebook it opened can offer the way back.
struct NotebookReturn: Equatable {
    let origin: UUID
    let page: UUID
    let title: String
    let destination: UUID
}

/// What the first pane's editor is closing for: to go back to the library, or only to close its tab.
enum EditorClosing { case library, tab }

/// What the editors of one window share with the library behind them.
@MainActor
@Observable
final class EditorWindow {
    static let tabLimit = 12

    var linkReturn: NotebookReturn?
    /// The notebook open beside the first one, in the same window.
    var beside: OpenNotebook?
    /// The notebook of the pane last touched. Keyboard shortcuts go to it.
    var active: UUID?
    /// Where the first pane ends, as a fraction of the window.
    var split: CGFloat = 0.5
    /// The notebooks open in tabs, in the order of the tab bar. A notebook on its own is one tab, and shows no bar.
    private(set) var tabs: [OpenNotebook] = []
    /// The tab on show in the first pane. If the first pane was the one being worked in, it still is.
    private(set) var selected: UUID? {
        didSet { if let active, active != beside?.id { self.active = selected } }
    }
    /// The editor on show has put its bars away (focus, presenting, find): the tab bar goes with them.
    var hidesChrome = false
    var pickingTab = false
    /// Set while everything is being saved on the way back to the library: tabs can't be changed meanwhile.
    var isLeaving = false
    @ObservationIgnored var closing = EditorClosing.library
    /// The documents of the tabs looked at since the editor opened. They stay open while another tab is on show, so
    /// a tab comes back with its undo history; all are saved and closed on the way back to the library.
    @ObservationIgnored private(set) var documents: [UUID: NotebookDocument] = [:]
    /// Shows another notebook, at a page if one is given: in a tab when there are tabs, and otherwise in place of
    /// the editor that is open, once that has saved and closed.
    @ObservationIgnored var openNotebook: ((UUID, UUID?) -> Void)?
    /// The window's scene, as the registry knows it. Until it is known, no notebook counts as another window's.
    @ObservationIgnored var scene: String?

    /// Shows a notebook in the first pane: in its own tab if it has one, in a new tab otherwise.
    func show(_ notebook: OpenNotebook) {
        guard !isOpenElsewhere(notebook.id) else { return }
        if notebook.id != selected { leaveTab() }
        if let index = tabs.firstIndex(where: { $0.id == notebook.id }) {
            tabs[index].pageID = notebook.pageID
        } else {
            tabs.append(notebook)
            // Past the limit, the first tab that isn't open behind the bar makes room.
            if tabs.count > Self.tabLimit, let waiting = tabs.firstIndex(where: { $0.id != notebook.id && documents[$0.id] == nil }) {
                tabs.remove(at: waiting)
            }
        }
        selected = notebook.id
    }

    func select(_ id: UUID) {
        guard id != selected, tabs.contains(where: { $0.id == id }), !isOpenElsewhere(id) else { return }
        leaveTab()
        selected = id
    }

    /// One tab along the bar, coming round at the ends.
    func step(_ delta: Int) {
        letGoOfTabsOpenElsewhere()
        guard tabs.count > 1, let index = tabs.firstIndex(where: { $0.id == selected }) else { return }
        select(tabs[(index + delta + tabs.count) % tabs.count].id)
    }

    /// A tab that is left comes back at the page it was left on, not the page it was first opened at.
    private func leaveTab() {
        if let index = tabs.firstIndex(where: { $0.id == selected }) { tabs[index].pageID = nil }
    }

    /// Only a tab's document is kept: one that finishes opening after its tab has gone is its next editor's to hold.
    func keep(_ document: NotebookDocument) {
        guard tabs.contains(where: { $0.id == document.id }) else { return }
        documents[document.id] = document
    }

    /// Lets go of a document its own editor has closed, or hands it over to be closed.
    @discardableResult
    func release(_ id: UUID) -> NotebookDocument? {
        documents.removeValue(forKey: id)
    }

    /// Takes a tab off the bar. If it was the tab on show, the one that takes its place is shown.
    func removeTab(_ id: UUID) {
        if id == selected { letGoOfTabsOpenElsewhere() }
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: index)
        if selected == id { selected = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id }
    }

    /// Moves a tab to where another stands on the bar, which makes room for it. The tab on show stays on show.
    @discardableResult
    func moveTab(_ id: UUID, to index: Int) -> Bool {
        guard let from = tabs.firstIndex(where: { $0.id == id }), from != index, tabs.indices.contains(index) else { return false }
        tabs.insert(tabs.remove(at: from), at: index)
        return true
    }

    /// Going back to the library: several tabs wait to be shown again, a notebook on its own doesn't.
    /// Returns the documents still open, to be saved and closed.
    func park() -> [NotebookDocument] {
        let open = Array(documents.values)
        documents = [:]
        if tabs.count < 2 {
            tabs = []
            selected = nil
        }
        for index in tabs.indices { tabs[index].pageID = nil }
        hidesChrome = false
        pickingTab = false
        isLeaving = false
        closing = .library
        return open
    }

    /// The tabs this window had when the app last ran.
    func restore(_ notebooks: [OpenNotebook]) {
        guard tabs.isEmpty, notebooks.count > 1 else { return }
        tabs = Array(notebooks.prefix(Self.tabLimit))
    }

    /// Lets go of the tabs of notebooks that have left the library. The tab on show stays: its editor says what happened.
    func keepTabs(where isPresent: (UUID) -> Bool) {
        let kept = tabs.filter { $0.id == selected || isPresent($0.id) }
        if kept.count != tabs.count { tabs = kept }
    }

    /// Whether another window has the notebook open. One editor writes each notebook, so it is never shown here.
    func isOpenElsewhere(_ id: UUID) -> Bool {
        scene.map { DocumentRegistry.shared.otherWindow(with: id, than: $0) != nil } ?? false
    }

    /// Lets go of the tabs of notebooks another window has opened since they were on show here: the notebook is that window's now.
    func letGoOfTabsOpenElsewhere() {
        keepTabs { !isOpenElsewhere($0) }
    }

    /// A notebook another window has open is shown there, at the page if one is given: that window comes forward, and this one lets go of the tab that waited for it.
    func goesToItsWindow(_ id: UUID, page: UUID? = nil) -> Bool {
        guard let scene, DocumentRegistry.shared.activateExistingEditor(for: id, page: page, from: scene) else { return false }
        if linkReturn?.destination == id { linkReturn = nil }
        letGoOfTabsOpenElsewhere()
        return true
    }

    /// A touch on a notebook's pages makes its pane the one being worked in, when the window shows two.
    func touched(_ id: UUID) {
        if beside != nil, active != id { active = id }
    }

    /// Whether a notebook's pane is the one being worked in: a double-tap or squeeze of the Pencil reaches both panes of a window.
    func isActive(_ id: UUID) -> Bool {
        guard let beside else { return true }
        return active.map { $0 == id } ?? (id != beside.id)
    }
}

/// Whether an editor has the window to itself or shares it.
enum EditorPaneRole { case single, primary, secondary }

extension EnvironmentValues {
    @Entry var editorPane = EditorPaneRole.single
}
