#!/bin/bash
# Docker installation script (invoked by zap appstore)
#
# Required environment variables (injected by zapexec): ZAP_PATH APPS_DIR PKG_PATH APP_PATH APP_VERSION
# Optional (options, injected verbatim as same-named env vars):
#   INSTALL_RUNTIME   select —— docker (default) / podman, container runtime
#   INSTALL_MIRROR    select —— official (get.docker.com, default) / aliyun (--mirror Aliyun)
#   INSTALL_CHANNEL   select —— stable (default) / test / nightly, Docker release channel (docker only)
#   REGISTRY_MIRROR   string —— registry mirror URL, written to /etc/docker/daemon.json
#   DATA_ROOT         string —— data directory, default /var/lib/docker
#   ENABLE_SERVICE    bool   —— when "true", enable on boot and start immediately (default true)
#   JOIN_DOCKER_GROUP string —— comma-separated usernames to add to the docker group to avoid sudo
#
# Notes:
#   * Installs via Docker's official convenience script get-docker.sh: it auto-detects the
#     distribution and invokes the system package manager.
#   * All three init systems (systemd / openrc / sysvinit) are attempted for enabling on boot.
#   * Safe to re-run: zap's upgrade flow is "uninstall first, then install", so this script is idempotent.
set -euo pipefail

source "${ZAP_PATH}/scripts/zap/bash_utils.sh"

assert_root || exit 1

INSTALL_RUNTIME="${INSTALL_RUNTIME:-docker}"
PODMAN_SOCK="/run/podman/podman.sock"
INSTALL_MIRROR="${INSTALL_MIRROR:-official}"
INSTALL_CHANNEL="${INSTALL_CHANNEL:-stable}"
REGISTRY_MIRROR="${REGISTRY_MIRROR:-}"
DATA_ROOT="${DATA_ROOT:-/var/lib/docker}"
ENABLE_SERVICE="${ENABLE_SERVICE:-true}"
JOIN_DOCKER_GROUP="${JOIN_DOCKER_GROUP:-}"

log_info "OS:${OS_PRETTY:-${OS_NAME:-unknown}},Arch:${OS_ARCH_ALIAS:-${OS_ARCH:-unknown}}"

if command -v docker >/dev/null 2>&1; then
    log_warn "Docker is already installed: $(docker --version 2>/dev/null || echo unknown); the existing installation will be overwritten."
fi

# ── Podman branch: no daemon, supports rootless; done after install ──────
if [ "${INSTALL_RUNTIME}" = "podman" ]; then
    log_info "Installing Podman…"
    if command -v podman >/dev/null 2>&1; then
        log_warn "Podman is already installed: $(podman --version 2>/dev/null || echo unknown); the existing installation will be overwritten."
    fi
    PKG_MGR="$(pkg_manager)" || PKG_MGR=""
    if [ -z "${PKG_MGR}" ]; then
        log_error "Unrecognized package manager; cannot install Podman"
        exit 1
    fi
    if ! pkg_install_any "${PKG_MGR}" podman; then
        log_error "Podman installation failed (you may retry using the Docker runtime instead)"
        exit 1
    fi

    # compose: Podman 5 ships `podman compose`; earlier versions fall back to podman-compose
    if ! podman compose version >/dev/null 2>&1; then
        pkg_install_any "${PKG_MGR}" podman-compose \
            || log_warn "podman-compose unavailable: Compose projects require Podman 5+, or install podman-compose manually"
    fi

    # The panel's container API uses podman.socket (compose goes through the CLI and is unaffected)
    if [ "${ENABLE_SERVICE}" = "true" ]; then
        if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
            if systemctl enable --now podman.socket >/dev/null 2>&1; then
                log_info "Enabled podman.socket (panel API uses ${PODMAN_SOCK})"
            else
                log_warn "Failed to enable podman.socket; run manually: systemctl enable --now podman.socket"
            fi
        else
            log_warn "Non-systemd system; start the API service manually: podman system service --time=0 unix://${PODMAN_SOCK}"
        fi
    else
        log_info "podman.socket not enabled as requested (ENABLE_SERVICE=false)"
    fi

    if ! command -v podman >/dev/null 2>&1; then
        log_error "Podman installation failed: podman command not found"
        exit 1
    fi

    ensure_dir "${APP_PATH}"
    cat > "${APP_PATH}/info.yaml" <<EOF
svc_name: podman
instance: podman
install_dir: /usr/bin
config_file: /etc/containers/containers.conf
expose:
    unix:${PODMAN_SOCK}
runtime: podman
version: ${APP_VERSION:-latest}
EOF

    log_ok "Podman installed successfully: $(podman --version 2>/dev/null || echo unknown)"
    log_info "Please set the container runtime to podman in System → Runtime: under Docker, containers run as root and the panel does not grant container capabilities to regular users"
    exit 0
fi

# ── Download the official convenience install script ───────────────────────────────────
INST_TMP="$(mktemp -d)"
trap 'rm -rf "${INST_TMP}"' EXIT

MIRROR_ARG=""
case "${INSTALL_MIRROR}" in
    aliyun)
        MIRROR_ARG="--mirror Aliyun"
        log_info "Install source: Aliyun mirror (get.docker.com --mirror Aliyun)"
        ;;
    official)
        log_info "Install source: official (get.docker.com)"
        ;;
    *)
        log_warn "Unknown install source \"${INSTALL_MIRROR}\"; falling back to the official source"
        ;;
esac

log_info "Downloading the Docker install script…"
download_file "https://get.docker.com" "${INST_TMP}/get-docker.sh"

