#!/bin/bash
# ===============================================
# Safe History and SSH Login Cleaner
# ===============================================
# This script clears shell command history,
# SSH login records, and failed login attempts
# without breaking system logging.
# Requires: Bash + sudo privileges
# ===============================================

set -euo pipefail

echo "[*] Clearing current shell history..."
history -c       # Clear in-memory history
history -w       # Write empty history to file

# Determine user's shell history file
HIST_FILE="${HISTFILE:-$HOME/.bash_history}"
if [ -f "$HIST_FILE" ]; then
    > "$HIST_FILE"
    echo "    - Cleared: $HIST_FILE"
fi

# Also check for zsh users
if [ -f "$HOME/.zsh_history" ]; then
    > "$HOME/.zsh_history"
    echo "    - Cleared: $HOME/.zsh_history"
fi

# Prevent further writing to history in current session
unset HISTFILE

echo "[*] Clearing SSH login records..."
sudo truncate -s 0 /var/log/wtmp    && echo "    - Cleared: /var/log/wtmp (login history)"
sudo truncate -s 0 /var/log/btmp    && echo "    - Cleared: /var/log/btmp (failed logins)"
sudo truncate -s 0 /var/log/lastlog && echo "    - Cleared: /var/log/lastlog (last login info)"

echo "[*] Restarting logging service..."
if systemctl is-active --quiet rsyslog; then
    sudo systemctl restart rsyslog
    echo "    - rsyslog restarted."
fi

echo "[*] Clearing SSH known hosts file..."
if [ -f "$HOME/.ssh/known_hosts" ]; then
    > "$HOME/.ssh/known_hosts"
    echo "    - Cleared: $HOME/.ssh/known_hosts"
fi

echo "[✓] Cleanup complete. Your history and SSH login records have been cleared."
