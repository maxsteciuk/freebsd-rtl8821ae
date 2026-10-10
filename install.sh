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
# The source tree is never modified: the modules are built from a private
# view of it in /var/db/rtl8821ae/build, made of links to the source tree
# with this repository's files in place of the ones it changes.  The
# modules are then installed into /boot/modules and /boot/loader.conf is
# configured to load them from there at boot.

set -e

# The state files must stay readable for --check run as a normal user,
# whatever umask root has; they stay writable only by root.
umask 022

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
		*)
			# One source tree: a second path would otherwise silently
			# replace the first.
			if [ -z "$arg" ] || [ -n "$SRCDIR" ]; then
				echo "ERROR: give exactly one source tree path (got '$SRCDIR' and '$arg')" >&2
				exit 2
			fi
			SRCDIR="$arg"
			INSTALL_ARGS="$INSTALL_ARGS $arg"
			;;
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

# Installer state: the source tree an install was built from, what the
# modules were built for, the modules it placed and the ones it found in
# their place, the build view, and what --uninstall moved aside.
STATE_DIR="/var/db/rtl8821ae"
BUILD_INFO="$STATE_DIR/build-info"
BUILD_DIR="$STATE_DIR/build"
MODULES_MANIFEST="$STATE_DIR/installed-modules"
MODULES_SAVED_DIR="$STATE_DIR/modules-orig"
STATUS="$STATE_DIR/status"
# Present when there was no loader.conf to snapshot at install time.
LOADER_CONF_ABSENT="$STATE_DIR/loader-conf-absent"

# Installs and uninstalls run under an exclusive lock on this file, so two
# of them cannot interleave their changes to the state, loader.conf and
# /boot/modules.  The script re-runs itself under lockf(1), which fails at
# once if another run holds the lock; the variable marks the locked run.
LOCK_FILE="$STATE_DIR/lock"

# Modules in load order, and the loader.conf settings that select them.
KMODS="rtwn-rtl8821aefw if_rtwn_pci"
LOADER_KEYS="rtwn-rtl8821aefw_load rtwn-rtl8821aefw_name if_rtwn_pci_load if_rtwn_pci_name"

# This repository's files: they take the place of the same paths in the
# build view (three of them replace upstream files, the rest are new).
OVERLAY_FILES="sys/dev/rtwn/pci/rtwn_pci_attach.h
sys/dev/rtwn/rtl8821a/pci/r21a_pci_attach.c
sys/dev/rtwn/rtl8821a/pci/r21a_pci_attach.h
sys/dev/rtwn/rtl8821a/pci/r21a_pci_compat.c
sys/dev/rtwn/rtl8821a/pci/r21ae_tx_desc.h
sys/contrib/dev/rtwn/rtwn-rtl8821aefw.fw.uu
sys/modules/rtwn_pci/Makefile
sys/modules/rtwnfw/Makefile
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

# Copy file $1 to $2 through a staged copy beside $2 and a rename, so $2
# never holds a partly written file.
copy_staged() {
	cp -p "$1" "$2.rtl8821ae-new"
	mv "$2.rtl8821ae-new" "$2"
}

# Write $2 to state file $1 through a temporary file and a rename, so the
# file always holds either its old or its new content.
write_state() {
	printf '%s\n' "$2" > "$1.new"
	mv "$1.new" "$1"
}

# Move $1, if it exists, aside under a name with the current time.
move_aside() {
	if [ -e "$1" ]; then
		mv "$1" "$1.$(date +%Y%m%d-%H%M%S)"
	fi
}

# loader.conf lines are read as the loader reads them (stand/lua/config.lua):
# optional space around "=", and a value that is either quoted or a single
# word of letters, digits, "-", "_" and "."; anything after it, such as a
# comment, is not part of the value.
LOADER_WORD='[-[:alnum:]][-[:alnum:]_.]*'

# Set $1="$2" in $LOADER_CONF, replacing any existing setting of $1.
loader_conf_set() {
	if grep -q "^[[:space:]]*$1[[:space:]]*=" "$LOADER_CONF" 2>/dev/null; then
		sed -i '' "s|^[[:space:]]*$1[[:space:]]*=.*|$1=\"$2\"|" "$LOADER_CONF"
	else
		echo "$1=\"$2\"" >> "$LOADER_CONF"
	fi
}

# Remove every setting of $1 from $LOADER_CONF; without the file there is
# nothing to remove.
loader_conf_unset() {
	if [ -f "$LOADER_CONF" ]; then
		sed -i '' "/^[[:space:]]*$1[[:space:]]*=/d" "$LOADER_CONF"
	fi
}

