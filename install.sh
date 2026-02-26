#!/bin/sh
# RTL8821AE/RTL8812AE PCIe WiFi Driver Installer for FreeBSD
#
# Usage: sudo sh install.sh [/path/to/freebsd/src]
#
# Copies driver sources, firmware, and Makefiles into the FreeBSD source
# tree, then builds and installs the kernel modules.

set -e

SRCDIR="${1:-/usr/src}"
REPODIR="$(cd "$(dirname "$0")" && pwd)"

die()  { echo "ERROR: $1" >&2; exit 1; }
info() { echo "==> $1"; }

# --- Sanity checks ---
[ "$(id -u)" -eq 0 ] || die "Must run as root (or with sudo)"
[ -d "$SRCDIR/sys/dev/rtwn" ] || die "FreeBSD source tree not found at $SRCDIR"

info "Installing RTL8821AE/RTL8812AE PCIe driver into $SRCDIR"

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
info "Installing firmware"
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
info "Installing kernel modules"
make -C "$SRCDIR/sys/modules/rtwn_pci" install
make -C "$SRCDIR/sys/modules/rtwnfw/rtwnrtl8821ae" install

# --- Load ---
info "Loading modules"
kldunload if_rtwn_pci 2>/dev/null || true
kldload rtwn-rtl8821aefw 2>/dev/null || true
kldload if_rtwn_pci 2>/dev/null || true

echo ""
echo "Done! To make persistent, add to /boot/loader.conf:"
echo '  rtwn-rtl8821aefw_load="YES"'
echo '  if_rtwn_pci_load="YES"'
echo ""
echo "Quick test:"
echo "  ifconfig wlan0 create wlandev rtwn0"
echo "  ifconfig wlan0 up"
echo "  ifconfig wlan0 list scan"
