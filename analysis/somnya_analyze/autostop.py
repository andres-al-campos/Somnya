"""Auto-stop on pickup: end the night when the phone is picked up after sleep and doesn't go back to
rest with someone beside it. `night_end` is the reference for the app's `PickupDetector`; change the
two together.

A pickup ends the night without judging whether it was the real morning one: anything recorded
after the alarm isn't wanted. With the shipped settings (armed 120 min, off 1 min, share 1.0) it
ended 100 of 134 nights (Jun–Oct 2026), 8 of them more than 15 min before the estimated wake.
Waiting for the phone to stay off the bed for 10 min instead ended only 4: after the alarm the
phone goes back on the bed.

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

from somnya_analyze import gyro_mean

SURFACE_DGRAV = 0.015  # same bars as classify_phone_state
SURFACE_GYRO = 0.015


def off_surface(df: pd.DataFrame) -> np.ndarray:
    g = df[["gravity_x", "gravity_y", "gravity_z"]].to_numpy(dtype=float)
    dgrav = np.r_[0.0, np.linalg.norm(np.diff(g, axis=0), axis=1)]
    gyro = gyro_mean(df)
    return ~((dgrav < SURFACE_DGRAV) & (gyro < SURFACE_GYRO))


def night_end(df: pd.DataFrame, *, armed_min=120.0, off_min=1.0, settle_min=5.0, wait_min=15.0, rest_min=120.0,
              moved_bar=0.6) -> float | None:
    """Where the app's PickupDetector ends the night: a pickup stands only if the phone doesn't
    settle again within `wait_min`, or settles and then feels no movement for `rest_min`. None if it
    never decides, which includes every night slept on after a pickup."""
    off = off_surface(df)
    mins = df["minutes"].to_numpy(dtype=float)
    act = df["accel_activity_count"].to_numpy(dtype=float)
    w = float(df["window_seconds"].iloc[0]) / 60.0 if "window_seconds" in df.columns else 0.5
    span = max(1, int(round(off_min / w)))
    on_total = still = 0.0
    run: list[float] = []
    pickup = settled = last_move = None
    for i in range(len(df)):
        if off[i]:
            run.append(mins[i]); still = 0.0
        else:
            on_total += w; still += w; run = []
        if on_total < armed_min:
            continue
        if len(run) >= span and (pickup is None or settled is not None):
            pickup, settled, last_move = run[0], None, None
        if pickup is None:
            continue
        if settled is None:
            if still >= settle_min:
                settled = mins[i]
            elif mins[i] - pickup >= wait_min:
                return float(pickup)
            continue
        if not off[i] and act[i] >= moved_bar:
            last_move = mins[i] + w
        if mins[i] - (last_move if last_move is not None else settled) >= rest_min:
            return float(last_move if last_move is not None else pickup)
    return None


def auto_stop(df: pd.DataFrame, *, armed_min=120.0, off_min=1.0, share=1.0) -> float | None:
    """The earlier rule, kept for the sweep below: minutes where the first pickup would end it."""
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
    if "gravity_x" not in df.columns or not ({"gyro_envelope", "gyro_mean"} & set(df.columns)):
        return None
    w = wake_time(df[df["on_surface"]])
    row = {"file": Path(path).name, "end_min": float(df["minutes"].iloc[-1]),
           "wake_min": w["wake_min"] if isinstance(w, dict) else np.nan}
    for a, o in GRID:
        row[f"a{a}_o{o}"] = auto_stop(df, armed_min=a, off_min=o)
    return row


def sweep(folder: Path) -> pd.DataFrame:
    files = sorted(str(p) for p in [*folder.glob("somnya-session-*.json"), *folder.glob("somnya-session-*.json.gz")])
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
