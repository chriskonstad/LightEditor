# App Store listing (draft for review)

The first release is **iPhone and iPad only**; the Mac version follows later. Character limits are Apple's; counts are for the text as drafted. Repository: https://github.com/chriskonstad/LightEditor (MIT).

## Identity

| Field | Value | Notes |
| --- | --- | --- |
| App name | **LightEditor** if available, else **LightEditor RAW** | App Store names are unique; "LightEditor" was taken when the record was created, so try it again first. |
| Home-screen name | LightEditor | `CFBundleDisplayName`. Apple allows a shorter display name when it's clearly the same app. |
| Bundle ID | `com.chriskonstad.lighteditor` | One record for iPhone, iPad and Mac (universal purchase). |
| SKU | `lighteditor` | Internal only; already set when the record was created. |
| Primary category | Photo & Video | |
| Secondary category | Graphics & Design | Optional. |
| Price | Free | No in-app purchases, no ads. |
| Platforms | iPhone (including iPhone Duo), iPad (Mac later) | Minimum iOS and iPadOS 27. Duo layout needs a build made with the iOS 27.1 SDK. |
| Copyright | `2026 Chris Konstad` | Shown on the store page. |

## Subtitle (30)

> Free RAW editor, open source

28/30. Alternative: "RAW editing, no subscription" (28/30).

## Promotional text (170)

> Free, open source and always subscription-free, now built for iPhone Duo. Edit RAW photos with precise color tools and on-device AI. No account, no tracking.

157/170. Promotional text can change any time without a new build.

## Keywords (100 bytes)

```
camera,dng,arw,raf,proraw,lut,preset,color,grading,film,mask,retouch,hsl,duo,remove,subscription
```

96/100. Words in the name and subtitle (light, editor, raw, free, open, source) already count, so they're left out. No competitor or camera-brand trademarks ("Lightroom", "Fujifilm", "Sony"): App Review rejects those in keywords (guideline 2.3.7).

## Description (4000)

```
LightEditor is a free, open-source RAW photo editor for iPhone, iPhone Duo and iPad, made for quick, color-focused edits on the road. It will always be free of subscriptions: no subscription, no in-app purchases, no account, no ads, no tracking. Your photos never leave your devices.

YOUR PHOTOS LIBRARY IS THE LIBRARY
LightEditor edits the photos already in Apple Photos. Originals stay untouched: every edit is saved non-destructively, syncs through iCloud Photos, and can be reverted at any time, in LightEditor or in Photos.

PRECISE, FAST TOOLS
• RAW decoding with Apple's latest RAW engine, for supported cameras and iPhone ProRAW. JPEG and HEIC work too.
• Light: exposure, contrast, highlights, shadows, whites and blacks, with Auto, Clarity, Texture and Dehaze.
• Color: white balance, vibrance, saturation, and an 8-band HSL mixer.
• Grade: color wheels for shadows, midtones and highlights, film looks, vignette and grain.
• Detail: noise reduction and sharpening applied to the RAW itself.
• Tone curve, crop, straighten, perspective and auto-straighten.
• Sliders stay smooth while you drag, even on large RAW files.

LOCAL ADJUSTMENTS AND AI, ON YOUR DEVICE
• Masks: linear and radial gradients, brush, luminance and color ranges.
• One-tap AI masks for the subject, people and the sky, or tap any object to select it.
• Remove distractions with heal, clone and AI removal. The most realistic mode fills the area with an on-device diffusion model.
All AI runs on your device. Nothing is uploaded.

EDIT MANY PHOTOS AT ONCE
• Copy and paste edits, choosing exactly which settings to paste.
• Bulk edit a selection: set values, or adjust each photo by an amount.
• Presets with an Amount slider, film-inspired looks, .cube LUTs, and import of XMP presets.

EDIT YOUR IPHONE'S PHOTOS ON YOUR IPAD
Traveling with an iPhone and an iPad? Your iPhone can share its library straight to your iPad over a direct, encrypted Wi-Fi link. No internet or router needed, and no cloud in between.

BUILT FOR IPHONE DUO
Unfold iPhone Duo and LightEditor turns into an iPad-class editor. Turn it sideways for the photo and the full set of tools side by side, or hold it upright for a big photo over a roomy panel. Fold it and you're back to the one-handed phone editor.

DESIGNED FOR TOUCH
Pull away from a slider for fine control, double-tap to reset, press and hold to compare, and drag the before/after split. Every slow task shows its progress in a job tray and can be cancelled.

PRIVATE BY DESIGN
LightEditor collects no data at all: no analytics, no crash reporting, no accounts, no servers.

FREE AND OPEN SOURCE, FOREVER
LightEditor is free, and it will always be subscription-free. The full source code is on GitHub under the MIT license, so anyone can read it, check what it does, report issues or contribute:
https://github.com/chriskonstad/LightEditor

Requires iOS or iPadOS 27.
```

About 2,300/4,000. Check before publishing:

- "XMP presets" is fine; don't add "Lightroom" in the description's first lines either. Naming another product only to say you import its format is usually accepted, but it's safer to leave out.
- The Fujifilm-style presets are described as "film-inspired looks", without the trademarked names.

