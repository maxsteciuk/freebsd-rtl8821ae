#!/bin/sh
# RTL8821AE/RTL8812AE PCIe WiFi (+Bluetooth) Driver Installer for FreeBSD
#
# Usage: sudo sh install.sh [options] [/path/to/freebsd/src]
#
#   --wifi       Install WiFi driver only (default)
#   --bluetooth  Set up Bluetooth support
#   --all        Install both WiFi driver and Bluetooth support
#   --reload     Reload the WiFi driver now even when a wlan interface on
#                it is up; that link drops while the driver reloads
#   --check      Report the state of the installed WiFi driver and exit
#   --uninstall  Undo the WiFi driver install and exit
#
# Before changing anything, checks that the source tree matches the running
# kernel and that its rtwn(4) driver interface is one this overlay supports.
# Then copies driver sources, firmware, and Makefiles into the FreeBSD
# source tree (saving the upstream files it replaces), builds and installs
# the kernel modules into /boot/modules, and configures /boot/loader.conf to
# load them from there at boot.

set -e

# --- Parse options ---
DO_WIFI=0
DO_BT=0
DO_RELOAD=0
MODE="install"
SRCDIR=""

usage() {
	echo "Usage: sudo sh $0 [--wifi|--bluetooth|--all] [--reload] [/path/to/freebsd/src]"
	echo "       sh $0 --check"
	echo "       sudo sh $0 --uninstall"
}

for arg in "$@"; do
	case "$arg" in
		--wifi)      DO_WIFI=1 ;;
		--bluetooth) DO_BT=1 ;;
		--all)       DO_WIFI=1; DO_BT=1 ;;
		--reload)    DO_RELOAD=1 ;;
		--check)     MODE="check" ;;
		--uninstall) MODE="uninstall" ;;
		--help|-h)   usage; exit 0 ;;
		-*)          usage >&2; exit 2 ;;
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
LOADER_CONF_SAVED="$LOADER_CONF.pre-rtl8821ae"

# Installer state: what the modules were built for, the upstream source
# files the install replaced, and what --uninstall moved aside.
STATE_DIR="/var/db/rtl8821ae"
BUILD_INFO="$STATE_DIR/build-info"
SRC_SAVED_DIR="$STATE_DIR/src-orig"

# Modules in load order, and the loader.conf settings that select them.
KMODS="rtwn-rtl8821aefw if_rtwn_pci"
LOADER_KEYS="rtwn-rtl8821aefw_load rtwn-rtl8821aefw_name if_rtwn_pci_load if_rtwn_pci_name"

# Upstream files the install overwrites, and files it adds; paths are
# relative to both this repository and the source tree.
REPLACED_FILES="sys/dev/rtwn/pci/rtwn_pci_attach.h
sys/modules/rtwn_pci/Makefile
sys/modules/rtwnfw/Makefile"
ADDED_FILES="sys/dev/rtwn/rtl8821a/pci/r21a_pci_attach.c
sys/dev/rtwn/rtl8821a/pci/r21a_pci_attach.h
sys/dev/rtwn/rtl8821a/pci/r21a_pci_compat.c
sys/dev/rtwn/rtl8821a/pci/r21ae_tx_desc.h
sys/contrib/dev/rtwn/rtwn-rtl8821aefw.fw.uu
sys/modules/rtwnfw/rtwnrtl8821ae/Makefile"

# pciconf -l match for the supported cards.
PCI_MATCH="vendor=0x10ec device=0x(8821|8812)"

# How long to wait for a wlan interface to associate after a reload.
WLAN_WAIT_SECONDS=60

die()  { echo "ERROR: $1" >&2; exit 1; }
warn() { echo "WARNING: $1" >&2; }
info() { echo "==> $1"; }

require_root() {
	[ "$(id -u)" -eq 0 ] || die "Must run as root (or with sudo)"
}

