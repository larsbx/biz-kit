#!/usr/bin/env python3
"""Stage a dependency bundle from an operator-built pinned mathlib checkout."""
import argparse
from pathlib import Path
import shutil
import subprocess
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from research_exchange_bridge.common import canonical, loads, require
from research_exchange_bridge.source import REVISION, dependency_identity

SUFFIXES = (".olean", ".olean.private", ".olean.server", ".ir", ".ir.sig")


def verify_checkout(root, revision):
    def git(*args):
        return subprocess.check_output(["git", "-C", str(root), *args], text=True).strip()

    require(git("rev-parse", "HEAD") == revision and not git("status", "--porcelain", "--untracked-files=all"),
            "source_checkout_mismatch")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mathlib", type=Path)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    root, destination = args.mathlib.resolve(), args.destination.resolve()
    require(not destination.is_relative_to(root), "invalid_configuration")
    verify_checkout(root, REVISION)
    require((root / "lean-toolchain").read_text().strip() == "leanprover/lean4:v4.35.0",
            "source_checkout_mismatch")
    manifest = loads((root / "lake-manifest.json").read_bytes())
    roots = [root]
    for package in manifest["packages"]:
        path = root / manifest["packagesDir"] / package["name"]
        verify_checkout(path, package["rev"])
        roots.append(path)

    destination.mkdir(mode=0o700)
    try:
        for checkout in roots:
            imports = checkout / ".lake/build/lib/lean"
            for path in imports.rglob("*"):
                require(not path.is_symlink(), "source_checkout_mismatch")
                if not path.is_file() or not path.name.endswith(SUFFIXES):
                    continue
                relative = path.relative_to(imports)
                require(relative.parts[0] not in {"Init", "Lean", "Lake", "Std", "Init.olean", "Lean.olean",
                                                   "Lake.olean", "Std.olean"}, "source_checkout_mismatch")
                output = destination / relative
                require(not output.exists(), "source_checkout_mismatch")
                output.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(path, output)
        digest = dependency_identity(destination)
    except BaseException:
        shutil.rmtree(destination)
        raise
    print(canonical({"mathlib_revision": REVISION, "imports_sha256": digest}).decode())


if __name__ == "__main__":
    main()
