# Security

OwlLuna keeps your notes on your iPad, and in your own iCloud if you turn sync on. If you find a way for them to reach anyone else, or a way past a notebook lock, please report it privately.

## Supported versions

Fixes go into the current build only: the latest TestFlight build for now, and the latest App Store version once there is one. On an older build, update first and check the problem is still there.

## How to report

Don't use a public issue. Use GitHub's private reporting:

1. Open the repository's [Security](https://github.com/owaisazmal/OwlLuna/security) tab.
2. Choose **Report a vulnerability**.
3. Say what you did and what happened, with your iPad model, iPadOS version, and the app's version and build.

You need a free GitHub account. Only you and the developer can read the report. Leave out notes you'd rather not share; a new notebook that shows the problem is just as good.

## What to report here

- A locked notebook that opens, or shows its pages, without Face ID, Touch ID or the passcode.
- A backup of a library with locked notebooks made without asking to unlock, or a backup file that does harm when restored.
- Anything copied to iCloud before you allowed sync, writing history being synced, or notes going anywhere but the app's private container in your iCloud.
- A locked notebook's title, cover or pages in a widget or Spotlight, its name offered to Siri, a widget showing a title or cover while the iPad is locked, or an export that holds more than you chose.
- Privacy questions about your own notes, when asking in public would mean showing them.

Not security problems:

- A lock doesn't encrypt a notebook's files beyond what iPadOS does for every app, and backups and iCloud copies hold locked notebooks like any other. That's by design, and the [Support page](https://owaisazmal.github.io/OwlLuna/support/#locks) says so.
- Problems in iPadOS, iCloud or Face ID go to [Apple](https://security.apple.com).
- Crashes and bugs that don't expose your notes go in [GitHub Issues](https://github.com/owaisazmal/OwlLuna/issues).

## What happens next

OwlLuna has one developer, working on it alongside other things. Expect a first reply within two weeks. You'll hear how it's going in the report, and before anything is made public.

Please keep the problem private until a fix is out. If you'd like credit in the advisory, say how you'd like to be named.
