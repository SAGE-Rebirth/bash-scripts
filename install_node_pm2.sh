#!/usr/bin/env bash
# ============================================================================
#  Node.js + PM2 Installer (Ubuntu/Debian) — package-manager based, no curl|bash
# ----------------------------------------------------------------------------
#  Default path uses the distro 'nodejs' + 'npm' apt packages (no external repo,
#  no GPG key). For a specific modern major, set NODE_MAJOR and it installs via
#  snap ('node --classic') — still no curl|bash and no GPG.
#  Idempotent + safe to re-run. Verbose logging. Detailed errors.
#  Overrides (env vars):
#     NODE_MAJOR=20            install Node 20 via snap   (default: empty -> apt)
#     PM2_USER=<name>          user that owns pm2 startup (default: invoker)
#     SETUP_PM2_STARTUP=yes|no install pm2 systemd boot unit (default: yes)
#     LOG_FILE=<path>          run log location               (default /tmp/...)
# ============================================================================
set -Eeuo pipefail

# ----------------------------- CORE LIBRARY ---------------------------------
SCRIPT_NAME="$(basename "${0:-install_node_pm2.sh}")"
LOG_FILE="${LOG_FILE:-/tmp/${SCRIPT_NAME%.sh}-$(date +%Y%m%d-%H%M%S).log}"
PM2_USER="${PM2_USER:-${SUDO_USER:-$(logname 2>/dev/null || id -un)}}"
NODE_MAJOR="${NODE_MAJOR:-}"
SETUP_PM2_STARTUP="${SETUP_PM2_STARTUP:-yes}"

if [ -t 1 ]; then
  C_RESET=$'\033[0m'; C_INFO=$'\033[36m'; C_OK=$'\033[32m'
  C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_STEP=$'\033[1;35m'
else
  C_RESET=''; C_INFO=''; C_OK=''; C_WARN=''; C_ERR=''; C_STEP=''
fi

if [ "$(id -u)" -eq 0 ]; then SUDO=''; else SUDO='sudo'; fi

: > "$LOG_FILE" 2>/dev/null || LOG_FILE="/tmp/${SCRIPT_NAME%.sh}.log"
_ts()  { date '+%Y-%m-%d %H:%M:%S'; }
_log() { local lvl="$1" col="$2"; shift 2; local line; line="$(_ts) [$lvl] $*"
         printf '%b%s%b\n' "$col" "$line" "$C_RESET"; printf '%s\n' "$line" >> "$LOG_FILE"; }
log_info()  { _log 'INFO ' "$C_INFO" "$@"; }
log_ok()    { _log 'OK   ' "$C_OK"   "$@"; }
log_warn()  { _log 'WARN ' "$C_WARN" "$@"; }
log_error() { _log 'ERROR' "$C_ERR"  "$@" 1>&2; }
log_step()  { printf '\n'; _log 'STEP ' "$C_STEP" "──── $* ────"; }

tail_log() { local n="${1:-5}"
  log_warn "----- last $n line(s) of log ($LOG_FILE) -----"
  tail -n "$n" "$LOG_FILE" 2>/dev/null || true
  printf '%s\n' "-------------------------------------------------"; }

on_error() { local rc=$? line="${1:-?}" cmd="${2:-?}"
  log_error "FAILED at line $line (exit $rc): $cmd"
  tail_log 5
  log_error "$SCRIPT_NAME aborted — full log: $LOG_FILE"
  exit "$rc"; }
trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR

run() {
  log_info "RUN: $*"
  set +e; "$@" 2>&1 | tee -a "$LOG_FILE"; local rc=${PIPESTATUS[0]}; set -e
  if [ "$rc" -ne 0 ]; then log_error "command exited $rc: $*"; return "$rc"; fi
  return 0; }

require_sudo() {
  [ -z "$SUDO" ] && { log_info "Running as root."; return 0; }
  command -v sudo >/dev/null 2>&1 || { log_error "sudo not found and not root."; exit 1; }
  if $SUDO -n true 2>/dev/null; then log_info "Passwordless sudo available."
  else log_warn "sudo may prompt for a password (not ideal in CI)."
       $SUDO true || { log_error "Cannot obtain sudo privileges."; exit 1; }; fi; }