# Set $1="$2" in $LOADER_CONF, replacing any existing setting of $1.
loader_conf_set() {
	if grep -q "^[[:space:]]*$1=" "$LOADER_CONF" 2>/dev/null; then
		sed -i '' "s|^[[:space:]]*$1=.*|$1=\"$2\"|" "$LOADER_CONF"
	else
		echo "$1=\"$2\"" >> "$LOADER_CONF"
	fi
}

# Remove every setting of $1 from $LOADER_CONF.
loader_conf_unset() {
	sed -i '' "/^[[:space:]]*$1=/d" "$LOADER_CONF"
}

# Print the value of setting $1 in file $2 without quotes, or nothing.
conf_value() {
	sed -n "s/^[[:space:]]*$1=\"\{0,1\}\([^\"]*\)\"\{0,1\}.*/\1/p" "$2" \
	    2>/dev/null | tail -n 1
}

# Print the path a loaded kernel module file was loaded from.
kld_path() {
	kldstat -v -n "$1" 2>/dev/null | sed -n 's/.*(\(.*\)).*/\1/p' | head -n 1
}

# Print __FreeBSD_version of the source tree.
src_version() {
	sed -n 's/^#define[[:space:]]*__FreeBSD_version[[:space:]]*\([0-9]*\).*/\1/p' \
	    "$SRCDIR/sys/sys/param.h" 2>/dev/null
}

# Print the pciconf -l line of the first supported card.
rtwn_card() {
	pciconf -l 2>/dev/null | grep -E "$PCI_MATCH" | head -n 1
}

# Print the wlan interfaces on the supported card that are up.
rtwn_wlans_up() {
	card_dev="$(rtwn_card | cut -d@ -f1)"
	case "$card_dev" in
	rtwn*)
		;;
	*)
		return 0
		;;
	esac
	for ifn in $(ifconfig -g wlan 2>/dev/null); do
		if ifconfig "$ifn" 2>/dev/null |
		    grep -q "parent interface: $card_dev\$" &&
		    ifconfig "$ifn" 2>/dev/null | grep -q '<UP'; then
			echo "$ifn"
		fi
	done
}

# Modules must be built from the source of the running kernel, or they
# may fail to load or misbehave once loaded.
check_src_version() {
	src="$(src_version)"
	kernel="$(uname -K)"
	[ -n "$src" ] ||
	    die "cannot read __FreeBSD_version from $SRCDIR/sys/sys/param.h"
	if [ "$src" != "$kernel" ]; then
		die "the source tree at $SRCDIR is version $src but the running kernel is $kernel; install the source matching 'freebsd-version -k' and try again"
	fi
}

# The overlay's attach function, together with the tree's PCI and core
# code, must set every per-chip hook the target rtwn(4) declares: a hook
# nobody sets is a NULL call at attach time.  Every member the overlay
# assigns must exist in the target, or the module does not compile.
check_rtwn_hooks() {
	rtwnvar="$SRCDIR/sys/dev/rtwn/if_rtwnvar.h"
	ours="$REPODIR/sys/dev/rtwn/rtl8821a/pci/r21a_pci_attach.c"
	set_hooks="$(cat "$ours" "$SRCDIR/sys/dev/rtwn/pci/rtwn_pci_attach.c" \
	    "$SRCDIR/sys/dev/rtwn/if_rtwn.c" |
	    grep -o -E 'sc_[a-z0-9_]+[[:space:]]*=[^=]' |
	    grep -o -E 'sc_[a-z0-9_]+' | sort -u)"

	unset_hooks=""
	for hook in $(grep -o -E '\(\*sc_[a-z0-9_]+\)' "$rtwnvar" |
	    tr -d '(*)' | sort -u); do
		if ! echo "$set_hooks" | grep -qx "$hook"; then
			unset_hooks="$unset_hooks $hook"
		fi
	done
	if [ -n "$unset_hooks" ]; then
		die "rtwn(4) in $SRCDIR has driver hooks this overlay does not set:$unset_hooks; the module would crash while attaching. This FreeBSD version is newer than the overlay supports (see README)."
	fi

	unknown_members=""
	for member in $(grep -o -E 'sc->sc_[a-z0-9_]+[[:space:]]*=[^=]' "$ours" |
	    grep -o -E 'sc_[a-z0-9_]+' | sort -u); do
		if ! grep -qw "$member" "$rtwnvar"; then
			unknown_members="$unknown_members $member"
		fi
	done
	if [ -n "$unknown_members" ]; then
		die "rtwn(4) in $SRCDIR lacks members this overlay sets:$unknown_members; the module would not compile. This FreeBSD version is older than the overlay supports (see README)."
	fi
}

