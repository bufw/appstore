#!/bin/bash
# PHP Compile & Install Script for AppStore
# inject vars：ZAP_PATH APPS_DIR PKG_PATH APP_PATH APP_VERSION MAJOR_VERSION MINOR_VERSION BUILD_PATH CPU_NUM ZAP_DATA_PATH
#
#   EXTS         multi-select, space-joined —— e.g. "bcmath calendar exif"
#   SET_DEFAULT true = /usr/local/bin/php
#
#  PHP version compatibility (openssl requirement):
#   PHP 7.4.33 require OpenSSL = 1.1.1w
#   PHP 8.0     require OpenSSL = 1.1.1w
#   PHP >= 8.1 require OpenSSL >=3
set -euo pipefail

source "${ZAP_PATH}/scripts/zap/bash_utils.sh"

# ── dependency install ───────────────────────────────────────
PKG_MGR="$(pkg_manager || true)"
case "${PKG_MGR}" in
    apt)
        apt-get update -y >/dev/null 2>&1 || log_warn "apt-get update failed (continuing the install attempt)"
        for p in libxml2-dev libsqlite3-dev libcurl4-openssl-dev libjpeg-dev libwebp-dev \
                 libpng-dev libonig-dev libicu-dev libzip-dev libpq-dev zlib1g-dev pkg-config; do
            pkg_install_any apt "$p" || true
        done
        ;;
    dnf | yum)
        for p in libxml2-devel sqlite-devel curl-devel libjpeg-devel libwebp-devel \
                 libpng-devel oniguruma-devel libicu-devel libzip-devel postgresql-devel \
                 zlib-devel pkgconfig; do
            pkg_install_any "${PKG_MGR}" "$p" || true
        done
        ;;
    *)
        log_warn "Unrecognized package manager: make sure the build dependencies are installed manually"
        ;;
esac

# ── php-fpm www ──────
prepare_install_env www

# ── PHP <= 8.0 uses openssl 1.1 ───────────────────────────
# PHP 7.x-8.0 OpenSSL < 3.0 , require openssl 1.1 :
#   * export PKG_CONFIG_PATH
#   * PHP 7.x configure  --with-openssl=<DIR>
OPENSSL_OPTS="--with-openssl"
if [[ "${APP_VERSION}" < "8.1.0" ]]; then
    if [ ! -d "${APPS_DIR}/openssl1.1" ]; then
        log_error "First, Go to AppStore and install openssl1.1"
        exit 1
    fi
    export PKG_CONFIG_PATH="${APPS_DIR}/openssl1.1/lib/pkgconfig"
    OPENSSL_OPTS="--with-openssl=${APPS_DIR}/openssl1.1"
    # add rpath to php-fpm binary, so that it can find openssl1.1 at runtime without relying on ldconfig
    export LDFLAGS="${LDFLAGS:+$LDFLAGS }-Wl,-rpath,${APPS_DIR}/openssl1.1/lib -L${APPS_DIR}/openssl1.1/lib"
fi
log_info "PKG_CONFIG_PATH: ${PKG_CONFIG_PATH:-} | OPENSSL_OPTS: ${OPENSSL_OPTS}"

PHP_VERSION="${APP_VERSION}"
# Short version name = major + minor concatenated without a dot: 8.5.33 → 85.
# This derives the directory php-85 / service php-fpm-85 / sock & pid php-fpm-85.sock, .pid,
# matching the naming convention in zapd/zapexec (php85 → /var/run/php-fpm-85.sock).
PHP_SHORT_VERSION="${MAJOR_VERSION}${MINOR_VERSION}"
PHP_DOWNLOAD_URL="$(pkg_mirror)/php/php-${PHP_VERSION}.tar.gz"
PHP_DOWNLOAD_NAME="php-${PHP_VERSION}.tar.gz"
PHP_INSTALL_PATH="${APPS_DIR}/php-${PHP_SHORT_VERSION}"
PHP_FPM_SOCK="/var/run/php-fpm-${PHP_SHORT_VERSION}.sock"
PHP_FPM_PID="/var/run/php-fpm-${PHP_SHORT_VERSION}.pid"
PHP_ERROR_LOG="/var/log/php/php-${PHP_SHORT_VERSION}.log"
PHP_FPM_ERROR_LOG="/var/log/php/php-fpm-${PHP_SHORT_VERSION}.log"

