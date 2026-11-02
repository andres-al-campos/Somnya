#!/bin/bash
# Law: nothing puts a tap on the mic without first checking the input can take one.
#
# The mic restart aborted the app 51 s into a session on 2 Nov, retrying while the mic was unavailable.

cd "$(dirname "$0")/.."
bad=0
while IFS= read -r file; do
    if ! grep -q "\.canTap" "$file"; then
        echo "✗ audio-tap-guarded: $file calls installTap without checking canTap."
        echo "    AVAudioNode.installTap raises an Objective-C exception on a bad format, which Swift can't catch, and an input reports one while a call or Siri holds the mic."
        echo "    Add 'guard input.canTap else { ... }' before the installTap and handle the failure."
        bad=1
    fi
done < <(grep -rl "installTap(" Sources)
[ "$bad" = 0 ] || exit 1
echo "✓ audio-tap-guarded: every mic tap checks the input first"
