# Security

OwlLuna keeps your notes on your iPad, and in your own iCloud if you turn sync on. If you find a way for them to reach anyone else, or a way past a notebook lock, please report it privately.

## Supported versions

Fixes go into the current build only: the latest TestFlight build for now, and the latest App Store version once the app is published there. If you're on an older build, update first and check that the problem is still there.

## How to report

Don't report a security problem in a public issue. Use GitHub's private reporting instead:

1. Open this repository's [Security](https://github.com/owaisazmal/OwlLuna/security) tab.
2. Choose **Report a vulnerability**.
3. Say what you did and what happened, with your iPad model, iPadOS version, and the app's version and build.

Posting needs a free GitHub account. Only you and the developer can read the report. Leave out any notes you'd rather not share: a new notebook that shows the problem is just as good.

## What to report here

- **Notebook locks and Face ID:** a locked notebook that opens, or shows its pages, without Face ID, Touch ID or the iPad's passcode.
- **Backups:** a backup made from a library with locked notebooks without asking you to unlock first, or a backup file from someone else that does harm when you restore it.
- **iCloud sync:** anything copied to iCloud before you allowed sync, writing history being synced, or notes going anywhere but the app's private container in your own iCloud.
- **Widgets, Spotlight and exports:** a locked notebook's title, cover or pages in a widget or in Spotlight, its name offered to Siri and Shortcuts, a widget showing a title or cover while the iPad is locked, or an export or share that holds more than you chose.
- **Privacy questions about your own notes:** what the app keeps, where it keeps it and who can read it, when asking in public would mean showing your notes.

These are not security problems:

- A lock doesn't encrypt a notebook's files beyond what iPadOS does for every app, and a backup or an iCloud copy holds a locked notebook like any other. That's by design, and the [Support page](https://owaisazmal.github.io/OwlLuna/support/#locks) says so.
- Problems in iPadOS, iCloud or Face ID themselves go to [Apple](https://security.apple.com).
- Crashes and other bugs that don't expose your notes go in [GitHub Issues](https://github.com/owaisazmal/OwlLuna/issues), with the bug report form.

## What happens next

OwlLuna has one developer, who works on it alongside other things. The aim is a first reply within two weeks. How long a fix takes depends on the problem. You'll hear how it's going in the report, and before anything about it is made public.

Please don't talk about the problem in public until a fix is out. If you'd like to be credited in the advisory, say how you'd like to be named.