# Save the upstream files the install overwrites, once, so --uninstall can
# put them back.  A file that already matches ours was overwritten by an
# earlier install, so its upstream version is unknown.
save_replaced_files() {
	for f in $REPLACED_FILES; do
		if [ -e "$SRC_SAVED_DIR/$f" ]; then
			continue
		fi
		if cmp -s "$REPODIR/$f" "$SRCDIR/$f"; then
			warn "$SRCDIR/$f already holds the overlay version; no upstream copy saved"
			continue
		fi
		mkdir -p "$SRC_SAVED_DIR/$(dirname "$f")"
		cp -p "$SRCDIR/$f" "$SRC_SAVED_DIR/$f"
	done
	echo "$SRCDIR" > "$STATE_DIR/srcdir"
}

write_build_info() {
	{
		echo "kernel_version=\"$(uname -K)\""
		echo "src_version=\"$(src_version)\""
		echo "srcdir=\"$SRCDIR\""
		echo "built=\"$(date '+%F %T')\""
		echo "commit=\"$(git -C "$REPODIR" rev-parse --short HEAD 2>/dev/null || true)\""
	} > "$BUILD_INFO"
}

# A driver reload destroys the wlan interfaces on it.  devd recreates them
# from rc.conf, but the static default route through them is gone.
restore_wlans() {
	for ifn in "$@"; do
		waited=0
		while ! ifconfig "$ifn" 2>/dev/null | grep -q 'status: associated'; do
			if [ "$waited" -ge "$WLAN_WAIT_SECONDS" ]; then
				warn "$ifn did not associate within $WLAN_WAIT_SECONDS seconds"
				break
			fi
			sleep 2
			waited=$((waited + 2))
		done
	done
	gateway="$(sysrc -n defaultrouter 2>/dev/null || true)"
	if [ -n "$gateway" ] && [ "$gateway" != "NO" ] &&
	    ! route -n get default > /dev/null 2>&1; then
		info "Restoring the default route via $gateway"
		route -n add default "$gateway" > /dev/null ||
		    warn "could not restore the default route via $gateway"
	fi
}

# ============================================================
# --check: report the installed state
# ============================================================

