#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
set -eu

work="$1"
cross="$2"
core=82267d695dfd61ef2be9a4326622d39d49fa1eae
boards=8a4d326fef4082a62cbcfbf2d8de73ef9839667b

mkdir -p "$work"
exec 9>"$work/build.lock"
flock 9

fetch() (
	name="$1"
	rev="$2"
	dst="$work/$name-$rev"
	if [ "$(git -C "$dst" rev-parse HEAD 2>/dev/null || :)" != "$rev" ]; then
		mkdir -p "$dst"
		git -C "$dst" init --quiet
		git -C "$dst" -c http.version=HTTP/1.1 fetch --no-tags --depth=1 \
			"https://github.com/dqsq2e2/$name.git" "$rev" >&2
		git -C "$dst" checkout --quiet --detach FETCH_HEAD
		test "$(git -C "$dst" rev-parse HEAD)" = "$rev"
	fi
	printf '%s\n' "$dst"
)

core_dir="$(fetch RKdev "$core")"
boards_dir="$(fetch RKdev-boards "$boards")"
python3 "$core_dir/tools/rkdev.py" prepare --profile emmc \
	--board "$boards_dir/boards/bq3588c/v1" --out "$work/out"
jobs="$(nproc)"
[ "$jobs" -le 256 ] || jobs=256
python3 "$core_dir/tools/rkdev.py" boot --locked --profile emmc \
	--board "$boards_dir/boards/bq3588c/v1" --cross-compile="$cross" \
	--cache "$work/build-cache" --out "$work/out" --jobs "$jobs"
