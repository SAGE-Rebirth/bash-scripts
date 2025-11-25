#!/bin/bash
set -euo pipefail

echo ">>> Installing Docker..."

# Remove old versions if any (safe)
sudo apt-get remove -y docker docker-engine docker.io containerd runc || true

# Install prerequisites
sudo apt-get update -y
sudo apt-get install -y ca-certificates curl gnupg apt-transport-https lsb-release

# Create keyrings dir (idempotent)
sudo install -m 0755 -d /etc/apt/keyrings

# Fetch Docker GPG key and dearmor non-interactively (no overwrite prompt)
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
  sudo gpg --batch --yes --dearmor -o /etc/apt/keyrings/docker.gpg

# Add Docker repository
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo $VERSION_CODENAME) stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# Install Docker Engine and plugins
sudo apt-get update -y
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Ensure docker group exists (Docker package often creates it, but be safe)
if ! getent group docker >/dev/null; then
  sudo groupadd docker
fi

# Add ubuntu user to docker group so ubuntu can run docker without sudo
sudo usermod -aG docker ubuntu

# Optional: set passwordless sudo for ubuntu (only if you actually want it)
if [ ! -f /etc/sudoers.d/ubuntu ]; then
  echo "ubuntu ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/ubuntu > /dev/null
  sudo chmod 440 /etc/sudoers.d/ubuntu
fi

echo ">>> Docker install + ubuntu group update complete."
echo ">>> To apply group changes now: either log out/log back in, or run: newgrp docker"
