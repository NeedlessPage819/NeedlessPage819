#!/bin/bash
# ZeroPassThrough Installer Script
# This script automates the setup of ZeroPassThrough on a Raspberry Pi Zero

# Exit immediately if a command exits with a non-zero status.
set -e

echo "=== ZeroPassThrough Installer ==="
echo "This script will set up your Raspberry Pi Zero as a USB HID passthrough device."

# Ensure the script is executed as root
if [ "$(id -u)" -ne 0 ]; then
    echo "Error: This script must be run as root. Try 'sudo bash $0'" >&2
    exit 1
fi

# Confirm before proceeding
read -p "This will configure your Raspberry Pi Zero for USB HID passthrough. Continue? (y/n) " -n 1 -r
echo
if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
    echo "Installation cancelled."
    exit 0
fi

echo "Installing required packages..."
apt-get update
apt-get install -y python3-pip python3-dev git

echo "Setting up USB gadget mode..."
# Enable dwc2 module in /boot/config.txt if not already enabled
if ! grep -q "dtoverlay=dwc2" /boot/config.txt; then
    echo "dtoverlay=dwc2" >> /boot/config.txt
fi

# Append necessary modules to /etc/modules if they do not already exist
if ! grep -q "dwc2" /etc/modules; then
    echo "dwc2" >> /etc/modules
fi

if ! grep -q "libcomposite" /etc/modules; then
    echo "libcomposite" >> /etc/modules
fi

echo "Creating USB gadget setup script at /usr/bin/zeropass-setup.sh..."
cat > /usr/bin/zeropass-setup.sh << 'EOF'
#!/bin/bash
# Ensure configfs is mounted
if [ ! -d /sys/kernel/config/usb_gadget ]; then
    mount -t configfs none /sys/kernel/config
fi

cd /sys/kernel/config/usb_gadget/
mkdir -p zeropassthrough
cd zeropassthrough

# USB device identifiers
echo 0x1d6b > idVendor       # Linux Foundation
echo 0x0104 > idProduct      # Multifunction Composite Gadget
echo 0x0100 > bcdDevice      # v1.0.0
echo 0x0200 > bcdUSB         # USB2

# Device strings
mkdir -p strings/0x409
echo "fedcba9876543210" > strings/0x409/serialnumber
echo "ZeroPassThrough" > strings/0x409/manufacturer
echo "Mouse Passthrough" > strings/0x409/product

# Configuration
mkdir -p configs/c.1/strings/0x409
echo "Config 1: Mouse" > configs/c.1/strings/0x409/configuration
echo 250 > configs/c.1/MaxPower

# Create HID function
mkdir -p functions/hid.usb0
echo 1 > functions/hid.usb0/protocol
echo 1 > functions/hid.usb0/subclass
echo 8 > functions/hid.usb0/report_length

# Mouse HID descriptor: 3-button mouse with X and Y movement
echo -ne "\x05\x01\x09\x02\xa1\x01\x09\x01\xa1\x00\x05\x09\x19\x01\x29\x05\x15\x00\x25\x01\x95\x05\x75\x01\x81\x02\x95\x01\x75\x03\x81\x01\x05\x01\x09\x30\x09\x31\x15\x81\x25\x7f\x75\x08\x95\x02\x81\x06\xc0\xc0" > functions/hid.usb0/report_desc

# Link the HID function to the configuration
ln -sf functions/hid.usb0 configs/c.1/

# Enable the gadget by binding to UDC
UDC=$(ls /sys/class/udc | head -n 1)
if [ -n "$UDC" ]; then
    echo "$UDC" > UDC
    echo "USB gadget enabled with UDC: $UDC"
else
    echo "ERROR: No UDC driver found. USB gadget not enabled."
    exit 1
fi
EOF

# Make the gadget setup script executable
chmod +x /usr/bin/zeropass-setup.sh

echo "Creating Python service script at /usr/bin/zeropass-mouse.py..."
cat > /usr/bin/zeropass-mouse.py << 'EOF'
#!/usr/bin/env python3
import struct
import time
import os
import sys

# Verify write access for the HID device file
if not os.access('/dev/hidg0', os.W_OK):
    print("Error: Cannot access /dev/hidg0. Make sure this script runs as root.")
    sys.exit(1)

def write_report(report):
    try:
        with open('/dev/hidg0', 'wb+') as fd:
            fd.write(report)
    except Exception as e:
        print(f"Error writing to HID device: {e}")

def main():
    print("ZeroPassThrough service started")
    # Wait a moment for the USB gadget to initialize
    time.sleep(2)
    
    # Send an 8-byte report (all zeros) to indicate that the service is running.
    # Adjust this report as needed to simulate mouse movements/buttons.
    try:
        report = struct.pack('8B', 0, 0, 0, 0, 0, 0, 0, 0)
        write_report(report)
    except Exception as e:
        print(f"Error sending report: {e}")
    
if __name__ == "__main__":
    main()
EOF

# Make the Python script executable
chmod +x /usr/bin/zeropass-mouse.py

echo "Creating systemd service unit file at /etc/systemd/system/zeropassthrough.service..."
cat > /etc/systemd/system/zeropassthrough.service << 'EOF'
[Unit]
Description=ZeroPassThrough Mouse Service
After=network.target
After=systemd-user-sessions.service
After=network-online.target

[Service]
Type=simple
ExecStartPre=/usr/bin/zeropass-setup.sh
ExecStart=/usr/bin/zeropass-mouse.py
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# Set proper permissions for the systemd service file
chmod 644 /etc/systemd/system/zeropassthrough.service

echo "Enabling service to start on boot..."
systemctl enable zeropassthrough.service

echo "Starting service..."
systemctl start zeropassthrough.service
systemctl status zeropassthrough.service --no-pager

echo "====================================="
echo "ZeroPassThrough installation complete!"
echo "Your Raspberry Pi Zero is now configured as a USB HID device."
echo "After rebooting, connect your Pi Zero to a computer via the USB DATA port (not PWR)."
echo "The Pi should appear as a mouse device."
echo "======================================"
echo "To check service status: sudo systemctl status zeropassthrough"
echo "To view logs: sudo journalctl -u zeropassthrough"
echo "======================================"
