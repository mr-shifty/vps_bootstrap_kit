#!/usr/bin/env bash
set -Eeuo pipefail

# Base server bootstrap for Ubuntu/Debian-like systems.
# Usage:
#   sudo ./bootstrap-server.sh
#   sudo ./bootstrap-server.sh /path/to/config.env

if [[ "${EUID}" -ne 0 ]]; then
  echo "ERROR: Run as root (use sudo)." >&2
  exit 1
fi

CONFIG_FILE="${1:-./server-setup.env}"

if [[ -f "${CONFIG_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${CONFIG_FILE}"
fi

# ---------- configurable values ----------
ADMIN_USER="${ADMIN_USER:-admin}"
ADMIN_PUBLIC_KEY="${ADMIN_PUBLIC_KEY:-}"
SSH_PORT="${SSH_PORT:-22}"
PANEL_IP="${PANEL_IP:-}"
DISABLE_ROOT_LOGIN="${DISABLE_ROOT_LOGIN:-yes}"
DISABLE_PASSWORD_AUTH="${DISABLE_PASSWORD_AUTH:-yes}"
TIMEZONE="${TIMEZONE:-UTC}"
SET_HOSTNAME="${SET_HOSTNAME:-}"
ENABLE_UFW="${ENABLE_UFW:-yes}"
ENABLE_FAIL2BAN="${ENABLE_FAIL2BAN:-yes}"
ENABLE_AUTO_UPDATES="${ENABLE_AUTO_UPDATES:-yes}"
CREATE_SWAP_GB="${CREATE_SWAP_GB:-0}"
AVAILABLE_TCP_PORTS="${AVAILABLE_TCP_PORTS:-14228 80 443 8443 1234}"
# Backward compatibility: if OPEN_TCP_PORTS is not set, reuse MANDATORY_TCP_PORTS if present.
OPEN_TCP_PORTS="${OPEN_TCP_PORTS:-${MANDATORY_TCP_PORTS:-${AVAILABLE_TCP_PORTS}}}"
ENABLE_ACME_SSL="${ENABLE_ACME_SSL:-no}"
ACME_EMAIL="${ACME_EMAIL:-}"
ACME_DOMAIN="${ACME_DOMAIN:-}"
ACME_ALT_DOMAINS="${ACME_ALT_DOMAINS:-}"
ACME_CA="${ACME_CA:-letsencrypt}"
ACME_KEY_LENGTH="${ACME_KEY_LENGTH:-ec-256}"
ACME_CERT_PATH="${ACME_CERT_PATH:-/etc/ssl/acme/${ACME_DOMAIN}/cert.pem}"
ACME_KEY_PATH="${ACME_KEY_PATH:-/etc/ssl/acme/${ACME_DOMAIN}/key.pem}"
ACME_FULLCHAIN_PATH="${ACME_FULLCHAIN_PATH:-/etc/ssl/acme/${ACME_DOMAIN}/fullchain.pem}"
ACME_CA_CERT_PATH="${ACME_CA_CERT_PATH:-/etc/ssl/acme/${ACME_DOMAIN}/ca.pem}"
ACME_RELOAD_CMD="${ACME_RELOAD_CMD:-}"
ACME_PRE_HOOK="${ACME_PRE_HOOK:-}"
ACME_POST_HOOK="${ACME_POST_HOOK:-}"

# ---------- helpers ----------
log() {
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "ERROR: required command is missing: $1" >&2
    exit 1
  fi
}

apt_install_if_missing() {
  local pkg="$1"
  if ! dpkg -s "${pkg}" >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkg}"
  fi
}

set_or_append_sshd_option() {
  local key="$1"
  local value="$2"
  local file="$3"

  if grep -qiE "^\s*${key}\s+" "${file}"; then
    sed -i.bak -E "s|^\s*${key}\s+.*|${key} ${value}|I" "${file}"
  else
    printf '%s %s\n' "${key}" "${value}" >> "${file}"
  fi
}

is_port_in_list() {
  local needle="$1"
  local item
  for item in $2; do
    if [[ "${item}" == "${needle}" ]]; then
      return 0
    fi
  done
  return 1
}

ensure_admin_user() {
  if id -u "${ADMIN_USER}" >/dev/null 2>&1; then
    log "User ${ADMIN_USER} already exists"
  else
    log "Creating user ${ADMIN_USER}"
    adduser --disabled-password --gecos "" "${ADMIN_USER}"
  fi

  usermod -aG sudo "${ADMIN_USER}"

  local home_dir
  home_dir="$(getent passwd "${ADMIN_USER}" | cut -d: -f6)"
  local ssh_dir="${home_dir}/.ssh"
  local auth_keys="${ssh_dir}/authorized_keys"

  mkdir -p "${ssh_dir}"
  chmod 700 "${ssh_dir}"
  touch "${auth_keys}"
  chmod 600 "${auth_keys}"

  if [[ -n "${ADMIN_PUBLIC_KEY}" ]]; then
    if ! grep -qxF "${ADMIN_PUBLIC_KEY}" "${auth_keys}"; then
      log "Adding SSH key for ${ADMIN_USER}"
      printf '%s\n' "${ADMIN_PUBLIC_KEY}" >> "${auth_keys}"
    fi
  fi

  chown -R "${ADMIN_USER}:${ADMIN_USER}" "${ssh_dir}"
}

configure_sshd() {
  local hardening_file="/etc/ssh/sshd_config.d/99-hardening.conf"
  mkdir -p /etc/ssh/sshd_config.d
  touch "${hardening_file}"

  set_or_append_sshd_option "Port" "${SSH_PORT}" "${hardening_file}"
  set_or_append_sshd_option "PermitRootLogin" "${DISABLE_ROOT_LOGIN}" "${hardening_file}"

  if [[ "${DISABLE_PASSWORD_AUTH}" == "yes" && -z "${ADMIN_PUBLIC_KEY}" ]]; then
    log "WARNING: ADMIN_PUBLIC_KEY is empty. Keeping PasswordAuthentication yes to avoid lockout."
    set_or_append_sshd_option "PasswordAuthentication" "yes" "${hardening_file}"
  else
    set_or_append_sshd_option "PasswordAuthentication" "${DISABLE_PASSWORD_AUTH}" "${hardening_file}"
  fi

  set_or_append_sshd_option "PubkeyAuthentication" "yes" "${hardening_file}"
  set_or_append_sshd_option "ChallengeResponseAuthentication" "no" "${hardening_file}"
  set_or_append_sshd_option "UsePAM" "yes" "${hardening_file}"

  if sshd -t; then
    systemctl reload ssh || systemctl reload sshd || true
    log "SSHD config applied"
  else
    echo "ERROR: sshd config test failed. Rolling back ${hardening_file}" >&2
    rm -f "${hardening_file}"
    exit 1
  fi
}

configure_ufw() {
  if [[ "${ENABLE_UFW}" != "yes" ]]; then
    log "Skipping UFW setup"
    return
  fi

  apt_install_if_missing ufw

  ufw --force reset
  ufw default deny incoming
  ufw default allow outgoing

  if [[ -z "${OPEN_TCP_PORTS// }" ]]; then
    echo "ERROR: OPEN_TCP_PORTS is empty. Choose one or more ports from: ${AVAILABLE_TCP_PORTS}" >&2
    exit 1
  fi

  local port
  for port in ${OPEN_TCP_PORTS}; do
    if ! [[ "${port}" =~ ^[0-9]+$ ]] || ((port < 1 || port > 65535)); then
      echo "ERROR: invalid port in OPEN_TCP_PORTS: ${port}" >&2
      exit 1
    fi

    if ! is_port_in_list "${port}" "${AVAILABLE_TCP_PORTS}"; then
      echo "ERROR: port ${port} is not in allowed selection list: ${AVAILABLE_TCP_PORTS}" >&2
      exit 1
    fi

    ufw allow "${port}"/tcp
  done

  if [[ -z "${PANEL_IP}" ]]; then
    echo "ERROR: PANEL_IP is required for UFW SSH rule (v4 restricted access)." >&2
    exit 1
  fi

  # SSH over IPv4 only from panel IP.
  ufw allow from "${PANEL_IP}" to any port "${SSH_PORT}" proto tcp
  # SSH over IPv6 from anywhere.
  ufw allow from ::/0 to any port "${SSH_PORT}" proto tcp

  ufw --force enable

  log "UFW enabled (open ports: ${OPEN_TCP_PORTS}; SSH ${SSH_PORT}: v4 from ${PANEL_IP}, v6 from anywhere)"
}

configure_fail2ban() {
  if [[ "${ENABLE_FAIL2BAN}" != "yes" ]]; then
    log "Skipping fail2ban setup"
    return
  fi

  apt_install_if_missing fail2ban

  cat >/etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 5

[sshd]
enabled = true
port = ${SSH_PORT}
EOF

  systemctl enable --now fail2ban
  log "fail2ban configured"
}

configure_acme_ssl() {
  if [[ "${ENABLE_ACME_SSL}" != "yes" ]]; then
    log "Skipping ACME SSL setup"
    return
  fi

  if [[ -z "${ACME_EMAIL}" ]]; then
    echo "ERROR: ACME_EMAIL is required when ENABLE_ACME_SSL=yes" >&2
    exit 1
  fi

  if [[ -z "${ACME_DOMAIN}" ]]; then
    echo "ERROR: ACME_DOMAIN is required when ENABLE_ACME_SSL=yes" >&2
    exit 1
  fi

  if ! is_port_in_list "80" "${OPEN_TCP_PORTS}"; then
    echo "ERROR: OPEN_TCP_PORTS must include 80 for ACME standalone challenge" >&2
    exit 1
  fi

  local acme_bin="/root/.acme.sh/acme.sh"
  if [[ ! -x "${acme_bin}" ]]; then
    log "Installing acme.sh"
    curl -fsSL https://get.acme.sh | sh -s email="${ACME_EMAIL}"
  fi

  if [[ ! -x "${acme_bin}" ]]; then
    echo "ERROR: acme.sh install failed" >&2
    exit 1
  fi

  "${acme_bin}" --set-default-ca --server "${ACME_CA}"

  local issue_args=(--issue --standalone -d "${ACME_DOMAIN}" --keylength "${ACME_KEY_LENGTH}")
  local alt
  for alt in ${ACME_ALT_DOMAINS}; do
    issue_args+=(-d "${alt}")
  done

  if [[ -n "${ACME_PRE_HOOK}" ]]; then
    issue_args+=(--pre-hook "${ACME_PRE_HOOK}")
  fi
  if [[ -n "${ACME_POST_HOOK}" ]]; then
    issue_args+=(--post-hook "${ACME_POST_HOOK}")
  fi

  log "Issuing certificate via acme.sh for ${ACME_DOMAIN}"
  "${acme_bin}" "${issue_args[@]}"

  mkdir -p "$(dirname "${ACME_CERT_PATH}")"
  mkdir -p "$(dirname "${ACME_KEY_PATH}")"
  mkdir -p "$(dirname "${ACME_FULLCHAIN_PATH}")"
  mkdir -p "$(dirname "${ACME_CA_CERT_PATH}")"

  local install_args=(
    --install-cert -d "${ACME_DOMAIN}"
    --cert-file "${ACME_CERT_PATH}"
    --key-file "${ACME_KEY_PATH}"
    --fullchain-file "${ACME_FULLCHAIN_PATH}"
    --ca-file "${ACME_CA_CERT_PATH}"
  )

  if [[ -n "${ACME_RELOAD_CMD}" ]]; then
    install_args+=(--reloadcmd "${ACME_RELOAD_CMD}")
  fi

  "${acme_bin}" "${install_args[@]}"

  chmod 600 "${ACME_KEY_PATH}" || true
  log "ACME certificate installed"
}

configure_auto_updates() {
  if [[ "${ENABLE_AUTO_UPDATES}" != "yes" ]]; then
    log "Skipping unattended upgrades setup"
    return
  fi

  apt_install_if_missing unattended-upgrades
  apt_install_if_missing apt-listchanges

  cat >/etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

  systemctl restart unattended-upgrades || true
  log "Automatic security updates enabled"
}

configure_timezone_and_hostname() {
  if [[ -n "${TIMEZONE}" ]]; then
    timedatectl set-timezone "${TIMEZONE}" || true
    log "Timezone set to ${TIMEZONE}"
  fi

  if [[ -n "${SET_HOSTNAME}" ]]; then
    hostnamectl set-hostname "${SET_HOSTNAME}"
    log "Hostname set to ${SET_HOSTNAME}"
  fi
}

configure_swap() {
  if [[ "${CREATE_SWAP_GB}" -le 0 ]]; then
    log "Skipping swap creation"
    return
  fi

  if swapon --show | grep -q .; then
    log "Swap already exists, skipping"
    return
  fi

  local swap_file="/swapfile"
  local swap_mb=$((CREATE_SWAP_GB * 1024))

  log "Creating ${CREATE_SWAP_GB}G swapfile"
  fallocate -l "${CREATE_SWAP_GB}G" "${swap_file}" || dd if=/dev/zero of="${swap_file}" bs=1M count="${swap_mb}"
  chmod 600 "${swap_file}"
  mkswap "${swap_file}"
  swapon "${swap_file}"

  if ! grep -qE '^/swapfile\s' /etc/fstab; then
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
  fi

  log "Swap enabled"
}

main() {
  require_cmd apt-get
  require_cmd systemctl
  require_cmd sshd

  log "Starting base server bootstrap"
  DEBIAN_FRONTEND=noninteractive apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y sudo openssh-server curl ca-certificates gnupg lsb-release

  ensure_admin_user
  configure_sshd
  configure_ufw
  configure_fail2ban
  configure_acme_ssl
  configure_auto_updates
  configure_timezone_and_hostname
  configure_swap

  log "Bootstrap completed successfully"
  log "Verify SSH access: ssh -p ${SSH_PORT} ${ADMIN_USER}@<server_ip>"
}

main "$@"
