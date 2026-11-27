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

## Canvas background

- The color around the photo in the editor is a viewing preference, kept on each device and never part of the edit or an export: **Black**, **Dark** (the ground, `#0E0F11`, the default), **Dark gray** (`#333333`), **Mid gray (18%)** (`#767676`, neutral 18% gray in linear light, for judging exposure), **Light gray** (`#BDBDBD`) and **White**.
- It's under **Background** in the iPhone More menu, the iPad/Mac view bar, the Mac's Photo menu, and Settings › Editor. The change shows at once.
- Nothing from an edit draws outside the photo: vignette, grain, dehaze and the clipping and mask overlays stay inside it at any zoom, pan and crop. (The crop overlay still dims the uncropped frame around the crop box.)

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
- **Color wheels:** drag anywhere on a wheel to move the puck relatively. A quick drag moves it with the finger; a slow, deliberate one moves it down to a quarter as far, so precision needs no special gesture. On the Mac, hold Option for a tenth. For exact values, open the wheel (see Color) and use its sliders.
- **Double-tap** a slider or wheel to reset it to its default.
- **Press and hold** a slider or wheel to see the photo without that setting. A "Without exposure" badge shows until release.
- Bipolar sliders fill from their default position (a small tick), not from the left end.
- **Colored tracks** show what moving a slider does, where the effect has a color: Temperature runs blue to amber, Tint green to magenta, Saturation and Vibrance gray to the full spectrum, Exposure, Highlights, Shadows, Whites, Blacks and grade Luminance dark to light. In the HSL mixer, Hue runs from the band's neighbor on one side, through its own color, to the neighbor on the other (Green: yellow, green, aqua), Saturation from gray to the band's color, and Luminance from a dark to a light shade of it. Mask sliders use the same tracks. A colored track shows the default as a tick and no fill; other sliders keep the amber fill.
- Only horizontal drags start on a slider; vertical swipes scroll the panel.

## Zoom