# ── Version / channel ───────────────────────────────────────────
# When APP_VERSION is "latest" (or empty), VERSION is not specified and the script installs the latest in that channel
INSTALL_VERSION=""
if [ "${APP_VERSION:-latest}" = "latest" ] || [ -z "${APP_VERSION:-}" ]; then
    log_info "Install target: latest in the ${INSTALL_CHANNEL} channel"
else
    INSTALL_VERSION="${APP_VERSION}"
    log_info "Install target: ${INSTALL_VERSION} (${INSTALL_CHANNEL} channel)"
fi

log_info "Starting Docker installation (about 1–3 minutes)…"
# shellcheck disable=SC2086
if ! VERSION="${INSTALL_VERSION}" CHANNEL="${INSTALL_CHANNEL}" \
        sh "${INST_TMP}/get-docker.sh" ${MIRROR_ARG}; then
    log_error "Docker installation failed"
    log_error "On networks in China, switch the install source to aliyun and retry"
    exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
    log_error "Docker installation failed: docker command not found"
    exit 1
fi

# ── daemon.json (written only when there are custom settings) ──────────────────────
DAEMON_JSON="/etc/docker/daemon.json"
ENTRIES=()

if [ "${DATA_ROOT}" != "/var/lib/docker" ]; then
    ensure_dir "${DATA_ROOT}"
    ENTRIES+=("  \"data-root\": \"${DATA_ROOT}\"")
    log_info "Data directory: ${DATA_ROOT}"
fi
if [ -n "${REGISTRY_MIRROR}" ]; then
    ENTRIES+=("  \"registry-mirrors\": [\"${REGISTRY_MIRROR}\"]")
    log_info "Registry mirror: ${REGISTRY_MIRROR}"
fi

DAEMON_WRITTEN="no"
if [ "${#ENTRIES[@]}" -gt 0 ]; then
    ensure_dir /etc/docker
    if [ -f "${DAEMON_JSON}" ]; then
        BAK="${DAEMON_JSON}.zapbak.$(date +%Y%m%d%H%M%S)"
        cp -a "${DAEMON_JSON}" "${BAK}"
        log_warn "${DAEMON_JSON} already exists; backed up to ${BAK} and overwritten. Merge existing custom settings manually"
    fi
    {
        printf '{\n'
        FIRST=1
        for E in "${ENTRIES[@]}"; do
            if [ "${FIRST}" -eq 1 ]; then
                FIRST=0
            else
                printf ',\n'
            fi
            printf '%s' "${E}"
        done
        printf '\n}\n'
    } > "${DAEMON_JSON}"
    DAEMON_WRITTEN="yes"
    log_info "Wrote ${DAEMON_JSON}"
else
    log_info "No custom config needed; skipping daemon.json"
fi

# ── Enable on boot and start ─────────────────────────────────────────
if [ "${ENABLE_SERVICE}" = "true" ]; then
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        if systemctl enable --now docker >/dev/null 2>&1; then
            log_info "Enabled on boot and started docker (systemd)"
        else
            log_warn "systemctl enable --now docker failed; run manually: systemctl enable --now docker"
        fi
    elif command -v rc-update >/dev/null 2>&1; then
        rc-update add docker default >/dev/null 2>&1 || true
        if rc-service docker start >/dev/null 2>&1 || service docker start >/dev/null 2>&1; then
            log_info "Enabled on boot and started docker (openrc)"
        else
            log_warn "docker failed to start; run manually: rc-service docker start"
        fi
    elif command -v service >/dev/null 2>&1; then
        service docker start >/dev/null 2>&1 || true
        log_info "Attempted to start docker (sysvinit)"
    else
        log_warn "Unrecognized init system; start docker manually"
    fi
else
    log_info "On-boot enable skipped as requested (ENABLE_SERVICE=false)"
fi

# ── add user to docker group ─────────────────────────────────────────────
if [ -n "${JOIN_DOCKER_GROUP}" ]; then
    if ! ensure_group docker; then
        log_warn "docker group is not available, skipping user addition"
    else
        IFS=',' read -ra GRANT_USERS <<< "${JOIN_DOCKER_GROUP}" || true
        for U in "${GRANT_USERS[@]}"; do
            U="$(printf '%s' "${U}" | tr -d '[:space:]')"
            [ -n "${U}" ] || continue
            if ! id "${U}" >/dev/null 2>&1; then
                log_warn "User ${U} does not exist, skipping"
                continue
            fi
            if ensure_usergroup "${U}" docker; then
                log_info "User ${U} has been added to the docker group (effective after re-login)"
            else
                log_warn "Failed to add user ${U} to the docker group, please add manually: usermod -aG docker ${U}"
            fi
        done
    fi
fi

# ── check ───────────────────────────────────────────────────
if docker info >/dev/null 2>&1; then
    log_ok "Docker daemon has been started successfully"
else
    log_warn "docker info command failed; start docker manually: systemctl start docker"
fi

VER_LINE="$(docker --version 2>/dev/null || echo unknown)"

# ── Register instance (apps/<category>/<name>/info.yaml) ────────
ensure_dir "${APP_PATH}"
cat > "${APP_PATH}/info.yaml" <<EOF
svc_name: docker
instance: docker
install_dir: /usr/bin
config_file: /etc/docker/daemon.json
expose:
    unix:/var/run/docker.sock
pid_file: /var/run/docker.pid
data_root: ${DATA_ROOT}
channel: ${INSTALL_CHANNEL}
version: ${APP_VERSION:-latest}
daemon_config: ${DAEMON_JSON}
daemon_written: ${DAEMON_WRITTEN}
data_root: ${DATA_ROOT}
registry_mirror: ${REGISTRY_MIRROR}
EOF

log_info "Docker installation successful: ${VER_LINE}"
