#!/bin/bash

# PM2 Deployment Script with Verbose Logging and Safe Permission Handling

# Configuration
PROJECT_DIR="/var/lib/jenkins/workspace/git-poll-user-service-job"
APP_ENTRY="src/index.js"
APP_NAME="user-service"
PM2_USER="ubuntu"
PM2_HOME="/home/$PM2_USER"
DEPLOY_USER=$(whoami)

echo "=== Starting Deployment Process ==="

# 1. Fix Directory Permissions
echo "[1/9] [PERMISSIONS] Setting proper directory ownership..."
echo "Command: sudo chown -R $DEPLOY_USER:$DEPLOY_USER $PROJECT_DIR"
sudo chown -R $DEPLOY_USER:$DEPLOY_USER $PROJECT_DIR
echo "Command: sudo chmod -R 755 $PROJECT_DIR"
sudo chmod -R 755 $PROJECT_DIR

# 2. Navigate to project
echo "[2/9] [NAVIGATION] Entering project directory..."
echo "Command: cd $PROJECT_DIR || { echo 'Failed to access project directory!'; exit 1; }"
cd $PROJECT_DIR || { echo "Failed to access project directory!"; exit 1; }

# 3. Clean previous installations (with explanations)
echo "[3/9] [CLEANUP] Preparing fresh installation..."
echo "To prevent conflicts from previous installations"
echo "Command: rm -rf node_modules"
rm -rf node_modules

echo "To ensure clean dependency resolution"
echo "Note: In production, you might want to keep this for consistent installs"
echo "Command: rm -f package-lock.json"
rm -f package-lock.json

# 4. Install dependencies safely
echo "[4/9] [DEPENDENCIES] Installing packages..."
echo "Command: npm install --no-optional --prefix $PROJECT_DIR"
npm install --no-optional --prefix $PROJECT_DIR

# 5. Verify installation
echo "[5/9] [VERIFICATION] Checking installation..."
echo "Command: [ -d 'node_modules' ]"
if [ ! -d "node_modules" ]; then
  echo "Error: node_modules not created! Checking permissions..."
  ls -la
  exit 1
fi

# 6. PM2 Process Management
echo "[6/9] [PROCESS] Managing application state..."
echo "Checking if $APP_NAME is already running..."
echo "Command: pm2 describe $APP_NAME >/dev/null 2>&1"
if pm2 describe $APP_NAME >/dev/null 2>&1; then
  echo "Reloading existing application with zero downtime..."
  echo "Command: pm2 reload $APP_NAME --update-env"
  pm2 reload $APP_NAME --update-env
else
  echo "Starting new application instance..."
  echo "Command: pm2 start $APP_ENTRY --name $APP_NAME"
  pm2 start $APP_ENTRY --name $APP_NAME
fi

# 7. Save process list
echo "[7/9] [PERSISTENCE] Saving process state..."
echo "Command: pm2 save"
pm2 save

# 8. Configure startup
echo "[8/9] [STARTUP] Setting up PM2 startup..."
echo "This ensures your app survives server reboots"
echo "Command: sudo env PATH=$PATH:/usr/bin /usr/lib/node_modules/pm2/bin/pm2 startup systemd -u $PM2_USER --hp $PM2_HOME"
sudo env PATH=$PATH:/usr/bin /usr/lib/node_modules/pm2/bin/pm2 startup systemd -u $PM2_USER --hp $PM2_HOME

# 9. Final verification
echo "[9/9] [COMPLETION] Deployment complete! Final status:"
echo "Command: pm2 list"
pm2 list

echo "=== Deployment Process Completed ==="