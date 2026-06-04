"""Offline analysis + threshold tuning for Somnya sleep-session CSV exports.

Built against the real exported schema (see SensorWindowCSV.swift): one row per 30s window,
accelerometer features always present, audio/breathing columns blank on pre-analyzer sessions.

Usage:
    uv run somnya-analyze path/to/somnya-session-*.csv [--out plots/]

Produces PNG plots (so they can be viewed directly, by a human or by Claude) and prints an
audio-signal sanity check + breathing summary to stdout.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import matplotlib

matplotlib.use("Agg")  # headless: write PNGs, no display needed
import matplotlib.pyplot as plt
import numpy as np
import pandas as pd

# Plausible human breathing band — mirrors SomnyaConfig. Used to count "physiological" estimates.
BREATHING_MIN_BPM = 6.0
BREATHING_MAX_BPM = 30.0


def load(csv_path: Path) -> pd.DataFrame:
    df = pd.read_csv(csv_path, parse_dates=["start_time_iso"])
    df = df.sort_values("start_time_iso").reset_index(drop=True)
    # Minutes from session start — friendlier x-axis than wall-clock.
    t0 = df["start_time_iso"].iloc[0]
    df["minutes"] = (df["start_time_iso"] - t0).dt.total_seconds() / 60.0
    return df


def audio_sanity(df: pd.DataFrame) -> str:
    """The key diagnostic: is the mic hearing breathing, or just the noise floor?"""
    if df["audio_rms"].isna().all():
        return (
            "AUDIO: no audio columns (session predates the audio analyzer). "
            "Nothing to diagnose on the mic side."
        )
    rms = df["audio_rms"].dropna()
    floor = df["audio_floor"].dropna()
    gap = (df["audio_rms"] - df["audio_floor"]).dropna()
    # Signal-to-floor ratio: how far above the quiet baseline the sound sits.
    ratio = (df["audio_rms"] / df["audio_floor"]).replace([np.inf, -np.inf], np.nan).dropna()
    lines = [
        "AUDIO SANITY (is breathing above the noise floor?)",
        f"  audio_rms   : mean={rms.mean():.6f}  min={rms.min():.6f}  max={rms.max():.6f}",
        f"  audio_floor : mean={floor.mean():.6f}",
        f"  rms - floor : mean={gap.mean():.6f}  max={gap.max():.6f}",
        f"  rms / floor : mean={ratio.mean():.2f}x  (>~2x = breathing likely audible; ~1x = buried)",
    ]
    if ratio.mean() < 1.5:
        lines.append(
            "  VERDICT: signal sits ON the noise floor — breathing is NOT clearly audible. "
            "Move phone closer, raise gain, or the passive-mic approach may not work at this distance."
        )
    else:
        lines.append("  VERDICT: signal rises above the floor — breathing should be detectable.")
    return "\n".join(lines)


def confidence_sweep(df: pd.DataFrame) -> str:
    """Real threshold sweep: now that breathing_confidence is exported, show how many windows
    would survive each candidate breathingMinConfidence — the value to set in SomnyaConfig."""
    if "breathing_confidence" not in df.columns or df["breathing_confidence"].isna().all():
        return ("CONFIDENCE SWEEP: no breathing_confidence column "
                "(session predates it, or mic was off). Re-export after the next test.")
    conf = df["breathing_confidence"].dropna()
    total = len(df)
    lines = ["CONFIDENCE SWEEP (how many windows survive each threshold):"]
    for thresh in (0.20, 0.30, 0.40, 0.50, 0.60, 0.70):
        kept = (conf >= thresh).sum()
        lines.append(f"  >= {thresh:.2f}: {kept:3d} / {total} windows")
    lines.append(f"  observed confidence: min={conf.min():.2f} "
                 f"median={conf.median():.2f} max={conf.max():.2f}")
    return "\n".join(lines)


def envelope_resliced(env_csv: Path, window_seconds_list=(30, 60, 120)) -> str:
    """Your offline-reslicing idea: load the dense ~10 Hz envelope and re-run breathing detection
    at DIFFERENT window sizes from the SAME capture — to see whether wider windows (more breaths
    per window) would have found a rhythm the on-device 30s windows missed."""
    if not env_csv.exists():
        return (f"RESLICE: no envelope file at {env_csv.name} — re-export after the next test "
                "(the app now writes a *-envelope.csv alongside the feature CSV).")
    env = pd.read_csv(env_csv, parse_dates=["window_start_iso"])
    # Flatten all windows back into one continuous 10 Hz envelope stream.
    env = env.sort_values(["window_start_iso", "sample_index"])
    stream = env["amplitude"].to_numpy()
    hz = 10.0
    lines = [f"RESLICE (re-detect breathing at wider windows, {len(stream)} envelope samples):"]
    for ws in window_seconds_list:
        n = int(ws * hz)
        if len(stream) < n:
            lines.append(f"  {ws:3d}s window: not enough data ({len(stream)} < {n} samples)")
            continue
        hits, confs = 0, []
        for start in range(0, len(stream) - n + 1, n):
            bpm, conf = _estimate_breathing(stream[start:start + n], hz)
            if bpm is not None:
                hits += 1
                confs.append(conf)
        avgc = f"avg_conf={np.mean(confs):.2f}" if confs else "avg_conf=n/a"
        lines.append(f"  {ws:3d}s window: {hits} estimate(s), {avgc}")
    return "\n".join(lines)


def polling_sweep(env_csv: Path, rates_hz=(10, 5, 4, 2, 1)) -> str:
    """How low can the envelope sampling rate go before breathing detection degrades? Decimate the
    stored 10 Hz envelope to each candidate rate, re-detect on a fixed 60s window, and compare.
    Lower viable rate = less to store/compute on-device. Captured dense once, tested at every rate."""
    if not env_csv.exists():
        return (f"POLLING SWEEP: no envelope file ({env_csv.name}) — re-export after the next test.")
    env = pd.read_csv(env_csv, parse_dates=["window_start_iso"])
    env = env.sort_values(["window_start_iso", "sample_index"])
    stream = env["amplitude"].to_numpy()
    base_hz = 10.0
    window_s = 60
    lines = ["POLLING SWEEP (decimate envelope, re-detect on 60s windows):"]
    for rate in rates_hz:
        step = max(1, int(round(base_hz / rate)))
        ds = stream[::step]
        eff_hz = base_hz / step
        n = int(window_s * eff_hz)
        if len(ds) < n:
            lines.append(f"  {rate:>2}Hz: not enough data")
            continue
        hits, confs = 0, []
        for start in range(0, len(ds) - n + 1, n):
            bpm, conf = _estimate_breathing(ds[start:start + n], eff_hz)
            if bpm is not None:
                hits += 1
                confs.append(conf)
        avgc = f"avg_conf={np.mean(confs):.2f}" if confs else "avg_conf=n/a"
        lines.append(f"  {rate:>2}Hz (~{eff_hz:.1f} eff): {hits} estimate(s), {avgc}")
    lines.append("  (rates where conf drops sharply = too slow; highest stable = the floor)")
    return "\n".join(lines)


def _estimate_breathing(envelope, hz, min_bpm=BREATHING_MIN_BPM, max_bpm=BREATHING_MAX_BPM,
                        min_conf=0.30):
    """Port of AudioAnalyzer.estimateBreathing — kept in sync so offline re-slicing matches the
    device. Detrend, autocorrelate, find the strongest normalized peak in the breathing band."""
    n = len(envelope)
    if n < int((60.0 / min_bpm) * hz * 2) or n <= 4:
        return None, 0.0
    x = envelope - envelope.mean()
    energy = float((x * x).sum())
    if energy <= 1e-12:
        return None, 0.0
    min_lag = int((60.0 / max_bpm) * hz)
    max_lag = min(n - 1, int((60.0 / min_bpm) * hz))
    if max_lag <= min_lag or min_lag < 1:
        return None, 0.0
    best_lag, best_corr = -1, -np.inf
    for lag in range(min_lag, max_lag + 1):
        corr = float((x[:n - lag] * x[lag:]).sum()) / energy
        if corr > best_corr:
            best_corr, best_lag = corr, lag
    if best_lag <= 0 or best_corr < min_conf:
        return None, max(0.0, best_corr)
    return 60.0 / (best_lag / hz), best_corr


def breathing_summary(df: pd.DataFrame) -> str:
    br = df["breathing_rate_bpm"].dropna()
    total = len(df)
    if br.empty:
        return f"BREATHING: 0 / {total} windows produced an estimate (all nil)."
    in_band = br[(br >= BREATHING_MIN_BPM) & (br <= BREATHING_MAX_BPM)]
    # Adjacent-window jumps reveal noise vs real signal: real breathing is stable window-to-window.
    var = df["breathing_rate_variability"].dropna()
    lines = [
        f"BREATHING: {len(br)} / {total} windows produced an estimate.",
        f"  rate (brpm): mean={br.mean():.1f}  min={br.min():.1f}  max={br.max():.1f}",
        f"  in-band [{BREATHING_MIN_BPM:.0f}-{BREATHING_MAX_BPM:.0f}]: {len(in_band)}",
    ]
    if not var.empty:
        lines.append(
            f"  window-to-window variability: mean={var.mean():.1f} brpm "
            "(>~3 brpm jumps = likely noise false-positives, not real breaths)"
        )
    return "\n".join(lines)


def make_plots(df: pd.DataFrame, out_dir: Path) -> list[Path]:
    out_dir.mkdir(parents=True, exist_ok=True)
    written: list[Path] = []

    # 1. Movement timeline.
    fig, ax = plt.subplots(figsize=(10, 3.2))
    ax.fill_between(df["minutes"], df["accel_activity_count"], color="indigo", alpha=0.6)
    ax.set(title="Movement (accel activity count) per 30s window",
           xlabel="minutes", ylabel="activity")
    p = out_dir / "movement.png"
    fig.tight_layout(); fig.savefig(p, dpi=110); plt.close(fig); written.append(p)

    # 2. Audio RMS vs floor — the money plot for the current problem.
    if not df["audio_rms"].isna().all():
        fig, ax = plt.subplots(figsize=(10, 3.2))
        ax.plot(df["minutes"], df["audio_rms"], color="teal", label="audio_rms")
        ax.plot(df["minutes"], df["audio_floor"], color="orange", ls="--", label="noise floor")
        ax.set(title="Audio RMS vs noise floor (overlap = breathing buried)",
               xlabel="minutes", ylabel="amplitude")
        ax.legend()
        p = out_dir / "audio_rms_vs_floor.png"
        fig.tight_layout(); fig.savefig(p, dpi=110); plt.close(fig); written.append(p)

    # 3. Breathing rate timeline (gaps = nil windows).
    br_df = df.dropna(subset=["breathing_rate_bpm"])
    if not br_df.empty:
        fig, ax = plt.subplots(figsize=(10, 3.2))
        ax.plot(br_df["minutes"], br_df["breathing_rate_bpm"],
                color="crimson", marker="o", ms=4)
        ax.axhspan(BREATHING_MIN_BPM, BREATHING_MAX_BPM, color="green", alpha=0.07,
                   label="physiological band")
        ax.set(title="Breathing rate estimates (unstable = noise)",
               xlabel="minutes", ylabel="brpm")
        ax.legend()
        p = out_dir / "breathing.png"
        fig.tight_layout(); fig.savefig(p, dpi=110); plt.close(fig); written.append(p)

    return written


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Analyze a Somnya session CSV export.")
    parser.add_argument("csv", type=Path, help="path to a somnya-session-*.csv")
    parser.add_argument("--out", type=Path, default=None,
                        help="directory for PNG plots (default: <csv-dir>/plots/)")
    args = parser.parse_args(argv)

    if not args.csv.exists():
        print(f"CSV not found: {args.csv}\n"
              f"Export one from the app (Raw Data -> Export CSV) and AirDrop it over, "
              f"then pass its path.", file=sys.stderr)
        return 1

    out_dir = args.out or (args.csv.parent / "plots")
    df = load(args.csv)

    print(f"Loaded {len(df)} windows from {args.csv.name}")
    print(f"Duration: {df['minutes'].iloc[-1]:.1f} min\n")
    print(audio_sanity(df), "\n")
    print(breathing_summary(df), "\n")
    print(confidence_sweep(df), "\n")

    # Envelope CSV sits next to the feature CSV with a -envelope suffix.
    env_csv = args.csv.with_name(args.csv.stem + "-envelope.csv")
    print(envelope_resliced(env_csv), "\n")
    print(polling_sweep(env_csv), "\n")

    written = make_plots(df, out_dir)
    print("Plots written:")
    for p in written:
        print(f"  {p}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
