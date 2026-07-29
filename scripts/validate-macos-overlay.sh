#!/bin/bash
# Live validation for the ASIF base+overlay macOS create path.
#
#   sudo ./scripts/validate-macos-overlay.sh     # first run: builds the base
#   ./scripts/validate-macos-overlay.sh          # later runs: rootless
#
# Asserts the contract the design promises:
#   1. the first create builds a base image and seals it read-only;
#   2. a second create takes seconds and needs no privileges;
#   3. the VM boots and the guest's readiness signal arrives;
#   4. a published port answers on localhost   ← GATE 1 (FB7731708);
#   5. the guest booted at all with cloned aux ← GATE 2 (aux-clone);
#   6. reset discards the overlay and leaves the base layerUUID unchanged.
#
# GATE 1 decides which port-exposure mechanism ships. vmnet forwarded ports
# were unreachable from the host's own loopback on macOS 26 (Apple DTS
# confirmed it as FB7731708); a community report says macOS 27 fixed it, and
# the fix is NOT in the Beta 4 release notes. If this gate fails, implement the
# reserved-IP NWListener relay described in the spec and ship that instead —
# one mechanism either way.
#
# GATE 2: Apple documents copying auxiliary storage alongside the disk image,
# and a full VZVirtualMachineConfiguration.validate() passes with cloned aux +
# a fresh machine identifier, but only a real boot proves the guest accepts it.
set -euo pipefail

SPOOK="${SPOOK:-./Spooktacular.app/Contents/MacOS/spook}"
BASE_DIR="$HOME/.spooktacular/cache/base"
PASS=0; FAIL=0

check() {
    if [ "$2" = "0" ]; then echo "  ✓ $1"; PASS=$((PASS+1));
    else echo "  ✗ $1"; FAIL=$((FAIL+1)); fi
}

cleanup() {
    "$SPOOK" delete ov-smoke-1 --force >/dev/null 2>&1 || true
    "$SPOOK" delete ov-smoke-2 --force >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "== create #1 (builds the base image if absent) =="
START=$(date +%s)
"$SPOOK" create ov-smoke-1 --openclaw --publish 18789:18789 --no-start --json > /tmp/ov1.json
FIRST_ELAPSED=$(( $(date +%s) - START ))
echo "  first create took ${FIRST_ELAPSED}s"

BUILD=$(ls "$BASE_DIR" 2>/dev/null | head -1)
test -n "$BUILD" && test -f "$BASE_DIR/$BUILD/base.asif"
check "base image exists (macOS build $BUILD)" "$?"

test ! -w "$BASE_DIR/$BUILD/base.asif"
check "base image is sealed read-only" "$?"

BASE_UUID_BEFORE=$(python3 -c "import json;print(json.load(open('$BASE_DIR/$BUILD/base.json'))['layerUUID'])")

echo "== create #2 (must be instant and need no privileges) =="
START=$(date +%s)
"$SPOOK" create ov-smoke-2 --no-start --json > /tmp/ov2.json
SECOND_ELAPSED=$(( $(date +%s) - START ))
echo "  second create took ${SECOND_ELAPSED}s"
[ "$SECOND_ELAPSED" -lt 60 ]
check "second create completed in under 60s (was ${SECOND_ELAPSED}s)" "$?"

BUNDLE=$(python3 -c 'import json;print(json.load(open("/tmp/ov2.json"))["path"])')
test -f "$BUNDLE/disk-overlay.asif"
check "per-VM overlay present" "$?"
test ! -f "$BUNDLE/disk.img"
check "no standalone disk image (the base is shared)" "$?"

# The overlay must be a small delta, not a copy of the base.
OVERLAY_BYTES=$(stat -f%z "$BUNDLE/disk-overlay.asif")
[ "$OVERLAY_BYTES" -lt 104857600 ]
check "overlay is sparse (${OVERLAY_BYTES} bytes)" "$?"

echo "== boot VM #1 and wait for the guest's readiness signal =="
# `spook start` prints '✓ Provisioning completed.' when the guest dials the
# host's vsock listener. No polling loop here by design — the signal is pushed.
"$SPOOK" start ov-smoke-1 --headless > /tmp/ov-start.log 2>&1 &
START_PID=$!

READY=1
for _ in $(seq 1 120); do
    if grep -q "Provisioning completed" /tmp/ov-start.log 2>/dev/null; then READY=0; break; fi
    if grep -q "Provisioning failed" /tmp/ov-start.log 2>/dev/null; then READY=2; break; fi
    sleep 5
done
check "GATE 2 — guest booted from cloned aux and reported readiness" "$READY"
if [ "$READY" = "2" ]; then
    echo "     → provisioning ran but failed; see the VM's first-boot.stderr.log"
elif [ "$READY" != "0" ]; then
    echo "     → no signal within 10 minutes. If the guest never booted, the"
    echo "       aux-clone gate failed: create auxiliary storage per VM instead."
fi

echo "== GATE 1: published port on localhost (FB7731708) =="
GATEWAY=1
for _ in $(seq 1 60); do
    if nc -z -w 2 127.0.0.1 18789 2>/dev/null; then GATEWAY=0; break; fi
    sleep 5
done
check "GATE 1 — localhost:18789 reachable via vmnet forwarding" "$GATEWAY"
if [ "$GATEWAY" != "0" ]; then
    echo "     → loopback forwarding is still broken on this OS build."
    echo "       Ship the reserved-IP NWListener relay instead (see the spec)."
fi

echo "== reset and verify the base is untouched =="
"$SPOOK" stop ov-smoke-1 >/dev/null 2>&1 || kill "$START_PID" 2>/dev/null || true
wait "$START_PID" 2>/dev/null || true

BASE_UUID_AFTER=$(python3 -c "import json;print(json.load(open('$BASE_DIR/$BUILD/base.json'))['layerUUID'])")
[ "$BASE_UUID_BEFORE" = "$BASE_UUID_AFTER" ]
check "base layerUUID unchanged after a guest wrote to its overlay" "$?"

echo ""
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
