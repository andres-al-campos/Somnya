# Somnya features

Updated 2026-10-25 11:38, at 0.4.

What a user can do with Somnya, how to reach it, and how to drive it. Read
this before adding anything: if it's already here, extend it instead of
building it again.

| Feature | File | Platforms | Driveable headless? |
|---|---|---|---|
| Tracking a night | [tracking.md](tracking.md) | iOS | No check yet |
| History | [history.md](history.md) | iOS | No check yet |
| A night's detail | [night-detail.md](night-detail.md) | iOS | No check yet |
| Debug tools | [debug-tools.md](debug-tools.md) | iOS | No check yet |

## What counts as a feature

Something a user sets out to do, with its own way in. What you only reach
inside a feature is a sub-feature and lives in that feature's file.

## Each file has

- **Sub-features**: what a user can do inside it, including limits.
- **How to get to it**: the user's path.
- **Driving it**: preconditions, the command that checks it, and what it
  observes. With no check, "No check yet" and why.
- **Gotchas**: what has bitten us or will.

Claims describe observable behavior, not code locations.

## Keeping it current

Update a feature's file in the same commit that changes the feature. A
feature touched for the first time gets a file and a row here.

## Driving conventions

`./build.sh check` runs every law in `tests/`, including the one that keeps
this map and its files in step, then every drive.

A feature's check is `tests/drive/<name>.sh`. `./build.sh drive` runs them all and
`./build.sh drive <name>` runs one; a name with no script is an error.

Somnya has no test target. Its features run on a phone lying on a bed with
someone asleep beside it, so most of what they do can only be seen on the
device. The analysis is prototyped in Python first (`analysis/`, see the
README), and that is where thresholds are tuned against real exported nights.
