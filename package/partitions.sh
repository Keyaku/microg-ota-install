# partitions.sh -- mount points, block-device resolution, mount/teardown.

SYSTEM_MOUNT="/mnt/system"
SYSTEM="$SYSTEM_MOUNT/system"
PRODUCT_MOUNT="/mnt/product"
PRODUCT="$PRODUCT_MOUNT"

cleanup() {
	[ -d "$filedir" ] && rm -rf "$filedir"
	$bootmode || {
		local part
		for part in $umountparts; do
			mountpoint -q $part && umount "$part"
		done
		umountparts=""
	}
	sync
}

abort() {
	ui_print " "
	ui_print "!!! FATAL ERROR: $1"
	ui_print " "
	ui_print "Stopping installation and Uninstalling..."
	cleanup
	ui_print " "
	ui_print "Installation failed!"
	ui_print " "
	exit 1
}

fstab_getmount() {
	grep -v "^#" /etc/recovery.fstab | grep "[[:blank:]]$1[[:blank:]]" | tail -n1 | tr -s "[:blank:]" " " | cut -d" " -f1
}

find_block() {
	local blkpath blkabslot blkmount blkmountexists blkdev
	local dynamicpart="$(getprop ro.boot.dynamic_partitions)"
	[ "$dynamicpart" = "true" ] || dynamicpart="false"
	[ "$dynamicpart" = "true" ] && blkpath="/dev/block/mapper" || {
		blkpath="/dev/block/by-name"
		[ -d "$blkpath" ] || blkpath="/dev/block/bootdevice/by-name"
	}
	blkabslot="$(getprop ro.boot.slot_suffix)"
	for name in "$@"; do
		blkmount="$(fstab_getmount "$name")"
		[ "$blkmount" ] && blkmountexists="true" || blkmountexists="false"
		case "$dynamicpart-$blkmountexists" in
			true-true)
				blkdev="${blkpath}/${blkmount}${blkabslot}"
			;;
			false-true)
				blkdev="${blkmount}${blkabslot}"
			;;
			true-false|false-false)
				blkdev="${blkpath}/${name}${blkabslot}"
			;;
		esac
		[ -b "$blkdev" ] && {
			echo "$blkdev"
			return
		}
	done
}

early_mount() {
	$bootmode || {
		log " "
		log "Mounting early"
		if ! mountpoint -q $SYSTEM_MOUNT; then
			mount /dev/block/mapper/system_[ab] $SYSTEM_MOUNT   && umountparts="$umountparts $SYSTEM_MOUNT" || abort "Couldn't mount system"
			ui_print "Mounted system"
		else
			mount -o remount,rw $SYSTEM_MOUNT || abort "Couldn't remount system"
			ui_print "Remounted system"
		fi
		if ! mountpoint -q $PRODUCT_MOUNT; then
			mount /dev/block/mapper/product_[ab] $PRODUCT_MOUNT && umountparts="$umountparts $PRODUCT_MOUNT" || abort "Couldn't mount product"
			ui_print "Mounted product"
		else
			mount -o remount,rw $PRODUCT_MOUNT || abort "Couldn't remount product"
			ui_print "Remounted product"
		fi
	}
}
