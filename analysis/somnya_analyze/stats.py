"""Per-sleep stats, tiered MEASURED / ESTIMATED / GUESSED.

Reference implementation of STATS_SPEC.md. The eventual SwiftUI `SleepStats` view renders the same
records natively; this proto freezes the math and validates it against real exports first.

The one rule: report what we MEASURED, label what we ESTIMATED, refuse to GUESS with a confident
face. Stillness ≠ sleep depth — depth stays GUESSED until HRV/heartbeat are reliable.

Usage:
    uv run somnya-stats path/to/somnya-session-*.json
"""

from __future__ import annotations

import argparse
import sys
from dataclasses import dataclass
from enum import Enum
from pathlib import Path

import numpy as np
import pandas as pd

from . import (
    HEART_MIN_BPM,
    HEART_MAX_BPM,
    BREATHING_MIN_BPM,
    BREATHING_MAX_BPM,
    _bandpass_bpm,
    _estimate_breathing,
    _estimate_periodic_peak,
    _surface_only,
    load,
)


class Tier(str, Enum):
    MEASURED = "MEASURED"     # direct sensor fact — trust it
    ESTIMATED = "ESTIMATED"   # derived, with an honest confidence
    GUESSED = "GUESSED"       # signal not available — withheld, not fabricated


@dataclass
class Stat:
    key: str
    label: str
    tier: Tier
    value: object            # float | str | None (None when GUESSED)
    unit: str = ""
    confidence: float | None = None   # 0..1, ESTIMATED only
    detail: str = ""

    def render(self) -> str:
        if self.tier is Tier.GUESSED:
            return f"  [GUESSED]   {self.label}: — ({self.detail})"
        val = self.value
        valstr = f"{val:.1f}" if isinstance(val, float) else str(val)
        conf = f"  conf={self.confidence:.0%}" if self.confidence is not None else ""
        tag = "[MEASURED]" if self.tier is Tier.MEASURED else "[ESTIMATED]"
        line = f"  {tag:11s} {self.label}: {valstr} {self.unit}".rstrip()
        if conf:
            line += conf
        if self.detail:
            line += f"   — {self.detail}"
        return line


@dataclass
class MovementEvent:
    """One discrete movement detected during the night. MEASURED — the highest-confidence thing the
    app produces: activity/jerk/rms all spike together (corr ≈ 0.97) far above the still baseline, so
    THAT a movement happened and WHEN is unambiguous. `large` is an intensity split (small = sheets/
    twitch, large = roll/reposition/sit-up), not a semantic claim about what the movement WAS."""
    minute: float
    activity: float
    large: bool
    repositioned: bool = False   # gravity vector flipped here → body orientation actually changed

    def render(self) -> str:
        dot = "●" if self.large else "•"
        kind = "large" if self.large else "small"
        repo = "  ↻ reposition (orientation changed)" if self.repositioned else ""
        return f"  {dot} min {self.minute:6.0f}  activity={self.activity:5.2f}  [{kind}]{repo}"


# Bars (mirror SomnyaConfig + STATS_SPEC).
MOVEMENT_THRESHOLD = 0.6        # SomnyaConfig.movementThreshold — still vs moved
LARGE_MOVEMENT_THRESHOLD = 1.5  # small (sheets/twitch) vs large (roll/reposition/sit-up).
                                # Natural valley in real data: small movements cluster 0.6-1.3,
                                # then a clear gap to the big ones (2.3, 2.6, 9, 10.6). Intensity
                                # only — NOT a semantic "roll-over" claim (that needs gravity flip).
BREATHING_KEEP_CONF = 0.30      # SomnyaConfig.breathingMinConfidence
# Adaptive multi-scale breathing recovery: a 30s window holds only ~7 breaths @15brpm — often too few
# for the autocorrelation to confirm the rhythm (peak < keep bar). Concatenating neighbours into a
# longer window (~22 breaths @90s) recovers those failures at the SAME rate (verified median 16.0 brpm
# either way), no harmonic risk (breathing is a smooth near-sinusoid, not a sharp BCG pulse). A
# window-size sweep showed plain longer windows trade coverage for accuracy — a 270s window recovers
# more but BLURS the rate (breathing drifts across it). So we ESCALATE only as needed: try radius 1
# (~90s) first, grow to radius BREATHING_RECOVER_MAX_RADIUS only if still failing. Calm windows clear
# short & accurate; only stubborn ones grow → ~150s coverage at ~90s accuracy.
BREATHING_RECOVER_MAX_RADIUS = 2  # max neighbours each side (radius 1=~90s, 2=~150s) before giving up
HEARTBEAT_TRUST_BAR = 0.40      # STATS_SPEC heartbeat trust bar
MIN_CONFIDENT_FOR_REGULARITY = 6  # need enough confident windows for a std to mean anything

# Heartbeat tracker: BCG is a sharp pulse rich in harmonics, so the autocorrelation often has a peak
# at 2x the true rate that can be TALLER than the fundamental — the detector would otherwise flip
# between ~51 and ~95 bpm window to window. Defense: track a running HR and only accept a candidate
# whose move is physiologically plausible for the REAL elapsed time, snapping 2x candidates to half.
HEARTBEAT_MAX_SLEW_BPM_PER_S = 0.5   # sleeping HR changes slowly; tight = clean track, rejects spikes
HEARTBEAT_HARMONIC_TOL = 0.12        # how close to exactly 2x counts as "a harmonic to snap down"

# Multi-scale coverage (two-pass detector). A window-size sweep on real nights showed the tradeoff
# cleanly: long windows (120s) are mostly TRUE (~71% of reads land on the real ~50-55 bpm fundamental,
# harmonics/noise averaged out) but sparse; short windows (15s) catch ~3-4x more moments but ~60% of
# their reads are noise/harmonic false-positives. So: PASS 1 builds a trustworthy ANCHOR track from
# long windows; PASS 2 walks short windows and keeps a read ONLY if it agrees with the anchor — short
# windows supply coverage, the anchor supplies the truth that filters their false-positives.
HEARTBEAT_ANCHOR_WIN_S = 120.0       # long window: high % real, locks the true fundamental
HEARTBEAT_INFILL_WIN_S = 15.0        # short window: nimble, catches brief well-coupled moments
HEARTBEAT_INFILL_TOL_BPM = 6.0       # an infill read must land within this of the interpolated anchor


