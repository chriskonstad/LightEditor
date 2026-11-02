# Test fixtures

Real camera files for the tests that need them: RAW decoding, Vision masks, auto
straighten, camera looks and performance. They're large, so the package doesn't bundle
them; `scripts/test.sh --raw` (or `EDITORCORE_RAW_FIXTURES=Fixtures`) runs those tests on
this folder. They also make a quick sample library for the simulator or the Mac app (see
`docs/spikes/simulator-tooling.md`).

Photos by Chris Konstad, included so anyone can run the tests. Location data isn't
recorded in any of them.

| File | Camera | Shot in | Notes |
| --- | --- | --- | --- |
| `DSC04319.ARW` | Sony A7R V | Creative Look ST, Clarity +1, Sharpness +4 | Street scene; ST reference for camera looks |
| `DSC04921.ARW` | Sony A7R V | Creative Look ST, Clarity +1, Sharpness +4 | Cat by a window; ST reference |
| `DSC06383.ARW` | Sony A7R V | Creative Look FL, Clarity +1, Sharpness +4, WB auto with A+1.5 shift, DRO auto | FL reference: the FL preset is fitted to its embedded JPEG |
| `DSCF2030.raf` | Fujifilm X-T5 | Nostalgic Neg. | Sunset; auto straighten uses the camera's level |
| `DSCF2763.jpg` | Fujifilm X-T5 | | A camera JPEG, for non-RAW paths |

Each RAW's embedded preview is the camera's own JPEG of that look, so
`CameraLookMatchTests` can measure how close a preset gets (set `CAMERA_LOOK_CHECK` to a
folder for side-by-side images, and `CAMERA_LOOK_TUNE=FL` to refit a look).
