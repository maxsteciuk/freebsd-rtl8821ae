#!/bin/sh
# RTL8821AE/RTL8812AE PCIe WiFi (+Bluetooth) Driver Installer for FreeBSD
#
# Usage: sudo sh install.sh [options] [/path/to/freebsd/src]
#
#   --wifi       Install WiFi driver only (default)
#   --bluetooth  Set up Bluetooth support
#   --all        Install both WiFi driver and Bluetooth support
#
# Copies driver sources, firmware, and Makefiles into the FreeBSD source
# tree, then builds and installs the kernel modules into /boot/modules and
# configures /boot/loader.conf to load them from there at boot.

set -e

# --- Parse options ---
DO_WIFI=0
DO_BT=0
SRCDIR=""

for arg in "$@"; do
	case "$arg" in
		--wifi)      DO_WIFI=1 ;;
		--bluetooth) DO_BT=1 ;;
		--all)       DO_WIFI=1; DO_BT=1 ;;
		--help|-h)
			echo "Usage: sudo sh $0 [--wifi|--bluetooth|--all] [/path/to/freebsd/src]"
			exit 0
			;;
		*)           SRCDIR="$arg" ;;
	esac
done

# Default: WiFi only (backward compatible)
if [ "$DO_WIFI" -eq 0 ] && [ "$DO_BT" -eq 0 ]; then
	DO_WIFI=1
fi

SRCDIR="${SRCDIR:-/usr/src}"
REPODIR="$(cd "$(dirname "$0")" && pwd)"

# The patched modules are installed into /boot/modules.  The stock
# if_rtwn_pci.ko stays in /boot/kernel, which comes first in
# kern.module_path, so the patched modules must always be named by path.
KMODDIR="/boot/modules"
LOADER_CONF="/boot/loader.conf"

die()  { echo "ERROR: $1" >&2; exit 1; }
info() { echo "==> $1"; }

# Set $1="$2" in $LOADER_CONF, replacing any existing setting of $1.
loader_conf_set() {
	if grep -q "^[[:space:]]*$1=" "$LOADER_CONF" 2>/dev/null; then
		sed -i '' "s|^[[:space:]]*$1=.*|$1=\"$2\"|" "$LOADER_CONF"
	else
		echo "$1=\"$2\"" >> "$LOADER_CONF"
	fi
}

# Print the path a loaded kernel module file was loaded from.
kld_path() {
	kldstat -v -n "$1" 2>/dev/null | sed -n 's/.*(\(.*\)).*/\1/p' | head -n 1
}

# --- Sanity checks ---
[ "$(id -u)" -eq 0 ] || die "Must run as root (or with sudo)"

if [ "$DO_WIFI" -eq 1 ]; then
	[ -d "$SRCDIR/sys/dev/rtwn" ] || die "FreeBSD source tree not found at $SRCDIR"
fi

info "Installing RTL8821AE/RTL8812AE driver into $SRCDIR"

# ============================================================
# WiFi Driver Installation
# ============================================================

