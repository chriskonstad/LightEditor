# Spike: a saved image smaller than the original

**Question.** Does Photos accept an edit whose rendered image is smaller than the original, and does everything that reads the photo still work?

**How.** `-PhotosCopySpike YES` (Debug builds, `App/Shared/PhotosCopySpike.swift`) takes the first RAW in the library, saves an edit through `PHContentEditingOutput` with a 12 MP HEIC at quality 0.8, reads it back, reverts, and saves again. It logs `SPIKE` lines. Run on the iPad 13 simulator (iOS 27.0) with an A7R V ARW (9504 × 6336) imported through `-ImportFolder`.

**Result: it works.**

| Check | After the 12 MP save | After revert |
| --- | --- | --- |
| `PHAsset.pixelWidth × pixelHeight` | 4243 × 2829 | 9504 × 6336 |
| Resources | ARW 68.6 MB, `Adjustments.plist`, `FullSizeRender.heic` 3.7 MB | ARW only |
| `requestImageDataAndOrientation` (what sharing gets) | the 4243 × 2829 HEIC, 3.7 MB | the ARW |
| `requestImage` at `PHImageManagerMaximumSize` | 4243 × 2829 | — |
| Our adjustment data on the next editing input | present | none |

Photos showed the photo normally, and its Info panel read "12 MP · 4243 × 2829 · 68.6 MB · Saved from LightEditor". Saving again after the revert worked the same way. The editing input's `fullSizeImageURL` is the original ARW either way, which is what the editor decodes.

**Caveat.** Anything that reads the edited photo (Photos' zoom, sharing, other apps) sees the smaller image; only LightEditor goes back to the original. That's the trade-off the setting offers, so it stays the user's choice, with full size as the default.

Not checked: iCloud sync between devices (the simulator has no iCloud Photos), and the Mac's Photos app.