## What's New (first release)

```
First release. Thanks for trying LightEditor!
```

## URLs

| Field | Required | Draft |
| --- | --- | --- |
| Privacy Policy URL | Yes | https://github.com/chriskonstad/LightEditor/blob/main/docs/app-store/privacy-policy.md |
| Support URL | Yes | https://github.com/chriskonstad/LightEditor/issues |
| Marketing URL | No | https://github.com/chriskonstad/LightEditor |

## App Privacy ("nutrition label")

Answer **"No, we do not collect data from this app."** Result: **Data Not Collected**.

Why that's accurate, under Apple's definition (collection means transmitting data off the device so that you or a third party can access it beyond servicing the request in real time):

- No analytics, crash reporting, advertising or third-party SDKs. The app has no third-party code at all.
- No servers and no network calls to the internet. The only networking is the optional device-to-device link between the user's own devices, which is direct, end-to-end encrypted, and never reaches the developer.
- Photos are read and written through PhotoKit, on device. iCloud Photos sync is Apple's, under Apple's privacy policy, not the app's.
- Tracking: **No**. `PrivacyInfo.xcprivacy` declares no tracking, no tracking domains and no collected data types.

## Age rating

Answer **None / No** to everything. Expected rating: **4+**.

| Question | Answer | Notes |
| --- | --- | --- |
| Violence, sexual content, nudity, profanity, horror, drugs, alcohol, tobacco, gambling, contests, mature themes | None | |
| Medical or treatment information | No | |
| Unrestricted web access | No | No web views or browser. |
| User-generated content shared with others | No | Photos are only exported by the user through the system share sheet. |
| Messaging or chat | No | |
| Advertising | No | |
| Loot boxes / in-app purchases | No | |
| Parental controls / age assurance | No | |

The diffusion model could in theory produce unexpected imagery, but only inside a small masked area, from a fixed "empty background" prompt, never from user text. That doesn't count as user-generated or AI-generated content in the questionnaire's sense. Mention it in the review notes anyway (below).

## Export compliance

`ITSAppUsesNonExemptEncryption` is `NO` in the build, so App Store Connect won't ask per build. The app's only encryption is CryptoKit (Apple's OS) for the device-to-device link: Curve25519 key agreement and ChaCha20-Poly1305. Apple's guidance treats encryption that is only "within the Apple operating system" as not needing documentation. If App Store Connect asks, the answers are: uses encryption, yes; proprietary or non-standard algorithms, no; standard algorithms instead of or in addition to Apple's OS, no. **Decision / check:** confirm this reading yourself; this isn't legal advice. France sometimes needs a separate declaration for apps that encrypt user data; Apple's export-compliance help page covers it.

## License agreement (EULA)

Apple's standard EULA, plus the Stable Diffusion use restrictions, which the model's license (CreativeML Open RAIL-M, paragraph 5) requires every user to be bound by. The app also asks once, before the first "LaMa + diffusion" removal, and shows every license under Settings › Licenses. Custom EULA text for App Store Connect (App Information › License Agreement), if you want it there too:

```
This app is licensed under Apple's Standard Licensed Application End User License Agreement (https://www.apple.com/legal/internet-services/itunes/dev/stdeula/), with one addition:

The "LaMa + diffusion" removal feature uses the Stable Diffusion 1.5 inpainting model, licensed under the CreativeML Open RAIL-M license (https://huggingface.co/spaces/CompVis/stable-diffusion-license). By using that feature you agree to that license's use-based restrictions (paragraph 5 and Attachment A), which are included in the app under Settings > Licenses.
```

## App Review notes

```
LightEditor is a RAW photo editor that works on the photos in the device's Photos library. No account or login is needed.

To try it: grant Photos access, pick any photo in the library grid, and drag the sliders. Edits save automatically when you leave the photo, and Photos > Revert restores the original.

AI removal: in the editor, open Retouch, choose Remove, and paint over an object. "LaMa + diffusion" runs a Stable Diffusion inpainting model on device with a fixed built-in prompt, only inside the painted area. Users can't enter prompts or generate images. Choosing it the first time shows the model's license (CreativeML Open RAIL-M) to agree to. All licenses are under Settings (gear icon in the library).

Remote editing (optional) needs two devices on iOS or iPadOS 27: on an iPhone, open Devices and turn on "Let nearby devices edit this library"; on an iPad nearby, open Devices and pick the iPhone under Nearby. It uses a direct peer-to-peer Wi-Fi link (Bonjour + Network framework), which is why the app asks for Local Network access.

Background processing: when the user applies an edit to many photos (Select, then Paste, Adjust or Preset) or imports several files, the job keeps running if they leave the app, as a BGContinuedProcessingTask with the system Live Activity showing its progress. It only starts from that user action, and uses background GPU on supported devices for the renders.

The app makes no internet connections and collects no data. It's free and open source (MIT): https://github.com/chriskonstad/LightEditor
```

**Check:** the steps above use the labels in the current UI; confirm them against the build you submit.

## Screenshots

See [screenshots.md](screenshots.md).
