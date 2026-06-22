#!/usr/bin/env bash
# ============================================================================
#  Safe History & SSH Login Cleaner
# ----------------------------------------------------------------------------
#  Clears shell history, SSH login records (wtmp/btmp/lastlog) and known_hosts
#  WITHOUT breaking system logging (truncates, never deletes log files).
#  Idempotent + safe to re-run. Verbose logging. Detailed errors.
#  Overrides (env vars):
#     CONFIRM=yes           skip the interactive confirmation prompt
#     CLEAR_KNOWN_HOSTS=no  keep ~/.ssh/known_hosts          (default: yes)
#     TARGET_USER=<name>    whose history to clean   (default: invoking user)
#     LOG_FILE=<path>       run log location                 (default /tmp/...)
# ============================================================================
set -Eeuo pipefail

# ----------------------------- CORE LIBRARY ---------------------------------
SCRIPT_NAME="$(basename "${0:-safe-clean.sh}")"
LOG_FILE="${LOG_FILE:-/tmp/${SCRIPT_NAME%.sh}-$(date +%Y%m%d-%H%M%S).log}"
TARGET_USER="${TARGET_USER:-${SUDO_USER:-$(logname 2>/dev/null || id -un)}}"
CLEAR_KNOWN_HOSTS="${CLEAR_KNOWN_HOSTS:-yes}"

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

# ----------------------------- HELPERS --------------------------------------
user_home() { getent passwd "$TARGET_USER" | cut -d: -f6; }

truncate_file() {  # safely zero a file only if it exists (keeps inode + logging)
  local f="$1" label="$2"
  if $SUDO test -e "$f"; then
    run $SUDO truncate -s 0 "$f"
    log_ok "Cleared: $f ($label)"
  else
    log_info "Not present, skipping: $f"
  fi; }

confirm() {
  [ "${CONFIRM:-}" = yes ] && { log_info "CONFIRM=yes — proceeding without prompt."; return 0; }
  if [ -t 0 ]; then
    log_warn "This will clear shell history and SSH login records for '$TARGET_USER'."
    read -r -p "Continue? [y/N]: " a
    [[ "$a" =~ ^[Yy]$ ]] || { log_info "Aborted by user."; exit 0; }
  else
    log_info "Non-interactive shell and CONFIRM!=yes — proceeding (logged for audit)."
  fi; }

# ----------------------------- TASKS ----------------------------------------
clear_shell_history() {
  log_step "Clearing shell history for '$TARGET_USER'"
  # In-memory history of THIS shell (best-effort; only meaningful when sourced).
  history -c 2>/dev/null || true
  local home; home="$(user_home)"; home="${home:-$HOME}"
  local f
  for f in "$home/.bash_history" "$home/.zsh_history" "$home/.sh_history" "$home/.local/share/fish/fish_history"; do
    if [ -f "$f" ]; then run : > "$f" 2>/dev/null || run $SUDO truncate -s 0 "$f"; log_ok "Cleared: $f"; fi
  done; }

clear_login_records() {
  log_step "Clearing SSH/login records (truncate — logging stays intact)"
  truncate_file /var/log/wtmp    "login history"
  truncate_file /var/log/btmp    "failed logins"
  truncate_file /var/log/lastlog "last login info"; }

restart_logging() {
  command -v systemctl >/dev/null 2>&1 || { log_info "systemd not present — skipping rsyslog restart."; return 0; }
  if systemctl is-active --quiet rsyslog 2>/dev/null; then
    log_step "Restarting rsyslog"
    run $SUDO systemctl restart rsyslog
    log_ok "rsyslog restarted."
  else
    log_info "rsyslog not active — nothing to restart."
  fi; }

clear_known_hosts() {
  [ "$CLEAR_KNOWN_HOSTS" = yes ] || { log_info "CLEAR_KNOWN_HOSTS=no — keeping known_hosts."; return 0; }
  log_step "Clearing SSH known_hosts for '$TARGET_USER'"
  local home; home="$(user_home)"; home="${home:-$HOME}"
  if [ -f "$home/.ssh/known_hosts" ]; then
    run : > "$home/.ssh/known_hosts"
    log_ok "Cleared: $home/.ssh/known_hosts"
  else
    log_info "No known_hosts file found — skipping."
  fi; }

# ----------------------------- MAIN -----------------------------------------
main() {
  log_step "Safe history & login cleaner — start"
  log_info "TARGET_USER=$TARGET_USER  Log=$LOG_FILE"
  require_sudo
  confirm
  clear_shell_history
  clear_login_records
  restart_logging
  clear_known_hosts
  log_step "Summary"
  log_ok "Cleanup complete. History and SSH login records cleared."
  tail_log 5; }

main "$@"
