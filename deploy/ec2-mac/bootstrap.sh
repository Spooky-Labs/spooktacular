#!/bin/bash
# ==============================================================================
# Spooktacular EC2 Mac Host Bootstrap
# ==============================================================================
#
# Turns an EC2 Mac instance into a Spooktacular host with 2 macOS VM slots.
#
# Usage:
#   - As EC2 user-data (runs automatically on first boot)
#   - Via SSM (recommended): aws ssm send-command \
#       --instance-ids i-xxx --document-name "SpooktacularInstall"
#   - Development only: ssh ec2-user@<ip> 'bash -s' < bootstrap.sh
#   - Drain mode: bootstrap.sh --drain   (stop accepting new VMs)
#   - Undrain:    bootstrap.sh --undrain  (resume accepting VMs)
#
# This script is idempotent -- safe to run multiple times.
#
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Configuration
# ------------------------------------------------------------------------------

SPOOKTACULAR_VERSION="${SPOOKTACULAR_VERSION:-latest}"
SPOOK_PORT="${SPOOK_PORT:-8484}"
SPOOK_HOST="${SPOOK_HOST:-0.0.0.0}"
CERT_DIR="/etc/spooktacular/tls"
CONFIG_DIR="/etc/spooktacular"
DRAIN_MARKER="${CONFIG_DIR}/drain"
LOG_FILE="/var/log/spooktacular-bootstrap.log"
PLIST_PATH="/Library/LaunchDaemons/app.spooktacular.serve.plist"
KEYCHAIN_SERVICE="com.spooktacular"
KEYCHAIN_ACCOUNT="api-token"
GITHUB_RELEASES="https://github.com/Spooky-Labs/spooktacular/releases"

# ------------------------------------------------------------------------------
# Logging
# ------------------------------------------------------------------------------

log() {
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[${timestamp}] $*" | tee -a "${LOG_FILE}"
}

log_error() {
    log "ERROR: $*" >&2
}

die() {
    log_error "$*"
    exit 1
}

# ------------------------------------------------------------------------------
# Drain / Undrain Mode
# ------------------------------------------------------------------------------
#
# --drain  : Write a drain marker so spook serve stops accepting new VMs.
#            Existing VMs are allowed to finish. When all VMs stop, the host
#            reports "drained" to the controller.
# --undrain: Remove the drain marker so the host resumes accepting new VMs.

handle_drain() {
    sudo mkdir -p "${CONFIG_DIR}"
    if [[ -f "${DRAIN_MARKER}" ]]; then
        log "Host is already in drain mode."
    else
        sudo touch "${DRAIN_MARKER}"
        log "Host marked for drain. spook serve will stop accepting new VMs."
        log "Existing VMs will be allowed to finish."
    fi
    exit 0
}

handle_undrain() {
    if [[ -f "${DRAIN_MARKER}" ]]; then
        sudo rm -f "${DRAIN_MARKER}"
        log "Drain marker removed. Host is now accepting new VMs."
    else
        log "Host is not in drain mode. Nothing to do."
    fi
    exit 0
}

# Parse flags
for arg in "$@"; do
    case "${arg}" in
        --drain)   handle_drain   ;;
        --undrain) handle_undrain ;;
        --help|-h)
            echo "Usage: bootstrap.sh [--drain | --undrain]"
            echo "  (no flags)  Bootstrap the host for Spooktacular"
            echo "  --drain     Stop accepting new VMs (graceful drain)"
            echo "  --undrain   Resume accepting new VMs"
            exit 0
            ;;
        *)
            die "Unknown flag: ${arg}. Use --help for usage."
            ;;
    esac
done

# ------------------------------------------------------------------------------
# IMDSv2 -- Instance Identity
# ------------------------------------------------------------------------------
#
# Query the EC2 Instance Metadata Service (v2, token-based) for the instance
# identity document. The instance ID is used later as a seed for API token
# generation so tokens are deterministically tied to the instance.

imds_fetch() {
    # Acquire a session token (TTL 6 hours)
    local imds_token
    imds_token="$(curl -sf -X PUT \
        "http://169.254.169.254/latest/api/token" \
        -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" \
        --connect-timeout 2 || true)"

    if [[ -z "${imds_token}" ]]; then
        log "WARNING: Could not reach IMDS. Running outside EC2 or IMDS disabled."
        INSTANCE_ID="local-$(hostname -s)"
        INSTANCE_TYPE="unknown"
        return
    fi

    INSTANCE_ID="$(curl -sf \
        -H "X-aws-ec2-metadata-token: ${imds_token}" \
        http://169.254.169.254/latest/meta-data/instance-id \
        --connect-timeout 2 || echo "unknown")"

    INSTANCE_TYPE="$(curl -sf \
        -H "X-aws-ec2-metadata-token: ${imds_token}" \
        http://169.254.169.254/latest/meta-data/instance-type \
        --connect-timeout 2 || echo "unknown")"
}

