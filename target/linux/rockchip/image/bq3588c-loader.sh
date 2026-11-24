#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
set -eu

work=$1
release=https://github.com/dqsq2e2/RKdev-boards/releases/download/bq3588c-emmc-v0.1-bq.4
loader_sha=dab12953ba49ddb58e036bd269948d42ed778ca5bb7e8c5a8d0290ed1b24e9c4
manifest_sha=f4b7161e6eb32954a5a06b45616acdc25e6a297e9c2617656b7fd6140de5a8af

mkdir -p "$work/out"
exec 9>"$work/build.lock"
flock 9

fetch() {
	name=$1
	hash=$2
	file=$work/$name
	if [ ! -f "$file" ] || ! printf '%s  %s\n' "$hash" "$file" | sha256sum --check --status; then
		curl --fail --location --silent --show-error --retry 3 --connect-timeout 20 \
			--output "$file.tmp" "$release/$name"
		printf '%s  %s\n' "$hash" "$file.tmp" | sha256sum --check
		mv -f "$file.tmp" "$file"
	fi
}

# The published and hardware-tested loader is shared with RKdev on both hosts.
fetch u-boot-rockchip.bin "$loader_sha"
fetch bq3588c-v1-emmc-0.1-bq.4.json "$manifest_sha"

python3 - "$work" "$loader_sha" <<'PY'
import json
from pathlib import Path
import shutil
import sys

work = Path(sys.argv[1])
manifest = json.loads((work / "bq3588c-v1-emmc-0.1-bq.4.json").read_text())
layout = manifest["layout"]
loader = work / "u-boot-rockchip.bin"
[extent] = (item for item in manifest["extents"] if item["kind"] == "loader")
if ((layout["board_id"], layout["profile"]) != ("bq3588c", "emmc")
        or (extent["sha256"], extent["length"], extent["offset"]) !=
           (sys.argv[2], loader.stat().st_size, layout["loader"]["offset"])):
    raise ValueError("The RKdev release does not match the BQ3588C loader and layout")
out = work / "out"
(out / "layout.json").write_text(json.dumps(layout) + "\n")
shutil.copyfile(loader, out / loader.name)
PY

cp "$(dirname "$0")/bq3588c-boot.env" "$work/out/u-boot-initial-env"
