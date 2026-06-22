#!/usr/bin/env bash
# ============================================================================
#  Ubuntu Safe Cache Cleaner
#  Frees disk by clearing apt cache, thumbnails and old journald logs.
# ----------------------------------------------------------------------------
#  Idempotent + safe to re-run. Verbose logging. Detailed errors.
#  Overrides (env vars):
#     CLEAR_RAM=yes|no|ask   drop kernel page cache (default: ask / no in CI)
#     JOURNAL_KEEP=7d        how much journald history to keep   (default 7d)
#     TARGET_USER=<name>     whose ~/.cache to clean    (default: invoking user)
#     LOG_FILE=<path>        where to write the run log (default: /tmp/...)
# ============================================================================
set -Eeuo pipefail

# ----------------------------- CORE LIBRARY ---------------------------------
SCRIPT_NAME="$(basename "${0:-clear-cache.sh}")"
LOG_FILE="${LOG_FILE:-/tmp/${SCRIPT_NAME%.sh}-$(date +%Y%m%d-%H%M%S).log}"
TARGET_USER="${TARGET_USER:-${SUDO_USER:-$(logname 2>/dev/null || id -un)}}"

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

run() {  # run <cmd...> : print it, stream output to console + log, detail errors
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

# ----------------------------- TASKS ----------------------------------------
clean_apt() {
  log_step "Cleaning APT cache & orphaned packages"
  run $SUDO apt-get clean
  run $SUDO apt-get autoclean -y
  run $SUDO apt-get -y --purge autoremove
  log_ok "APT cache and orphaned packages cleared."; }

clean_thumbnails() {
  log_step "Cleaning thumbnail cache for '$TARGET_USER'"
  local home; home="$(getent passwd "$TARGET_USER" | cut -d: -f6)"; home="${home:-$HOME}"
  if [ -d "$home/.cache/thumbnails" ]; then
    run rm -rf "$home/.cache/thumbnails"
    log_ok "Thumbnail cache removed (regenerates on demand)."
  else
    log_info "No thumbnail cache at $home/.cache/thumbnails — skipping."
  fi; }

clean_journal() {
  if ! command -v journalctl >/dev/null 2>&1; then
    log_warn "journalctl not present — skipping journal cleanup."; return 0; fi
  log_step "Vacuuming systemd journal (keeping ${JOURNAL_KEEP:-7d})"
  run $SUDO journalctl --rotate
  run $SUDO journalctl --vacuum-time="${JOURNAL_KEEP:-7d}"
  log_ok "Journald logs vacuumed."; }

clean_ram() {
  log_step "RAM page cache"
  local choice="${CLEAR_RAM:-ask}"
  if [ "$choice" = ask ]; then
    if [ -t 0 ]; then
      read -r -p "Drop kernel page cache too? [y/N]: " a
      [[ "$a" =~ ^[Yy]$ ]] && choice=yes || choice=no
    else
      choice=no
      log_info "Non-interactive shell — skipping RAM cache (set CLEAR_RAM=yes to force)."
    fi
  fi
  if [ "$choice" = yes ]; then
    run $SUDO sync
    run $SUDO sh -c 'echo 3 > /proc/sys/vm/drop_caches'
    log_ok "Kernel page cache dropped."
  else
    log_info "Skipping RAM cache drop."
  fi; }

show_disk() {
  log_step "Disk usage (root filesystem)"
  run df -h / ; }

# ----------------------------- MAIN -----------------------------------------
main() {
  log_step "Ubuntu Safe Cache Cleaner — start"
  log_info "User=$TARGET_USER  Log=$LOG_FILE"
  require_sudo
  show_disk
  clean_apt
  clean_thumbnails
  clean_journal
  clean_ram
  show_disk
  log_step "Summary"
  log_ok "Cache cleaning completed successfully."
  tail_log 5; }

main "$@"
