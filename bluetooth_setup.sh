#!/bin/sh
# RTL8821AE Bluetooth Setup Script for FreeBSD
#
# The RTL8821AE is a combo WiFi+Bluetooth chip. WiFi uses PCIe (rtwn driver),
# Bluetooth uses an internal USB 1.1 interface (ng_ubt_rtl driver).
#
# This script sets up the Bluetooth subsystem:
#   1. Installs firmware package (rtlbt-firmware)
#   2. Loads required kernel modules
#   3. Verifies the Bluetooth USB device
#   4. Configures persistent boot settings
#
# Usage: sudo sh bluetooth_setup.sh [options]
#   -f PATH   Firmware path override
#   -p        Persistent: add loader.conf/rc.conf entries
#   -n        Non-interactive: skip confirmations
#   -h        Help
#
# Copyright (c) 2026 Maksym Stetsyuk
# SPDX-License-Identifier: BSD-2-Clause

set -e

# --- Defaults ---
FW_PATH="/usr/local/share/rtlbt-firmware"
PERSISTENT=0
INTERACTIVE=1

# --- Known RTL8821AE Bluetooth USB device IDs ---
# These are subsystem vendor IDs for the BT half of the RTL8821AE combo chip.
RTL8821AE_BT_DEVICES="
0x0b05:0x17dc
0x13d3:0x3414
0x13d3:0x3458
0x13d3:0x3461
0x13d3:0x3462
"

# --- Required kernel modules ---
BT_MODULES="ng_ubt ng_hci ng_l2cap ng_btsocket"

die()  { echo "ERROR: $1" >&2; exit 1; }
info() { echo "==> $1"; }
warn() { echo "WARNING: $1" >&2; }

usage() {
	echo "Usage: sudo sh $0 [options]"
	echo ""
	echo "Options:"
	echo "  -f PATH   Firmware path (default: $FW_PATH)"
	echo "  -p        Make configuration persistent across reboots"
	echo "  -n        Non-interactive mode (skip confirmations)"
	echo "  -h        Show this help"
	exit 0
}

# --- Parse arguments ---
while getopts "f:pnh" opt; do
	case "$opt" in
		f) FW_PATH="$OPTARG" ;;
		p) PERSISTENT=1 ;;
		n) INTERACTIVE=0 ;;
		h) usage ;;
		*) usage ;;
	esac
done

# --- Sanity checks ---
[ "$(id -u)" -eq 0 ] || die "Must run as root (or with sudo)"

# --- Step 1: Install firmware package ---
install_firmware() {
	info "Checking for Bluetooth firmware"

	if [ -d "$FW_PATH" ] && [ -f "$FW_PATH/rtl8821a_fw.bin" ]; then
		info "Firmware already installed at $FW_PATH"
		return 0
	fi

	# Check if the package is installed
	if pkg info rtlbt-firmware >/dev/null 2>&1; then
		info "rtlbt-firmware package installed but firmware not at $FW_PATH"
		# Find actual firmware location
		actual_path=$(pkg info -l rtlbt-firmware 2>/dev/null | grep "rtl8821a_fw" | head -1 | xargs dirname 2>/dev/null || true)
		if [ -n "$actual_path" ] && [ -d "$actual_path" ]; then
			FW_PATH="$actual_path"
			info "Found firmware at $FW_PATH"
			return 0
		fi
	fi

	info "Installing rtlbt-firmware package"
	if ! pkg install -y rtlbt-firmware; then
		warn "pkg install failed. Trying alternative methods..."

		# Try fetching from ports
		if [ -d /usr/ports/comms/rtlbt-firmware ]; then
			info "Building from ports"
			make -C /usr/ports/comms/rtlbt-firmware install clean
		else
			die "Cannot install rtlbt-firmware. Install manually: pkg install rtlbt-firmware"
		fi
	fi

	# Verify firmware exists after installation
	if [ ! -f "$FW_PATH/rtl8821a_fw.bin" ]; then
		# Search for the firmware file
		actual_path=$(find /usr/local/share -name "rtl8821a_fw.bin" -print -quit 2>/dev/null | xargs dirname 2>/dev/null || true)
		if [ -n "$actual_path" ]; then
			FW_PATH="$actual_path"
			info "Firmware found at $FW_PATH"
		else
			die "Firmware file rtl8821a_fw.bin not found after installation"
		fi
	fi
}

# --- Step 2: Load kernel modules ---
load_modules() {
	info "Loading Bluetooth kernel modules"

	for mod in $BT_MODULES; do
		if kldstat -q -m "$mod" 2>/dev/null; then
			info "  $mod already loaded"
		else
			info "  Loading $mod"
			if ! kldload "$mod" 2>/dev/null; then
				warn "  Failed to load $mod (may already be compiled into kernel)"
			fi
		fi
	done
}

