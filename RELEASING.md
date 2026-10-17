# Releasing OwlLuna

A checklist for each new build. Run the commands from the repository's root. The examples cut 1.0.1 (build 3); put in your own numbers.

## Version numbers

- `MARKETING_VERSION` is the version testers see, such as 1.0.1.
- `CURRENT_PROJECT_VERSION` is the build. It goes up by one for every upload and is never used twice.
- The tag is `v` and the version in three numbers, so version 1.0 is tagged `v1.0.0`.

## 1. Bump the version

In Xcode, open the project's settings. In General › Identity, set Version and Build on the **OwlLuna** target and on the **OwlLunaWidgets** target. Both targets must have the same numbers, or the upload is turned away.

Check them:

```bash
for t in OwlLuna OwlLunaWidgets; do xcodebuild -project OwlLuna.xcodeproj -target "$t" -configuration Release -showBuildSettings 2>/dev/null | grep -E ' (MARKETING_VERSION|CURRENT_PROJECT_VERSION) = '; done
```

## 2. Update the changelog

In [CHANGELOG.md](CHANGELOG.md), move what is under Unreleased into a new section, `## [1.0.1] (build 3) - YYYY-MM-DD`, and leave Unreleased empty. Add its link at the bottom and point Unreleased at the new tag:

```
[Unreleased]: https://github.com/owaisazmal/OwlLuna/compare/v1.0.1...HEAD
[1.0.1]: https://github.com/owaisazmal/OwlLuna/compare/v1.0.0...v1.0.1
```

Commit the bump and the changelog. Archive from that commit with nothing else changed, so the tag matches the build exactly.

## 3. Check that it archives

Push `main`, then run the Release workflow from the Actions tab (Release › Run workflow). It archives a Release build without signing and keeps the archive as an artifact. Or run the same check on the Mac:

```bash
xcodebuild archive -project OwlLuna.xcodeproj -scheme OwlLuna -configuration Release -destination 'generic/platform=iOS' -archivePath "$TMPDIR/OwlLuna.xcarchive" CODE_SIGNING_ALLOWED=NO
```

## 4. Archive and upload from Xcode

1. Set the run destination to Any iOS Device (arm64).
2. Choose Product › Archive.
3. In the Organizer, choose Distribute App, then TestFlight & App Store, and upload.
4. In App Store Connect › TestFlight, wait for the build to finish processing.
5. Set What to Test for the build. A short form of the changelog section is enough.
6. Add the build to the external testing group. The first build of a new version waits for Beta App Review.

The app says it uses no non-exempt encryption (`ITSAppUsesNonExemptEncryption` is NO), so there is no export question to answer.

## 5. Tag the release

```bash
git tag -a v1.0.1 -m "OwlLuna 1.0.1 (build 3)"
```

```bash
git push origin v1.0.1
```

Pushing the tag runs the Release workflow on that commit. It fails if the tag doesn't match the app's version, or if the widgets' numbers differ from the app's.

## 6. Publish the GitHub Release

This needs the GitHub CLI, signed in once:

```bash
brew install gh
```

```bash
gh auth login
```

Take the version's section of the changelog as the notes:

```bash
awk '/^## \[1\.0\.1\]/{on=1; next} on && /^## \[/{exit} on' CHANGELOG.md > "$TMPDIR/notes.md"
```

```bash
gh release create v1.0.1 --verify-tag --title "OwlLuna 1.0.1 (build 3)" --notes-file "$TMPDIR/notes.md"
```

Add `--prerelease` while a version is only on TestFlight.

## Later: upload from CI

The Release workflow doesn't sign or upload, so it needs no secrets. Uploading from CI would need:

- An App Store Connect API key (App Store Connect › Users and Access › Integrations), with a role that may use cloud-managed signing.
- Its key ID, issuer ID and `.p8` file stored as repository secrets, for example `ASC_KEY_ID`, `ASC_ISSUER_ID` and `ASC_KEY_P8`.
- The archive step run without `CODE_SIGNING_ALLOWED=NO`, with `-allowProvisioningUpdates` and the key passed through `-authenticationKeyPath`, `-authenticationKeyID` and `-authenticationKeyIssuerID`.
- An `xcodebuild -exportArchive` step with an export options file whose method is `app-store-connect` and destination is `upload`.
- A GitHub environment with a required reviewer, so a pushed tag can't upload without approval.
