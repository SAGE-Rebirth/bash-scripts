#!/bin/bash

echo "===== Ubuntu Safe Cache Cleaner ====="

# 1. Clear APT cache
echo "[1/4] Clearing APT cache..."
sudo apt clean
sudo apt autoclean
echo "✅ APT cache cleared."

# 2. Remove thumbnail cache
echo "[2/4] Removing thumbnail cache..."
rm -rf ~/.cache/thumbnails/*
echo "✅ Thumbnails cleared."

# 3. Clean journal logs older than 7 days
echo "[3/4] Cleaning system logs older than 7 days..."
sudo journalctl --vacuum-time=7d
echo "✅ Logs cleaned."

# 4. Clear RAM cache (optional)
read -p "Do you want to clear memory (RAM) cache as well? [y/N]: " choice
if [[ "$choice" =~ ^[Yy]$ ]]; then
    echo "Clearing RAM cache..."
    sudo sync
    echo 3 | sudo tee /proc/sys/vm/drop_caches
    echo "✅ RAM cache cleared."
else
    echo "⏩ Skipping RAM cache clear."
fi

echo "===== Cache Cleaning Completed ====="