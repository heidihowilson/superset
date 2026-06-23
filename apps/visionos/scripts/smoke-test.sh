#!/usr/bin/env bash
# visionOS smoke gate — boot a sim, run the scheme's test action (SupersetUITests +
# SupersetTests), and ALWAYS reap the simulator afterward.
#
# Why this exists: the worker runs `xcodebuild test` on its Mac, which boots a visionOS
# Simulator for the XCUITest gate but never shuts it down — booted devices and the
# Simulator.app GUI pile up across runs and degrade the host (same boot-a-resource-never-
# reap leak as the agent sessions). The trap below shuts down *only the device this script
# booted* and quits Simulator.app, even when the test goes red or the run is interrupted.
#
# Usage:  bash apps/visionos/scripts/smoke-test.sh        # from anywhere
#         SMOKE_DEVICE="Apple Vision Pro" bash .../smoke-test.sh
set -uo pipefail
cd "$(dirname "$0")/.."   # -> apps/visionos
DEVICE="${SMOKE_DEVICE:-Apple Vision Pro}"

# Resolve the device UDID up front so we shut down exactly what we boot (never `shutdown all`,
# which could kill a Simulator the human has open).
udid=$(xcrun simctl list devices available -j 2>/dev/null | python3 -c "
import sys,json
devs=json.load(sys.stdin).get('devices',{})
print(next((d['udid'] for rs in devs.values() for d in rs if d.get('name')=='$DEVICE'),''))")
[ -z "$udid" ] && { echo "smoke: no '$DEVICE' simulator available — install a visionOS runtime"; exit 2; }

was_booted=$(xcrun simctl list devices booted 2>/dev/null | grep -c "$udid")
reap() {
  # Only reap if we were the ones who booted it; leave a human-opened sim alone.
  [ "$was_booted" = "0" ] && xcrun simctl shutdown "$udid" 2>/dev/null || true
  # Quit the GUI app if no other device is still booted (the lingering-window leak).
  [ -z "$(xcrun simctl list devices booted 2>/dev/null | grep -E 'Booted')" ] \
    && osascript -e 'tell application "Simulator" to quit' 2>/dev/null || true
}
trap reap EXIT INT TERM

xcrun simctl boot "$udid" 2>/dev/null || true
xcodebuild test \
  -project Superset.xcodeproj -scheme Superset \
  -destination "platform=visionOS Simulator,id=$udid"
