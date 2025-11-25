#!/bin/bash
# ======================================================
# GitHub CLI Installer for Ubuntu
# ======================================================
# Installs the official GitHub CLI (gh) from GitHub's repo
# ======================================================

set -euo pipefail

echo "[*] Updating package list..."
sudo apt update -y

echo "[*] Installing prerequisites..."
sudo apt install -y curl

echo "[*] Adding GitHub CLI GPG key..."
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | \
sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
sudo chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg

echo "[*] Adding GitHub CLI repository..."
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] \
https://cli.github.com/packages stable main" | \
sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null

echo "[*] Updating package list again..."
sudo apt update -y

echo "[*] Installing GitHub CLI..."
sudo apt install -y gh

echo "[✓] Installation complete!"
gh --version
