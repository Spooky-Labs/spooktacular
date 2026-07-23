#!/bin/bash
# Live validation for Linux cloud-init provisioning — ROOTLESS: run as
# your normal user, no sudo anywhere.
#
#   ./scripts/validate-linux-provisioning.sh [image-alias] [--keep]
#
# Creates a provisioned Linux VM (default image alias: fedora) with the
# OpenClaw template, boots it, and asserts the provisioning contract:
#
#   1. create writes seed.iso + a pendingProvisioning marker (no
#      plaintext password anywhere in the bundle);
#   2. the guest comes up with SSH reachable (cloud-init made the
#      account and enabled sshd);
#   3. the OpenClaw gateway answers on 18789 (first-boot script ran as
#      root via runcmd) — polled up to 10 minutes, npm install is slow;
#   4. after the first start, seed.iso is gone and the marker cleared.
#
# The VM is stopped and deleted at the end unless --keep is passed.
set -euo pipefail

IMAGE="${1:-fedora}"
KEEP="${2:-}"
NAME="lx-smoke"
SPOOK="${SPOOK:-./Spooktacular.app/Contents/MacOS/spook}"
PASS=0; FAIL=0

check() { # label, condition-result
    if [ "$2" = "0" ]; then echo "  ✓ $1"; PASS=$((PASS+1));
    else echo "  ✗ $1"; FAIL=$((FAIL+1)); fi
}

echo "== create ($IMAGE, --openclaw, rootless) =="
CREATE_JSON=$("$SPOOK" create "$NAME" --os linux --from-image "$IMAGE" --openclaw --json)
BUNDLE=$(echo "$CREATE_JSON" | python3 -c 'import json,sys;print(json.load(sys.stdin)["path"])')
VM_USER=$(echo "$CREATE_JSON" | python3 -c 'import json,sys;print(json.load(sys.stdin)["provisioning"]["username"])')
VM_PASS=$(echo "$CREATE_JSON" | python3 -c 'import json,sys;print(json.load(sys.stdin)["provisioning"]["password"])')
echo "  bundle: $BUNDLE (account: $VM_USER)"

test -f "$BUNDLE/seed.iso"; check "seed.iso present after create" "$?"
python3 -c "import json,sys;m=json.load(open('$BUNDLE/metadata.json'));sys.exit(0 if m.get('pendingProvisioning') else 1)"
check "pendingProvisioning marker present" "$?"
! grep -rq "$VM_PASS" "$BUNDLE"; check "plaintext password NOT in bundle" "$?"

echo "== first start (cloud-init applies account + SSH + script) =="
"$SPOOK" start "$NAME" --headless &
START_PID=$!
sleep 5

echo "== waiting for guest IP + SSH (up to 5 min) =="
IP=""
for _ in $(seq 1 60); do
    IP=$("$SPOOK" ip "$NAME" 2>/dev/null | tail -1 | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' || true)
    [ -n "$IP" ] && nc -z -w 2 "$IP" 22 2>/dev/null && break
    sleep 5
done
[ -n "$IP" ] && nc -z -w 2 "$IP" 22; check "SSH reachable at ${IP:-<no ip>} (account exists, sshd up)" "$?"

echo "== waiting for OpenClaw gateway on 18789 (up to 10 min; npm is slow) =="
GATEWAY=1
for _ in $(seq 1 120); do
    if nc -z -w 2 "$IP" 18789 2>/dev/null; then GATEWAY=0; break; fi
    sleep 5
done
check "OpenClaw gateway answering on 18789" "$GATEWAY"

echo "== post-first-boot hygiene =="
"$SPOOK" stop "$NAME" >/dev/null 2>&1 || kill "$START_PID" 2>/dev/null || true
wait "$START_PID" 2>/dev/null || true
test ! -f "$BUNDLE/seed.iso"; check "seed.iso scrubbed after first boot" "$?"
python3 -c "import json,sys;m=json.load(open('$BUNDLE/metadata.json'));sys.exit(1 if m.get('pendingProvisioning') else 0)"
check "pendingProvisioning marker cleared" "$?"

if [ "$KEEP" != "--keep" ]; then
    echo "== cleanup =="
    rm -rf "$BUNDLE"
fi

echo ""
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
