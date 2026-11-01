# A night

Updated 2026-10-31 22:56, at 0.4.

How one night went, against what's usual for you, in the order it happened.

## Sub-features

- **Header card**: time asleep (estimated, from falling asleep to waking),
  time in bed and the usual time asleep; when you got into bed, fell asleep
  and woke up; the night as a bar (asleep span, longest still stretch,
  movements as dots); and a sentence naming the three biggest differences
  from usual.
- **Week of rings**: the night and up to six before it, each ring the share
  of time in bed spent asleep.
- **Cards**, by chapter: falling asleep, longest still stretch, movements,
  heart rate. Each has its difference from usual and a line of the last
  eight nights; a card whose difference is small dims.
- **Breathing** says it isn't measured: the microphone can't tell a person
  from an empty bed.
- **In-depth view** opens the night's detail (see `night-detail.md`).

"Usual" is the average of up to 7 earlier nights of 3 hours or more, and
needs at least 3. Wake time, the longest still stretch and movements are
the Swift port of `wake_time`, `longest_still_min` and `movement_events` in
`analysis/somnya_analyze/stats.py`.

## How to get to it

Main screen → History → a night.

## Driving it

No check yet. There's no test target or UI drive. In the simulator,
uncompressed exports dropped into the app's `Documents/import` are imported
at launch, so the screen can be looked at with real nights.

## Gotchas

- Earlier nights only have a heart rate once they've been opened (it's
  computed and cached then), so heart rate often has no usual.
- Woke up may land on the end of the recording (unchecked): on a night that ended at the
  pickup, the last movement is the pickup itself.
- The line of nights keeps a minimum scale (twice the difference worth
  pointing out), so ordinary variation draws flat. Scaling it to its own
  range made noise look like big swings.
