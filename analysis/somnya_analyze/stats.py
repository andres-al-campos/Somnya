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
    _bandpass_bpm,
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
HEARTBEAT_TRUST_BAR = 0.40      # STATS_SPEC heartbeat trust bar
MIN_CONFIDENT_FOR_REGULARITY = 6  # need enough confident windows for a std to mean anything

# Heartbeat tracker: BCG is a sharp pulse rich in harmonics, so the autocorrelation often has a peak
# at 2x the true rate that can be TALLER than the fundamental — the detector would otherwise flip
# between ~51 and ~95 bpm window to window. Defense: track a running HR and only accept a candidate
# whose move is physiologically plausible for the REAL elapsed time, snapping 2x candidates to half.
HEARTBEAT_MAX_SLEW_BPM_PER_S = 0.5   # sleeping HR changes slowly; tight = clean track, rejects spikes
HEARTBEAT_HARMONIC_TOL = 0.12        # how close to exactly 2x counts as "a harmonic to snap down"


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


def _breathing_stats(surf: pd.DataFrame) -> list[Stat]:
    out: list[Stat] = []
    if "breathing_rate_bpm" not in surf.columns or "breathing_confidence" not in surf.columns:
        out.append(Stat("breathing_rate_bpm", "Breathing rate", Tier.GUESSED, None,
                        detail="no breathing data in this session (mic off or pre-analyzer)"))
        return out
    n_surf = len(surf)
    conf_mask = surf["breathing_confidence"] >= BREATHING_KEEP_CONF
    confident = surf[conf_mask & surf["breathing_rate_bpm"].notna()]
    n_conf = len(confident)
    if n_conf == 0:
        out.append(Stat("breathing_rate_bpm", "Breathing rate", Tier.GUESSED, None,
                        detail=f"0 / {n_surf} windows cleared the confidence bar "
                               f"({BREATHING_KEEP_CONF:.2f}) — too quiet/buried to trust"))
        return out
    coverage = n_conf / n_surf if n_surf else 0.0
    rates = confident["breathing_rate_bpm"].to_numpy(dtype=float)
    out.append(Stat("breathing_rate_bpm", "Breathing rate", Tier.ESTIMATED,
                    float(np.median(rates)), "brpm", confidence=coverage,
                    detail=f"median over {n_conf} confident window(s) "
                           f"({coverage:.0%} of on-bed time)"))
    # Regularity (the one weak depth hint) — only if enough confident windows.
    if n_conf >= MIN_CONFIDENT_FOR_REGULARITY:
        std = float(np.std(rates))
        verdict = ("steady (consistent with deeper rest)" if std < 2.0
                   else "irregular (consistent with light/restless sleep)")
        out.append(Stat("breathing_regularity", "Breathing regularity", Tier.ESTIMATED,
                        std, "brpm std", confidence=coverage,
                        detail=f"{verdict} — a WEAK hint, not a depth measurement"))
    else:
        out.append(Stat("breathing_regularity", "Breathing regularity", Tier.GUESSED, None,
                        detail=f"only {n_conf} confident window(s) — too few to read regularity"))
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


def _heartbeat_series(df: pd.DataFrame, surf: pd.DataFrame):
    """Slew-limited heartbeat track over the night → list of (minute, bpm, conf).

    Three defenses against 2x-harmonic lock-in (the cause of the ~51-vs-~95 bimodal scatter):
      1. Slew limit: a candidate may move the running HR by at most HEARTBEAT_MAX_SLEW_BPM_PER_S × the
         REAL elapsed seconds since the last accepted point (gaps permit big moves, close windows don't)
         — so a real HR rise (gradual) passes but an instant 51→95 teleport (harmonic) is rejected.
      2. Sub-harmonic snap: a candidate ~2× the track is replaced by its half (the true fundamental).
      3. Physiological envelope: HEART_MIN_BPM..HEART_MAX_BPM backstop for wild artifacts.
    Returns [] (→ GUESSED) when the envelope is too slow or no confident track forms."""
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
    n = int(60 * hz)

    out = []
    cur = None
    last_min = None
    for start in range(0, len(band) - n + 1, n):
        minute = float(times[start + n // 2])
        peaks = _hr_all_peaks(band[start:start + n], hz)
        cands = [(b, c) for b, c in peaks
                 if c >= HEARTBEAT_TRUST_BAR and HEART_MIN_BPM <= b <= HEART_MAX_BPM]
        if not cands:
            continue
        if cur is None:
            # Seed on the LOWEST among the near-strongest peaks → avoid seeding on a harmonic.
            top = cands[0][1]
            strong = [b for b, c in cands if c >= top * 0.8]
            cur = min(strong) if strong else cands[0][0]
            out.append((minute, cur, cands[0][1])); last_min = minute
            continue
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
        # Red track.
        m = [t[0] for t in track]; y = [t[1] for t in track]
        ax.plot(m, y, color="#c0392b", lw=1.5, zorder=3)
        ax.scatter(m, y, s=20, color="#c0392b", edgecolors="white", linewidths=0.4, zorder=4)
        med = float(np.median(y))
        ax.text(0.005, 0.97,
                f"resting HR ≈ {med:.0f} bpm  ({len(track)} tracked win; harmonics rejected → grey)",
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
