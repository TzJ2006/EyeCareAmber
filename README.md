# Amber

> [中文文档](README.zh-Hans.md)

[![CI](https://github.com/TzJ2006/EyeCareAmber/actions/workflows/ci.yml/badge.svg)](https://github.com/TzJ2006/EyeCareAmber/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

A menu-bar lighting tool for macOS 15+. Native on Apple Silicon. Steady-state CPU: 0.0%.

---

## Quick start

### Download

Grab the universal build from [Releases](https://github.com/TzJ2006/EyeCareAmber/releases).

```bash
unzip Amber-1.1.0-universal.zip
mv Amber.app /Applications/
xattr -dr com.apple.quarantine /Applications/Amber.app
open /Applications/Amber.app
```

**The `xattr` line is required.** Release builds are ad-hoc signed, not notarized — there is no paid Apple Developer certificate behind this project. macOS quarantines anything downloaded from the internet it cannot verify and refuses to launch it. If you would rather not run that command, build from source instead; a locally built app never acquires the quarantine flag.

### Build from source

```bash
git clone https://github.com/TzJ2006/EyeCareAmber.git
cd EyeCareAmber && ./build.sh --install
```

The build product is `build/Amber.app`. `--install` copies it to `/Applications` and launches it. Look for the icon in the menu bar.

```bash
./build.sh              # arm64 only (recommended)
./build.sh --universal  # arm64 + x86_64
```

---

## Approach: why not an overlay window

Most similar tools **paint a translucent yellow overlay**. Amber instead **writes the display gamma lookup table (LUT)** — the same path used by f.lux and system Night Shift.

| | Overlay window | Gamma LUT (this project) |
|---|---|---|
| Ongoing cost | Compositor blends an extra fullscreen layer every frame | **0** — written once into the display pipeline, then applied by scan-out hardware |
| Coverage | Cannot cover windows above it | All screens, all windows, fullscreen apps, games, menu bar, Dock |
| Contrast | Adds light on top; blacks go gray | Scales output; black stays black |
| Screenshots / recording | Captured in the image | Not affected (usually a plus) |

Trade-off: a few capture cards / virtual displays cannot accept LUT writes. The app detects that and falls back to an overlay, or you can force overlay in Advanced settings.

The overlay is used only for explicit “extra dimming” or when LUT is unavailable. Science presets use 0 extra dimming at night; the window stays closed when not needed.

### Division of labor with system auto-brightness

Keep macOS auto-brightness on. The system owns the ambient light sensor and hardware backlight. Amber does not read the ALS and never sets system brightness; it only applies relative LUT attenuation on top of the current backlight.

On the built-in display Amber does read the resulting backlight, in nits, from `AppleARMBacklight` in the IORegistry. That closes the loop that relative attenuation alone cannot: the same ×0.75 factor is 119 nits at a 400-nit backlight and 8.9 nits at 30 nits, and the second one is below every published comfort floor. Once the screen is already dark enough, Amber stops dimming further — it never makes the display harder to read than leaving it off. External displays and Intel Macs have no such node, so there the time curve runs on relative attenuation only.

### Power design

- **No polling loop.** A single `DispatchSourceTimer`; the next fire time comes from the scheduler.
- **Adaptive steps on ramps** by perceptual thresholds, not a fixed interval. CCT threshold 5 mired, brightness 0.8% — both below what the eye can resolve under gradual, no-reference conditions. Flat ends of the curve can sleep for tens of minutes; only the steep middle wakes every few tens of seconds.
- **Generous leeway** (300 s on plateaus) so the kernel can coalesce wakes with other processes.
- **No LUT write if gains are unchanged.**
- **UI updates only while the menu is open.**
- No `CVDisplayLink`, no per-frame callbacks, no resident background thread.

Measured: ~271 timer wakes in 24 hours (about once every 5 minutes). For comparison, an idle Mac has thousands of timer wakes per second.

---

## Evidence base

Three things the literature does **not** support — so this app is not built on them:

1. **Screen blue light does not damage the eyes.** The American Academy of Ophthalmology’s position is that blue light from digital devices neither causes eye strain nor eye disease. Screen blue light is about one-thousandth the intensity of daylight.
2. **Blue-blocking glasses have no proven effect on eye strain.** A 2023 Cochrane review (17 studies, 619 people) found that, at short follow-up, blue-filtering lenses **may not** reduce computer-related eye strain versus clear lenses, with no difference in best-corrected acuity and no evidence of retinal protection.
3. **Digital eye strain is driven mainly by how we use our eyes, not by spectrum.** Lower blink rate, sustained accommodation, dry eye — those are the usual sources. The useful advice is the 20-20-20 rule (every 20 minutes, look 20 feet away for 20 seconds).

**So the evidence-backed goals of this software are not “eye protection,” but “reduce nighttime light’s interference with circadian rhythm and sleep,” plus lowering screen-to-room contrast in the evening.** Both of those are well supported.

### Light dose: where the numbers come from

Brown et al. (2022, *PLOS Biology*) is the leading expert consensus, signed by core circadian researchers including Brainard, Cajochen, Czeisler, and Lockley. It uses **melanopic EDI** (melanopic equivalent daylight illuminance, CIE S 026:2018) and recommends:

| Period | Recommended melanopic EDI (vertical, at the eye) |
|---|---|
| Daytime | **≥ 250 lux** |
| 3 hours before bed | **≤ 10 lux** |
| During sleep | **≤ 1 lux** (≤ 10 lux for necessary nighttime activity) |

It also states that daytime light **should** be rich near the melanopsin peak, and evening light should be depleted in that band.

**That directly shapes this app’s curve: daytime is deliberately not yellowed.** Short-wavelength light by day is a positive circadian input; all-day warmth works against you.

### Why brightness must drop too

Nagare, Plitnick & Figueiro (2019) measured iPad Night Shift’s effect on melatonin. Screen brightness was held at maximum throughout. Less Warm (5997 K) suppressed melatonin 19% after two hours, More Warm (2837 K) 12% — no significant difference between the two settings, and **all conditions still suppressed melatonin significantly relative to the dim control**. The study had no Night-Shift-off arm, so it cannot say what Night Shift is worth against a native screen; what it does show is that moving the slider from coldest to warmest, at unchanged brightness, does not rescue you.

Conclusion: **changing spectrum alone, without lowering intensity, is not enough to avoid melatonin suppression.**

Presets therefore combine spectrum and dose: bedtime 4300 K ×0.55 (~42.6% relative model output); deep night 2700 K ×0.56 (~30.0%). The factor is LUT attenuation on top of system backlight, not hardware brightness. Sliders show both the factor and model “relative output.”

The night pair is chosen to satisfy both endpoints at once. Luminance is fixed first: about 30% relative output lands near 36 cd/m² at a typical dim-room backlight, matching the low-stimulus arm of Li et al. (2026) that improved DLMO, cortisol, subjective sleep, visual fatigue **and** cognition together — the one measured luminance where both endpoints move the right way. A screen that is too dim is itself a fatigue source (Yu & Akita 2019: 9 cd/m² provoked physical, psychological and visual fatigue; 25 cd/m² only visual).

Colour temperature is then picked where the two cost curves cross. Holding that luminance, melanopic output falls roughly linearly as the screen warms, but the blue channel collapses: going from 2700 K down to 1950 K buys about 5 more points of melanopic reduction while the blue gain drops 27-fold, from 0.101 to 0.0037, which turns blue interface elements black. Going warmer than 2700 K is where you stop paying for what you get.

### Wavelength choice

Melanopsin on ipRGCs peaks near 480 nm; after pre-retinal filtering the effective peak is about **490 nm** — the main channel for melatonin suppression and circadian phase shift. The built-in curve uses a Govardovskii A1 visual-pigment template (λmax = 490 nm); self-test confirms the peak at 490 nm.

Night intervention studies commonly use amber filters that **cut below ~550 nm**. RCTs by Burkhart & Phelps (2009) and Shechter et al. (2018) found better subjective and objective (actigraphy) sleep after wearing amber lenses for 2 hours before bed. Amber’s deep-night default is 2700 K, the warmest colour temperature with direct melatonin data behind it (Nagare, Rea, Plitnick & Figueiro 2019 measured 18.4% suppression at 2700 K against 24.7% at 6500 K); the verified literature has nothing at all between about 3000 K and 4400 K. The sliders still reach 1950 K for anyone who wants maximum amber, and stop there because below about 1930 K the blue gain clamps to exactly zero and nothing further changes.

### Why evening dimming exists

ISO 9241-303 suggests 100–150 cd/m² for screens at 500 lx horizontal illuminance. Under low light the comfortable band is far lower, though the literature is not tight about where: published optima for dark rooms span roughly 20–65 cd/m², a fivefold spread across studies. Amber treats 20 cd/m² as a floor rather than a target. Keeping noon-level screen brightness after dark is a major source of evening discomfort — hence the dusk transition.

---

## Features

### Smart mode

Scheduled from wake / bedtime anchors:

| Phase | When | Default |
|---|---|---|
| Day | Wake → 3 h before bed | 6500 K ×1.00 |
| Dusk | From sunset (if earlier than the boundary above) | Smooth to ~5280 K ×0.84 |
| Bedtime | From 3 h before bed; 90 min ramp then hold | 4300 K ×0.55 |
| Deep-night sleep aid | From bedtime; 45 min ramp then hold | 2700 K ×0.56, no extra dimming |
| Dawn | 30 min before wake | Return to day values |

Transitions use smoothstep; CCT interpolates in mired space (perceptually linear for color temperature).

### Sunrise / sunset sources

Four options; default is the second:

| Source | Notes |
|---|---|
| Off | Schedule from wake / bedtime only |
| **Follow system appearance** (default) | macOS Appearance → Auto switches to Dark at sunset. Listening for `AppleInterfaceThemeChangedNotification` infers sunset. **No location permission, no continuous power cost.** Requires Appearance set to Auto |
| Use location | CoreLocation fetches coordinates once, caches locally; all later math is local |
| Manual coordinates | Enter lat/lon; 0.1° is enough (error < 1 minute) |

Sunrise/sunset use the NOAA Solar Calculator locally. Self-test checks:

| Place / date | This app | Reference |
|---|---|---|
| Greenwich 2025-06-21 | Sunrise 03:42, sunset 20:20 UTC | 03:43, 20:21 |
| Greenwich 2025-12-21 | Sunrise 08:03, sunset 15:52 UTC | 08:04, 15:53 |
| Beijing 2025-03-20 | Sunrise 06:18, sunset 18:25 CST | 06:19, 18:26 |

### Manual mode

Sliders for CCT (1950–6500 K), LUT factor, and extra dimming; manual defaults 4500 K ×0.80. Night CCT range is 1950–4500 K. With night sleep aid on, entering the deep-night window still switches to more conservative values.

### Live metrics

The menu shows, for the current settings:

- **Melanopic output** — light that drives melatonin suppression, relative to native white at full brightness
- **Relative output** — photopic model output after LUT and overlay
- **Blue-channel attenuation** — model attenuation after LUT and overlay

Values use a spectral model of a typical LED-backlit sRGB panel. **They describe relative screen output for comparison only — not hardware brightness, lux, nits, or absolute mEDI.**

Reference numbers:

| Preset | Melanopic output | Relative output | Assumed backlight 30 / 120 / 400 nits |
|---|---|---|---|
| Day 6500 K ×1.00 | 99.9% | 100% | 30 / 120 / 400 nits |
| Bedtime 4300 K ×0.55 | 32.8% | 42.6% | 12.8 / 51.1 / 170.4 nits |
| Deep night 2700 K ×0.56 | 15.3% | 30.0% | 9.0 / 36.0 / 120.1 nits |

Absolute-brightness columns are scenarios for a given backlight, not runtime measurements or guarantees.

---

## Self-tests

```bash
swift run Amber --selftest             # Color science, melanopsin curve, solar times, 24 h schedule walk-through
swift run Amber --compare-presets      # Compare v1/v2 presets; relative metrics and backlight scenarios
swift run Amber --apply 2700 0.62      # End-to-end LUT write accuracy + restore
swift run Amber --restore-test         # Confirm restore does not damage display calibration
swift run Amber --render-ui out.png    # Offscreen-render the menu UI to PNG
python3 Scripts/check-localization.py  # Four-locale key parity + locale codes vs build product
python3 Scripts/check-readme-parity.py  # Keep README.md and README.zh-Hans.md in sync
```

The “locale code vs build product” check in `check-localization.py` exists for a real reason: the source directory is `Resources/zh-Hans.lproj`, but SwiftPM lowercases it to `zh-hans.lproj` inside `Amber_Amber.bundle`. `Bundle.path(forResource:ofType:)` matches the resource table by exact string; a case mismatch returns nil and the Chinese UI silently falls back to raw keys — no compile error, only visible when you switch to Chinese. Always check the **build product**, not the source tree.

`--render-ui` needs neither Accessibility permission nor clicking the menu bar: it hosts the real `MenuContentView`, runs full layout, and screenshots — catching overflow, narrow controls, and contrast issues that compile-time checks miss.

`--restore-test` writes a nonlinear fake calibration with an S-curve, runs the full “capture baseline → apply → restore” loop, compares the whole table pointwise, and subtracts a write-then-read control to isolate table-length resampling noise.

**Why that test exists:** an early implementation called `CGDisplayRestoreColorSyncSettings()`, which on built-in XDR panels wiped the system-loaded calibration to a linear ramp and did not restore it — permanently breaking the user’s display calibration until re-login. Restore now writes back the original LUT captured at launch; attributable error 0.000000.

---

## Known limitations

- **Do not run system Night Shift at the same time.** It works below the gamma layer, so it does not overwrite the LUT — the two warmings multiply instead, and the result is warmer than either intends. Tools that *do* fight over the same table are f.lux, Lunar, BetterDisplay and MonitorControl; every 15 minutes Amber checks whether one of them overwrote it and, if so, adopts that table as the new baseline — damage control, not a good setup.
- Absolute nits are readable on Apple Silicon built-in displays only, and through an undocumented IORegistry key that Apple may rename. On external displays, on Intel Macs, or if that key moves, Amber falls back to relative attenuation and the comfort floor cannot be enforced.
- Dimming through the LUT scales white but not black, so on an LCD the on-screen contrast ratio falls with the output factor. On the mini-LED XDR panels the loss is irrelevant; on a MacBook Air it is not.
- Writing gamma tables makes macOS turn off HDR/EDR while Amber is active.
- There are reports (FB18559786, FB19136488) of `CGSetDisplayTransferByTable` being silently ignored on Apple Silicon built-in displays while “Automatically adjust brightness” is on. It reproduces on some macOS builds and not others; `--apply` verifies by reading the table back, so run it if colours never change.
- Room light can dominate dose at the eye; relative melanopic metrics describe the screen model only, not room total light or absolute mEDI.
- Exposure duration is part of dose. In Wood et al.’s tablet study, one hour at max brightness alone did not significantly suppress melatonin; two hours did. Amber does not track usage time.
- LUT changes do not appear in screenshots or screen recordings.
- A few capture cards / virtual displays cannot write LUTs; the app falls back to an overlay.
- The overlay sits above `CGShieldingWindowLevel` and can cover system alerts (clicks pass through).
- Launch-at-login uses `SMAppService`; the app must be signed (`build.sh` ad-hoc signs) and at a stable path — prefer `/Applications`.

---

## Code layout

```
Sources/Amber/
  main.swift              Entry; handles diagnostic flags first
  AmberApp.swift          MenuBarExtra + AppDelegate + signal handling
  Diagnostics.swift       Self-test / verification tools
  Localization.swift      Four-locale string tables and formatting
  Core/
    ColorScience.swift    CIE CMFs, Planckian locus, melanopsin, melanopic metrics
    SolarClock.swift      NOAA sunrise/sunset
    SolarProvider.swift   Unified solar info sources
    Schedule.swift        Time → light target (pure) + adaptive stepping
    Settings.swift        Persistence with tolerant decoding
    GammaController.swift LUT I/O, baselines, lossless restore, overwrite detection
    OverlayController.swift Overlay (extra dim / fallback only)
    Engine.swift          Orchestration + low-power timing + system events
  UI/
    MenuContentView.swift Menu UI
  Resources/
    {en,fr,es,zh-Hans}.lproj/Localizable.strings
Scripts/
  check-localization.py   Localization integrity checks
```

`Schedule.evaluate` and `ColorScience` are pure functions with no system APIs — that is why self-tests can cover the core logic.

---

## References

- Brown TM, Brainard GC, Cajochen C, et al. (2022). Recommendations for daytime, evening, and nighttime indoor light exposure to best support physiology, sleep, and wakefulness in healthy adults. *PLOS Biology* 20(3): e3001571. https://doi.org/10.1371/journal.pbio.3001571
- Singh S, Keller PR, Busija L, McMillan P, Makrai E, Lawrenson JG, Hull CC, Downie LE (2023). Blue-light filtering spectacle lenses for visual performance, sleep, and macular health in adults. *Cochrane Database of Systematic Reviews* 8: CD013244. https://doi.org/10.1002/14651858.CD013244.pub2
- Nagare R, Plitnick B, Figueiro MG (2019). Does the iPad Night Shift mode reduce melatonin suppression? *Lighting Research & Technology* 51(3): 373–383. https://doi.org/10.1177/1477153517748189
- Wood B, Rea MS, Plitnick B, Figueiro MG (2013). Light level and duration of exposure determine the impact of self-luminous tablets on melatonin suppression. *Applied Ergonomics* 44(2): 237–240. https://doi.org/10.1016/j.apergo.2012.07.008
- Burkhart K, Phelps JR (2009). Amber lenses to block blue light and improve sleep: a randomized trial. *Chronobiology International* 26(8): 1602–1612.
- CIE S 026/E:2018. *System for Metrology of Optical Radiation for ipRGC-Influenced Responses to Light.*
- Govardovskii VI, Fyhrquist N, Reuter T, et al. (2000). In search of the visual pigment template. *Visual Neuroscience* 17(4): 509–528.
- Wyman C, Sloan PP, Shirley P (2013). Simple analytic approximations to the CIE XYZ color matching functions. *Journal of Computer Graphics Techniques* 2(2): 1–11.
- Kim YS, et al. (1996). Cubic polynomial approximation of the Planckian locus (1667–25000 K).
- American Academy of Ophthalmology. *Should You Be Worried About Blue Light?* https://www.aao.org/eye-health/tips-prevention/should-you-be-worried-about-blue-light
- ISO 9241-303:2011. *Ergonomics of human-system interaction — Requirements for electronic visual displays.*

---

## Contributing

Before changing code, run these three — they cover the easiest regressions:

```bash
swift build && swift run Amber --selftest && python3 Scripts/check-localization.py
```

When changing light parameters, always check `--compare-presets` for the net effect on **melanopic dose**. The biggest pitfall this project hit: tuning CCT from one paper without recomputing dose afterward — visual-fatigue and circadian literature optimize **different endpoints**, and their optima often conflict.

New UI copy must be added to all four `Localizable.strings` files (`en` / `fr` / `es` / `zh-Hans`); a missing key shows as the raw key in that locale.

## License

[MIT](LICENSE)

This project is not a medical device and does not give medical advice. Parameters are **engineering starting points** from public literature, not clinical thresholds. Individual sensitivity to nighttime light can vary by more than an order of magnitude (Phillips et al., 2019). For sleep or eye conditions, see a professional.
