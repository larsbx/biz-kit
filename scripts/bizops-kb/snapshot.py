#!/usr/bin/env python3
"""Import and independently check a pinned, read-only bizops-kb snapshot.

Only tracked Markdown is published. The source commit and complete tree proof
let CI verify its Git provenance without access to the upstream repository.
These checks prove byte identity, never operational approval of a procedure.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import subprocess
import tempfile


REPOSITORY = "larsbx/bizops-kb"
DEFAULT_ROOT = Path(__file__).resolve().parents[2] / "apps/bizops_kb/priv"
HEX40 = re.compile(r"[0-9a-f]{40}\Z")
JD = re.compile(r"^([0-9]{2}\.[0-9]{2}[a-z]?)\s+(.+)$")
AREA = re.compile(r"^\d{2}-\d{2} ")
MAX_METADATA_BYTES = 2 * 1024 * 1024
MAX_METADATA_DEPTH = 32
MAX_DOCUMENT_BYTES = 1024 * 1024
MAX_TOTAL_BYTES = 16 * 1024 * 1024
MAX_DOCUMENTS = 1000


class InvalidSnapshot(ValueError):
    """Snapshot content or source proof did not verify."""


def require(condition: bool, message: str) -> None:
    if not condition:
        raise InvalidSnapshot(message)


def object_hash(kind: str, body: bytes) -> str:
    return hashlib.sha1(kind.encode() + b" " + str(len(body)).encode() + b"\0" + body).hexdigest()


def valid_path(path: str) -> bool:
    return (
        isinstance(path, str)
        and bool(path)
        and len(path.encode("utf-8")) <= 2048
        and not path.startswith("/")
        and not re.match(r"^[A-Za-z]:", path)
        and "\\" not in path
        and all(ord(c) >= 32 and ord(c) != 127 for c in path)
        and all(part not in ("", ".", "..", ".git") for part in path.split("/"))
    )


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "duplicate JSON key: " + key)
        result[key] = value
    return result


def read_bounded_regular(path: Path, limit: int) -> bytes:
    # Nonblocking open also prevents a substituted FIFO from hanging a check.
    # NOFOLLOW rejects a symlink substituted after the inventory walk.
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0)
    require(not path.is_symlink(), "symlinked snapshot file")
    with os.fdopen(os.open(path, flags), "rb") as handle:
        info = os.fstat(handle.fileno())
        require(stat.S_ISREG(info.st_mode), "snapshot file is not regular")
        require(info.st_size <= limit, "snapshot file exceeds byte limit")
        body = handle.read(limit + 1)
        require(len(body) <= limit, "snapshot file exceeds byte limit")
        return body


def read_json(path: Path):
    body = read_bounded_regular(path, MAX_METADATA_BYTES)
    # Bound nesting before the decoder, independently of the interpreter's
    # recursion setting. Quoted and escaped brackets are ordinary source text.
    depth, quoted, escaped = 0, False, False
    for byte in body:
        if quoted:
            if escaped:
                escaped = False
            elif byte == 92:
                escaped = True
            elif byte == 34:
                quoted = False
        elif byte == 34:
            quoted = True
        elif byte in (91, 123):
            depth += 1
            require(depth <= MAX_METADATA_DEPTH, "metadata nesting exceeds limit")
        elif byte in (93, 125):
            depth -= 1
    try:
        return json.loads(body.decode("utf-8"), object_pairs_hook=unique_object)
    except (UnicodeError, json.JSONDecodeError, RecursionError) as error:
        raise InvalidSnapshot("invalid UTF-8 or JSON metadata") from error


def write_json(path: Path, value) -> None:
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def tree_hash(entries: list[dict]) -> str:
    """Rebuild every Git tree using Git's byte ordering and directory suffix."""
    root = {}
    paths = set()
    for entry in entries:
        path = entry["path"]
        require(valid_path(path) and path not in paths, "invalid or duplicate source path")
        require(entry["mode"] in ("100644", "100755", "120000"), "unsupported source object mode")
        require(bool(HEX40.fullmatch(entry["sha"])), "invalid source object identity")
        paths.add(path)
        parts = path.split("/")
        node = root
        for part in parts[:-1]:
            node = node.setdefault(part, {})
            require(isinstance(node, dict), "file/directory collision")
        require(parts[-1] not in node, "file/directory collision")
        node[parts[-1]] = (entry["mode"], entry["sha"])

    def digest(node):
        records = []
        for name, value in node.items():
            if isinstance(value, dict):
                mode, sha, order = "40000", digest(value), (name + "/").encode()
            else:
                mode, sha = value
                order = name.encode()
            records.append((order, mode.encode() + b" " + name.encode() + b"\0" + bytes.fromhex(sha)))
        return object_hash("tree", b"".join(record for _, record in sorted(records)))

    return digest(root)


