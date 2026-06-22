#!/usr/bin/env bash
# ============================================================================
#  Jenkins Installer (Ubuntu/Debian) — NO GPG key, NO apt repo, NO keyring
# ----------------------------------------------------------------------------
#  Jenkins is not in the distro repos, so the cleanest package-manager-only
#  path is: download the official .deb once, then let APT install it and
#  resolve every dependency:  apt-get install -y ./jenkins.deb
#  -> no signing key to import, no .asc/.gpg dearmor, no sources.list entry.
#
#  Java is installed straight from the distro apt repos (openjdk).
#  Idempotent + safe to re-run. Verbose logging. Detailed errors.
#  Overrides (env vars):
#     JAVA_PACKAGE=openjdk-17-jre-headless   JRE/JDK package (default shown)
#     JENKINS_VERSION=2.541.3   pin a version  (default: latest debian-stable)
#     JENKINS_USER=jenkins      service user (created by the package)
#     GRANT_SUDO=yes|no         passwordless sudo for JENKINS_USER (default yes)
#     ENABLE_UFW=yes|no         open 8080/ssh via ufw  (default no — avoid lockout)
#     LOG_FILE=<path>           run log location              (default /tmp/...)
# ============================================================================
set -Eeuo pipefail

# ----------------------------- CORE LIBRARY ---------------------------------
SCRIPT_NAME="$(basename "${0:-jenkins-setup.sh}")"
LOG_FILE="${LOG_FILE:-/tmp/${SCRIPT_NAME%.sh}-$(date +%Y%m%d-%H%M%S).log}"
JAVA_PACKAGE="${JAVA_PACKAGE:-openjdk-17-jre-headless}"
JENKINS_USER="${JENKINS_USER:-jenkins}"
JENKINS_VERSION="${JENKINS_VERSION:-}"
GRANT_SUDO="${GRANT_SUDO:-yes}"
ENABLE_UFW="${ENABLE_UFW:-no}"
JENKINS_MIRROR="https://get.jenkins.io/debian-stable"

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

ensure_group_member() {  # <user> <group>
  local u="$1" g="$2"
  getent group "$g" >/dev/null 2>&1 || run $SUDO groupadd "$g"
  if id -nG "$u" 2>/dev/null | tr ' ' '\n' | grep -qx "$g"; then
    log_ok "User '$u' already in group '$g'."
  else
    run $SUDO usermod -aG "$g" "$u"
    log_ok "Added '$u' to group '$g'."
  fi; }

