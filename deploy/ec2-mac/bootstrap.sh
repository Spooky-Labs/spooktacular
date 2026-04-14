#!/bin/bash
# ==============================================================================
# Spooktacular EC2 Mac Host Bootstrap
# ==============================================================================
#
# Turns an EC2 Mac instance into a Spooktacular host with 2 macOS VM slots.
#
# Usage:
#   - As EC2 user-data (runs automatically on first boot)
#   - Via SSM Run Command: aws ssm send-command --document-name "AWS-RunShellScript" \
#       --parameters commands="curl -fsSL .../bootstrap.sh | bash"
#   - Manually: ssh ec2-user@<ip> 'bash -s' < bootstrap.sh
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
LOG_FILE="/var/log/spooktacular-bootstrap.log"
PLIST_PATH="/Library/LaunchDaemons/app.spooktacular.serve.plist"
TOKEN_FILE="${CONFIG_DIR}/api-token"
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
# Preconditions
# ------------------------------------------------------------------------------

log "=== Spooktacular EC2 Mac Bootstrap ==="
log "Version: ${SPOOKTACULAR_VERSION}"

# Verify we are on macOS
[[ "$(uname)" == "Darwin" ]] || die "This script must run on macOS."

# Verify Apple Silicon (arm64) -- required for Virtualization.framework
[[ "$(uname -m)" == "arm64" ]] || die "Apple Silicon (arm64) required. This host is $(uname -m)."

# Verify macOS 14+ (Sonoma or later)
MACOS_MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
[[ "${MACOS_MAJOR}" -ge 14 ]] || die "macOS 14+ required. Found: $(sw_vers -productVersion)"

log "Host: $(system_profiler SPHardwareDataType 2>/dev/null | grep 'Model Name' | awk -F': ' '{print $2}' || echo 'unknown')"
log "macOS: $(sw_vers -productVersion) ($(sw_vers -buildVersion))"

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

if [[ -f "${TOKEN_FILE}" ]]; then
    log "API token already exists at ${TOKEN_FILE}. Skipping generation."
else
    # Generate a cryptographically random 32-byte hex token
    API_TOKEN="$(openssl rand -hex 32)"
    echo "${API_TOKEN}" | sudo tee "${TOKEN_FILE}" >/dev/null
    sudo chmod 600 "${TOKEN_FILE}"
    log "API token generated and stored at ${TOKEN_FILE}."
    log "Retrieve it with: sudo cat ${TOKEN_FILE}"
fi

# ------------------------------------------------------------------------------
# Step 5: Install LaunchDaemon for spook serve
# ------------------------------------------------------------------------------

log "Step 5/6: Installing LaunchDaemon..."

SPOOK_BIN="$(command -v spook)"
API_TOKEN_VALUE="$(sudo cat "${TOKEN_FILE}")"

# Create the LaunchDaemon plist
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
        <string>--api-token</string>
        <string>${API_TOKEN_VALUE}</string>
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
log "  API token:     sudo cat ${TOKEN_FILE}"
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