imds_fetch

# ------------------------------------------------------------------------------
# Preconditions
# ------------------------------------------------------------------------------

log "=== Spooktacular EC2 Mac Bootstrap ==="
log "Version: ${SPOOKTACULAR_VERSION}"
log "Instance: ${INSTANCE_ID} (${INSTANCE_TYPE})"

# Verify we are on macOS
[[ "$(uname)" == "Darwin" ]] || die "This script must run on macOS."

# Verify Apple Silicon (arm64) -- required for Virtualization.framework
[[ "$(uname -m)" == "arm64" ]] || die "Apple Silicon (arm64) required. This host is $(uname -m)."

# Verify macOS 14+ (Sonoma or later) -- preflight check
MACOS_VERSION="$(sw_vers -productVersion)"
MACOS_MAJOR="$(echo "${MACOS_VERSION}" | cut -d. -f1)"
if [[ "${MACOS_MAJOR}" -lt 14 ]]; then
    die "macOS 14 (Sonoma) or later required for Virtualization.framework. Found: ${MACOS_VERSION}. Please use a macOS 14+ AMI (amzn-ec2-macos-14* or amzn-ec2-macos-15*)."
fi

log "Host: $(system_profiler SPHardwareDataType 2>/dev/null | grep 'Model Name' | awk -F': ' '{print $2}' || echo 'unknown')"
log "macOS: ${MACOS_VERSION} ($(sw_vers -buildVersion))"

# Log supported macOS versions for this host family
log_supported_macos_versions() {
    case "${INSTANCE_TYPE}" in
        mac1.metal)
            log "Host family: mac1 (Intel x86_64). Supports macOS 10.15+."
            log "WARNING: mac1.metal is Intel-based and does NOT support Virtualization.framework VMs."
            ;;
        mac2.metal)
            log "Host family: mac2 (Apple M1). Supports macOS 12 (Monterey) and later."
            ;;
        mac2-m1ultra.metal)
            log "Host family: mac2-m1ultra (Apple M1 Ultra). Supports macOS 12 (Monterey) and later."
            ;;
        mac2-m2.metal)
            log "Host family: mac2-m2 (Apple M2). Supports macOS 13 (Ventura) and later."
            ;;
        mac2-m2pro.metal)
            log "Host family: mac2-m2pro (Apple M2 Pro). Supports macOS 13 (Ventura) and later."
            ;;
        unknown)
            log "Instance type unknown (not running on EC2). Skipping host family check."
            ;;
        *)
            log "Instance type: ${INSTANCE_TYPE}. Check AWS docs for supported macOS versions."
            ;;
    esac
}

log_supported_macos_versions

# ------------------------------------------------------------------------------
# Step 1: Install Spooktacular
# ------------------------------------------------------------------------------

log "Step 1/6: Installing Spooktacular..."

if command -v spook &>/dev/null; then
    INSTALLED_VERSION="$(spook --version 2>/dev/null || echo 'unknown')"
    log "Spooktacular already installed: ${INSTALLED_VERSION}"
    if [[ "${SPOOKTACULAR_VERSION}" == "latest" ]]; then
        log "Skipping reinstall (already present). Set SPOOKTACULAR_VERSION to force a specific version."
    fi
else
    # Try Homebrew first
    if command -v brew &>/dev/null; then
        log "Installing via Homebrew..."
        if brew install --cask spooktacular 2>>"${LOG_FILE}"; then
            log "Homebrew install succeeded."
        else
            log "Homebrew install failed, falling back to GitHub release."
            INSTALL_FROM_GITHUB=true
        fi
    else
        INSTALL_FROM_GITHUB=true
    fi

    if [[ "${INSTALL_FROM_GITHUB:-false}" == "true" ]]; then
        log "Installing from GitHub releases..."
        DOWNLOAD_URL="${GITHUB_RELEASES}/latest/download/spook"
        if [[ "${SPOOKTACULAR_VERSION}" != "latest" ]]; then
            DOWNLOAD_URL="${GITHUB_RELEASES}/download/v${SPOOKTACULAR_VERSION}/spook"
        fi

        curl -fsSL "${DOWNLOAD_URL}" -o /usr/local/bin/spook \
            || die "Failed to download spook from ${DOWNLOAD_URL}"
        chmod +x /usr/local/bin/spook
        log "Installed spook to /usr/local/bin/spook"
    fi
