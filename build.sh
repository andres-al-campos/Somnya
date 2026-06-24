#!/bin/bash
# Build Somnya.app, sign it with your Apple ID, and install to your iPhone.
#
# Standalone: needs only Xcode's command-line tools and an Apple ID signed in
# to Xcode (Settings → Accounts). No Sideloadly, no ReSign, no Xcode GUI build.
# ReSign can also build this project on its own for auto-renewal, but it is not
# required — this script is the self-contained path.
#
# Usage:
#   ./build.sh                 # build, sign, install to connected iPhone (default)
#   ./build.sh --no-install    # build + sign only, stage into ./build/Somnya.app
#   ./build.sh -n              # short form of --no-install
#   ./build.sh --device <id>   # target a specific device (else first available)
#   ./build.sh -v              # verbose xcodebuild output
#   ./build.sh -h              # show this help

set -euo pipefail

APP_NAME=Somnya
PROJECT="$APP_NAME.xcodeproj"
SCHEME="$APP_NAME"
INSTALL=1
VERBOSE=0
DEVICE_ID=""

while [ $# -gt 0 ]; do
    case "$1" in
        -n|--no-install) INSTALL=0 ;;
        -v|--verbose)    VERBOSE=1 ;;
        --device)        shift; DEVICE_ID="${1:-}" ;;
        -h|--help)
            sed -n '8,17p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "error: unknown flag '$1'. Run '$0 --help' for usage."
            exit 1
            ;;
    esac
    shift
done

cd "$(dirname "$0")"

# 0. Signing config. project.yml pulls DEVELOPMENT_TEAM from Config.xcconfig,
#    which is gitignored (per-machine). On a fresh clone it won't exist yet.
if [ ! -f "Config.xcconfig" ]; then
    echo "error: Config.xcconfig not found. Copy the template and set your Apple Team ID:"
    echo "         cp Config.xcconfig.example Config.xcconfig"
    echo "       then edit Config.xcconfig and set DEVELOPMENT_TEAM (Xcode → Settings →"
    echo "       Accounts → your team). A free Apple ID works. Then re-run ./build.sh."
    exit 1
fi

# 1. Regenerate project from project.yml. Somnya uses xcodegen — the .xcodeproj
#    is a generated artifact, so this must run before xcodebuild can see it.
if [ -f "project.yml" ]; then
    if ! command -v xcodegen >/dev/null 2>&1; then
        echo "error: xcodegen not installed. Install with: brew install xcodegen"
        exit 1
    fi
    echo "→ xcodegen generate"
    xcodegen generate --quiet
fi

# 2. Build + sign. Debug into a controlled derived-data dir so we know exactly
#    where the .app lands — same contract ReSign uses. -allowProvisioningUpdates
#    lets Xcode create/refresh the free-account provisioning profile headlessly.
DERIVED_DATA="$PWD/build/DerivedData"
mkdir -p "$DERIVED_DATA"

echo "→ xcodebuild ($APP_NAME, Debug, signed)"
XCB_ARGS=(
    -project "$PROJECT"
    -scheme "$SCHEME"
    -configuration Debug
    -destination 'generic/platform=iOS'
    -derivedDataPath "$DERIVED_DATA"
    -allowProvisioningUpdates
    clean build
)

if [ "$VERBOSE" = "1" ]; then
    xcodebuild "${XCB_ARGS[@]}"
elif command -v xcbeautify >/dev/null 2>&1; then
    set -o pipefail
    xcodebuild "${XCB_ARGS[@]}" | xcbeautify
else
    set -o pipefail
    # Surface the actionable signing errors; otherwise just the build verdict.
    if ! xcodebuild "${XCB_ARGS[@]}" 2>&1 | tee "$DERIVED_DATA/build.log" \
        | grep -E "(error|warning): |\*\* BUILD (SUCCEEDED|FAILED) \*\*"; then
        :
    fi
    if grep -q "No Accounts\|No profiles for\|Signing for" "$DERIVED_DATA/build.log" 2>/dev/null; then
        echo "error: code signing failed. Open Xcode → Settings → Accounts and sign in"
        echo "       with your Apple ID, then set DEVELOPMENT_TEAM in Config.xcconfig"
        echo "       (copy it from Config.xcconfig.example) and re-run ./build.sh."
        exit 1
    fi
fi

APP_PATH="$DERIVED_DATA/Build/Products/Debug-iphoneos/$APP_NAME.app"
if [ ! -d "$APP_PATH" ]; then
    echo "error: .app not found at $APP_PATH. Re-run with -v to see full xcodebuild output."
    exit 1
fi

# 3. Stage a copy into ./build for convenience / inspection.
OUT_DIR="build"
rm -rf "$OUT_DIR/$APP_NAME.app"
cp -R "$APP_PATH" "$OUT_DIR/"
echo "✓ Built & signed: $OUT_DIR/$APP_NAME.app"

# 4. Install to the connected iPhone via devicectl.
if [ "$INSTALL" = "1" ]; then
    if [ -z "$DEVICE_ID" ]; then
        # First "available" device's identifier (a UUID). Match the UUID by shape
        # rather than column position — the Name/Model columns have a variable
        # word count, so counting fields is unreliable.
        DEVICE_ID=$(xcrun devicectl list devices 2>/dev/null \
            | grep available \
            | grep -oE '[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}' \
            | head -1)
    fi
    if [ -z "$DEVICE_ID" ]; then
        echo "error: no iPhone found. Connect via USB (and unlock it) or pair over Wi-Fi"
        echo "       in Xcode → Window → Devices and Simulators, then re-run ./build.sh."
        echo "       The .app is staged at $OUT_DIR/$APP_NAME.app if you want it."
        exit 1
    fi

    echo "→ Installing to device $DEVICE_ID"
    # devicectl occasionally drops the device link mid-install with a transient
    # "Connection interrupted" (CoreDeviceError 3002). Retry a couple of times
    # before giving up — the identical command usually succeeds on the next try.
    installed=0
    for attempt in 1 2 3; do
        if xcrun devicectl device install app --device "$DEVICE_ID" "$APP_PATH"; then
            installed=1
            break
        fi
        echo "  install attempt $attempt failed (transient device-link error); retrying..."
        sleep 2
    done
    if [ "$installed" = "1" ]; then
        echo "✓ $APP_NAME installed. Launch it from your home screen."
    else
        echo "error: install failed after 3 attempts. Make sure the iPhone is unlocked"
        echo "       and stays connected, then re-run ./build.sh. The signed .app is at"
        echo "       $OUT_DIR/$APP_NAME.app."
        exit 1
    fi
else
    echo "  (--no-install) Skipped device install."
fi