if [ "$DO_WIFI" -eq 1 ]; then
	info "--- WiFi Driver Installation ---"

	# --- Copy new driver files ---
	info "Copying driver source files"
	mkdir -p "$SRCDIR/sys/dev/rtwn/rtl8821a/pci"
	cp "$REPODIR/sys/dev/rtwn/rtl8821a/pci/r21a_pci_attach.c"  "$SRCDIR/sys/dev/rtwn/rtl8821a/pci/"
	cp "$REPODIR/sys/dev/rtwn/rtl8821a/pci/r21a_pci_attach.h"  "$SRCDIR/sys/dev/rtwn/rtl8821a/pci/"
	cp "$REPODIR/sys/dev/rtwn/rtl8821a/pci/r21a_pci_compat.c"  "$SRCDIR/sys/dev/rtwn/rtl8821a/pci/"
	cp "$REPODIR/sys/dev/rtwn/rtl8821a/pci/r21ae_tx_desc.h"    "$SRCDIR/sys/dev/rtwn/rtl8821a/pci/"

	# --- Copy modified PCI attach header ---
	info "Updating rtwn_pci_attach.h (adds RTL8821AE/RTL8812AE device IDs)"
	cp "$REPODIR/sys/dev/rtwn/pci/rtwn_pci_attach.h" "$SRCDIR/sys/dev/rtwn/pci/"

	# --- Copy firmware ---
	info "Installing WiFi firmware"
	mkdir -p "$SRCDIR/sys/contrib/dev/rtwn"
	cp "$REPODIR/sys/contrib/dev/rtwn/rtwn-rtl8821aefw.fw.uu" "$SRCDIR/sys/contrib/dev/rtwn/"

	# --- Copy Makefiles ---
	info "Updating Makefiles"
	cp "$REPODIR/sys/modules/rtwn_pci/Makefile" "$SRCDIR/sys/modules/rtwn_pci/"

	mkdir -p "$SRCDIR/sys/modules/rtwnfw/rtwnrtl8821ae"
	cp "$REPODIR/sys/modules/rtwnfw/rtwnrtl8821ae/Makefile" "$SRCDIR/sys/modules/rtwnfw/rtwnrtl8821ae/"
	cp "$REPODIR/sys/modules/rtwnfw/Makefile" "$SRCDIR/sys/modules/rtwnfw/"

	# --- Build ---
	info "Building if_rtwn_pci kernel module"
	make -C "$SRCDIR/sys/modules/rtwn_pci" clean all

	info "Building rtwn-rtl8821aefw firmware module"
	make -C "$SRCDIR/sys/modules/rtwnfw/rtwnrtl8821ae" clean all

	# --- Install ---
	info "Installing WiFi kernel modules into $KMODDIR"
	make -C "$SRCDIR/sys/modules/rtwn_pci" install KMODDIR="$KMODDIR"
	make -C "$SRCDIR/sys/modules/rtwnfw/rtwnrtl8821ae" install KMODDIR="$KMODDIR"

	# --- Boot configuration ---
	# Without the _name settings the loader picks the stock module.
	info "Configuring $LOADER_CONF to load the modules from $KMODDIR"
	if [ -f "$LOADER_CONF" ] && [ ! -f "$LOADER_CONF.pre-rtl8821ae" ]; then
		cp -p "$LOADER_CONF" "$LOADER_CONF.pre-rtl8821ae"
	fi
	loader_conf_set rtwn-rtl8821aefw_load "YES"
	loader_conf_set rtwn-rtl8821aefw_name "$KMODDIR/rtwn-rtl8821aefw.ko"
	loader_conf_set if_rtwn_pci_load "YES"
	loader_conf_set if_rtwn_pci_name "$KMODDIR/if_rtwn_pci.ko"

	# --- Load ---
	# Load by path: "kldload if_rtwn_pci" would load the stock module.
	info "Loading WiFi modules from $KMODDIR"
	kldunload if_rtwn_pci 2>/dev/null || true
	kldunload rtwn-rtl8821aefw 2>/dev/null || true
	kldload "$KMODDIR/rtwn-rtl8821aefw.ko" 2>/dev/null || true
	kldload "$KMODDIR/if_rtwn_pci.ko" 2>/dev/null || true

	LOADED="$(kld_path if_rtwn_pci)"
	if [ "$LOADED" = "$KMODDIR/if_rtwn_pci.ko" ]; then
		info "if_rtwn_pci loaded from $LOADED"
	else
		echo "WARNING: if_rtwn_pci is loaded from '${LOADED:-nowhere}'," \
		    "not $KMODDIR; reboot to use the new module" >&2
	fi
fi

# ============================================================
# Bluetooth Setup
# ============================================================

if [ "$DO_BT" -eq 1 ]; then
	info "--- Bluetooth Setup ---"
	sh "$REPODIR/bluetooth_setup.sh" -p -n
fi

# ============================================================
# Summary
# ============================================================

echo ""
echo "Done!"

if [ "$DO_WIFI" -eq 1 ]; then
	echo ""
	echo "WiFi: $LOADER_CONF now loads the modules from $KMODDIR:"
	grep -E '^(rtwn-rtl8821aefw|if_rtwn_pci)_' "$LOADER_CONF" | sed 's/^/  /'
	echo ""
	echo "WiFi quick test:"
	echo "  ifconfig wlan0 create wlandev rtwn0"
	echo "  ifconfig wlan0 up"
	echo "  ifconfig wlan0 list scan"
fi

if [ "$DO_BT" -eq 1 ]; then
	echo ""
	echo "Bluetooth: verify with:"
	echo "  sudo sh bluetooth_test.sh -v"
	echo ""
	echo "See BLUETOOTH.md for detailed Bluetooth documentation."
fi

if [ "$DO_WIFI" -eq 1 ] && [ "$DO_BT" -eq 0 ]; then
	echo ""
	echo "To also set up Bluetooth, re-run with --bluetooth or --all:"
	echo "  sudo sh install.sh --all"
fi
