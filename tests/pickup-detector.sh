#!/bin/bash
# Law: a pickup ends the night only if the phone doesn't go back to rest with someone beside it.
#
# Turning off the alarm and going back to sleep is a normal morning, and a pickup used to end the
# night on the spot. Each scenario below is a morning, 30 s a window, and the time the night should end.

cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/main.swift" <<'SWIFT'
import Foundation
// A night of `s` still windows, then `o` off the bed (phone moving), and so on.
enum Step { case still(Int), off(Int), stirring(Int) }
func run(_ steps: [Step]) -> Double? {
    var d = PickupDetector(), t = 0.0, flip = false
    for step in steps {
        let (n, kind): (Int, Int)
        switch step { case .still(let c): (n, kind) = (c, 0); case .off(let c): (n, kind) = (c, 1); case .stirring(let c): (n, kind) = (c, 2) }
        for i in 0..<n {
            if kind == 1 { flip.toggle() }
            let moved = kind == 2 && i % 40 == 0
            let r = PickupDetector.Reading(start: Date(timeIntervalSince1970: t), seconds: 30,
                gravity: (0, flip ? 0.5 : 0, -1), gyro: 0, activity: moved ? 2 : 0.3)
            if let end = d.observe(r) { return end.timeIntervalSince1970 / 60 }
            t += 30
        }
    }
    return nil
}
let night = 720 // six hours, in windows
let cases: [(String, [Step], Double?)] = [
    ("alarm, back to sleep, sleeps on", [.still(night), .off(4), .stirring(240)], nil),
    ("alarm, up and carrying the phone", [.still(night), .off(60)], 360),
    ("alarm, phone left on a table", [.still(night), .off(4), .still(300)], 360),
    ("back to sleep, then up, phone left", [.still(night), .off(4), .stirring(100), .still(300)], 360 + 2 + 40 + 0.5),
    ("two pickups, gets up at the second", [.still(night), .off(4), .stirring(60), .off(60)], 360 + 2 + 30),
    ("no pickup", [.still(night)], nil),
]
var bad = 0
for (name, steps, want) in cases where run(steps) != want {
    print("    \(name): night ended at \(run(steps).map { "\($0) min" } ?? "no end"), want \(want.map { "\($0) min" } ?? "no end")")
    bad += 1
}
exit(bad == 0 ? 0 : 1)
SWIFT
if ! out=$(swiftc -o "$tmp/check" "$tmp/main.swift" Sources/Session/PickupDetector.swift Sources/Model/SomnyaConfig.swift 2>&1); then
    echo "✗ pickup-detector: the detector didn't compile on its own:"; echo "$out" | head -20 | sed 's/^/    /'
    echo "    Keep Sources/Session/PickupDetector.swift free of SwiftData, so this check can run without a simulator."
    exit 1
fi
if ! out=$("$tmp/check"); then
    echo "✗ pickup-detector: a morning ended at the wrong time:"; echo "$out"
    echo "    Fix PickupDetector, and night_end in analysis/somnya_analyze/autostop.py with it."
    exit 1
fi
echo "✓ pickup-detector: going back to sleep keeps recording, leaving ends at the pickup"
