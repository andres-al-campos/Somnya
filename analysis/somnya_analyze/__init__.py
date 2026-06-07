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

# Plausible resting/sleeping heart rate band (bpm). 40 (athlete deep sleep) to 120 (covers
# elevated/REM). In Hz that's ~0.67-2.0 Hz — well within the 8Hz accel envelope's Nyquist (4Hz).
HEART_MIN_BPM = 40.0
HEART_MAX_BPM = 120.0


def classify_phone_state(df: pd.DataFrame) -> pd.DataFrame:
    """Label each window 'on_surface' vs in-hand, from signals we already capture. A phone resting
    on a bed has a ROCK-STEADY gravity vector (dGrav≈0 between windows) and near-zero gyro; held in
    a hand it drifts and jitters continuously. The cleanest discriminator is gravity stability.
    Adds boolean column `on_surface`. This auto-excludes in-hand time from breathing/heartbeat/
    posture analysis (no eyeballing) and is the seed of automatic sleep detection."""
    if not {"gravity_x", "gravity_y", "gravity_z"}.issubset(df.columns):
        df["on_surface"] = True   # no gravity data → assume surface (legacy files)
        return df
    g = df[["gravity_x", "gravity_y", "gravity_z"]].to_numpy(dtype=float)
    # Change in gravity vector vs the previous window (0 = perfectly still surface).
    dgrav = np.r_[0.0, np.linalg.norm(np.diff(g, axis=0), axis=1)]
    # Gyro energy per window (mean of the gyro envelope), if present.
    if "gyro_envelope" in df.columns:
        gyro_e = df["gyro_envelope"].apply(
            lambda v: float(np.mean(v)) if isinstance(v, list) and v else 0.0).to_numpy()
    else:
        gyro_e = np.zeros(len(df))
    # Thresholds chosen from real nap data: surface windows sit at dgrav<0.01, gyro<0.01.
    on_surface = (dgrav < 0.015) & (gyro_e < 0.015)
    # Smooth: a single noisy window inside a long still run is still "surface" (debounce).
    s = pd.Series(on_surface)
    on_surface = (s.rolling(3, center=True, min_periods=1).mean() >= 0.5).to_numpy()
    df["on_surface"] = on_surface
    df["_dgrav"] = dgrav
    return df


def _surface_only(df: pd.DataFrame) -> pd.DataFrame:
    """Restrict to on-surface windows (phone resting, not in hand). Breathing/heartbeat/posture are
    only meaningful then. Falls back to the full df if the column is absent (legacy files)."""
    if "on_surface" in df.columns and df["on_surface"].any():
        return df[df["on_surface"]].reset_index(drop=True)
    return df


def phone_state_summary(df: pd.DataFrame) -> str:
    """Report the in-hand → on-surface handoff so it's explicit which part of the night is trusted."""
    if "on_surface" not in df.columns:
        return "PHONE STATE: not classified."
    n = len(df)
    surf = int(df["on_surface"].sum())
    lines = [f"PHONE STATE: {surf}/{n} windows on-surface ({100*surf/n:.0f}%)."]
    # Find the first sustained on-surface run (the "set it down" moment).
    runs = df["on_surface"].to_numpy()
    handoff = None
    for i in range(len(runs) - 6):
        if runs[i:i + 6].all():   # 6 windows = 3 min of continuous surface
            handoff = i
            break
    if handoff is not None:
        t = df["minutes"].iloc[handoff]
        lines.append(f"  Set down ~min {t:.0f} (first sustained on-surface run). Earlier = in-hand, "
                     "excluded from breathing/heartbeat/posture.")
    else:
        lines.append("  No sustained on-surface period found — was the phone held the whole time?")
    return "\n".join(lines)


