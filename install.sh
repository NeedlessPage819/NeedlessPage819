#!/bin/bash
# ZeroPassThrough - Automated Setup Script
# This script configures a Raspberry Pi Zero as a USB HID mouse passthrough device

# Exit on error
set -e

echo "===== ZeroPassThrough Automated Setup ====="
echo "This script will configure your Raspberry Pi Zero for USB mouse passthrough."
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then
  echo "Error: This script must be run as root (sudo)."
  exit 1
fi

# Check if this is a Raspberry Pi
if ! grep -q "Raspberry Pi" /proc/device-tree/model 2>/dev/null; then
  echo "Warning: This doesn't appear to be a Raspberry Pi. Continue anyway? (y/n)"
  read -r response
  if [[ ! "$response" =~ ^[Yy]$ ]]; then
    echo "Setup aborted."
    exit 1
  fi
fi

echo "[1/5] Configuring USB gadget mode..."

# Configure config.txt for USB OTG
if ! grep -q "dtoverlay=dwc2" /boot/config.txt; then
  echo "dtoverlay=dwc2" >> /boot/config.txt
  echo "  - Added dtoverlay=dwc2 to config.txt"
else
  echo "  - dtoverlay=dwc2 already in config.txt"
fi

# Configure cmdline.txt for USB modules
if ! grep -q "modules-load=dwc2,g_hid" /boot/cmdline.txt; then
  sed -i 's/rootwait/rootwait modules-load=dwc2,g_hid/' /boot/cmdline.txt
  echo "  - Added modules-load=dwc2,g_hid to cmdline.txt"
else
  echo "  - modules-load already in cmdline.txt"
fi

echo "[2/5] Installing required packages..."
apt update
apt install -y python3-pip python3-dev git
pip3 install evdev

echo "[3/5] Creating HID gadget setup script..."
# Create HID setup script
cat > /usr/local/bin/hid_setup.sh << 'EOF'
#!/bin/bash

cd /sys/kernel/config/usb_gadget/
mkdir -p hidg && cd hidg

echo 0x1d6b > idVendor    # Linux Foundation
echo 0x0104 > idProduct   # Mouse device

mkdir -p strings/0x409
echo "ZeroPassThrough" > strings/0x409/serialnumber
echo "Raspberry Pi" > strings/0x409/manufacturer
echo "Pi Zero HID Mouse" > strings/0x409/product

mkdir -p configs/c.1
mkdir -p configs/c.1/strings/0x409
echo "HID Mouse Configuration" > configs/c.1/strings/0x409/configuration

mkdir -p functions/hid.usb0
echo 1 > functions/hid.usb0/protocol
echo 2 > functions/hid.usb0/subclass
echo -ne \
  "\x05\x01\x09\x02\xa1\x01\x09\x01\xa1\x00\x05\x09\x19\x01\x29\x03\x15\x00\x25\x01\x95\x03\x75\x01\x81\x02"\
  "\x95\x01\x75\x05\x81\x03\x05\x01\x09\x30\x09\x31\x09\x38\x15\x81\x25\x7f\x75\x08\x95\x03\x81\x06\xc0\xc0" \
  > functions/hid.usb0/report_desc
echo 8 > functions/hid.usb0/report_length

ln -s functions/hid.usb0 configs/c.1/

ls /sys/class/udc > UDC
EOF

chmod +x /usr/local/bin/hid_setup.sh

echo "[4/5] Creating mouse passthrough Python script..."
# Create mouse passthrough Python script
cat > /usr/local/bin/mouse_passthrough.py << 'EOF'
#!/usr/bin/env python3
"""
ZeroPassThrough - USB Mouse Input Passthrough
This script captures USB mouse input and passes it to the USB HID gadget.
"""

import os
import sys
import time
import struct
import threading
import socket
from evdev import InputDevice, ecodes, list_devices

# Configuration options - modify as needed
CONFIG = {
    'invert_y': False,       # Invert Y-axis movement
    'sensitivity': 1.0,      # Movement sensitivity multiplier
    'debug_mode': False,     # Enable detailed debug output
    'smooth_scroll': True,   # Enable scroll wheel smoothing
    'scroll_divider': 2,     # Reduce scroll sensitivity
    'socket_enabled': True,  # Enable socket server for remote control
    'socket_host': '0.0.0.0',# Listen on all interfaces
    'socket_port': 8888,     # UDP port for receiving commands
}

