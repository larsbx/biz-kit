"""Operator-authorized compilation of one restricted Lean proof-term profile."""
from dataclasses import dataclass
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
from tempfile import TemporaryDirectory

from .common import BridgeError, CORE, canonical, hexadecimal, require, sha
from adapter_pilot.checker import ControlledChecker
from adapter_pilot.common import file_digest

sys.path.insert(0, str(CORE / "tools"))
from runtime_identity import tree_identity

SCOPE = "bounded-lean-source-v1"
SCHEMA = "research-exchange/" + SCOPE
REVISION = "56a005855ea17e0b0958f73ec801ae140b0a1679"
TARGET = "submitted"
STATEMENT = "Nat.Prime 2"
IMPORT = "Mathlib.Data.Nat.Prime.Defs"
POLICY = {"allowed_axioms": ["Classical.choice", "Quot.sound", "propext"], "required_checkers": ["leanchecker", "lean4lean"],
          "grammar": "prime-two-term-v1", "source_bytes": 4096, "artifact_bytes": 16777216,
          "address_space_bytes": 6442450944, "cpu_seconds": 25, "wall_seconds": 60,
          "heartbeats": 20000, "rec_depth": 256}
EXTENDED_POLICY = {**POLICY, "export_wall_seconds": 180}
# Only reviewed constants, parentheses and ASCII whitespace can reach Lean.
TERM = re.compile(rb"(?:Nat\.prime_two|id|[() \t])+")
TOKENS = re.compile(rb"Nat\.prime_two|id|[()]")
HEADER = (f"module\npublic import {IMPORT}\nset_option maxHeartbeats {POLICY['heartbeats']}\n"
          f"set_option maxRecDepth {POLICY['rec_depth']}\n"
          f"public theorem {TARGET} : {STATEMENT} :=\n  ").encode()


def is_source(profile):
    return profile.get("schema") == SCHEMA


def profile_for(environment, policy=EXTENDED_POLICY):
    require(hexadecimal(environment), "profile_identity_mismatch")
    require(policy in (POLICY, EXTENDED_POLICY), "profile_identity_mismatch")
    return {"schema": SCHEMA, "theorem": TARGET, "statement_sha256": sha(STATEMENT.encode()),
            "library_revision": REVISION, "source_sha256": sha(HEADER),
            "toolchain_lock_sha256": environment, "policy": policy}


def materialize(source):
    require(0 < len(source) <= POLICY["source_bytes"] and TERM.fullmatch(source), "source_refused")
    # Bound lexical tokens and nesting before invoking Lean.
    tokens = TOKENS.findall(source)
    depth = 0
    for token in tokens:
        if token == b"(":
            depth += 1
            require(depth <= 64, "source_resource_limit")
        elif token == b")":
            depth -= 1
            require(depth >= 0, "source_refused")
    require(depth == 0 and b"Nat.prime_two" in tokens, "source_refused")
    require(len(tokens) <= 192, "source_resource_limit")
    # Requiring token boundaries makes it safe to materialize the exact submitted bytes.
    require(not re.search(rb"(?:id|Nat\.prime_two)(?=id|Nat\.prime_two)", source), "source_refused")
    # Keep the submitted proof term in the operator-owned theorem declaration.
    return HEADER + b"(" + source + b")\n"


def dependency_identity(root):
    """Fingerprint the operator's complete import bundle, with no ambient search path."""
    root = Path(root).resolve(strict=True)
    require((root / "Mathlib/Data/Nat/Prime/Defs.olean").is_file(), "source_environment_mismatch")
    files = {}
    for path in sorted(root.rglob("*")):
        require(not path.is_symlink(), "source_environment_mismatch")
        if path.is_dir():
            continue
        require(path.is_file() and path.name.endswith((".olean", ".olean.private", ".olean.server", ".ir", ".ir.sig")),
                "source_environment_mismatch")
        files[path.relative_to(root).as_posix()] = file_digest(path)
    return sha(canonical(files))


def environment_identity(checker, root):
    tools = checker.identities()
    runtime = tree_identity(checker.lean_root)["sha256"]
    require(runtime == checker.lock["tree_sha256"]["lean"], "source_environment_mismatch")
    return sha(canonical({"core_toolchain": checker.lock_sha256, "tools": tools,
                          "lean_distribution": runtime, "mathlib_revision": REVISION,
                          "mathlib_imports": dependency_identity(root)}))


def run_stage(argv, directory, env, *, limit=None, timeout=None):
    limit = POLICY["artifact_bytes"] if limit is None else limit
    timeout = POLICY["wall_seconds"] if timeout is None else timeout
    with (directory / "stdout").open("wb") as output, (directory / "stderr").open("wb") as errors:
        process = subprocess.Popen(
            ["/usr/bin/prlimit", f"--as={POLICY['address_space_bytes']}",
             f"--cpu={POLICY['cpu_seconds']}:{POLICY['cpu_seconds'] + 1}",
             f"--fsize={limit}", "--core=0", "--nofile=128", "--", *map(str, argv)],
            cwd=directory, env=env, stdin=subprocess.DEVNULL, stdout=output, stderr=errors,
            start_new_session=True,
        )
        try:
            code = process.wait(timeout=timeout)
        except subprocess.TimeoutExpired as error:
            raise BridgeError("source_timeout") from error
        finally:
            if process.poll() is None:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.wait()
    if code in (-signal.SIGXCPU, -signal.SIGXFSZ, -signal.SIGKILL) or any(
            path.stat().st_size >= limit for path in (directory / "stdout", directory / "stderr")):
        raise BridgeError("source_resource_limit")
    require(code == 0, "source_stage_failed")
    return (directory / "stdout").read_bytes()