do_check() {
	problems=0
	kernel="$(uname -K)"
	echo "RTL8821AE WiFi driver status"
	echo "  running kernel:    $(freebsd-version -k) ($kernel)"

	if [ -r "$BUILD_INFO" ]; then
		built_for="$(conf_value kernel_version "$BUILD_INFO")"
		echo "  modules built for: $built_for on $(conf_value built "$BUILD_INFO")"
		if [ "$built_for" != "$kernel" ]; then
			echo "  PROBLEM: the kernel changed since the modules were built; rerun install.sh"
			problems=$((problems + 1))
		fi
	else
		echo "  modules built for: unknown (no $BUILD_INFO)"
	fi

	card="$(rtwn_card)"
	case "$card" in
	"")
		echo "  card:              no RTL8821AE/RTL8812AE found"
		problems=$((problems + 1))
		;;
	rtwn*)
		echo "  card:              $(echo "$card" | cut -d: -f1-4) (driver attached)"
		;;
	*)
		echo "  card:              $(echo "$card" | cut -d: -f1-4) (no driver attached)"
		problems=$((problems + 1))
		;;
	esac

	for kmod in $KMODS; do
		loaded="$(kld_path "$kmod")"
		if [ "$loaded" = "$KMODDIR/$kmod.ko" ]; then
			echo "  $kmod: loaded from $loaded"
		elif [ -n "$loaded" ]; then
			echo "  $kmod: loaded from $loaded"
			echo "  PROBLEM: expected $KMODDIR/$kmod.ko"
			problems=$((problems + 1))
		else
			echo "  $kmod: not loaded"
			problems=$((problems + 1))
		fi
	done

	echo "  $LOADER_CONF:"
	for key in $LOADER_KEYS; do
		value="$(conf_value "$key" "$LOADER_CONF")"
		echo "    $key=${value:-(not set)}"
		case "$key" in
		*_load)
			expected="YES"
			;;
		*_name)
			expected="$KMODDIR/${key%_name}.ko"
			;;
		esac
		if [ "$value" != "$expected" ]; then
			echo "  PROBLEM: expected $key=\"$expected\""
			problems=$((problems + 1))
		fi
	done

	for ifn in $(rtwn_wlans_up); do
		echo "  $ifn: $(ifconfig "$ifn" | sed -n 's/^[[:space:]]*status: //p')"
	done

	echo ""
	if [ "$problems" -eq 0 ]; then
		echo "No problems found."
		return 0
	fi
	echo "$problems problem(s) found."
	return 1
}

# ============================================================
# --uninstall: undo the WiFi driver install
# ============================================================

do_uninstall() {
	require_root
	aside="$STATE_DIR/uninstalled-$(date +%Y%m%d-%H%M%S)"
	mkdir -p "$aside"

	info "Restoring the module settings in $LOADER_CONF"
	for key in $LOADER_KEYS; do
		if grep -q "^[[:space:]]*$key=" "$LOADER_CONF_SAVED" 2>/dev/null; then
			loader_conf_set "$key" "$(conf_value "$key" "$LOADER_CONF_SAVED")"
		else
			loader_conf_unset "$key"
		fi
	done

	info "Moving the installed modules to $aside"
	for kmod in $KMODS; do
		if [ -e "$KMODDIR/$kmod.ko" ]; then
			mv "$KMODDIR/$kmod.ko" "$aside/"
		fi
	done
	kldxref "$KMODDIR"

	srcdir="$(cat "$STATE_DIR/srcdir" 2>/dev/null || echo "$SRCDIR")"
	info "Restoring the upstream source files in $srcdir"
	for f in $ADDED_FILES; do
		if [ -e "$srcdir/$f" ]; then
			mkdir -p "$aside/src/$(dirname "$f")"
			mv "$srcdir/$f" "$aside/src/$f"
		fi
	done
	for f in $REPLACED_FILES; do
		if [ -e "$SRC_SAVED_DIR/$f" ]; then
			mkdir -p "$aside/src/$(dirname "$f")"
			mv "$srcdir/$f" "$aside/src/$f"
			cp -p "$SRC_SAVED_DIR/$f" "$srcdir/$f"
		else
			warn "no saved upstream copy of $f; $srcdir/$f still holds the overlay version"
		fi
	done
	if [ -e "$BUILD_INFO" ]; then
		mv "$BUILD_INFO" "$aside/"
	fi

	echo ""
	echo "Done.  Reboot to finish: the stock driver then loads and the"
	echo "RTL8821AE/RTL8812AE stays unattached.  The removed files are in"
	echo "$aside."
}

case "$MODE" in
check)
	do_check
	exit $?
	;;
uninstall)
	do_uninstall
	exit 0
	;;
esac

