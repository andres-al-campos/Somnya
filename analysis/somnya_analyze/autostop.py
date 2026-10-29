"""Auto-stop on pickup: end tracking once the phone has been off the bed for good. A sweep over real
nights, kept for its answer: don't build this. On 134 nights (Jun–Oct 2026) it fired on at most 5,
and 3 of those were mid-sleep. After waking the phone stays on the bed (median 24 recorded minutes
after wake), and those windows look like sleep on every motion and audio feature, so neither a
pickup nor an emptied bed shows up here. What the app does instead is close a session once its
windows stop arriving (`SomnyaConfig.captureStoppedSeconds`).

The rule runs window by window, seeing only the past, as the app does:
  • a window is OFF the bed when the gravity vector moved since the last window or the gyro is
    busy — the same test as `classify_phone_state`, without its centred smoothing (the app can't
    see the next window);
  • it's ARMED once the phone has lain on the bed for `armed_min` minutes in all, so the hand-held
    minutes before setting it down never count;
  • it FIRES when at least `share` of the last `off_min` minutes were off the bed, and stops the
    session at the first off window of that stretch (when it was picked up), not when it fired.

    uv run python -m somnya_analyze.autostop sessions
"""
from __future__ import annotations

import argparse
import sys
import warnings
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path

import numpy as np
import pandas as pd

SURFACE_DGRAV = 0.015  # same bars as classify_phone_state
SURFACE_GYRO = 0.015


def off_surface(df: pd.DataFrame) -> np.ndarray:
    g = df[["gravity_x", "gravity_y", "gravity_z"]].to_numpy(dtype=float)
    dgrav = np.r_[0.0, np.linalg.norm(np.diff(g, axis=0), axis=1)]
    gyro = df["gyro_envelope"].apply(
        lambda v: float(np.mean(v)) if isinstance(v, list) and v else 0.0).to_numpy()
    return ~((dgrav < SURFACE_DGRAV) & (gyro < SURFACE_GYRO))


def auto_stop(df: pd.DataFrame, *, armed_min=120.0, off_min=10.0, share=0.8) -> float | None:
    """Minutes into the session where auto-stop would end it, or None if it never fires."""
    off = off_surface(df)
    mins = df["minutes"].to_numpy(dtype=float)
    w = float(df["window_seconds"].iloc[0]) / 60.0 if "window_seconds" in df.columns else 0.5
    span = max(1, int(round(off_min / w)))
    on_total = 0.0
    for i in range(len(df)):
        if not off[i]:
            on_total += w
        if on_total < armed_min or i + 1 < span:
            continue
        recent = off[i + 1 - span:i + 1]
        if recent.mean() >= share and off[i]:
            first = i + 1 - span + int(np.argmax(recent))
            return float(mins[first])
    return None


GRID = [(a, o) for a in (60, 120, 180) for o in (5, 10, 15, 20, 30)]


def _one(path: str):
    warnings.filterwarnings("ignore")
    from somnya_analyze import load
    from somnya_analyze.stats import wake_time
    df = load(Path(path))
    if not {"gravity_x", "gyro_envelope"}.issubset(df.columns):
        return None
    w = wake_time(df[df["on_surface"]])
    row = {"file": Path(path).name, "end_min": float(df["minutes"].iloc[-1]),
           "wake_min": w["wake_min"] if isinstance(w, dict) else np.nan}
    for a, o in GRID:
        row[f"a{a}_o{o}"] = auto_stop(df, armed_min=a, off_min=o)
    return row


def sweep(folder: Path) -> pd.DataFrame:
    files = sorted(str(p) for p in folder.glob("somnya-session-*.json"))
    with ProcessPoolExecutor(max_workers=6) as ex:
        rows = [r for r in ex.map(_one, files) if r]
    return pd.DataFrame(rows)


def report(d: pd.DataFrame, early_slack=15.0) -> str:
    """Per setting: how often it fired, how often it fired while still asleep (more than
    `early_slack` minutes before the estimated wake), and how close a fire landed to wake."""
    d = d[d["end_min"] >= 180]
    out = [f"{len(d)} nights of 3h+, {d['wake_min'].notna().sum()} with an estimated wake\n",
           f"{'armed':>6} {'off':>4} {'fired':>6} {'early':>6} {'median Δ':>9} {'p90 |Δ|':>8}"]
    for a, o in GRID:
        s = d[f"a{a}_o{o}"]
        fired = s.notna()
        has_w = fired & d["wake_min"].notna()
        delta = (s - d["wake_min"])[has_w]
        early = int((delta < -early_slack).sum())
        out.append(f"{a:>5}m {o:>3}m {fired.sum():>6} {early:>6} {delta.median():>8.1f}m "
                   f"{delta.abs().quantile(.9):>7.1f}m")
    return "\n".join(out)


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description="Simulate auto-stop over every session in a folder.")
    p.add_argument("folder", type=Path)
    p.add_argument("--csv", type=Path, help="also write the per-night results here")
    args = p.parse_args(argv)
    d = sweep(args.folder)
    if args.csv:
        d.to_csv(args.csv, index=False)
    print(report(d))
    return 0


if __name__ == "__main__":
    sys.exit(main())
