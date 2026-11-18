#!/usr/bin/env python3
"""Install the pinned Linux x86_64 proof tools outside the source tree."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tarfile
import urllib.request

from runtime_identity import file_sha, tree_identity


def download(spec: dict, directory: Path, offline: bool) -> Path:
    archive = directory / spec["archive"]
    if archive.exists():
        if file_sha(archive) != spec["sha256"]:
            raise ValueError(f"cached archive hash mismatch: {archive}")
        return archive
    if offline:
        raise ValueError(f"archive is unavailable offline: {archive}")
    temporary = archive.with_name(archive.name + ".partial")
    if temporary.exists():
        raise ValueError(f"refusing to overwrite an unfinished download: {temporary}")
    print(f"Downloading {spec['url']}", flush=True)
    request = urllib.request.Request(spec["url"], headers={"User-Agent": "formal-research-exchange-bootstrap/1"})
    try:
        with urllib.request.urlopen(request, timeout=120) as source, temporary.open("xb") as output:
            shutil.copyfileobj(source, output, length=1024 * 1024)
        if file_sha(temporary) != spec["sha256"]:
            raise ValueError(f"download hash mismatch: {archive.name}")
        temporary.rename(archive)
    finally:
        if temporary.exists():
            temporary.unlink()
    return archive


def unpack(archive: Path, destination: Path) -> None:
    destination.mkdir(parents=True, exist_ok=True)
    if archive.name.endswith(".zst"):
        process = subprocess.Popen(["zstd", "-dc", str(archive)], stdout=subprocess.PIPE)
        try:
            with tarfile.open(fileobj=process.stdout, mode="r|") as source:
                source.extractall(destination, filter="data")
        finally:
            if process.stdout:
                process.stdout.close()
        if process.wait() != 0:
            raise ValueError("zstd decompression failed")
    else:
        with tarfile.open(archive, mode="r:gz") as source:
            source.extractall(destination, filter="data")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--destination", type=Path, required=True)
    parser.add_argument("--offline", action="store_true")
    parser.add_argument("--build-app-path-adapter", action="store_true",
                        help="only for an environment where Lean cannot discover its own executable")
    args = parser.parse_args()
    if platform.system() != "Linux" or platform.machine() not in {"x86_64", "AMD64"}:
        raise ValueError("this toolchain lock targets Linux x86_64")
    root = Path(__file__).resolve().parents[1]
    destination = args.destination.resolve()
    if destination.is_relative_to(root):
        raise ValueError("install the runtimes outside the reviewed source tree")
    destination.mkdir(parents=True, exist_ok=True)
    lock = json.loads((root / "toolchains.lock.json").read_text())
    if lock["schema"] != "formal-research-exchange/toolchains/v1":
        raise ValueError("unsupported lock schema")
    for name in ["lean", "jre", "apalache"]:
        spec = lock["downloads"][name]
        installed = destination / spec["installed_relative"]
        if not installed.exists():
            archive = download(spec, destination, args.offline)
            unpack(archive, destination / spec["extract_relative"])
        if not installed.is_dir():
            raise ValueError(f"expected runtime directory is missing: {installed}")
    quint_root = destination / "quint"
    quint_root.mkdir(exist_ok=True)
    for name in ["package.json", "package-lock.json"]:
        shutil.copyfile(root / "tooling/quint" / name, quint_root / name)
    if not (quint_root / "node_modules").exists():
        command = ["npm", "ci", "--ignore-scripts", "--no-audit", "--no-fund"]
        if args.offline:
            command.append("--offline")
        subprocess.run(command, cwd=quint_root, check=True)
    paths = {
        "lean": destination / lock["downloads"]["lean"]["installed_relative"],
        "jre": destination / lock["downloads"]["jre"]["installed_relative"],
        "quint_node_modules": quint_root / "node_modules",
    }
    for name, path in paths.items():
        actual = tree_identity(path)
        if actual["sha256"] != lock["tree_sha256"][name]:
            raise ValueError(f"installed distribution differs from the lock: {name}")
        print(f"Verified {name}: {actual['sha256']}", flush=True)
    apalache_jar = destination / "quint-home/apalache-dist-0.62.4/apalache/lib/apalache.jar"
    if file_sha(apalache_jar) != lock["file_sha256"]["apalache_jar"]:
        raise ValueError("Apalache/TLC jar differs from the lock")
    result = {
        "lean_root": str(paths["lean"]),
        "quint_cli": str(quint_root / "node_modules/@informalsystems/quint/dist/src/cli.js"),
        "java_bin": str(paths["jre"] / "bin/java"),
        "quint_home": str(destination / "quint-home"),
    }
    if args.build_app_path_adapter:
        adapter = destination / "toolchain_app_path.so"
        subprocess.run(["cc", "-shared", "-fPIC", "-Wall", "-Wextra", "-Werror", "-O2",
                        str(root / "tools/explicit_app_path.c"), "-ldl", "-o", str(adapter)], check=True)
        if file_sha(adapter) != lock["optional_file_sha256"]["application_path_adapter"]:
            raise ValueError("adapter build differs from the pinned build; review and re-lock it before use")
        result["app_path_adapter"] = str(adapter)
    (destination / "setup.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
