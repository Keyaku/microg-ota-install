# native-libs.sh -- free-space sizing + on-disk unpack of an APK's JNI libs.

# Available 1K blocks on the filesystem holding $1 (POSIX -P => single line).
get_avail_kb() {
	df -kP "$1" 2>/dev/null | tail -n1 | tr -s '[:blank:]' ' ' | sed 's/^ *//' | cut -d' ' -f4
}

# Round KB up to whole MB, for human-friendly messages.
kb_to_mb() { echo $(( ( ${1:-0} + 512 ) / 1024 )); }

# Echo the first ABI in ARCH_LIBS that the APK actually bundles .so files for
# (APKs store libs under the full ABI name: arm64-v8a, armeabi-v7a, ...).
pick_apk_abi() {
	local apk="$1" abi
	for abi in $ARCH_LIBS; do
		unzip -l "$apk" "lib/$abi/*.so" 2>/dev/null | grep -q "lib/$abi/" && { echo "$abi"; return 0; }
	done
}

# Sum the uncompressed size (KB, rounded up) of an APK's lib/<abi>/*.so entries.
# $1 = apk  $2 = abi  $3 = optional filename prefix filter (e.g. "libcronet.").
apk_lib_kb() {
	local apk="$1" abi="$2" filt="${3:-}"
	unzip -l "$apk" "lib/$abi/${filt}"'*.so' 2>/dev/null | tr -s '[:blank:]' ' ' | sed 's/^ *//' | {
		total=0
		while read size d t name; do
			# Skip the unzip -l header/footer: only real lib entries match.
			case "$name" in lib/"$abi"/*.so) ;; *) continue ;; esac
			total=$(( total + ( size + 1023 ) / 1024 ))
		done
		echo "$total"
	}
}

# Extract an installed APK's bundled JNI libraries onto disk under
# <appdir>/lib/<arch>/. PackageManager does NOT unpack native libs for
# pre-installed (system/privileged) apps the way it does for user-installed
# ones -- it expects them already laid out on disk. Without this, GmsCore's
# Cronet library never lands anywhere loadable and apps that pull Cronet from
# Play Services (e.g. Google Maps) crash with "libcronet.<ver>.so not found".
#
# The on-disk dir for a bundled app is bitness-based (arm64, arm, x86, x86_64
# -- i.e. $ARCH), even though the APK stores libs under the full ABI name.
#
# $1 = installed APK   $2 = app dir (where lib/ goes)   $3 = optional filename
# prefix filter (e.g. "libcronet." to unpack only Cronet).
extract_native_libs() {
	local apk="$1" appdir="$2" filt="${3:-}"
	local abi dest lib
	[ -f "$apk" ] || { log "extract_native_libs: no such apk $apk"; return 0; }
	abi="$(pick_apk_abi "$apk")"
	[ -n "$abi" ] || { ui_print "No bundled native libs for $ARCH in $(basename "$apk")"; return 0; }
	dest="$appdir/lib/$ARCH"
	rm -rf "$appdir/lib"
	mkdir -p "$dest"
	if [ -n "$filt" ]; then
		ui_print "Extracting native libs ($abi -> lib/$ARCH, ${filt}* only)..."
	else
		ui_print "Extracting native libs ($abi -> lib/$ARCH)..."
	fi
	# -j flattens the lib/<abi>/ prefix; -o overwrites.
	unzip -o -j "$apk" "lib/$abi/${filt}"'*.so' -d "$dest" >/dev/null \
		|| abort "Couldn't extract native libs from $(basename "$apk")"
	for lib in "$dest"/*.so; do
		[ -f "$lib" ] && chmod 644 "$lib"
	done
	chmod 755 "$appdir/lib" "$dest"
	# Label like other system files so SELinux permits load on boot.
	command -v chcon >/dev/null 2>&1 && chcon -R u:object_r:system_file:s0 "$appdir/lib" 2>/dev/null
}
