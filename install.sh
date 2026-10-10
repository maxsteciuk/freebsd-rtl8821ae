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

# --check and --uninstall are whole operations of their own: reject a
# second one, and any install argument alongside them, rather than let the
# order of the arguments decide what runs.
MODE_ARG=""
INSTALL_ARGS=""
for arg in "$@"; do
	case "$arg" in
		--wifi)      DO_WIFI=1; INSTALL_ARGS="$INSTALL_ARGS $arg" ;;
		--bluetooth) DO_BT=1; INSTALL_ARGS="$INSTALL_ARGS $arg" ;;
		--all)       DO_WIFI=1; DO_BT=1; INSTALL_ARGS="$INSTALL_ARGS $arg" ;;
		--reload)    DO_RELOAD=1; INSTALL_ARGS="$INSTALL_ARGS $arg" ;;
		--check|--uninstall)
			if [ -n "$MODE_ARG" ] && [ "$MODE_ARG" != "$arg" ]; then
				echo "ERROR: $MODE_ARG and $arg cannot be combined" >&2
				exit 2
			fi
			MODE_ARG="$arg"
			MODE="${arg#--}"
			;;
		--help|-h)   usage; exit 0 ;;
		-*)          usage >&2; exit 2 ;;
		*)           SRCDIR="$arg"; INSTALL_ARGS="$INSTALL_ARGS $arg" ;;
	esac
done
if [ -n "$MODE_ARG" ] && [ -n "$INSTALL_ARGS" ]; then
	echo "ERROR: $MODE_ARG takes no other arguments (got:$INSTALL_ARGS)" >&2
	exit 2
fi

# Default: WiFi only (backward compatible)
if [ "$DO_WIFI" -eq 0 ] && [ "$DO_BT" -eq 0 ]; then
	DO_WIFI=1
fi

SRCDIR="${SRCDIR:-/usr/src}"
# One spelling per tree, so a recorded install is recognised however the
# path is written (trailing slash, symlink).
SRCDIR="$(realpath "$SRCDIR" 2>/dev/null || echo "$SRCDIR")"
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
MANIFEST="$STATE_DIR/installed-files"
MODULES_MANIFEST="$STATE_DIR/installed-modules"
MODULES_SAVED_DIR="$STATE_DIR/modules-orig"
STATUS="$STATE_DIR/status"

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

