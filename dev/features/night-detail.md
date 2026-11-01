# A night's detail

Updated 2026-10-31 20:56, at 0.4.

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
  mattress.
- **Raw data**: every 30-second window as a table, exportable as JSON.

## How to get to it

Main screen → History → a night. Raw Data is at the bottom of the detail.

## Driving it

No check yet. The analysis is Swift with no test target; its reference is the
Python prototype in `analysis/` and `analysis/STATS_SPEC.md`.

By hand only: open a recorded night.

## Gotchas

- Breathing confidence doesn't show a person is there. On 31 Oct the phone
  lay alone on the empty bed for 44 min (dogs and neighbours audible): mean
  confidence 0.23, a quarter of windows at 0.3 or more, the same as the
  sleep of 29–31 Oct (0.22–0.24, 19–23%). So a breathing rate read at these
  confidences may be noise, and anything that leans on breathing confidence
  (the fall-asleep estimate does) leans on noise too.

- Somnya doesn't show sleep stages or a sleep score: lying awake and still
  looks the same as deep sleep to an accelerometer. `analysis/STATS_SPEC.md`
  sorts every stat into measured, estimated or not enough data.
- The analysis runs when the detail opens and is cached; a spinner shows
  meanwhile.
