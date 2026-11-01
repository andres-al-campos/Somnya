#!/bin/bash
# Law: a @ModelActor is created inside Task.detached, never straight from a view.
#
# A model actor runs its work on the thread that created it, so one made from SwiftUI (the main
# actor) did all its fetching and analysis on the main thread. Pruning old nights that way left
# the app on a black screen at launch.

cd "$(dirname "$0")/.."
actors=$(grep -rhA1 '^@ModelActor' Sources | grep -oE 'actor [A-Za-z]+' | awk '{print $2}')
bad=""
for a in $actors; do
    while IFS= read -r hit; do
        [ -z "$hit" ] && continue
        file=${hit%%:*}; line=$(echo "$hit" | cut -d: -f2)
        # The construction must sit on the same line as, or the line after, a Task.detached.
        if ! sed -n "$((line > 1 ? line - 1 : 1)),${line}p" "$file" | grep -q 'Task.detached'; then
            bad="$bad\n    $file:$line creates $a outside Task.detached"
        fi
    done < <(grep -rn "$a(modelContainer:" Sources)
done
if [ -n "$bad" ]; then
    echo -e "✗ model-actor-off-main: a model actor is created on the caller's thread:$bad"
    echo "    Wrap it: try await Task.detached { try await TheActor(modelContainer: container).work() }.value"
    echo "    A model actor runs on the thread that made it, so made from a view it blocks the screen."
    exit 1
fi
echo "✓ model-actor-off-main: every model actor is created off the main thread"
