#!/bin/bash
# Law: a failed device install reaches build.sh's own retries and error message.
#
# Runs build.sh's install step against a devicectl that always fails. ReSign shows the
# script's last error line in its notification, so if the script dies on devicectl's
# own line, that bare "error 3002" is all anyone sees.

cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/xcrun" <<'EOF'
#!/bin/bash
echo "ERROR: Failed to install the app on the device. (com.apple.dt.CoreDeviceError error 3002 (0xBBA))"
exit 1
EOF
printf '#!/bin/bash\n' > "$tmp/sleep"
chmod +x "$tmp/xcrun" "$tmp/sleep"

{
    echo 'set -euo pipefail'
    echo 'INSTALL=1 DEVICE_ID=TEST APP_PATH=App.app OUT_DIR=build APP_NAME=App'
    sed -n '/^# 4\. Install/,$p' build.sh
} > "$tmp/install.sh"

out=$(PATH="$tmp:$PATH" bash "$tmp/install.sh" 2>&1)
attempts=$(grep -c "CoreDeviceError" <<< "$out")
if [ "$attempts" -eq 3 ] && grep -q "^error: couldn't install to the iPhone" <<< "$out"; then
    echo "✓ install-failure: a failing install is retried 3 times and ends on build.sh's own error"
    exit 0
fi
echo "✗ install-failure: build.sh stopped after $attempts install attempt(s) without its own error message."
echo "    Under set -e, a failing command outside an if/while condition ends the script. Run the"
echo "    devicectl pipeline as the if condition in _template/ios-build.sh, then run"
echo "    _template/sync-build-scripts.sh. Output was:"
sed 's/^/      /' <<< "$out"
exit 1
