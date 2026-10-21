# Changelog

All notable changes to OwlLuna are listed here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html). Each TestFlight build has its own section, such as 1.0.0-build.3 for build 3 of 1.0; the build that goes to the App Store also gets a section with the version alone.

## [Unreleased]

### Added

- Text boxes can use a serif, monospaced or Fraunces typeface, with italic and underline.
- A text box can be a bulleted, numbered or checklist list. Tick a checklist line on the page.
- A text box can be highlighted in any of the highlighter's four colours.
- Crop a picture on the page: choose Crop, then drag an edge or a corner. Reset Crop brings the whole picture back, and exports keep only the part you kept.
- Squeeze or stretch a picture on the page from the grip on any of its sides. The corner handle and a pinch still keep its proportions, and a picture settles back on its own shape as you near it.
- Shapes in the tool tray: tie it on from Customise Tools, then pick a line, arrow, circle, rectangle or triangle on the strip over the tray and drag it out on the page in the pen's ink. The strip has Undo too, and Customise Tools says how draw and hold straightens a shape you draw by hand.
- Draw and hold makes an arrow of a line with a short hook at its end, or with a barb either side of its tip.
- Settings › Appearance: follow the iPad's Light or Dark, or always use one of them, in every window.
- Settings › Input › Left-Handed moves the page ribbon, the zoom window's buttons and the panels beside the page to the left.
- Settings › Recently Deleted: empty it after 7, 30 or 90 days. Each iPad keeps to its own length, and sync leaves a notebook on an iPad that keeps it longer.
- Settings › Pen Tray puts the tray back to the pens it started with.
- Settings › Recordings sets the language transcripts use. Each recording can still pick another.
- A list view for the library. Switch between Shelf and List in the library's bar. Each row shows the cover, title, pages and last change, with the folder and tags beside it where there's room. Tabs over the list sort it, and the arrow beside them turns the order round.
- The sort menu can turn the order round.
- Select several notebooks, or Select All, then favourite, tag, move, lock, export as PDFs or delete them together.
- Drag a notebook from the library into another app as a PDF. Locked notebooks and those in Recently Deleted stay behind.
- A notebook open on two iPads keeps up with itself. One you write in is sent a few seconds after you stop, and the other iPad shows the new writing in place if it has nothing unsaved. Where both were written in, the notice offers Keep Both, which keeps the older as a conflicted copy at once rather than when the notebook closes.
- Sync progress. A thread runs along the library's bar while notebooks are syncing, a notebook says "Not uploaded yet" under its cover until iCloud has it, and Settings counts the notebooks being synced and uploaded, "Uploading 3 of 12", over a row of ticks.
- Smart shelves and the pens in the tray sync with iCloud. A smart shelf changed on two iPads keeps the later change, and the tray's pens go as one set, the last changed winning.
- Scanned PDFs, and slides saved as pictures, are read for search too: their words turn up in the library's search, Find in Notebook, Spotlight and the study guide.
- Words in pictures placed on a page are read for search as well, just the part that shows when a picture is cropped. Find in Notebook marks them where they lie, even on a turned picture.
- An exported PDF carries the words in placed pictures too, as invisible text over each word, turned with its picture, that any PDF reader can find and select.
- Select PDF Text and the snapping highlighter work on scanned PDFs and slides saved as pictures too, on the words read off the page.
- Paper of your own. In the paper drawer or New Notebook, Add Paper… takes the first page of a PDF, or a picture, from Files or Photos: a planner, a lab sheet, score paper, a letterhead. It waits under My Paper with a miniature for every notebook; touch and hold it to rename or delete it. A page on it keeps its own copy in the notebook, a new page after it carries on with it, and your paper syncs and is backed up along with your stickers.
- Choose what a PDF export takes: drag the mustard ends along a strip of the pages, or tap a page, This Page or All Pages; keep the paper or leave out its colour and ruling; and pick Smaller File or Sharper Ink. Exporting images asks which pages and about the paper too.
- This Page as a PDF, in the editor's Export menu.
- Exported PDFs can be searched: the words read from your handwriting, and from scans and photos, lie under them as text that any PDF reader can find and select. Searchable Handwriting turns it off.
- Notebook as Text, in the editor's Export menu, and Export as Text in the library: the words of each page, read first where they haven't been yet, as plain text or as Markdown with a heading for each page.

### Changed

- iCloud sync is no longer experimental. It has been tested on real iCloud, on iPads signed in to one Apple Account.
- iCloud sync takes less room and data. An iPad downloads only what a notebook it receives lacks, leaves pictures, PDFs and recordings to iCloud once they're uploaded, compares files by their contents rather than their dates, and no longer waits a minute without a network before sending.
- Dark Paper in Dark Mode is now Keep Paper Light, in Settings › Appearance. Exports always keep the page's own colours.
- The language picked in a recording's transcript is now for that recording only.
- A notebook made with a newer version of OwlLuna can now go into Recently Deleted and come back out.
- A notebook deleted for good on another iPad now goes into Recently Deleted here, unless it was in there already.
- On a Mac, fingers and the pointer draw from the start.
- A recording carries on when the iPad locks or you switch apps. A notebook with a lock still stops recording when it locks, and keeps the iPad awake until then.
- At the accessibility text sizes, Shelf is now a list in OwlLuna's own style, led by Continue writing and the desk cards, with each notebook's folder and tags under its title.
- Pen, fineliner and fountain pen go into an exported PDF as shapes rather than a picture, so they stay sharp at any zoom and usually take less room than the picture of them did.

### Fixed

