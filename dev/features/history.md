# History

Updated 2026-10-28 18:17, at 0.4.

Every recorded night, newest first, and a way to get them off the phone for
analysis.

## Sub-features

- A list of nights with date, length and window count. The night being
  recorded is marked ACTIVE, one where tracking stopped unexpectedly
  TRUNCATED, and an exported one with a cloud tick.
- Tap a night for its detail ([A night's detail](night-detail.md)).
- **Export new** (nights not yet exported) or **Export all**, as a zip of one
  JSON file per night, through the share sheet. Exported nights are marked.
- **Sync to <folder>**: pick a folder once (**Choose sync folder…**), then one
  tap writes every finished night the folder doesn't have yet, one plain JSON
  file each. Meant for the Mac's `analysis/sessions/` shared over SMB and
  connected in the Files app, so nights reach the Mac over the local network
  with no share sheet and no unzipping.
- Swipe to delete a night.

## How to get to it

Main screen → History. The button shows how many nights there are.

## Driving it

No check yet. There's no test target, and a night can only be recorded on a
phone.

By hand only: export a night and open it with `analysis/`. For sync: share
`analysis/sessions/` from the Mac (System Settings → General → Sharing → File
Sharing), connect to it in Files (⋯ → Connect to Server →
`smb://<mac>.local`, Registered User), choose it as the sync folder, tap Sync,
and check the files land on the Mac.

## Gotchas

- Sync decides what's missing from the folder's contents, not `exportedAt`,
  so files deleted on the Mac come back on the next sync. It also stamps
  `exportedAt`, so Export new skips synced nights.
- The sync folder is a security-scoped bookmark. Whether it survives the
  phone or the Mac restarting is unverified; if Sync says it can't reach the
  folder, opening the share once in Files reconnects it, and choosing the
  folder again is the fallback.

- Export is JSON only. A CSV writer for the 30-second windows exists in the
  code but nothing calls it.
- Exports are for `analysis/` on the Mac; exported nights land in
  `analysis/sessions/`, which is gitignored as personal data.
