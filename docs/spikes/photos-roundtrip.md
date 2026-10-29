# Spike M0.4: Photos round trip

Status: **single-device round trip works in the simulator; cross-device sync still to test on real devices.**

## What works (iOS 27 simulator, local test library)

1. Import: `PHAssetCreationRequest` with the ARW or RAF as the `.photo` resource creates a RAW asset, which shows up in the RAW smart album. RAW+JPEG pairs import as one asset, with the RAW as `.alternatePhoto` (`PhotoImporter`).
2. Edit: `requestContentEditingInput` → render a full-size HEIC → `PHContentEditingOutput.renderedContentURL(for: .heic)` plus `PHAdjustmentData`:
   - format `app.raweditor.recipe`, version `1`;
   - data: zlib-compressed recipe JSON.
3. After saving, the asset's UTI becomes `public.heic`, its size matches the crop (e.g. 6338×6336 for a straightened square crop of a 9504×6336 ARW), and the library grid shows the edit.
4. Reopening reads our adjustment data back (`canHandleAdjustmentData`) and re-renders from the original RAW: crop, straighten and presets all came back.
5. Bulk edits commit several `PHAssetChangeRequest`s in one `performChanges`, so iOS asks for permission once per batch rather than once per photo.

## Size limit

A recipe with every HSL band set plus a curve, crop, LUT and wheels encodes to **well under 4 KB** after zlib (`RecipeTests.adjustmentDataIsCompressedAndSmall`). Apple doesn't document a hard limit for `PHAdjustmentData`. Masks (V1) will be stored as vector recipes, so the data should stay small. The practical ceiling is still to be measured.

## Still to test on devices

- iCloud sync of the edit to the iPad and the Mac, and reopening there.
- "Revert" in Photos clearing our adjustment data (the app's own Revert uses `revertAssetContentToOriginal`).
- The per-edit permission prompt iOS shows when an app modifies a photo. The simulator didn't show one.
- `PHAsset.originalResourceChoice` (new in OS 27) for RAW+JPEG pairs: the app currently always edits the RAW when there is one.
