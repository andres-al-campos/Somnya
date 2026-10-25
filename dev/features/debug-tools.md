# Debug tools

Updated 2026-10-25 11:38, at 0.4.

Tools for checking the sensors and the app's own log while the capture
pipeline is being built.

## Sub-features

- **Debug Logs**: the app's lifecycle log, with Clear.
- **Sonar Tone**: plays a clean tone at a chosen frequency and volume, to test
  whether the near-ultrasound band a sonar would use bothers anyone.
- **Calibrate dB**: hold a reference sound meter beside the phone, let the
  live meter average, type in the reference reading and tap Calibrate. The
  offset is kept for this phone and used wherever decibels are shown. Reset
  to default undoes it.

## How to get to it

Main screen → Debug. Sonar Tone and Calibrate dB are in its toolbar.

## Driving it

No check yet, and none planned: these are for a developer on the device.

## Gotchas

- These ship in the normal build, on the main screen beside History.
