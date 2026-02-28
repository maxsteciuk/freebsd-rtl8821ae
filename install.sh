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
# tree, then builds and installs the kernel modules.

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

die()  { echo "ERROR: $1" >&2; exit 1; }
info() { echo "==> $1"; }

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
	info "Installing WiFi kernel modules"
	make -C "$SRCDIR/sys/modules/rtwn_pci" install
	make -C "$SRCDIR/sys/modules/rtwnfw/rtwnrtl8821ae" install

	# --- Load ---
	info "Loading WiFi modules"
	kldunload if_rtwn_pci 2>/dev/null || true
	kldload rtwn-rtl8821aefw 2>/dev/null || true
	kldload if_rtwn_pci 2>/dev/null || true
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
	echo "WiFi: add to /boot/loader.conf:"
	echo '  rtwn-rtl8821aefw_load="YES"'
	echo '  if_rtwn_pci_load="YES"'
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