def _window_minutes(df: pd.DataFrame) -> float:
    return float(df.attrs.get("config", {}).get("window_seconds", 30)) / 60.0


def _classify_posture(gx, gy, gz) -> str:
    ax, ay, az = abs(gx), abs(gy), abs(gz)
    if az >= ax and az >= ay:
        return "screen-up" if gz < 0 else "face-down"
    if ax >= ay:
        return "left-side" if gx > 0 else "right-side"
    return "head-up" if gy < 0 else "head-down"


def movement_events(df: pd.DataFrame, gravity_flip: float = 0.15) -> list[MovementEvent]:
    """Discrete movement events for the timeline (dots). Consecutive moved windows collapse into one
    event (a roll spanning two windows is one movement), tagged with peak intensity and a reposition
    flag when the gravity vector flipped across it.

    MEASURED tier: the cleanest signal the app has. We assert THAT and WHEN, and a small/large
    intensity split — never a guess at the movement's meaning."""
    surf = _surface_only(df)
    if "accel_activity_count" not in surf.columns or not len(surf):
        return []
    act = surf["accel_activity_count"].to_numpy(dtype=float)
    mins = surf["minutes"].to_numpy(dtype=float)
    moved = act >= MOVEMENT_THRESHOLD
    has_grav = {"gravity_x", "gravity_y", "gravity_z"}.issubset(surf.columns)
    if has_grav:
        g = surf[["gravity_x", "gravity_y", "gravity_z"]].to_numpy(dtype=float)

    events: list[MovementEvent] = []
    i = 0
    n = len(act)
    while i < n:
        if not moved[i]:
            i += 1
            continue
        j = i
        while j + 1 < n and moved[j + 1]:
            j += 1
        # Event spans windows [i, j]. Peak activity = its intensity.
        peak_idx = i + int(np.argmax(act[i:j + 1]))
        peak = float(act[peak_idx])
        # Reposition: gravity vector before the event vs after it moved appreciably.
        repositioned = False
        if has_grav and i > 0 and j + 1 < n:
            repositioned = float(np.linalg.norm(g[j + 1] - g[i - 1])) > gravity_flip
        events.append(MovementEvent(
            minute=float(mins[peak_idx]), activity=peak,
            large=peak >= LARGE_MOVEMENT_THRESHOLD, repositioned=repositioned))
        i = j + 1
    return events


def compute_sleep_stats(df: pd.DataFrame) -> list[Stat]:
    """Compute the full tiered stat list for one session DataFrame (already loaded via `load`)."""
    wmin = _window_minutes(df)
    stats: list[Stat] = []

    # ---- MEASURED: gross timing & phone state ------------------------------------------------
    total_min = float(df["minutes"].iloc[-1]) + wmin if len(df) else 0.0
    stats.append(Stat(
        "time_in_bed_min", "Time in bed", Tier.MEASURED, total_min, "min",
        detail="span of the recording — NOT time asleep"))

    surf = _surface_only(df)
    has_state = "on_surface" in df.columns and df["on_surface"].any()
    if has_state:
        n = len(df)
        on = int(df["on_surface"].sum())
        stats.append(Stat("on_surface_min", "On the bed (analyzed)", Tier.MEASURED,
                          on * wmin, "min",
                          detail=f"{100*on/n:.0f}% of the night; in-hand time is excluded"))
        # Set-down moment: first 6-window sustained surface run.
        runs = df["on_surface"].to_numpy()
        handoff = next((i for i in range(len(runs) - 6) if runs[i:i + 6].all()), None)
        if handoff is not None:
            stats.append(Stat("set_down_min", "Phone set down at", Tier.MEASURED,
                              float(df["minutes"].iloc[handoff]), "min",
                              detail="in-hand before this, on the bed after"))

    # ---- MEASURED: movement / stillness ------------------------------------------------------
    if "accel_activity_count" in surf.columns and len(surf):
        act = surf["accel_activity_count"].to_numpy(dtype=float)
        still = act < MOVEMENT_THRESHOLD
        stats.append(Stat("still_pct", "Time still", Tier.MEASURED,
                          float(100 * still.mean()), "%",
                          detail=f"activity < {MOVEMENT_THRESHOLD} (calibrated); still ≠ asleep"))
        # Longest still stretch: prefer the device counter if it ever fired, else recompute.
        longest = 0
        if "immobility_run_length" in surf.columns and surf["immobility_run_length"].max() > 0:
            longest = int(surf["immobility_run_length"].max())
        else:
            run = 0
            for s in still:
                run = run + 1 if s else 0
                longest = max(longest, run)
        stats.append(Stat("longest_still_min", "Longest still stretch", Tier.MEASURED,
                          longest * wmin, "min",
                          detail="unbroken low-movement run"))
        # Discrete movement events, split by intensity (small = sheets/twitch, large = roll/sit-up).
        events = movement_events(df)
        n_large = sum(1 for e in events if e.large)
        n_small = len(events) - n_large
        n_repo = sum(1 for e in events if e.repositioned)
        stats.append(Stat("movement_events", "Movements detected", Tier.MEASURED, len(events), "",
                          detail=f"{n_small} small, {n_large} large"
                                 + (f"; {n_repo} repositioned (orientation changed)" if n_repo else "")
                                 + " — see timeline"))

    # ---- MEASURED: posture -------------------------------------------------------------------
    if {"gravity_x", "gravity_y", "gravity_z"}.issubset(surf.columns) and len(surf):
        labels = [_classify_posture(x, y, z) for x, y, z in zip(
            surf["gravity_x"], surf["gravity_y"], surf["gravity_z"])]
        from collections import Counter
        top, topn = Counter(labels).most_common(1)[0]
        flips = sum(1 for a, b in zip(labels, labels[1:]) if a != b)
        stats.append(Stat("posture_main", "Main position", Tier.MEASURED,
                          f"{top} ({100*topn/len(labels):.0f}%)", "",
                          detail="phone orientation (heuristic); calibrate to body later"))
        stats.append(Stat("position_changes", "Position changes", Tier.MEASURED, flips, "",
                          detail="how often orientation flipped"))

    # ---- MEASURED: barometer context ---------------------------------------------------------
    if "pressure_kpa" in df.columns and df["pressure_kpa"].notna().any():
        p = df["pressure_kpa"].dropna().to_numpy(dtype=float)
        stats.append(Stat("pressure_drift_kpa", "Pressure drift", Tier.MEASURED,
                          float(p[-1] - p[0]), "kPa",
                          detail="context only (weather/altitude)"))

    # ---- MEASURED: disturbed time (the honest ONE-WAY depth inference) -----------------------
    # Movement rules deep sleep OUT at that moment (deep sleep requires stillness). The reverse is
    # NOT true — stillness ≠ deep. So this is a confident NEGATIVE marker only: "not deep here",
    # never "deep here". Counts windows with any movement; that's time we KNOW wasn't restful.
    if "accel_activity_count" in surf.columns and len(surf):
        moved_windows = int((surf["accel_activity_count"] >= MOVEMENT_THRESHOLD).sum())
        stats.append(Stat("disturbed_min", "Disturbed time", Tier.MEASURED,
                          moved_windows * wmin, "min",
                          detail="movement → definitely NOT deep sleep here "
                                 "(one-way: stillness can't prove the reverse)"))

    # ---- ESTIMATED: time to fall asleep (body settling into sustained quiet) -----------------
    stats.append(_sleep_onset_stat(df, surf, wmin))

    # ---- ESTIMATED: breathing ----------------------------------------------------------------
    stats.extend(_breathing_stats(surf))

    # ---- ESTIMATED or GUESSED: heartbeat -----------------------------------------------------
    stats.append(_heartbeat_stat(df, surf))

    # ---- GUESSED: the things we honestly can't tell yet --------------------------------------
    stats.append(Stat("sleep_stages", "Sleep stages", Tier.GUESSED, None,
                      detail="can't tell light/deep/REM yet — needs reliable heartbeat (HRV)"))
    stats.append(Stat("sleep_quality", "Sleep quality / depth", Tier.GUESSED, None,
                      detail="won't score quality off movement alone — that's the stillness≠depth trap"))
    stats.append(Stat("total_sleep_time", "Total sleep time", Tier.GUESSED, None,
                      detail="can't separate asleep-still from awake-still without a sleep/wake signal"))

    return stats


