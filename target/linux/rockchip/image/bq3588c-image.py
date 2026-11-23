#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only

import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import uuid

MIB = 1024 * 1024
SECTOR = 512
LOADER_OFFSET = 32 * 1024
ENV_OFFSET = 16 * MIB
BOOT_START = 32  # MiB; clear of the loader and both redundant environment slots
NAMESPACE = uuid.UUID("57ec6628-22b4-413e-981a-4a274c56cc94")


def digest(path):
    with path.open("rb") as src:
        return hashlib.file_digest(src, "sha256").hexdigest()


def build(output, kernel, dtb, rootfs, loader, boot_mib, root_mib):
    if boot_mib <= 0 or root_mib <= 0:
        raise ValueError("Invalid partition size")
    if not 0 < loader.stat().st_size <= ENV_OFFSET - LOADER_OFFSET:
        raise ValueError("RKdev U-Boot overlaps the eMMC environment")
    with kernel.open("rb") as src:
        if src.read(64)[56:60] != b"ARM\x64":
            raise ValueError("Expected a raw ARM64 Linux Image")
    if not 0 < rootfs.stat().st_size <= root_mib * MIB:
        raise ValueError("Root filesystem does not fit its partition")

    # RKdev renumbers these partitions when it installs into the system area,
    # while preserving their GPT UUIDs. Use the UUID in both boot layouts.
    disk_guid = uuid.uuid5(NAMESPACE, ":".join(digest(p) for p in (kernel, dtb, rootfs)))
    boot_guid, root_guid = (uuid.uuid5(disk_guid, name) for name in ("boot", "rootfs"))

    with tempfile.TemporaryDirectory(dir=output.parent, prefix=".bq3588c-") as tmp:
        base = Path(tmp)
        boot = base / "boot"
        (boot / "extlinux").mkdir(parents=True)
        shutil.copyfile(kernel, boot / "Image")
        shutil.copyfile(dtb, boot / "bq3588c.dtb")
        (boot / "extlinux/extlinux.conf").write_text(
            "default immortalwrt\n"
            "timeout 0\n"
            "label immortalwrt\n"
            "  menu label ImmortalWrt\n"
            "  kernel /Image\n"
            "  fdt /bq3588c.dtb\n"
            "  append coherent_pool=2M console=tty1 console=ttyS2,1500000n8 "
            "earlycon=uart8250,mmio32,0xfeb50000 "
            f"root=PARTUUID={root_guid} rootwait rw\n",
            encoding="ascii",
        )
        boot_image = base / "boot.ext4"
        args = ["make_ext4fs", "-J", "-L", "immortalwrt-boot", "-l", str(boot_mib * MIB)]
        if epoch := os.environ.get("SOURCE_DATE_EPOCH"):
            args.extend(("-T", epoch))
        subprocess.run(args + [boot_image, boot], check=True)

        root_start = BOOT_START + boot_mib
        end = root_start + root_mib
        sector_per_mib = MIB // SECTOR
        image = base / "disk.img"
        with image.open("wb") as disk:
            disk.truncate((end + 1) * MIB)
        subprocess.run(
            ["sgdisk", "--clear", "--set-alignment=1", f"--disk-guid={disk_guid}",
             f"--new=1:{BOOT_START * sector_per_mib}:{root_start * sector_per_mib - 1}",
             f"--new=2:{root_start * sector_per_mib}:{end * sector_per_mib - 1}",
             f"--partition-guid=1:{boot_guid}", f"--partition-guid=2:{root_guid}",
             "--typecode=1:8300", "--typecode=2:8300",
             "--change-name=1:IMMORTALWRT_BOOT", "--change-name=2:IMMORTALWRT_ROOTFS",
             image],
            check=True,
        )
        with loader.open("rb") as src, image.open("r+b") as disk:
            disk.seek(LOADER_OFFSET)
            shutil.copyfileobj(src, disk)
        for path, start in [(boot_image, BOOT_START), (rootfs, root_start)]:
            subprocess.run(["dd", f"if={path}", f"of={image}", "bs=1M", f"seek={start}",
                            "conv=sparse,notrunc", "status=none"], check=True)
        image.replace(output)


if __name__ == "__main__":
    out, kernel, dtb, rootfs, loader, boot_size, root_size = sys.argv[1:]
    build(Path(out), Path(kernel), Path(dtb), Path(rootfs), Path(loader),
          int(boot_size), int(root_size))
