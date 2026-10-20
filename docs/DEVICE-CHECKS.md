# Device checks before 1.0

Unless a check is marked **Done**, it has only run in the simulator, or in tests through a stand-in. Each check needs a person and a real iPad, and some need a Pencil, a second iPad or a display. Work through a group, then tick its items in the "Device checks before 1.0" issue and attach what the check asks you to keep.

Each check gives its setup, numbered steps, what a pass looks like, the failures to look for and the evidence to keep. **Bold** names are the app's own buttons and menus, spelt as the app spells them. In the editor, **⋯** is the More button at the right of the bar and **+** is Add. A file and line, such as `OwlLuna/Canvas/ZoomWindow.swift:13`, is where a value lives; if the line has moved since this was written, search for the name beside it.

- [Before you start](#before-you-start): builds, devices, evidence, fixtures, tunables
- [iCloud sync](#icloud-sync): one sitting with two iPads; Sync 1, 4, 5 and 7 done, Sync 3 in part
- [Apple Pencil](#apple-pencil)
- [Hardware and services](#hardware-and-services)
- [Windows, screens and keys](#windows-screens-and-keys)
- [Whiteboards](#whiteboards)
- [Measurements](#measurements)

## Before you start

### Which build

| | TestFlight | Run from Xcode (Debug) | Profile from Xcode (⌘I) |
|---|---|---|---|
| Build configuration | Release | Debug | Release (the scheme's Profile action) |
| Test-only launch arguments | No | Yes | No |
| Instruments | No | Yes, with Debug timings | Yes |
| Xcode's Download Container | No | Yes | Yes |
| Log values Console hides as `<private>` | Hidden | Shown in Xcode's console | Hidden |
| iCloud sync | Yes | Yes, with a team that can sign iCloud | Yes, likewise |

- To run from Xcode, set up your own signing first ([README › Getting started](../README.md#getting-started)).
- Use the same build on both iPads for the sync sitting, and one build for the whole of any group. Write the version and build (TestFlight shows both) and the iPadOS version (Settings › General › About) beside every result.

### Devices and accessories

- **Two iPads** signed in to one Apple Account with iCloud Drive on, for sync. Use a test Apple Account: the sitting deletes notebooks for good.
- **One iPad with Face ID and one with Touch ID**, if you can; the two sync iPads can be these.
- **Apple Pencil Pro** for squeeze and hover. Double-tap needs an Apple Pencil (2nd generation) or Apple Pencil Pro. Write down which Pencil every Pencil result came from.
- **iPadOS:** the app supports iPadOS 18 and later. The calligraphy pen and the study guide need iPadOS 26 or later. CI's iPadOS 18 job is skipped while its runner has no iPadOS 18 simulator, so a short pass of the main paths on an iPad with iPadOS 18 is worth doing too.
- **A hardware keyboard with a trackpad**, such as a Magic Keyboard, for the keys and the pointer.
- **A display** with a USB-C to HDMI adapter, or an Apple TV for AirPlay.
- **A Mac** with Xcode 27 and Console, and an **iPhone** that films slow motion (for latency).

### Evidence

Each check names what to keep. This is how to get each kind.

- **Console.** On the Mac, open Console, pick the iPad in the sidebar and click Start. In the search field type `subsystem:com.owais.OwlLuna` and press Return, then add `category:` and the category the check names. The app's categories are:

  | Category | What logs there | Where |
  |---|---|---|
  | `sync` | a pass that failed, a notebook that failed, a folder list that can't be read | `OwlLuna/Services/SyncCenter.swift:88`, `OwlLuna/Services/LibrarySync.swift:346` |
  | `library` | index saves, filing and manifest updates, today's page, expired notebooks | `OwlLuna/Library/LibraryStore.swift:33` |
  | `index` | the library index set aside or failing to save, folders that can't be read | `OwlLuna/Storage/LibraryIndex.swift:460` |
  | `storage` | old packages that couldn't be renamed | `OwlLuna/Storage/StorageRoot.swift:6` |
  | `flashcards` | card files that couldn't be read or written | `OwlLuna/Storage/FlashcardStore.swift:162` |
  | `spotlight` | Spotlight indexing that failed | `OwlLuna/Services/SpotlightIndex.swift:37` |
  | `activity` | the writing history | `OwlLuna/Library/WritingActivity.swift:47` |
  | `widgets` | the App Group missing from the build | `Shared/WidgetSnapshot.swift:27` |
  | `fonts` | a bundled font that didn't register | `OwlLuna/Design/Typography.swift:24` |

  Two things to know. Every line the app logs is an error, so a pass that went well leaves nothing; the app's own diagnostics below say what it did. And the notebook IDs and error text in those lines show as `<private>` in Console; Xcode's console shows them while it runs the app. For iCloud's own side, also stream the processes `bird` and `cloudd`.
- **Screen recordings.** Control Center › Screen Recording (add it in Control Center if it isn't there). A recording doesn't show your hand, so for the Pencil and palm checks also film the iPad with a phone.
- **Instruments.** In Xcode, choose the iPad as the destination and Product › Profile (⌘I). That builds Release and opens Instruments; pick the template the check names and record for as long as it says. Instruments can't profile a TestFlight build. The app's signposts (subsystem `com.owais.OwlLuna`) show in the os_signpost instrument, which you can add to any template: "Launch" (`app`), "Open to first ink" (`editor`), "Save" (`document`), "Thumbnail" (`thumbnails`), "OCR page" (`ocr`), "Export" (`export`) and "Cover render" (`covers`).
- **sysdiagnose.** Press and hold both volume buttons and the top button for about a second, then let go. About ten minutes later it is in Settings › Privacy & Security › Analytics & Improvements › Analytics Data, named `sysdiagnose_…`; share it to the Mac with AirDrop. For sync, first install the iCloud logging profile for iOS and iPadOS from Apple's Profiles and Logs page (developer.apple.com/bug-reporting/profiles-and-logs) on both iPads, so the sysdiagnose holds iCloud's detailed logs. Take one on both iPads within a few minutes of anything going wrong.
- **The app's own diagnostics.**
  - Settings › iCloud: the line under **Sync Now** says what the last pass did ("2 notebooks sent, 3 notebooks received" and so on, or "Everything is up to date") and when it finished ("Last synced …"). Below it are the last error, any upload problem, and a row for each notebook that didn't sync, with the reason.
  - The library's bar: a worded **iCloud** plate with a count appears when there is news (tomato for trouble, cobalt for conflicted copies alone). Its card lists each item, with **Open**, **Keep**, **Delete** or **Replace** where they apply, then **Dismiss** and **Try Again**.
  - The editor's notice banner, for example "A newer version is waiting in iCloud…".
  - On a build run or profiled from Xcode: Xcode › Window › Devices and Simulators, pick the iPad, select OwlLuna under Installed Apps, then **⋯** › Download Container. Under `AppData/Library/Application Support/` are `sync-state.json` (what each notebook last agreed), `expired-trash.json`, the notebooks in `Library/<id>.owlluna/`, and `Arriving/` and `Deleting/`. This isn't possible with a TestFlight build.
- **Crash and memory logs.** Settings › Privacy & Security › Analytics & Improvements › Analytics Data: `OwlLuna-…` for a crash, `JetsamEvent-…` when iPadOS ended the app for memory. TestFlight also offers to send a crash report.

### Fixtures

The test fixtures are made by the tests or by launch arguments, and launch arguments only exist in Debug builds (`#if DEBUG`, `OwlLuna/App/AppModel.swift:146` to `:176`). A TestFlight build is a Release build and reads none of them.

| Fixture | Made by | Debug build from Xcode | TestFlight build |
|---|---|---|---|
| **Heavy ink:** 100 Letter pages × 500 strokes | `V2StressFixture.write` (`OwlLunaTests/PerformanceBaselineTests.swift:483`), inside the unit tests, in a temporary folder deleted afterwards (`:34`) | **Can't be loaded into the app.** Run the unit test on the iPad instead (below) | **Can't be loaded.** Use the hand-made stand-in (below) |
| **300-page PDF** | `-seedLongPDF` (`OwlLuna/App/AppModel.swift:84`, `OwlLuna/App/DebugProbes.swift:400`) | Launch argument | **Can't be loaded as it is.** Import any long PDF (library **New** › **Import PDF…**), or restore a backup made on a Debug build |
| **A library of N notebooks** | `-seedLibrary N` (`OwlLuna/App/AppModel.swift:83`) | Launch argument | **Can't be loaded as it is.** Restore a backup made on a Debug build |
| Replay, handwriting and study notebooks | `-seedReplay`, `-seedHandwriting`, `-seedStudy` (`OwlLuna/App/AppModel.swift:85` to `:87`) | Launch argument | Can't be loaded |

**A seed on a Debug build.** In Xcode, Product › Scheme › Edit Scheme… › Run › Arguments, add the argument under Arguments Passed On Launch, and run on the iPad.

- The seeds only write into an empty library (`OwlLuna/App/AppModel.swift:82`). Without `-storageRoot` that is the iPad's real library, which syncs if sync is on: answer **Not Now** to the iCloud question, or use an iPad that isn't in the sync sitting.
- With `-storageRoot <name> -resetStorage` the library is a test folder that never reaches iCloud, Spotlight or the widgets (`OwlLuna/App/AppModel.swift:154` to `:164`). That is fine for the Pencil and memory checks but useless for sync.
- A seeded real library stays in the app's container, so Product › Profile afterwards (Release, no arguments) opens it.
- To carry it to a TestFlight build: Settings › Backup › **Back Up Library…**, save the file, then on the TestFlight iPad Settings › Backup › **Restore from a Backup…**.

**The heavy fixture on a device.** The exact fixture can only be measured through its unit test, run on the iPad:

```bash
TEST_RUNNER_OWLLUNA_PERF=1 xcodebuild test -project OwlLuna.xcodeproj -scheme OwlLuna -destination 'platform=iOS,name=<your iPad name>' -only-testing:OwlLunaTests/PerformanceBaselineTests/testV2MemoryScrollingHeavyInk
```

It prints `PERF v2 memory, scrolling heavy ink: …` and `PERF v2 memory, heavy ink at 5x: peak=…MB`. Swap the test name for `testV2StrokeEndHeavyNotebook`, `testV2OpenHeavy` or `testV2PageOperationsHeavy` for the other heavy timings.

**A hand-made stand-in, on any build.**

1. Make a notebook on the default paper (Narrow Ruled, Letter) and write a full page of ordinary handwriting, about 150 strokes.
2. **⋯** › **Select Ink Across Pages**, then drag from the page's top-left corner to its bottom-right (a straight drag selects a box). The bar says "150 strokes. Drag them to move them."
3. Tap **Duplicate**, drag the copy back over the writing, and tap **Done**. Do it twice more, selecting everything each time: about 600 strokes.
4. **⋯** › **Duplicate Page** until there are at least 30 pages. 30 is past the 24 clean pages the ink cache keeps; 100 matches the fixture.

### Tunables

These values were chosen in the simulator and need judging with a real hand. The check that judges each one is linked.

| Tunable | Value | Where | Judged in |
|---|---|---|---|
| Zoom window: rest before it moves on | 0.8 s | `ZoomWindow.rest`, `OwlLuna/Canvas/ZoomWindow.swift:13`; used at `OwlLuna/Canvas/PageStack.swift:2686` | [Pencil 8](#pencil-8) |
| Zoom window: the band | the last 30% of the window (`advanceZone` 0.7); moves 55% of its width (`stride`); windows of 30, 42 or 60% of the page (`widths`) | `OwlLuna/Canvas/ZoomWindow.swift:9`, `:11`, `:7` | [Pencil 8](#pencil-8) |
| Handwriting to Text: rest before it is set as type | 1.0 s (`InkTyping.pause`), with the reading begun 0.4 s into it (`InkTyping.lookAhead`). It was 1.2 s before | `OwlLuna/Canvas/InkTyping.swift:13`, `:17`; the timer at `OwlLuna/Canvas/PageStack.swift:1135`. A Debug build takes `-inkTypingPause <seconds>` (`InkTyping.swift:11`) | [Pencil 9](#pencil-9) |
| Draw and hold, and loop to select: rest | 0.45 s (`ShapeSnap.holdDuration`) | `OwlLuna/Canvas/ShapeSnap.swift:278`; used at `OwlLuna/Canvas/PageStack.swift:1202` (loop) and `:1234` (shapes) | [Pencil 6](#pencil-6), [Pencil 7](#pencil-7) |
| Draw and hold: how still a rest is | 6 pt (`TouchRests.slop`) | `OwlLuna/Canvas/ShapeSnap.swift:304` | [Pencil 7](#pencil-7) |
| Draw and hold: which touch's rest counts | the Pencil's; a finger's only when fingers draw and it was alone on the pages; only for a stroke begun while that touch was down | `TouchRests.began`, `OwlLuna/Canvas/ShapeSnap.swift:322`; `TouchRests.take`, `:353` | [Pencil 3](#pencil-3) |
| Draw and hold: smallest shape | 24 pt across | `OwlLuna/Canvas/ShapeSnap.swift:32` | [Pencil 7](#pencil-7) |
| Scribble to erase | at least 5 turns (`minimumReversals`), travelling 4 times its own diagonal (`density`), over half of a stroke (`cover`) | `OwlLuna/Canvas/PencilGestures.swift:7`, `:9`, `:11` | [Pencil 6](#pencil-6) |
| Loop to select | its ends within 30% of its size, or 20 pt | `OwlLuna/Canvas/PencilGestures.swift:105` | [Pencil 6](#pencil-6) |
| Undo budget | 48 MB, between 20 and 200 steps (`UndoBudget`) | `OwlLuna/Editor/NotebookDocument.swift:46`, `:47`; applied after a save at `:705` | [Measure 3](#measure-3) |

## iCloud sync

One sitting on two iPads, called A and B. The steps build on each other, so run them in order. Allow about three hours, plus an overnight wait if you try the optional storage step in [Sync 8](#sync-8).

Sync 1, 4, 5 and 7, and the lock and folder in Sync 3, were tested on real iCloud by the maintainer in October 2026, on iPads signed in to one Apple Account. The rest are still open. A new sitting still runs them in order, since the later checks use the notebooks they make.

**Setup for the whole sitting**

- Two iPads on the same build, signed in to the same **test** Apple Account, with iCloud Drive on and at least 2 GB free in iCloud. Date and Time set automatically on both (Settings › General › Date & Time).
- Start with an empty copy in iCloud: turn sync off in OwlLuna on every device that had it on, then delete OwlLuna's data under Settings › your name › iCloud.
- B starts without OwlLuna installed. A can start with an empty library.
- The iCloud logging profile installed on both iPads (see [Evidence](#evidence)).
- Console on the Mac, one window per iPad, filtered to `subsystem:com.owais.OwlLuna category:sync`.
- A note of the time (by the iPad's clock) at each step, so logs can be matched to it.

**"Sync A"** in the steps means: on A, close any open notebook with **Library** (a notebook syncs when it is closed), open Settings (the library sidebar's **Settings**), tap **Sync Now** under iCloud, and wait until the line below it ends "Last synced" with the time now. Screenshot that line. **"Wait"** means a minute; iCloud carries files between devices in its own time.

**Evidence for every step:** Console `category:sync` on both iPads, a screen recording of each iPad, the Settings › iCloud screenshot after each sync, and a sysdiagnose on both iPads at the first failure. On a Debug build, Download Container on both iPads after a failure too.

<a id="sync-1"></a>
### Sync 1. The first sync, and a notebook written on one iPad arrives on the other

**Done:** tested on real iCloud by the maintainer, October 2026.

**Steps:**
1. On A, open OwlLuna. When it asks "Keep a copy of your notebooks in iCloud?", tap **Sync with iCloud**. If it doesn't ask, turn on Settings › iCloud › **Sync with iCloud**.
2. On A, **New** › **New Notebook**. Name it "Sync 1", write "one" on page 1, then **+** › **Page After Current** and write "two". Add a photo with **+** › **Picture on This Page…**. Tap **Library**.
3. Make "Sync 2", "Sync 3" and "Sync 4" the same way, with a word each.
4. Make four quick notes (**New** › **Quick Note**), each with a word on it. These are for [Sync 6](#sync-6).
5. Sync A. Note the line under Sync Now.
6. On B, install OwlLuna from TestFlight and open it. Tap **Sync with iCloud** when asked. Wait two minutes, then Sync B.

**Pass:**
- A's line says how many notebooks were sent: eight, if A started empty.
- B didn't copy anything before you answered.
- B's library shows all eight, with the same covers. "Sync 1" opens on B with both pages, the ink and the photo.
- B's line says the notebooks were received, then, after another Sync Now, "Everything is up to date".
- No "(conflicted copy)" anywhere.

**Common failures:**
- A notebook that arrives with blank pages, missing ink or a missing photo. A pull should wait until every file has arrived.
- "notebooks still downloading from iCloud" on B for more than five minutes on good Wi-Fi.
- "iCloud is still downloading your library. Sync will try again shortly." after several Sync Nows.
- A notebook that opens read-only or empty.

<a id="sync-2"></a>
### Sync 2. Writing back, and a notebook open on the other iPad

**Steps:**
1. On A, open "Sync 1" and leave it open at page 1 without writing. Go to the Home Screen.
2. On B, open "Sync 1", write "from B" on page 2, tap **Library**. Sync B. Wait.
3. On A, open OwlLuna again (it comes back in "Sync 1").
4. On A, still in "Sync 1", write "from A" on page 1 and go to the Home Screen without leaving the notebook.
5. On B, open "Sync 1", write "B again" on page 1, tap **Library**. Sync B. Wait.
6. On A, open OwlLuna again. Read the banner, then tap **Library**.
7. Sync A, wait, Sync B.

**Pass:**
- Step 3: within a few seconds A's editor shows "from B" on page 2, at the same page, with no conflicted copy.
- Step 6: A keeps "from A" and its banner says "A newer version is waiting in iCloud. When you close this notebook, both are kept, the older as a conflicted copy."
- Step 7: both iPads have "Sync 1" and "Sync 1 (conflicted copy)", and between them they hold "from B", "from A" and "B again". The library's iCloud plate (cobalt) lists the copy with **Open**.

**Common failures:**
- Step 3: A stays on the old page with no banner, or makes a conflicted copy although nothing was written on A.
- Step 6: A's writing is replaced by B's, or lost.
- Step 7: more than one conflicted copy, or one of the three lines missing.

<a id="sync-3"></a>
### Sync 3. A lock, a favourite, a folder, a tag and a sticker carry over

**Done in part:** the lock and the folder were tested on real iCloud by the maintainer, October 2026. The favourite, the tag, the sticker and the rename in step 7 are still open.

**Steps:**
1. On A, touch and hold "Sync 2" › **Lock…** and confirm with Face ID or Touch ID.
2. Touch and hold "Sync 3" › **Favourite**.
3. In the sidebar, **New Folder**, name it "Trip" and tap **Create**. Drag "Sync 3" onto "Trip" in the sidebar. Touch and hold "Trip" › **Spine Colour** and pick one.
4. Touch and hold "Sync 4" › **Tags…**, add the tag "device-check" and finish.
5. Open any notebook, **+** › **Sticker…**, and under My Stickers tap **From Photo…** and pick a photo with a clear subject. Tap **Library**.
6. Sync A, wait, Sync B.
7. On B, touch and hold "Trip" › **Rename**, call it "Trip 2" and save. Sync B, wait, Sync A.

**Pass:**
- On B: "Sync 2" is blurred under a padlock and asks for Face ID or Touch ID to open. "Sync 3" is a favourite and is in "Trip", which has the spine colour. The sidebar has a "device-check" tag with "Sync 4". The sticker is under My Stickers in B's sticker drawer.
- After step 7, A's folder is "Trip 2", still with its colour and "Sync 3" in it.

**Common failures:**
- A lock missing on B. A lock must never be lost to a sync.
- The folder twice, a notebook outside its folder, or the rename going back.
- The sticker missing, or a blank tile in its place.

<a id="sync-4"></a>
### Sync 4. A delete, and a restore from Recently Deleted

**Done:** tested on real iCloud by the maintainer, October 2026.

**Steps:**
1. On A, touch and hold "Sync 4" › **Delete**. Sync A, wait, Sync B.
2. On B, sidebar › **Recently Deleted**. Touch and hold "Sync 4" › **Restore**. Sync B, wait, Sync A.
3. On A, check "Sync 4" is back on its shelf with its tag.
4. On A, delete "Sync 4" again. Sync A, wait, Sync B. Then on A, **Recently Deleted**, touch and hold "Sync 4" › **Delete Permanently** and confirm. Sync A, wait, Sync B.

**Pass:**
- Step 1: "Sync 4" is in B's Recently Deleted, not gone.
- Steps 2 and 3: it is back on both iPads.
- Step 4: it is gone from both, B's Recently Deleted included (it was there already, so it goes for good).

**Common failures:** step 1 deleting it for good on B; the restore not reaching A; "Sync 4" coming back after step 4; a conflicted copy.

<a id="sync-5"></a>
### Sync 5. A pass with no network, and a notebook changed on both

**Done:** tested on real iCloud by the maintainer, October 2026.

**Steps:**
1. On A, turn on Airplane Mode in Control Center and check that Wi-Fi is off too.
2. On A: in "Sync 3", write "A offline" on page 1 and tap **Library**. In the sidebar, touch and hold "Trip 2" › **Rename** and call it "Trip offline". Make a notebook "Made offline" with a word in it. Sync A.
3. Screenshot A's Settings › iCloud.
4. On B, online: in "Sync 3", write "B online" on page 1 and tap **Library**. Touch and hold "Trip 2" › **Spine Colour** and pick another colour. Sync B.
5. Wait five minutes. Nothing from A should reach B.
6. On A, turn Airplane Mode off and make sure Wi-Fi is on. Open OwlLuna. Wait two minutes. Sync A, wait, Sync B, then Sync A again.

**Pass:**
- Step 3: nothing says a notebook failed. The line may say notebooks were sent and are still uploading, and Settings may say "iCloud can't be reached right now. Changes made on this iPad will upload when it's back." Both are right: the pass writes to the iPad's own copy of the iCloud folder, and iCloud uploads it later.
- Step 6: both iPads have "Sync 3" and "Sync 3 (conflicted copy)", one with "A offline" and one with "B online", and the plate lists the copy with **Open**. The folder is "Trip offline" with B's new colour on both (each is settled on its own). "Made offline" is on both.

**Common failures:** one of the two lines lost; two conflicted copies; the folder name or colour going back on either iPad; "Made offline" not on B ten minutes after A is back online; "Sync stopped" on A.

<a id="sync-6"></a>
### Sync 6. Many deletes at once are held back

A pass that would take more than three notebooks out of the library, or more than half of it, takes none of them and asks (`LibrarySync.deletesAtOnce`, `OwlLuna/Services/LibrarySync.swift:456`).

**Steps:**
1. On A, turn on Airplane Mode.
2. In the library tap **Select**, pick the four quick notes from [Sync 1](#sync-1) and tap **Delete**. Then **Recently Deleted** › **Empty** › **Delete All**.
3. Turn Airplane Mode off. Wait. Sync A.
4. The library bar shows the iCloud plate in tomato. Tap it: the card says "4 notebooks weren't deleted". Tap **Keep**.
5. Sync A.
6. Do steps 1 to 3 again. This time tap **Delete** on the card, then **Delete** under "Delete 4 notebooks?".
7. Sync A, wait, Sync B.

**Pass:**
- Step 3: nothing is deleted on B, and A's line includes "4 deletions held back".
- Step 5: the four notes are back on A with their writing.
- Step 7: they are gone from A and are in B's Recently Deleted (not gone for good), and B doesn't ask.

**Common failures:** B deleting them before you chose; **Keep** not bringing them back; B showing the held notice as well; B deleting them for good.

<a id="sync-7"></a>
### Sync 7. A large upload

**Done:** tested on real iCloud by the maintainer, October 2026.

There is no progress figure for a large upload yet (ARCHITECTURE › iCloud sync › Not done), so this check times it by hand.

**Setup:** a PDF of 200 pages or more, such as a textbook.

**Steps:**
1. On A, **New** › **Import PDF…** and pick the PDF. Open it, tap **Record Audio** and record 20 minutes (talk, or play a podcast near the iPad), then stop. Write on a few pages. Tap **Library**.
2. Sync A. Note the time.
3. Every minute, Sync B and note both iPads' lines.
4. Partway through, turn A's Wi-Fi off for 30 seconds and back on.
5. Note when A stops saying the notebook is still uploading, and when it opens whole on B.

**Pass:**
- A says the notebook is still uploading until it has, then "Everything is up to date".
- B says it is still downloading, and the notebook only appears once all of it is there. On B every page, the PDF, the ink and the recording are there and play.
- The upload carries on by itself after the Wi-Fi break.
- Record the two times; there is no target yet.

**Common failures:** the notebook on B with blank PDF pages, no recording, or "The notebook's files couldn't be read."; "Some files didn't upload" on A; the upload never finishing; the notebook twice on B.

<a id="sync-8"></a>
### Sync 8. Evicted files and `.icloud` placeholders

A file iCloud hasn't brought down, or has taken off the iPad to save room, is a placeholder named `.<name>.icloud`. The app asks for everything to be downloaded at each pass and waits up to 60 seconds (`OwlLuna/Services/LibrarySync.swift:511`, `CloudFiles.download` at `:1138`). It must wait for a placeholder and never copy one.

The Files app can't make iPadOS evict OwlLuna's files: OwlLuna's iCloud folder isn't shown there (there is no `NSUbiquitousContainers` in `Config/Info.plist`, and the copy lives in `<container>/Sync`), so there is no Remove Download to tap. These steps start B from nothing instead, so every file has to come down from iCloud.

**Steps:**
1. Sync B and Sync A, so neither iPad has anything the other lacks.
2. On B, touch and hold the OwlLuna icon › Remove App › Delete App. That removes B's library from the iPad; the copy in iCloud stays.
3. Install OwlLuna again from TestFlight, open it, and tap **Sync with iCloud**.
4. As notebooks appear, open one straight away.
5. Sync B until the line says "Everything is up to date".
6. Optional, overnight: fill B until iPadOS warns that storage is almost full (large videos will do it), leave it overnight so iPadOS takes iCloud files off it, free the space, then open OwlLuna and Sync B.

**Pass:**
- Every notebook comes back whole, with its folder, tags, favourite and lock (locked notebooks still ask), and every sticker.
- A notebook that isn't all there isn't opened part-way: it appears once it is whole.
- Nothing is deleted on A. A device that has never synced only adds.
- Step 6: every notebook opens whole afterwards.

**Common failures:** notebooks missing on B; **any delete reaching A**; duplicates or conflicted copies; a notebook stuck as still downloading; a sticker missing.

<a id="sync-9"></a>
### Sync 9. The last notebook, reopened at launch

A window that reopens its notebook at launch first pulls that one, for 4 seconds at most (`SyncCenter.reopenLimit`, `OwlLuna/Services/SyncCenter.swift:352`).

**Steps:**
1. On A, open "Sync 1" and leave it at page 1 without writing.
2. Restart A (Settings › General › Shut Down, then turn it on). Don't close OwlLuna in the app switcher first: a window closed there starts in the library next time.
3. While A is off, on B open "Sync 1", write "while A was off", tap **Library** and Sync B.
4. On A, unlock the iPad, wait a minute, and open OwlLuna.

**Pass:** A opens in "Sync 1" with "while A was off" on it, within about four seconds of the splash, with no conflicted copy and no banner.

**Common failures:** A opens the old version and then shows "A newer version is waiting…" or makes a conflicted copy; it takes much longer than four seconds. If A starts in the library, the window wasn't restored and this check didn't run: note it and try again.

<a id="sync-10"></a>
### Sync 10. A device whose clock runs fast

A change is stamped after every stamp the device has seen, so a device with a fast clock can't win over a later change made elsewhere (`LibraryState.stamp(after:at:)` in `OwlLuna/Models/NotebookManifest.swift`).

**Steps:**
1. On B, Settings › General › Date & Time: turn off Set Automatically and set the time ten minutes ahead.
2. On B, touch and hold "Made offline" › **Lock…**. Sync B, wait, Sync A.
3. On A, whose clock is right, check "Made offline" is locked, then touch and hold it › **Remove Lock…**. Sync A, wait, Sync B.
4. On B, turn Set Automatically back on.

**Pass:** after step 3 "Made offline" is unlocked on both iPads, although A's clock was behind B's.

**Common failures:** it is locked again on either iPad after the passes.

<a id="sync-11"></a>
### Sync 11. Recently Deleted kept for different lengths

Each iPad keeps to its own length. One whose time runs out leaves the notebook on an iPad that keeps it longer.

**Steps:**
1. On A, Settings › Recently Deleted › **Keep Deleted Notebooks For** › 7 days. On B, 90 days.
2. On A, delete "Sync 1 (conflicted copy)". Sync A, wait, Sync B. Check it is in B's Recently Deleted.
3. On A, Settings › General › Date & Time: turn off Set Automatically and set the date eight days ahead. Change nothing else on A while its clock is ahead.
4. On A, close OwlLuna in the app switcher and open it again (the purge runs once a launch, after the first sync).
5. On A, look in **Recently Deleted**. Sync A, wait, Sync B.
6. On A, turn Set Automatically back on, then close and reopen OwlLuna.

**Pass:** after step 5 the notebook is gone from A's Recently Deleted and still in B's. After step 6 it doesn't come back to A.

**Common failures:** B losing it; it coming back to A's library or Recently Deleted.

<a id="sync-12"></a>
### Sync 12. A folder list in iCloud that can't be read (optional, needs a Mac)

This needs a Mac signed in to the same Apple Account with iCloud Drive on, and it damages the test account's folder list on purpose.

**Steps:**
1. On the Mac, in Terminal, list `~/Library/Mobile Documents/` and look for `iCloud~com~owais~OwlLuna` (named after the iCloud container, so another prefix if the build used another). If it isn't there, skip this check.
2. Copy `Sync/folders.json` in it to the Desktop, then replace the file's contents with `not json`.
3. Wait two minutes. Sync A.
4. On A, tap the iCloud plate. Under "Folders aren't syncing" tap **Replace**, then **Replace** under "Replace the folder list in iCloud?".
5. Sync A, wait, Sync B.

**Pass:** at step 3 the plate says "Folders aren't syncing", A's folders stay as they were and notebooks still sync. After step 5 the plate clears on both and both iPads keep all their folders.

**Common failures:** folders deleted on either iPad; A writing over the damaged list without being asked; no notice at all.

<a id="sync-13"></a>
### Sync 13. Another Apple Account signs in (optional)

**Steps:**
1. On B, sign out of iCloud and sign in to a second test Apple Account with iCloud Drive on. Open OwlLuna.
2. Read what it asks. Tap **Turn Off Sync**.
3. Sign back in to the first account and turn on Settings › iCloud › **Sync with iCloud** again. Answer **Sync with This Account** if asked.

**Pass:** step 1 asks "A different Apple Account is signed in", with **Sync with This Account** and **Turn Off Sync**, and copies nothing first. After step 3 B syncs with the first account as before.

**Common failures:** B copying its notebooks into the second account without asking; B's library emptied.

**To finish the sitting:** Sync both, compare the two libraries notebook by notebook, and screenshot both Settings › iCloud lines.

## Apple Pencil

<a id="pencil-1"></a>
### Pencil 1. Writing with each kind of pen

**Setup:** an iPad with an Apple Pencil (note which), iPadOS 26 or later for the calligraphy pen. One notebook on white Narrow Ruled paper and one on Chalkboard.

**Steps:**
1. In the tray, tap the empty label after the pens (**New Pen**). The new pen's options open.
2. For each kind in the pen roll, in turn: Pen, Fineliner, Fountain Pen, Calligraphy Pen, Pencil, Highlighter, Crayon, Watercolour:
   1. Write a line lightly and a line pressing hard.
   2. With the pencil and the crayon, tilt the Pencil and shade.
   3. Set **Width** to its thin end and write, then its thick end.
   4. Set **Opacity** low and write over other ink.
3. If the iPad and Pencil support hover, hold the tip just above the page.
4. Pinch to 5× and write with the pen and the pencil.
5. Do step 2 on Chalkboard paper, and with Settings › Appearance › Dark.

**Pass:** each kind looks like its drawing in the roll. Pressure changes the weight where the kind uses it and tilt shades with the pencil. Every kind leaves a mark at the thin end of Width. Low opacity is fainter, never darker. Ink is sharp at 5× once the pinch stops. The pen's swatch in the tray matches its ink on the page in light, dark and on Chalkboard.

**Common failures:** a kind that leaves no mark at the thin end (PencilKit's pen, fineliner and fountain pen leave none under about 2; see ARCHITECTURE › Tools); ink trailing the tip; a stroke that changes colour or width when you lift; the calligraphy pen offered on iPadOS before 26.

**Evidence:** a screen recording; a photo of each page at 1× and at 5×.

<a id="pencil-2"></a>
### Pencil 2. Both kinds of eraser

**Steps:**
1. Write a few lines with a pen and a highlighter.
2. Tap **Eraser** in the tray, tap it again for its options and choose **Whole Strokes**. Rub across a word.
3. Choose **Part of a Stroke**. Rub half of a word at a narrow width, then at a wide one.
4. Undo after each rub (**Undo** in the bar, or ⌘Z).

**Pass:** Whole Strokes takes every stroke the tip touches and only those. Part of a Stroke cuts only under its width, and the width shown matches what is cut. One Undo puts back one rub. Erasing never scrolls the page.

**Common failures:** a cut wider or narrower than the width shown; one Undo putting back more or less than one rub.

**Evidence:** a screen recording.

<a id="pencil-3"></a>
### Pencil 3. Palm rejection

A resting palm or thumb must never draw, scroll, or count as the Pencil resting for draw and hold (`TouchRests`, `OwlLuna/Canvas/ShapeSnap.swift:303` to `:359`). How often a palm gets past iPadOS's own palm rejection has never been seen.

**Steps:**
1. With **⋯** › **Draw With** › **Apple Pencil Only**, write a paragraph with the side of your hand on the glass, as on paper: on the lower half of the page, and close to the tray.
2. Put the palm down first and then write; lift the palm halfway through a word.
3. Draw a straight line, rest the Pencil at its end for a moment with the palm down, then lift.
4. Draw a line without resting, lifting the palm just before the Pencil.
5. Choose **⋯** › **Draw With** › **Pencil and Finger** and do steps 1 to 4 again. Scroll with two fingers while the palm is down.
6. Turn on Settings › Input › **Left-Handed** and write with the left hand.

**Pass:** no dots, marks or scrolling from the palm. Step 3 straightens the line; step 4 never does. The tray's buttons never fire from the palm.

**Common failures:** marks where the palm landed; the page jumping; a shape straightened that you didn't hold, or not straightened although the Pencil rested.

**Evidence:** a phone video of hand and screen together, and a screen recording. Note how many stray marks per page.

<a id="pencil-4"></a>
### Pencil 4. Latency

**Setup:** an iPad Pro with a 120 Hz screen and, if you can, an iPad at 60 Hz. An iPhone filming slow motion at 240 frames a second. Apple Notes for comparison. The heavy stand-in from [Fixtures](#fixtures).

**Steps:**
1. In Notes, draw fast zigzags with its pen and film the tip close up in slow motion.
2. Do the same in OwlLuna with the Pen: on an empty page; on a page of the heavy stand-in; at 5×; with Handwriting to Text on; while recording audio; and in the zoom window's strip.
3. In each clip, count the frames between the tip and the end of the ink, five times.

**Pass:** in every case OwlLuna is within one frame of the clip (about 4 ms) of Notes on the same iPad. Both use PencilKit, so any extra lag is the app's.

**Common failures:** lag that grows on the heavy page or at 5×; a stutter as the Pencil lifts (work at stroke end); ink appearing in jumps.

**Evidence:** the slow-motion clips. Instruments, Time Profiler, 60 seconds of writing on the heavy page: on the main thread nothing at stroke end should come near 4 ms (the simulator measured 0.12 ms).

<a id="pencil-5"></a>
### Pencil 5. Double-tap and squeeze switch tools, and the ink dish opens under the tip

The app has no system tool picker, so it carries out the system's setting itself (`OwlLuna/Canvas/PageStack.swift:2914`). Where the system asks for a palette, the ink dish comes to the tip (`toggleDish`, `:2947`).

**Setup:** an Apple Pencil Pro (double-tap and squeeze) or an Apple Pencil (2nd generation) (double-tap only), on an iPad with hover if you can. Note what iPadOS's Settings › Apple Pencil has for double-tap and squeeze.

**Steps:**
1. In OwlLuna, Settings › Apple Pencil: **Double-Tap** and **Squeeze** on **System Setting**.
2. In iPadOS Settings › Apple Pencil, set double-tap to switch between the current tool and the eraser. In a notebook, take a pen, double-tap: the eraser. Double-tap again: the pen.
3. Set it to switch between the current tool and the last one. Take pen A, then pen B, then double-tap: pen A.
4. Leave squeeze on showing the palette. Hold the tip over the middle of the page and squeeze: the ink dish opens. Tap a well. Squeeze near the edge of the page, near the tray, and with the tip far above the glass.
5. In OwlLuna's Settings set **Squeeze** to each choice in turn: **Switch to Eraser**, **Undo**, **Select Ink**, **Show or Hide Tools**, **Tool Palette at the Pencil**, **Zoom Window**. Try each.
6. Do the same for **Double-Tap**.
7. Try both in focus mode, while presenting, with a sheet open and in a read-only notebook.

**Pass:** one action for each tap or squeeze, and no system picker. The dish opens centred under the tip, wholly on the pages and clear of the tray; with the tip too far off it opens in the middle of the pages. A tap outside puts it away. In focus mode they work as when writing; while presenting, with a sheet open or in a read-only notebook, nothing happens.

**Common failures:** the dish away from the tip; two actions from one squeeze; iPadOS's own palette appearing; nothing at all.

**Evidence:** a screen recording and a phone video of the Pencil.

<a id="pencil-6"></a>
### Pencil 6. Scribble to erase and loop to select, in real handwriting

These have only been recognised from strokes drawn by tests.

**Setup:** Settings › Apple Pencil › **Scribble to Erase** and **Circle and Hold to Select** on. A pen in hand: the highlighter, crayon and watercolour shade, and never erase.

**Steps:**
1. Write twenty words, some printed and some joined.
2. Scribble back and forth over one word, about six times. Do it 20 times on different words, and Undo each.
3. Draw a loop round two words, hold still for half a second and lift. Drag what is selected. Do it 20 times.
4. Write things that look like scribbles: "mmm", "www", a spring of loops, cross-hatching. Draw a loop round a word without holding.
5. Scribble over ink with the highlighter, the crayon and the watercolour.

**Pass:** a scribble erases what it covers and nothing else, and one Undo brings it back. A held loop selects the words and the bar says how many strokes. Nothing in step 4 erases or selects. Step 5 never erases. Count how many of each 20 worked.

**Common failures:** a scribble left as a zigzag (too strict); "m" or "w" erasing (too loose); a loop selecting without the hold; the loop's own stroke left behind.

**Tunable:** scribble needs at least 5 turns (`ScribbleRecognizer.minimumReversals`, `OwlLuna/Canvas/PencilGestures.swift:7`), 4 times its diagonal in length (`density`, `:9`) and half of a stroke under it (`cover`, `:11`). A loop's ends must meet within 30% of its size or 20 pt (`:105`), then rest 0.45 s (`ShapeSnap.holdDuration`, `OwlLuna/Canvas/ShapeSnap.swift:278`). Note which way each miss went.

**Evidence:** a screen recording and the counts.

<a id="pencil-7"></a>
### Pencil 7. Draw and hold

**Setup:** Settings › Apple Pencil › **Straighten Shapes** on.

**Steps:**
1. Draw a line, rest the Pencil for half a second and lift. Then draw one and lift without resting.
2. With a rest each time: a circle, an ellipse, a rectangle, a triangle, a five-sided shape, and an open zigzag of three straight pieces.
3. After each one that straightens, Undo twice.
4. Draw a shape smaller than a fingertip (under 24 pt) and rest.
5. Write a page of handwriting with your usual pauses at the ends of words.
6. In the zoom window's strip, draw a shape and rest.

**Pass:** shapes straighten only after a rest, into the kind drawn. The first Undo gives your own stroke back and the second removes it. Step 4 and step 6 are left as drawn. Nothing in step 5 straightens.

**Common failures:** a pause at the end of a word turning a letter into a line; a held shape not straightening; Undo removing the stroke at once.

**Tunable:** the rest is 0.45 s (`ShapeSnap.holdDuration`, `OwlLuna/Canvas/ShapeSnap.swift:278`). Too short: letters and ticks you pause on become lines. Too long: you hold and wait and are unsure it took. A rest only counts while the tip stays within 6 pt (`TouchRests.slop`, `:304`); if a steady hold still fails, the tip is drifting further than that. It must be taken within 2 s of lifting (`takeHold(for:within:)`, `:403`). Count, of 20 deliberate holds, how many straightened, and on the handwriting page how many straightened by mistake.

**Evidence:** a screen recording and the counts.

<a id="pencil-8"></a>
### Pencil 8. The zoom window

**Setup:** a ruled notebook and a Pencil. **⋯** › **Zoom Window**.

**Steps:**
1. Write a long sentence in the strip at your usual speed. When the writing reaches the tinted band on the right, lift and rest.
2. Do ten lines at each size, using the strip's **Zoom In** and **Zoom Out**.
3. Write a word that crosses into the band and carry on without stopping.
4. Rest at the end of the line, and at the foot of the page.
5. Drag the outline's tab on the page; try **Move Back Along the Line**, **Move Along the Line**, **Next Line** and **Bring the Zoom Area to This Page**.
6. Turn on Settings › Input › **Left-Handed** and do step 1 again.

**Pass:** the window moves on 0.8 s after the last stroke in the band, never while you are still writing, and what you just wrote stays in view on the left. At the end of a line it goes to the next, and at the foot of the page to the top of the next. With Left-Handed on the buttons are on the left and the band stays on the right. Ink in the strip and on the page match.

**Common failures:** the window moving under the Pencil; writing that runs off the strip before it moves; a move lost at the end of a page.

**Tunable:** the rest is 0.8 s (`ZoomWindow.rest`, `OwlLuna/Canvas/ZoomWindow.swift:13`, used at `OwlLuna/Canvas/PageStack.swift:2686`). Late: you sit with the Pencil up, waiting for it. Jumpy: it moves while you lift between letters or go back to dot an "i". The band is the last 30% of the window (`advanceZone`, `OwlLuna/Canvas/ZoomWindow.swift:9`) and a move is 55% of its width (`stride`, `OwlLuna/Canvas/ZoomWindow.swift:11`). Too narrow a band: you reach the end of the strip first. Too wide: it moves on with room left. For each size, note how many of the ten moves felt late, early or right, your writing hand, and your speed.

**Evidence:** a screen recording of each size, with a phone video of the hand.

<a id="pencil-9"></a>
### Pencil 9. Handwriting to Text with cursive and small writing

This has only read block letters drawn by a test.

**Setup:** tray › **Customise Tools** › **Shortcuts in the Tray** › **Handwriting to Text**. Tap the new shortcut in the tray to turn it on. A ruled page.

**Steps:**
1. Write a sentence in print at your usual size, then stop.
2. Write one in joined-up writing.
3. Write small, on Narrow Ruled, in both.
4. Write with your usual pauses between words; dot the i's and cross the t's after the word.
5. Write a line, then carry on onto the line below.
6. Undo once after a word is set.
7. Turn the shortcut off halfway through a line.
8. Also: **⋯** › **Select Ink Across Pages**, draw round some handwriting and tap **Turn into Text**. Correct a word, then **Copy**, then **Replace Handwriting**.

**Pass:** a sentence becomes one text box that carries on along the line and onto the next, in the pen's colour. One Undo gives the handwriting back and it stays ink. Turning the shortcut off reads what was waiting at once. Count wrong words in every 20, for print, joined-up and small.

**Common failures:** a word set in two pieces; i-dots and t-crosses left as ink beside the text; the first word after turning it on much slower than the rest (Vision warming up; `InkText.warmUp`, `OwlLuna/Canvas/PageStack.swift:2892`).

**Tunable:** the rest is 1.0 s (`InkTyping.pause`, `OwlLuna/Canvas/InkTyping.swift:13`), and reading starts 0.4 s into it (`InkTyping.lookAhead`, `:17`). Too short: a word is set while you pause to think, or its dots arrive after it is set. Too long: you've started the next line before the last is set and it feels late. On a Debug build, compare `-inkTypingPause 0.8` and `-inkTypingPause 1.4` with the default. A phone video shows the time from lift to text; aim for about one second.

**Evidence:** screen recordings of each kind of writing and the counts.

<a id="pencil-10"></a>
### Pencil 10. Selecting PDF text, and the snapping highlighter

**Setup:** notebooks made with **Import PDF…** from three PDFs: plain text in one column, a paper in two columns, and a scanned PDF with no text. Settings › Apple Pencil › **Snap Highlighter to PDF Text** on.

**Steps:**
1. **⋯** › **Select PDF Text**. With the Pencil, drag across words, tap a word, and tap **Select All on This Page**. **Copy**, and paste into Notes. **Highlight** in each **Highlight Colour**.
2. In the two-column PDF, drag along a line in the left column and into the margin.
3. Tap **Done**. Take the Highlighter and draw roughly along a line of text: a little wavy, a little off the line, across two lines. Do it on the scanned PDF too.
4. Undo after a highlighter snaps.
5. Erase a highlight with the eraser.

**Pass:** the selection follows the Pencil letter by letter and doesn't jump lines when it reaches the margin. The copied words are in reading order. A highlight lies over each line. A snapped highlighter stroke is straight, as tall as the line and no wider than the letters it passed over. The first Undo gives your own stroke back. On the scanned PDF the highlighter stays as drawn. The eraser takes a highlight off.

**Common failures:** a selection crossing into the other column; a crash on tapping a word; a snap onto the wrong line; a snap with the setting off.

**Evidence:** a screen recording and the pasted text.

## Hardware and services

<a id="hw-1"></a>
### Hardware 1. Scanning with the camera

**Setup:** three printed sheets: one in small print, one with a table, one creased. Good light and dim light.

**Steps:**
1. In a notebook, **+** › **Scan Documents…**. Allow the camera when asked. Scan the three sheets and save.
2. Undo once, then redo.
3. In the library, **New** › **Scan Documents…** and scan two sheets.
4. Wait a minute, then search the library for a word printed on a scan and open the result.
5. In that notebook, ⌘F (or **⋯** › **Find in Notebook…**) for the same word.

**Pass:** the prompt reads "OwlLuna uses the camera to scan paper into your notebooks." The sheets go in after the current page, straight and cropped, as tall as the paper was, and one Undo removes all three. The library's scan makes a notebook of its own with the first page as its cover. Search finds the word and opens at its page, and Find marks it.

**Common failures:** soft or low-resolution pages (a scan is kept at up to 2,400 px); a page on its side; pages out of order; the printed words never found.

**Evidence:** screenshots of the pages and of the search result.

<a id="hw-2"></a>
### Hardware 2. Face ID and Touch ID on a locked notebook

**Setup:** an iPad with Face ID and one with Touch ID if you can, each with a passcode.

**Steps:**
1. Touch and hold a notebook › **Lock…**. Allow Face ID when iPadOS asks the first time.
2. Tap the locked notebook. Then, in it, go to the Home Screen and come back. Look at it in the app switcher.
3. Fail Face ID or Touch ID on purpose, then use the passcode. Then cancel once.
4. Reach it other ways: a link to it from another notebook, **Open Another Notebook Beside…** and **Open Another Notebook in a Tab…**.
5. Touch and hold it › **Export as PDF**. Then Settings › Backup › **Back Up Library…**.
6. In it, start **Record Audio**, pull down Notification Centre, then go to the Home Screen.
7. Touch and hold it › **Remove Lock…**.
8. Remove the iPad's passcode for a moment and try **Lock…** on another notebook.

**Pass:**
- The prompt reads "OwlLuna uses Face ID to open the notebooks you have locked."
- Every way in asks, and a refusal leaves you outside it. The cover is blurred under a padlock.
- Back from the Home Screen, it shows "“Title” is locked" with **Unlock**, and the app switcher never shows its pages.
- Export and backup ask first.
- The recording carries on while Notification Centre is down and is stopped and saved at the Home Screen.
- Without a passcode: "To lock notebooks, set a passcode on this iPad in Settings first."

**Common failures:** a way in that doesn't ask; pages showing in the app switcher; being asked twice; the recording lost.

**Evidence:** a screen recording, and a photo of the app switcher.

<a id="hw-3"></a>
### Hardware 3. Translation with a language still to download

**Setup:** in iPadOS Settings, find Translate's downloaded languages (Settings › Apps › Translate › Downloaded Languages on iPadOS 18) and remove the one you will use, for example German. Wi-Fi on.

**Steps:**
1. Write a few lines in English. **⋯** › **Select Ink Across Pages**, draw round them, and tap **Turn into Text**.
2. In the sheet, **Translate** › German. Allow the download when iPadOS asks.
3. When it is done, tap **Show Original**.
4. With Wi-Fi off, translate into another language that isn't downloaded; then decline a download.

**Pass:** after the download the words are translated line by line, keeping their lines, with "Translated into German on this iPad." **Show Original** brings back what was read. Offline, or declined, the sheet says it couldn't translate and keeps the original.

**Common failures:** "Translating…" that never ends; lines run together; a crash after the download.

**Evidence:** a screen recording.

<a id="hw-4"></a>
### Hardware 4. The calendar's permission prompt

**Setup:** OwlLuna freshly installed, so it has never asked. Some events today in Calendar, one of them all day; more than ten on another day if you can.

**Steps:**
1. In a notebook, **+** › **Today's Events**. Tap Don't Allow.
2. Allow full access in Settings › Privacy & Security › Calendars › OwlLuna. **+** › **Today's Events** again.
3. Settings › Daily Journal › **Print Today's Events** on. The next day, open today's page (⌘T in the library).
4. If you can, do steps 1 and 2 with OwlLuna in Spanish, French or German (its language is in iPadOS Settings › Apps › OwlLuna).

**Pass:** the prompt reads "OwlLuna reads today's events to print them on a page when you ask it to. They are read on this iPad, and once printed they are part of the notebook." (translated in the other languages). After a refusal: "OwlLuna isn't allowed to read your calendar. Allow it in Settings › Privacy & Security › Calendars." Once allowed, a text box of today's events, all-day ones first, at most ten lines and then "+ N more". The journal's new page starts with that day's events.

**Common failures:** no prompt; a silent failure after a refusal; events from the wrong day; the toggle left on after a refusal.

**Evidence:** screenshots of the prompt and the page.

<a id="hw-5"></a>
### Hardware 5. Transcribing real speech

**Setup:** an iPad that can transcribe English on the device (Settings › Recordings › **Transcription Language** lists only languages it can). A two-minute recording of clear speech and a 60-minute one (a lecture played from another device will do).

**Steps:**
1. In a notebook, **Record Audio** and talk for two minutes while writing notes. Stop.
2. Turn on Airplane Mode. **Recordings** › the speech bubble (**Transcript**) › **Transcribe**. Allow speech recognition when asked. Time it.
3. Read the lines. Tap three lines: the replay starts at each with its ink.
4. Back in **Recordings**, tap **Replay with Ink**: the transcript sits beside the page and marks the line being said.
5. Search the library for a word that was said.
6. Do steps 2 and 3 with the 60-minute recording, and time it.
7. If the sheet's **Language** menu offers a language that Settings › Recordings › **Transcription Language** leaves out (one the iPad can't do on the device), pick it and tap **Transcribe**.

**Pass:** the transcription works in Airplane Mode. Most words are right (estimate the share on the two-minute one). Lines break at sentences, pauses or sixteen words. A tapped line starts within about a second of where those words were said. The long one covers the whole hour, with times that rise through it. Library search finds a word that was said and names the recording. Step 7 says "This iPad can't transcribe … on the device…" and leaves the recording as it is.

**Common failures:** a transcript that stops early; line times spaced evenly through the recording, so tapping a line plays the wrong moment (the recogniser gave no times, and the words were spread evenly); "The recording couldn't be transcribed: …"; words lost before a trailing silence.

**Evidence:** a screen recording with sound, the two times, and a note of a few wrong words.

<a id="hw-6"></a>
### Hardware 6. The study guide from real handwriting and from a long notebook

**Setup:** an iPad with Apple Intelligence on, iPadOS 26 or later. A page of real lecture notes in handwriting, and a long notebook (30 or more handwritten pages, or a long PDF with text). If you can, an iPad without Apple Intelligence.

**Steps:**
1. On the handwritten page, **⋯** › **Study Guide…**, **Write From** › the page. On **Summary**, time how long it takes.
2. **Practice Questions**: time it, and check each answer against the notes.
3. **Add to Page**, and **Save N as Flashcards**.
4. **Write From** › **Whole Notebook** on the long notebook. Time it.
5. **Write From** › a recording with a transcript.
6. Open **Study Guide…** on the iPad without Apple Intelligence, or with it turned off.

**Pass:** the key points match the notes and the questions can be answered from them. Note anything made up. The long notebook finishes; record the time. Without Apple Intelligence the sheet explains why and offers nothing.

**Common failures:** "These notes are too long for the model on this iPad to read at once."; "The model on this iPad wouldn't write about these notes."; a sheet that never finishes; nonsense from misread handwriting (check whether library search finds the page's words, which come from the same reading).

**Evidence:** screenshots of each result and the times. The model reads long notes in pieces of 3,200 characters (`StudyGuide.chunkLimit`, `OwlLuna/Study/StudyGuide.swift:59`).

<a id="hw-7"></a>
### Hardware 7. Lifting a subject out of a photo for a sticker

**Setup:** photos of a pet, a person, a mug on a table, a busy landscape, and a screenshot.

**Steps:**
1. **+** › **Sticker…**, and under My Stickers tap **From Photo…**. Pick the pet. It says "Cutting Out…".
2. Place the new sticker, pinch to 5× and enlarge it.
3. Do it with each photo. For the landscape, expect "No Subject Found" and tap **Use Whole Photo**.

**Pass:** the subject is lifted with a white die-cut edge and no background left, in a few seconds (note how many). It is acceptable at 5×. Where there is no subject, the whole photo is offered.

**Common failures:** a halo or bits of background; ears or fingers cut off; a crash on a large photo; nothing happening.

**Evidence:** screenshots of each sticker.

<a id="hw-8"></a>
### Hardware 8. Control Center buttons and the Action button

**Setup:** open Control Center, tap **+** at the top, then Add a Control, and add OwlLuna's **Quick Note** and **Today's Page**.

**Steps:**
1. Close OwlLuna in the app switcher. Tap **Quick Note** in Control Center.
2. With OwlLuna in the library, tap **Today's Page**.
3. With a notebook open and something just written in it, tap **Quick Note**.
4. With two OwlLuna windows open, tap **Today's Page**.
5. If the iPad has an Action button (Settings › Action Button), set it to one of OwlLuna's controls and press it. If it has none, mark this part as not applicable.

**Pass:** each opens the right thing once: a new quick note, or today's journal page. In step 3 the writing is saved first. In step 4 the front window opens it.

**Common failures:** OwlLuna opening with nothing happening; two quick notes; lost writing.

**Evidence:** a screen recording.

<a id="hw-9"></a>
### Hardware 9. What Spotlight shows

**Setup:** Settings › Search › **Find Notebooks in Spotlight** on. A notebook with an unusual handwritten word, an unusual word in a text box, and a PDF; a locked notebook with an unusual title.

**Steps:**
1. Write the words, tap **Library**, and wait a minute (indexing runs a few seconds after a change).
2. On the Home Screen, swipe down and search for the notebook's title, then the handwritten word, the typed word and a word in the PDF.
3. Tap a result.
4. Search for the locked notebook's title and its words.
5. Rename the notebook and search for the new name. Delete it and search again.
6. Turn the setting off and search again.

**Pass:** a result shows the title, "Notebook, N pages" and the cover. Handwritten, typed and PDF words find it, and a tap opens the notebook. The locked notebook never shows. The new name shows and the old doesn't; a deleted notebook goes; with the setting off nothing shows.

**Common failures:** an old title; a locked notebook found; a tap that only opens the library.

**Evidence:** screenshots of the results; Console `category:spotlight`.

<a id="hw-10"></a>
### Hardware 10. A recording in the background, locked, cut off or interrupted

**Setup:** a passcode on the iPad, and Settings › Display & Brightness › Auto-Lock at 2 minutes. Two notebooks, one of them locked from the library. A Smart Folio or Magic Keyboard cover if you have one, and a second phone to call the iPad. A Debug build for step 8. Talk or play some speech near the iPad throughout.

**Steps:**
1. In the notebook without a lock, **Record Audio** and leave the iPad untouched until it locks itself, then for five minutes more. Unlock, go back to the notebook and Stop. Play the recording through.
2. **Record Audio**, press the top button to lock, and wait two minutes. Unlock and Stop.
3. **Record Audio**, switch to another app that doesn't play sound for two minutes, and come back. Stop. With Stage Manager on, do it again with a second OwlLuna window in front instead of another app, and in that window open another notebook, play one of its recordings, then tap **Record Audio**. Then close the recording window from the app switcher, leaving the other open, and open the notebook it showed.
4. Open the locked notebook, unlock it, **Record Audio** and leave the iPad untouched for three minutes. Then press the top button to lock. Unlock the iPad and the notebook.
5. In the notebook without a lock, **Record Audio**, then call the iPad from the phone (or ask Siri something). End the call and come back. With a cover, record again and close it.
6. **Record Audio**, lock the iPad, wait a minute, then call it from the phone. End the call, wait a minute, and unlock.
7. **Record Audio** for two minutes, then swipe OwlLuna away in the app switcher. Open the notebook again and play the recording.
8. On a Debug build, record for two minutes and stop the app from Xcode. Open the notebook again.

**Pass:** in steps 1 to 3 the system's recording indicator shows while OwlLuna is behind the lock or another app, no notice appears, and each recording is as long as it ran and plays without a gap where the iPad locked or the app changed; in step 1 the iPad locks itself as usual. In step 3 the second window says recordings can't play while another notebook is recording, and that only one notebook can record at a time, and the first window's recording carries on; closing its window leaves "Recording stopped at … when its window was closed." when the notebook opens again. In step 4 the iPad stays awake, and locking it stops the recording with "Recording stopped at … when the notebook locked."; the indicator goes out at the lock. Step 5 leaves "when another app needed the microphone" and "when the iPad's cover was closed". Step 6 leaves "when another app needed the microphone" after unlocking, the recording up to the call is in **Recordings** and plays, and no notice says the notebook couldn't be saved. Steps 7 and 8 show "Recording stopped at … when OwlLuna quit" and the recording plays to where it was cut off. Every recording shares as an `.m4a`.

**Common failures:** "Recording couldn't start: …"; a recording that stops at the lock or the app switch, or a gap in it there; a recording in one window cut short by playing or recording in another; the recording indicator still on after Stop; the iPad locking during step 4, or the locked notebook recording on behind the lock; a recording missing after a stop while locked, or a "Couldn't save" notice after unlocking; a recording missing after a quit, or one listed at 0:00 that won't play; no notice, or a notice that names the wrong time.

**Evidence:** a screen recording of steps 1 to 4 and 6; a screenshot of each notice.

## Windows, screens and keys

<a id="win-1"></a>
### Windows 1. A second screen: the page, the laser and the presenter's notes

This has only been checked with a stand-in window.

**Setup:** a display on a USB-C to HDMI adapter, or an Apple TV (Control Center › Screen Mirroring). Stage Manager off. A notebook with notes on three pages (**⋯** › **Presenter Notes…**) and study tape on one.

**Steps:**
1. Connect the display. The iPad mirrors.
2. **⋯** › **Present** (or ⌥⌘↩).
3. Draw with the Pencil: the laser. **Laser Colour** › green.
4. Pinch on the iPad.
5. Turn pages with the arrows, the space bar and the on-screen bar.
6. Tap the study tape to lift it.
7. Tap **Notes and Next Page** to hide the panel and again to show it.
8. Tap **Done**.
9. Present again, unplug the display, then plug it back in.
10. Turn Stage Manager on and do steps 1 to 3 again. The app only handles a mirrored screen (`OwlLuna/App/OwlLunaApp.swift:15`), so note what happens.

**Pass:** the display shows only the page, on black, and the laser with its fading tail. The iPad keeps the controls and the panel with the next page, the notes, the clock and the time presenting. Zooming on the iPad, the display follows. Lifted tape is lifted there too. The notes never reach the display. After **Done** the display mirrors again, and unplugging doesn't stop the presentation on the iPad.

**Common failures:** a black display; the page cropped or off-centre; a laser that lags; notes on the display; a crash on unplugging.

**Evidence:** a phone video of both screens, and a screen recording on the iPad.

<a id="win-2"></a>
### Windows 2. Two windows together, with a notebook opened in one while a picker is up in the other

**Setup:** an iPad that has Split View and Stage Manager. Notebooks X, Y and Z.

**Steps:**
1. Open a second OwlLuna window side by side in Split View.
2. In window 1, open X. In window 2, open Y and choose **Open Another Notebook in a Tab…** from its title menu. Leave the picker up.
3. In window 1, open Z (from the library, or a tab).
4. In window 2's picker, tap Z.
5. In window 2, go back to the library and tap X's cover.
6. Write in both windows; change the pen in one.
7. Do steps 1 to 6 with Stage Manager, with the two windows overlapping.
8. Close one window from the app switcher.

**Pass:** whatever would open a notebook another window has open brings that window forward with the notebook on show instead (steps 4 and 5), and never opens it twice. A pen chosen in one window is the pen in the other. Writing in both is saved. After step 8 the other window carries on with its notebook.

**Common failures:** the same notebook in two editors at once; a crash; a tab arriving in the wrong window.

**Evidence:** a screen recording.

<a id="win-3"></a>
### Windows 3. Tab shortcuts and ⌘F on a hardware keyboard

In the iPadOS 27 simulator under tests, ⌘F never reached the app (ARCHITECTURE › Known limits).

**Setup:** a hardware keyboard and three tabs open (title menu › **Open Another Notebook in a Tab…**).

**Steps:**
1. ⇧⌘] and ⇧⌘[ to step along the tabs, then ⌃Tab and ⇧⌃Tab.
2. ⌘W to close the tab on show. With one notebook left, ⌘W again.
3. In a notebook, ⌘F, type a word, then ⌘G, ⇧⌘G and Esc.
4. In the library, ⌘F.
5. Without touching the screen first, after opening a notebook: ⌘Z, ⌘N and ⌘F.

**Pass:** each shortcut works once. ⌘W closes the tab while there are tabs and goes back to the library after. ⌘F opens the find bar in a notebook and goes to the search field in the library. Step 5 works without a tap on the page first.

**Common failures:** ⌘F doing nothing; ⌘W closing the window instead of the tab; shortcuts that only work after tapping the page.

**Evidence:** a screen recording.

<a id="win-4"></a>
### Windows 4. Dragging a tab with a finger and with a pointer

**Setup:** four tabs, and a trackpad or mouse.

**Steps:**
1. Drag the first tab to the end of the bar with a finger. Drag one to the middle.
2. Do the same with the pointer.
3. Hold a tab: **Move Left**, **Move Right**, **Close Other Tabs**, **Open Beside**.
4. Drag a tab onto the page and let go.
5. Go back to the library and open a notebook. Then restart the iPad and open the app (closing it in the app switcher would start a fresh window instead).

**Pass:** a tab lands where it is dropped, with no "+" copy badge, and the tab on show stays on show. Dropping it on the page does nothing. The order survives the library and a restart.

**Common failures:** the page scrolling instead; a tab duplicated; a drop ignored; a crash.

**Evidence:** a screen recording.

<a id="win-5"></a>
### Windows 5. A long sitting with many tabs open

**Setup:** a build run or profiled from Xcode, so memory can be watched. Twelve notebooks, the most tabs a window takes (`EditorWindow.tabLimit`, `OwlLuna/Editor/EditorScreen.swift:19`): some pages of the heavy stand-in, a long PDF, some photo pages.

**Steps:**
1. Open all twelve as tabs. Write a few strokes in each.
2. For 30 minutes, step through the tabs with ⇧⌘], writing and undoing in some. Visit the library and come back now and then. Record audio in one tab for five minutes. Send the app to the Home Screen and back twice.
3. Note memory every five minutes.

**Pass:** no crash and no `JetsamEvent` log. Each tab keeps its undo history. Memory levels off rather than climbing with each tab visited. With twelve open, **Open Another Notebook in a Tab…** is greyed out.

**Common failures:** the app ending without a crash log (look for a `JetsamEvent`); a tab that opens blank; undo history lost on coming back to a tab.

**Evidence:** Instruments, Allocations, for the whole 30 minutes; Analytics Data logs.

## Whiteboards

<a id="board-1"></a>
### Whiteboard 1. Writing at 5× and far from the middle of the board

PencilKit has been checked at a board's size in the simulator, written in at 1× and pinched far out, but at 5× only laid out, and never with a Pencil.

**Steps:**
1. In the library, **New** › **Whiteboard**.
2. Write at 1× in the middle. Pinch to 5× and write small.
3. Pinch out as far as it goes (0.15×). Drag with two fingers four or five screens in one direction, then towards a corner. Write there at 1× and at 5×.
4. **Whiteboard** › **Show Everything**, then **Actual Size**.
5. Pan and pinch while the tools are showing.
6. **Back to Pages**, then tap the board's card to open it again.

**Pass:** at every distance and zoom, ink lands under the tip and is sharp once the pinch stops. **Show Everything** fits the middle and the far writing together. Reopening comes back to where you were.

**Common failures:** ink off from the tip, or wobbly, far from the middle; blank tiles; the board jumping when you pinch with the tools out.

**Evidence:** a screen recording; photos at 5× in the middle and far out.

<a id="board-2"></a>
### Whiteboard 2. A board with a great deal of ink

**Steps:**
1. Fill a wide stretch of a board with writing and drawings, then multiply it with **⋯** › **Select Ink Across Pages**, **Duplicate** and drag, as for the stand-in in [Fixtures](#fixtures), until it holds several thousand strokes.
2. Pan, pinch in and out, and **Show Everything**.
3. Leave and reopen the board.

**Pass:** panning and pinching don't stall; **Show Everything** settles within about a second; reopening is quick; memory levels off.

**Common failures:** stalls when crossing into new tiles; a long wait opening the board; memory that keeps climbing.

**Evidence:** Instruments, Animation Hitches, 30 seconds of panning; then Allocations over a minute of panning and pinching.

<a id="board-3"></a>
### Whiteboard 3. Time-lapse, find and presenting on a board

**Steps:**
1. On the board from [Whiteboard 1](#board-1), title menu › **Export** › **This Page as a Time-lapse Video…**.
2. ⌘F for a handwritten word written far from the middle.
3. With a display connected, **Present** the board ([Windows 1](#win-1)).

**Pass:** the video shows the part of the board with ink on it, written in order, at most twenty seconds long. Find marks the word in the right place and brings it into view. Presenting shows that part of the board on the display, with the laser.

**Common failures:** a video of empty board, or of only part of the ink; a find mark in the wrong place; a blank display.

**Evidence:** the video file; a screen recording; a phone video of the display.

## Measurements

The simulator can't measure hitches, and its memory figures leave out graphics memory (ARCHITECTURE › Measurements), so every figure here is still to be taken.

<a id="measure-1"></a>
### Measure 1. Scroll hitches in Instruments

**Setup:** a 120 Hz iPad Pro. Product › Profile (Release). In the library: 500 notebooks (`-seedLibrary 500` on a Debug run first, see [Fixtures](#fixtures)), a 300-page PDF (`-seedLongPDF`, or any long PDF) and the heavy stand-in.

**Steps:**
1. Instruments › Animation Hitches. Record 30 seconds of flicking the library from top to bottom and back.
2. The same in the 300-page PDF, in the heavy stand-in, and in each at 5×.

**Pass:** a hitch time ratio under 5 ms per second, which Apple counts as good, with no single hitch you can see.

**Common failures:** hitches as new pages come into view (thumbnails, ink loads, tiles); hitches at the end of a pinch (the zoom being baked).

**Evidence:** the `.trace` files, and a note of the hitch ratio and the worst hitch for each. On a Debug build, `-framePacing` adds a small readout of long frames (`OwlLuna/App/DebugProbes.swift:9`); its numbers carry Debug's costs, so use it only to compare.

<a id="measure-2"></a>
### Measure 2. Memory at 5× with the heavy fixture

**Steps:**
1. Run the heavy fixture's unit test on the iPad ([Fixtures](#fixtures)) and keep the two `PERF v2 memory` lines.
2. Product › Profile › Allocations, with the heavy stand-in. Scroll the whole notebook, pinch to 5×, and scroll through ten pages there. About three minutes.
3. Do it once more on the 300-page PDF.

**Pass:** memory levels off while scrolling and at 5×, with no `JetsamEvent` and no memory warning ending the session. Compare with the simulator's figures in ARCHITECTURE (heavy: 516 MB scrolling, 520 MB at 5×, without graphics memory).

**Common failures:** memory climbing page by page (a cache not bounded); the app ending at 5×.

**Evidence:** the test's output, the `.trace` files, and the peak for each.

<a id="measure-3"></a>
### Measure 3. The undo budget against a memory trace

Undo keeps whole-page drawings. The number of steps is 48 MB divided by the heaviest page's saved ink, kept between 20 and 200 (`UndoBudget`, `OwlLuna/Editor/NotebookDocument.swift:45` to `:52`), set after each save (`:705`). It is an estimate from the size on disk; in memory a drawing may take more.

**Steps:**
1. Find the size of a heavy stand-in page's ink file: Download Container (see [Evidence](#evidence)) and look at `ink/<page id>.pkdrawing` in its package. The steps it should allow are 48 MB divided by that size, kept between 20 and 200.
2. Product › Profile › Allocations. Open that page.
3. Mark a generation. Make ten more strokes than the steps it should allow, a second or two apart, so saves run between them.
4. Mark a generation. Tap **Undo** (or ⌘Z) until it greys out, counting the steps.
5. Do steps 3 and 4 on a light page with 30 strokes.

**Pass:** on the heavy page the count is the number worked out in step 1, and the last ten strokes can't be undone. On the light page all 30 can. The memory that grew in step 3 is no more than about twice the count times the file size. More than twice means the budget counts too little and should use a drawing's size in memory.

**Common failures:** far more growth than the estimate; the count of steps not matching the page's size.

**Evidence:** the `.trace` file, the step counts and the page's file size.
