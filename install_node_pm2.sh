#!/bin/bash

# Node.js and PM2 Installation Script

echo "Starting Node.js and PM2 installation..."

# Update system packages
echo "[1/6] Updating system packages..."
sudo apt update

# Install curl and software-properties-common if not already installed
echo "[2/6] Installing required dependencies..."
sudo apt install -y curl software-properties-common

# Install Node.js LTS version
echo "[3/6] Installing Node.js LTS version..."
curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
sudo apt install -y nodejs

# Verify Node.js and npm installation
echo "[4/6] Verifying installations..."
echo "Node.js version: $(node -v)"
echo "npm version: $(npm -v)"

# Install PM2 globally
echo "[5/6] Installing PM2 process manager..."
sudo npm install -g pm2

# Verify PM2 installation
echo "[6/6] PM2 version: $(pm2 --version)"

echo "Node.js and PM2 installation completed successfully!"