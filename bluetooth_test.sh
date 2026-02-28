#!/bin/sh
# RTL8821AE Bluetooth Test Script for FreeBSD
#
# Validates that the Bluetooth subsystem is properly configured and
# operational on systems with RTL8821AE combo WiFi+Bluetooth cards.
#
# Usage: sudo sh bluetooth_test.sh [-v]
#   -v  Verbose output
#
# Copyright (c) 2026 Maksym Stetsyuk
# SPDX-License-Identifier: BSD-2-Clause

VERBOSE=0
PASS=0
FAIL=0
SKIP=0

# --- Known RTL8821AE Bluetooth USB device IDs ---
RTL8821AE_BT_DEVICES="
0x0b05:0x17dc
0x13d3:0x3414
0x13d3:0x3458
0x13d3:0x3461
0x13d3:0x3462
"

while getopts "v" opt; do
	case "$opt" in
		v) VERBOSE=1 ;;
		*) echo "Usage: $0 [-v]"; exit 1 ;;
	esac
done

# --- Test helpers ---
test_pass() {
	PASS=$((PASS + 1))
	printf "  \033[32mPASS\033[0m  %s\n" "$1"
}

test_fail() {
	FAIL=$((FAIL + 1))
	printf "  \033[31mFAIL\033[0m  %s\n" "$1"
	if [ -n "$2" ]; then
		printf "        %s\n" "$2"
	fi
}

test_skip() {
	SKIP=$((SKIP + 1))
	printf "  \033[33mSKIP\033[0m  %s\n" "$1"
	if [ -n "$2" ]; then
		printf "        %s\n" "$2"
	fi
}

verbose() {
	if [ "$VERBOSE" -eq 1 ]; then
		printf "        %s\n" "$1"
	fi
}

separator() {
	echo ""
	echo "--- $1 ---"
}

# ============================================================
# Test Suite
# ============================================================

echo "RTL8821AE Bluetooth Test Suite"
echo "=============================="
echo ""

# --- 1. Kernel Module Tests ---
separator "Kernel Modules"

# Test 1.1: ng_ubt module
if kldstat -q -m "uhub/ng_ubt" 2>/dev/null || kldstat -q -m "ng_ubt" 2>/dev/null; then
	test_pass "ng_ubt (USB Bluetooth transport) loaded"
else
	# Check if compiled into kernel
	if sysctl -n kern.features.bluetooth 2>/dev/null | grep -q "1"; then
		test_pass "ng_ubt compiled into kernel"
	else
		test_fail "ng_ubt not loaded" "Run: kldload ng_ubt"
	fi
fi

# Test 1.2: ng_hci module
if kldstat -q -m ng_hci 2>/dev/null; then
	test_pass "ng_hci (HCI protocol) loaded"
else
	test_fail "ng_hci not loaded" "Run: kldload ng_hci"
fi

# Test 1.3: ng_l2cap module
if kldstat -q -m ng_l2cap 2>/dev/null; then
	test_pass "ng_l2cap (L2CAP protocol) loaded"
else
	test_fail "ng_l2cap not loaded" "Run: kldload ng_l2cap"
fi

# Test 1.4: ng_btsocket module
if kldstat -q -m ng_btsocket 2>/dev/null; then
	test_pass "ng_btsocket (Bluetooth sockets) loaded"
else
	test_fail "ng_btsocket not loaded" "Run: kldload ng_btsocket"
fi

# --- 2. Firmware Tests ---
separator "Firmware"

# Test 2.1: rtlbtfw utility
if [ -x /usr/sbin/rtlbtfw ]; then
	test_pass "rtlbtfw utility available"
else
	test_fail "rtlbtfw utility not found" "Should be at /usr/sbin/rtlbtfw"
fi

# Test 2.2: Firmware files
FW_FOUND=0
for dir in /usr/local/share/rtlbt-firmware /usr/share/firmware/rtlbt; do
	if [ -f "$dir/rtl8821a_fw.bin" ]; then
		test_pass "Firmware file found: $dir/rtl8821a_fw.bin"
		FW_FOUND=1
		fw_size=$(stat -f%z "$dir/rtl8821a_fw.bin" 2>/dev/null || echo "unknown")
		verbose "Firmware size: $fw_size bytes"
		break
	fi
done
if [ "$FW_FOUND" -eq 0 ]; then
	test_fail "Firmware rtl8821a_fw.bin not found" "Run: pkg install rtlbt-firmware"
fi

