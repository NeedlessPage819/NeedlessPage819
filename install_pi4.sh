#!/bin/bash
# ZeroPassThrough Installer Script for Raspberry Pi 4
# This script automates the setup of ZeroPassThrough on a Raspberry Pi 4

# Exit on error
set -e

echo "=== ZeroPassThrough Installer for Raspberry Pi 4 ==="
echo "This script will set up your Raspberry Pi 4 as a USB HID passthrough device."

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    echo "Error: This script must be run as root. Try 'sudo bash $0'" >&2
    exit 1
fi

# Confirm before proceeding
read -p "This will configure your Raspberry Pi 4 for USB HID passthrough. Continue? (y/n) " -n 1 -r
echo
if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
    echo "Installation cancelled."
    exit 0
fi

echo "Installing required packages..."
apt-get update
apt-get install -y python3-pip python3-dev git build-essential libudev-dev

echo "Setting up USB gadget mode..."
# Enable dwc3 module for Pi 4
if ! grep -q "dtoverlay=dwc3" /boot/config.txt; then
    echo "dtoverlay=dwc3" >> /boot/config.txt
fi

# Add modules to /etc/modules
if ! grep -q "dwc3" /etc/modules; then
    echo "dwc3" >> /etc/modules
fi

if ! grep -q "libcomposite" /etc/modules; then
    echo "libcomposite" >> /etc/modules
fi

# Create HID setup script
cat > /usr/bin/zeropass-setup.sh << 'EOF'
#!/bin/bash
# Make sure configfs is mounted
if [ ! -d /sys/kernel/config/usb_gadget ]; then
    mount -t configfs none /sys/kernel/config
fi

cd /sys/kernel/config/usb_gadget/
mkdir -p zeropassthrough
cd zeropassthrough

# USB device identifiers
echo 0x1d6b > idVendor # Linux Foundation
echo 0x0104 > idProduct # Multifunction Composite Gadget
echo 0x0100 > bcdDevice # v1.0.0
echo 0x0200 > bcdUSB # USB2

# Device information
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
echo -ne \\x05\\x01\\x09\\x02\\xa1\\x01\\x09\\x01\\xa1\\x00\\x05\\x09\\x19\\x01\\x29\\x05\\x15\\x00\\x25\\x01\\x95\\x05\\x75\\x01\\x81\\x02\\x95\\x01\\x75\\x03\\x81\\x01\\x05\\x01\\x09\\x30\\x09\\x31\\x15\\x81\\x25\\x7f\\x75\\x08\\x95\\x02\\x81\\x06\\xc0\\xc0 > functions/hid.usb0/report_desc

# Link the HID function to the configuration
ln -sf functions/hid.usb0 configs/c.1/

# Enable the gadget by binding to UDC
# Find first UDC driver (should be "fe980000.usb" on Pi 4)
UDC=$(ls /sys/class/udc | head -n 1)
if [ ! -z "$UDC" ]; then
    echo "$UDC" > UDC
    echo "USB gadget enabled with UDC: $UDC"
else
    echo "ERROR: No UDC driver found. USB gadget not enabled."
    exit 1
fi
EOF

chmod +x /usr/bin/zeropass-setup.sh

# Create the mouse passthrough service
echo "Creating main service..."
cat > /usr/bin/zeropass-mouse.py << 'EOF'
#!/usr/bin/env python3
import struct
import time
import os
import sys
import evdev
from evdev import ecodes

# Check for permissions
if not os.access('/dev/hidg0', os.W_OK):
    print("Error: Cannot access /dev/hidg0. Make sure this script runs as root.")
    sys.exit(1)

def write_report(report):
    try:
        with open('/dev/hidg0', 'wb+') as fd:
            fd.write(report)
    except Exception as e:
        print(f"Error writing to HID device: {e}")

def find_mouse():
    devices = [evdev.InputDevice(path) for path in evdev.list_devices()]
    for device in devices:
        if ecodes.EV_REL in device.capabilities():
            return device.path
    return None

def main():
    print("ZeroPassThrough service started")
    # Wait a moment for the USB gadget to initialize
    time.sleep(2)
    
    # Find mouse device
    mouse_path = find_mouse()
    if not mouse_path:
        print("Error: No mouse device found")
        sys.exit(1)
    
    print(f"Found mouse at {mouse_path}")
    mouse = evdev.InputDevice(mouse_path)
    
    # Attempt to move mouse slightly to indicate service is running
    try:
        # Button mask (5 bits) + padding (3 bits) + X + Y
        write_report(struct.pack('<BBB', 0, 5, 0))  # Move right 5 pixels
        time.sleep(0.1)
        write_report(struct.pack('<BBB', 0, -5, 0))  # Move left 5 pixels
        time.sleep(0.1)
        write_report(struct.pack('<BBB', 0, 0, 0))   # Stop movement
        print("Movement test successful")
    except Exception as e:
        print(f"Movement test failed: {e}")
    
    print("ZeroPassThrough initialized. Waiting for input...")
    
    # Main event loop
    button_state = 0
    for event in mouse.read_loop():
        if event.type == ecodes.EV_REL:
            if event.code == ecodes.REL_X:
                write_report(struct.pack('<BBB', button_state, event.value, 0))
            elif event.code == ecodes.REL_Y:
                write_report(struct.pack('<BBB', button_state, 0, event.value))
        elif event.type == ecodes.EV_KEY:
            if event.code in [ecodes.BTN_LEFT, ecodes.BTN_RIGHT, ecodes.BTN_MIDDLE]:
                if event.code == ecodes.BTN_LEFT:
                    if event.value == 1:
                        button_state |= 1
                    else:
                        button_state &= ~1
                elif event.code == ecodes.BTN_RIGHT:
                    if event.value == 1:
                        button_state |= 2
                    else:
                        button_state &= ~2
                elif event.code == ecodes.BTN_MIDDLE:
                    if event.value == 1:
                        button_state |= 4
                    else:
                        button_state &= ~4
                write_report(struct.pack('<BBB', button_state, 0, 0))

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("Service stopped by user")
    except Exception as e:
        print(f"Service error: {e}")
        sys.exit(1)
EOF

chmod +x /usr/bin/zeropass-mouse.py

# Create systemd service
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

# Set proper permissions
chmod 644 /etc/systemd/system/zeropassthrough.service

# Enable and start the service
echo "Enabling service to start on boot..."
systemctl enable zeropassthrough.service

echo "Starting service..."
systemctl start zeropassthrough.service
systemctl status zeropassthrough.service --no-pager

echo "====================================="
echo "ZeroPassThrough installation complete!"
echo "Your Raspberry Pi 4 is now configured as a USB HID device."
echo "After rebooting, connect your Pi 4 to a computer via USB."
echo "The Pi should appear as a mouse device."
echo "======================================"
echo "To check service status: sudo systemctl status zeropassthrough"
echo "To view logs: sudo journalctl -u zeropassthrough"
echo "======================================" 