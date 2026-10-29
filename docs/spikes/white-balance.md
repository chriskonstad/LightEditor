# Spike M0.5: where white balance lives

Status: **decided: grade stage.**

## Measurement

On the A7R V file at preview size (2560 px), M4 Pro Mac, RAW 9:

| Change | Re-render cost |
| --- | --- |
| `CIRAWFilter.neutralTemperature` changed on an existing filter | about 30 ms |
| Noise reduction changed on an existing filter | about 30 ms |
| Exposure (RAW filter's own) changed | about 30 ms |
| Grade-stage white balance on the cached RGBA16F decode | part of the about 3 ms total grade frame |

Changing white balance on the RAW filter does not trigger the full multi-second RAW 9 decode; the filter caches its demosaic internally. But at about 30 ms on an M4 Pro, it is still several frames on M1, and it would put the RAW filter back in the slider loop.

## Decision

White balance runs in the grade stage with `CITemperatureAndTint` on the cached linear decode. It maps the chosen temperature/tint onto the decoder's as-shot white point (`neutralTemperature`/`neutralTint`, read once per photo).

- The recipe stores absolute Kelvin and tint. Absent means "as shot".
- Pasting in "Adjust by" mode uses the source photo's as-shot values (carried in `RecipeClip.sourceDefaults`), so a +500 K change transfers as +500 K.
- The tradeoff: grade-stage WB is a chromatic adaptation on rendered linear RGB, not a change to the camera-space neutral. Large corrections (more than about ±2000 K) may differ slightly from Lightroom. Revisit if users notice, e.g. by doing a RAW-stage WB re-decode on slider release.