# Test 2.3: rtlbt-firmware package
if pkg info rtlbt-firmware >/dev/null 2>&1; then
	pkg_ver=$(pkg info rtlbt-firmware | head -1)
	test_pass "rtlbt-firmware package installed"
	verbose "$pkg_ver"
else
	test_fail "rtlbt-firmware package not installed" "Run: pkg install rtlbt-firmware"
fi

# --- 3. USB Device Tests ---
separator "USB Device Detection"

# Test 3.1: Any USB devices visible
if [ "$(id -u)" -ne 0 ]; then
	test_skip "USB device detection (requires root)"
else
	usb_list=$(usbconfig list 2>/dev/null || true)
	if [ -n "$usb_list" ]; then
		test_pass "USB subsystem operational"
		verbose "$(echo "$usb_list" | wc -l | tr -d ' ') USB devices found"
	else
		test_fail "No USB devices detected" "Check USB controller"
	fi

	# Test 3.2: RTL8821AE Bluetooth device
	bt_found=0
	usb_desc=$(usbconfig dump_device_desc 2>/dev/null || true)
	for devid in $RTL8821AE_BT_DEVICES; do
		vendor=$(echo "$devid" | cut -d: -f1)
		product=$(echo "$devid" | cut -d: -f2)
		# Match vendor and product allowing spaces around '='
		if echo "$usb_desc" | grep -q "idVendor.*$vendor" && \
		   echo "$usb_desc" | grep -q "idProduct.*$product"; then
			bt_found=1
			test_pass "RTL8821AE Bluetooth USB device found ($devid)"
			break
		fi
	done

	# Check generic Realtek BT class
	if [ "$bt_found" -eq 0 ]; then
		if echo "$usb_desc" | grep -q "bDeviceClass.*0x00e0"; then
			test_pass "Generic Bluetooth USB device found (class 0xe0)"
			bt_found=1
		fi
	fi

	if [ "$bt_found" -eq 0 ]; then
		test_fail "No RTL8821AE Bluetooth USB device detected" \
			"Check card installation and USB controller BIOS settings"
	fi
fi

# --- 4. devd Configuration Tests ---
separator "devd Configuration"

# Test 4.1: rtlbtfw.conf present
if [ -f /etc/devd/rtlbtfw.conf ]; then
	test_pass "devd rtlbtfw.conf installed"

	# Test 4.2: Contains RTL8821AE entries
	if grep -q "8821AE" /etc/devd/rtlbtfw.conf 2>/dev/null; then
		test_pass "rtlbtfw.conf contains RTL8821AE entries"
	else
		test_fail "rtlbtfw.conf missing RTL8821AE entries"
	fi
else
	test_fail "devd rtlbtfw.conf not found" "Automatic firmware loading disabled"
fi

# Test 4.3: devd running
if service devd status >/dev/null 2>&1; then
	test_pass "devd service running"
else
	test_fail "devd service not running" "Run: service devd start"
fi

# --- 5. Netgraph Bluetooth Stack Tests ---
separator "Netgraph Bluetooth Stack"

if [ "$(id -u)" -ne 0 ]; then
	test_skip "Netgraph tests (requires root)"
else
	# Test 5.1: Netgraph subsystem
	if ngctl list >/dev/null 2>&1; then
		test_pass "Netgraph subsystem operational"
	else
		test_fail "Netgraph subsystem not available"
	fi

	# Test 5.2: ubt node present
	ubt_node=$(ngctl list 2>/dev/null | grep "ubt" | head -1 | awk '{print $2}')
	if [ -n "$ubt_node" ]; then
		test_pass "Bluetooth UBT Netgraph node: $ubt_node"

		# Test 5.3: Node type
		node_type=$(ngctl list 2>/dev/null | grep "ubt" | head -1 | awk '{print $4}')
		if [ "$node_type" = "ubt" ]; then
			test_pass "UBT node type correct"
		else
			verbose "Node type: $node_type"
		fi
	else
		test_fail "No UBT Netgraph node" "Firmware may not be loaded"
	fi

	# Test 5.4: HCI node
	hci_node=$(ngctl list 2>/dev/null | grep "hci" | head -1 | awk '{print $2}')
	if [ -n "$hci_node" ]; then
		test_pass "HCI Netgraph node: $hci_node"
	else
		test_skip "No HCI node (Bluetooth stack may not be fully configured)"
	fi
fi

# --- 6. HCI Device Tests ---
separator "HCI Device"

if [ "$(id -u)" -ne 0 ]; then
	test_skip "HCI tests (requires root)"