- Zoom and pan work in every mode: the tabs, Masks, Retouch and Crop.
- **Two fingers** pinch to any zoom between Fit and 800%, and move together to pan; the photo follows the fingers. A "NN%" label shows while zooming (and on double-tap). 100% means one original pixel per screen pixel.
- **Double-tap** toggles Fit and 100%, except where taps are a tool's (Retouch, and the brush, object and color masks).
- **One finger** pans when zoomed in, wherever no tool takes it: in Crop it moves the crop box, and in Retouch and the mask brush it paints.
- On the Mac, a trackpad pinch zooms and two-finger scrolling (or a scroll wheel) pans.
- The zoom carries over between tabs and modes. Masks, Retouch and Crop show the uncropped photo, so when a crop, straighten or perspective makes that a different frame, the zoom goes back to Fit on the way in or out.
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
4. **Tab picker:** Presets · Light · Color · Effects · Detail · Masks · Finish. Presets come first because they set the sliders in the other tabs, which stay adjustable afterwards (imported .cube LUTs set the Film LUT and its amount instead). The tabs and their sections follow Lightroom's order, which is also roughly the order edits are applied in (see "Grade order" in DESIGN.md). Tab order doesn't change the result: the pipeline order is fixed, whichever control was touched first. The editor opens on Light. Where the names don't fit (the iPhone, and the iPad and Mac inspector) it shows icons, with the current tab's name underneath.
5. **Tab content:**
   - **Light:** an Auto button, then Exposure, Contrast, Highlights, Shadows, Whites, Blacks; a Presence section (Clarity, Texture, Dehaze); and the tone curve.
   - **Color:** Temperature (shown in K) and Tint, Vibrance and Saturation, then the HSL mixer with a Color · Hue · Saturation · Luminance picker:
     - **Color:** a row of 8 hue swatches (Red, Orange, Yellow, Green, Aqua, Blue, Purple, Magenta). The selected swatch drives three sliders: hue, saturation and luminance, on colored tracks (see "Adjusting values").
     - **Press and hold** a swatch, or any HSL slider, to see which parts of the photo that band affects: its colors stay and the rest turns dim gray, with a "Showing blues" badge.
     - **Hue, Saturation or Luminance:** Lightroom's layout, with all 8 colors for that one property.

     Then **Color grading**, as in Lightroom's Color panel: four color wheels (Shadows, Midtones, Highlights, Global): a 2×2 grid, or one row of four when the panel is at least 560 pt wide. Under each wheel, its name with a chevron and a readout ("211° · 29 · L −8", or "Neutral"). Drag a wheel for a quick change. Tap it, or its name, to **open** it:
     - A row with a back chevron ("All wheels" where it fits; Escape on a keyboard) and chips for the four wheels, so you can switch without going back; an edited wheel's chip has a dot in its color. When the chips don't fit (large text), they become a menu.
     - The wheel, large, with a crosshair and a dashed ring at the current strength. Beside it (iPhone, and panels at least 560 pt wide) or above it (the iPad landscape and Mac inspector, and accessibility text sizes): **Hue** (0–359°, on a rainbow track), **Saturation** (0–100, gray to the hue) and **Luminance**. Hue and Saturation edit the same point as the wheel and fine-adjust like every slider. Raising Saturation from zero uses the hue last shown, so a neutral wheel keeps the hue you chose. Double-tap Hue or Saturation to reset the wheel; press and hold to see the photo without it.
     - The open wheel fits the iPhone panel without scrolling.
     
     Then Blending and Balance.
   - **Effects:** the creative stages, in the order they're applied: a Film LUT picker and Amount; Vignette (Amount, Midpoint), applied after the crop; Grain (Amount, Size).
   - **Detail:** an info note ("Detail runs in the RAW 9 decoder…"), then Noise reduction, Color noise, Sharpness and Detail, Moiré reduction and the Lens corrections switch (the camera's lens profile). Below, **Manual Lens Corrections**: Distortion (positive fixes barrel, negative pincushion; the frame stays filled), Red/cyan fringe, Blue/yellow fringe (lateral chromatic aberration) and Lens vignetting, with its Midpoint once it's set. These grade without a re-decode; distortion and fringing show outside Masks and Retouch, like perspective.
   - **Masks:**
     - With no masks yet, a grid to create one: Subject, Sky, People, Background, Object (tap to select), Brush, Linear gradient, Radial gradient, Luminance range, Color range, Depth range (when the build bundles the depth model). AI masks are amber.
     - Otherwise:
       - The mask list. Each row shows its icon, name, adjustment count and a show/hide eye, with a menu for Duplicate and Delete; "+ New" adds a mask. Press and hold a row to see that mask's overlay until release, whatever the "Show overlay" toggle says.
       - The selected mask's parts. Each part shows its operation (+ add, − subtract, ∩ intersect), name and AI status (Analyzing…, or why nothing was found), with a menu for Combine, Invert and Delete; "+ Add" adds a part with any operation.
       - The selected part's settings:
         - Brush: Paint/Erase, Size, Feather, Flow.
         - Luminance range, Color range and Depth range: **tap the photo to pick**. Luminance centers its range on the tapped tone, Depth on the tapped distance (keeping the range's width), and Color picks the tapped color. Luminance has Dark end, Bright end and Smoothness; Depth has Near, Far and Smoothness over a near-to-far bar. The depth map is measured once per photo ("Measuring depth" in the job tray, "Analyzing…" on the part); a tap before it's ready says so.
         - Radial: Feather, Angle.
         - Luminance: a gradient bar plus Dark end, Bright end, Smoothness.
         - Color: a picked-color swatch plus Range.
       - A "Show overlay" toggle, Amount, and the local sliders: Temperature, Tint, Exposure, Contrast, Highlights, Shadows, Whites, Blacks, Clarity, Texture, Dehaze, Saturation, Vibrance.
       - The overlay hides itself while you adjust, as in Lightroom. It shows while the selection is made or refined, and the first change to Amount or a local slider hides it so the effect is visible; the toggle turns off to match. It comes back when you go back to the selection: a brush stroke or tap, moving a gradient, a part or brush setting, adding, deleting, inverting or combining a part, or picking a mask or part. Turning the toggle on by hand keeps the overlay on while you adjust, until you refine the selection again; turning it off keeps it off until you turn it back on. This is view state, not part of the recipe.
     - On the photo, which shows uncropped while this tab is open. It zooms and pans as in the other tabs, for detailed masks and to judge local adjustments up close; the zoom carries over between tabs unless a crop or perspective changes the frame:
       - Linear gradient: lines at the start (solid), middle (dashed) and end (dotted), with handles to move either end or both. Drag the photo away from the handles to pan; pinch or double-tap to zoom.
       - Radial gradient: the ellipse and its feather ring, with center and edge handles. Panning and zooming as for the linear gradient.
       - Brush: one finger paints, with a size cursor (red while erasing); two fingers pinch to zoom and drag to pan, and a second finger cancels a stroke in progress. As in Retouch, the brush stays the same size on screen, so zooming in paints finer.
       - Object and color: tap to add to the selection or pick the color; drag to pan and pinch to zoom.
       - The selected mask is tinted red when the overlay is on.
   - **Finish:** what frames the cropped photo, shown on the photo and in every save and export:
     - A caption first: "For exports and shares. The photo saved in Photos stays without a border or watermark." Border and watermark are output settings, not part of the look: they show in the preview, exports and shares, not in the image saved to Photos or in presets, and copy and paste as their own group.
     - **Border:** Width and Extra bottom (for a gallery or instant-film look), both a share of the photo's short edge so the border looks the same at any size; Color chips White · Black · a system color picker; Canvas chips Fit · 1:1 · 4:5 · 9:16 · 3:2 · 2:3, which pad the frame to that shape (e.g. 4:5 for Instagram) without cropping the photo. The section's Reset clears the border and the watermark.
     - **Last used border** and **Last used watermark** buttons (under the Border header and the Watermark switch) apply the border or watermark last used on any photo, as one undo step. Each shows only when there's one saved that differs from this photo's. What's on a photo when the Finish tab opens, and every change made there, becomes the last used; a part that's off is never saved, so opening a plain photo doesn't forget it.
     - **Watermark** switch, off by default. When on: a Text · Logo switch. Text: an empty text field, focused ("Your watermark, e.g. © Your Name"); there's no default text, and an empty watermark draws nothing. Logo: "Choose Logo…" opens the file picker for PNG, JPEG, HEIC, TIFF, PDF or SVG (an SVG is converted to a vector PDF); once chosen, a thumbnail, the file's name and "Replace…". Then a 3 × 3 position grid with the position's name, color chips White · Black · picker (text only; a logo keeps its colors), and Size (Height for a logo), Angle, Opacity and Margin sliders. The watermark sits on the photo, inside its margin; long text and wide logos shrink to fit, and a logo keeps its aspect ratio.
     - **On the photo**, while the Finish tab is open, the watermark has a dashed frame: drag it anywhere (it snaps to the photo's center lines; the grid then reads "Placed by hand" and Margin hides), drag the corner handle to resize and turn it at once, or pinch and rotate on a touch screen; it snaps to right angles. Double-tap straightens it, and tapping a grid cell puts it back on the grid. Text and vector logos are set at the export's pixel size, never scaled as bitmaps; turned watermarks are drawn at twice the size and scaled down with Lanczos.
     - Masks, Retouch and Crop show the photo without its frame; the histogram leaves the frame out.
   - **Presets:** 3-column grids of tiles rendered live from the current photo, in three sections:
     - Presets: Original and the built-ins.
     - Fujifilm film simulations.
     - My presets, plus "Import…". Saving a preset ("New preset") takes the look only: never Crop, Detail, the saved image size, or the border and watermark.

     There is also an Amount slider. When a Fuji photo records the film simulation it was shot with, a "Shot as Classic Chrome · Apply" banner tops the tab, and that tile carries a camera badge.
6. **Bottom bar:** Copy edits · Crop · Undo · Export (accent).

**Retouch mode** (the Retouch button in the bottom bar or view bar) keeps the zoom (see "Zoom"). One finger paints (a tap on a spot selects it); two fingers pinch to zoom and drag to pan, and a second finger cancels a stroke in progress. The brush stays the same size on screen, so zooming in paints finer. It replaces the tabs with:
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

**Crop mode** replaces the tabs with the crop tools. One finger moves the crop box or drags a corner; two fingers zoom and pan, and zoomed in, drags move the box by finer steps:
- aspect chips: Free, Original, 1:1, 4:5, 3:2, 4:3, 16:9, 65:24 XPan, Custom… (enter any width and height) and swap orientation;
- Straighten (±45°) with an **Auto** button and, once used, an "Auto · Camera level" or "Auto · Horizon" badge. The slider then fine-tunes the found angle. Double-tap resets to 0 and turns Auto off;
- Vertical perspective and Horizontal perspective;
- **Four corners** ("On" when set) with "Set Corners…" / "Edit Corners…": the photo switches to how it was shot (no perspective, straighten or crop), with four handles joined by an amber outline, a grid that follows the shape's perspective, and the outside dimmed. Drag the corners onto something that should be rectangular; a handle can't fold the shape over itself. "Apply" goes back to the crop tool with the shape made rectangular (its size follows the shape's sides); "Remove Corners" turns it off. The keystone sliders, straighten and crop then apply on top;
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
  - Checkbox rows for each paste group, all ticked except Crop: White balance, Light, Color and grading, Film LUT (.cube), Detail and noise ("Re-decodes, slower"), Masks ("AI masks re-detect on each photo"), Crop ("Per photo", off by default), Border and watermark ("For exports and shares", off by default; output settings, so this is how they spread to a batch).
  - A primary button: "Paste to N photos".

## Opening a photo from Photos (iPhone and iPad)

- In Photos, Share › **LightEditor** (the app row of the share sheet) opens that photo in LightEditor's editor, from a cold launch or with the app already running. The back button returns to the library as usual, and the status bar offers "◀ Photos".
- The share extension shows only a small card, "Opening in LightEditor…", while it hands off. If it can't, the card explains why and offers Close:
  - "This photo has no capture date, so LightEditor can't find it in your library. Open it from the LightEditor app instead."
  - "LightEditor couldn't be opened from here. Open the app and choose the photo there."
- Toasts in the app: "Your library has 2 identical copies · Opened one", "Couldn't find this photo in your library", and, with limited access, "LightEditor can't see this photo · Allow it in Settings › Privacy › Photos".

## iPad — Editor (landscape)

- **Toolbar:** back to the album, the job tray pill (center), then Copy, Paste, Compare and Export (accent).
- **Left:** a vertical filmstrip (84 pt tiles), with the current photo outlined in amber.
- **Center:** the photo, fit to the view.
- **View bar** under the photo: Fit · 100% · Show clipping · Split before/after · Background, plus "History · N steps" on the right.
- **Right inspector** (about 340 pt): the tab picker, then panel content. The mock shows the color wheels, Blending and Balance (now at the end of the Color tab), plus a Film LUT picker and Amount (now in Effects).
- **Job tray popover:** lists concurrent jobs, e.g. "Pasting edits to 6 photos · 2 left · 4 of 6 saved", "Re-decoding RAW 9 · IMG_4822", "Saving to Photos · IMG_4823 · waiting for earlier saves". While photos are queued, the pill reads "N photos left" instead of the job count.
- **Export sheet:** HEIC or JPEG; size as Full or 24/12/6/2 MP (only those smaller than the photo), each row showing pixel dimensions and an estimated file size; a quality slider; "Save to Photos" (a new photo next to the original) and "Render for sharing" (then a share link). Format, size and quality are remembered.
- **Saved image size** (More menu → "Saved image size…"): the size and quality of the image the edit saves to Photos, which is what Photos, iCloud and sharing use (the original keeps every pixel). "Use the Default" on follows Settings; moving either slider gives the photo its own. Maximum size is a slider from 1 MP to the photo's (cropped) size, whose right end is "Full size"; quality is 40–100%. File Size shows the setting's pixel size with an estimate (from a small sample, within about 20%), and the size of the image saved in Photos now ("Saves when you leave" while there are unsaved changes). "Make … the Default" copies the setting to Settings. The setting pastes as its own group, "Saved image size", off by default, so it can be copied to a batch. Settings has the default under "Saved Image" (the same two sliders, where the size slider's right end, past 100 MP, is "Full size").

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