# Remove every setting of $1 from $LOADER_CONF; without the file there is
# nothing to remove.
loader_conf_unset() {
	if [ -f "$LOADER_CONF" ]; then
		sed -i '' "/^[[:space:]]*$1=/d" "$LOADER_CONF"
	fi
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

# Print __FreeBSD_version of the source tree, or nothing if it cannot be
# read.  Always succeeds, so callers under set -e reach their own check.
src_version() {
	sed -n 's/^#define[[:space:]]*__FreeBSD_version[[:space:]]*\([0-9]*\).*/\1/p' \
	    "$SRCDIR/sys/sys/param.h" 2>/dev/null || true
}

# Print the pciconf -l line of the first supported card.
rtwn_card() {
	pciconf -l 2>/dev/null | grep -E "$PCI_MATCH" | head -n 1
}

# Print the PCI devices attached to rtwn(4).  Reloading if_rtwn_pci
# detaches all of them, not only the RTL8821AE/RTL8812AE.
rtwn_pci_devs() {
	pciconf -l 2>/dev/null | sed -n 's/^\(rtwn[0-9][0-9]*\)@.*/\1/p'
}

# Print the wlan interfaces that are up on a PCI rtwn(4) device.
rtwn_wlans_up() {
	devs="$(rtwn_pci_devs)"
	for ifn in $(ifconfig -g wlan 2>/dev/null); do
		parent="$(ifconfig "$ifn" 2>/dev/null |
		    sed -n 's/^[[:space:]]*parent interface: //p')"
		if [ -n "$parent" ] && echo "$devs" | grep -qx "$parent" &&
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
	[ -r "$ours" ] ||
	    die "$ours not found; run install.sh from the repository it came with"
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

# Save the upstream files the install overwrites, per source version, so
# --uninstall can put back copies that match the tree it restores into.
# A file that matches ours still holds an earlier install, so the saved
# copy (if any) is kept.  Otherwise the file holds upstream content, which
# may be newer than the saved copy even when __FreeBSD_version did not
# change (for example a security update), so the saved copy is refreshed
# and the old one moved aside.
save_replaced_files() {
	saved="$SRC_SAVED_DIR/$(src_version)"
	for f in $REPLACED_FILES; do
		# Ours: this repository's version, or any version this installer
		# recorded (an older overlay, before the repository was updated).
		if cmp -s "$REPODIR/$f" "$SRCDIR/$f" || installed_unchanged "$f"; then
			if [ ! -e "$saved/$f" ]; then
				warn "$SRCDIR/$f already holds the overlay version; no upstream copy saved"
			fi
			continue
		fi
		if [ -e "$saved/$f" ]; then
			if cmp -s "$saved/$f" "$SRCDIR/$f"; then
				continue
			fi
			mv "$saved/$f" "$saved/$f.superseded-$(date +%Y%m%d-%H%M%S)"
		fi
		mkdir -p "$saved/$(dirname "$f")"
		cp -p "$SRCDIR/$f" "$saved/$f"
	done
}

# Start an install transaction, before the first change.  For a fresh
# install, snapshot loader.conf (moving an older snapshot aside) and start
# an empty list of written source files; a reinstall keeps the snapshot
# and entries of the install already recorded until they are replaced.
# Record the target tree and that the install is pending.  Source files
# and modules are recorded as each is written, so a failed install can be
# undone with --uninstall, which only touches files this install wrote.
begin_install() {
	mkdir -p "$STATE_DIR"
	if [ ! -e "$STATE_DIR/srcdir" ]; then
		if [ -e "$LOADER_CONF_SAVED" ]; then
			mv "$LOADER_CONF_SAVED" "$LOADER_CONF_SAVED.$(date +%Y%m%d-%H%M%S)"
		fi
		if [ -f "$LOADER_CONF" ]; then
			cp -p "$LOADER_CONF" "$LOADER_CONF_SAVED"
		fi
		if [ -e "$MANIFEST" ]; then
			mv "$MANIFEST" "$MANIFEST.$(date +%Y%m%d-%H%M%S)"
		fi
		: > "$MANIFEST"
		if [ -e "$MODULES_MANIFEST" ]; then
			mv "$MODULES_MANIFEST" "$MODULES_MANIFEST.$(date +%Y%m%d-%H%M%S)"
		fi
		if [ -e "$MODULES_SAVED_DIR" ]; then
			mv "$MODULES_SAVED_DIR" "$MODULES_SAVED_DIR.$(date +%Y%m%d-%H%M%S)"
		fi
	fi
	echo "pending" > "$STATUS"
	echo "$SRCDIR" > "$STATE_DIR/srcdir"
}

# Add the checksum of file $3 to the entries for $2 in checksum list $1.
# Every checksum ever recorded for a path stays valid, so a file is
# recognised as this installer's whether or not the rename that follows
# its recording happened.
record_entry() {
	line="$2 $(sha256 -q "$3")"
	if ! grep -qxF "$line" "$1" 2>/dev/null; then
		echo "$line" >> "$1"
	fi
}

# Copy source file $1 from the repository into the tree, keeping the
# entries of files not yet replaced, so --uninstall touches every file this
# install wrote, and only those, even if a later step fails.  The copy is
# staged beside the destination and recorded before it is renamed into
# place, so a file is never changed under its real name before it is
# recorded.
install_source_file() {
	mkdir -p "$SRCDIR/$(dirname "$1")"
	cp "$REPODIR/$1" "$SRCDIR/$1.rtl8821ae-new"
	record_entry "$MANIFEST" "$1" "$SRCDIR/$1.rtl8821ae-new"
	mv "$SRCDIR/$1.rtl8821ae-new" "$SRCDIR/$1"
}

# Before the modules are installed, save any module file already in their
# place that this install did not put there (an earlier manual install,
# for example), so --uninstall can put it back.
save_existing_modules() {
	for kmod in $KMODS; do
		if [ -e "$KMODDIR/$kmod.ko" ] && ! module_unchanged "$kmod" &&
		    [ ! -e "$MODULES_SAVED_DIR/$kmod.ko" ]; then
			mkdir -p "$MODULES_SAVED_DIR"
			cp -p "$KMODDIR/$kmod.ko" "$MODULES_SAVED_DIR/$kmod.ko"
		fi
	done
}

# Install module $1, built in module directory $2, the same way: stage it
# beside its destination with the owner and mode make install would use,
# record it, then rename it into place.  kldxref ignores the staged name,
# whose last suffix is not .ko, so a leftover can never be loaded.
install_module() {
	built="$(make -C "$2" -V .OBJDIR)/$1.ko"
	mkdir -p "$KMODDIR"
	install -o root -g wheel -m 444 "$built" "$KMODDIR/$1.ko.rtl8821ae-new"
	record_entry "$MODULES_MANIFEST" "$1" "$KMODDIR/$1.ko.rtl8821ae-new"
	mv "$KMODDIR/$1.ko.rtl8821ae-new" "$KMODDIR/$1.ko"
}

finish_install() {
	echo "complete" > "$STATUS"
}

# Without the _name settings the loader picks the stock module.
configure_loader() {
	loader_conf_set rtwn-rtl8821aefw_load "YES"
	loader_conf_set rtwn-rtl8821aefw_name "$KMODDIR/rtwn-rtl8821aefw.ko"
	loader_conf_set if_rtwn_pci_load "YES"
	loader_conf_set if_rtwn_pci_name "$KMODDIR/if_rtwn_pci.ko"
}

# Succeed if source file $1 still holds something this installer wrote.
installed_unchanged() {
	[ -e "$SRCDIR/$1" ] &&
	    grep -qxF "$1 $(sha256 -q "$SRCDIR/$1")" "$MANIFEST" 2>/dev/null
}

# Succeed if module $1 is still one this installer placed.
module_unchanged() {
	[ -e "$KMODDIR/$1.ko" ] &&
	    grep -qxF "$1 $(sha256 -q "$KMODDIR/$1.ko")" "$MODULES_MANIFEST" 2>/dev/null
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
		echo "  PROBLEM: cannot tell whether the modules match the kernel; rerun install.sh"
		problems=$((problems + 1))
	fi
	status="$(cat "$STATUS" 2>/dev/null || true)"
	case "$status" in
	complete)
		# Without these records --uninstall refuses or cannot restore.
		for record in "$STATE_DIR/srcdir" "$MANIFEST" "$MODULES_MANIFEST"; do
			if [ ! -s "$record" ]; then
				echo "  PROBLEM: $record is missing or empty; rerun install.sh"
				problems=$((problems + 1))
			fi
		done
		;;
	pending)
		echo "  PROBLEM: an install did not complete; rerun install.sh or run --uninstall"
		problems=$((problems + 1))
		;;
	*)
		echo "  PROBLEM: no completed install is recorded; rerun install.sh"
		problems=$((problems + 1))
		;;
	esac

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
		# kldstat remembers the path a module was loaded from, even if the
		# file was replaced or removed since; the next boot loads the file.
		if ! module_unchanged "$kmod"; then
			echo "  PROBLEM: $KMODDIR/$kmod.ko is missing or not the module this install placed"
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
	# Only undo an install this script recorded: without the record there
	# is no telling which settings and files are ours.
	[ -r "$STATE_DIR/srcdir" ] ||
	    die "no install by this script is recorded in $STATE_DIR; nothing changed"
	require_root
	SRCDIR="$(cat "$STATE_DIR/srcdir")"
	# Read before changing anything, so a missing source tree cannot stop
	# the uninstall halfway.
	src_ver="$(src_version)"
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
		if module_unchanged "$kmod"; then
			mv "$KMODDIR/$kmod.ko" "$aside/"
			if [ -e "$MODULES_SAVED_DIR/$kmod.ko" ]; then
				cp -p "$MODULES_SAVED_DIR/$kmod.ko" "$KMODDIR/$kmod.ko"
				info "Put back the $kmod.ko that was there before the install"
			fi
		elif [ -e "$KMODDIR/$kmod.ko" ]; then
			warn "$KMODDIR/$kmod.ko was not placed by this install or changed since; left in place"
		fi
	done
	if [ -e "$MODULES_SAVED_DIR" ]; then
		mv "$MODULES_SAVED_DIR" "$aside/"
	fi
	# Best effort: a failure here must not leave the uninstall half done.
	kldxref "$KMODDIR" || warn "kldxref $KMODDIR failed; run it by hand"

	# Restore only copies saved from the tree's current source version;
	# copies from an older version would downgrade the upgraded tree.
	# A file that does not hold what the install wrote was never copied (a
	# failed install) or was updated or
	# edited since, so it is left alone.
	if [ -z "$src_ver" ]; then
		warn "cannot read the source version in $SRCDIR; its source files are left as they are"
	elif [ ! -r "$MANIFEST" ]; then
		warn "no record of the installed source files; $SRCDIR is left as it is"
	else
		saved="$SRC_SAVED_DIR/$src_ver"
		info "Restoring the upstream source files in $SRCDIR"
		for f in $ADDED_FILES; do
			if installed_unchanged "$f"; then
				mkdir -p "$aside/src/$(dirname "$f")"
				mv "$SRCDIR/$f" "$aside/src/$f"
			elif [ -e "$SRCDIR/$f" ]; then
				warn "$SRCDIR/$f does not hold what this install wrote; left in place"
			fi
		done
		for f in $REPLACED_FILES; do
			if ! installed_unchanged "$f"; then
				warn "$SRCDIR/$f does not hold what this install wrote; left in place"
			elif [ -e "$saved/$f" ]; then
				mkdir -p "$aside/src/$(dirname "$f")"
				mv "$SRCDIR/$f" "$aside/src/$f"
				cp -p "$saved/$f" "$SRCDIR/$f"
			else
				warn "no saved upstream copy of $f for source version $src_ver; $SRCDIR/$f still holds the overlay version"
			fi
		done
		mv "$MANIFEST" "$aside/"
	fi
	for state in "$BUILD_INFO" "$MODULES_MANIFEST" "$STATUS"; do
		if [ -e "$state" ]; then
			mv "$state" "$aside/"
		fi
	done
	mv "$STATE_DIR/srcdir" "$aside/"

	echo ""
	echo "Done.  Reboot to finish: the boot configuration and modules from"
	echo "before the install then apply.  The removed files are in"
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
	# One recorded install at a time: installing into a second tree would
	# lose the record needed to undo the first.
	recorded_srcdir="$(cat "$STATE_DIR/srcdir" 2>/dev/null || true)"
	if [ -n "$recorded_srcdir" ] && [ "$recorded_srcdir" != "$SRCDIR" ]; then
		die "an install into $recorded_srcdir is recorded; run --uninstall before installing into $SRCDIR"
	fi
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
	begin_install

	# --- Copy new driver files ---
	info "Copying driver source files"
	install_source_file sys/dev/rtwn/rtl8821a/pci/r21a_pci_attach.c
	install_source_file sys/dev/rtwn/rtl8821a/pci/r21a_pci_attach.h
	install_source_file sys/dev/rtwn/rtl8821a/pci/r21a_pci_compat.c
	install_source_file sys/dev/rtwn/rtl8821a/pci/r21ae_tx_desc.h

	# --- Copy modified PCI attach header ---
	info "Updating rtwn_pci_attach.h (adds RTL8821AE/RTL8812AE device IDs)"
	install_source_file sys/dev/rtwn/pci/rtwn_pci_attach.h

	# --- Copy firmware ---
	info "Installing WiFi firmware"
	install_source_file sys/contrib/dev/rtwn/rtwn-rtl8821aefw.fw.uu

	# --- Copy Makefiles ---
	info "Updating Makefiles"
	install_source_file sys/modules/rtwn_pci/Makefile
	install_source_file sys/modules/rtwnfw/rtwnrtl8821ae/Makefile
	install_source_file sys/modules/rtwnfw/Makefile

	# --- Build ---
	info "Building if_rtwn_pci kernel module"
	make -C "$SRCDIR/sys/modules/rtwn_pci" clean all

	info "Building rtwn-rtl8821aefw firmware module"
	make -C "$SRCDIR/sys/modules/rtwnfw/rtwnrtl8821ae" clean all

	# --- Check the build before installing it ---
	BUILT="$(make -C "$SRCDIR/sys/modules/rtwn_pci" -V .OBJDIR)/if_rtwn_pci.ko"
	strings "$BUILT" | grep -q 'RTL8821AE' ||
	    die "$BUILT has no RTL8821AE support; no kernel modules were installed, but the source tree was changed: run 'sh install.sh --uninstall' to undo that"

	# --- Install ---
	info "Installing WiFi kernel modules into $KMODDIR"
	save_existing_modules
	install_module if_rtwn_pci "$SRCDIR/sys/modules/rtwn_pci"
	install_module rtwn-rtl8821aefw "$SRCDIR/sys/modules/rtwnfw/rtwnrtl8821ae"
	kldxref "$KMODDIR"
	write_build_info

	# --- Boot configuration ---
	info "Configuring $LOADER_CONF to load the modules from $KMODDIR"
	configure_loader
	finish_install

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
