# detect.sh -- prop parsing and ROM/device probing.

select_word() {
	local -i select_current=0
	local select_found select_each
	local select_term="$1"
	while read -r select_line; do
		select_current=0
		select_found=""
		for select_each in $select_line; do
			select_current="$(( select_current + 1 ))"
			[ "$select_current" = "$select_term" ] && { select_found="yes"; break; }
		done
		[ "$select_found" = "yes" ] && echo "$select_each"
	done
}

file_getprop() {
	grep "^$2=" "$1" | head -n1 | select_word 1 | cut -d= -f2
}

get_sysroot() {
	[ -e "/system/build.prop" ] && { SYSROOT="/"; SYSROOT_PART="/system"; }
	[ -e "/system/system/build.prop" ] && { SYSROOT="/system"; SYSROOT_PART="/system"; }
	[ -e "/system_root/system/build.prop" ] && { SYSROOT="/system_root"; SYSROOT_PART="/system_root"; }
	[ -e "/mnt/system/system/build.prop" ] && { SYSROOT="/mnt/system"; SYSROOT_PART="/mnt/system"; }
	[ -f "$SYSROOT/system/build.prop" ] || ui_print "Could not find a ROM!"
}

get_abi() {
	ABI="$(file_getprop "$SYSROOT/system/build.prop" ro.product.cpu.abi)"
	case "$ABI" in
		arm64*)
			ARCH=arm64
			ARCH_LIBS="arm64-v8a armeabi-v7a armeabi"
		;;
		arm*)
			ARCH=arm
			ARCH_LIBS="armeabi-v7a armeabi"
		;;
		x86_64*)
			ARCH=x86_64
			ARCH_LIBS="x86_64 x86 armeabi-v7a armeabi"
		;;
		x86*)
			ARCH=x86
			ARCH_LIBS="x86 armeabi-v7a armeabi"
		;;
		mips64*)
			ARCH=mips64
			ARCH_LIBS="mips64 mips"
		;;
		mips*)
			ARCH=mips
			ARCH_LIBS="mips"
		;;
		*)
			abort "Could not recognise architecture: $ABI"
		;;
	esac
}

get_sdk_build() {
	BUILD_VERSION_SDK="$(file_getprop "$SYSROOT/system/build.prop" ro.build.version.sdk)"
	[ "$BUILD_VERSION_SDK" ] || abort "Could not find SDK"
	[ "$BUILD_VERSION_SDK" -gt 0 ] || abort "Could not recognise SDK: $BUILD_VERSION_SDK"
}
