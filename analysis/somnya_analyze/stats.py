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


# Bars (mirror SomnyaConfig + STATS_SPEC).
MOVEMENT_THRESHOLD = 0.6        # SomnyaConfig.movementThreshold
BREATHING_KEEP_CONF = 0.30      # SomnyaConfig.breathingMinConfidence
HEARTBEAT_TRUST_BAR = 0.40      # STATS_SPEC heartbeat trust bar
MIN_CONFIDENT_FOR_REGULARITY = 6  # need enough confident windows for a std to mean anything


def _window_minutes(df: pd.DataFrame) -> float:
    return float(df.attrs.get("config", {}).get("window_seconds", 30)) / 60.0


def _classify_posture(gx, gy, gz) -> str:
    ax, ay, az = abs(gx), abs(gy), abs(gz)
    if az >= ax and az >= ay:
        return "screen-up" if gz < 0 else "face-down"
    if ax >= ay:
        return "left-side" if gx > 0 else "right-side"
    return "head-up" if gy < 0 else "head-down"


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
        # Stirs = low→high crossings of the threshold (movement events).
        stirs = int(np.sum((~still[1:]) & (still[:-1])))
        stats.append(Stat("stir_count", "Movement events", Tier.MEASURED, stirs, "",
                          detail="times you stirred out of stillness"))

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


def _heartbeat_stat(df: pd.DataFrame, surf: pd.DataFrame) -> Stat:
    if "accel_envelope" not in surf.columns:
        return Stat("heartbeat_bpm", "Heart rate (BCG)", Tier.GUESSED, None,
                    detail="no accel envelope — re-export from the dense-accel build")
    hz = float(df.attrs.get("config", {}).get("accel_envelope_hz", 8.0))
    if hz < HEART_MAX_BPM / 60.0 * 2:
        return Stat("heartbeat_bpm", "Heart rate (BCG)", Tier.GUESSED, None,
                    detail=f"envelope only {hz:.0f}Hz — too slow for heartbeat; raise accel_envelope_hz")
    chunks = [np.asarray(v, dtype=float) for v in surf["accel_envelope"]
              if isinstance(v, list) and v]
    if not chunks:
        return Stat("heartbeat_bpm", "Heart rate (BCG)", Tier.GUESSED, None,
                    detail="accel envelope present but empty on-bed")
    band = _bandpass_bpm(np.concatenate(chunks), hz, HEART_MIN_BPM, HEART_MAX_BPM)
    n = int(60 * hz)
    rates, confs = [], []
    for start in range(0, len(band) - n + 1, n):
        bpm, conf = _estimate_periodic_peak(band[start:start + n], hz,
                                            min_bpm=HEART_MIN_BPM, max_bpm=HEART_MAX_BPM,
                                            min_conf=0.30)
        if bpm is not None and conf >= HEARTBEAT_TRUST_BAR:
            rates.append(bpm)
            confs.append(conf)
    if rates:
        return Stat("heartbeat_bpm", "Heart rate (BCG)", Tier.ESTIMATED,
                    float(np.mean(rates)), "bpm", confidence=float(np.mean(confs)),
                    detail=f"{len(rates)} window(s) cleared the {HEARTBEAT_TRUST_BAR:.2f} bar")
    return Stat("heartbeat_bpm", "Heart rate (BCG)", Tier.GUESSED, None,
                detail=f"no window cleared the {HEARTBEAT_TRUST_BAR:.2f} trust bar — "
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
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
