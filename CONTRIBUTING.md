# Contributing to OwlLuna

Thanks for helping make a great free notes app. Everyone taking part is expected to follow the [Code of Conduct](CODE_OF_CONDUCT.md).

## Workflow

1. Open an issue first for anything larger than a small fix, so we can agree on the approach.
2. Fork the repo and create a branch from `main`.
3. Keep pull requests focused on one change.
4. Make sure the app builds without warnings and the tests pass (⌘U).
5. Include iPad screenshots or a short screen recording for UI changes, in portrait and landscape, light and dark.

## Code style

- Swift + SwiftUI, with UIKit only where PencilKit needs it (`Canvas/`).
- Match the surrounding code: small types, descriptive names, and minimal comments. Code should explain itself; use a short comment only when the *why* isn't obvious.
- New source files are picked up automatically. The project uses folder-synchronized groups, so just add the file to the right folder.
- Put page-geometry logic in `NotebookLayout` / `PageRemapper` and cover it with unit tests.
- Don't add third-party dependencies without discussing it in an issue first. The app deliberately relies only on Apple frameworks.

## Privacy

OwlLuna collects no data. Please don't add analytics, tracking, ads, or network calls that send user content anywhere.

## Reporting bugs

Use the bug report form in [GitHub Issues](https://github.com/owaisazmal/OwlLuna/issues/new/choose). Include your iPad model, iPadOS version, the app's version and build, steps to reproduce, and what you expected versus what happened. For drawing bugs, say whether you were using Apple Pencil or a finger.

Issues are public. Report a security problem, or a privacy question about your own notes, privately instead: see [SECURITY.md](SECURITY.md).