grant_passwordless_sudo() {  # validated with visudo to avoid breaking sudo
  local u="$1" tmp; tmp="$(mktemp)"
  printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$u" > "$tmp"
  if $SUDO visudo -cf "$tmp" >/dev/null 2>&1; then
    run $SUDO install -m 0440 -o root -g root "$tmp" "/etc/sudoers.d/$u"
    log_ok "Passwordless sudo configured for '$u' (syntax validated, perms 0440)."
  else
    log_error "Generated sudoers entry invalid — NOT installing (no change made)."
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

cleanup_old_repo() {
  # Remove any legacy Jenkins apt-repo/key leftovers so 'apt-get update' can't
  # fail later on a stale/expired key (a common source of GPG errors).
  log_step "Removing any legacy Jenkins apt repo / key entries"
  run $SUDO rm -f /etc/apt/sources.list.d/jenkins*.list \
                  /etc/apt/sources.list.d/jenkins*.sources \
                  /usr/share/keyrings/jenkins*.gpg \
                  /usr/share/keyrings/jenkins*.asc \
                  /etc/apt/trusted.gpg.d/jenkins*.gpg \
                  /etc/apt/trusted.gpg.d/jenkins*.asc
  $SUDO sed -i '/pkg\.jenkins\.io/d;/get\.jenkins\.io/d' /etc/apt/sources.list 2>/dev/null || true
  log_ok "Legacy Jenkins repo/key entries cleared (if any)."; }

install_prereqs() {
  # Only base tooling from distro apt — wget is the single small downloader used
  # to fetch the .deb file (no GPG, no piping into a shell).
  apt_install ca-certificates wget fontconfig; }

install_java() {
  log_step "Installing Java ($JAVA_PACKAGE) from distro apt"
  apt_install "$JAVA_PACKAGE"
  command -v java >/dev/null 2>&1 || { log_error "java not found after install."; exit 1; }
  run java -version; }

resolve_deb_name() {
  # Determine the .deb filename to fetch from the official Jenkins mirror.
  if [ -n "$JENKINS_VERSION" ]; then
    printf 'jenkins_%s_all.deb\n' "$JENKINS_VERSION"; return 0
  fi
  local listing name
  listing="$(wget -qO- "$JENKINS_MIRROR/" 2>/dev/null || true)"
  name="$(printf '%s\n' "$listing" \
            | grep -oE 'jenkins_[0-9]+\.[0-9]+\.[0-9]+_all\.deb' \
            | sort -V | tail -n1)"
  # Return empty on failure — the caller decides how to handle it (fail loud,
  # rather than silently installing a hard-coded version that ages over time).
  printf '%s\n' "$name"; }

install_jenkins() {
  log_step "Installing Jenkins from official .deb via APT (no key, no repo)"
  local deb_name deb_path url
  deb_name="$(resolve_deb_name)"
  if [ -z "$deb_name" ]; then
    log_error "Could not determine the latest Jenkins .deb from $JENKINS_MIRROR."
    log_error "The mirror may be unreachable. Pin a version explicitly and retry, e.g.:"
    log_error "    JENKINS_VERSION=2.541.3 ./$SCRIPT_NAME"
    log_error "Find available versions at: $JENKINS_MIRROR/"
    exit 1
  fi
  deb_path="/tmp/$deb_name"
  url="$JENKINS_MIRROR/$deb_name"
  log_info "Selected package: $deb_name"
  log_info "Downloading: $url"
  run $SUDO wget -q --show-progress -O "$deb_path" "$url"
  [ -s "$deb_path" ] || { log_error "Downloaded .deb is empty: $deb_path"; exit 1; }
  apt_update_once
  # APT installs the local .deb AND resolves its dependencies. No signing key
  # is required for a local file install.
  run $SUDO env DEBIAN_FRONTEND=noninteractive apt-get "${APT_LOCK_OPT[@]}" install -y "$deb_path"
  run $SUDO rm -f "$deb_path"
  log_ok "Jenkins installed via APT from local .deb."; }

configure_permissions() {
  log_step "Configuring permissions for '$JENKINS_USER'"
  id "$JENKINS_USER" >/dev/null 2>&1 && log_ok "Service user '$JENKINS_USER' exists." \
    || log_warn "User '$JENKINS_USER' not found (package normally creates it)."
  # Let Jenkins jobs drive docker without sudo, if docker is present.
  if getent group docker >/dev/null 2>&1; then ensure_group_member "$JENKINS_USER" docker; fi
  if [ "$GRANT_SUDO" = yes ]; then grant_passwordless_sudo "$JENKINS_USER"
  else log_info "GRANT_SUDO=no — leaving sudoers untouched."; fi; }

start_jenkins() {
  command -v systemctl >/dev/null 2>&1 || { log_warn "systemd not present — start Jenkins manually."; return 0; }
  log_step "Enabling and starting Jenkins"
  run $SUDO systemctl daemon-reload
  run $SUDO systemctl enable jenkins
  run $SUDO systemctl restart jenkins
  if $SUDO systemctl is-active --quiet jenkins; then
    log_ok "Jenkins service is active."
  else
    log_error "Jenkins failed to start. Recent service logs:"
    $SUDO journalctl -u jenkins -n 5 --no-pager 2>&1 | tee -a "$LOG_FILE" || true
    exit 1
  fi; }

configure_firewall() {
  [ "$ENABLE_UFW" = yes ] || { log_info "ENABLE_UFW=no — not touching the firewall (avoids SSH lockout)."; return 0; }
  command -v ufw >/dev/null 2>&1 || apt_install ufw
  log_step "Configuring UFW (allow ssh + 8080)"
  run $SUDO ufw allow OpenSSH || run $SUDO ufw allow ssh || true
  run $SUDO ufw allow 8080/tcp
  run $SUDO ufw --force enable
  log_ok "UFW configured."; }

show_admin_password() {
  log_step "Initial admin password"
  local f="/var/lib/jenkins/secrets/initialAdminPassword" i
  for i in $(seq 1 30); do $SUDO test -f "$f" && break; sleep 1; done
  if $SUDO test -f "$f"; then
    log_info "Jenkins initial admin password:"
    $SUDO cat "$f" | tee -a "$LOG_FILE"
  else
    log_warn "Password file not ready yet. Retrieve later with: sudo cat $f"
  fi; }

# ----------------------------- MAIN -----------------------------------------
main() {
  log_step "Jenkins installer — start"
  log_info "JAVA=$JAVA_PACKAGE  JENKINS_USER=$JENKINS_USER  GRANT_SUDO=$GRANT_SUDO  UFW=$ENABLE_UFW"
  log_info "Log=$LOG_FILE"
  require_sudo
  check_os
  cleanup_old_repo
  install_prereqs
  install_java
  install_jenkins
  configure_permissions
  start_jenkins
  configure_firewall
  show_admin_password
  log_step "Summary"
  log_ok "Jenkins installation completed successfully."
  log_info "Recent Jenkins service log:"
  $SUDO journalctl -u jenkins -n 5 --no-pager 2>&1 | tee -a "$LOG_FILE" || true
  log_info "Access Jenkins on:  http://<server-ip>:8080  (ensure the port is open in your cloud SG)."
  tail_log 5; }

main "$@"