def load(path: Path) -> pd.DataFrame:
    """Load a session as a per-window DataFrame. Accepts the new single JSON export (preferred —
    carries envelope, filtered_envelope, mel_bands, and config inline) or the legacy feature CSV."""
    if path.suffix.lower() == ".json":
        df = _load_json(path)
    else:
        df = pd.read_csv(path, parse_dates=["start_time_iso"])
    # Normalize the time column name across formats.
    time_col = "start" if "start" in df.columns else "start_time_iso"
    df[time_col] = pd.to_datetime(df[time_col])
    df = df.sort_values(time_col).reset_index(drop=True)
    df["minutes"] = (df[time_col] - df[time_col].iloc[0]).dt.total_seconds() / 60.0
    # Alias new JSON column names to the CSV names the rest of the tool expects.
    aliases = {"breathing_rate_bpm": "breathing_rate_bpm", "audio_rms": "audio_rms"}
    for src, dst in aliases.items():
        if src in df.columns and dst not in df.columns:
            df[dst] = df[src]
    df = classify_phone_state(df)
    return df


def _load_json(path: Path) -> pd.DataFrame:
    import json
    with open(path) as f:
        doc = json.load(f)
    df = pd.json_normalize(doc["windows"])
    # Stash config + envelopes on the frame for the sweeps (as attrs so they survive).
    df.attrs["config"] = doc.get("config", {})
    return df


