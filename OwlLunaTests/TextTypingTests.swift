import XCTest
import UIKit
@testable import OwlLuna

/// Typing in a text box on the page: ticks through edits and undo, pasted line breaks, and ticking by hand.
@MainActor
final class TextTypingTests: XCTestCase {
    private let paper = PageDefaults(template: .blank, paperColor: .white, pageSize: .letter)

    private func item(_ box: TextBox, width: CGFloat = 260, at centre: CGPoint = CGPoint(x: 300, y: 300)) -> PageItem {
        PageItem(content: .text(box), center: centre, size: CGSize(width: width, height: box.height(width: width)))
    }

    private func checklist(_ string: String, ticked: Set<Int> = []) -> TextBox {
        var box = TextBox(string: string, fontSize: 24)
        box.list = .check
        box.checked = ticked
        return box
    }

    private func makeDocument(items: [PageItem]) async throws -> NotebookDocument {
        let root = temporaryRoot(self)
        var page = paper.newPage()
        page.items = items
        let manifest = NotebookManifest(title: "Lab", defaults: paper, pages: [page])
        try await NotebookPackage(root: root, id: manifest.id).create(manifest)
        return try await NotebookDocument.open(manifest.id, root: root)
    }

    private func pause(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    /// The page stack showing a document in a window of its own, once its first page has loaded.
    private func show(_ document: NotebookDocument) async throws -> (PageStackController, UIWindow) {
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
        return (controller, window)
    }

    /// Starts typing in a box, as a tap on its words does, and hands back the text view put over it.
    private func startTyping(_ placed: PageItem, in document: NotebookDocument, controller: PageStackController, window: UIWindow) throws -> UITextView {
        controller.select(ItemSelection(pageID: document.pages[0].id, itemID: placed.id))
        controller.editText()
        return try XCTUnwrap(window.descendants(UITextView.self).first { $0.accessibilityIdentifier == "page.text.editor" })
    }

    /// An edit made the way the keyboard, a cut or a paste makes one: asked of the delegate, made unless refused, then reported.
    private func edit(_ textView: UITextView, _ range: NSRange, _ text: String) {
        guard textView.delegate?.textView?(textView, shouldChangeTextIn: range, replacementText: text) ?? true else { return }
        textView.textStorage.replaceCharacters(in: range, with: text)
        textView.delegate?.textViewDidChange?(textView)
    }

    /// One edit to a checklist being typed in, and the box as Edit Text then saves it.
    private func saved(_ string: String, ticked: Set<Int>, after range: NSRange, _ text: String) async throws -> TextBox {
        let placed = item(checklist(string, ticked: ticked))
        let document = try await makeDocument(items: [placed])
        let (controller, window) = try await show(document)
        let textView = try startTyping(placed, in: document, controller: controller, window: window)
        edit(textView, range, text)
        controller.select(nil)
        return try XCTUnwrap(document.pages[0].items.first?.text)
    }

    private func tickActions(of id: UUID, in window: UIWindow) throws -> [UIAccessibilityCustomAction] {
        let view = try XCTUnwrap(window.descendants(PageItemView.self).first { $0.item.id == id })
        return try XCTUnwrap(view.accessibilityCustomActions)
    }

    // MARK: Ticks through edits

    func testDeletingAWholeLineKeepsTheOtherTicksOnTheirLines() async throws {
        let gone = try await saved("Oats\nFlour\nFish", ticked: [1], after: NSRange(location: 5, length: 6), "")
        XCTAssertEqual(gone.string, "Oats\nFish")
        XCTAssertEqual(gone.checked, [], "Flour's tick goes with Flour and doesn't land on Fish")

        let below = try await saved("Oats\nFlour\nFish", ticked: [2], after: NSRange(location: 5, length: 6), "")
        XCTAssertEqual(below.string, "Oats\nFish")
        XCTAssertEqual(below.checked, [1], "Fish keeps its tick")

        let over = try await saved("Oats\nFlour\nEggs", ticked: [0, 2], after: NSRange(location: 0, length: 15), "O")
        XCTAssertEqual(over.string, "O")
        XCTAssertEqual(over.checked, [], "typing over everything starts a box with nothing ticked")
    }

    func testALinePastedAboveATickedOneLeavesTheTickWhereItWas() async throws {
        let pasted = try await saved("Call Anna\nCall Bob\nEmail Cat", ticked: [1], after: NSRange(location: 10, length: 0), "Call Dan\n")
        XCTAssertEqual(pasted.lines, ["Call Anna", "Call Dan", "Call Bob", "Email Cat"])
        XCTAssertEqual(pasted.checked, [2], "Call Bob is still the one ticked")
    }

    func testPastedLineBreaksOfEveryKindComeInAsReturns() async throws {
        let placed = item(checklist("Oats\nEggs", ticked: [1]))
        let document = try await makeDocument(items: [placed])
        let (controller, window) = try await show(document)
        let textView = try startTyping(placed, in: document, controller: controller, window: window)

        edit(textView, NSRange(location: 5, length: 0), "Milk\r\n\r\nFlour\r\n")
        XCTAssertEqual(textView.text, "Oats\nMilk\n\nFlour\nEggs")
        edit(textView, NSRange(location: 0, length: 0), "Rye\rSpelt\u{2029}")
        XCTAssertEqual(textView.text, "Rye\nSpelt\nOats\nMilk\n\nFlour\nEggs")

        controller.select(nil)
        let box = try XCTUnwrap(document.pages[0].items.first?.text)
        XCTAssertEqual(box.string, "Rye\nSpelt\nOats\nMilk\n\nFlour\nEggs")
        XCTAssertEqual(box.numbers, [1, 2, 3, 4, nil, 5, 6], "a blank line pasted from Windows text isn't an item")
        XCTAssertEqual(box.checked, [6], "Eggs keeps its tick")
    }

    func testUndoingAJoinBringsTheTickBack() async throws {
        let placed = item(checklist("Oats\nFlour", ticked: [1]))
        let document = try await makeDocument(items: [placed])
        let (controller, window) = try await show(document)
        let textView = try startTyping(placed, in: document, controller: controller, window: window)

        edit(textView, NSRange(location: 4, length: 1), "")
        XCTAssertEqual(textView.text, "OatsFlour")
        // The text view's own undo puts the return back while its undo manager is undoing.
        let undo = try XCTUnwrap(textView.undoManager)
        undo.registerUndo(withTarget: textView) { view in
            view.textStorage.replaceCharacters(in: NSRange(location: 4, length: 0), with: "\n")
            view.delegate?.textViewDidChange?(view)
        }
        undo.undo()
        XCTAssertEqual(textView.text, "Oats\nFlour")

        controller.select(nil)
        XCTAssertEqual(document.pages[0].items.first?.text?.checked, [1], "Flour's tick comes back with its line")
    }

    // MARK: Ticking

    func testABoxCanBeTickedWhileItIsTypedInAndEditTextSavesTheTick() async throws {
        let placed = item(checklist("Oats\nFlour\nEggs"))
        let document = try await makeDocument(items: [placed])
        let (controller, window) = try await show(document)
        func ticks() -> Set<Int> { document.pages[0].items.first?.text?.checked ?? [] }
        let textView = try startTyping(placed, in: document, controller: controller, window: window)

        func tickNames() -> [String] {
            (textView.accessibilityCustomActions ?? []).map(\.name).filter { $0.hasPrefix("Tick ") || $0.hasPrefix("Untick ") }
        }
        XCTAssertEqual(tickNames(), ["Tick Oats", "Tick Flour", "Tick Eggs"])
        let flour = try XCTUnwrap(textView.accessibilityCustomActions?.first { $0.name == "Tick Flour" })
        XCTAssertTrue(flour.actionHandler?(flour) ?? false)
        XCTAssertEqual(tickNames(), ["Tick Oats", "Untick Flour", "Tick Eggs"], "the box under the words is ticked as typing goes on")
        XCTAssertEqual(ticks(), [], "the page keeps the box as it was until typing ends")

        edit(textView, NSRange(location: 15, length: 0), "\nMilk")
        controller.select(nil)
        XCTAssertEqual(document.pages[0].items.first?.text?.string, "Oats\nFlour\nEggs\nMilk")
        XCTAssertEqual(ticks(), [1], "the tick is saved with what was typed")
        XCTAssertEqual(document.undoManager.undoActionName, "Edit Text")
        document.undoManager.undo()
        XCTAssertEqual(ticks(), [])
    }

    func testATickThatCantBeMadeNowSaysSo() async throws {
        let placed = item(checklist("Oats\nFlour"))
        let root = temporaryRoot(self)
        var page = paper.newPage()
        page.items = [placed]
        var manifest = NotebookManifest(title: "Future", defaults: paper, pages: [page])
        manifest.schemaVersion = 99
        let package = NotebookPackage(root: root, id: manifest.id)
        try FileManager.default.createDirectory(at: package.url, withIntermediateDirectories: true)
        try ManifestCodec.encode(manifest).write(to: package.manifestURL)
        let future = try await NotebookDocument.open(manifest.id, root: root)
        XCTAssertTrue(future.isReadOnly)
        let (_, futureWindow) = try await show(future)
        let refused = try tickActions(of: placed.id, in: futureWindow)
        XCTAssertFalse(refused[0].actionHandler?(refused[0]) ?? true, "a notebook from a newer version can't be ticked, and VoiceOver hears so")
        XCTAssertEqual(future.pages[0].items.first?.text?.checked, [])

        let document = try await makeDocument(items: [placed])
        let (controller, window) = try await show(document)
        controller.setFinding(true)
        let locked = try tickActions(of: placed.id, in: window)
        XCTAssertFalse(locked[0].actionHandler?(locked[0]) ?? true, "nor can anything be ticked while the notebook is searched")
        XCTAssertEqual(document.pages[0].items.first?.text?.checked, [])
        controller.setFinding(false)
        let open = try tickActions(of: placed.id, in: window)
        XCTAssertTrue(open[0].actionHandler?(open[0]) ?? false)
        XCTAssertEqual(document.pages[0].items.first?.text?.checked, [0])
    }

    func testABoxTickedOrRetypedByHandIsNoLongerAPrintedAgenda() async throws {
        var ticked = item(checklist("9:00  Standup\n13:00  Lunch with Sam"))
        ticked.raw["agenda"] = .bool(true)
        var retyped = item(checklist("15:00  Dentist"), at: CGPoint(x: 300, y: 600))
        retyped.raw["agenda"] = .bool(true)
        let document = try await makeDocument(items: [ticked, retyped])
        let (controller, window) = try await show(document)
        func printed(_ id: UUID) -> Bool { document.pages[0].items.first { $0.id == id }?.isPrintedAgenda ?? false }
        var redated = document.pages[0]
        DailyJournal.print([], on: &redated)
        XCTAssertTrue(redated.items.isEmpty, "a page of nothing but printed agenda is cleared when it is re-dated")

        let actions = try tickActions(of: ticked.id, in: window)
        XCTAssertTrue(actions[0].actionHandler?(actions[0]) ?? false)
        XCTAssertFalse(printed(ticked.id), "a tick makes the box the user's own")
        redated = document.pages[0]
        DailyJournal.print([], on: &redated)
        XCTAssertEqual(redated.items.map(\.id), [ticked.id, retyped.id], "so re-dating the page keeps the ticked list")

        _ = try startTyping(retyped, in: document, controller: controller, window: window)
        controller.select(nil)
        XCTAssertTrue(printed(retyped.id), "typing that changes nothing leaves the agenda as printed")
        let textView = try startTyping(retyped, in: document, controller: controller, window: window)
        edit(textView, NSRange(location: 14, length: 0), " (moved)")
        controller.select(nil)
        XCTAssertEqual(document.pages[0].items.first { $0.id == retyped.id }?.text?.string, "15:00  Dentist (moved)")
        XCTAssertFalse(printed(retyped.id), "words changed by hand make it the user's own too")
    }

    func testAPrintedAgendaTypedOverByABuildThatKeepsItsMarkIsTheUsersOwn() throws {
        let events = [AgendaEvent(title: "Lab group", start: Date(timeIntervalSinceReferenceDate: 0))]
        var printed = try XCTUnwrap(Agenda.item(for: events, on: paper.newPage()))
        XCTAssertTrue(printed.isPrintedAgenda)
        var box = try XCTUnwrap(printed.text)
        box.string += "\nBring lab coat"
        printed.content = .text(box)
        XCTAssertFalse(printed.isPrintedAgenda, "the mark holds the printed words, so words typed over them count as the user's")
        printed.raw["agenda"] = .bool(true)
        XCTAssertTrue(printed.isPrintedAgenda, "a mark from before still counts")
    }

    func testAStyleThatChangesNothingKeepsTheAgendaAndADuplicateKeepsWhatANewerBuildStored() async throws {
        var placed = item(checklist("9:00  Standup"))
        placed.raw["agenda"] = .bool(true)
        placed.raw["face"] = .string("calligraphy")
        let document = try await makeDocument(items: [placed])
        let session = EditorSession(document: document)
        session.selection = ItemSelection(pageID: document.pages[0].id, itemID: placed.id)
        let before = document.pages[0].items
        session.updateText { $0.tint = .ink }
        XCTAssertEqual(document.pages[0].items, before, "tapping the colour already chosen changes nothing, the agenda mark included")

        session.duplicateSelection()
        let copy = try XCTUnwrap(document.pages[0].items.last)
        XCTAssertNotEqual(copy.id, placed.id)
        XCTAssertEqual(copy.json.objectValue?["face"], .string("calligraphy"), "a copy keeps the face a newer build chose")
        XCTAssertFalse(copy.isPrintedAgenda, "a copy is placed by hand")
        session.selection = ItemSelection(pageID: document.pages[0].id, itemID: placed.id)
        session.updateText { $0.tint = .cobalt }
        XCTAssertFalse(document.pages[0].items[0].isPrintedAgenda, "a real change makes the box the user's own")
    }

    func testWhileABoxIsTypedInOnlyItsMarkerColumnTicks() throws {
        let box = checklist("Oats\nFlour")
        let style = try XCTUnwrap(box.editingText(scale: 1, onDark: false).attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        let flour = try XCTUnwrap(box.checkboxes(width: 260).first { $0.line == 1 }?.rect)
        let words = CGPoint(x: style.firstLineHeadIndent + 3, y: flour.midY)
        XCTAssertEqual(box.checkbox(at: words, width: 260), 1, "on the page a tap just into the words still ticks")
        XCTAssertNil(box.checkbox(at: words, width: 260, reach: 0), "while typing it only places the caret")
        XCTAssertEqual(box.checkbox(at: CGPoint(x: flour.midX, y: flour.midY), width: 260, reach: 0), 1)
    }

    // MARK: Undo

    func testWhatIsTypedInANewBoxIsNeverUndoneFromTheBarAndAfterwardsComesAndGoesWithTheBox() async throws {
        let document = try await makeDocument(items: [])
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
        func words() -> [String] { document.pages[0].items.compactMap { $0.text?.string } }

        session.addText()
        let textView = try XCTUnwrap(window.descendants(UITextView.self).first { $0.accessibilityIdentifier == "page.text.editor" })
        let box = try XCTUnwrap(session.selection)
        edit(textView, NSRange(location: 0, length: 0), "Molar mass")
        session.refreshUndoState()
        XCTAssertEqual(document.undoManager.undoActionName, "Add Text Box")
        XCTAssertTrue(session.canUndo)
        XCTAssertFalse(session.canUndoFromBar, "the bar's Undo would take the box away with its words, so it stands aside")
        XCTAssertNotNil(textView.undoManager)
        XCTAssertFalse(textView.undoManager === document.undoManager || textView.undoManager === controller.canvas(forPage: 0)?.undoManager,
                       "⌘Z and the three-finger swipe undo the typing, never the page")
        await pause(0.1)

        session.updateText { $0.isBold = true }
        session.refreshUndoState()
        XCTAssertTrue(session.canUndoFromBar, "a change of style while typing is the bar's to undo")
        document.undoManager.undo()
        session.refreshUndoState()
        XCTAssertTrue(session.isEditingText)
        XCTAssertEqual(textView.text, "Molar mass", "undoing the style leaves the words")
        XCTAssertFalse(session.canUndoFromBar)
        XCTAssertTrue(session.canRedoFromBar, "and putting it back is too")

        textView.delegate?.textViewDidEndEditing?(textView)
        XCTAssertEqual(words(), ["Molar mass"])
        XCTAssertEqual(session.selection, box, "the box stays picked up")
        XCTAssertEqual(document.undoManager.undoActionName, "Add Text Box", "a new box and what was first typed in it are one step")
        session.refreshUndoState()
        XCTAssertTrue(session.canUndoFromBar)
        await pause(0.1)
        document.undoManager.undo()
        XCTAssertEqual(words(), [], "one undo takes the box away")
        document.undoManager.redo()
        XCTAssertEqual(words(), ["Molar mass"], "redo brings it back with its words")

        session.addText()
        let empty = try XCTUnwrap(window.descendants(UITextView.self).first { $0.accessibilityIdentifier == "page.text.editor" })
        empty.delegate?.textViewDidEndEditing?(empty)
        XCTAssertEqual(words(), ["Molar mass"], "a box left empty isn't kept")
        await pause(0.1)
        document.undoManager.undo()
        XCTAssertEqual(words(), [], "nor is its step: the next undo takes the first box away")
    }

    // MARK: Drawing

    func testTheMarkersOfABoxTypedInFarZoomedInHaveNoMorePixelsThanAScreenful() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 834, height: 1194)
        window.isHidden = false
        addTeardownBlock { @MainActor in window.isHidden = true }
        let screen = window.traitCollection.displayScale
        let box = checklist((1...20).map { "Item \($0)" }.joined(separator: "\n"))

        let markers = TextMarkersView()
        window.addSubview(markers)
        markers.bounds = CGRect(x: 0, y: 0, width: 1941, height: 2627)
        markers.show(box, onDark: false, scale: 6.47)
        let deep = markers.contentScaleFactor
        XCTAssertLessThan(deep, screen, "a box five times enlarged isn't backed at the screen's scale")
        XCTAssertLessThanOrEqual(1941 * 2627 * deep * deep, 2400 * 2400 * 1.001, "its bitmap is no bigger than an item's art may be")

        markers.bounds = CGRect(x: 0, y: 0, width: 300, height: 406)
        markers.show(box, onDark: false, scale: 1)
        XCTAssertEqual(markers.contentScaleFactor, screen, "a box that fits on the screen is drawn at the screen's scale")
    }
}

private extension UIView {
    func descendants<View: UIView>(_ type: View.Type) -> [View] {
        subviews.flatMap { ($0 as? View).map { [$0] } ?? [] + $0.descendants(type) }
    }
}
