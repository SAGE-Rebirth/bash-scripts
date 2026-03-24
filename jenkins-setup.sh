#!/bin/bash

set -e

echo ">>> [JENKINS INSTALLER] Starting installation on Ubuntu..."

# Variables
JENKINS_USER=${JENKINS_USER:-jenkins}
JAVA_PACKAGE="openjdk-17-jdk"  # Updated to Java 17

# Ensure script runs on Ubuntu
if ! grep -iq "ID=ubuntu" /etc/os-release; then
    echo "❌ This script is intended for Ubuntu systems only."
    exit 1
fi

# Clean all old Jenkins repo entries and GPG keys to prevent conflicts
sudo rm -f /etc/apt/sources.list.d/jenkins*.list
sudo rm -f /etc/apt/sources.list.d/jenkins*.sources
sudo rm -f /usr/share/keyrings/jenkins*.asc /usr/share/keyrings/jenkins*.gpg
sudo rm -f /etc/apt/trusted.gpg.d/jenkins*.gpg /etc/apt/trusted.gpg.d/jenkins*.asc
sudo apt-key del "$(apt-key list 2>/dev/null | grep -B1 -i jenkins | head -1 | awk '{print $NF}')" 2>/dev/null || true
# Remove Jenkins entries from /etc/apt/sources.list if present
sudo sed -i '/pkg\.jenkins\.io/d' /etc/apt/sources.list 2>/dev/null || true

# Update and install prerequisites
echo ">>> Updating system and installing required tools..."
sudo apt-get update -y
sudo apt-get install -y git curl wget gnupg2 software-properties-common ufw apt-transport-https

# Remove old Java versions (if any)
echo ">>> Removing old Java versions (if present)..."
sudo apt-get remove --purge -y openjdk-11-* ^default-jre ^default-jdk || true
sudo apt-get autoremove -y

# Install Java 17 (LTS)
echo ">>> Installing OpenJDK 17 (LTS)..."
sudo apt-get install -y "$JAVA_PACKAGE"

# Set Java 17 as default
echo ">>> Setting Java 17 as default..."
sudo update-alternatives --set java /usr/lib/jvm/java-17-openjdk-amd64/bin/java
sudo update-alternatives --set javac /usr/lib/jvm/java-17-openjdk-amd64/bin/javac

# Verify Java version
echo ">>> Java version:"
java -version

# Install Jenkins via direct .deb download (no GPG key or repo needed)
echo ">>> Downloading and installing Jenkins directly..."
JENKINS_DEB="/tmp/jenkins.deb"

# Fetch the latest stable Jenkins .deb filename from the download mirror
JENKINS_DEB_URL=$(curl -fsSL "https://get.jenkins.io/debian-stable/" \
  | grep -oP 'href="\Kjenkins_[0-9]+\.[0-9]+\.[0-9]+_all\.deb' \
  | sort -V | tail -1)

if [ -z "$JENKINS_DEB_URL" ]; then
    echo "❌ Could not determine latest Jenkins .deb URL. Falling back to known version."
    JENKINS_DEB_URL="jenkins_2.541.3_all.deb"
fi

echo ">>> Downloading: https://get.jenkins.io/debian-stable/${JENKINS_DEB_URL}"
curl -fSL "https://get.jenkins.io/debian-stable/${JENKINS_DEB_URL}" -o "$JENKINS_DEB"

sudo dpkg -i "$JENKINS_DEB" || sudo apt-get install -f -y
rm -f "$JENKINS_DEB"

# Configure Jenkins to use Java 17
echo ">>> Setting JAVA_HOME in /etc/default/jenkins..."
if ! grep -q "JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64" /etc/default/jenkins; then
    echo "JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64" | sudo tee -a /etc/default/jenkins > /dev/null
fi

# Ensure the Jenkins user exists
if id "$JENKINS_USER" &>/dev/null; then
    echo ">>> User '$JENKINS_USER' already exists."
else
    echo ">>> Creating user '$JENKINS_USER'..."
    sudo useradd -m -s /bin/bash "$JENKINS_USER"
fi

# Add to sudo group (passwordless)
echo ">>> Adding '$JENKINS_USER' to sudo group..."
sudo usermod -aG sudo "$JENKINS_USER"
echo "$JENKINS_USER ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/"$JENKINS_USER" > /dev/null
sudo chmod 777 /etc/sudoers.d/"$JENKINS_USER"

# Add Jenkins user to docker group
echo ">>> Adding '$JENKINS_USER' to docker group..."
sudo usermod -aG docker "$JENKINS_USER" || true

# Enable Jenkins on boot and start
echo ">>> Enabling and starting Jenkins..."
sudo systemctl daemon-reload
sudo systemctl enable jenkins
sudo systemctl restart jenkins

# Verify Jenkins is running
echo ">>> Checking Jenkins status..."
if systemctl is-active --quiet jenkins; then
    echo "✅ Jenkins is running!"
else
    echo "❌ Jenkins failed to start. Check logs:"
    sudo journalctl -u jenkins -n 20 --no-pager
    exit 1
fi

# Configure firewall
echo ">>> Configuring UFW firewall..."
sudo ufw allow ssh
sudo ufw allow 8080/tcp
sudo ufw --force enable

# Display Jenkins admin password
JENKINS_PASS_FILE="/var/lib/jenkins/secrets/initialAdminPassword"
echo ">>> Waiting for Jenkins initial password (max 30s)..."
for i in {1..30}; do
    if [ -f "$JENKINS_PASS_FILE" ]; then
        break
    fi
    sleep 1
done

if [ -f "$JENKINS_PASS_FILE" ]; then
    echo ">>> Jenkins Initial Admin Password:"
    sudo cat "$JENKINS_PASS_FILE"
else
    echo ">>> Jenkins is still initializing. Retrieve password later with:"
    echo "     sudo cat $JENKINS_PASS_FILE"
fi

# Success
echo -e "\n✅ Jenkins installation completed successfully!"
echo "👉 Access Jenkins: http://$(curl -s ifconfig.me):8080"
echo "⚠️  Ensure your EC2 Security Group allows TCP 8080 inbound!"
