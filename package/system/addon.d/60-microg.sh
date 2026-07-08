#!/sbin/sh
#
# /system/addon.d/60-microg.sh
# During a system upgrade, this script backs up microG,
# /system is formatted and reinstalled, then the files are restored.
#

. /tmp/backuptool.functions

PRODUCT=$SYSMOUNT/product

# One path per line, relative to $PRODUCT. Missing files are skipped by
# backup_file/restore_file, so listing the optional default-permissions XMLs
# unconditionally is safe.
list_files() {
cat <<EOF
etc/permissions/privapp-permissions-com.google.android.gms.xml
etc/permissions/privapp-permissions-com.android.vending.xml
etc/default-permissions/default-permissions-com.google.android.gms.xml
etc/default-permissions/default-permissions-com.android.vending.xml
priv-app/GmsCore/GmsCore.apk
priv-app/GmsCompanion/GmsCompanion.apk
app/GsfProxy/GsfProxy.apk
EOF
}

# Re-extract GmsCore's bundled JNI libs onto disk after a restore. The OTA
# backup only preserves the APK, and PackageManager does not unpack native
# libs for pre-installed apps, so without this the Cronet library goes missing
# again after every system update and apps like Google Maps crash.
restore_native_libs() {
	GMS_APK="$PRODUCT/priv-app/GmsCore/GmsCore.apk"
	[ -f "$GMS_APK" ] || return 0
	case "$(getprop ro.product.cpu.abi)" in
		arm64*)  srcabi=arm64-v8a;   arch=arm64  ;;
		arm*)    srcabi=armeabi-v7a; arch=arm    ;;
		x86_64*) srcabi=x86_64;      arch=x86_64 ;;
		x86*)    srcabi=x86;         arch=x86    ;;
		*) return 0 ;;
	esac
	unzip -l "$GMS_APK" "lib/$srcabi/*.so" >/dev/null 2>&1 || return 0

	# Sum uncompressed KB of matching libs; $1 = optional filename prefix.
	sum_kb() {
		unzip -l "$GMS_APK" "lib/$srcabi/${1:-}"'*.so' 2>/dev/null \
			| tr -s '[:blank:]' ' ' | sed 's/^ *//' | {
			t=0
			while read s d tt n; do
				case "$n" in lib/"$srcabi"/*.so) t=$(( t + ( s + 1023 ) / 1024 )) ;; esac
			done
			echo "$t"
		}
	}
	avail=$(df -kP "$PRODUCT" 2>/dev/null | tail -n1 | tr -s '[:blank:]' ' ' | sed 's/^ *//' | cut -d' ' -f4)
	full=$(sum_kb ""); cron=$(sum_kb "libcronet.")
	margin=3072

	dest="$PRODUCT/priv-app/GmsCore/lib/$arch"
	rm -rf "$PRODUCT/priv-app/GmsCore/lib"
	mkdir -p "$dest"
	# Mirror the installer's guard rails: full unpack if it fits, else cronet
	# only, else nothing -- never half-fill /product on an OTA restore.
	if [ -n "$avail" ] && [ "$avail" -ge $(( full + margin )) ]; then
		unzip -o -j "$GMS_APK" "lib/$srcabi/*.so" -d "$dest" >/dev/null 2>&1 || return 0
	elif [ -n "$avail" ] && [ "$avail" -ge $(( cron + margin )) ]; then
		unzip -o -j "$GMS_APK" "lib/$srcabi/libcronet."'*.so' -d "$dest" >/dev/null 2>&1 || return 0
	else
		rm -rf "$PRODUCT/priv-app/GmsCore/lib"
		return 0
	fi
	chmod 755 "$PRODUCT/priv-app/GmsCore/lib" "$dest"
	chmod 644 "$dest"/*.so 2>/dev/null
	command -v restorecon >/dev/null 2>&1 && restorecon -R "$PRODUCT/priv-app/GmsCore/lib" 2>/dev/null
}

case "$1" in
backup)
	list_files | while read FILE; do
		backup_file "$PRODUCT/$FILE"
	done
;;
restore)
	list_files | while read FILE; do
		restore_file "$PRODUCT/$FILE"
	done
;;
pre-backup)
	# Stub
;;
post-backup)
	# Stub
;;
pre-restore)
	# Stub
;;
post-restore)
	restore_native_libs
;;
esac