def _breathing_recover(s: pd.DataFrame, conf):
    """Adaptive multi-scale recovery pass. For each window that FAILED the confidence bar, retry on a
    longer neighbour-concatenation, ESCALATING the radius (1→…→BREATHING_RECOVER_MAX_RADIUS) only until
    it clears — so calm windows recover at the short, accurate ~90s scale and only stubborn ones grow.
    Fills recovered (rate, conf) in place. Returns (rates, confs) aligned to s. No-op when the per-window
    audio envelope isn't stored."""
    rates = s["breathing_rate_bpm"].to_numpy(dtype=float).copy()
    confs = np.nan_to_num(s["breathing_confidence"].to_numpy(dtype=float)).copy()
    env_col = "filtered_envelope" if "filtered_envelope" in s.columns else (
        "envelope" if "envelope" in s.columns else None)
    if env_col is None:
        return rates, confs
    hz = 4.0  # audio_envelope_hz; the breathing envelope rate
    envs = s[env_col].tolist()
    n = len(s)
    for i in range(n):
        if confs[i] >= BREATHING_KEEP_CONF:
            continue  # already confident — leave it
        for radius in range(1, BREATHING_RECOVER_MAX_RADIUS + 1):  # grow only as far as needed
            parts = [np.asarray(envs[j], float) for j in range(i - radius, i + radius + 1)
                     if 0 <= j < n and isinstance(envs[j], list) and envs[j]]
            if not parts:
                continue
            r, c = _estimate_breathing(np.concatenate(parts), hz)
            if r is not None and c >= BREATHING_KEEP_CONF and BREATHING_MIN_BPM <= r <= BREATHING_MAX_BPM:
                rates[i], confs[i] = r, c  # recovered at the smallest scale that worked
                break
    return rates, confs


def _breathing_stats(surf: pd.DataFrame) -> list[Stat]:
    """Breathing rate + regularity, computed over the CONFIRMED-SLEEP period (post-onset), with a
    multi-scale recovery pass. Three honesty upgrades over the old whole-night version:
      1. Sleep-only: awake/restless windows (high rate-variance, hard to read) no longer pollute the
         numbers — so a calm night stops always reading "irregular".
      2. Recovery: 90s fallback on failed windows lifts coverage (~75%→~93% in calm sleep) at the same
         rate — see _breathing_recover.
      3. Regularity from per-window VARIABILITY (breathing_rate_variability), which actually drops to
         ~1.0 in calm sleep, not whole-night rate std (always inflated by awake periods)."""
    out: list[Stat] = []
    if "breathing_rate_bpm" not in surf.columns or "breathing_confidence" not in surf.columns:
        out.append(Stat("breathing_rate_bpm", "Breathing rate", Tier.GUESSED, None,
                        detail="no breathing data in this session (mic off or pre-analyzer)"))
        return out

    # Scope to confirmed sleep (post-onset). Falls back to the whole on-bed period if onset is unknown.
    onset = sleep_onset(surf)
    s = surf.reset_index(drop=True)
    if onset is not None:
        s = s[s["minutes"] >= onset["settle_min"]].reset_index(drop=True)
    scope = "asleep" if onset is not None else "on-bed"
    n_surf = len(s)
    if n_surf == 0:
        out.append(Stat("breathing_rate_bpm", "Breathing rate", Tier.GUESSED, None,
                        detail="no windows after sleep onset to read breathing from"))
        return out

    rates_all, confs_all = _breathing_recover(s, None)  # multi-scale recovery
    keep = (confs_all >= BREATHING_KEEP_CONF) & np.isfinite(rates_all)
    n_conf = int(keep.sum())
    if n_conf == 0:
        out.append(Stat("breathing_rate_bpm", "Breathing rate", Tier.GUESSED, None,
                        detail=f"0 / {n_surf} {scope} windows cleared the confidence bar "
                               f"({BREATHING_KEEP_CONF:.2f}) — too quiet/buried to trust"))
        return out
    coverage = n_conf / n_surf
    rates = rates_all[keep]
    out.append(Stat("breathing_rate_bpm", "Breathing rate", Tier.ESTIMATED,
                    float(np.median(rates)), "brpm", confidence=coverage,
                    detail=f"median over {n_conf} confident window(s) "
                           f"({coverage:.0%} of {scope} time)"))

    # Regularity from per-window variability during sleep — the signal that actually tracks calm.
    if n_conf >= MIN_CONFIDENT_FOR_REGULARITY and "breathing_rate_variability" in s.columns:
        rv = s["breathing_rate_variability"].to_numpy(dtype=float)[keep]
        rv = rv[np.isfinite(rv)]
        if len(rv):
            reg = float(np.median(rv))
            verdict = ("steady (consistent with deeper rest)" if reg < 1.5
                       else "somewhat variable" if reg < 3.0
                       else "irregular (consistent with light/restless sleep)")
            out.append(Stat("breathing_regularity", "Breathing regularity", Tier.ESTIMATED,
                            reg, "brpm variability", confidence=coverage,
                            detail=f"{verdict} — median per-window variation during sleep; "
                                   "a WEAK depth hint, not a measurement"))
            return out
    out.append(Stat("breathing_regularity", "Breathing regularity", Tier.GUESSED, None,
                    detail=f"only {n_conf} confident {scope} window(s) — too few to read regularity"))
    return out


