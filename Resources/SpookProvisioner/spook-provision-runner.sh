#!/bin/bash
# Spooktacular provisioner runner.
#
# Bundled host-side in the main app's Resources/SpookProvisioner/
# (staged there by build-app.sh; located at runtime via
# `ProvisionerAssets.locate()`). `DiskInjector.installProvisionerDaemon`
# writes this script and its paired LaunchDaemon plist directly onto
# the guest's Data volume — `/usr/local/libexec/` and
# `/Library/LaunchDaemons/` respectively, root:wheel — before first
# boot, by attaching the disk image as a host-side root file
# operation. No guest-side install step, no `SMAppService`
# registration, nothing for the guest user to approve: `launchd`
# invokes this script as root on every boot per `RunAtLoad=true`.
#
# Behavior: fires once per boot (`RunAtLoad=true`). Mounts the
# per-VM virtio-fs share; if `first-boot.sh` is present at the
# share root, runs it as root, captures stdout/stderr/exit-code,
# archives the script body to `first-boot.ran.sh`, and removes
# the trigger file so subsequent boots no-op.
#
# The host writes `first-boot.sh` via `DiskInjector.inject(...)`
# before starting the VM; re-injecting replaces the trigger and
# a new boot runs the new script. No WatchPaths, no queue, no
# timestamped per-run directories — a single flat file tracks
# pending/ran state by presence/absence.

set -uo pipefail

MOUNT_TAG="spook-provision"
MOUNT_POINT="/Library/Application Support/Spooktacular/provision"
SCRIPT_PATH="${MOUNT_POINT}/first-boot.sh"
ARCHIVE_PATH="${MOUNT_POINT}/first-boot.ran.sh"
STDOUT_LOG="${MOUNT_POINT}/first-boot.stdout.log"
STDERR_LOG="${MOUNT_POINT}/first-boot.stderr.log"
EXIT_FILE="${MOUNT_POINT}/first-boot.exit-code"

log() {
    echo "[spook-provisioner $(date -u +%FT%TZ)] $*" >&2
}

mkdir -p "${MOUNT_POINT}"

# Mount if not already mounted. `mount | grep` is the stable
# cross-macOS-version presence check — `mountpoint(1)` isn't
# shipped on macOS.
if ! /sbin/mount | grep -q " on ${MOUNT_POINT} "; then
    log "mounting ${MOUNT_TAG} at ${MOUNT_POINT}"
    if ! /sbin/mount_virtiofs "${MOUNT_TAG}" "${MOUNT_POINT}"; then
        log "ERROR: mount_virtiofs failed — provisioner share unavailable"
        exit 0
    fi
fi

if [ ! -f "${SCRIPT_PATH}" ]; then
    log "no first-boot script present; nothing to do"
    exit 0
fi

# The framework creates the provisioning account (VZMacGuestProvisioningOptions)
# during early boot; this RunAtLoad daemon can fire before it exists. Wait
# (bounded ~2 min) for the account before running the user script, which may
# `sudo -u` it (e.g. the GitHub runner config).
RUNNER_USER="${SPOOK_PROVISION_USER:-runner}"
for _ in $(seq 1 60); do
    id "${RUNNER_USER}" >/dev/null 2>&1 && break
    sleep 2
done

log "running first-boot script"
/bin/bash "${SCRIPT_PATH}" \
    > "${STDOUT_LOG}" \
    2> "${STDERR_LOG}"
EXIT=$?

# Preserve the script body for audit, then remove the trigger
# so `RunAtLoad` on the next boot no-ops. The archive is written
# back through the read-write provisioning share to the HOST —
# never copy the script verbatim: GitHubRunnerTemplate embeds the
# live GitHub Actions registration token as a single `TOKEN='...'`
# line (Sources/SpooktacularApplication/GitHubRunnerTemplate.swift),
# and this archive has no host-side cleanup path, so a verbatim
# copy would leave a valid, unspent, still-registerable token
# sitting on host disk indefinitely for any local user who can
# read the bundle. `sed` blanks the value on any line starting
# with `TOKEN=` — keeping the rest of the script byte-for-byte for
# debugging — and is a harmless no-op for every other template
# (RemoteDesktopTemplate, OpenClawTemplate, custom --user-data
# scripts), none of which emit a `TOKEN=` line.
sed "s/^TOKEN=.*/TOKEN='[REDACTED]'/" "${SCRIPT_PATH}" > "${ARCHIVE_PATH}"
echo "${EXIT}" > "${EXIT_FILE}"
rm -f "${SCRIPT_PATH}"
log "first-boot completed exit=${EXIT}"