def document_metadata(path: str, body: bytes, entry: dict) -> dict:
    parts = PurePosixPath(path).parts
    stem = PurePosixPath(path).stem
    match = JD.fullmatch(stem)
    jd_id, title = match.groups() if match else (None, stem)
    categorized = len(parts) >= 3 and bool(AREA.match(parts[0]))
    area = parts[0] if categorized else "Source and decisions"
    category = parts[1] if categorized else "Source and decisions"
    require(0 < len(title.encode()) <= 1024, "title exceeds runtime limit")
    require(len(area.encode()) <= 512 and len(category.encode()) <= 512, "category exceeds runtime limit")
    return {
        "id": jd_id or "ref-" + hashlib.sha256(path.encode()).hexdigest()[:16],
        "jd_id": jd_id,
        "title": title,
        "path": path,
        "area": area,
        "category": category,
        "sha256": hashlib.sha256(body).hexdigest(),
        "blob_sha": entry["sha"],
        "size": len(body),
    }


def catalogue(proof: dict, bodies: dict[str, bytes]) -> dict:
    require(0 < len(bodies) <= MAX_DOCUMENTS, "document count exceeds limit")
    require(all(len(body) <= MAX_DOCUMENT_BYTES for body in bodies.values()), "document exceeds byte limit")
    require(sum(map(len, bodies.values())) <= MAX_TOTAL_BYTES, "snapshot exceeds total byte limit")
    entries = {item["path"]: item for item in proof["entries"]}
    documents = [document_metadata(path, bodies[path], entries[path]) for path in sorted(bodies)]
    require(len({doc["id"] for doc in documents}) == len(documents), "duplicate document ID")
    return {
        "schema": 1,
        "repository": REPOSITORY,
        "revision": proof["revision"],
        "tree": proof["tree"],
        "documents": documents,
    }


def check_links(documents: list[dict], bodies: dict[str, bytes]) -> int:
    aliases = {}
    for doc in documents:
        for name in {doc["id"], doc["path"], str(PurePosixPath(doc["path"]).with_suffix("")), PurePosixPath(doc["path"]).stem}:
            aliases.setdefault(name, set()).add(doc["id"])
    count = 0
    for path, body in bodies.items():
        for target in re.findall(r"\[\[([^\]\n]+)\]\]", body.decode("utf-8")):
            target = target.split("|", 1)[0].split("#", 1)[0].strip()
            if not target:  # A heading inside the current note.
                continue
            if target.endswith(".md"):
                target = target[:-3]
            require(len(aliases.get(target, set())) == 1, f"unresolved or ambiguous wikilink in {path}: {target}")
            count += 1
    return count


def check(root: Path) -> dict:
    catalog = read_json(root / "catalog.json")
    proof = read_json(root / "source-proof.json")
    require(proof["schema"] == 1 and proof["repository"] == REPOSITORY, "invalid source proof schema")
    require(bool(HEX40.fullmatch(proof["revision"])) and bool(HEX40.fullmatch(proof["tree"])), "invalid source revision")
    commit = base64.b64decode(proof["commit_base64"], validate=True)
    require(object_hash("commit", commit) == proof["revision"], "source commit hash mismatch")
    require(commit.split(b"\n", 1)[0] == b"tree " + proof["tree"].encode(), "commit/tree mismatch")
    require(tree_hash(proof["entries"]) == proof["tree"], "source tree hash mismatch")
    entries = {entry["path"]: entry for entry in proof["entries"] if entry["path"].endswith(".md")}
    require(0 < len(entries) <= MAX_DOCUMENTS, "empty or excessive source snapshot")
    require(all(entry["mode"] == "100644" for entry in entries.values()), "Markdown must be a regular nonexecutable file")

    content = root / "content"
    require(content.is_dir() and not content.is_symlink(), "invalid content directory")
    actual = set()
    for directory, directories, files in os.walk(content, followlinks=False):
        for name in directories + files:
            require(not (Path(directory) / name).is_symlink(), "symlink in content snapshot")
        actual.update((Path(directory) / name).relative_to(content).as_posix() for name in files)
    require(actual == set(entries), "snapshot file inventory differs from pinned source")
    bodies = {}
    total_bytes = 0
    for path, entry in entries.items():
        body = read_bounded_regular(content / path, MAX_DOCUMENT_BYTES)
        total_bytes += len(body)
        require(total_bytes <= MAX_TOTAL_BYTES, "snapshot exceeds total byte limit")
        body.decode("utf-8")
        require(object_hash("blob", body) == entry["sha"], "source blob mismatch: " + path)
        bodies[path] = body
    expected = catalogue(proof, bodies)
    require(catalog == expected, "catalog differs from verified source metadata")
    links = check_links(expected["documents"], bodies)
    return {"repository": REPOSITORY, "revision": proof["revision"], "tree": proof["tree"], "documents": len(bodies), "bytes": sum(map(len, bodies.values())), "wikilinks": links, "read_only": True}