# --- Checks that change nothing ---
if [ "$DO_WIFI" -eq 1 ]; then
	[ -d "$SRCDIR/sys/dev/rtwn" ] || die "FreeBSD source tree not found at $SRCDIR"
	check_src_version
	check_rtwn_hooks
	if [ -z "$(rtwn_card)" ]; then
		warn "no RTL8821AE/RTL8812AE card found; installing anyway"
	fi
fi

require_root

info "Installing RTL8821AE/RTL8812AE driver into $SRCDIR"

NEED_REBOOT=0

# ============================================================
# WiFi Driver Installation
# ============================================================

if [ "$DO_WIFI" -eq 1 ]; then
	info "--- WiFi Driver Installation ---"
	mkdir -p "$STATE_DIR"

	# --- Save the upstream files about to be overwritten ---
	save_replaced_files

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

	# --- Check the build before installing it ---
	BUILT="$(make -C "$SRCDIR/sys/modules/rtwn_pci" -V .OBJDIR)/if_rtwn_pci.ko"
	strings "$BUILT" | grep -q 'RTL8821AE' ||
	    die "$BUILT has no RTL8821AE support; nothing was installed"

	# --- Install ---
	info "Installing WiFi kernel modules into $KMODDIR"
	make -C "$SRCDIR/sys/modules/rtwn_pci" install KMODDIR="$KMODDIR"
	make -C "$SRCDIR/sys/modules/rtwnfw/rtwnrtl8821ae" install KMODDIR="$KMODDIR"
	write_build_info

	# --- Boot configuration ---
	# Without the _name settings the loader picks the stock module.
	info "Configuring $LOADER_CONF to load the modules from $KMODDIR"
	if [ -f "$LOADER_CONF" ] && [ ! -f "$LOADER_CONF_SAVED" ]; then
		cp -p "$LOADER_CONF" "$LOADER_CONF_SAVED"
	fi
	loader_conf_set rtwn-rtl8821aefw_load "YES"
	loader_conf_set rtwn-rtl8821aefw_name "$KMODDIR/rtwn-rtl8821aefw.ko"
	loader_conf_set if_rtwn_pci_load "YES"
	loader_conf_set if_rtwn_pci_name "$KMODDIR/if_rtwn_pci.ko"

	# --- Load ---
	# Reloading the driver takes down every wlan interface on it, which
	# cuts off a machine reached over that link, so that needs --reload.
	# Load by path: "kldload if_rtwn_pci" would load the stock module.
	# A module that is still loaded after the unload could not be
	# unloaded, so the new one only takes effect at the next boot.  Any
	# other load failure would also happen at boot, so it stops the install.
	WLANS_UP="$(echo $(rtwn_wlans_up))"
	if [ -n "$WLANS_UP" ] && [ "$DO_RELOAD" -eq 0 ]; then
		info "Not reloading the driver now: $WLANS_UP is up on it (--reload reloads anyway)"
		NEED_REBOOT=1
	else
		if [ -n "$WLANS_UP" ]; then
			info "--reload: $WLANS_UP goes down while the driver reloads"
		fi
		info "Loading WiFi modules from $KMODDIR"
		kldunload if_rtwn_pci 2>/dev/null || true
		kldunload rtwn-rtl8821aefw 2>/dev/null || true
		for KMOD in $KMODS; do
			if kldstat -q -n "$KMOD"; then
				warn "$KMOD is still loaded from '$(kld_path "$KMOD")'; reboot to use the new module"
				NEED_REBOOT=1
			else
				kldload "$KMODDIR/$KMOD.ko" ||
				    die "cannot load $KMODDIR/$KMOD.ko (see dmesg)"
				info "$KMOD loaded from $(kld_path "$KMOD")"
			fi
		done
		if [ -n "$WLANS_UP" ]; then
			restore_wlans $WLANS_UP
		fi
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
	if [ "$NEED_REBOOT" -eq 1 ]; then
		echo ""
		echo "Reboot to activate the new driver."
	fi
	echo ""
	echo "Check the result (also after every FreeBSD upgrade):"
	echo "  sh install.sh --check"
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