class MousePassthrough:
    def __init__(self):
        self.mouse_input = None
        self.hid_output = None
        self.running = True
        self.report = [0, 0, 0, 0]  # [buttons, x, y, wheel]
        self.socket = None
        self.prev_time = time.time()
        self.debug_print(f"ZeroPassThrough starting with config: {CONFIG}")
        
    def find_mouse(self):
        """Find the first connected mouse device."""
        devices = [InputDevice(path) for path in list_devices()]
        for device in devices:
            # Check if this device has mouse-like capabilities
            if ecodes.EV_REL in device.capabilities() and ecodes.REL_X in device.capabilities()[ecodes.EV_REL]:
                self.debug_print(f"Found mouse device: {device.name} at {device.path}")
                return device.path
        return None
    
    def open_devices(self):
        """Open input mouse device and HID gadget output."""
        mouse_path = self.find_mouse()
        if not mouse_path:
            print("No mouse device found. Please connect a USB mouse.")
            return False
        
        try:
            self.mouse_input = InputDevice(mouse_path)
            self.hid_output = open('/dev/hidg0', 'wb+')
            return True
        except PermissionError:
            print("Permission denied accessing devices. Try running with sudo.")
            return False
        except FileNotFoundError:
            print("HID gadget device not found. Check if USB gadget mode is configured.")
            return False
        except Exception as e:
            print(f"Error opening devices: {e}")
            return False
    
    def setup_socket(self):
        """Set up UDP socket for remote control if enabled."""
        if CONFIG['socket_enabled']:
            try:
                self.socket = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
                self.socket.bind((CONFIG['socket_host'], CONFIG['socket_port']))
                self.socket.setblocking(False)
                self.debug_print(f"UDP socket listening on {CONFIG['socket_host']}:{CONFIG['socket_port']}")
                return True
            except Exception as e:
                print(f"Error setting up socket: {e}")
                CONFIG['socket_enabled'] = False
                return False
        return False
    
    def send_report(self):
        """Send HID report to the gadget device."""
        try:
            self.hid_output.write(struct.pack('BBBB', *self.report))
            self.hid_output.flush()
        except Exception as e:
            print(f"Error sending HID report: {e}")
    
    def reset_report(self):
        """Reset report values except buttons."""
        self.report[1] = 0  # x
        self.report[2] = 0  # y
        self.report[3] = 0  # wheel
    
    def debug_print(self, message):
        """Print debug message if debug mode is enabled."""
        if CONFIG['debug_mode']:
            print(f"DEBUG: {message}")
    
    def handle_socket_commands(self):
        """Check for and process remote commands from socket."""
        if not CONFIG['socket_enabled'] or not self.socket:
            return
        
        try:
            while True:
                try:
                    data, addr = self.socket.recvfrom(1024)
                    command = data.decode('utf-8').strip()
                    self.debug_print(f"Received command: {command} from {addr}")
                    self.process_command(command)
                except BlockingIOError:
                    # No more data to read
                    break
                except Exception as e:
                    self.debug_print(f"Socket error: {e}")
                    break
        except Exception as e:
            self.debug_print(f"Error in socket handling: {e}")
    
    def process_command(self, command):
        """Process remote control commands."""
        try:
            if command.startswith('click'):
                parts = command.split(' ')
                button = int(parts[1]) if len(parts) > 1 else 1
                duration = float(parts[2]) if len(parts) > 2 else 0.1
                
                # Set button
                self.report[0] |= button
                self.send_report()
                
                # Schedule release after duration
                threading.Timer(duration, self.release_button, args=[button]).start()
            
            elif command.startswith('move'):
                parts = command.split(' ')
                if len(parts) >= 3:
                    x = int(parts[1])
                    y = int(parts[2])
                    self.report[1] = max(-127, min(127, x))
                    self.report[2] = max(-127, min(127, y))
                    self.send_report()
                    self.reset_report()
            
            elif command.startswith('scroll'):
                parts = command.split(' ')
                if len(parts) >= 2:
                    amount = int(parts[1])
                    self.report[3] = max(-127, min(127, amount))
                    self.send_report()
                    self.reset_report()
            
            elif command == 'stop':
                self.running = False
        
        except Exception as e:
            self.debug_print(f"Error processing command: {e}")
    
    def release_button(self, button):
        """Release a previously clicked button."""
        self.report[0] &= ~button
        self.send_report()
    
    def process_events(self):
        """Process mouse input events and update HID reports."""
        for event in self.mouse_input.read():
            if event.type == ecodes.EV_KEY:
                # Mouse button event
                button_bit = 0
                if event.code == ecodes.BTN_LEFT:
                    button_bit = 1
                elif event.code == ecodes.BTN_RIGHT:
                    button_bit = 2
                elif event.code == ecodes.BTN_MIDDLE:
                    button_bit = 4
                
                if event.value:  # Button pressed
                    self.report[0] |= button_bit
                else:  # Button released
                    self.report[0] &= ~button_bit
                
                self.send_report()
            
            elif event.type == ecodes.EV_REL:
                # Mouse movement or scroll
                if event.code == ecodes.REL_X:
                    sensitivity = CONFIG['sensitivity']
                    value = max(-127, min(127, int(event.value * sensitivity)))
                    self.report[1] = value
                
                elif event.code == ecodes.REL_Y:
                    sensitivity = CONFIG['sensitivity']
                    value = max(-127, min(127, int(event.value * sensitivity)))
                    if CONFIG['invert_y']:
                        value = -value
                    self.report[2] = value
                
                elif event.code == ecodes.REL_WHEEL:
                    if CONFIG['smooth_scroll']:
                        value = max(-127, min(127, int(event.value / CONFIG['scroll_divider'])))
                    else:
                        value = -1 if event.value < 0 else 1 if event.value > 0 else 0
                    self.report[3] = value
                
                self.send_report()
                self.reset_report()
    
    def run(self):
        """Main execution loop."""
        if not self.open_devices():
            return False
        
        if CONFIG['socket_enabled']:
            self.setup_socket()
        
        print("ZeroPassThrough running. Press Ctrl+C to exit.")
        
        try:
            while self.running:
                # Handle socket commands if enabled
                if CONFIG['socket_enabled']:
                    self.handle_socket_commands()
                
                # Process mouse events if available
                if self.mouse_input.poll(timeout=100):
                    self.process_events()
                
                # Brief pause to prevent CPU hogging
                time.sleep(0.001)
        
        except KeyboardInterrupt:
            print("Exiting...")
        except Exception as e:
            print(f"Error in main loop: {e}")
        finally:
            if self.mouse_input:
                self.mouse_input.close()
            if self.hid_output:
                self.hid_output.close()
            if self.socket:
                self.socket.close()
        
        return True