# ----------------------------- APT HELPERS ----------------------------------
export DEBIAN_FRONTEND=noninteractive
APT_LOCK_OPT=(-o 'DPkg::Lock::Timeout=600')
APT_UPDATED=0
apt_update_once() {
  [ "$APT_UPDATED" -eq 1 ] && return 0
  log_step "Refreshing apt package index"
  run $SUDO apt-get "${APT_LOCK_OPT[@]}" update -y
  APT_UPDATED=1; }
apt_install() {
  apt_update_once
  log_step "Installing: $*"
  run $SUDO env DEBIAN_FRONTEND=noninteractive apt-get "${APT_LOCK_OPT[@]}" install -y "$@"; }

# ----------------------------- TASKS ----------------------------------------
check_os() {
  [ -r /etc/os-release ] || { log_error "/etc/os-release missing — unsupported OS."; exit 1; }
  . /etc/os-release
  case "${ID:-}${ID_LIKE:-}" in
    *debian*|*ubuntu*) log_info "Detected ${PRETTY_NAME:-$ID} — supported." ;;
    *) log_error "This installer targets Debian/Ubuntu only (found ${ID:-unknown})."; exit 1 ;;
  esac; }

install_node_apt() {
  log_step "Installing Node.js + npm from distro apt repositories"
  apt_install nodejs npm
  log_ok "Node.js installed via apt."; }

install_node_snap() {
  log_step "Installing Node.js $NODE_MAJOR via snap (--classic, no curl/gpg)"
  command -v snap >/dev/null 2>&1 || apt_install snapd
  run $SUDO snap install node --classic --channel="${NODE_MAJOR}/stable"
  # Expose snap binaries on PATH for this session if needed.
  case ":$PATH:" in *":/snap/bin:"*) : ;; *) export PATH="$PATH:/snap/bin" ;; esac
  log_ok "Node.js $NODE_MAJOR installed via snap."; }

install_node() {
  if [ -n "$NODE_MAJOR" ]; then install_node_snap; else install_node_apt; fi; }

verify_node() {
  log_step "Verifying Node.js / npm"
  command -v node >/dev/null 2>&1 || { log_error "node not found on PATH after install."; exit 1; }
  command -v npm  >/dev/null 2>&1 || { log_error "npm not found on PATH after install.";  exit 1; }
  run node -v
  run npm -v; }

install_pm2() {
  log_step "Installing PM2 globally via npm"
  run $SUDO env PATH="$PATH" npm install -g pm2
  command -v pm2 >/dev/null 2>&1 || { log_error "pm2 not found on PATH after install."; exit 1; }
  run pm2 --version
  log_ok "PM2 installed."; }

setup_pm2_startup() {
  [ "$SETUP_PM2_STARTUP" = yes ] || { log_info "SETUP_PM2_STARTUP=no — skipping boot integration."; return 0; }
  if ! command -v systemctl >/dev/null 2>&1; then
    log_warn "systemd not detected — skipping pm2 startup unit."; return 0; fi
  log_step "Configuring PM2 to resurrect on boot for '$PM2_USER'"
  local home; home="$(getent passwd "$PM2_USER" | cut -d: -f6)"; home="${home:-/home/$PM2_USER}"
  # Running 'pm2 startup' as root installs the systemd unit for the target user.
  run $SUDO env PATH="$PATH" pm2 startup systemd -u "$PM2_USER" --hp "$home" \
    || log_warn "pm2 startup returned non-zero — you can re-run it manually later."
  log_ok "PM2 boot integration configured (run 'pm2 save' as $PM2_USER after starting apps)."; }

# ----------------------------- MAIN -----------------------------------------
main() {
  log_step "Node.js + PM2 installer — start"
  log_info "NODE_MAJOR=${NODE_MAJOR:-<apt default>}  PM2_USER=$PM2_USER  Log=$LOG_FILE"
  require_sudo
  check_os
  install_node
  verify_node
  install_pm2
  setup_pm2_startup
  log_step "Summary"
  log_ok "Node.js and PM2 installation completed successfully."
  tail_log 5; }

main "$@"
