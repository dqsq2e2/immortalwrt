#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only

import hashlib
import itertools
import json
import os
from pathlib import Path
import re
import sys
from urllib.error import HTTPError
from urllib.request import Request, urlopen

REPOSITORY = "dqsq2e2/RKdev-boards"
TAG = re.compile(r"bq3588c-emmc-v([0-9]+\.[0-9]+(?:\.[0-9]+)?(?:-[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?)")
LOADER = "u-boot-rockchip.bin"
SUMS = "SHA256SUMS"
RELEASE_INFO = "rkdev-release.json"
MIB = 1024 * 1024
SECTOR = 512
BOOT_START = 32  # MiB


def read_url(url, headers, token=None):
    request = Request(url, headers={"User-Agent": "BQ3588C-ImmortalWrt", **headers})
    if token:
        request.add_unredirected_header("Authorization", f"Bearer {token}")
    with urlopen(request, timeout=60) as response:
        return response.read()


def published_releases():
    headers = {"Accept": "application/vnd.github+json"}
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    for page in itertools.count(1):
        url = f"https://api.github.com/repos/{REPOSITORY}/releases?per_page=100&page={page}"
        try:
            releases = json.loads(read_url(url, headers, token))
        except HTTPError as error:
            if token and error.code in (401, 403, 404, 429):
                # The Actions token may be scoped to the firmware repository.
                token = None
                releases = json.loads(read_url(url, headers))
            elif error.code in (403, 429):
                raise ValueError("GitHub release API unavailable anonymously; set GH_TOKEN") from error
            else:
                raise
        if not isinstance(releases, list):
            raise ValueError("GitHub release list is not a JSON array")
        yield from releases
        if len(releases) < 100:
            return


def select_release(releases):
    matches = []
    for release in releases:
        if TAG.fullmatch(release["tag_name"]) and not release["draft"] and release["published_at"]:
            matches.append(release)
    if not matches:
        raise ValueError(f"No published BQ3588C eMMC release in {REPOSITORY}")
    return max(matches, key=lambda release: (release["published_at"], release["id"]))


def download_asset(asset):
    name = asset["name"]
    data = read_url(asset["browser_download_url"], {})
    digest = asset.get("digest")
    if len(data) != asset["size"] or (
            digest and digest != "sha256:" + hashlib.sha256(data).hexdigest()):
        raise ValueError(f"{name} does not match the GitHub release asset")
    return data


def checksum(sums, name):
    matches = re.findall(rf"^([a-fA-F0-9]{{64}}) [ *]{re.escape(name)}$", sums, re.MULTILINE)
    if len(matches) != 1:
        raise ValueError(f"Expected one SHA-256 entry for {name} in {SUMS}")
    return matches[0].lower()


def validated_layout(info, loader_digest, loader_size):
    tag = TAG.fullmatch(info["tag"])
    manifest = info["manifest"]
    layout = manifest["layout"]
    if (info["repository"] != REPOSITORY or not tag
            or manifest["kind"] != "recovery-image"
            or manifest["schema"] != 1 or layout["schema"] != 1
            or manifest["sources"]["version"] != tag[1]
            or (layout["board_id"], layout["profile"]) != ("bq3588c", "emmc")
            or layout["loader"]["format"] != "rockchip-sd"
            or not re.fullmatch(r"[0-9a-f]{64}", layout["layout_id"])):
        raise ValueError("Expected a BQ3588C eMMC RKdev manifest matching the release tag")

    [extent] = [item for item in manifest["extents"] if item["kind"] == "loader"]
    loader_offset = layout["loader"]["offset"]
    if (extent["sha256"] != loader_digest or info["sha256"][LOADER] != loader_digest
            or extent["length"] != loader_size or extent["offset"] != loader_offset):
        raise ValueError("RKdev U-Boot does not match the manifest and release checksums")

    offsets = layout["environment"]["offsets"]
    size = layout["environment"]["size"]
    if (len(offsets) != 2 or size <= 5 or offsets[0] + size > offsets[1]
            or offsets[1] + size > BOOT_START * MIB):
        raise ValueError("Incorrect RKdev redundant environment geometry")
    if not (34 * SECTOR <= loader_offset < loader_offset + loader_size
            <= loader_offset + layout["loader"]["length"] <= offsets[0]):
        raise ValueError("RKdev U-Boot overlaps GPT or the eMMC environment")

    return layout


def fetch_bundle(out):
    release = select_release(published_releases())
    tag = release["tag_name"]
    print(f"BQ3588C RKdev release: {tag}", flush=True)
    version = TAG.fullmatch(tag)[1]
    assets = {asset["name"]: asset for asset in release["assets"] if asset["state"] == "uploaded"}
    manifests = [name for name in assets if
                 re.fullmatch(rf"bq3588c-[\w.-]+-emmc-{re.escape(version)}\.json", name)]
    if len(manifests) != 1 or not {LOADER, SUMS} <= assets.keys():
        raise ValueError(f"{tag} is missing the loader, checksum list, or a unique layout manifest")
    [manifest_name] = manifests
    sums = download_asset(assets[SUMS]).decode("ascii")
    contents = {}
    digests = {}
    for name in (manifest_name, LOADER):
        expected = checksum(sums, name)
        data = download_asset(assets[name])
        if hashlib.sha256(data).hexdigest() != expected:
            raise ValueError(f"{tag}: {name} failed SHA-256 verification against {SUMS}")
        contents[name] = data
        digests[name] = expected

    manifest = json.loads(contents[manifest_name])
    if manifest["image"]["name"] != Path(manifest_name).stem + ".img":
        raise ValueError(f"{tag}: mismatched recovery image manifest")
    info = {"repository": REPOSITORY, "tag": tag, "manifest_asset": manifest_name,
            "sha256": digests, "manifest": manifest}
    validated_layout(info, digests[LOADER], len(contents[LOADER]))

    out.mkdir(parents=True, exist_ok=True)
    (out / LOADER).write_bytes(contents[LOADER])
    (out / RELEASE_INFO).write_text(json.dumps(info, indent=2, sort_keys=True) + "\n")
    print(f"BQ3588C RKdev U-Boot SHA-256: {digests[LOADER]}", flush=True)


def load_layout(bundle):
    info = json.loads((bundle / RELEASE_INFO).read_text())
    with (bundle / LOADER).open("rb") as loader:
        return validated_layout(info, hashlib.file_digest(loader, "sha256").hexdigest(),
                                os.fstat(loader.fileno()).st_size)


if __name__ == "__main__":
    try:
        fetch_bundle(Path(sys.argv[1]))
    except (KeyError, OSError, TypeError, ValueError) as error:
        sys.exit(f"BQ3588C RKdev bundle: {error}")