cd "${PKG_PATH}"
if [ ! -f "${PHP_DOWNLOAD_NAME}" ]; then
    log_info "Downloading PHP"
    download_file "${PHP_DOWNLOAD_URL}" "${PHP_DOWNLOAD_NAME}"
fi

log_info "Extracting packages"
rm -rf "${BUILD_PATH}"
mkdir -p "${BUILD_PATH}"
tar -xzf "${PHP_DOWNLOAD_NAME}" -C "${BUILD_PATH}"

# ── build & install ───────────────────────────────────────
log_info "building PHP ${APP_VERSION}"
cd "${BUILD_PATH}/php-${APP_VERSION}"

# GD-related options vary by version: PHP 7.x uses --with-jpeg-dir, 8.0+ uses --with-jpeg, 8.1+ supports --with-webp
GD_OPT="--enable-gd"
if [[ "${MAJOR_VERSION}" == "7" ]]; then
    GD_OPT="${GD_OPT} --with-jpeg-dir"
else
    GD_OPT="${GD_OPT} --with-jpeg"
    if [[ "${APP_VERSION}" > "8.1.0" ]]; then
        GD_OPT="${GD_OPT} --with-webp"
    fi
fi

# ── User-selectable extensions (the EXTS multi-select from options; checked values are
#    space-joined into $EXTS) ──
# Expanded one by one into --enable-<ext> and appended to configure; the choice value is the
# switch name, anything outside the allowlist is skipped
REQUIRE_PG=0
EXT_OPTS=()
if [ -n "${EXTS:-}" ]; then
    read -r -a _exts <<< "${EXTS}"
    for _e in "${_exts[@]}"; do
        case "${_e}" in
            bcmath|calendar|exif|fileinfo)
                EXT_OPTS+=(--enable-${_e}) ;;
            pdo_postgresql)
                REQUIRE_PG=1
                EXT_OPTS+=(--with-pdo-pgsql) ;;
            *)
                log_warn "Unrecognized extension \"${_e}\", skipped" ;;
        esac
    done
    if [ ${REQUIRE_PG} -eq 1 ]; then
        #install pgsql-devel
        if [ "${PKG_MGR}" = "apt" ]; then
            pkg_install_any apt postgresql-server-dev-all || true
        elif [ "${PKG_MGR}" = "dnf" ] || [ "${PKG_MGR}" = "yum" ]; then
            pkg_install_any "${PKG_MGR}" postgresql-devel || true
        else
            log_warn "Unrecognized package manager: make sure the PostgreSQL development package is installed manually"
        fi
    fi
    if [ ${#EXT_OPTS[@]} -gt 0 ]; then
        log_info "Extensions enabled for this install: ${EXTS}"
    fi
fi

./configure \
    --prefix="${PHP_INSTALL_PATH}" \
    --with-config-file-path="${PHP_INSTALL_PATH}/etc" \
    --with-config-file-scan-dir="${PHP_INSTALL_PATH}/etc/php.d" \
    --enable-sysvsem \
    --enable-sysvshm \
    --enable-pcntl \
    --enable-fpm \
    --disable-cgi \
    --with-fpm-user=www \
    --with-fpm-group=www \
    ${OPENSSL_OPTS} \
    --with-zlib \
    --with-zip \
    --enable-soap \
    --enable-sockets \
    --with-curl \
    ${GD_OPT} \
    --enable-mysqlnd \
    --with-mysqli=mysqlnd \
    --with-pdo-mysql=mysqlnd \
    --enable-mbstring \
    --enable-intl \
    --enable-bcmath \
    --enable-calendar \
    --enable-exif \
    --enable-fileinfo \
    "${EXT_OPTS[@]}"

log_info "make install"
make -j "${CPU_NUM:-1}" && make install

if [ ! -d "${PHP_INSTALL_PATH}" ]; then
    log_error "PHP ${APP_VERSION} Install failed"
    exit 1
fi

# ── openssl runtime location self-check (7.x-8.0 only) ─────────────────
# Linking with -L always succeeds, but failure only surfaces at runtime (php-fpm won't start),
# so verify the RUNPATH right here.
if [[ "${APP_VERSION}" < "8.1.0" ]] && command -v readelf >/dev/null 2>&1; then
    if readelf -d "${PHP_INSTALL_PATH}/sbin/php-fpm" 2>/dev/null | grep -q "openssl1\.1"; then
        log_ok "php-fpm has openssl1.1 runtime path inlined (RUNPATH); not relying on system ldconfig"
    else
        log_warn "php-fpm has no openssl1.1 RUNPATH; at runtime it must rely on the ldconfig cache. Ensure /etc/ld.so.conf.d/zap-openssl-1.conf exists and run ldconfig"
    fi
fi

# ── Config files ───────────────────────────────────────────────
mkdir -p "${PHP_INSTALL_PATH}/etc/php.d"
# php.ini: prefer the official template, fall back when missing, so the panel's "Service config → PHP"
# always has an editable main config (PHP can run without php.ini and falls back to built-in defaults,
# which would make the panel unable to detect the config)
if [ -f "${BUILD_PATH}/php-${APP_VERSION}/php.ini-production" ]; then
    cp "${BUILD_PATH}/php-${APP_VERSION}/php.ini-production" "${PHP_INSTALL_PATH}/etc/php.ini"
elif [ -f "${BUILD_PATH}/php-${APP_VERSION}/php.ini-development" ]; then
    cp "${BUILD_PATH}/php-${APP_VERSION}/php.ini-development" "${PHP_INSTALL_PATH}/etc/php.ini"
elif [ -f "${PHP_INSTALL_PATH}/etc/php.ini-production" ]; then
    cp "${PHP_INSTALL_PATH}/etc/php.ini-production" "${PHP_INSTALL_PATH}/etc/php.ini"
else
    log_warn "Source package provides no php.ini template; writing a minimal php.ini"
    cat > "${PHP_INSTALL_PATH}/etc/php.ini" <<'PHPEOF'
[PHP]
memory_limit = 128M
post_max_size = 32M
upload_max_filesize = 32M
max_execution_time = 60
max_input_time = 60
date.timezone = Asia/Shanghai
display_errors = Off
expose_php = Off
PHPEOF
fi
if [ -f "${BUILD_PATH}/php-${APP_VERSION}/sapi/fpm/php-fpm.conf" ]; then
    cp "${BUILD_PATH}/php-${APP_VERSION}/sapi/fpm/php-fpm.conf" "${PHP_INSTALL_PATH}/etc/php-fpm.conf"
else
    cp "${PHP_INSTALL_PATH}/etc/php-fpm.conf.default" "${PHP_INSTALL_PATH}/etc/php-fpm.conf"
fi
if [ -f "${BUILD_PATH}/php-${APP_VERSION}/sapi/fpm/www.conf" ]; then
    cp "${BUILD_PATH}/php-${APP_VERSION}/sapi/fpm/www.conf" "${PHP_INSTALL_PATH}/etc/php-fpm.d/www.conf"
else
    cp "${PHP_INSTALL_PATH}/etc/php-fpm.d/www.conf.default" "${PHP_INSTALL_PATH}/etc/php-fpm.d/www.conf"
fi

ensure_dir /var/log/php
sed -i "s#;pid = run/php-fpm.pid#pid = ${PHP_FPM_PID}#g" "${PHP_INSTALL_PATH}/etc/php-fpm.conf"
sed -i "s#;error_log = log/php-fpm.log#error_log = ${PHP_ERROR_LOG}#g" "${PHP_INSTALL_PATH}/etc/php-fpm.conf"
sed -i "s#listen = 127.0.0.1:9000#listen = ${PHP_FPM_SOCK}#g" "${PHP_INSTALL_PATH}/etc/php-fpm.d/www.conf"
sed -i "s#;listen.mode = 0660#listen.mode = 0666#g" "${PHP_INSTALL_PATH}/etc/php-fpm.d/www.conf"
# php_admin_value[error_log]
sed -i "s#;php_admin_value\[error_log\] = log/php-fpm.log#php_admin_value[error_log] = ${PHP_FPM_ERROR_LOG}#g" "${PHP_INSTALL_PATH}/etc/php-fpm.d/www.conf"
# default www
cat > "${PHP_INSTALL_PATH}/etc/php-fpm.d/www.conf" <<EOF
[www]
user = www
group = www
listen = ${PHP_FPM_SOCK}
;listen.backlog = 511
listen.owner = www
listen.group = www
listen.mode = 0666
listen.allowed_clients = 127.0.0.1

pm = ondemand
pm.max_children = 2
;pm.process_idle_timeout = 10s;
pm.max_requests = 500

env[HOSTNAME] = $HOSTNAME
env[PATH] = /usr/local/bin:/usr/bin:/bin
env[TEMP] = /tmp
env[TMP] = /tmp
env[TMPDIR] = /tmp

EOF


# ── systemd / init.d service ─────────────────────────────────
if command -v systemctl >/dev/null 2>&1; then
    if [ -f "${BUILD_PATH}/php-${APP_VERSION}/sapi/fpm/php-fpm.service" ]; then
        cp "${BUILD_PATH}/php-${APP_VERSION}/sapi/fpm/php-fpm.service" "/etc/systemd/system/php-fpm-${PHP_SHORT_VERSION}.service"
    else
        # Generate a minimal service unit (some distro sources don't ship php-fpm.service)
        cat > "/etc/systemd/system/php-fpm-${PHP_SHORT_VERSION}.service" <<EOF
[Unit]
Description=The PHP FastCGI Process Manager (PHP ${PHP_VERSION})
After=network.target

[Service]
Type=forking
ExecStart=${PHP_INSTALL_PATH}/sbin/php-fpm -y ${PHP_INSTALL_PATH}/etc/php-fpm.conf
ExecReload=/bin/kill -USR2 \$MAINPID
PrivateTmp=false

[Install]
WantedBy=multi-user.target
EOF
    fi
    sed -i "s#^PrivateTmp=true#PrivateTmp=false#g" "/etc/systemd/system/php-fpm-${PHP_SHORT_VERSION}.service"
    systemctl daemon-reload
    systemctl enable "php-fpm-${PHP_SHORT_VERSION}.service"
    systemctl start "php-fpm-${PHP_SHORT_VERSION}.service"
elif command -v chkconfig >/dev/null 2>&1; then
    if [ -f "${BUILD_PATH}/php-${APP_VERSION}/sapi/fpm/init.d.php-fpm" ]; then
        cp "${BUILD_PATH}/php-${APP_VERSION}/sapi/fpm/init.d.php-fpm" "/etc/init.d/php-fpm-${PHP_SHORT_VERSION}"
        chmod +x "/etc/init.d/php-fpm-${PHP_SHORT_VERSION}"
    fi
    chkconfig --add "php-fpm-${PHP_SHORT_VERSION}"
    chkconfig "php-fpm-${PHP_SHORT_VERSION}" on
    service "php-fpm-${PHP_SHORT_VERSION}" start
fi

# ── Global command symlinks (when the form option SET_DEFAULT=true, register as the system-wide
#    default PHP) ──
# SET_DEFAULT is injected by the install form's "Set as global default PHP" toggle (true / false).
# Defaults to true, for compatibility with older direct executions or installs whose snapshot lacks
# this option (the historical behavior was to register unconditionally).
if [ "${SET_DEFAULT:-true}" = "true" ]; then
    ln -sf "${PHP_INSTALL_PATH}/bin/php" /usr/local/bin/php
    ln -sf "${PHP_INSTALL_PATH}/bin/php-cgi" /usr/local/bin/php-cgi
    if [ ! -e /usr/bin/php ]; then
        ln -s "${PHP_INSTALL_PATH}/bin/php" /usr/bin/php
    fi
    log_info "Registered PHP ${PHP_VERSION} as the global default (/usr/local/bin)"
else
    log_info "Default not selected; skipping /usr/local/bin registration, keeping the existing default version"
fi

# ── Register instance info (apps/<category>/<name>/info.yaml, shown in "Installed") ──────
# svc_name=php-fpm-<major+minor> (e.g. php-fpm-85, same as the systemd unit); status probing and
# panel start/stop go through systemctl; pid_file is kept as a fallback liveness probe on systems
# without systemd (chkconfig).
ensure_dir "${APP_PATH}"
cat > "${APP_PATH}/info.yaml" <<EOF
svc_name: php-fpm-${PHP_SHORT_VERSION}
instance: php${PHP_SHORT_VERSION}
install_dir: ${PHP_INSTALL_PATH}
version: ${APP_VERSION}
config_file: ${PHP_INSTALL_PATH}/etc/php.ini
config_files:
  - path: ${PHP_INSTALL_PATH}/etc/php.ini
    label: php.ini
  - path: ${PHP_INSTALL_PATH}/etc/php-fpm.conf
    label: php-fpm.conf
  - path: ${PHP_INSTALL_PATH}/etc/php-fpm.d/www.conf
    label: php-fpm.d/www.conf(FPM Pool)
log_files:
  - ${PHP_ERROR_LOG}
  - ${PHP_FPM_ERROR_LOG}
pid_file: ${PHP_FPM_PID}
expose: unix:${PHP_FPM_SOCK}
tags:
  - php
  - runtime
EOF

log_info "PHP ${APP_VERSION} installed successfully"
