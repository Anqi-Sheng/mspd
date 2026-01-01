#!/usr/bin/env bash

# --- Configuration ---
BINARY_SRC="mspd.sh"
CONF_SRC="mspd.conf"
INSTALL_BIN="/usr/local/bin/mspd"
INSTALL_CONF="/etc/mspd.conf"
LOG_DIR="/var/log/mspd"

echo "--- Master System Power Dashboard Installer ---"

# 1. Root Check
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root (sudo ./installer.sh)"
  exit 1
fi

# 2. Check for source files
if [ ! -f "$BINARY_SRC" ] || [ ! -f "$CONF_SRC" ]; then
    echo "Error: Missing $BINARY_SRC or $CONF_SRC in current folder."
    exit 1
fi

# 3. Create Log Directory and Fix Permissions
echo "Setting up logs at $LOG_DIR..."
mkdir -p "$LOG_DIR"
# Use 755 for directories (rwxr-xr-x) so they can be 'entered'
chmod 755 "$LOG_DIR"

touch "$LOG_DIR/peaks.log" "$LOG_DIR/benchmarks.log"
# Use 666 for files so the script can write to them regardless of user
chmod 666 "$LOG_DIR/peaks.log" "$LOG_DIR/benchmarks.log"

# 4. Install Binary
echo "Installing binary to $INSTALL_BIN..."
cp "$BINARY_SRC" "$INSTALL_BIN"
chmod +x "$INSTALL_BIN"

# 5. Install Config
if [ -f "$INSTALL_CONF" ]; then
    echo -n "Config already exists at $INSTALL_CONF. Overwrite? (y/n): "
    read ovr
    if [[ "$ovr" == "y" ]]; then
        cp "$CONF_SRC" "$INSTALL_CONF"
        echo "Config overwritten."
    else
        echo "Skipping config install."
    fi
else
    echo "Installing config to $INSTALL_CONF..."
    cp "$CONF_SRC" "$INSTALL_CONF"
fi

# Final Ownership Sync
chown -R root:root "$LOG_DIR"
chmod 755 "$LOG_DIR"

echo "------------------------------------------------"
echo "SUCCESS: Installation Complete."
echo "You can now type 'sudo mspd' from any directory."
echo "Logs are located in: $LOG_DIR"
echo "------------------------------------------------"