if __name__ == "__main__":
    # Check if running as root
    if os.geteuid() != 0:
        print("This script must be run as root (sudo). Exiting.")
        sys.exit(1)
    
    # Run the passthrough
    passthrough = MousePassthrough()
    success = passthrough.run()
    sys.exit(0 if success else 1)
EOF

chmod +x /usr/local/bin/mouse_passthrough.py

echo "[5/5] Setting up systemd service for autostart..."
# Create systemd service
cat > /etc/systemd/system/zeropassthrough.service << 'EOF'
[Unit]
Description=ZeroPassThrough USB Mouse Passthrough
After=network.target

[Service]
ExecStart=/bin/bash -c '/usr/local/bin/hid_setup.sh && /usr/local/bin/mouse_passthrough.py'
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# Enable and start the service
systemctl enable zeropassthrough.service
systemctl start zeropassthrough.service

echo ""
echo "===== ZeroPassThrough setup complete! ====="
echo ""
echo "The system will automatically start the mouse passthrough service after reboot."
echo "To test the service now, connect a USB mouse and plug the Pi into a computer."
echo ""
echo "For troubleshooting, check the service status with:"
echo "  sudo systemctl status zeropassthrough"
echo ""
echo "A reboot is recommended to apply all changes:"
echo "  sudo reboot"
echo "" 