# UI Spec

This spec comes from the mocks at https://claude.ai/artifact/RWe7rQCDhk5K45MKNW6h1U. Where the mocks and this file disagree, this file wins.

## Visual language

- **Dark UI**, because photo editing needs a neutral, dim surround:
  - Ground `#0E0F11`
  - Panels `#141518` and `#1A1B1F`
  - Dividers `#23252A`
- **Text:** primary `#ECECEC`, secondary `#9DA1A8`.
- **One accent:** amber `#E8A33D`, used for selection, primary actions, slider fill and progress. Text on amber is `#1A1206`.
- **System font** (SF). Use tabular numerals for all values.
- **Native controls** where a system control fits: segmented tab pickers, standard sheets and menus. Editing sliders and color wheels are custom (see "Adjusting values"), because the system slider can't do fine adjustment, hold-to-compare or double-tap reset.
- **Touch targets** are at least 44 pt on iPhone and iPad.

## Shared behaviors

- **Open a photo:** show the embedded preview instantly, then swap in the RAW 9 render when it's decoded.
- **Job tray:** a pill in the toolbar showing a spinner and job count. Tapping it opens a popover listing each job with a label, progress bar and cancel.
  - **Open question:** is the pill always visible, or only while jobs run? The current mock shows "No jobs running" on the Mac.
