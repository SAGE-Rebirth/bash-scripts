#!/bin/bash

# Script: jmeter-ec2-setup.sh (improved with Java cleanup + install OpenJDK 17+)
# Run as root (sudo).

set -e

JMETER_VERSION="5.6.3"
JMETER_DIR="/opt/jmeter"
JMETER_USER="ubuntu"  # Adjust if you SSH as a different user
DOWNLOAD_URL="https://dlcdn.apache.org//jmeter/binaries/apache-jmeter-${JMETER_VERSION}.tgz"

echo "Starting JMeter setup with Java cleanup and OpenJDK 17+ install..."

# -- 1. Update system repositories --
apt update
apt upgrade -y

# -- 2. Remove older Java versions (if any) --

echo "Removing older Java versions..."

# List installed openjdk packages (if any)
JAVA_PACKAGES=$(dpkg -l | grep -E 'openjdk-[0-9]+-jdk' | awk '{print $2}' || true)

if [ -n "$JAVA_PACKAGES" ]; then
    echo "Found Java packages: $JAVA_PACKAGES"
    apt remove -y $JAVA_PACKAGES
    apt autoremove -y
else
    echo "No OpenJDK versions found to remove."
fi

# Also remove any possible Oracle Java or alternative java installations if needed:
dpkg -l | grep -E 'oracle-java|java-common' && echo "Removing additional possible Java packages..." && apt purge -y oracle-java* java-common || true

# -- 3. Install OpenJDK 17 --
echo "Installing OpenJDK 17..."
apt install -y openjdk-17-jdk

echo "Java version after install:"
java -version

# -- 4. Download and extract JMeter setup (only if not already done) --
if [ ! -d "$JMETER_DIR" ]; then
    echo "Downloading Apache JMeter ${JMETER_VERSION}..."
    wget -O /tmp/apache-jmeter.tgz $DOWNLOAD_URL
    tar -xvzf /tmp/apache-jmeter.tgz -C /opt
    mv /opt/apache-jmeter-${JMETER_VERSION} $JMETER_DIR
    chown -R $JMETER_USER:$JMETER_USER $JMETER_DIR
else
    echo "JMeter directory already exists, skipping download."
fi

# -- 5. Add JMeter to system PATH (if missing) --
if ! grep -q 'JMETER_HOME' /etc/profile; then
    echo "Configuring environment variables for JMeter..."
    echo "export JMETER_HOME=$JMETER_DIR" >> /etc/profile
    echo 'export PATH=$PATH:$JMETER_HOME/bin' >> /etc/profile
fi
export JMETER_HOME=$JMETER_DIR
export PATH=$PATH:$JMETER_HOME/bin

# -- 6. JVM Heap tuning for JMeter (adapt to RAM) --
RAM_MB=$(grep MemTotal /proc/meminfo | awk '{print $2/1024}')
MIN_HEAP=$(printf "%.0f" "$(echo "${RAM_MB}/4" | bc)")
MAX_HEAP=$(printf "%.0f" "$(echo "${RAM_MB}/2" | bc)")

JMETER_PROP="$JMETER_DIR/bin/jmeter"
JMETER_SERVER_PROP="$JMETER_DIR/bin/jmeter-server"

for P in "$JMETER_PROP" "$JMETER_SERVER_PROP"; do
    sed -i '/^-Xms/s/-Xms[0-9]*/-Xms'${MIN_HEAP}'m/' $P
    sed -i '/^-Xmx/s/-Xmx[0-9]*/-Xmx'${MAX_HEAP}'m/' $P
done

# -- 7. Set high ulimits for files/processes --
cat <<EOT > /etc/security/limits.d/jmeter.conf
$JMETER_USER soft nofile 65536
$JMETER_USER hard nofile 65536
$JMETER_USER soft nproc 65536
$JMETER_USER hard nproc 65536
EOT

if ! grep -q 'ulimit -n 65536' /home/$JMETER_USER/.bashrc; then
    echo 'ulimit -n 65536' >> /home/$JMETER_USER/.bashrc
fi

# -- 8. Enable NTP for time sync --
apt install -y chrony
systemctl enable chrony --now

# -- 9. Correct ownership --
chown -R $JMETER_USER:$JMETER_USER $JMETER_DIR

# -- 10. JMeter directory symlink for user convenience --
if [ ! -e "/home/$JMETER_USER/jmeter" ]; then
    ln -s $JMETER_DIR /home/$JMETER_USER/jmeter
    chown -h $JMETER_USER:$JMETER_USER /home/$JMETER_USER/jmeter
fi

# -- 11. Final instructions --
cat <<EOM

Setup complete!

- Apache JMeter ${JMETER_VERSION} installed at: $JMETER_DIR
- OpenJDK 17 installed and active.
- JVM heap settings applied based on system RAM: -Xms${MIN_HEAP}m -Xmx${MAX_HEAP}m
- File descriptor limits (ulimit) set high for the JMeter user ($JMETER_USER).
- NTP time synchronization enabled.

To start using JMeter:

1. Log out and back in, or source the profile:
   source /etc/profile

2. Run in non-GUI mode:
   jmeter -n -t /path/to/your/testplan.jmx -l results.jtl

3. For distributed testing, configure security groups and properties as needed.

Happy load testing!

EOM

exit 0