# Print the value of setting $1 in file $2 without quotes, or nothing.
conf_value() {
	sed -n \
	    -e "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\"\([^\"]*\)\".*/\1/p" \
	    -e "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\($LOADER_WORD\).*/\1/p" \
	    "$2" 2>/dev/null | tail -n 1
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

# Make the build view in directory $1: every directory on the way to an
# overlay file is a real directory, everything else in it is a link to the
# same entry in the source tree, and the overlay files are copies of this
# repository's.  The source tree itself is only read.
make_build_view() {
	view="$1"
	dirs="."
	for f in $OVERLAY_FILES; do
		d="$(dirname "$f")"
		while [ "$d" != "." ]; do
			dirs="$dirs
$d"
			d="$(dirname "$d")"
		done
	done
	dirs="$(echo "$dirs" | sort -u)"
	for d in $dirs; do
		mkdir -p "$view/$d"
		if [ ! -d "$SRCDIR/$d" ]; then
			continue
		fi
		for entry in "$SRCDIR/$d"/*; do
			if [ ! -e "$entry" ] && [ ! -L "$entry" ]; then
				continue
			fi
			rel="${entry#"$SRCDIR"/}"
			rel="${rel#./}"
			if echo "$dirs" | grep -qxF "$rel" ||
			    echo "$OVERLAY_FILES" | grep -qxF "$rel"; then
				continue
			fi
			ln -s "$entry" "$view/$rel"
		done
	done
	for f in $OVERLAY_FILES; do
		cp "$REPODIR/$f" "$view/$f"
	done
}

# Run make in the build view.  Three things are given on the command line
# because the tree's own make files would otherwise look past the view:
# SRCTOP, which src.sys.env.mk derives from the real path of share/mk (a
# link back to the source tree), SYSDIR, and __MPATH, the list of *_if.m
# interface files, which config.mk finds with a find(1) that does not
# follow the view's links.
build_make() {
	MAKEOBJDIRPREFIX="$BUILD_DIR/obj" make \
	    SRCTOP="$BUILD_DIR/src" SYSDIR="$BUILD_DIR/src/sys" \
	    __MPATH="$VIEW_MPATH" "$@"
}

# Set VIEW_MPATH, the interface files of the build view, following its
# links.
find_view_interfaces() {
	VIEW_MPATH="$(find -L "$BUILD_DIR/src/sys/" -name '*_if.m' 2>/dev/null |
	    sort | tr '\n' ' ' || true)"
	[ -n "$VIEW_MPATH" ] ||
	    die "found no *_if.m interface files under $BUILD_DIR/src/sys"
}

# Start an install transaction, before the first change to the system.
# For a fresh install, snapshot loader.conf (moving an older snapshot
# aside) and start new module records; a reinstall keeps the snapshot and
# records of the install already recorded.  Record the source tree and
# that the install is pending: --uninstall can then undo a failed install,
# and only touches modules this installer placed.
begin_install() {
	mkdir -p "$STATE_DIR"
	chmod 755 "$STATE_DIR"
	if [ ! -e "$STATE_DIR/srcdir" ]; then
		# Stage the new snapshot before moving the old one aside.  With
		# no loader.conf, record that instead, so --uninstall can tell
		# "there was nothing" from a lost snapshot.
		if [ -f "$LOADER_CONF" ]; then
			cp -p "$LOADER_CONF" "$LOADER_CONF_SAVED.rtl8821ae-new"
		fi
		move_aside "$LOADER_CONF_SAVED"
		move_aside "$LOADER_CONF_ABSENT"
		if [ -f "$LOADER_CONF" ]; then
			mv "$LOADER_CONF_SAVED.rtl8821ae-new" "$LOADER_CONF_SAVED"
		else
			write_state "$LOADER_CONF_ABSENT" "no $LOADER_CONF before the install"
		fi
		move_aside "$MODULES_MANIFEST"
		move_aside "$MODULES_SAVED_DIR"
	fi
	write_state "$STATUS" "pending"
	write_state "$STATE_DIR/srcdir" "$SRCDIR"
}

# Add the checksum of file $3 to the entries for $2 in checksum list $1.
# Every checksum ever recorded for a name stays valid, so a module is
# recognised as this installer's whether or not the rename that follows
# its recording happened.
record_entry() {
	line="$2 $(sha256 -q "$3")"
	if ! grep -qxF "$line" "$1" 2>/dev/null; then
		echo "$line" >> "$1"
	fi
}

# Succeed if module $1 is still one this installer placed.
module_unchanged() {
	[ -e "$KMODDIR/$1.ko" ] &&
	    grep -qxF "$1 $(sha256 -q "$KMODDIR/$1.ko")" "$MODULES_MANIFEST" 2>/dev/null
}

# Before the modules are installed, save any module file already in their
# place that this installer did not put there (an earlier manual install,
# for example), so --uninstall can put it back.
save_existing_modules() {
	for kmod in $KMODS; do
		if [ -e "$KMODDIR/$kmod.ko" ] && ! module_unchanged "$kmod" &&
		    [ ! -e "$MODULES_SAVED_DIR/$kmod.ko" ]; then
			mkdir -p "$MODULES_SAVED_DIR"
			copy_staged "$KMODDIR/$kmod.ko" "$MODULES_SAVED_DIR/$kmod.ko"
		fi
	done
}

# Install module $1, built in view module directory $2: stage it beside
# its destination with the owner and mode make install would use, record
# it, then rename it into place, so a module is never replaced under its
# real name before it is recorded.  kldxref ignores the staged name, whose
# last suffix is not .ko, so a leftover can never be loaded.
install_module() {
	built="$(build_make -C "$2" -V .OBJDIR)/$1.ko"
	mkdir -p "$KMODDIR"
	install -o root -g wheel -m 444 "$built" "$KMODDIR/$1.ko.rtl8821ae-new"
	record_entry "$MODULES_MANIFEST" "$1" "$KMODDIR/$1.ko.rtl8821ae-new"
	mv "$KMODDIR/$1.ko.rtl8821ae-new" "$KMODDIR/$1.ko"
}

finish_install() {
	write_state "$STATUS" "complete"
}

# Without the _name settings the loader picks the stock module.
configure_loader() {
	loader_conf_set rtwn-rtl8821aefw_load "YES"
	loader_conf_set rtwn-rtl8821aefw_name "$KMODDIR/rtwn-rtl8821aefw.ko"
	loader_conf_set if_rtwn_pci_load "YES"
	loader_conf_set if_rtwn_pci_name "$KMODDIR/if_rtwn_pci.ko"
}

write_build_info() {
	{
		echo "kernel_version=\"$(uname -K)\""
		echo "src_version=\"$(src_version)\""
		echo "srcdir=\"$SRCDIR\""
		echo "built=\"$(date '+%F %T')\""
		echo "commit=\"$(git -C "$REPODIR" rev-parse --short HEAD 2>/dev/null || true)\""
	} > "$BUILD_INFO.new"
	mv "$BUILD_INFO.new" "$BUILD_INFO"
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
		for record in "$STATE_DIR/srcdir" "$MODULES_MANIFEST"; do
			if [ ! -s "$record" ]; then
				echo "  PROBLEM: $record is missing or empty; rerun install.sh"
				problems=$((problems + 1))
			fi
		done
		if [ ! -r "$LOADER_CONF_SAVED" ] && [ ! -e "$LOADER_CONF_ABSENT" ]; then
			echo "  PROBLEM: the loader.conf snapshot $LOADER_CONF_SAVED is missing; --uninstall cannot restore the module settings"
			problems=$((problems + 1))
		fi
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
	# is no telling which settings and modules are ours.
	[ -r "$STATE_DIR/srcdir" ] ||
	    die "no install by this script is recorded in $STATE_DIR; nothing changed"
	# Everything the restore relies on must be there before anything
	# changes; otherwise refuse, so the state survives for a later retry.
	if [ ! -r "$LOADER_CONF_SAVED" ] && [ ! -e "$LOADER_CONF_ABSENT" ]; then
		die "the loader.conf snapshot $LOADER_CONF_SAVED is missing or unreadable, so the module settings cannot be restored; nothing changed"
	fi
	if [ "$(cat "$STATUS" 2>/dev/null || true)" = "complete" ] &&
	    [ ! -s "$MODULES_MANIFEST" ]; then
		die "the record of installed modules $MODULES_MANIFEST is missing or empty, so they cannot be told apart from other modules; nothing changed"
	fi
	require_root
	aside="$STATE_DIR/uninstalled-$(date +%Y%m%d-%H%M%S)"
	mkdir -p "$aside"

	# Put back the snapshot's own lines for each setting that differs from
	# it, verbatim, so their quoting, spacing and comments come back exactly
	# as they were; a setting that already matches is left untouched.
	info "Restoring the module settings in $LOADER_CONF"
	for key in $LOADER_KEYS; do
		pattern="^[[:space:]]*$key[[:space:]]*="
		current="$(grep "$pattern" "$LOADER_CONF" 2>/dev/null || true)"
		before="$(grep "$pattern" "$LOADER_CONF_SAVED" 2>/dev/null || true)"
		if [ "$current" != "$before" ]; then
			loader_conf_unset "$key"
			if [ -n "$before" ]; then
				printf '%s\n' "$before" >> "$LOADER_CONF"
			fi
		fi
	done

	info "Moving the installed modules to $aside"
	for kmod in $KMODS; do
		if module_unchanged "$kmod"; then
			if [ -e "$MODULES_SAVED_DIR/$kmod.ko" ]; then
				# Copy ours aside, then swap the earlier module in
				# through a staged copy: the path never goes missing,
				# and a failed copy leaves ours in place for a retry.
				cp -p "$KMODDIR/$kmod.ko" "$aside/"
				copy_staged "$MODULES_SAVED_DIR/$kmod.ko" "$KMODDIR/$kmod.ko"
				info "Put back the $kmod.ko that was there before the install"
			else
				mv "$KMODDIR/$kmod.ko" "$aside/"
			fi
		elif [ -e "$KMODDIR/$kmod.ko" ]; then
			warn "$KMODDIR/$kmod.ko was not placed by this install or changed since; left in place"
		fi
	done
	# Best effort: a failure here must not leave the uninstall half done.
	kldxref "$KMODDIR" || warn "kldxref $KMODDIR failed; run it by hand"

	for state in "$MODULES_SAVED_DIR" "$BUILD_DIR" "$BUILD_INFO" \
	    "$MODULES_MANIFEST" "$LOADER_CONF_ABSENT" "$STATUS"; do
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
	[ -r "$STATE_DIR/srcdir" ] ||
	    die "no install by this script is recorded in $STATE_DIR; nothing changed"
	require_root
	if [ -z "$RTL8821AE_INSTALL_LOCKED" ]; then
		export RTL8821AE_INSTALL_LOCKED=1
		exec lockf -k -t 0 "$LOCK_FILE" /bin/sh "$0" "$@"
	fi
	do_uninstall
	exit 0
	;;
esac

# --- Checks that change nothing ---
if [ "$DO_WIFI" -eq 1 ]; then
	[ -d "$SRCDIR/sys/dev/rtwn" ] || die "FreeBSD source tree not found at $SRCDIR"
	check_src_version
	check_rtwn_hooks
	# One recorded install at a time: installing from a second tree would
	# lose the record of which tree the installed modules came from.
	recorded_srcdir="$(cat "$STATE_DIR/srcdir" 2>/dev/null || true)"
	if [ -n "$recorded_srcdir" ] && [ "$recorded_srcdir" != "$SRCDIR" ]; then
		die "an install from $recorded_srcdir is recorded; run --uninstall before installing from $SRCDIR"
	fi
	if [ -z "$(rtwn_card)" ]; then
		warn "no RTL8821AE/RTL8812AE card found; installing anyway"
	fi
fi

require_root
if [ -z "$RTL8821AE_INSTALL_LOCKED" ]; then
	mkdir -p "$STATE_DIR"
	chmod 755 "$STATE_DIR"
	export RTL8821AE_INSTALL_LOCKED=1
	exec lockf -k -t 0 "$LOCK_FILE" /bin/sh "$0" "$@"
fi

info "Installing RTL8821AE/RTL8812AE driver from $SRCDIR"

NEED_REBOOT=0

# ============================================================
# WiFi Driver Installation
# ============================================================

if [ "$DO_WIFI" -eq 1 ]; then
	info "--- WiFi Driver Installation ---"
	mkdir -p "$STATE_DIR"

	# --- Build, from a private view of the source tree ---
	info "Preparing the build view in $BUILD_DIR (the source tree is not changed)"
	move_aside "$BUILD_DIR"
	make_build_view "$BUILD_DIR/src"
	find_view_interfaces

	info "Building if_rtwn_pci kernel module"
	build_make -C "$BUILD_DIR/src/sys/modules/rtwn_pci" clean all

	info "Building rtwn-rtl8821aefw firmware module"
	build_make -C "$BUILD_DIR/src/sys/modules/rtwnfw/rtwnrtl8821ae" clean all

	# --- Check the build before installing it ---
	BUILT="$(build_make -C "$BUILD_DIR/src/sys/modules/rtwn_pci" -V .OBJDIR)/if_rtwn_pci.ko"
	strings "$BUILT" | grep -q 'RTL8821AE' ||
	    die "$BUILT has no RTL8821AE support; nothing was installed"

	# --- Install ---
	begin_install
	# If anything below stops the install, say what state it left and how
	# to get out of it.
	trap 'if [ "$(cat "$STATUS" 2>/dev/null)" = "pending" ]; then echo "ERROR: the install did not complete; what it changed so far is recorded: rerun install.sh, or undo it with: sh install.sh --uninstall" >&2; fi' EXIT
	info "Installing WiFi kernel modules into $KMODDIR"
	save_existing_modules
	install_module if_rtwn_pci "$BUILD_DIR/src/sys/modules/rtwn_pci"
	install_module rtwn-rtl8821aefw "$BUILD_DIR/src/sys/modules/rtwnfw/rtwnrtl8821ae"
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