class SourceStageError(BridgeError):
    def __init__(self, code, stage):
        super().__init__(code)
        self.stage = stage


def run_source_stage(stage, argv, directory, env, **limits):
    try:
        return run_stage(argv, directory, env, **limits)
    except BridgeError as error:
        raise SourceStageError(error.code, stage) from error


def audit_axioms(output):
    match = re.fullmatch(rb"'submitted' (?:does not depend on any axioms|depends on axioms: \[([^\]]*)\])\n",
                         output)
    require(match is not None, "source_audit_failed")
    axioms = [] if match[1] is None else match[1].decode("utf-8").split(", ")
    require(len(set(axioms)) == len(axioms) and set(axioms) <= set(POLICY["allowed_axioms"]),
            "source_axioms_prohibited")
    return sorted(axioms)


@dataclass(frozen=True)
class CheckedSource:
    profile_sha256: str
    artifact_sha256: str  # Existing durable input digest. For this profile the input is source.
    receipt: dict


def check_source(checker: ControlledChecker, root, profile, source, binding, profile_sha256):
    require(sha(source) == binding["artifact_sha256"] and binding["target"] == TARGET,
            "stored_identity_mismatch")
    program = materialize(source)
    require(root is not None, "source_worker_disabled")
    root = Path(root).resolve(strict=True)
    environment = environment_identity(checker, root)
    require(profile == profile_for(environment, profile.get("policy")) and environment == binding["environment_sha256"] and
            REVISION == binding["source_revision"], "source_environment_mismatch")
    with TemporaryDirectory(prefix="exchange-source-") as scratch:
        directory = Path(scratch)
        env = checker.environment(directory)
        env["LEAN_PATH"] = os.pathsep.join((str(directory), str(root)))
        source_path = directory / "Submission.lean"
        source_path.write_bytes(program)
        source_path.chmod(0o400)
        paths = checker.paths
        run_source_stage("compile", [paths["lean"], "-s", "32768", "-j", "1", "-o", "Submission.olean", "Submission.lean"], directory, env)
        (directory / "Audit.lean").write_text(f"module\nimport Submission\n#print axioms {TARGET}\n", encoding="ascii")
        axioms = audit_axioms(run_source_stage("axiom_audit", [paths["lean"], "-s", "32768", "-j", "1", "Audit.lean"], directory, env))
        closure = run_source_stage("export", [paths["leanexport"], "Submission", "--", TARGET], directory, env,
                            timeout=profile["policy"].get("export_wall_seconds", POLICY["wall_seconds"]))
        require(0 < len(closure) < POLICY["artifact_bytes"], "source_resource_limit")
        closure_path = directory / "submission.export"
        closure_path.write_bytes(closure)
        closure_path.chmod(0o400)
        closure_sha = sha(closure)
        checks = []
        for name, flag, success in (
            ("leanchecker", "--from-export", rb"Lean default kernel accepts the solution"),
            ("lean4lean", "--import", rb"checked [1-9][0-9]* declarations"),
        ):
            output = run_source_stage(name, [paths[name], flag, closure_path], directory, checker.environment())
            require(re.search(success, output) is not None and file_digest(closure_path) == closure_sha,
                    "source_replay_failed")
            checks.append({"checker": name, "closure_sha256": closure_sha, "status": "passed"})
        require(source_path.read_bytes() == program, "stored_identity_mismatch")
    require(environment_identity(checker, root) == environment, "source_environment_mismatch")
    receipt = {"schema": SCHEMA, "scope": SCOPE, "status": "passed", "source_sha256": sha(source),
               "materialized_sha256": sha(program), "closure_sha256": closure_sha, "target": TARGET,
               "statement_sha256": profile["statement_sha256"], "library_revision": REVISION,
               "environment_sha256": environment, "policy_sha256": binding["policy_sha256"],
               "axioms": axioms, "checkers": checks}
    return CheckedSource(profile_sha256, sha(source), receipt)


def validate_evidence(receipt, binding, profile, source):
    """Rebind the trusted worker's evidence inside the durable commit guard."""
    closure = receipt.get("closure_sha256")
    axioms = receipt.get("axioms")
    require(type(axioms) is list and all(type(name) is str for name in axioms) and
            axioms == sorted(set(axioms)) and set(axioms) <= set(POLICY["allowed_axioms"]),
            "checker_inconclusive")
    require(hexadecimal(closure) and receipt == {
        "schema": SCHEMA, "scope": SCOPE, "status": "passed",
        "source_sha256": binding["artifact_sha256"], "materialized_sha256": sha(materialize(source)),
        "closure_sha256": closure, "target": binding["target"],
        "statement_sha256": profile["statement_sha256"], "library_revision": binding["source_revision"],
        "environment_sha256": binding["environment_sha256"], "policy_sha256": binding["policy_sha256"],
        "axioms": axioms,
        "checkers": [{"checker": name, "closure_sha256": closure, "status": "passed"}
                     for name in POLICY["required_checkers"]],
    }, "checker_inconclusive")
