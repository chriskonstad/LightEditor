# App Review risks and release checklist

Checked against the build settings in `project.yml` and the code as of October 2026. The first release is iPhone and iPad; the Mac follows.

## Handled

- **Model licenses.** Settings › Licenses (the gear in the library, or "About and Licenses" on the first-run screen) shows the full MIT, Apache-2.0 (LaMa) and CreativeML Open RAIL-M (Stable Diffusion) texts. The first "LaMa + diffusion" removal asks the user to agree to the Open RAIL-M use restrictions; until then new removals default to LaMa. `listing.md` also has optional EULA text for App Store Connect.
- **Usage strings.** `NSPhotoLibraryUsageDescription`, `NSPhotoLibraryAddUsageDescription` and `NSLocalNetworkUsageDescription` are specific and accurate; `NSBonjourServices` lists `_lighteditor._tcp`.
- **Privacy manifest.** `App/Resources/PrivacyInfo.xcprivacy` declares no tracking and no collected data, plus the required reasons for UserDefaults (CA92.1) and file timestamps (C617.1, the decode cache's own files).
- **Debug hooks.** `-ImportFolder` and the Mac debug automation are compiled only into Debug builds. `-FixtureLibrary` and the diagnostics flags exist in Release but only act on launch arguments, which App Store users can't pass.
- **No login, no network, no third-party SDKs,** so there's no demo account to provide and the privacy label is "Data Not Collected".
- **Generative AI.** The diffusion engine only runs inside a user-drawn mask with a fixed "empty background" prompt; users can't type prompts. The review notes in `listing.md` say so.

## Watch for

1. **App size.** The models add about 880 MB (LaMa ~100 MB, Stable Diffusion ~780 MB). Within Apple's limits, but iOS asks before downloading over cellular. If reviewers or users push back, move Stable Diffusion to Apple-hosted Background Assets (a download from Apple's servers on first use).
2. **Trademarks (guideline 5.2.1).** The built-in presets use Fujifilm film simulation names. Settings and THIRD-PARTY.md say they're approximations and trademarks of Fujifilm. If App Review objects, rename them and keep the Fujifilm mapping only for detecting the simulation a RAF was shot with.
3. **Export compliance.** `ITSAppUsesNonExemptEncryption = NO`. The only encryption is CryptoKit (Curve25519, ChaCha20-Poly1305) for the device-to-device link, i.e. Apple OS encryption.
4. **Name.** "LightEditor" was taken on the App Store when the record was created; the record is "LightEditor RAW". The home-screen name is LightEditor either way.

## Mac

Release Mac builds sign with the team (Debug stays ad-hoc so anyone can build it), and `scripts/testflight.sh --mac` archives and uploads them. LightEditor › Settings… (⌘,) opens the about, privacy and licenses window. The remote-editing identity key uses the data protection keychain on the Mac too: the legacy login keychain blocked launch on a password prompt whenever the app's signature changed. Screenshots come from a Debug build (see `docs/app-store/screenshots.md`).

## Release checklist

- [x] In-app licenses and the diffusion agreement.
- [x] `MARKETING_VERSION` 1.0.
- [x] Repository public, so the privacy policy and support URLs resolve.
- [x] App Information, pricing (Free), App Privacy, age rating and the listing text in App Store Connect.
- [x] EU Digital Services Act trader status (not a trader).
- [x] Screenshots per `screenshots.md` (iPhone 6.9", iPad 13", iPhone Duo).
- [x] Build 2610291908 (iOS 27.1 SDK, adds background bulk edits) submitted for review on 2026-10-29, replacing 2610291034 before review began. Upload with plain `scripts/testflight.sh`: `--internal-only` builds can't be attached to an App Store version.
- [x] Approved and released 2026-11-01: https://apps.apple.com/app/lighteditor-raw/id6824085422
- [x] 1.0.1 (build 2611041042) submitted 2026-11-04, released automatically on approval
- [x] 1.0.1 approved and released by 2026-11-07
- [x] 1.0.2 submitted 2026-11-07 for iOS (build 2611070958) and, for the first time, the Mac (build 2611071007), both released automatically on approval. The first Mac export needed the Apple ID (Mac App Store profile and Mac Installer Distribution certificate), like the first export after a new entitlement.
