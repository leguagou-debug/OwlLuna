# Changelog

All notable changes to OwlLuna are listed here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html). Each version also names the build that went to TestFlight.

## [Unreleased]

### Added

- Text boxes can use a serif, monospaced or Fraunces typeface, with italic and underline.
- A text box can be a bulleted, numbered or checklist list. Tick a checklist line on the page.
- A text box can be highlighted in any of the highlighter's four colours.
- Crop a picture on the page: choose Crop, then drag an edge or a corner. Reset Crop brings the whole picture back, and exports keep only the part you kept.
- Settings › Appearance: follow the iPad's Light or Dark, or always use one of them, in every window.
- Settings › Input › Left-Handed moves the page ribbon, the zoom window's buttons and the panels beside the page to the left.
- Settings › Recently Deleted: empty it after 7, 30 or 90 days. Each iPad keeps to its own length, and sync leaves a notebook on an iPad that keeps it longer.
- Settings › Pen Tray puts the tray back to the pens it started with.
- Settings › Recordings sets the language transcripts use. Each recording can still pick another.
- A list view for the library. Switch between Shelf and List in the library's bar. The list shows tags, folder, pages and last changed as room allows, and a column heading sorts by it.
- The sort menu can turn the order round.
- Select several notebooks, or Select All, then favourite, tag, move, lock, export as PDFs or delete them together.
- Drag a notebook from the library into another app as a PDF. Locked notebooks and those in Recently Deleted stay behind.

### Changed

- Dark Paper in Dark Mode is now Keep Paper Light, in Settings › Appearance. Exports always keep the page's own colours.
- The language picked in a recording's transcript is now for that recording only.
- A notebook made with a newer version of OwlLuna can now go into Recently Deleted and come back out.
- A notebook deleted for good on another iPad now goes into Recently Deleted here, unless it was in there already.

### Fixed

- iCloud sync no longer deletes many notebooks at once without asking. It holds them back and says so: Keep brings them back everywhere, and Delete lets the deletions go through.
- Folder changes made on two iPads are settled one at a time, so a rename made offline is no longer lost.
- A folder list that can't be read, on the iPad or in iCloud, is never written over. The library says folders aren't syncing, and your folders stay as they were.
- Restoring a backup over a damaged folder list keeps the folders you had.
- A change made after syncing with an iPad whose clock runs fast now wins, as it should.
- A notebook reopened at launch, or open when you come back to the app, first takes in writing done on another iPad. If that isn't ready, the editor says a newer version is waiting, and closing keeps both.
- Typing in a text box while zoomed in now wraps the lines where the page does.

## [1.0.0] (build 2) - 2026-10-15

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

[Unreleased]: https://github.com/owaisazmal/OwlLuna/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/owaisazmal/OwlLuna/releases/tag/v1.0.0
