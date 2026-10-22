import XCTest
import PencilKit
@testable import OwlLuna

/// Presenting changes nothing on the pages: undo and redo wait until it ends.
@MainActor
final class PresentingTests: XCTestCase {
    private func pause(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    func testNothingIsUndoneOrRedoneWhilePresentingAndBothWorkAfterwards() async throws {
        let root = temporaryRoot(self)
        let manifest = NotebookManifest(title: "Lecture", defaults: PageDefaults(template: .blank, paperColor: .white, pageSize: .letter),
                                        pages: [.template(.blank, color: .white, size: .letter)])
        try await NotebookPackage(root: root, id: manifest.id).create(manifest)
        let document = try await NotebookDocument.open(manifest.id, root: root)
        let session = EditorSession(document: document)
        let controller = PageStackController(session: session)
        session.canvas = controller
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 834, height: 1194)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        addTeardownBlock { @MainActor in window.isHidden = true }
        controller.view.layoutIfNeeded()
        for _ in 0..<100 where controller.canvas(forPage: 0)?.isLoaded != true { await pause(0.05) }
        let page = document.pages[0].id
        let canvas = try XCTUnwrap(controller.canvas(forPage: 0))
        let anchor = try XCTUnwrap(controller.view.subviews.compactMap { $0 as? ResponderAnchor }.first)
        func strokes() -> Int { document.loadedInk(page)?.strokes.count ?? 0 }

        let first = dot(at: CGPoint(x: 100, y: 100)), second = dot(at: CGPoint(x: 160, y: 100))
        document.canvasDidChangeInk(page, to: PKDrawing(strokes: [first]))
        await pause(0.1)
        document.canvasDidChangeInk(page, to: PKDrawing(strokes: [first, second]))
        await pause(0.1)
        anchor.undoManager?.undo()
        XCTAssertEqual(strokes(), 1)
        await pause(0.1)

        session.enter(.presenting)
        XCTAssertFalse(session.canUndo, "the bar's Undo, and ⌘Z with it, is off")
        XCTAssertFalse(session.canRedo)
        for manager in [anchor.undoManager, canvas.undoManager] {
            XCTAssertEqual(manager?.canUndo, false, "⌘Z, the Edit menu and the three-finger swipe find nothing to undo")
            XCTAssertEqual(manager?.canRedo, false)
            manager?.undo()
        }
        XCTAssertEqual(strokes(), 1, "the page stays as it was")
        anchor.undoManager?.redo()
        canvas.undoManager?.redo()
        XCTAssertEqual(strokes(), 1, "redo changes nothing either")
        XCTAssertTrue(document.undoManager.canUndo && document.undoManager.canRedo, "the steps wait for afterwards")

        session.enter(.writing)
        XCTAssertTrue(session.canUndo)
        XCTAssertTrue(session.canRedo)
        anchor.undoManager?.redo()
        XCTAssertEqual(strokes(), 2)
        await pause(0.1)
        canvas.undoManager?.undo()
        canvas.undoManager?.undo()
        XCTAssertEqual(strokes(), 0, "undo works again once presenting ends")
    }
}
