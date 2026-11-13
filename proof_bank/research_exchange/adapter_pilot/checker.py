"""Replay exact operator-approved exports; never compile contributor source."""
from __future__ import annotations

from dataclasses import dataclass
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time

from .common import (MAX_ARTIFACT, PilotError, canonical, digest, file_digest,
                     source_identity, validate_profile)


@dataclass(frozen=True)
class CheckedExport:
    profile_sha256: str
    artifact_sha256: str
    receipt: dict


@dataclass(frozen=True)
class RejectedExport:
    profile_sha256: str
    artifact_sha256: str


def matches_export(profile: dict, artifact: bytes) -> bool:
    return len(artifact) == profile["artifact_bytes"] and digest(artifact) == profile["artifact_sha256"]


# Preserve the immutable controlled profile of slots provisioned at PR #335.
# validate_profile binds this digest to the complete reviewed source map.
LEGACY_PROFILE_SOURCE = "1917b988aee220d575a16a868d78e623e387f8d24cffa8848875851fb6ec6f27"


class ControlledChecker:
    """A trusted-local adapter for a fixed reviewed proof-export profile.

    The binary/library pins and optional loader adapter are checked against the
    repository lock. The OS, Python, dynamic loader and local operator remain
    trusted. The artifact digest is checked BEFORE any checker subprocess.
    """

    def __init__(self, lean_root: Path, package_root: Path | None = None,
                 application_path_adapter: Path | None = None,
                 timeout_seconds: int = 30):
        self.lean_root = Path(lean_root).resolve(strict=True)
        self.package_root = (Path(package_root) if package_root else
                             Path(__file__).resolve().parents[1]).resolve(strict=True)
        self.adapter = (Path(application_path_adapter).resolve(strict=True)
                        if application_path_adapter else None)
        if type(timeout_seconds) is not int or not 1 <= timeout_seconds <= 180:
            raise ValueError("timeout_seconds must be between 1 and 180")
        self.timeout_seconds = timeout_seconds
        self.lock_path = self.package_root / "toolchains.lock.json"
        self.lock = json.loads(self.lock_path.read_text())
        self.lock_sha256 = file_digest(self.lock_path)
        self.paths = {
            name: self.lean_root / "bin" / name
            for name in ("lean", "leanexport", "leanchecker", "lean4lean")
        }
        self.paths["leanshared"] = self.lean_root / "lib/lean/libleanshared.so"
        self.identities()

    def identities(self) -> dict[str, str]:
        if file_digest(self.lock_path) != self.lock_sha256:
            raise PilotError(503, "checker_identity_changed")
        hashes = {name: file_digest(path) for name, path in self.paths.items()}
        if any(h != self.lock["file_sha256"][name] for name, h in hashes.items()):
            raise PilotError(503, "checker_identity_mismatch")
        if (self.adapter is not None and file_digest(self.adapter) !=
                self.lock["optional_file_sha256"]["application_path_adapter"]):
            raise PilotError(503, "checker_identity_mismatch")
        return hashes

    def environment(self, lean_path: Path | None = None) -> dict[str, str]:
        # Caller environment cannot inject a different loader, plugin or import
        # search path. Only the separately pinned optional loader is admitted.
        env = {"PATH": "/usr/bin:/bin", "LANG": "C.UTF-8", "LC_ALL": "C.UTF-8",
               "LEAN_SYSROOT": str(self.lean_root), "FRE_LEAN_ROOT": str(self.lean_root)}
        if lean_path is not None:
            env["LEAN_PATH"] = str(lean_path) + os.pathsep + str(self.lean_root / "lib/lean")
        if self.adapter is not None:
            env["LD_PRELOAD"] = str(self.adapter)
        return env

    def replay_export(self, artifact: bytes) -> list[dict]:
        """Trusted preparation/internal primitive; HTTP never accepts a profile."""
        if type(artifact) is not bytes or not 0 < len(artifact) <= MAX_ARTIFACT:
            raise PilotError(422, "proof_refused")
        tools = self.identities()
        results = []
        with tempfile.TemporaryDirectory(prefix="exchange-proof-") as directory:
            path = Path(directory) / "candidate.export"
            path.write_bytes(artifact)
            path.chmod(0o400)
            for name, flag, pattern in (
                ("leanchecker", "--from-export", r"Lean default kernel accepts the solution"),
                ("lean4lean", "--import", r"checked [1-9][0-9]* declarations"),
            ):
                started = time.monotonic_ns()
                try:
                    result = subprocess.run(
                        [str(self.paths[name]), flag, str(path)], cwd=directory,
                        env=self.environment(), capture_output=True, timeout=self.timeout_seconds,
                        check=False,
                    )
                except (subprocess.TimeoutExpired, OSError) as exc:
                    raise PilotError(503, "checker_unavailable") from exc
                output = result.stdout.decode("utf-8", errors="replace")
                if result.returncode != 0 or re.search(pattern, output) is None:
                    raise PilotError(503, "checker_inconclusive")
                if file_digest(path) != digest(artifact):
                    raise PilotError(503, "artifact_changed")
                results.append({
                    "checker": name, "binary_sha256": tools[name],
                    "exit_code": result.returncode,
                    "stdout": output,
                    "stderr": result.stderr.decode("utf-8", errors="replace"),
                    "duration_ns": time.monotonic_ns() - started,
                })
        # Detect ordinary on-disk tool mutation during the run; this is not a
        # hostile-host attestation or a guarantee against privileged races.
        if self.identities() != tools:
            raise PilotError(503, "checker_identity_changed")
        return results

    def check(self, profile: dict, artifact: bytes) -> CheckedExport | RejectedExport:
        validate_profile(profile)
        if type(artifact) is not bytes or not 0 < len(artifact) <= MAX_ARTIFACT:
            raise PilotError(503, "stored_identity_mismatch")
        if (profile["toolchain_lock_sha256"] != self.lock_sha256
                or profile["tool_sha256"] != self.identities()
                or (profile["source_sha256"] != LEGACY_PROFILE_SOURCE
                    and profile["source_files"] != source_identity(self.package_root))):
            raise PilotError(503, "profile_identity_mismatch")
        profile_hash = digest(canonical(profile))
        if not matches_export(profile, artifact):
            return RejectedExport(profile_hash, digest(artifact))
        receipts = self.replay_export(artifact)
        receipt = {
            "schema": "research-exchange/controlled-check/v1",
            "profile_sha256": profile_hash,
            "artifact_sha256": profile["artifact_sha256"],
            "theorem": profile["theorem"], "checkers": receipts,
            "status": "passed", "scope": "exact-reviewed-export-only",
            "application_path_adapter_sha256": file_digest(self.adapter) if self.adapter else None,
        }
        return CheckedExport(profile_hash, profile["artifact_sha256"], receipt)
