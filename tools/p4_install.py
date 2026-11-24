#!/usr/bin/env python3
"""Build address-based P4 packages and install them without padding over NVS."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SLOT_LIMITS = {"sentinel": 0x600000, "controller": 0x400000}
SLOT_OFFSETS = {"sentinel": 0x120000, "controller": 0x720000}
MANIFEST_OFFSET = 0xB20000
MANIFEST_BYTES = 0x1000
FIXED_IMAGES = {
    "bootloader": (0x2000, 0x6000),
    "partition_table": (0x8000, 0x1000),
    "ota_data": (0xF000, 0x2000),
    "chooser": (0x20000, 0x100000),
    "sentinel": (SLOT_OFFSETS["sentinel"], SLOT_LIMITS["sentinel"]),
    "controller": (SLOT_OFFSETS["controller"], SLOT_LIMITS["controller"]),
    "app_manifest": (MANIFEST_OFFSET, MANIFEST_BYTES),
}
PROFILES = {
    "network": ("sentinel",),
    "rf": ("sentinel",),
    "sentinel": ("sentinel",),
    "controller": ("controller",),
    "combined": ("sentinel", "controller"),
}
PROFILE_DEFAULT_SCENE = {"network": "network", "rf": "rf", "sentinel": "sentinel",
                         "controller": "chooser", "combined": "sentinel"}
SCENE_IDS = {"sentinel": 0, "network": 1, "rf": 2, "chooser": 0}
BASE_IMAGES = (
    ("bootloader", 0x2000, "firmware/app_chooser/build_slots/bootloader/bootloader.bin"),
    ("partition_table", 0x8000, "firmware/app_chooser/build_slots/partition_table/partition-table.bin"),
    ("ota_data", 0xF000, "firmware/app_chooser/build_slots/ota_data_initial.bin"),
    ("chooser", 0x20000, "firmware/app_chooser/build_slots/app_chooser.bin"),
)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def run(command: list[str], *, env: dict[str, str] | None = None,
        cwd: Path | None = None) -> str:
    result = subprocess.run(command, cwd=cwd or ROOT, env=env, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if result.returncode:
        raise RuntimeError(f"Command failed ({result.returncode}): {' '.join(command)}\n{result.stdout}")
    return result.stdout


def build_project(name: str, env: dict[str, str]) -> None:
    project = ROOT / "firmware" / name
    print(f"Building {name}…", flush=True)
    run(["idf.py", "-B", "build_slots", "build"], env=env, cwd=project)


def package(args: argparse.Namespace) -> None:
    apps = PROFILES[args.profile]
    out = Path(args.out).expanduser().resolve()
    if out.exists() and any(out.iterdir()):
        raise RuntimeError(f"Output directory must be empty to prevent stale package files: {out}")
    if "controller" in apps and not args.controller_image:
        raise RuntimeError(f"Profile {args.profile} requires --controller-image")

    env = os.environ.copy()
    if args.rtl_sdr_source:
        env["RTL_SDR_SOURCE"] = str(Path(args.rtl_sdr_source).expanduser().resolve())
    if "sentinel" in apps and not env.get("RTL_SDR_SOURCE"):
        raise RuntimeError("RF Monitor needs RTL_SDR_SOURCE or --rtl-sdr-source")

    build_project("app_chooser", env)
    if "sentinel" in apps:
        build_project("rf_monitor", env)

    out.mkdir(parents=True, exist_ok=True)
    images_dir = out / "images"
    images_dir.mkdir(exist_ok=True)

    source_entries = list(BASE_IMAGES)
    for app in apps:
        if app == "controller":
            source = Path(args.controller_image).expanduser().resolve()
            if not source.is_file():
                raise RuntimeError(f"Controller image not found: {source}")
            if source.stat().st_size > SLOT_LIMITS[app]:
                raise RuntimeError("Controller image exceeds its 4 MiB partition")
            if source.read_bytes()[:1] != b"\xE9":
                raise RuntimeError("Controller image does not have an ESP app image header")
            image = "controller"
            destination = images_dir / f"{image}.bin"
            shutil.copy2(source, destination)
            source_entries.append((app, SLOT_OFFSETS[app], str(destination)))
            continue
        source = ROOT / "firmware" / "rf_monitor" / "build_slots" / "rf_monitor.bin"
        if not source.is_file():
            raise RuntimeError(f"Built image not found: {source}")
        if source.stat().st_size > SLOT_LIMITS[app]:
            raise RuntimeError(f"{app} image exceeds its assigned partition")
        destination = images_dir / f"{app}.bin"
        shutil.copy2(source, destination)
        source_entries.append((app, SLOT_OFFSETS[app], str(destination)))

    entries = []
    for label, offset, source in source_entries:
        path = Path(source)
        if not path.is_absolute():
            path = ROOT / path
        if not path.is_file():
            raise RuntimeError(f"Required image missing: {path}")
        copied = images_dir / path.name
        if copied.resolve() != path.resolve():
            shutil.copy2(path, copied)
        entries.append({"name": label, "offset": offset, "file": f"images/{copied.name}",
                        "bytes": copied.stat().st_size, "sha256": sha256(copied)})

    installed_bits = {"sentinel": 1 << 0, "controller": 1 << 1}
    mask = sum(installed_bits[app] for app in apps)
    default_scene = PROFILE_DEFAULT_SCENE[args.profile]
    app_manifest = bytearray([0xFF]) * MANIFEST_BYTES
    app_manifest[:8] = b"P4S1" + bytes((1, mask, SCENE_IDS[default_scene], 0))
    manifest_image = images_dir / "app_manifest.bin"
    manifest_image.write_bytes(app_manifest)
    entries.append({"name": "app_manifest", "offset": MANIFEST_OFFSET,
                    "file": "images/app_manifest.bin", "bytes": MANIFEST_BYTES,
                    "sha256": sha256(manifest_image)})

    manifest = {
        "format": 1,
        "target": "esp32p4",
        "flash_bytes": 16 * 1024 * 1024,
        "profile": args.profile,
        "apps": list(apps),
        "default_scene": default_scene,
        "preserved_ranges": [{"start": 0x9000, "end": 0xF000, "name": "NVS"}],
        "entries": entries,
    }
    (out / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    plan = ["P4 Sentinel install plan (review only; use p4_install.py flash)",
            f"Target: ESP32-P4, 16 MiB flash", f"Profile: {args.profile}",
            "Writes:"]
    plan += [f"  0x{entry['offset']:06x}  {entry['bytes']:>8} bytes  {entry['file']}"
             for entry in entries]
    plan += ["Preserved: NVS 0x009000–0x00EFFF; SD card; every app partition omitted from this profile."]
    (out / "flash-plan.txt").write_text("\n".join(plan) + "\n")
    print(f"Package ready: {out}")
    print(f"Profile: {args.profile}; apps: {', '.join(apps)}")
    print(f"Review {out / 'manifest.json'} and {out / 'flash-plan.txt'} before flashing.")


def validate_package(package_dir: Path) -> list[dict]:
    manifest_path = package_dir / "manifest.json"
    manifest = json.loads(manifest_path.read_text())
    if manifest.get("format") != 1 or manifest.get("target") != "esp32p4" or manifest.get("flash_bytes") != 16 * 1024 * 1024:
        raise RuntimeError("Package format, target, or flash size is not the expected ESP32-P4 16 MiB layout")
    profile = manifest.get("profile")
    if profile not in PROFILES or manifest.get("apps") != list(PROFILES[profile]):
        raise RuntimeError("Package profile and installed-app list do not match")
    entries = manifest.get("entries")
    if not isinstance(entries, list):
        raise RuntimeError("Package has no valid image entry list")
    required = {"bootloader", "partition_table", "ota_data", "chooser", "app_manifest", *PROFILES[profile]}
    seen: set[str] = set()
    ranges: list[tuple[int, int, str]] = []
    for entry in entries:
        if not isinstance(entry, dict):
            raise RuntimeError("Malformed package image entry")
        name = entry.get("name")
        if name not in FIXED_IMAGES or name in seen:
            raise RuntimeError(f"Unexpected or duplicate package image: {name!r}")
        seen.add(name)
        offset, limit = FIXED_IMAGES[name]
        size = entry.get("bytes")
        if entry.get("offset") != offset or not isinstance(size, int) or isinstance(size, bool) or size < 1 or size > limit:
            raise RuntimeError(f"Invalid size or fixed address for {name}")
        relative = entry.get("file")
        if not isinstance(relative, str):
            raise RuntimeError(f"Invalid package path for {name}")
        path = (package_dir / relative).resolve()
        if not path.is_relative_to(package_dir.resolve()) or not path.is_file():
            raise RuntimeError(f"Image path is missing or escapes the package: {relative}")
        if path.stat().st_size != size or not re.fullmatch(r"[0-9a-f]{64}", entry.get("sha256", "")) or sha256(path) != entry["sha256"]:
            raise RuntimeError(f"Package image verification failed: {relative}")
        if name in ("sentinel", "controller", "chooser") and path.read_bytes()[:1] != b"\xE9":
            raise RuntimeError(f"{name} does not have an ESP app image header")
        end = offset + size
        if end > 16 * 1024 * 1024:
            raise RuntimeError(f"{name} extends beyond flash")
        ranges.append((offset, end, name))
    if seen != required:
        raise RuntimeError(f"Package entries differ from profile; expected {sorted(required)}, got {sorted(seen)}")
    ranges.sort()
    for previous, current in zip(ranges, ranges[1:]):
        if previous[1] > current[0]:
            raise RuntimeError(f"Package images overlap: {previous[2]} and {current[2]}")
    manifest_entry = next(entry for entry in entries if entry["name"] == "app_manifest")
    manifest_bytes = (package_dir / manifest_entry["file"]).read_bytes()
    expected_mask = sum({"sentinel": 1, "controller": 2}[app] for app in PROFILES[profile])
    default_scene = PROFILE_DEFAULT_SCENE[profile]
    if manifest.get("default_scene") != default_scene or manifest_bytes[:8] != b"P4S1" + bytes((1, expected_mask, SCENE_IDS[default_scene], 0)):
        raise RuntimeError("Installed-app manifest contents do not match the package profile")
    return entries


def flash(args: argparse.Namespace) -> None:
    package_dir = Path(args.package_dir).expanduser().resolve()
    entries = validate_package(package_dir)
    if not args.yes:
        raise RuntimeError("Flashing requires explicit --yes after reviewing the package")
    if not args.port:
        raise RuntimeError("--port is required")

    backup_dir = Path(args.backup_dir).expanduser().resolve()
    backup_dir.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    backup = backup_dir / f"p4-preinstall-{stamp}.bin"
    flash_info = run([sys.executable, "-m", "esptool", "--chip", "esp32p4",
                      "--port", args.port, "flash-id"])
    if not re.search(r"Detected flash size:\s*16\s*MB", flash_info, re.IGNORECASE):
        raise RuntimeError(f"Expected a 16 MiB flash device; refusing to write.\n{flash_info}")
    run([sys.executable, "-m", "esptool", "--chip", "esp32p4", "--port", args.port,
         "read-flash", "0x0", "0x1000000", str(backup)])
    if backup.stat().st_size != 16 * 1024 * 1024:
        raise RuntimeError("Full-flash backup has an unexpected size; refusing to write")
    backup_hash = sha256(backup)
    (backup.with_suffix(".bin.sha256")).write_text(f"{backup_hash}  {backup.name}\n")
    print(f"Verified recovery backup: {backup}\nSHA-256: {backup_hash}")

    command = [sys.executable, "-m", "esptool", "--chip", "esp32p4", "--port", args.port,
               "--before", "default-reset", "--after", "hard-reset", "write-flash",
               "--flash-mode", "keep", "--flash-freq", "keep", "--flash-size", "keep"]
    for entry in entries:
        command.extend([f"0x{entry['offset']:x}", str(package_dir / entry["file"])])
    print(run(command))
    print("Install complete. The USB serial device will re-enumerate after reset.")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    pack = subparsers.add_parser("package", help="build selected firmware and create a reviewed install package")
    pack.add_argument("--profile", choices=sorted(PROFILES), required=True)
    pack.add_argument("--out", required=True)
    pack.add_argument("--controller-image")
    pack.add_argument("--rtl-sdr-source")
    pack.set_defaults(func=package)
    install = subparsers.add_parser("flash", help="back up and install an existing package")
    install.add_argument("package_dir")
    install.add_argument("--port", required=True)
    install.add_argument("--backup-dir", required=True)
    install.add_argument("--yes", action="store_true", help="confirm the reviewed package may be written")
    install.set_defaults(func=flash)
    args = parser.parse_args()
    try:
        args.func(args)
    except (OSError, RuntimeError, ValueError, KeyError, json.JSONDecodeError) as error:
        print(f"p4_install: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
