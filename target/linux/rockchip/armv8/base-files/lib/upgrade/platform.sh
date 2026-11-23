REQUIRE_IMAGE_METADATA=1

bq3588c_rkdev_upgrade() {
	[ "$(board_name)" = 'bearkey,bq3588c' ] || return 1
	echo "Use RKdev Recovery or flash the combined disk image offline." >&2
	return 0
}

platform_check_image() {
	# The legacy Rockchip writer uses fixed partition numbers. Code 74
	# makes this non-forceable, including when ImmortalWrt is in RKdev's system area.
	bq3588c_rkdev_upgrade && return 74
	legacy_sdcard_check_image "$1"
}

platform_copy_config() {
	local partdev

	if export_partdevice partdev 1; then
		mount -o rw,noatime "/dev/$partdev" /mnt
		cp -af "$UPGRADE_BACKUP" "/mnt/$BACKUP_FILE"
		umount /mnt
	fi
}

platform_do_upgrade() {
	bq3588c_rkdev_upgrade && return 1
	legacy_sdcard_do_upgrade "$1"
}
