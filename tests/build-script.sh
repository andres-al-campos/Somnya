#!/bin/bash
# Law: build.sh matches walled_garden/_template/ios-build.sh, which it's generated from.
#
# A fix made here and never copied up is lost at the next sync, and the other apps never
# get it. Editing this copy first is fine; this fails until the template has it too.
# On a clone without the template beside it, there's nothing to compare, so it passes.

cd "$(dirname "$0")/.."
app=$(basename "$PWD")
template=../_template/ios-build.sh

if [ ! -f "$template" ]; then
    echo "✓ build-script: no _template/ beside this project to compare with"
    exit 0
fi
if sed "s/@APP_NAME@/$app/g" "$template" | cmp -s - build.sh; then
    echo "✓ build-script: build.sh matches _template/ios-build.sh"
    exit 0
fi
echo "✗ build-script: build.sh differs from _template/ios-build.sh."
echo "    If build.sh has a fix, copy it into the template (with @APP_NAME@ for \"$app\") and run"
echo "    _template/sync-build-scripts.sh. If the template is newer, just run the sync."
exit 1
