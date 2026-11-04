#!/bin/bash
# Law: starting, recording and stopping never read the night from the store on the main thread.
#
# Stop froze the app for up to 6.3 s on the phone, in a search that found nothing, and reading the
# session's windows relationship loads a night's raw streams. Crash recovery at launch is the exception.

cd "$(dirname "$0")/.."
file=Sources/Session/SessionManager.swift
if hits=$(grep -nE 'FetchDescriptor<SensorWindow>|(session|currentSession\??)\.windows' "$file"); then
    echo "✗ session-manager-no-store-reads: $file reads windows from the store on the main thread:"
    echo "$hits" | sed 's/^/    /'
    echo "    Use savedWindows, which already holds each saved window's start and id."
    exit 1
fi
echo "✓ session-manager-no-store-reads: the live session reads no windows from the store"
