# Spike: open a photo from Apple Photos in LightEditor

Status: **built as a share extension that hands the photo to the app, on iOS and (2026-11-27) the Mac, plus Image › Edit With on the Mac. Works in the iOS 27.0 simulator and against a folder library on the Mac; not yet tried from Photos on a device or a real Mac library.**

The goal: a photo selected in the Photos app opens in LightEditor's editor, without finding it again in LightEditor's library. Edits still save non-destructively through `PhotoKitLibrary` (`PHContentEditingOutput` plus our `PHAdjustmentData`), so the recipe stays the source of truth.

## Options compared

| | Photo Editing Extension | Share extension (chosen) | Action extension | App Intent with a `PHAsset` |
| --- | --- | --- | --- | --- |
| Where it appears | Photos › Edit › ⋯ | Share sheet, app row ("LightEditor") | Share sheet, action list | Shortcuts and Siri only |
| What Photos hands over | A `PHContentEditingInput`: a rendered image (`fullSizeImageURL`), no local identifier | Rendered copies (HEIC and JPEG), no local identifier | The same as a share extension | The `PHAsset` itself (new in OS 27) |
| Can it open the full app? | No, editing happens inside the extension | Yes (see below) | Yes, the same way | Yes (`supportedModes = .foreground`) |
| Memory | Extension limits. A 61 MP RAW 9 save peaks around 1.4 GB, far over them | The app's own budget | The app's | The app's |
| RAW and RAW+JPEG | Edits the rendered image, not the RAW | Matched back to the asset, so the app edits the RAW | The same | Exact asset |
| Mac | Photos for Mac has editing extensions | Photos for Mac has share extensions too (not built yet) | The same | Shortcuts on the Mac |
| Verdict | A second, weaker editor inside Photos | **One tap from Photos into the real editor** | Less visible than the app row | No way to start it from a photo without a user-made shortcut |

Nothing newer in the iOS 27.1 SDK covers this. No new "open in" or "edit with" extension point exists. The PhotoKit additions are ratings, keywords, captions, upload jobs, a persistent change observer and `PHAssetResource.filename`. The one relevant change is that `_Photos_AppIntents` makes `PHAsset` an App Intents value type (`_SystemIntentValue`), so an intent can take a library photo as a parameter.

## What the simulator showed (iOS 27.0, local test library)

A probe share extension, sharing one photo from Photos:

- **Item provider:** `public.heic` and `public.jpeg`, no `suggestedName`. The files are `…/PhotoData/OutgoingTemp/<UUID>/DSCF2030.heic` and `…/Compatible/DSCF2030.jpeg`. They're named after the original's filename (`DSCF2030.raf`), not the library's (`IMG_0012.RAF`). The `<UUID>` is new for each share; it isn't the asset's UUID.
- **Metadata:** the shared copy of an unedited photo keeps the camera's EXIF, including `DateTimeOriginal` and its pixel size (7728×5152 for the X-T5 RAF).
- **Edited photos:** Photos shares the render saved with the edit as it is. Until now LightEditor's renders had no EXIF, so the shared copy had no capture time and couldn't be matched. Renders now carry the original's capture metadata, but never its location (`Exporter.carriedMetadata`).
- **RAW:** Photos renders the photo before handing it over. A 61 MP ARW showed "Preparing…" for a few seconds in the simulator.
- **Photos access:** the extension reports `.authorized`, sharing the app's authorization. It doesn't need access: the app does the matching.
- **Opening the app:** `NSExtensionContext.open(_:)` returns `false`. Apple documents it for widgets only. `UIApplication.shared` is unavailable in extensions. The `UIApplication` object is in the extension's responder chain, though, and `open(_:options:completionHandler:)` isn't marked extension-unavailable. Calling it opens `lighteditor://edit?…`, from a warm start and from a cold launch.

## How it works

1. **Share extension (`ShareExtension/`).** It reads the shared copy's filename, `DateTimeOriginal`, `OffsetTimeOriginal` and size into a `SharedPhoto`. Then it opens `lighteditor://edit?name=dscf2030&taken=2025:01:31%2021:15:41&size=7728x5152` (`PhotoHandoff`) and closes. It touches no Photos API.
2. **App (`AppModel.open(_:)`).** It parses the URL. The library's `SharedPhotoLookup` returns photos created at that capture time. EXIF times without an offset are local, so any real time zone counts: a whole number of quarter hours from UTC, within ±1.5 s. `SharedPhotoMatcher` keeps the photos whose resource filenames (both halves of a RAW+JPEG pair) or size agree best. It opens the first match in the editor. If the request arrives before library access, it waits until access is granted.
3. **Editing is unchanged.** `beginEditing` and saving go through `PhotoKitLibrary`, so the RAW original, our adjustment data and Revert in Photos all behave as before.

Edge cases:

- **Identical copies** (the same file imported twice) can't be told apart. The editor opens the first, with a toast saying so.
- **No capture time** (some screenshots and downloads, or a LightEditor edit saved before 1.0.5): the extension says it can't find the photo. Saving the edit again from LightEditor fixes the old edits.
- **Limited library access:** if the photo isn't in the selection, a toast points to Settings.
- **Another device's library** (remote editing): the app switches back to this device's library first, since Photos shared a local photo.

## The Mac (2026-11-27)

- **Share › Edit in LightEditor.** The same extension target builds for macOS (`supportedDestinations: [iOS, macOS]`), with an AppKit `ShareViewController` that does the same handoff and opens the link with `NSWorkspace.shared.open`, which extensions may use on the Mac. It's sandboxed (Mac extensions must be) and only reads the shared file. `pluginkit` lists it under `com.apple.share-services` once the app has run; Photos may need it switched on in System Settings › General › Login Items & Extensions › Sharing.
- **Image › Edit With › LightEditor** (and Finder's Open With). Photos lists apps that open the photo's type, so the Mac app declares RAW, JPEG, HEIC, TIFF and PNG (`App/Resources/Info-macOS.plist`, role Editor, rank Alternate so it's never the default). A file handed over goes through the same matcher (`AppModel.openFile`), so the library photo opens and is edited the usual way, with our adjustment data; the handed-over copy isn't changed, so Photos sees no external edit to import. To verify on a real library: that Photos doesn't hold the photo in an external-edit state that conflicts with the PhotoKit save.
- **Tests.** `MacOpenFromPhotosTests` hands the app a fixture file (as Edit With does) and a share link, and checks the matching photo opens, against the folder library, which implements `SharedPhotoLookup` the same way. No Photos library is involved.

## Risks

- **App Review.** Reaching `UIApplication` through the responder chain uses only public API, and it's a common workaround for share extensions. Apple's guidance is still that only widgets open their app, so a reviewer could object. If `open` ever fails, the extension shows "Open the app and choose the photo there" instead of doing nothing.
- **A different second or name.** If Photos ever shares under another name, size still decides. If a photo's date was changed in Photos, the shared copy carries the new date too (to verify on a device).

## Spike questions

- Does a Shortcuts share-sheet shortcut pass a Photos selection to an App Intent's `PHAsset` parameter? If so, an "Edit in LightEditor" intent would identify the asset exactly, with no matching.
- A Mac share extension: Photos for Mac's share menu, opening the app with `NSWorkspace`. A Mac forum thread reports Photos on macOS 26 sharing only a temporary file, which is all the matcher needs.
- On a device: the "Preparing…" time for a 61 MP RAW from iCloud (Photos may download the original first), and whether "Options › All Photos Data" changes what's shared.