def audio_sanity(df: pd.DataFrame) -> str:
    """The key diagnostic: is the mic hearing breathing, or just the noise floor?"""
    if "audio_rms" not in df.columns or df["audio_rms"].isna().all():
        return (
            "AUDIO: no audio columns (session predates the audio analyzer, or mic was off). "
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


def envelope_stream(path: Path, df: pd.DataFrame):
    """Flatten the per-window envelope into one continuous stream + its sample rate. Prefers the
    inline JSON envelope (filtered, what detection runs on); falls back to a legacy *-envelope.csv."""
    hz = float(df.attrs.get("config", {}).get("audio_envelope_hz", 10.0))
    # JSON path: each window row carries a 'filtered_envelope' (or 'envelope') list.
    col = "filtered_envelope" if "filtered_envelope" in df.columns else (
        "envelope" if "envelope" in df.columns else None)
    if col is not None:
        chunks = [np.asarray(v, dtype=float) for v in df[col] if isinstance(v, list) and v]
        if chunks:
            return np.concatenate(chunks), hz
    # Legacy CSV path.
    env_csv = path.with_name(path.stem + "-envelope.csv")
    if env_csv.exists():
        env = pd.read_csv(env_csv, parse_dates=["window_start_iso"])
        env = env.sort_values(["window_start_iso", "sample_index"])
        col = "filtered_amplitude" if "filtered_amplitude" in env.columns else "amplitude"
        return env[col].to_numpy(), 10.0
    return None, hz


def envelope_resliced(path: Path, df: pd.DataFrame, window_seconds_list=(30, 60, 120)) -> str:
    """Re-run breathing detection at DIFFERENT window sizes from the SAME capture — to see whether
    wider windows (more breaths each) find a rhythm the on-device 30s windows missed."""
    stream, hz = envelope_stream(path, df)
    if stream is None:
        return "RESLICE: no envelope available — re-export after the next test."
    lines = [f"RESLICE (re-detect breathing at wider windows, {len(stream)} samples @ {hz:.0f}Hz):"]
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


def polling_sweep(path: Path, df: pd.DataFrame, rates_hz=(10, 5, 4, 2, 1)) -> str:
    """How low can the envelope sampling rate go before detection degrades? Decimate the stored
    envelope to each candidate rate, re-detect on 60s windows, compare. Captured dense once,
    tested at every rate."""
    stream, base_hz = envelope_stream(path, df)
    if stream is None:
        return "POLLING SWEEP: no envelope available — re-export after the next test."
    # Only sweep rates at/below what was captured.
    rates_hz = tuple(r for r in rates_hz if r <= base_hz)
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


def accel_breathing(df: pd.DataFrame) -> str:
    """Run the SAME envelope→autocorrelation breathing estimator on the dense ACCEL envelope —
    i.e. can the phone-on-mattress accelerometer see breathing as bed motion (ballistocardiography)?
    A silent, emission-free alternative to the mic. Reports a rms/floor-style sanity check plus
    detection at 30/60/120s windows, so it can be compared directly against the mic results above."""
    if "accel_envelope" not in df.columns:
        return ("ACCEL BREATHING: no accel_envelope in this file — it predates the dense-accel\n"
                "  capture. Re-export after a phone-on-mattress night on the new build to test this.")
    hz = float(df.attrs.get("config", {}).get("accel_envelope_hz", 8.0))
    df = _surface_only(df)   # only meaningful when the phone is resting, not held
    chunks = [np.asarray(v, dtype=float) for v in df["accel_envelope"]
              if isinstance(v, list) and v]
    if not chunks:
        return "ACCEL BREATHING: accel_envelope column present but empty."
    stream = np.concatenate(chunks)

    lines = [f"ACCEL BREATHING (bed motion, {len(stream)} samples @ {hz:.0f}Hz):"]

    # Sanity: how far does the breathing-band oscillation rise above the broadband fluctuation?
    # Detrended std (signal) vs the median per-window std (a noise-floor proxy). >~2x = promising.
    sig = float(np.std(stream - np.mean(stream)))
    per_window = np.array([float(np.std(c - np.mean(c))) for c in chunks if len(c) > 1])
    floor = float(np.median(per_window)) if per_window.size else 0.0
    ratio = sig / floor if floor > 1e-12 else float("inf")
    lines.append(f"  signal std={sig:.5f}  per-window-median std={floor:.5f}  ratio={ratio:.2f}x")

    # Detection at several window sizes (reuse the shared estimator).
    for ws in (30, 60, 120):
        n = int(ws * hz)
        if len(stream) < n:
            lines.append(f"  {ws:3d}s window: not enough data ({len(stream)} < {n})")
            continue
        hits, confs, rates = 0, [], []
        for start in range(0, len(stream) - n + 1, n):
            bpm, conf = _estimate_breathing(stream[start:start + n], hz)
            if bpm is not None:
                hits += 1
                confs.append(conf)
                rates.append(bpm)
        if confs:
            lines.append(f"  {ws:3d}s window: {hits} estimate(s), avg_conf={np.mean(confs):.2f}, "
                         f"rate mean={np.mean(rates):.1f} brpm")
        else:
            lines.append(f"  {ws:3d}s window: 0 estimates (no rhythm found)")
    lines.append("  (compare ratio + conf to the mic above — higher here = bed motion is the better signal)")
    return "\n".join(lines)


def _bandpass_bpm(x, hz, low_bpm, high_bpm, order=4):
    """Zero-phase Butterworth band-pass (scipy). A SHARP filter is essential here: the heartbeat is
    ~25x weaker than breathing and sits a couple of octaves above it, so a gentle filter leaks the
    huge breathing wave into the heart band and drowns the pulse. filtfilt = no phase distortion,
    so peak timing (→ rate) is preserved. Falls back to the raw signal if the band is degenerate."""
    from scipy.signal import butter, filtfilt
    x = np.asarray(x, dtype=float)
    nyq = hz / 2.0
    lo = (low_bpm / 60.0) / nyq
    hi = (high_bpm / 60.0) / nyq
    lo, hi = max(lo, 1e-4), min(hi, 0.999)
    if not (0 < lo < hi < 1) or len(x) <= order * 3:
        return x - x.mean()
    b, a = butter(order, [lo, hi], btype="band")
    return filtfilt(b, a, x)


def posture_summary(df: pd.DataFrame) -> str:
    """Decode the mean-gravity vector per window into sleep posture (back / left / right / face-down /
    upright) and report how the night was distributed. Phone lies flat on the mattress, so 'down'
    (gravity) relative to the device axes tells us how the body — and the phone with it — is oriented.
    Apnea is worse supine (on the back), so this is a real future-feature signal."""
    need = {"gravity_x", "gravity_y", "gravity_z"}
    if not need.issubset(df.columns):
        return ("POSTURE: no gravity vector in this file — re-export after a night on the build with\n"
                "  gyro/gravity capture to see which side you slept on.")
    df = _surface_only(df)   # posture = body posture only once the phone is resting on the bed
    gx = df["gravity_x"].to_numpy(dtype=float)
    gy = df["gravity_y"].to_numpy(dtype=float)
    gz = df["gravity_z"].to_numpy(dtype=float)

    # iOS device frame: x = right edge, y = top edge, z = out of screen. Gravity points toward earth.
    # Phone flat, screen up on a bedside table → gz ≈ -1. Lying screen-down → gz ≈ +1. On its side
    # (phone tucked beside you on a side-sleep) → gx dominates. This is a heuristic, refined with data.
    def classify(x, y, z):
        ax, ay, az = abs(x), abs(y), abs(z)
        if az >= ax and az >= ay:
            return "screen-up" if z < 0 else "face-down"
        if ax >= ay:
            return "left-side" if x > 0 else "right-side"
        return "head-up" if y < 0 else "head-down"

    labels = [classify(x, y, z) for x, y, z in zip(gx, gy, gz)]
    total = len(labels)
    from collections import Counter
    counts = Counter(labels)
    lines = ["POSTURE (mean gravity → orientation; heuristic, phone-on-mattress):"]
    for label, c in counts.most_common():
        lines.append(f"  {label:11s}: {c:4d} windows ({100*c/total:4.1f}%)")
    # Posture changes = how often the label flips (a restlessness proxy).
    flips = sum(1 for a, b in zip(labels, labels[1:]) if a != b)
    lines.append(f"  position changes: {flips} (label flips across {total} windows)")
    lines.append("  NOTE: labels map the PHONE's orientation; calibrate to body posture once we "
                 "correlate a known night.")
    return "\n".join(lines)


def pressure_summary(df: pd.DataFrame) -> str:
    """Barometer sanity: did pressure drift over the night (weather front) and is the per-window
    noise small enough that breathing micro-pressure could ever show? Just a first look."""
    if "pressure_kpa" not in df.columns:
        return "PRESSURE: no barometer data in this file (device may lack one, or pre-capture)."
    p = df["pressure_kpa"].dropna().to_numpy(dtype=float)
    if p.size == 0:
        return "PRESSURE: column present but empty."
    drift = p[-1] - p[0]
    lines = ["PRESSURE (barometer, kPa):",
             f"  start={p[0]:.3f}  end={p[-1]:.3f}  drift={drift:+.3f} kPa over the night",
             f"  range={p.max()-p.min():.3f}  std={np.std(p):.4f}"]
    lines.append("  (a steady fall often precedes worse weather/sleep; large std = noisy sensor.)")
    return "\n".join(lines)


def _estimate_periodic_peak(x, hz, min_bpm, max_bpm, min_conf=0.30):
    """Like _estimate_breathing but only accepts a peak that is a genuine INTERIOR local maximum of
    the autocorrelation — i.e. a real bump, not the band-edge. Broadband residual (leaked breathing,
    noise) makes autocorr fall monotonically from the shortest lag; that produces a fake 'peak' at
    min_lag. Requiring corr[lag] > corr[lag-1] and > corr[lag+1] rejects that, so a null reads null."""
    x = np.asarray(x, dtype=float)
    n = len(x)
    x = x - x.mean()
    energy = float((x * x).sum())
    if energy <= 1e-12 or n <= 4:
        return None, 0.0
    min_lag = int((60.0 / max_bpm) * hz)
    max_lag = min(n - 1, int((60.0 / min_bpm) * hz))
    if max_lag - min_lag < 2 or min_lag < 1:
        return None, 0.0
    corr = np.array([float((x[:n - lag] * x[lag:]).sum()) / energy
                     for lag in range(min_lag, max_lag + 1)])
    # Interior local maxima only (exclude the two ends so a band-edge slope can't win).
    best_lag, best_corr = -1, -np.inf
    for i in range(1, len(corr) - 1):
        if corr[i] > corr[i - 1] and corr[i] >= corr[i + 1] and corr[i] > best_corr:
            best_corr, best_lag = corr[i], min_lag + i
    if best_lag <= 0 or best_corr < min_conf:
        return None, max(0.0, best_corr)
    return 60.0 / (best_lag / hz), float(best_corr)


def heartbeat_detect(df: pd.DataFrame) -> str:
    """Can the phone-on-mattress accelerometer see the HEARTBEAT (ballistocardiography)? The heart's
    recoil is a small 0.7-2 Hz motion sitting UNDER the much larger breathing wave. We band-pass the
    accel envelope to the heart band (stripping breathing) then autocorrelate for a pulse rate.

    HONEST CAVEAT: the BCG signal is often 10-100x weaker than breathing and a soft mattress absorbs
    it. A clear result here is exciting (HRV → 'how restful was your sleep'); a null result is the
    expected outcome and just means we'd need a stronger signal (higher-rate accel, or sonar)."""
    if "accel_envelope" not in df.columns:
        return ("HEARTBEAT (accel BCG): no accel_envelope in this file — re-export after a\n"
                "  phone-on-mattress night on the new build to test this.")
    hz = float(df.attrs.get("config", {}).get("accel_envelope_hz", 8.0))
    df = _surface_only(df)   # heartbeat only meaningful when the phone is resting, not held
    chunks = [np.asarray(v, dtype=float) for v in df["accel_envelope"]
              if isinstance(v, list) and v]
    if not chunks:
        return "HEARTBEAT (accel BCG): accel_envelope present but empty."
    stream = np.concatenate(chunks)

    # Nyquist sanity: need the sample rate to comfortably exceed the heart band.
    if hz < HEART_MAX_BPM / 60.0 * 2:
        return (f"HEARTBEAT (accel BCG): envelope is only {hz:.0f}Hz — too slow to resolve up to "
                f"{HEART_MAX_BPM:.0f}bpm ({HEART_MAX_BPM/60:.1f}Hz). Raise accel_envelope_hz.")

    band = _bandpass_bpm(stream, hz, HEART_MIN_BPM, HEART_MAX_BPM)
    lines = [f"HEARTBEAT (accel BCG, {len(stream)} samples @ {hz:.0f}Hz, band {HEART_MIN_BPM:.0f}-"
             f"{HEART_MAX_BPM:.0f}bpm):"]

    # Detect on 30/60s windows in the heart band (note: same estimator, heart-band lags).
    for ws in (30, 60):
        n = int(ws * hz)
        if len(band) < n:
            lines.append(f"  {ws:3d}s window: not enough data")
            continue
        hits, confs, rates = 0, [], []
        for start in range(0, len(band) - n + 1, n):
            bpm, conf = _estimate_periodic_peak(band[start:start + n], hz,
                                                min_bpm=HEART_MIN_BPM, max_bpm=HEART_MAX_BPM,
                                                min_conf=0.30)
            if bpm is not None:
                hits += 1
                confs.append(conf)
                rates.append(bpm)
        total = (len(band) - n) // n + 1
        if confs:
            lines.append(f"  {ws:3d}s window: {hits}/{total} estimate(s), "
                         f"avg_conf={np.mean(confs):.2f}, rate mean={np.mean(rates):.0f} bpm "
                         f"(std {np.std(rates):.0f})")
        else:
            lines.append(f"  {ws:3d}s window: 0/{total} estimates — heartbeat not visible in accel")
    lines.append("  Interpret: stable rate in 50-70bpm + conf>0.4 = real BCG (exciting). "
                 "Scattered/low-conf = buried (expected); needs higher-rate accel or sonar.")
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
    var = (df["breathing_rate_variability"].dropna()
           if "breathing_rate_variability" in df.columns else pd.Series(dtype=float))
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


# Somnya's confidence colormap: blue (unsure) → green → yellow → red (confident). Position encodes
# the value; color temperature encodes how much to trust it. The reference for the native SwiftUI
# chart later. (Prototype intentionally avoids the red-white-blue diverging map.)
from matplotlib.colors import LinearSegmentedColormap as _LSC
CONF_CMAP = _LSC.from_list("somnya_conf", ["#2c6fbb", "#27ae60", "#f1c40f", "#e74c3c"])


def plot_value_with_confidence(ax, minutes, values, conf, *, conf_lo=0.15, conf_hi=0.55,
                               window_min=0.5, gap_factor=1.2):
    """Plot a value-over-time series where COLOR = confidence and the line BREAKS at data gaps.

    Honesty rules baked in:
    - The line only connects truly-consecutive windows (gap > window*gap_factor → break), so a long
      flat segment can never fake 'steady value' across windows we never measured. Absence shows as
      absence.
    - Isolated detections (no consecutive neighbor) render as standalone dots — a real-but-unconfirmed
      reading, honestly shown rather than strung into a fake line.
    - Color = confidence (blue→red); alpha also scales with confidence so low-conf points recede and
      the eye is drawn to where we're actually sure."""
    from matplotlib.collections import LineCollection
    x = np.asarray(minutes, dtype=float)
    y = np.asarray(values, dtype=float)
    c = np.asarray(conf, dtype=float)
    norm = plt.Normalize(conf_lo, conf_hi)
    gap = window_min * gap_factor

    # Segments only between consecutive windows.
    segs, segc = [], []
    for i in range(len(x) - 1):
        if x[i + 1] - x[i] <= gap:
            segs.append([[x[i], y[i]], [x[i + 1], y[i + 1]]])
            segc.append(c[i])
    if segs:
        lc = LineCollection(segs, cmap=CONF_CMAP, norm=norm, linewidth=2.6)
        lc.set_array(np.asarray(segc))
        ax.add_collection(lc)
    # Points (all of them), alpha by confidence.
    for xi, yi, ci in zip(x, y, c):
        ax.scatter(xi, yi, c=[ci], cmap=CONF_CMAP, norm=norm,
                   s=26, alpha=max(0.15, min(1.0, ci / conf_hi)), zorder=3)
    # A mappable for the colorbar.
    sm = plt.cm.ScalarMappable(cmap=CONF_CMAP, norm=norm); sm.set_array([])
    return sm


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

    # 3. Breathing rate — value=position, color=confidence, line breaks at data gaps. The honest
    #    version: a long flat line can't fake "steady" across windows we never measured.
    br_df = df.dropna(subset=["breathing_rate_bpm"]).copy()
    if "breathing_confidence" in br_df.columns:
        br_df = br_df.dropna(subset=["breathing_confidence"])
    if not br_df.empty and "breathing_confidence" in br_df.columns:
        win_min = float(df.attrs.get("config", {}).get("window_seconds", 30)) / 60.0
        fig, ax = plt.subplots(figsize=(10, 3.4))
        ax.axhspan(BREATHING_MIN_BPM, BREATHING_MAX_BPM, color="gray", alpha=0.05)
        sm = plot_value_with_confidence(
            ax, br_df["minutes"].to_numpy(), br_df["breathing_rate_bpm"].to_numpy(),
            br_df["breathing_confidence"].to_numpy(), window_min=win_min)
        fig.colorbar(sm, ax=ax, label="confidence", pad=0.01)
        ax.set(title="Breathing rate — color = confidence, gaps = no trustworthy reading",
               xlabel="minutes", ylabel="brpm", ylim=(0, 32))
        ax.set_xlim(df["minutes"].min(), df["minutes"].max())
        p = out_dir / "breathing.png"
        fig.tight_layout(); fig.savefig(p, dpi=110); plt.close(fig); written.append(p)

    return written


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Analyze a Somnya session CSV export.")
    parser.add_argument("path", type=Path,
                        help="path to a somnya-session-*.json (preferred) or legacy .csv")
    parser.add_argument("--out", type=Path, default=None,
                        help="directory for PNG plots (default: <file-dir>/plots/)")
    args = parser.parse_args(argv)

    if not args.path.exists():
        print(f"File not found: {args.path}\n"
              f"Export one from the app (Raw Data -> Export JSON) and AirDrop it over, "
              f"then pass its path.", file=sys.stderr)
        return 1

    out_dir = args.out or (args.path.parent / "plots")
    df = load(args.path)

    print(f"Loaded {len(df)} windows from {args.path.name}")
    print(f"Duration: {df['minutes'].iloc[-1]:.1f} min\n")
    print(phone_state_summary(df), "\n")
    print(audio_sanity(df), "\n")
    print(breathing_summary(df), "\n")
    print(confidence_sweep(df), "\n")
    print(envelope_resliced(args.path, df), "\n")
    print(polling_sweep(args.path, df), "\n")
    print(accel_breathing(df), "\n")
    print(heartbeat_detect(df), "\n")
    print(posture_summary(df), "\n")
    print(pressure_summary(df), "\n")

    written = make_plots(df, out_dir)
    print("Plots written:")
    for p in written:
        print(f"  {p}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