def _hr_all_peaks(x, hz, min_conf=0.30):
    """Every interior local-max of the heart-band autocorrelation as (bpm, corr), strongest first.
    The tracker needs ALL candidates (not just the tallest) so it can pick the one consistent with the
    running HR rather than blindly taking a harmonic peak that happens to be taller this window."""
    x = np.asarray(x, float); n = len(x); x = x - x.mean()
    energy = float((x * x).sum())
    if energy <= 1e-12 or n <= 4:
        return []
    min_lag = int((60.0 / HEART_MAX_BPM) * hz)
    max_lag = min(n - 1, int((60.0 / HEART_MIN_BPM) * hz))
    if max_lag - min_lag < 2 or min_lag < 1:
        return []
    corr = np.array([float((x[:n - lag] * x[lag:]).sum()) / energy
                     for lag in range(min_lag, max_lag + 1)])
    peaks = []
    for i in range(1, len(corr) - 1):
        if corr[i] > corr[i - 1] and corr[i] >= corr[i + 1] and corr[i] >= min_conf:
            peaks.append((60.0 / ((min_lag + i) / hz), float(corr[i])))
    peaks.sort(key=lambda t: -t[1])
    return peaks


def _hr_global_seed(band, times, hz, win_s):
    """Robust starting HR for the tracker: the MEDIAN of each window's best fundamental across the whole
    night. A single seed window can land on a harmonic (e.g. 91 when the truth is 55); the night-wide
    median can't, because the true rate is by far the most common value and harmonics are outvoted."""
    n = int(win_s * hz)
    if n < 4 or len(band) < n:
        return None
    fundamentals = []
    for start in range(0, len(band) - n + 1, n):
        peaks = [(b, c) for b, c in _hr_all_peaks(band[start:start + n], hz)
                 if c >= HEARTBEAT_TRUST_BAR and HEART_MIN_BPM <= b <= HEART_MAX_BPM]
        if not peaks:
            continue
        top = peaks[0][1]
        strong = [b for b, c in peaks if c >= top * 0.8]  # lowest strong peak = this window's fundamental
        fundamentals.append(min(strong))
    return float(np.median(fundamentals)) if fundamentals else None


