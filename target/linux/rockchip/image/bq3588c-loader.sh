#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
set -eu

work=$1
script_dir=$(dirname "$0")

mkdir -p "$work/out"
exec 9>"$work/build.lock"
flock 9

# Keep the tested RKdev loader independent of the board release retention policy.
python3 - "$script_dir" "$work/out" <<'PY'
import gzip
from hashlib import sha256
import json
from pathlib import Path
import shutil
import sys

script_dir, out = map(Path, sys.argv[1:])
assets = script_dir / "bq3588c-rkdev"
manifest_bytes = (assets / "manifest.json").read_bytes()
if sha256(manifest_bytes).hexdigest() != "f4b7161e6eb32954a5a06b45616acdc25e6a297e9c2617656b7fd6140de5a8af":
    sys.exit("BQ3588C RKdev manifest SHA-256 mismatch")
manifest = json.loads(manifest_bytes)
layout = manifest["layout"]
loader = gzip.decompress((assets / "u-boot-rockchip.bin.gz").read_bytes())
[extent] = (item for item in manifest["extents"] if item["kind"] == "loader")
if ((layout["board_id"], layout["profile"]) != ("bq3588c", "emmc")
        or (extent["sha256"], extent["length"], extent["offset"]) !=
           (sha256(loader).hexdigest(), len(loader), layout["loader"]["offset"])
        or len(loader) > layout["loader"]["length"]):
    sys.exit("BQ3588C RKdev loader does not match the pinned manifest and layout")
(out / "layout.json").write_text(json.dumps(layout) + "\n")
(out / "u-boot-rockchip.bin").write_bytes(loader)
shutil.copyfile(script_dir / "bq3588c-boot.env", out / "u-boot-initial-env")
PY
