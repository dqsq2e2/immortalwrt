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

from bq3588c_loader import BOOT_START, LOADER, MIB, SECTOR, fetch_bundle, load_layout

NAMESPACE = uuid.UUID("57ec6628-22b4-413e-981a-4a274c56cc94")


def digest(path):
    with path.open("rb") as src:
        return hashlib.file_digest(src, "sha256").hexdigest()


def check_ext4(image):
    # make_ext4fs leaves unused inode bitmap bits clear. Normalize them before packaging.
    env = os.environ.copy()
    if epoch := env.get("SOURCE_DATE_EPOCH"):
        env["E2FSPROGS_FAKE_TIME"] = epoch
    repair = subprocess.run(["e2fsck", "-f", "-p", image], env=env)
    if repair.returncode not in (0, 1):
        repair.check_returncode()
    subprocess.run(["e2fsck", "-f", "-n", image], check=True, env=env)


def build(output, kernel, dtb, rootfs, boot_mib, root_mib):
    if boot_mib <= 0 or root_mib <= 0:
        raise ValueError("Invalid partition size")
    with kernel.open("rb") as src:
        if src.read(64)[56:60] != b"ARM\x64":
            raise ValueError("Expected a raw ARM64 Linux Image")
    if not 0 < rootfs.stat().st_size <= root_mib * MIB:
        raise ValueError("Root filesystem does not fit its partition")

    with tempfile.TemporaryDirectory(dir=output.parent, prefix=".bq3588c-") as tmp:
        base = Path(tmp)
        if bundle := os.environ.get("BQ3588C_RKDEV_BUNDLE"):
            boot_files = Path(bundle)
        else:
            boot_files = base / "rkdev"
            fetch_bundle(boot_files)
        layout = load_layout(boot_files)
        loader = boot_files / LOADER
        offsets = layout["environment"]["offsets"]
        env_size = layout["environment"]["size"]
        loader_offset = layout["loader"]["offset"]

        root_image = base / "rootfs.ext4"
        subprocess.run(["cp", "--reflink=auto", "--sparse=always", rootfs, root_image], check=True)
        check_ext4(root_image)

        # RKdev renumbers partitions while preserving their GPT UUIDs.
        disk_guid = uuid.uuid5(NAMESPACE, ":".join(digest(p) for p in (kernel, dtb, root_image)))
        boot_guid, root_guid = (uuid.uuid5(disk_guid, name) for name in ("boot", "rootfs"))

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
        check_ext4(boot_image)

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
        env_text = base / "u-boot.env"
        env_defaults = Path(__file__).with_name("bq3588c-boot.env")
        rows = dict(row.split("=", 1) for row in env_defaults.read_text().splitlines() if row)
        rows.update(bootcmd="rkdevboot", stdin="serial", rkdev_layout=layout["layout_id"],
                    rkdev_targets=" ".join(layout["boot_order"]))
        env_text.write_text("".join(f"{key}={value}\n" for key, value in rows.items()))
        env_image = base / "u-boot.env.bin"
        subprocess.run(["mkenvimage", "-r", "-s", str(env_size), "-o", env_image, env_text], check=True)
        with loader.open("rb") as src, image.open("r+b") as disk:
            disk.seek(loader_offset)
            shutil.copyfileobj(src, disk)
            for offset in offsets:
                disk.seek(offset)
                disk.write(env_image.read_bytes())
        for path, start in [(boot_image, BOOT_START), (root_image, root_start)]:
            subprocess.run(["dd", f"if={path}", f"of={image}", "bs=1M", f"seek={start}",
                            "conv=sparse,notrunc", "status=none"], check=True)
        image.replace(output)


if __name__ == "__main__":
    out, kernel, dtb, rootfs, boot_size, root_size = sys.argv[1:]
    build(Path(out), Path(kernel), Path(dtb), Path(rootfs),
          int(boot_size), int(root_size))