elif [ -z "$ubt_node" ]; then
	test_skip "HCI tests (no UBT node available)"
else
	# Test 6.1: Read BD_ADDR via hccontrol
	if command -v hccontrol >/dev/null 2>&1; then
		# Try to get node name for hccontrol
		hci_name=$(ngctl list 2>/dev/null | grep "Type: hci" | head -1 | awk '{print $2}' | tr -d '"')
		if [ -n "$hci_name" ]; then
			bd_addr=$(hccontrol -n "$hci_name" read_bd_addr 2>/dev/null || true)
			if [ -n "$bd_addr" ]; then
				test_pass "HCI Read BD_ADDR succeeded"
				verbose "$bd_addr"
			else
				test_fail "HCI Read BD_ADDR failed"
			fi

			# Test 6.2: Read local name
			local_name=$(hccontrol -n "$hci_name" read_local_name 2>/dev/null || true)
			if [ -n "$local_name" ]; then
				test_pass "HCI Read Local Name succeeded"
				verbose "$local_name"
			else
				test_fail "HCI Read Local Name failed"
			fi

			# Test 6.3: Read supported features
			features=$(hccontrol -n "$hci_name" read_local_supported_features 2>/dev/null || true)
			if [ -n "$features" ]; then
				test_pass "HCI Read Local Supported Features succeeded"
				if echo "$features" | grep -q "LE Supported"; then
					test_pass "Bluetooth Low Energy (BLE) supported"
				else
					test_fail "Bluetooth Low Energy (BLE) not reported"
				fi
			else
				test_fail "HCI Read Supported Features failed"
			fi
		else
			test_skip "HCI tests (no HCI node name found)"
		fi
	else
		test_skip "hccontrol not available"
	fi
fi

# --- 7. WiFi + Bluetooth Coexistence Test ---
separator "WiFi + Bluetooth Coexistence"

# Test 7.1: WiFi driver loaded
if kldstat -q -m "pci/rtwn_pci" 2>/dev/null || kldstat -q -m "if_rtwn_pci" 2>/dev/null; then
	test_pass "WiFi driver (if_rtwn_pci) loaded"
	wifi_loaded=1
else
	test_skip "WiFi driver not loaded (if_rtwn_pci)"
	wifi_loaded=0
fi

# Test 7.2: WiFi interface present
if ifconfig rtwn0 >/dev/null 2>&1 || sysctl -n net.wlan.0.%parent 2>/dev/null | grep -q "rtwn"; then
	test_pass "WiFi interface rtwn0 present"
else
	test_skip "WiFi interface rtwn0 not present"
fi

# Test 7.3: Both WiFi and BT simultaneously
if [ "$wifi_loaded" -eq 1 ] && [ -n "$ubt_node" ]; then
	test_pass "WiFi and Bluetooth both operational simultaneously"
else
	test_skip "Coexistence test (need both WiFi and BT active)"
fi

# --- 8. Boot Configuration Tests ---
separator "Boot Configuration"

# Test 8.1: loader.conf entries
loader_ok=1
for mod in ng_ubt ng_hci ng_l2cap ng_btsocket; do
	if grep -qF "${mod}_load=\"YES\"" /boot/loader.conf 2>/dev/null; then
		verbose "$mod configured in loader.conf"
	else
		loader_ok=0
	fi
done

if [ "$loader_ok" -eq 1 ]; then
	test_pass "All Bluetooth modules in /boot/loader.conf"
else
	test_skip "Bluetooth modules not yet in loader.conf" \
		"Run: bluetooth_setup.sh -p"
fi

# Test 8.2: WiFi loader.conf entries
if grep -qF 'if_rtwn_pci_load="YES"' /boot/loader.conf 2>/dev/null; then
	test_pass "WiFi module in /boot/loader.conf"
else
	test_skip "WiFi module not in loader.conf"
fi

# ============================================================
# Summary
# ============================================================

echo ""
echo "=============================="
TOTAL=$((PASS + FAIL + SKIP))
echo "Results: $TOTAL tests — $PASS passed, $FAIL failed, $SKIP skipped"

if [ "$FAIL" -eq 0 ]; then
	printf "\033[32mAll tests passed!\033[0m\n"
	exit 0
else
	printf "\033[31m%d test(s) failed.\033[0m\n" "$FAIL"
	echo ""
	echo "Troubleshooting:"
	echo "  1. Run: sudo sh bluetooth_setup.sh"
	echo "  2. See BLUETOOTH.md for detailed guidance"
	exit 1
fi
