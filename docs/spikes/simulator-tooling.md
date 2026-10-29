# Driving the simulator (Xcode 27)

Notes from testing the app in the iOS 27 simulators. This keeps testing in a simulator's local Photos library instead of a real one.

## Getting RAW files into a simulator's library

`xcrun simctl addmedia` rejects ARW and RAF ("File type unsupported"). Instead, launch a Debug build with a folder to import:

```sh
xcrun simctl launch <udid> com.chriskonstad.lighteditor -ImportFolder /path/to/raws
```

It imports through the app's own `PhotoImporter`, the same path as the Import button. Grant Photos access first with `xcrun simctl privacy <udid> grant photos com.chriskonstad.lighteditor`.

## axe

axe 1.5.2 looks for `SimulatorKit.framework` in `Xcode.app/Contents/Developer/Library/PrivateFrameworks`. Xcode 27 moved it to `Contents/SharedFrameworks`. A shim works without touching Xcode:

1. Build a directory that mirrors `Xcode.app/Contents` with symlinks.
2. Add `Developer/Library/PrivateFrameworks/SimulatorKit.framework` pointing at the new location.
3. Run axe with `DEVELOPER_DIR` set to the shim's `Contents/Developer`.

With that, `describe-ui` and `screenshot` work. `tap`, `swipe` and `touch` worked on the iPad simulator. On the iPhone simulator they didn't register while the Claude simulator panel was attached to it; the panel's own tap and swipe worked there.

Taps on buttons inside a `ScrollView` need the element's hit area to match its frame. `.contentShape(Rectangle())` on tiles fixed thumbnails whose `scaledToFill` images made their hit areas spill into the neighbors.

## Mac

Use a folder library so the real Photos library is never touched:

```sh
open "LightEditor.app" --args -FixtureLibrary ~/Library/Containers/com.chriskonstad.lighteditor/Data/Fixtures
```

The folder has to be inside the app's sandbox container. Debug builds also accept:

- `-OpenFirstAsset YES`;
- `-SnapshotTo <dir>`, which writes window snapshots, the renderer's frame count and the canvas image every 2 s. Metal content doesn't appear in `cacheDisplay` snapshots, hence the separate `canvas.png`.

## Debugging AI removal on a real device

The simulator runs Core ML on the CPU, so it can't reproduce GPU or Neural Engine bugs. A Debug build has a diagnostic that needs no UI or Photos access:

```sh
xcodebuild -scheme LightEditor -configuration Debug -destination "id=<udid>" -derivedDataPath build/DeviceDebug -allowProvisioningUpdates build
xcrun devicectl device install app --device <udid> build/DeviceDebug/Build/Products/Debug-iphoneos/LightEditor.app
xcrun devicectl device copy to --device <udid> --domain-type appDataContainer --domain-identifier com.chriskonstad.lighteditor --source <folder of RAWs> --destination Documents/Diagnostics/in
xcrun devicectl device process launch --device <udid> --console --terminate-existing com.chriskonstad.lighteditor -- -DiagnoseRemove YES
```

It logs timings, memory and errors (`DIAG` lines), and writes before/after crops for each engine plus a 1024 fill per compute unit to `Documents/Diagnostics/out`. Copy them back with `devicectl device copy from`. The phone must be unlocked. Installing a Debug build replaces the TestFlight build until the next upload.


## Render benchmark on a device

`-RenderBenchmark YES` (Debug builds) times the preview paths on the first ARW in `Documents/Diagnostics/in`: the 2560 px decode, Fit from the decode vs screen-sized proxies, 100% from the lazy RAW vs cached tiles, and the histogram. It prints `BENCH` lines and writes `Documents/Diagnostics/out/bench.txt`. Copy the RAW in and launch it the same way as the removal diagnostic above.
