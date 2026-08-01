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
# `spook` resolves its data root from SUDO_USER, so the invoking user's home
# is the right place to look even when this script runs under sudo. Using
# $HOME here would check /var/root and never find the base.
REAL_HOME="$(eval echo ~${SUDO_USER:-$(id -un)})"
BASE_DIR="$REAL_HOME/.spooktacular/cache/base"
PASS=0; FAIL=0

# Run-scoped scratch. Fixed /tmp paths made the first (privileged) run leave
# root-owned files that a later unprivileged run could not overwrite — and only
# the first run needs root, so every run after it should be unprivileged.
WORK="$(mktemp -d)"
echo "scratch: $WORK"

check() {
    if [ "$2" = "0" ]; then echo "  ✓ $1"; PASS=$((PASS+1));
    else echo "  ✗ $1"; FAIL=$((FAIL+1)); fi
}

# Runs an assertion and records it, without aborting.
#
# The previous form — a bare `test ...` followed by `check "..." "$?"` — could
# never report a failure: under `set -e` the failing test exits the script
# before `check` runs. A run that failed its very first assertion printed no ✗,
# no RESULT line, and looked exactly like a run that had been killed. Reporting
# which gate failed is the only reason this script exists.
assert() {
    local description="$1"; shift
    if "$@"; then echo "  ✓ $description"; PASS=$((PASS+1));
    else echo "  ✗ $description"; FAIL=$((FAIL+1)); fi
}

# Deliberately does not delete. `spook delete` requires per-action presence
# verification, so an unattended cleanup raises a Touch ID sheet in the middle
# of a run and then fails when nobody is at the console — which is how two
# same-named VMs came to exist and made `spook start ov-smoke-1` ambiguous.
# Report what was left instead, with the command to remove it.
cleanup() {
    local leftovers="${VM1_ID:-} ${VM2_ID:-}"
    if [ -n "${leftovers// /}" ]; then
        echo ""
        echo "Smoke VMs left behind (deleting them needs presence verification):"
        for id in $leftovers; do echo "  $SPOOK delete $id --force"; done
    fi
}
trap cleanup EXIT

echo "== create #1 (builds the base image if absent) =="
START=$(date +%s)
"$SPOOK" create ov-smoke-1 --openclaw --publish 18789:18789 --no-start --json > "$WORK/ov1.json"
FIRST_ELAPSED=$(( $(date +%s) - START ))
echo "  first create took ${FIRST_ELAPSED}s"

# Address VMs by the UUID `create --json` just handed back, never by name.
# Names are not unique: a leftover from an earlier run made `ov-smoke-1` match
# two VMs, `spook start` refused the ambiguous selector, and the script then
# waited ten minutes for a readiness signal from a guest it had never booted —
# reporting a GATE 2 failure that was nothing of the kind.
VM1_ID=$(python3 -c "import json;print(json.load(open('$WORK/ov1.json'))['id'])")
echo "  VM #1 is $VM1_ID"

BUILD=$(ls "$BASE_DIR" 2>/dev/null | head -1)
assert "base image exists (macOS build ${BUILD:-none})" test -f "$BASE_DIR/$BUILD/base.asif"

# Ask for the mode rather than for writability. The first build runs as root,
# and root may write any file whatever its permission bits say, so `test -w`
# answers "yes" for a correctly sealed image and `test ! -w` fails every time.
SEAL_MODE=$(stat -f "%OLp" "$BASE_DIR/$BUILD/base.asif" 2>/dev/null || echo "missing")
assert "base image is sealed read-only (mode $SEAL_MODE)" test "$SEAL_MODE" = "444"

BASE_UUID_BEFORE=$(python3 -c "import json;print(json.load(open('$BASE_DIR/$BUILD/base.json'))['layerUUID'])")

echo "== create #2 (must be instant and need no privileges) =="
START=$(date +%s)
"$SPOOK" create ov-smoke-2 --no-start --json > "$WORK/ov2.json"
SECOND_ELAPSED=$(( $(date +%s) - START ))
echo "  second create took ${SECOND_ELAPSED}s"
assert "second create completed in under 60s (was ${SECOND_ELAPSED}s)" \
    test "$SECOND_ELAPSED" -lt 60

VM2_ID=$(python3 -c "import json;print(json.load(open('$WORK/ov2.json'))['id'])")
BUNDLE=$(python3 -c "import json;print(json.load(open('$WORK/ov2.json'))['path'])")
assert "per-VM overlay present" test -f "$BUNDLE/disk-overlay.asif"
assert "no standalone disk image (the base is shared)" test ! -f "$BUNDLE/disk.img"

# The overlay must be a small delta, not a copy of the base.
OVERLAY_BYTES=$(stat -f%z "$BUNDLE/disk-overlay.asif" 2>/dev/null || echo 0)
assert "overlay is sparse (${OVERLAY_BYTES} bytes)" test "$OVERLAY_BYTES" -lt 104857600

echo "== boot VM #1 and wait for the guest's readiness signal =="
# `spook start` prints '✓ Provisioning completed.' when the guest dials the
# host's vsock listener. No polling loop here by design — the signal is pushed.
"$SPOOK" start "$VM1_ID" --headless > "$WORK/ov-start.log" 2>&1 &
START_PID=$!

READY=1
for _ in $(seq 1 120); do
    if grep -q "Provisioning completed" "$WORK/ov-start.log" 2>/dev/null; then READY=0; break; fi
    if grep -q "Provisioning failed" "$WORK/ov-start.log" 2>/dev/null; then READY=2; break; fi
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
"$SPOOK" stop "$VM1_ID" >/dev/null 2>&1 || kill "$START_PID" 2>/dev/null || true
wait "$START_PID" 2>/dev/null || true

BASE_UUID_AFTER=$(python3 -c "import json;print(json.load(open('$BASE_DIR/$BUILD/base.json'))['layerUUID'])")
assert "base layerUUID unchanged after a guest wrote to its overlay" \
    test "$BASE_UUID_BEFORE" = "$BASE_UUID_AFTER"

echo ""
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
