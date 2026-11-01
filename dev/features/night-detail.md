# A night's detail

Updated 2026-11-01 14:23, at 0.4.

What Somnya measured about one night, each figure marked by how far it can be
trusted.

## Sub-features

- **Time to fall asleep**, estimated from when stirring stopped and breathing
  steadied, with a note that it's not a brain measurement. Says so when there
  was no clear point of settling, and when the night was recorded by a build
  that didn't track it.
- **Movement over time**: accelerometer activity per 30-second window.
- **Breathing rate over time**, from the microphone, with gaps where no
  rhythm was clear. Says why when there's no trustworthy estimate.
- **Heart rate over time**, from the accelerometer pulse
  (ballistocardiography), when the body was coupled well enough to the
  mattress. Since Nov 2026 the costly part runs during the night: each 120 s
  block is band-passed and autocorrelated once the next window lands, and the
  results are saved on the windows (`heartSegments`, ~10 KB a night). At stop
  and on opening, only the cheap tracker runs over them.
- **Raw data**: every 30-second window as a table, exportable as JSON.

## How to get to it

Main screen → History → a night → In-depth view. Raw Data is at the top of the detail.

## Driving it

No check yet. The analysis is Swift with no test target; its reference is the
Python prototype in `analysis/` and `analysis/STATS_SPEC.md`.

Heart rate made during the night against a whole-night run: import real nights
into the simulator (see `RealNightImport`), then launch with `-checkHeartLive`
(`xcrun simctl launch --console-pty booted com.aurende.somnya -checkHeartLive`).
It ends `HEARTLIVE done: N nights, 0 different`. On 1 Nov: 11 nights, 0 different.

By hand only: open a recorded night.

## Gotchas

- A night older than the last 30 has no raw streams. One recorded before
  Nov 2026 keeps the heart-rate track saved when it was last analysed, so a
  tracker change doesn't reach it; a later one keeps its segments and
  recomputes. A change to the band-pass or the autocorrelation reaches neither, while fell-asleep, which reads only per-window numbers,
  still recomputes.

- Breathing confidence doesn't show a person is there. On 31 Oct the phone
  lay alone on the empty bed for 44 min (dogs and neighbours audible): mean
  confidence 0.23, a quarter of windows at 0.3 or more, the same as the
  sleep of 29–31 Oct (0.22–0.24, 19–23%). So a breathing rate read at these
  confidences may be noise, and anything that leans on breathing confidence
  (the fall-asleep estimate does) leans on noise too. The empty bed even got
  a breathing rate (13.3/min) in the night's stats.
- Heart rate passed the same control: the empty bed found a pulse in 8% of
  windows at scattered rates (median 87, spread 36), with no heart rate in
  its stats, while the nights of 29–31 Oct found one in 13–18% at a steady
  53/min (spread about 6).
- Breathing from motion hasn't been tested fairly yet. A breath tilts the
  phone, which iOS counts as a change in gravity, and the accel and gyro
  envelopes are magnitudes with gravity removed. Since Nov 2026 gravity is
  stored at 5 Hz (`gravity_envelope` in exports); the test is a night plus
  an empty-bed control, looking for a 0.2–0.5 Hz rhythm. The old gyro
  envelope showed 0.19–0.25 rhythm strength on nights against 0.16 on the
  empty bed, and fusing it with accel made heart rate worse on 5 nights, so
  it's no longer recorded densely.

- Somnya doesn't show sleep stages or a sleep score: lying awake and still
  looks the same as deep sleep to an accelerometer. `analysis/STATS_SPEC.md`
  sorts every stat into measured, estimated or not enough data.
- The analysis runs when the detail opens and is cached; a spinner shows
  meanwhile.
