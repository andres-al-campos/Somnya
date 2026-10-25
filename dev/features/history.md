# History

Updated 2026-10-25 11:38, at 0.4.

Every recorded night, newest first, and a way to get them off the phone for
analysis.

## Sub-features

- A list of nights with date, length and window count. The night being
  recorded is marked ACTIVE, one where tracking stopped unexpectedly
  TRUNCATED, and an exported one with a cloud tick.
- Tap a night for its detail ([A night's detail](night-detail.md)).
- **Export new** (nights not yet exported) or **Export all**, as a zip of one
  JSON file per night, through the share sheet. Exported nights are marked.
- Swipe to delete a night.

## How to get to it

Main screen → History. The button shows how many nights there are.

## Driving it

No check yet. There's no test target, and a night can only be recorded on a
phone.

By hand only: export a night and open it with `analysis/`.

## Gotchas

- Export is JSON only. A CSV writer for the 30-second windows exists in the
  code but nothing calls it.
- Exports are for `analysis/` on the Mac; exported nights land in
  `analysis/sessions/`, which is gitignored as personal data.
