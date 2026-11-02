#!/bin/bash
# Law: the Night screen's report reads saved results, never a night's windows.
#
# A window's row carries its raw streams, so reading windows for a few numbers loaded 25 MB a night
# and held the screen for seconds. Fetching only some fields made it worse (26 s against 5.8 s on a
# copy of the phone's store), so the numbers are saved with the night instead.

cd "$(dirname "$0")/.."
hits=$(grep -nE '\.windows|SensorWindow' Sources/Session/NightReport.swift)
if [ -n "$hits" ]; then
    echo "✗ night-report-no-windows: Sources/Session/NightReport.swift reads windows:"
    echo "$hits" | sed 's/^/    /'
    echo "    Add the figure to SessionAnalysisCache and read it from there; refresh() is where windows get read."
    exit 1
fi
echo "✓ night-report-no-windows: the Night screen's report reads no windows"