def _hr_anchor_track(band, times, hz, win_s, seed=None):
    """Slew-limited heartbeat track on one window size → list of (minute, bpm, conf).

    Three defenses against 2x-harmonic lock-in (the cause of the ~51-vs-~95 bimodal scatter):
      1. Slew limit: a candidate may move the running HR by at most HEARTBEAT_MAX_SLEW_BPM_PER_S × the
         REAL elapsed seconds since the last accepted point (gaps permit big moves, close windows don't)
         — so a real HR rise (gradual) passes but an instant 51→95 teleport (harmonic) is rejected.
      2. Sub-harmonic snap: a candidate ~2× the track is replaced by its half (the true fundamental).
      3. Physiological envelope: HEART_MIN_BPM..HEART_MAX_BPM backstop for wild artifacts.
    `seed` (a global-median HR) pins the starting rate so the track can't begin locked on a harmonic."""
    n = int(win_s * hz)
    if n < 4 or len(band) < n:
        return []
    out = []
    cur = seed
    last_min = None
    for start in range(0, len(band) - n + 1, n):
        minute = float(times[start + n // 2])
        peaks = _hr_all_peaks(band[start:start + n], hz)
        cands = [(b, c) for b, c in peaks
                 if c >= HEARTBEAT_TRUST_BAR and HEART_MIN_BPM <= b <= HEART_MAX_BPM]
        if not cands:
            continue
        if cur is None:
            # No global seed available — fall back to the lowest of the near-strongest peaks.
            top = cands[0][1]
            strong = [b for b, c in cands if c >= top * 0.8]
            cur = min(strong) if strong else cands[0][0]
            out.append((minute, cur, cands[0][1])); last_min = minute
            continue
        if last_min is None:
            # Seeded from the global median: let the first real read land anywhere within the infill
            # tolerance of the seed (the median is robust but approximate), then slew normally after.
            budget = HEARTBEAT_INFILL_TOL_BPM
        else:
            budget = HEARTBEAT_MAX_SLEW_BPM_PER_S * max(1.0, (minute - last_min) * 60.0)
        expanded = list(cands)
        for b, c in cands:
            if abs(b / cur - 2.0) < HEARTBEAT_HARMONIC_TOL * 2 and abs(b / 2 - cur) < abs(b - cur):
                expanded.append((b / 2.0, c))  # snap a ~2x harmonic down to the fundamental
        within = [(b, c) for b, c in expanded if abs(b - cur) <= budget]
        if not within:
            continue  # nothing plausible this window — coast, don't force a point
        b, c = min(within, key=lambda t: (abs(t[0] - cur), -t[1]))
        cur = 0.7 * cur + 0.3 * b  # gentle smoothing toward the accepted candidate
        out.append((minute, cur, c)); last_min = minute
    return out


def _heartbeat_series(df: pd.DataFrame, surf: pd.DataFrame):
    """Two-pass multi-scale heartbeat track over the night → list of (minute, bpm, conf).

    PASS 1 (anchor): a long window (HEARTBEAT_ANCHOR_WIN_S) builds a trustworthy slew-limited track —
      long windows are mostly TRUE (the real fundamental dominates; harmonics/noise average out).
    PASS 2 (infill): short windows (HEARTBEAT_INFILL_WIN_S) catch brief well-coupled moments the long
      windows miss, but only a read that AGREES with the interpolated anchor (within HEARTBEAT_INFILL_
      TOL_BPM) is kept — the anchor's truth filters the short windows' noise/harmonic false-positives.
    The merged, time-sorted points give long-window confidence WITH short-window coverage.
    Returns [] (→ GUESSED) when the envelope is too slow or no confident anchor forms."""
    if "accel_envelope" not in surf.columns:
        return []
    hz = float(df.attrs.get("config", {}).get("accel_envelope_hz", 8.0))
    if hz < HEART_MAX_BPM / 60.0 * 2:
        return []
    chunks, tline = [], []
    for _, row in surf.iterrows():
        env = row["accel_envelope"]
        if isinstance(env, list) and env:
            chunks.append(np.asarray(env, float))
            tline.append(np.full(len(env), float(row["minutes"])))
    if not chunks:
        return []
    stream = np.concatenate(chunks)
    times = np.concatenate(tline)
    band = _bandpass_bpm(stream, hz, HEART_MIN_BPM, HEART_MAX_BPM)

    # PASS 1 — the anchor. Seed from the night-wide median fundamental so the track can't begin locked
    # on a harmonic, then slew-track on long windows. Without an anchor there's no truth to check infill
    # against, so bail to GUESSED.
    seed = _hr_global_seed(band, times, hz, HEARTBEAT_ANCHOR_WIN_S)
    anchor = _hr_anchor_track(band, times, hz, HEARTBEAT_ANCHOR_WIN_S, seed=seed)
    if not anchor:
        return []
    if len(anchor) == 1:
        return anchor  # single long read — nothing to interpolate against; report it as-is

    amins = np.array([m for m, _, _ in anchor])
    arates = np.array([b for _, b, _ in anchor])

    # PASS 2 — infill from short windows, gated by agreement with the interpolated anchor.
    n = int(HEARTBEAT_INFILL_WIN_S * hz)
    infill = []
    if n >= 4 and len(band) >= n:
        for start in range(0, len(band) - n + 1, n):
            minute = float(times[start + n // 2])
            expected = float(np.interp(minute, amins, arates))  # the anchor's truth at this instant
            peaks = _hr_all_peaks(band[start:start + n], hz)
            best = None
            for b, c in peaks:
                if c < HEARTBEAT_TRUST_BAR:
                    continue
                for cand in (b, b / 2.0, b * 2.0):  # allow snapping an octave to meet the anchor
                    if HEART_MIN_BPM <= cand <= HEART_MAX_BPM and abs(cand - expected) <= HEARTBEAT_INFILL_TOL_BPM:
                        if best is None or c > best[1]:
                            best = (cand, c)
                        break
            if best is not None:
                infill.append((minute, best[0], best[1]))

    # Merge anchor + infill, dedup near-coincident minutes (prefer the anchor's value), sort by time.
    merged = list(anchor)
    occupied = list(amins)
    for m, b, c in infill:
        if all(abs(m - om) > HEARTBEAT_INFILL_WIN_S / 60.0 for om in occupied):
            merged.append((m, b, c)); occupied.append(m)
    merged.sort(key=lambda t: t[0])
    return merged


# Sleep-onset estimator. We have NO brain signal, so we can never see "asleep" directly — only the
# BODY's correlates of falling asleep:
#   1. Sustained stillness — awake-in-bed fidgets (immobility run resets to 0); sleep = still & STAYS still.
#   2. Regular breathing — awake breathing is irregular (low breathing_confidence); it steadies at onset.
# THE VALIDATION (the part that makes "fell asleep" trustworthy) is a PERSISTENCE CRITERION borrowed
# from clinical sleep scoring: a moment only counts as durable onset if sleep PERSISTS after it — here,
# the next ONSET_PERSIST_MIN minutes must stay mostly still (movement in < ONSET_PERSIST_MOVED_FRAC of
# windows). Movement is our highest-confidence (MEASURED) signal, so it's the right thing to validate
# with. This cleanly separates "settled for good" from "a lull that didn't stick": on a hot/restless
# night you may briefly doze (a DRIFT) then get pulled back out — only the run that holds is the SETTLE.
# ESTIMATED, ± a few min (body settling ≠ brain N1).
ONSET_IMMOBILITY_RUN = 8        # windows of unbroken stillness that mark a settling attempt (≈4 min @30s)
ONSET_BREATH_CONF = 0.33        # breathing_confidence at/above which the rhythm reads as regular
ONSET_PERSIST_MIN = 10.0        # sleep must persist this many minutes after onset (clinical ~10 min)
ONSET_PERSIST_MOVED_FRAC = 0.05 # ...with movement in < this fraction of post-onset windows. STRICT by
                                # design: "when did I fall asleep?" means "when did I STOP stirring",
                                # not the clinical first-persistent-epoch (which tolerates arousals and
                                # fires earlier than people feel). Near-zero stirring = actually down.


def sleep_onset(surf: pd.DataFrame):
    """Detect when you fell asleep, validated by a clinical persistence criterion. Returns a dict
    {drift_min, settle_min, stirs, confidence} or None. Shared by the stat and the plot so they agree.

      • settle_min — the HEADLINE "fell asleep" time: the first settling attempt after which sleep
        PERSISTS (next ONSET_PERSIST_MIN minutes stay < ONSET_PERSIST_MOVED_FRAC moved). This is the
        durable onset — the moment that actually stuck.
      • drift_min  — an EARLIER settling attempt that FAILED persistence (you briefly dozed, then got
        pulled back out — e.g. too hot). None when onset stuck on the first try (no separate drift).
      • confidence — how cleanly it resolved: high when calm held immediately and little stirring
        preceded it; lower when onset was fitful (a drift→settle gap, lots of pre-onset stirs).

    No brain signal exists, so this is the body's durable settling, not EEG onset — ESTIMATED, ± a few
    min. The hold shrinks for short recordings so naps still validate."""
    if "immobility_run_length" not in surf.columns or not len(surf):
        return None
    s = surf.reset_index(drop=True)
    imm = s["immobility_run_length"].to_numpy(dtype=float)
    mins = s["minutes"].to_numpy(dtype=float)
    bconf = (s["breathing_confidence"].to_numpy(dtype=float)
             if "breathing_confidence" in s.columns else np.zeros(len(s)))
    moved = ((s["accel_activity_count"].to_numpy(dtype=float) >= MOVEMENT_THRESHOLD)
             if "accel_activity_count" in s.columns else np.zeros(len(s), dtype=bool))
    n = len(s)
    # A settling ATTEMPT: stillness run is long AND breathing reads regular.
    attempt = (imm >= ONSET_IMMOBILITY_RUN) & (np.nan_to_num(bconf) >= ONSET_BREATH_CONF)
    if not attempt.any():
        return None

    total_min = float(mins[-1]) if n else 0.0
    persist_min = min(ONSET_PERSIST_MIN, max(2.0, total_min / 4))  # shrink for naps, floor 2 min

    def persists(i):
        """Does sleep hold for persist_min after window i? (movement in < frac of those windows)."""
        end_t = mins[i] + persist_min
        j = int(np.searchsorted(mins, end_t))
        seg = moved[i:max(i + 1, j)]
        return len(seg) > 0 and seg.mean() < ONSET_PERSIST_MOVED_FRAC

    # SETTLE = first attempt window whose sleep PERSISTS. (The validation that makes it trustworthy.)
    settle_idx = None
    for i in range(n):
        if attempt[i] and persists(i):
            settle_idx = i
            break
    if settle_idx is None:
        # Settled at least once but never durably — report the last attempt, flag low confidence.
        settle_idx = int(np.argmax(attempt))

    # DRIFT = an earlier attempt that did NOT persist (a real-but-failed doze). Only if well before settle.
    first_attempt = int(np.argmax(attempt))
    drift_idx = first_attempt if (first_attempt < settle_idx and
                                  mins[settle_idx] - mins[first_attempt] >= 3) else None

    stirs = int(moved[:max(1, settle_idx)].sum())

    # Confidence: starts high, docked for a fitful onset (drift→settle gap) and a restless run-up.
    conf = 0.75
    if drift_idx is not None:
        gap = mins[settle_idx] - mins[drift_idx]
        conf -= min(0.30, 0.02 * gap)        # longer "couldn't stay asleep" gap → less certain
    conf -= min(0.20, 0.01 * stirs)          # more pre-onset stirring → less certain
    if not (settle_idx < n and attempt[settle_idx] and persists(settle_idx)):
        conf = min(conf, 0.35)               # never durably validated → cap low
    conf = float(max(0.25, min(0.85, conf)))

    return {
        "drift_min": None if drift_idx is None else float(mins[drift_idx]),
        "settle_min": float(mins[settle_idx]),
        "stirs": stirs,
        "confidence": conf,
    }


def _sleep_onset_stat(df: pd.DataFrame, surf: pd.DataFrame, wmin: float) -> Stat:
    """Time-to-fall-asleep. Headline = the durable SETTLE point (validated by the persistence
    criterion). When an earlier failed DRIFT exists (briefly dozed, got pulled back out), the detail
    tells that story — the gap is "couldn't stay asleep". ESTIMATED, confidence reflects how cleanly
    it resolved, never a precise timestamp."""
    if "immobility_run_length" not in surf.columns or not len(surf):
        return Stat("sleep_onset_min", "Time to fall asleep", Tier.GUESSED, None,
                    detail="need immobility + breathing signals — re-export from a fuller build")
    res = sleep_onset(surf)
    if res is None:
        return Stat("sleep_onset_min", "Time to fall asleep", Tier.GUESSED, None,
                    detail="never settled into sustained sleep-like quiet — a restless night, "
                           "or onset is off the recorded window")
    drift_min, settle_min, stirs, conf = (res["drift_min"], res["settle_min"],
                                          res["stirs"], res["confidence"])
    if drift_min is not None:  # an earlier doze that didn't stick → the fitful-onset story
        detail = (f"almost fell asleep ~{drift_min:.0f} min but kept stirring (couldn't stay down); "
                  f"stopped stirring for good ~{settle_min:.0f} min "
                  f"({stirs} stir(s) before. body-settling, not brain onset — ± a few min)")
    else:  # onset stuck on the first try
        detail = (f"stopped stirring and fell asleep around min {settle_min:.0f} "
                  f"({stirs} stir(s) before. body-settling, not brain onset — ± a few min)")
    return Stat("sleep_onset_min", "Time to fall asleep", Tier.ESTIMATED,
                settle_min, "min", confidence=conf, detail=detail)


def _heartbeat_stat(df: pd.DataFrame, surf: pd.DataFrame) -> Stat:
    if "accel_envelope" not in surf.columns:
        return Stat("heartbeat_bpm", "Heart rate (BCG)", Tier.GUESSED, None,
                    detail="no accel envelope — re-export from the dense-accel build")
    hz = float(df.attrs.get("config", {}).get("accel_envelope_hz", 8.0))
    if hz < HEART_MAX_BPM / 60.0 * 2:
        return Stat("heartbeat_bpm", "Heart rate (BCG)", Tier.GUESSED, None,
                    detail=f"envelope only {hz:.0f}Hz — too slow for heartbeat; raise accel_envelope_hz")
    # Slew-limited track (rejects 2x-harmonic lock-in); report its MEDIAN as the resting rate.
    track = _heartbeat_series(df, surf)
    if track:
        rates = [b for _, b, _ in track]
        confs = [c for _, _, c in track]
        return Stat("heartbeat_bpm", "Heart rate (BCG)", Tier.ESTIMATED,
                    float(np.median(rates)), "bpm", confidence=float(np.mean(confs)),
                    detail=f"{len(track)} tracked window(s); harmonic-rejected median "
                           f"(range {min(rates):.0f}-{max(rates):.0f})")
    return Stat("heartbeat_bpm", "Heart rate (BCG)", Tier.GUESSED, None,
                detail=f"no confident heartbeat track formed (trust bar {HEARTBEAT_TRUST_BAR:.2f}) — "
                       "not yet measurable on this device/mattress")


def format_stats(stats: list[Stat]) -> str:
    by_tier = {Tier.MEASURED: [], Tier.ESTIMATED: [], Tier.GUESSED: []}
    for s in stats:
        by_tier[s.tier].append(s)
    out = ["PER-SLEEP STATS (tiered):"]
    for tier, header in ((Tier.MEASURED, "MEASURED — direct sensor facts, trust these"),
                         (Tier.ESTIMATED, "ESTIMATED — derived, with confidence"),
                         (Tier.GUESSED, "GUESSED — withheld until the signal exists")):
        if by_tier[tier]:
            out.append(f"\n{header}:")
            out.extend(s.render() for s in by_tier[tier])
    return "\n".join(out)


def format_movement_timeline(events: list[MovementEvent]) -> str:
    if not events:
        return "MOVEMENT TIMELINE: no movements detected (phone never registered motion on-bed)."
    out = ["MOVEMENT TIMELINE (• small  ● large  ↻ reposition — the highest-confidence signal):"]
    out.extend(e.render() for e in events)
    return "\n".join(out)


def plot_heartbeat(df: pd.DataFrame, out_path):
    """Heart rate (accel BCG) over the night, as a slew-limited TRACK that rejects the 2x-harmonic.

    The grey cloud is every raw candidate peak (incl. the harmonic band ~2x the true rate, the cause
    of the old bimodal scatter). The red line is the tracker's accepted heartbeat: it follows the true
    fundamental, only allowing physiologically plausible moves per elapsed time. Honest by
    construction — the rejected harmonics stay VISIBLE as the grey cloud, not airbrushed; the track is
    what we trust. Flat-ish red line = a stable resting HR; a gradual climb = a real rise (e.g. REM)."""
    import matplotlib.pyplot as plt
    from . import set_hours_axis

    hz = float(df.attrs.get("config", {}).get("accel_envelope_hz", 8.0))
    xmax = (float(df["minutes"].iloc[-1]) + _window_minutes(df)) if len(df) else 1.0
    surf = _surface_only(df) if "on_surface" in df.columns else df

    fig, ax = plt.subplots(figsize=(11, 3.0))
    track = _heartbeat_series(df, surf) if hz >= HEART_MAX_BPM / 60.0 * 2 else []

    if track:
        # Grey cloud: every raw confident candidate (shows the harmonics the tracker rejected).
        chunks, tline = [], []
        for _, row in surf.iterrows():
            env = row["accel_envelope"]
            if isinstance(env, list) and env:
                chunks.append(np.asarray(env, float)); tline.append(np.full(len(env), float(row["minutes"])))
        stream = np.concatenate(chunks); times = np.concatenate(tline)
        band = _bandpass_bpm(stream, hz, HEART_MIN_BPM, HEART_MAX_BPM)
        n = int(60 * hz)
        for start in range(0, len(band) - n + 1, n):
            minute = float(times[start + n // 2])
            for b, c in _hr_all_peaks(band[start:start + n], hz):
                if c >= HEARTBEAT_TRUST_BAR:
                    ax.scatter(minute, b, s=8, color="#bbb", alpha=0.4, zorder=1)
        # Red track — but BREAK the line across gaps so we never draw a connecting segment through
        # minutes we couldn't read (that would imply a measurement that doesn't exist; honesty rule,
        # same as the breathing chart). A gap > GAP_BREAK_MIN minutes splits the line; dots always show.
        GAP_BREAK_MIN = 4.0  # > a couple of analysis windows = a real gap, not just one dropped read
        m = [t[0] for t in track]; y = [t[1] for t in track]
        seg_x, seg_y = [m[0]], [y[0]]
        for i in range(1, len(m)):
            if m[i] - m[i - 1] > GAP_BREAK_MIN:
                ax.plot(seg_x, seg_y, color="#c0392b", lw=1.5, zorder=3)
                seg_x, seg_y = [], []
            seg_x.append(m[i]); seg_y.append(y[i])
        if seg_x:
            ax.plot(seg_x, seg_y, color="#c0392b", lw=1.5, zorder=3)
        ax.scatter(m, y, s=20, color="#c0392b", edgecolors="white", linewidths=0.4, zorder=4)
        med = float(np.median(y))
        coverage = 100.0 * len(track) / max(1, int((df["minutes"].iloc[-1]) / (n / hz / 60.0)))
        ax.text(0.005, 0.97,
                f"resting HR ≈ {med:.0f} bpm  (read on {len(track)} windows ≈ {coverage:.0f}% of the night; "
                "gaps = no reading)",
                transform=ax.transAxes, va="top", ha="left", fontsize=9,
                bbox=dict(boxstyle="round", fc="white", ec="#ccc", alpha=0.85))
    else:
        why = (f"envelope only {hz:.0f} Hz — too slow for heartbeat (need ≥ "
               f"{HEART_MAX_BPM/60*2:.0f} Hz)") if hz < HEART_MAX_BPM / 60.0 * 2 else \
              "no confident heartbeat track formed"
        ax.text(0.5, 0.5, f"No heart-rate track\n({why})", transform=ax.transAxes,
                ha="center", va="center", fontsize=11, color="#888")

    ax.set_ylim(HEART_MIN_BPM, HEART_MAX_BPM)
    ax.set(title="Heart rate (accel BCG) — red = tracked heartbeat, grey = rejected harmonic candidates",
           ylabel="bpm")
    set_hours_axis(ax, xmax)
    fig.tight_layout()
    fig.savefig(out_path, dpi=110)
    plt.close(fig)
    return out_path


def plot_sleep_onset(df: pd.DataFrame, out_path):
    """Falling-asleep timeline: the restless run-up, the moment you first drifted into sleep-like quiet,
    and the moment that quiet HELD. Visualizes _sleep_onset_stat so you can SEE why the estimate is what
    it is — the same three signals that settle together at onset, plotted over the early night.

    Top band: movement activity (the restless run-up — spikes = stirs). Bottom band: how long stillness
    has held unbroken (immobility run). Green dashed = drifted (first quiet); green solid = settled (quiet
    that held). The shaded pre-settle region is time-to-fall-asleep, made visible and honestly bounded."""
    import matplotlib.pyplot as plt
    from . import set_hours_axis

    surf = _surface_only(df)
    res = sleep_onset(surf)
    wmin = _window_minutes(df)
    xmax = float(df["minutes"].iloc[-1]) + wmin if len(df) else 1.0

    fig, ax = plt.subplots(figsize=(11, 3.0))
    mins = surf["minutes"].to_numpy(dtype=float) if len(surf) else np.array([0.0])

    # Restless run-up: movement activity as a faint fill (spikes = stirs while trying to settle).
    if "accel_activity_count" in surf.columns and len(surf):
        act = surf["accel_activity_count"].to_numpy(dtype=float)
        ax.fill_between(mins, act, color="indigo", alpha=0.35, lw=0, label="movement (stirs)")
        ax.axhline(MOVEMENT_THRESHOLD, color="#888", lw=0.7, ls=":", zorder=0)

    if res is not None:
        drift_min, settle_min, stirs = res["drift_min"], res["settle_min"], res["stirs"]
        # Shade the pre-settle (falling-asleep) span — the time-to-sleep, bounded honestly.
        ax.axvspan(0, settle_min, color="#f1c40f", alpha=0.10, zorder=0,
                   label="falling asleep (time to settle)")
        if drift_min is not None:  # an earlier doze that didn't stick
            ax.axvline(drift_min, color="#e67e22", lw=1.4, ls="--", zorder=4,
                       label=f"almost (didn't stay) ~{drift_min:.0f} min")
        ax.axvline(settle_min, color="#1e8449", lw=2.4, zorder=4,
                   label=f"fell asleep ~{settle_min:.0f} min")
        title = (f"Falling asleep — almost ~{drift_min:.0f} min (kept stirring), then asleep "
                 f"~{settle_min:.0f} min" if drift_min is not None
                 else f"Falling asleep — asleep ~{settle_min:.0f} min")
        ax.set_title(f"{title}  ({stirs} stir(s) before settling)")
    else:
        ax.text(0.5, 0.5, "no clear settling into sleep-like quiet (restless night, or off-window)",
                transform=ax.transAxes, ha="center", va="center", fontsize=11, color="#888")
        ax.set_title("Falling asleep — no clear onset detected")

    ax.set(ylabel="activity")
    ax.set_ylim(bottom=0)
    set_hours_axis(ax, xmax)
    ax.legend(loc="upper right", fontsize=8)
    fig.tight_layout()
    fig.savefig(out_path, dpi=110)
    plt.close(fig)
    return out_path


def plot_movement_timeline(df: pd.DataFrame, out_path):
    """The movement timeline as a graph: one dot per discrete movement, sized + colored by intensity,
    on a horizontal time axis. The honest counterpart to the raw activity fill — it shows discrete
    EVENTS (not a continuous smear), excludes in-hand time, and marks repositions.

    Reads as: mostly-empty baseline = stillness; scattered dots = stirs; big dots = real movement.
    A movement dot means 'definitely not deep sleep here' — the one-way depth marker, made visible."""
    import matplotlib.pyplot as plt
    from . import CONF_CMAP  # reuse the project palette (low→high = red→green); here = intensity

    events = movement_events(df)
    wmin = _window_minutes(df)
    xmax = float(df["minutes"].iloc[-1]) + wmin if len(df) else 1.0

    fig, ax = plt.subplots(figsize=(11, 2.8))

    # Shade "phone moved" time (not flat/still — could be handheld OR just bumped; we can't tell which,
    # so we DON'T claim "in-hand"). Useful info: it flags time that wasn't settled tracking, and is a
    # seed for future automatic sleep detection (people sometimes handle the phone after starting).
    if "on_surface" in df.columns and not df["on_surface"].all():
        inhand = ~df["on_surface"].to_numpy()
        m = df["minutes"].to_numpy()
        i = 0
        labelled = False
        while i < len(inhand):
            if inhand[i]:
                j = i
                while j + 1 < len(inhand) and inhand[j + 1]:
                    j += 1
                ax.axvspan(m[i], m[j] + wmin, color="gray", alpha=0.15,
                           label="phone moved" if not labelled else None)
                labelled = True
                i = j + 1
            else:
                i += 1

    # Y-AXIS RESTORED: dots are placed by intensity (y) AND sized by it — redundant encoding reads at
    # a glance. Size = EXCESS over the stillness threshold so trivial stirs become near-invisible specks
    # and real movements dominate — nothing hidden, but the night reads mostly-empty = mostly-still.
    ax.axhline(MOVEMENT_THRESHOLD, color="#27ae60", lw=1.2, alpha=0.5, ls="--")  # the calm floor

    if events:
        xs = [e.minute for e in events]
        ys = [e.activity for e in events]               # y-position = raw intensity
        excess = [max(0.0, y - MOVEMENT_THRESHOLD) for y in ys]
        emax = max(excess) or 1.0
        # AREA grows ∝ excess^1.5 so small stirs shrink hard; threshold stir ~6px, biggest ~260px.
        sizes = [6 + 254 * (x / emax) ** 1.5 for x in excess]
        norm = plt.Normalize(0, emax)
        # CONF_CMAP runs red(0)→green(1); big movement should be RED, so invert.
        colors = [1.0 - norm(x) for x in excess]
        ax.scatter(xs, ys, s=sizes, c=colors, cmap=CONF_CMAP, vmin=0, vmax=1,
                   edgecolors="black", linewidths=0.4, zorder=3)
        for e in events:
            if e.repositioned:
                ax.annotate("↻", (e.minute, e.activity), fontsize=12, ha="center", va="bottom",
                            xytext=(0, 8), textcoords="offset points", color="#e74c3c")

    ax.set_ylim(MOVEMENT_THRESHOLD * 0.7,
                max(3.0, (max(e.activity for e in events) * 1.15) if events else 3.0))
    ax.set(title="Movement timeline — bigger/higher dot = bigger movement. Mostly empty = mostly still.",
           # Honest about the unit: a relative actigraphy index (integrated jerk over the window),
           # good for ORDERING movements, not a physical absolute.
           ylabel="movement intensity\n(activity index)")
    from . import set_hours_axis  # shared hours x-axis (lazy import avoids circular import)
    set_hours_axis(ax, xmax)
    if "on_surface" in df.columns and not df["on_surface"].all():
        ax.legend(loc="upper right", fontsize=8, framealpha=0.6)
    fig.tight_layout()
    fig.savefig(out_path, dpi=110)
    plt.close(fig)
    return out_path


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Compute tiered per-sleep stats for a Somnya session.")
    parser.add_argument("path", type=Path, help="path to a somnya-session-*.json")
    args = parser.parse_args(argv)
    if not args.path.exists():
        print(f"File not found: {args.path}\n"
              f"Export one from the app (Raw Data → Export JSON) and AirDrop it over, "
              f"then pass its path.", file=sys.stderr)
        return 1
    df = load(args.path)
    print(f"Loaded {len(df)} windows from {args.path.name} "
          f"({df['minutes'].iloc[-1]:.0f} min)\n")
    print(format_stats(compute_sleep_stats(df)))
    print()
    print(format_movement_timeline(movement_events(df)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
