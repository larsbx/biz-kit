"""Hash tool distributions without treating a version string as their identity."""
from __future__ import annotations

import hashlib
from pathlib import Path

from source_snapshot import canonical, digest_bytes


def file_sha(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def tree_identity(root: Path) -> dict[str, object]:
    """Include every regular file and internal symlink, independent of timestamps."""
    root = root.resolve(strict=True)
    entries: list[dict[str, object]] = []
    for path in sorted(root.rglob("*")):
        relative = path.relative_to(root).as_posix()
        if path.is_symlink():
            if not path.resolve(strict=True).is_relative_to(root):
                raise ValueError(f"runtime symlink escapes distribution: {relative}")
            entries.append({"path": relative, "symlink": str(path.readlink())})
        elif path.is_file():
            entries.append({"path": relative, "bytes": path.stat().st_size,
                            "sha256": file_sha(path)})
        elif not path.is_dir():
            raise ValueError(f"unsupported runtime file type: {relative}")
    return {"path": str(root), "sha256": digest_bytes(canonical(entries)),
            "entries": len(entries),
            "bytes": sum(int(entry.get("bytes", 0)) for entry in entries)}
