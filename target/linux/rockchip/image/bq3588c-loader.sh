#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
set -eu

work="$1"
downloads="$2"
cross="$3"
core=b728ca09e6243479aff39a1b4e85dc03645b606d
boards=948c3f13d4147a428180016de490ae4be66663dc

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
jobs="$(nproc)"
[ "$jobs" -le 256 ] || jobs=256
python3 "$core_dir/tools/rkdev.py" boot --locked --profile emmc \
	--board "$boards_dir/boards/bq3588c/v1" --cross-compile="$cross" \
	--cache "$downloads/rkdev-bq3588c" --out "$work/out" --jobs "$jobs"