- iCloud sync no longer deletes many notebooks at once without asking. It holds them back and says so: Keep brings them back everywhere, and Delete lets the deletions go through.
- Folder changes made on two iPads are settled one at a time, so a rename made offline is no longer lost.
- A folder list that can't be read, on the iPad or in iCloud, is never written over. The library says folders aren't syncing, and your folders stay as they were.
- Restoring a backup over a damaged folder list keeps the folders you had.
- A change made after syncing with an iPad whose clock runs fast now wins, as it should.
- A notebook reopened at launch, or open when you come back to the app, first takes in writing done on another iPad. If that isn't ready, the editor says a newer version is waiting, and closing keeps both.
- Typing in a text box while zoomed in now wraps the lines where the page does.
- Today's events on a journal page are no longer replaced when the page moves to a new day once you have typed in them, ticked them or restyled them.
- A notebook you close no longer stays in memory until the app quits.
- A recording is kept if OwlLuna quits, crashes or runs out of battery before Stop. It joins the list, as long as it got, the next time the notebook opens.
- If a recording stops without Stop, the editor says when and why.
- A finger that drags where only the Pencil draws is told why nothing was drawn, the first time, with a Let Fingers Draw button.
- A resting palm or thumb no longer spoils draw and hold.
- With two notebooks side by side, touching either one makes it the one you're working in, and a Pencil double-tap or squeeze reaches only that one.
- With Settings › Appearance set to always Light or always Dark, a notebook opens at the right page and a whiteboard opens ready to write on.
- At the largest text sizes, the library's title is no longer cut off.
- In Dark Mode, the grips and corner handle on a selected picture or text box, and the knobs of a crop, are easy to see. Increase Contrast gives them a darker edge.
- Highlighter in an exported PDF no longer hides the writing and printed words under it.
- A link to another page in an export of one page, or of some pages, shows that page's name rather than "Missing page", and bookmarks keep their page numbers.
- Ink put on a page as it opens, such as a shape or an undo, no longer stays half drawn when the iPad is short of memory. A page that finishes loading at that moment no longer hides it, or drops it when you next write there.

## [1.0.0-build.2] - 2026-10-15

The first build for TestFlight testers. No accounts, no ads and no tracking.

### Added

#### Writing

- Apple Pencil handwriting with palm rejection, pressure and tilt.
- A tool tray with up to eight pens: pen, fineliner, fountain pen, calligraphy pen (iPadOS 26), pencil, highlighter, crayon and watercolour, each with its own colour, width and opacity. An eraser, a lasso and the shortcuts you choose sit beside them.
- Draw and hold: rest the pen at the end of a line or shape and it straightens.
- Pencil gestures: scribble over ink to erase it, loop round ink to select it, and choose what double-tap and squeeze do. An ink dish of your pens comes to the Pencil's tip.
- Select ink across pages and move it to another page.
- Handwriting to text, read on the iPad: turn selected ink into text, or have it set as type as you write. Translate it with Apple's translator.
- A zoom window for writing small and neat.
- Whiteboards: a page with no edges.
- Pinch to zoom up to 5×, with Fit Width and Fit Page.
- Undo and redo, including changes to pages.
- Hardware keyboard shortcuts.
- Draw with the Pencil only, or with a finger too.
- Focus mode, which puts the toolbar away.
- Notebook tabs, and two notebooks side by side in one window.

#### Presenting

- Present one page at a time, with a laser pointer.
- On a second screen, the audience sees the page while the iPad keeps the controls, your presenter notes, the next page and a timer.

#### Notebooks and paper

- Fourteen paper templates, nine paper colours and four page sizes.
- Change a page's paper and colour in place.
- New notebook starters, and Quick Note.
- A page navigator for jumping to, moving, adding, duplicating and deleting pages.
- Bookmarks, and links to another page, another notebook or a web address.

#### PDFs and pictures

- Import PDFs and write on them. Select a PDF's text to copy or highlight it, and a highlighter that snaps to a line of text.
- Insert photos as pages, and scan documents with the camera.
- Pictures, forty built-in stickers, and stickers of your own cut out of photos.
- Study tape that hides what is under it until you tap it.
- Typed text boxes, and today's events from your calendar.
- Export a notebook as a PDF, its pages as images, or a page as a time-lapse video.

#### Studying

- Flashcards made from study tape, from handwriting or by hand, with spaced repetition.
- A study guide written by Apple Intelligence on the iPad: the main points and practice questions.

#### Audio

- Record alongside a notebook, and replay the recording with your ink.
- Transcripts made on the iPad, never on a server.

#### Library

- Cloth, Print and first-page covers.
- A daily journal, with Today's page and On This Day.
- A This Week strip and a writing calendar, with no streaks or badges.
- Locked notebooks, opened with Face ID, Touch ID or the passcode.
- Folders inside folders, tags, smart shelves, favourites and sorting.
- Recently Deleted, emptied after 30 days.
- Search in handwriting, typed text, PDFs, scans and transcripts, Find in Notebook, and Spotlight.
- iCloud sync between your iPads. This is experimental: it has not yet run against real iCloud.
- Back up the whole library to one file, and restore it on this or another iPad.

#### Everywhere else

- English, Spanish, French and German. The translations have not yet been checked by native speakers.
- Home Screen and Lock Screen widgets, Control Center buttons, and Shortcuts and Siri.
- Runs on iPadOS 18 and later, and on Apple silicon Macs.

### Changed

- The app is now called OwlLuna. Notebooks and backups from before the rename still open.

[Unreleased]: https://github.com/owaisazmal/OwlLuna/compare/v1.0.0-build.2...HEAD
[1.0.0-build.2]: https://github.com/owaisazmal/OwlLuna/releases/tag/v1.0.0-build.2