def git(source: Path, *args: str) -> bytes:
    # Source reads must use the requested object, not a replacement ref, an
    # inherited alternate repository, or a lazy network fetch for missing data.
    environment = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
    environment.update({"GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull,
                        "GIT_NO_LAZY_FETCH": "1", "GIT_TERMINAL_PROMPT": "0",
                        "GIT_OPTIONAL_LOCKS": "0"})
    try:
        return subprocess.run(["git", "--no-replace-objects", "-C", str(source), *args],
                              check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              env=environment, timeout=30).stdout
    except subprocess.TimeoutExpired as error:
        raise InvalidSnapshot("Git object read exceeded its 30-second deadline") from error
    except OSError as error:
        raise InvalidSnapshot("Git object reader could not be started") from error


def import_snapshot(source: Path, revision: str, root: Path) -> dict:
    require(bool(HEX40.fullmatch(revision)), "use an exact 40-character source commit")
    commit = git(source, "cat-file", "commit", revision)
    require(object_hash("commit", commit) == revision, "source commit hash mismatch")
    tree = commit.split(b"\n", 1)[0].decode().removeprefix("tree ")
    entries = []
    bodies = {}
    total_bytes = 0
    for row in git(source, "ls-tree", "-r", "-z", revision).split(b"\0"):
        if not row:
            continue
        metadata, raw_path = row.split(b"\t", 1)
        mode, kind, sha = metadata.decode().split()
        path = raw_path.decode("utf-8")
        require(kind == "blob" and valid_path(path), "unsupported source entry")
        entry = {"path": path, "mode": mode, "sha": sha}
        entries.append(entry)
        if path.endswith(".md"):
            require(mode == "100644", "Markdown must be a regular nonexecutable file")
            size = int(git(source, "cat-file", "-s", sha))
            require(size <= MAX_DOCUMENT_BYTES, "document exceeds byte limit")
            require(len(bodies) < MAX_DOCUMENTS, "document count exceeds limit")
            total_bytes += size
            require(total_bytes <= MAX_TOTAL_BYTES, "snapshot exceeds total byte limit")
            body = git(source, "cat-file", "blob", sha)
            require(object_hash("blob", body) == sha, "source blob hash mismatch")
            body.decode("utf-8")
            bodies[path] = body
    proof = {"schema": 1, "repository": REPOSITORY, "revision": revision, "tree": tree, "commit_base64": base64.b64encode(commit).decode(), "entries": sorted(entries, key=lambda item: item["path"])}
    require(tree_hash(proof["entries"]) == tree, "source tree hash mismatch")
    root.mkdir(parents=True, exist_ok=True)
    if (root / "content").exists():
        check(root)  # Never silently overwrite edits to the generated snapshot.
    with tempfile.TemporaryDirectory(prefix=".snapshot-", dir=root.parent) as temporary:
        stage = Path(temporary)
        (stage / "content").mkdir()
        for path, body in bodies.items():
            destination = stage / "content" / path
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(body)
        write_json(stage / "catalog.json", catalogue(proof, bodies))
        write_json(stage / "source-proof.json", proof)
        result = check(stage)
        if (root / "content").exists():
            shutil.rmtree(root / "content")
        shutil.move(str(stage / "content"), root / "content")
        os.replace(stage / "catalog.json", root / "catalog.json")
        os.replace(stage / "source-proof.json", root / "source-proof.json")
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("import", "check"):
        command = commands.add_parser(name)
        command.add_argument("--root", type=Path, default=DEFAULT_ROOT)
        if name == "import":
            command.add_argument("--source", type=Path, required=True)
            command.add_argument("--revision", required=True)
    args = parser.parse_args()
    try:
        result = check(args.root) if args.command == "check" else import_snapshot(args.source, args.revision, args.root)
    except (InvalidSnapshot, OSError, ValueError, KeyError, TypeError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Snapshot refused: {error}\n")
    print(json.dumps(result, sort_keys=True))


if __name__ == "__main__":
    main()
