# Somnya

An on-device iPhone sleep tracker. It listens and senses overnight to detect movement,
breathing, and heartbeat, and reports what it actually measured instead of inventing a
sleep score.

> **Work in progress.** The sensing pipeline and analysis work; the polished stats UI is
> still being built. Expect rough edges.

## The one rule

> The app reports what it **measured**. It clearly labels what it **estimated**. It
> refuses to **guess** with a confident face.

Lying awake but still looks identical to deep sleep on an accelerometer, so Somnya won't
pretend to know your sleep stages. Every stat carries a tier: a direct sensor fact, an
estimate with an honest confidence, or "not enough data." See
[analysis/STATS_SPEC.md](analysis/STATS_SPEC.md) for the full catalog.

## How it works

- The phone sits on the bed. Somnya keeps the mic alive with the screen locked
  (background-audio mode) and samples motion, gravity, and barometric pressure.
- Audio and motion are aggregated into 30-second windows on-device: movement events,
  stillness, posture, breathing rate and regularity, and a BCG-based heartbeat estimate.
- Sleep onset and wake time are detected to bookend the sleep window.
- Everything is processed and stored on device (SwiftData). Nothing leaves the phone.
  Sessions can be exported as CSV/JSON for offline analysis.

## Requirements

- An iPhone running iOS 17.0 or later
- Xcode + command-line tools, an Apple ID signed in to Xcode (a free Apple ID is enough
  to install to your own device), and [xcodegen](https://github.com/yonaskolb/XcodeGen)
  (`brew install xcodegen`)

## Build & install

```sh
# one-time: set your Apple Development Team ID
cp Config.xcconfig.example Config.xcconfig
#   then edit Config.xcconfig and set DEVELOPMENT_TEAM to your team
#   (Xcode → Settings → Accounts → your team)

./build.sh                 # build, sign, install to the connected iPhone (default)
./build.sh --no-install    # build + sign only, stage into ./build/Somnya.app
./build.sh -h              # full usage
```

`build.sh` regenerates the Xcode project from `project.yml` (xcodegen), then builds and
signs with `xcodebuild` (`-allowProvisioningUpdates` refreshes the free-account
provisioning profile headlessly) and installs to a connected device with `devicectl`. No
Xcode GUI, Sideloadly, or re-signing tools required.

`Config.xcconfig` holds your personal Team ID and is gitignored, so it never gets
committed.

A free-account signature expires after about 7 days. Re-run `./build.sh` to renew it,
or use [ReSign](https://github.com/andres-al-campos/ReSign) to renew automatically.

## Offline analysis

`analysis/` is a Python package ([uv](https://github.com/astral-sh/uv)) for tuning
thresholds and prototyping stats against exported sessions, before that logic is ported to
Swift.

```sh
cd analysis
uv run somnya-analyze    # plots/threshold tuning over exported CSVs
uv run somnya-stats      # the per-sleep stats breakdown
```

Your exported sleep captures live under `analysis/sessions/` and are gitignored — personal
data, never committed.

## Project layout

```
Sources/
  Capture/    audio + motion analyzers, windowing, biquad/mel filters
  Session/    SessionManager, sleep-onset + heartbeat detection, analysis cache
  Model/      SwiftData models, config
  Intents/    Shortcuts "start session" action
  Views/      tracking, history, session detail, calibration, debug
  Debug/      CSV/JSON export, calibration + tone testers, logging
analysis/     offline Python analysis + the stats spec
build.sh      regenerate + build + sign + install
```