- **RAW-stage changes** (Detail tab): the status reads "Re-decoding RAW 9", a thin progress line runs under the photo, and the old render stays on screen until the new one is ready.
- **Compare:** a toggle shows the original with a "Before" badge. On Mac, the `\` key does the same (Lightroom convention).
- **Copy edits:** shows a brief toast, "Edits copied · Paste on any photo".
- **Undo/redo:** every committed slider change is one step. Undo and redo show a toast naming the step, e.g. "Undid Exposure +0.50".
- **Reset:** a section's Reset resets it to defaults. If the photo already had edits in that section when it was opened, Reset is a menu: "Back to when opened" or "Reset to defaults". The More menu has "Back to when opened" for the whole photo. Each is one undoable step.

## Adjusting values

Every editing slider and color wheel behaves the same way:

- **Drag** for coarse changes. Movement is relative to where the finger lands, so touching a control never makes the value jump.
- **Fine adjustment (Nitro-style):** while dragging a slider, pull the finger above or below the track. The thumb turns blue with a "Fine" label (one tenth of the movement); pull further for "Finer" (one fortieth, purple). Coming back to the track resumes coarse movement from the current value. On the Mac, hold Option.
- **Color wheels (darktable-style):** drag anywhere on the wheel to move the puck relatively; pull the finger outside the wheel for fine and finer control, with the same colors and labels.
- **Double-tap** a slider or wheel to reset it to its default.
- **Press and hold** a slider or wheel to see the photo without that setting. A "Without exposure" badge shows until release.
- Bipolar sliders fill from their default position (a small tick), not from the left end.
- Only horizontal drags start on a slider; vertical swipes scroll the panel.

## Zoom

- **Pinch** to any zoom between Fit and 800%, anchored under the fingers. A "NN%" label shows while zooming (and on double-tap). 100% means one original pixel per screen pixel.
- **Double-tap** toggles Fit and 100%. Drag pans when zoomed in.
- Past what the 2560 px preview can show, the canvas renders the full-size RAW (only the visible area).
- The iPad/Mac view bar has Fit and 100% plus the current percentage.

## Compare

- **Before/after toggle:** the whole photo shows the original with a "Before" badge (`\` on the Mac).
- **Split:** a draggable divider, original on the left and edit on the right, with Before and After labels. It starts in the middle of what's on screen, and works at any zoom: the divider stays put in the view while the photo zooms and pans under it. On the photo, tap the compare button for split; press and hold it to see the whole photo before. "Split" is also in the iPad/Mac view bar and the iPhone More menu.

## iPhone — Editor

From top to bottom:

1. **Top bar.** Back ("Library") on the left; the filename in the middle, or the re-decode status while one is running; a More menu on the right.
2. **Photo** (about 40% of the height). Overlays: a histogram (top right), the camera and decoder badge "A7R V · RAW 9" (bottom left), and the compare toggle (bottom right).
3. **Progress line.** 2 pt, visible only during a re-decode.
4. **Tab picker:** Presets · Light · Color · Grade · Detail · Masks. Presets come first because they set the sliders in the other tabs, which stay adjustable afterwards (imported .cube LUTs set the Film LUT and its amount instead). The editor opens on Light. In the iPad and Mac inspector it shows icons, with the tab's name underneath.
5. **Tab content:**
   - **Light:** an Auto button, then Exposure, Contrast, Highlights, Shadows, Whites, Blacks; a Presence section (Clarity, Texture, Dehaze); and the tone curve.
   - **Color:** Temperature (shown in K) and Tint, Vibrance and Saturation, then the HSL mixer with a Color · Hue · Saturation · Luminance picker:
     - **Color:** a row of 8 hue swatches (Red, Orange, Yellow, Green, Aqua, Blue, Purple, Magenta). The selected swatch drives three sliders: hue, saturation and luminance, tinted with that hue.
     - **Press and hold** a swatch, or any HSL slider, to see which parts of the photo that band affects: its colors stay and the rest turns dim gray, with a "Showing blues" badge.
     - **Hue, Saturation or Luminance:** Lightroom's layout, with all 8 colors for that one property.
   - **Grade:** four color wheels in a 2×2 grid (Shadows, Midtones, Highlights, Global), each with a hue and strength readout. Then their luminance sliders, Blending and Balance; a Film LUT picker and Amount; and Effects (Vignette, Midpoint, Grain, Grain size).
   - **Detail:** an info note ("Detail runs in the RAW 9 decoder…"), then Noise reduction, Color noise, Sharpness and Detail.
   - **Masks:**
     - With no masks yet, a grid to create one: Subject, Sky, People, Background, Object (tap to select), Brush, Linear gradient, Radial gradient, Luminance range, Color range. AI masks are amber.
     - Otherwise:
       - The mask list. Each row shows its icon, name, adjustment count and a show/hide eye, with a menu for Duplicate and Delete; "+ New" adds a mask.
       - The selected mask's parts. Each part shows its operation (+ add, − subtract, ∩ intersect), name and AI status (Analyzing…, or why nothing was found), with a menu for Combine, Invert and Delete; "+ Add" adds a part with any operation.
       - The selected part's settings:
         - Brush: Paint/Erase, Size, Feather, Flow.
         - Radial: Feather, Angle.
         - Luminance: a gradient bar plus Dark end, Bright end, Smoothness.
         - Color: a picked-color swatch plus Range.
       - A "Show overlay" toggle, Amount, and the local sliders: Temperature, Tint, Exposure, Contrast, Highlights, Shadows, Whites, Blacks, Clarity, Texture, Dehaze, Saturation, Vibrance.
     - On the photo, which shows uncropped while this tab is open:
       - Linear gradient: lines at the start (solid), middle (dashed) and end (dotted), with handles to move either end or both.
       - Radial gradient: the ellipse and its feather ring, with center and edge handles.
       - Brush: drag to paint, with a size cursor (red while erasing).
       - Object and color: tap to add to the selection or pick the color.
       - The selected mask is tinted red when the overlay is on.
   - **Presets:** 3-column grids of tiles rendered live from the current photo, in three sections:
     - Presets: Original and the built-ins.
     - Fujifilm film simulations.
     - My presets, plus "Import…".

     There is also an Amount slider. When a Fuji photo records the film simulation it was shot with, a "Shot as Classic Chrome · Apply" banner tops the tab, and that tile carries a camera badge.
6. **Bottom bar:** Copy edits · Crop · Undo · Export (accent).

**Retouch mode** (the Retouch button in the bottom bar or view bar) starts at Fit. One finger paints (a tap on a spot selects it); two fingers pinch to zoom and drag to pan, and a second finger cancels a stroke in progress. The brush stays the same size on screen, so zooming in paints finer. It replaces the tabs with:
- a Remove · Heal · Clone picker and a hint;
- Brush size;
- for Remove, the engine for new removals: "LaMa + diffusion" (the default when the build includes it), "LaMa · full resolution" or "LaMa · fast";
- for a diffusion spot, **Try another** for a different variation;
- the selected spot's type, engine (changing it refills the spot), status ("Filling from the full-resolution original…" while AI runs, then what filled it) and Delete;
- Show spots, a spot count, Clear all and Done.

On the photo (uncropped):
- paint to add a spot, or tap a spot to select it;
- spots show as ovals, with amber for the selected one;
- heal and clone spots show a dashed source circle you can drag.

**Crop mode** replaces the tabs with the crop tools:
- aspect chips: Free, Original, 1:1, 4:5, 3:2, 4:3, 16:9, 65:24 XPan, Custom… (enter any width and height) and swap orientation;
- Straighten (±45°) with an **Auto** button and, once used, an "Auto · Camera level" or "Auto · Horizon" badge. The slider then fine-tunes the found angle. Double-tap resets to 0 and turns Auto off;
- Vertical perspective and Horizontal perspective;
- Reset and Done.

The photo shows the corrected, straightened frame with the crop rectangle, corner handles, a fine square grid and the thirds, and the area outside the crop is dimmed.

## iPad in portrait

The side-by-side workspace (filmstrip, photo with view bar, inspector) needs about 1100 pt, more than any iPad has in portrait. Below that width, including narrow Split View, the iPad uses the stacked editor: the photo takes the top half, and the tab picker, panel and bottom bar sit below, at most 680 pt wide and centered. Landscape keeps the workspace.

## iPhone — Library and bulk paste

- **Library grid:** 3 columns of square thumbnails with 2 pt gaps, and a "Today's import"-style album title.
- **Select mode:** Cancel / "N Selected" / Select All in the top bar. Selected tiles show an amber check; unselected tiles show a white ring.
- **Header chip:** "Copied: IMG_4821" whenever the clipboard holds a recipe.
- **Paste sheet** (medium detent):
  - Title: "Paste edits to N photos", with the subtitle "From IMG_4821 · copied just now".
  - A segmented control: "Set values" or "Adjust by (+/−)".
  - Checkbox rows for each paste group, all ticked except Crop: White balance, Light, Color and grading, Film LUT (.cube), Detail and noise ("Re-decodes, slower"), Masks ("AI masks re-detect on each photo"), Crop ("Per photo", off by default).
  - A primary button: "Paste to N photos".

## iPad — Editor (landscape)

- **Toolbar:** back to the album, the job tray pill (center), then Copy, Paste, Compare and Export (accent).
- **Left:** a vertical filmstrip (84 pt tiles), with the current photo outlined in amber.
- **Center:** the photo, fit to the view.
- **View bar** under the photo: Fit · 100% · Show clipping · Split before/after, plus "History · N steps" on the right.
- **Right inspector** (about 340 pt): the tab picker, then panel content. The mock shows the Grade tab with color wheels, Blending and Balance, plus a Film LUT picker and Amount.
- **Job tray popover:** lists concurrent jobs, e.g. "Pasting edits to 6 photos · 2 left · 4 of 6 saved", "Re-decoding RAW 9 · IMG_4822", "Saving to Photos · IMG_4823 · waiting for earlier saves". While photos are queued, the pill reads "N photos left" instead of the job count.
- **Export sheet:** HEIC or JPEG; size as Full or 24/12/6/2 MP (only those smaller than the photo), each row showing pixel dimensions and an estimated file size; a quality slider; "Save to Photos" (a new photo next to the original) and "Render for sharing" (then a share link). Format, size and quality are remembered.

## Mac — Editor

- **Toolbar:** sidebar toggle, the filename plus "A7R V · RAW 9", the job tray pill (center), then Copy, Paste, Compare and Export.
- **Sidebar:**
  - Library: All Photos, Recently edited, Favorites.
  - Albums.
  - History: a list of steps, newest first, with the current step highlighted. Clicking a step jumps to it, and a Snapshot button saves the current state.
- **Center:** the photo, with a horizontal filmstrip below it (72 pt tiles).
- **Inspector:** the tab picker, histogram, sliders for the active tab, and a Presets section with "Import .cube or XMP…".
- **Keyboard shortcuts** (proposed):

| Action | Shortcut |
| --- | --- |
| Copy edits | ⇧⌘C |
| Paste edits | ⇧⌘V |
| Before/after | `\` |
| Undo / redo | ⌘Z / ⇧⌘Z |
| Previous / next photo | ← / → |
| Fit / 100% | Z |
| Export | ⌘E |

- **Layout:** fluid. The window resizes, and the inspector stays at a fixed width.

## Not in D0

- Any sync or nearby-sharing UI. That comes in M4.

## Remote editing

- **Devices** (library toolbar, and "Edit Photos on Another Device…" on the first-run access screen) opens a sheet:
  - "Let nearby devices edit this library", a toggle for the device with the photos.
  - **Nearby:** devices sharing their library, each with Edit. Shows "Looking for devices…" while searching.
  - While connected, the sheet shows who is connected and Disconnect.
- **Approval:** both devices show a sheet: "Let iPad edit your photos?" or "Edit the photos on iPhone?", a large six-digit code, "Check that … shows the same code, then allow on both devices", and Don't Allow / Allow. After Allow it shows "Waiting for …" and Cancel until the other device answers.
- **Banner** above the library while connected: "Photos on iPhone" on the editing device and "iPad is editing this library" on the sharing device, each with Disconnect. While the link is down the editing device shows a spinner and "Reconnecting to iPhone… edits are kept here", and the editor shows a small "Reconnecting to iPhone · edits are kept" badge on the photo; the sharing device shows "iPad will reconnect".
- **Allowed devices** in the Devices sheet lists trusted devices with Forget. Trusted devices reconnect without the code.
- On the editing device, Import is disabled. Job tray entries for work done on the other device say so, e.g. "Saving edit to iPhone".

