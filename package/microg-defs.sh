# microg-defs.sh -- package-wide constants and shared preamble for the microG
# installer and uninstaller. Single source of truth: keeping the app directory
# and payload names here stops the two scripts from drifting apart.

# App directory names (must match what the installer creates on disk).
GSF=GsfProxy
GMS=GmsCore
STORE=GmsCompanion

# addon.d survival script name.
ADDOND_MICROG=60-microg.sh

# Privileged-permission allowlists.
PERM_PATH="etc/permissions"
PERM_GMS='privapp-permissions-com.google.android.gms.xml'
PERM_STORE='privapp-permissions-com.android.vending.xml'

# Canonical install locations within the target partition (GmsCore/Companion
# are privileged; GsfProxy is a plain app).
GSF_DIR="app/$GSF"
GMS_DIR="priv-app/$GMS"
STORE_DIR="priv-app/$STORE"
PERM_DIR="$PERM_PATH"

# Print the framed title/description banner.
# $1 = title   $2 = description (optional)
print_banner() {
	ui_print " "
	ui_print "-- $(center_text 40 "$1") --"
	[ -n "$2" ] && ui_print "-- $(center_text 40 "$2") --"
}

# Mount partitions and detect the ROM. Pass "install" to additionally resolve
# the device ABI and SDK level (only the installer needs those); otherwise just
# the mount + sysroot lookup runs. Prints nothing -- callers report as they see
# fit.
prepare_rom() {
	early_mount
	get_sysroot
	if [ "$1" = install ]; then
		get_abi
		get_sdk_build
	fi
}

# Standard success teardown: unmount, clean the work dir, report and exit 0.
finish() {
	ui_print " "
	ui_print "Unmounting..."
	cleanup
	ui_print " "
	ui_print "Done!"
	exit 0
}
