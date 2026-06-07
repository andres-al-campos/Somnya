# Somnya — Per-Sleep Stats Spec (tiered: MEASURED / ESTIMATED / GUESSED)

This is the **reference spec** for the per-sleep stats breakdown. The Python proto
(`somnya_analyze.stats.compute_sleep_stats`) implements it against real exports; the eventual
SwiftUI `SleepStats` view renders the same numbers natively. Logic is frozen here first so we
never build the pretty version against unsettled math.

## The one rule everything obeys

> **The app reports what it MEASURED. It clearly labels what it ESTIMATED. It refuses to GUESS
> with a confident face.**

This is the hard lesson from June 2026: *stillness ≠ sleep depth*. Lying awake-but-still looks
identical to deep sleep on the accelerometer. So every stat carries a **tier**, and the UI must
render the tier visibly (icon/color), never flatten all three into one truthy-looking list.

## The three tiers

| Tier | Meaning | Visual intent (SwiftUI later) | Examples |
|------|---------|-------------------------------|----------|
| **MEASURED** | Direct sensor fact. Trust it. | Solid, full-opacity, ✓ | time in bed, set-down time, movement vs still, longest still stretch, # stirs, posture distribution, pressure drift |
| **ESTIMATED** | Derived with a known, honest confidence. Show the number AND the confidence. | Confidence-colored (green→red), shows ±/conf | breathing rate (where confident), breathing regularity, heartbeat (only if conf clears bar) |
| **GUESSED** | We genuinely don't have the signal. Don't fabricate. | Greyed / "not enough data" placeholder | sleep stages, "sleep quality" / depth score, total sleep time (as opposed to time in bed) |

A stat can **change tier per session**: breathing is ESTIMATED on a night with confident windows,
but degrades to GUESSED if no window cleared the confidence bar. The tier is computed, not fixed.

---

## Stat catalog

All inputs are real fields in the JSON export (verified against
`somnya-session-2026-06-06T23-38-41.json`). Per-window unless noted. `W = window_seconds` (30s).
`surface` = the `on_surface`-classified subset (phone resting, not in-hand) from
`classify_phone_state`.

### MEASURED — accelerometer + gravity + barometer facts

| Stat | Field(s) | Formula | Notes |
|------|----------|---------|-------|
| `time_in_bed_min` | `session.start/end`, or first→last window | `(end - start)` in minutes | NOT sleep time. Honestly named. |
| `set_down_min` | `on_surface` | first index of a 6-window (3 min) sustained surface run → its `minutes` | when in-hand → on-bed handoff happened; null if never set down |
| `in_hand_min` / `on_surface_min` | `on_surface` | count×W of each, in minutes | the trusted analysis window is on-surface only |
| `still_pct` | `accel_activity_count` | % of **surface** windows with `activity < movementThreshold (0.6)` | the calibrated still test |
| `longest_still_min` | `immobility_run_length` (new exports) **or** recomputed from `activity` | max run × W, in minutes | fixed-threshold bug now resolved; recompute for legacy files |
| `movement_events` | `accel_activity_count` (+ `gravity_*`) | consecutive moved windows (`activity ≥ 0.6`) collapse into one event at peak intensity; split small/large at `1.5`; flag `repositioned` if gravity vector moved > 0.15 across it | **The single highest-confidence signal in the app** — activity/jerk/rms corr ≈ 0.97, events spike 3-30× over baseline. Powers the timeline (• small ● large ↻ reposition). Intensity is MEASURED; the *semantic* "roll-over" label is only ESTIMATED via the gravity flip, calibrated once a night with real position changes exists. |
| `disturbed_min` | `accel_activity_count` | count of moved windows × W | The honest ONE-WAY depth inference: movement rules deep sleep OUT here, but stillness can NOT rule it in. A confident NEGATIVE depth marker only. |
| `posture_dist` | `gravity_x/y/z` | classify each surface window → {screen-up, face-down, left, right, head-up/down}; % each | heuristic; phone orientation, calibrate to body later |
| `position_changes` | posture labels | # of label flips across surface windows | restlessness proxy (independent of movement_events) |
| `pressure_drift_kpa` | `pressure_kpa` | `last - first` | context only (weather/altitude); steady fall ~ worse weather |

### ESTIMATED — periodic signals with a confidence number

| Stat | Field(s) | Formula | Confidence rule |
|------|----------|---------|-----------------|
| `breathing_rate_bpm` | `breathing_rate_bpm` + `breathing_confidence` | mean over surface windows where `conf ≥ breathingMinConfidence (0.3)` | **n_confident / n_surface**. If 0 confident windows → tier drops to GUESSED. Report median + the count, never a mean over noise. |
| `breathing_regularity` | confident `breathing_rate_bpm` | std (brpm) of the confident windows; lower = steadier | only meaningful with ≥ ~6 confident windows; else GUESSED. The ONE weak depth hint — label it as such. |
| `heartbeat_bpm` | `accel_envelope` → BCG (band-pass + autocorr) | `heartbeat_detect` mean rate over windows with `conf ≥ 0.40` | strict bar (0.40). Below it → GUESSED ("not yet measurable on this device"). Currently ~0.37 → expect GUESSED until more data / higher Hz. |

### GUESSED — withheld until the signal exists

| Stat | Why withheld | What it needs |
|------|--------------|---------------|
| `sleep_stages` (light/deep/REM) | `assigned_stage` is `'unknown'`, no stager runs. Stillness ≠ depth. | reliable HRV (→ reliable heartbeat) + a validated stager |
| `sleep_quality_score` / depth | would be a movement-based lie | HRV, HR-dip, breathing-regularity all reliable together |
| `total_sleep_time` | can't tell asleep-still from awake-still | sleep/wake classifier, which needs the above |

**Rendering rule for GUESSED:** show the label + a one-line *honest reason* ("Not enough signal to
tell deep from light sleep yet — needs reliable heartbeat data"), never a number. This is a feature,
not a gap: it's *why* someone would trust Somnya over a tracker that invents a sleep score.

---

## Output shape (proto → SwiftUI contract)

`compute_sleep_stats(df)` returns a list of `Stat` records, each:

```
Stat(
  key:        str           # "breathing_rate_bpm"
  label:      str           # "Breathing rate"
  tier:       MEASURED | ESTIMATED | GUESSED
  value:      float | str | None   # None when GUESSED
  unit:       str           # "brpm", "min", "%", ""
  confidence: float | None  # 0..1, only for ESTIMATED
  detail:     str           # human one-liner; for GUESSED, the honest "why not"
)
```

The SwiftUI view maps tier → visual treatment and confidence → the green→…→red color from
`CONF_CMAP` (already defined). Same semantics everywhere: position = value, color = confidence.

## Confidence display thresholds (shared with the chart)

- `breathingMinConfidence = 0.30` (config) — the per-window keep bar for breathing.
- `heartbeat trust bar = 0.40` — below this, heartbeat is GUESSED, not reported.
- Session-level confidence for an ESTIMATED stat = **fraction of usable windows that cleared the
  bar** (coverage), not the mean peak height. "We could read your breathing 40% of the night" is
  more honest than averaging a confidence.
