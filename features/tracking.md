# Tracking a night

Updated 2026-10-23 00:01, at 0.4.

Start tracking at bedtime with the phone on the mattress, and stop it in the
morning. Somnya records movement, breathing and heartbeat in 30-second windows
overnight, with the screen locked.

## Sub-features

- **Start Tracking / Stop Tracking**, one button on the main screen. While
  tracking, a live timer and the count of windows recorded so far.
- **From Shortcuts or Siri**: "Start Somnya Session" opens the app and starts
  tracking (for a Back Tap or a bedtime automation); "Stop Somnya Session"
  stops it without opening the app (for a wake-up alarm automation). Each has
  Siri phrases, such as "Start Somnya session".
- **Microphone card**: asks for the microphone, or says it's off and opens
  Settings. Without it, breathing isn't measured.
- **Guardrails**: at start, checks that the screen stays awake, motion and
  the microphone are running, and that it's a real device. A failed one shows
  a warning with how to fix it; tracking goes on.
- **Short recordings**: a night of 30 minutes or less asks whether to save or
  discard it.
- Starting while History or Debug is open goes back to the main screen.

## How to get to it

Open Somnya; the button is on the main screen. Or run the Start Somnya
Session shortcut.

## Driving it

No check yet. Capture needs the phone's accelerometer and microphone through a
locked night, which a simulator doesn't have, and there's no test target. A
start/stop drive in the simulator could check the session record and the
short-recording prompt.

By hand only: a real night on the phone, then its detail.

## Gotchas

- Overnight capture depends on the `audio` background mode keeping the app
  alive with the screen locked (see `AGENTS.md`). If a night records nothing,
  check that first.
- The Start shortcut has to open the app, because capture must run in the
  app's own process. The Stop shortcut deliberately doesn't.
- A session left open when the app dies is closed at the next launch and
  marked truncated in History.
- The main screen is a scaffold: it still says "v0.4 scaffold", and the
  planned single-scroll summary isn't built.
