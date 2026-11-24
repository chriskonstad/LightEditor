---
name: release
description: Ship a LightEditor version — bump the version, write the release notes, upload iOS and Mac builds to TestFlight, submit both to App Store review, and tag the release on GitHub. Use for "release 1.0.6", "ship this to the App Store", "submit to the store", "upload a TestFlight build", or "tag the release".
---

# Releasing a version

One version ships both platforms: iPhone/iPad and the Mac, from the same commit and
the same release notes. Work top to bottom; each step says what to check before moving on.

## 1. Version and notes

- Bump `MARKETING_VERSION` in `project.yml`. It's set once at project level so the app
  and the share extension always match; never put it on a target.
- Add the version's notes to `docs/app-store/listing.md` as a fenced block under
  `## What's New (<version>)`. That block is the single source: `scripts/submit-app-store.py`
  sends it to App Store Connect and `scripts/tag-release.sh` puts it in the GitHub release.
  - No price words ("free" in the Mac subtitle was rejected under guideline 2.3.7) and no
    camera brand names.
  - The Mac uses the same notes, so say so in the bullet when a feature is iPhone/iPad only.
  - Write what the user sees, and give a fix its own bullet starting "Fixed:".
- Commit the bump and the notes **before** archiving, so the tag can point at the commit
  the builds came from.

## 2. Test

```sh
scripts/test.sh
```

Performance numbers only count from real devices; the Simulator is fine for logic and UI.

## 3. Upload the builds

```sh
scripts/testflight.sh          # iPhone and iPad; also sends it to the external "Friends" group
scripts/testflight.sh --mac    # the Mac
```

Build numbers are timestamps, printed as it archives. Read one back from an archive with:

```sh
/usr/libexec/PlistBuddy -c "Print :ApplicationProperties:CFBundleVersion" build/release/LightEditor-macOS.xcarchive/Info.plist
```

**Export failures are normal and fixable.** After a new target, capability or entitlement,
and for the first Mac export after signing changes, the export step fails with
"Cloud signing permission error", plus "No profiles for …" or "No signing certificate
'Mac App Distribution' found": the App Store Connect API key can't create cloud-managed
profiles or certificates. The archive is already in `build/release`, so don't re-archive —
re-run just the export with the Apple ID signed in to Xcode (no API key):

```sh
xcodebuild -exportArchive -archivePath build/release/LightEditor-macOS.xcarchive -exportPath build/release/export -exportOptionsPlist build/release/ExportOptions.plist -allowProvisioningUpdates
```

The plist says `destination upload`, so this uploads too. Later runs of `scripts/testflight.sh`
work again, because the profile and certificate now exist.

Don't use `--internal-only` for a build meant for the App Store: TestFlight-internal builds
can't be attached to a version.

## 4. Submit to the App Store

```sh
scripts/submit-app-store.py ios 2611221339
scripts/submit-app-store.py macos 2611232015
```

Each run waits for processing, creates that platform's version if needed, sets its
"What's New" from the listing, attaches the build and submits it. The release type is
"after approval", so an approved version goes live on its own. The script is safe to
re-run and refuses a version that is already in review or on sale.

## 5. Tag it on GitHub

```sh
scripts/tag-release.sh <version> <commit> "iOS build <n>, Mac build <n>"
```

`<commit>` is the one the builds were archived from. This pushes `v<version>` and creates
the GitHub release with the same notes. The maintainer asked for this on every release, so
it needs no separate yes.

## 6. Finish up

- Add a line to the release checklist at the end of `docs/app-store/review-risks.md`
  saying what was submitted, with both build numbers and the date.
- Commit, and push `main` to its remotes.
- Tell the user both build numbers, and that TestFlight reaches their phone in 5–15 minutes
  while App Store review takes longer.

## Checking state without the App Store Connect website

`scripts/asc.py` is the shared API client. For a one-off query:

```sh
python3 -c "
import sys; sys.path.insert(0, 'scripts')
import asc; asc.load_env()
print(asc.call('GET', f'/v1/apps/{asc.APP_ID}/appStoreVersions?limit=4&fields[appStoreVersions]=versionString,appStoreState,platform')[1])"
```
