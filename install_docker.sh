#!/usr/bin/env bash
# ============================================================================
#  Docker Installer (Ubuntu/Debian) — official apt packages, no curl|bash, no GPG
# ----------------------------------------------------------------------------
#  Installs docker.io + buildx + compose-v2 straight from the distro repos so
#  there is NO external apt repo, NO downloaded GPG key, NO dearmor step to fail.
#  Idempotent + safe to re-run. Verbose logging. Detailed errors.
#  Overrides (env vars):
#     DOCKER_USER=<name>   user to add to the 'docker' group (default: invoker)
#     GRANT_SUDO=yes|no    give DOCKER_USER passwordless sudo   (default: no)
#     LOG_FILE=<path>      run log location                     (default /tmp/...)
# ============================================================================
set -Eeuo pipefail

# ----------------------------- CORE LIBRARY ---------------------------------
SCRIPT_NAME="$(basename "${0:-install_docker.sh}")"
LOG_FILE="${LOG_FILE:-/tmp/${SCRIPT_NAME%.sh}-$(date +%Y%m%d-%H%M%S).log}"
DOCKER_USER="${DOCKER_USER:-${SUDO_USER:-$(logname 2>/dev/null || id -un)}}"
GRANT_SUDO="${GRANT_SUDO:-no}"

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
APT_LOCK_OPT=(-o 'DPkg::Lock::Timeout=600')   # wait up to 10m for apt/dpkg locks
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
pkg_exists() { apt-cache show "$1" >/dev/null 2>&1; }
apt_install_optional() {   # install only packages that actually exist in the repos
  apt_update_once
  local p
  for p in "$@"; do
    if pkg_exists "$p"; then apt_install "$p"
    else log_warn "Component '$p' not in repositories — skipping (not present on this release)."; fi
  done; }

ensure_group_member() {  # <user> <group>
  local u="$1" g="$2"
  getent group "$g" >/dev/null 2>&1 || run $SUDO groupadd "$g"
  if id -nG "$u" 2>/dev/null | tr ' ' '\n' | grep -qx "$g"; then
    log_ok "User '$u' already in group '$g'."
  else
    run $SUDO usermod -aG "$g" "$u"
    log_ok "Added '$u' to group '$g' — apply now with: newgrp $g (or re-login)."
  fi; }

grant_passwordless_sudo() {  # validated with visudo to avoid lockout
  local u="$1" tmp; tmp="$(mktemp)"
  printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$u" > "$tmp"
  if $SUDO visudo -cf "$tmp" >/dev/null 2>&1; then
    run $SUDO install -m 0440 -o root -g root "$tmp" "/etc/sudoers.d/$u"
    log_ok "Passwordless sudo configured for '$u' (syntax validated)."
  else
    log_error "Generated sudoers entry is invalid — NOT installing (no change made)."
  fi
  rm -f "$tmp"; }

# ----------------------------- TASKS ----------------------------------------
check_os() {
  [ -r /etc/os-release ] || { log_error "/etc/os-release missing — unsupported OS."; exit 1; }
  . /etc/os-release
  case "${ID:-}${ID_LIKE:-}" in
    *debian*|*ubuntu*) log_info "Detected ${PRETTY_NAME:-$ID} — supported." ;;
    *) log_error "This installer targets Debian/Ubuntu only (found ${ID:-unknown})."; exit 1 ;;
  esac; }

remove_conflicts() {
  log_step "Removing conflicting legacy docker packages (if any)"
  run $SUDO apt-get "${APT_LOCK_OPT[@]}" remove -y docker docker-engine runc || true
  log_ok "Legacy package check done."; }

install_docker() {
  log_step "Installing Docker from official Ubuntu repositories"
  # docker.io = Docker engine + CLI from the distro (no external repo/GPG needed)
  apt_install docker.io
  # Optional but recommended components — skipped automatically if not packaged.
  apt_install_optional docker-buildx docker-compose-v2 docker-compose
  log_ok "Docker packages installed."; }

enable_service() {
  log_step "Enabling and starting the Docker service"
  if command -v systemctl >/dev/null 2>&1; then
    run $SUDO systemctl enable docker
    run $SUDO systemctl restart docker
    if $SUDO systemctl is-active --quiet docker; then
      log_ok "Docker service is active."
    else
      log_error "Docker service failed to start. Recent service logs:"
      $SUDO journalctl -u docker -n 5 --no-pager 2>&1 | tee -a "$LOG_FILE" || true
      exit 1
    fi
  else
    log_warn "systemd not detected — start the docker daemon manually for your init system."
  fi; }

configure_permissions() {
  log_step "Configuring permissions for '$DOCKER_USER'"
  ensure_group_member "$DOCKER_USER" docker
  if [ "$GRANT_SUDO" = yes ]; then
    grant_passwordless_sudo "$DOCKER_USER"
  else
    log_info "GRANT_SUDO=no — not modifying sudoers (set GRANT_SUDO=yes to enable)."
  fi; }

verify() {
  log_step "Verifying Docker installation"
  run docker --version
  command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1 \
    && run docker compose version || log_warn "'docker compose' plugin not available (optional)."
  log_info "Running a privileged daemon check (hello-world is skipped to avoid network deps)."
  run $SUDO docker info --format 'Server Version: {{.ServerVersion}} | Storage: {{.Driver}}' \
    || log_warn "Could not query docker info yet — daemon may still be warming up."; }

# ----------------------------- MAIN -----------------------------------------
main() {
  log_step "Docker installer — start"
  log_info "DOCKER_USER=$DOCKER_USER  GRANT_SUDO=$GRANT_SUDO  Log=$LOG_FILE"
  require_sudo
  check_os
  remove_conflicts
  install_docker
  enable_service
  configure_permissions
  verify
  log_step "Summary"
  log_ok "Docker install complete."
  log_info "Run docker without sudo after applying group change: newgrp docker  (or re-login)."
  tail_log 5; }

main "$@"