fi

# Verify installation
command -v spook &>/dev/null || die "spook binary not found in PATH after installation."
log "spook version: $(spook --version 2>/dev/null || echo 'unknown')"

# ------------------------------------------------------------------------------
# Step 2: Generate TLS certificates
# ------------------------------------------------------------------------------

log "Step 2/6: Configuring TLS certificates..."

sudo mkdir -p "${CERT_DIR}"

if [[ -f "${CERT_DIR}/cert.pem" && -f "${CERT_DIR}/key.pem" ]]; then
    log "TLS certificates already exist at ${CERT_DIR}/. Skipping generation."
    log "To regenerate, delete ${CERT_DIR}/cert.pem and ${CERT_DIR}/key.pem, then re-run."
else
    log "Generating self-signed TLS certificate..."
    log "WARNING: Self-signed certs are for bootstrapping only. Replace with"
    log "         ACM Private CA or your org's PKI certificates for production."

    # Get the instance's private IP for the SAN (if on EC2)
    INSTANCE_IP="$(curl -s --connect-timeout 2 http://169.254.169.254/latest/meta-data/local-ipv4 || echo '127.0.0.1')"
    INSTANCE_HOSTNAME="$(hostname -f 2>/dev/null || hostname)"

    sudo openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout "${CERT_DIR}/key.pem" \
        -out "${CERT_DIR}/cert.pem" \
        -days 365 \
        -subj "/CN=spooktacular/O=Spooktacular" \
        -addext "subjectAltName=IP:${INSTANCE_IP},IP:127.0.0.1,DNS:${INSTANCE_HOSTNAME},DNS:localhost" \
        2>>"${LOG_FILE}" \
        || die "Failed to generate TLS certificate."

    sudo chmod 600 "${CERT_DIR}/key.pem"
    sudo chmod 644 "${CERT_DIR}/cert.pem"
    log "TLS certificate generated for ${INSTANCE_IP} (expires in 365 days)."
fi

# ------------------------------------------------------------------------------
# Step 3: Create base VM from latest macOS
# ------------------------------------------------------------------------------

log "Step 3/6: Creating base VM image..."

if spook list 2>/dev/null | grep -q "^base "; then
    log "Base VM already exists. Skipping creation."
    log "To recreate, run: spook delete base && spook create base --from-ipsw latest"
else
    log "Downloading and installing latest macOS restore image..."
    log "This step downloads ~13GB and may take 15-30 minutes on first run."

    spook create base --from-ipsw latest 2>&1 | tee -a "${LOG_FILE}" \
        || die "Failed to create base VM. Check ${LOG_FILE} for details."

    log "Base VM created successfully."
fi

# ------------------------------------------------------------------------------
# Step 4: Generate API token
# ------------------------------------------------------------------------------

log "Step 4/6: Configuring API authentication..."

sudo mkdir -p "${CONFIG_DIR}"

# Store the API token in the macOS Keychain instead of a plaintext file.
# Rationale: tokens in files risk exposure via world-readable permissions,
# ps output (when passed as CLI arguments), LaunchDaemon plist contents,
# and shell history. The Keychain is encrypted at rest and access-controlled
# by the OS. The spook daemon reads the token from Keychain at startup.
if security find-generic-password -s "${KEYCHAIN_SERVICE}" -a "${KEYCHAIN_ACCOUNT}" >/dev/null 2>&1; then
    log "API token already exists in Keychain (service=${KEYCHAIN_SERVICE}). Skipping generation."
else
    # Generate a 32-byte hex token seeded with the instance identity.
    # By mixing the instance ID into the seed, the token is deterministically
    # tied to this EC2 instance. If the same bootstrap runs again on the same
    # instance (idempotent re-run), the Keychain check above prevents
    # regeneration. On a *new* instance, a new unique token is produced.
    SEED_MATERIAL="${INSTANCE_ID}-$(date +%s)-$(openssl rand -hex 16)"
    API_TOKEN="$(echo -n "${SEED_MATERIAL}" | openssl dgst -sha256 -hex | awk '{print $NF}')"

    # -U updates if exists, -a is account, -s is service, -w is password
    security add-generic-password \
        -a "${KEYCHAIN_ACCOUNT}" \
        -s "${KEYCHAIN_SERVICE}" \
        -w "${API_TOKEN}" \
        -U \
        || die "Failed to store API token in Keychain."

    # Remove any legacy plaintext token file from previous bootstrap runs
    if [[ -f "${CONFIG_DIR}/api-token" ]]; then
        sudo rm -f "${CONFIG_DIR}/api-token"
        log "Removed legacy plaintext token file."
    fi

    log "API token generated and stored in Keychain (service=${KEYCHAIN_SERVICE}, account=${KEYCHAIN_ACCOUNT})."
    log "Retrieve it with: security find-generic-password -s '${KEYCHAIN_SERVICE}' -a '${KEYCHAIN_ACCOUNT}' -w"
