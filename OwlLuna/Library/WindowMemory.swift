import SwiftUI

/// What each window has open, kept the moment it changes. iPadOS saves a window's own state only on the way to
/// the background, so an app stopped straight after would otherwise reopen with what was open before.
enum WindowMemory {
    private static let key = "owlluna.windowNotebooks"
    private static let restoringKey = "owlluna.windowsRestoring"
    /// The SceneStorage key of the notebook a window has open: the scene's own note of it.
    static let openNotebookKey = "owlluna.openNotebook"

    private static var all: [String: [String]] {
        get { UserDefaults.standard.dictionary(forKey: key) as? [String: [String]] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    private static var restoring: [String] {
        get { UserDefaults.standard.stringArray(forKey: restoringKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: restoringKey) }
    }

    /// The notebook on show, the one beside it, then the tabs in their order when there are several.
    static func remember(_ notebook: UUID?, beside: UUID?, tabs: [UUID] = [], in scene: String) {
        all[scene] = [notebook?.uuidString ?? "", notebook == nil ? "" : beside?.uuidString ?? ""] + tabs.map(\.uuidString)
    }

    /// Nil when the window has nothing kept here yet; a notebook of nil when it had none open.
    static func remembered(in scene: String) -> (notebook: UUID?, beside: UUID?, tabs: [UUID])? {
        all[scene].map { kept in
            (UUID(uuidString: kept.first ?? ""), UUID(uuidString: kept.dropFirst().first ?? ""), kept.dropFirst(2).compactMap(UUID.init(uuidString:)))
        }
    }

    /// Whether a window would reopen a notebook: what is kept here, or `fallback`, the scene's own note of it, when nothing is kept yet.
    static func reopens(in scene: String, fallback: String = "") -> Bool {
        if let kept = remembered(in: scene) { return kept.notebook != nil }
        return UUID(uuidString: fallback) != nil
    }

    /// Marks a window while it reopens what it had: a mark still there at the next launch means the reopening crashed.
    static func setRestoring(_ isRestoring: Bool, in scene: String) {
        restoring = restoring.filter { $0 != scene } + (isRestoring ? [scene] : [])
    }

    /// True once for a window whose last reopening crashed, which lets go of what it had open.
    static func restoreCrashed(in scene: String) -> Bool {
        guard restoring.contains(scene) else { return false }
        setRestoring(false, in: scene)
        remember(nil, beside: nil, in: scene)
        return true
    }

    /// Lets go of windows iPadOS no longer keeps.
    static func keep(only scenes: Set<String>) {
        let kept = all.filter { scenes.contains($0.key) }
        if kept.count != all.count { all = kept }
        let marked = restoring.filter(scenes.contains)
        if marked.count != restoring.count { restoring = marked }
    }
}

/// Reports the window scene's persistent identifier, which keys the one-editor-per-notebook rule.
struct SceneReader: UIViewRepresentable {
    let onChange: (String?) -> Void

    func makeUIView(context: Context) -> SceneReaderView {
        let view = SceneReaderView()
        view.onChange = onChange
        return view
    }

    func updateUIView(_ view: SceneReaderView, context: Context) {}

    final class SceneReaderView: UIView {
        var onChange: ((String?) -> Void)?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            onChange?(window?.windowScene?.session.persistentIdentifier)
        }
    }
}