# --- Step 3: Detect Bluetooth USB device ---
detect_bt_device() {
	info "Detecting RTL8821AE Bluetooth USB device"

	bt_dev=""
	for devid in $RTL8821AE_BT_DEVICES; do
		vendor=$(echo "$devid" | cut -d: -f1)
		product=$(echo "$devid" | cut -d: -f2)

		# Search usbconfig output for matching device
		match=$(usbconfig dump_device_desc 2>/dev/null | grep -B5 "idVendor.*=$vendor" | grep -A5 "idProduct.*=$product" || true)
		if [ -n "$match" ]; then
			bt_dev="$devid"
			break
		fi
	done

	# Also check with generic Realtek BT class match
	if [ -z "$bt_dev" ]; then
		match=$(usbconfig dump_device_desc 2>/dev/null | grep -B2 "idVendor.*=0x0bda" | grep -A10 "bInterfaceClass.*=0xe0" || true)
		if [ -n "$match" ]; then
			bt_dev="generic_realtek"
		fi
	fi

	if [ -z "$bt_dev" ]; then
		warn "No RTL8821AE Bluetooth USB device detected"
		echo ""
		echo "The Bluetooth controller is on an internal USB interface."
		echo "If not detected, check:"
		echo "  1. The RTL8821AE card is physically installed"
		echo "  2. USB controller is enabled in BIOS"
		echo "  3. Run: usbconfig list"
		echo ""
		return 1
	fi

	info "Found Bluetooth device: $bt_dev"
	return 0
}

# --- Step 4: Load firmware via rtlbtfw ---
load_firmware() {
	info "Loading Bluetooth firmware"

	if [ ! -x /usr/sbin/rtlbtfw ]; then
		die "rtlbtfw utility not found at /usr/sbin/rtlbtfw"
	fi

	# Find the USB device node for the Bluetooth interface
	bt_ugen=""
	for dev in /dev/ugen*; do
		[ -e "$dev" ] || continue
		devname=$(basename "$dev")
		desc=$(usbconfig -d "$devname" dump_device_desc 2>/dev/null || true)

		for devid in $RTL8821AE_BT_DEVICES; do
			vendor=$(echo "$devid" | cut -d: -f1)
			product=$(echo "$devid" | cut -d: -f2)
			if echo "$desc" | grep -q "idVendor.*=$vendor" && \
			   echo "$desc" | grep -q "idProduct.*=$product"; then
				bt_ugen="$devname"
				break 2
			fi
		done
	done

	if [ -z "$bt_ugen" ]; then
		info "No device node found — devd may have already loaded firmware"
		# Verify by checking if ng_ubt attached
		if ngctl list 2>/dev/null | grep -q "ubt"; then
			info "Bluetooth device already attached to Netgraph (firmware loaded)"
			return 0
		fi
		warn "Could not find USB device node for firmware loading"
		return 1
	fi

	info "Loading firmware to $bt_ugen"
	if ! rtlbtfw -d "$bt_ugen" -f "$FW_PATH"; then
		warn "Firmware loading failed — device may need power cycle"
		return 1
	fi

	info "Firmware loaded successfully"
}

# --- Step 5: Verify Bluetooth stack ---
verify_stack() {
	info "Verifying Bluetooth stack"

	# Wait for ng_ubt to attach after firmware loading
	sleep 2

	# Check for Netgraph ubt node
	if ngctl list 2>/dev/null | grep -q "ubt"; then
		info "Netgraph Bluetooth node created"
	else
		warn "No Netgraph ubt node found — Bluetooth may not be operational"
		return 1
	fi

	# Try to read HCI local version
	ubt_node=$(ngctl list 2>/dev/null | grep "ubt" | head -1 | awk '{print $2}')
	if [ -n "$ubt_node" ]; then
		info "Bluetooth HCI node: $ubt_node"
	fi

	return 0
}

# --- Step 6: Configure persistent settings ---
configure_persistent() {
	if [ "$PERSISTENT" -eq 0 ]; then
		return 0
	fi

	info "Configuring persistent Bluetooth settings"

	# Add modules to loader.conf
	for mod in $BT_MODULES; do
		mod_line="${mod}_load=\"YES\""
		if ! grep -qF "$mod_line" /boot/loader.conf 2>/dev/null; then
			echo "$mod_line" >> /boot/loader.conf
			info "  Added $mod_line to /boot/loader.conf"
		fi
	done

	# Ensure devd is running (it handles automatic firmware loading)
	if ! service devd status >/dev/null 2>&1; then
		service devd start
		info "  Started devd service"
	fi

	# Verify rtlbtfw.conf is installed in devd
	if [ -f /etc/devd/rtlbtfw.conf ]; then
		info "  devd rtlbtfw.conf already installed"
	else
		warn "  /etc/devd/rtlbtfw.conf not found — automatic firmware loading disabled"
		echo "  Firmware will need to be loaded manually after each reboot"
	fi
}

# --- Main ---
main() {
	echo "RTL8821AE Bluetooth Setup for FreeBSD"
	echo "======================================"
	echo ""

	install_firmware
	load_modules
	detect_bt_device || true
	load_firmware || true
	verify_stack || true

	if [ "$PERSISTENT" -eq 1 ]; then
		configure_persistent
	fi

	echo ""
	echo "======================================"
	echo "Bluetooth setup complete."
	echo ""
	echo "To make persistent across reboots, re-run with -p flag:"
	echo "  sudo sh bluetooth_setup.sh -p"
	echo ""
	echo "To verify Bluetooth is working:"
	echo "  sudo sh bluetooth_test.sh"
	echo ""
	echo "For detailed documentation, see BLUETOOTH.md"
}

main
