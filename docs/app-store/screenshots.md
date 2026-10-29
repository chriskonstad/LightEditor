# Screenshot plan

Capture everything from simulators (iPhone, iPad) and a Debug Mac build with a folder library, using sample photos, **never a real Photos library**. See `docs/spikes/simulator-tooling.md` for importing RAWs (`-ImportFolder`) and the Mac folder library (`-FixtureLibrary`).

## Photos to use

- Your own shots only, so you own the rights. Landscapes, cityscapes, food and architecture work best.
- No identifiable strangers, faces, license plates, race bibs or house numbers. For the people-mask shot, use a photo of someone who has agreed, or a back-turned or distant figure.
- At least one ARW, one RAF and one ProRAW DNG, so the library shows a mix of cameras.
- One photo with an obvious distraction (sign, trash can, tourist in the distance) for the removal shot.

## Sizes

| Platform | Simulator / setup | Size (portrait unless noted) | Required |
| --- | --- | --- | --- |
| iPhone 6.9" | iPhone Pro Max simulator | 1320 × 2868 (or 1290 × 2796) | Yes; App Store Connect scales it for smaller iPhones |
| iPad 13" | iPad Pro 13-inch simulator | 2064 × 2752 (or 2048 × 2732); landscape is fine | Yes, since the app runs on iPad |
| Mac | Debug build, window sized to 1440 × 900 points on a Retina display | 2880 × 1800 (16:10) | Yes, for the Mac version |

Capture iOS screenshots with `xcrun simctl io <udid> screenshot shot.png`, with the status bar cleaned first:

```sh
xcrun simctl status_bar <udid> override --time 9:41 --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3
```

## The set (same story on each platform, up to 10 allowed)

| # | Screen | Caption (optional overlay text) |
| --- | --- | --- |
| 1 | Editor on a colorful RAW, Light panel open, before/after split dragged to the middle | Edit RAW photos. No subscription. |
| 2 | Color panel with the HSL mixer, or Grade with the color wheels | Precise color, built for touch |
| 3 | Masks: AI sky mask selected with its overlay, then a warm/cool adjustment | One-tap AI masks for sky, subject and people |
| 4 | Retouch: before and after of a distraction removed with "LaMa + diffusion" (two captures, side by side) | Remove distractions on device |
| 5 | Library grid with a selection and the paste-groups sheet, or the bulk edit sheet | Edit a whole trip at once |
| 6 | Presets tab with film-inspired looks and the Amount slider | Presets, film looks and LUTs |
| 7 | iPad: Devices screen editing the iPhone's library (iPad set only); iPhone/Mac: the job tray with a running export | Edit your iPhone's photos on your iPad |
| 8 | Privacy card: plain background with "No account. No tracking. Your photos stay on your device." | Private by design |

Notes:

- On iPad, the side-by-side workspace (filmstrip, photo, panel) in landscape reads best.
- For the remote-editing shot, run two simulators: share from the iPhone simulator; the iPad simulator lists "Simulator on this Mac".
- Keep captions short and consistent. Plain screenshots without overlays are also fine for App Review.
- Don't show trademarked film simulation names prominently in captions; showing them inside the preset list is OK.

| iPhone Duo | iPhone Duo simulator (Xcode 27.1), unfolded | 2007 × 2853 inner screen, or 2853 × 2007 sideways | Optional now; required for submissions from April 2027. Filling it shows "optimized for iPhone Duo". |

Unfold the Duo with the Open pose button in its Device Hub window (simctl has no fold command), and capture with the Claude simulator tool: `simctl io screenshot` returns the inner screen black.

## App preview video (optional)

A 15–30 s screen recording per platform: drag exposure and a color wheel, tap an AI sky mask, paint a removal. `xcrun simctl io <udid> recordVideo preview.mov`. Skip for the first release unless you want it.

## Captured for 1.0 (2026-10-28)

From an iPhone 18 Pro Max simulator (1320 × 2868) and an iPad Pro 13-inch (M5) simulator in landscape (2752 × 2064), both running a folder library of the test fixtures (`-FixtureLibrary`). Saved in `build/screenshots/` (git-ignored); README images are in `docs/images/`.

- iPhone: Light (Auto), Grade wheels, Color/HSL mixer, mask picker, presets, Settings.
- iPad: Light, Grade, mask picker, presets.
- iPhone Duo (unfolded, iOS 27.1 simulator): editor sideways with the inspector beside the photo, editor upright, Grade sideways.

Not capturable in the Simulator: AI masks (Vision segmentation fails there) and a clean removal (LaMa fills look smeared on the Simulator's CPU path). Add those from a real device in a later update.
