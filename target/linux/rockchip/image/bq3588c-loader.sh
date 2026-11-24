#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
set -eu

# RKdev uses the distro toolchain and OpenSSL. Keep OpenWrt's staged
# pkg-config and LibreSSL headers and libraries out of this build.
export PATH="${ORIG_PATH:-$PATH}"
unset PKG_CONFIG PKG_CONFIG_PATH PKG_CONFIG_LIBDIR PKG_CONFIG_SYSROOT_DIR
unset CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH LIBRARY_PATH LD_LIBRARY_PATH

work="$1"
cross="$2"
core=dcf9bdb9c1fccc0889c4250616da3ab3b7b2b7e4
boards=b3010bfd237137d545fd056dc8944491b5e67fc9

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