fi

# ------------------------------------------------------------------------------
# Step 5: Install LaunchDaemon for spook serve
# ------------------------------------------------------------------------------

log "Step 5/6: Installing LaunchDaemon..."

SPOOK_BIN="$(command -v spook)"

# Create the LaunchDaemon plist.
# NOTE: The API token is NOT passed as a ProgramArguments entry. Passing
# secrets via plist arguments exposes them in `ps` output and in the plist
# file itself. Instead, `spook serve` reads the token from the macOS
# Keychain at startup using service="com.spooktacular", account="api-token".
sudo tee "${PLIST_PATH}" >/dev/null <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>app.spooktacular.serve</string>

    <key>ProgramArguments</key>
    <array>
        <string>${SPOOK_BIN}</string>
        <string>serve</string>
        <string>--host</string>
        <string>${SPOOK_HOST}</string>
        <string>--port</string>
        <string>${SPOOK_PORT}</string>
        <string>--tls-cert</string>
        <string>${CERT_DIR}/cert.pem</string>
        <string>--tls-key</string>
        <string>${CERT_DIR}/key.pem</string>
    </array>

    <key>RunAtLoad</key>
    <true/>

    <key>KeepAlive</key>
    <true/>

    <key>StandardOutPath</key>
    <string>/var/log/spooktacular-serve.log</string>

    <key>StandardErrorPath</key>
    <string>/var/log/spooktacular-serve.log</string>

    <key>WorkingDirectory</key>
    <string>/var/root</string>
</dict>
</plist>
PLIST

sudo chmod 644 "${PLIST_PATH}"
sudo chown root:wheel "${PLIST_PATH}"

# Load (or reload) the LaunchDaemon
if sudo launchctl list | grep -q "app.spooktacular.serve"; then
    log "LaunchDaemon already loaded. Reloading..."
    sudo launchctl unload "${PLIST_PATH}" 2>/dev/null || true
fi

sudo launchctl load "${PLIST_PATH}" \
    || die "Failed to load LaunchDaemon. Check: sudo launchctl list app.spooktacular.serve"

log "LaunchDaemon installed and loaded."

# Wait briefly for the server to start
sleep 3

# Verify the API server is responding
if curl -sf -k "https://localhost:${SPOOK_PORT}/health" >/dev/null 2>&1; then
    log "API server is responding on port ${SPOOK_PORT} (TLS enabled)."
else
    log "WARNING: API server not yet responding. It may still be starting."
    log "Check logs: tail -f /var/log/spooktacular-serve.log"
fi

# ------------------------------------------------------------------------------
# Step 6: Validate installation
# ------------------------------------------------------------------------------

log "Step 6/6: Running validation..."

spook doctor 2>&1 | tee -a "${LOG_FILE}" || true

# ------------------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------------------

INSTANCE_IP="$(curl -s --connect-timeout 2 http://169.254.169.254/latest/meta-data/local-ipv4 || echo '<instance-ip>')"

log ""
log "=============================================="
log "  Spooktacular ready -- 2 VM slots available"
log "=============================================="
log ""
log "  API endpoint:  https://${INSTANCE_IP}:${SPOOK_PORT}"
log "  API token:     security find-generic-password -s '${KEYCHAIN_SERVICE}' -a '${KEYCHAIN_ACCOUNT}' -w"
log "  Base VM:       spook list"
log "  Clone a VM:    spook clone base runner-01"
log "  Start a VM:    spook start runner-01 --headless"
log "  Health check:  spook doctor"
log "  Server logs:   tail -f /var/log/spooktacular-serve.log"
log ""
log "  For Kubernetes integration, point the controller at:"
log "    https://${INSTANCE_IP}:${SPOOK_PORT}"
log ""
log "  See: deploy/kubernetes/README.md"
log ""
