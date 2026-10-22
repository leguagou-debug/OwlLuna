import SwiftUI

/// Holds first responder while the library is in front, so ⌘F reaches the search field and ⌘Z the library's undo.
struct SearchActivator: UIViewRepresentable {
    let isSearching: Bool
    let isCovered: Bool
    let onFind: () -> Void
    @Environment(\.undoManager) private var undoManager

    func makeUIView(context: Context) -> ActivatorView { ActivatorView() }

    /// Acts only on changes, so ordinary library updates never move first responder.
    func updateUIView(_ view: ActivatorView, context: Context) {
        view.onFind = onFind
        view.libraryUndoManager = undoManager
        if isCovered != view.wasCovered {
            view.wasCovered = isCovered
            view.isCovered = isCovered
            DispatchQueue.main.async { if isCovered { view.resignFirstResponder() } else { view.reclaimFirstResponder() } }
        }
        guard isSearching != view.wasSearching else { return }
        view.wasSearching = isSearching
        if !isSearching { DispatchQueue.main.async { view.reclaimFirstResponder() } }
    }

    final class ActivatorView: UIView {
        var onFind: (() -> Void)?
        var wasSearching = false
        var wasCovered = false
        var isCovered = false
        weak var libraryUndoManager: UndoManager?

        override var canBecomeFirstResponder: Bool { !isCovered }

        override var keyCommands: [UIKeyCommand]? {
            guard !isCovered else { return [] }
            let commands = [
                UIKeyCommand(title: String(localized: "Search Library"), action: #selector(findRequested), input: "f", modifierFlags: .command),
                UIKeyCommand(title: String(localized: "Undo"), action: #selector(undoLibraryChange), input: "z", modifierFlags: .command),
                UIKeyCommand(title: String(localized: "Redo"), action: #selector(redoLibraryChange), input: "z", modifierFlags: [.command, .shift]),
            ]
            for command in commands { command.wantsPriorityOverSystemBehavior = true }
            return commands
        }

        @objc private func findRequested() { if !isCovered { onFind?() } }

        @objc private func undoLibraryChange() { libraryUndoManager?.undo() }

        @objc private func redoLibraryChange() { libraryUndoManager?.redo() }

        override func find(_ sender: Any?) { findRequested() }

        override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
            switch action {
            case #selector(undoLibraryChange): !isCovered && libraryUndoManager?.canUndo == true
            case #selector(redoLibraryChange): !isCovered && libraryUndoManager?.canRedo == true
            default: (action == #selector(find(_:)) && !isCovered) || super.canPerformAction(action, withSender: sender)
            }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            NotificationCenter.default.removeObserver(self, name: UITextField.textDidEndEditingNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(textDidEndEditing(_:)), name: UITextField.textDidEndEditingNotification, object: nil)
            DispatchQueue.main.async { self.reclaimFirstResponder() }
        }

        @objc private func textDidEndEditing(_ note: Notification) {
            guard (note.object as? UIView)?.window === window else { return }
            DispatchQueue.main.async { self.reclaimFirstResponder() }
        }

        /// Takes ⌘F back once a field stops editing, unless the user has gone straight into another one.
        func reclaimFirstResponder() {
            guard !isCovered, let window else { return }
            if let field = UIResponder.current as? UIView, field is UITextInput, field.window === window { return }
            becomeFirstResponder()
        }
    }
}

private extension UIResponder {
    private static weak var found: UIResponder?

    /// Whatever holds first responder in the app right now.
    static var current: UIResponder? {
        found = nil
        UIApplication.shared.sendAction(#selector(owlLunaCaptureFirstResponder), to: nil, from: nil, for: nil)
        return found
    }

    @objc private func owlLunaCaptureFirstResponder() { UIResponder.found = self }
}
