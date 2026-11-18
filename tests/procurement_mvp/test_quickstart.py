"""Wrapper/gate controls only; fake Docker never counts as application execution."""
import ast
import copy
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
TOOLS = ROOT / "tools/procurement-quickstart"
spec = importlib.util.spec_from_file_location("quickstart_evidence", TOOLS / "evidence.py")
evidence = importlib.util.module_from_spec(spec)
spec.loader.exec_module(evidence)
REVISION = "a" * 40
IMAGE = "sha256:" + "b" * 64


class EvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.result = {"kind": "procurement-quickstart-v1", "trust": evidence.TRUST,
                       "status": "passed", "revision": REVISION, "image_id": IMAGE,
                       "stages": dict.fromkeys(evidence.STAGES, True)}
        for name in ("toolchain", "database", "runtime", "cleanup"):
            (self.root / (name + ".log")).write_text("SYNTHETIC UNIT FIXTURE, NOT EXECUTION\n")
        (self.root / "formal").mkdir()
        for name in ("Workflow", "Admission", "workflow-typecheck", "workflow-tests", "workflow-run",
                     "admission-typecheck", "admission-tests", "admission-run"):
            (self.root / "formal" / (name + ".log")).write_text("SYNTHETIC\n")
        (self.root / "host/release").mkdir(parents=True)
        (self.root / "host/procurement-release.tar.gz").write_bytes(b"not an actual release")
        self.receipt = {"kind": "procurement-packaged-acceptance-v1", "trust": evidence.TRUST,
                        "revision": REVISION,
                        "artifact_sha256": evidence.sha256(self.root / "host/procurement-release.tar.gz"),
                        "checks": dict.fromkeys(evidence.CHECKS, True)}
        self.save()

    def save(self):
        (self.root / "result.json").write_text(json.dumps(self.result))
        (self.root / "host/release/receipt.json").write_text(json.dumps(self.receipt))
        evidence.write_manifest(self.root)

    def rejects(self):
        with self.assertRaises((ValueError, OSError)):
            evidence.verify(self.root, REVISION)

    def test_consistent_fixture_is_only_unsigned(self):
        self.assertEqual(evidence.verify(self.root, REVISION)["trust"], evidence.TRUST)

    def test_failed_run_rejects_even_with_old_success_receipt(self):
        self.result["status"] = "failed"
        self.save()
        self.rejects()

    def test_all_stage_failures_and_non_booleans_rejected(self):
        for stage in evidence.STAGES:
            for value in (False, None, 1, "true", "skipped"):
                with self.subTest(stage=stage, value=value):
                    self.result["stages"] = dict.fromkeys(evidence.STAGES, True)
                    self.result["stages"][stage] = value
                    self.save()
                    self.rejects()

    def test_missing_or_extra_stage(self):
        del self.result["stages"]["formal"]
        self.save()
        self.rejects()
        self.result["stages"]["formal"] = True
        self.result["stages"]["invented"] = True
        self.save()
        self.rejects()

    def test_every_packaged_check_is_required(self):
        for name in evidence.CHECKS:
            original = self.receipt["checks"].pop(name)
            self.save()
            self.rejects()
            self.receipt["checks"][name] = original

    def test_packaged_check_non_boolean(self):
        self.receipt["checks"]["http_lifecycle"] = 1
        self.save()
        self.rejects()

    def test_revision_mismatch(self):
        with self.assertRaises(ValueError):
            evidence.verify(self.root, "c" * 40)
        self.receipt["revision"] = "c" * 40
        self.save()
        self.rejects()

    def test_artifact_changed_even_with_updated_manifest(self):
        (self.root / "host/procurement-release.tar.gz").write_bytes(b"modified")
        evidence.write_manifest(self.root)
        self.rejects()

    def test_log_tampering(self):
        (self.root / "runtime.log").write_text("modified")
        self.rejects()

    def test_missing_required_log_even_with_updated_manifest(self):
        (self.root / "formal/Admission.log").unlink()
        evidence.write_manifest(self.root)
        self.rejects()

    def test_extra_file_not_in_manifest(self):
        (self.root / "unrecorded.log").write_text("extra")
        self.rejects()

    def test_unsigned_cannot_be_relabelled_verified(self):
        self.result["trust"] = "verified-attestation"
        self.save()
        self.rejects()

    def test_image_id_required(self):
        self.result["image_id"] = "latest"
        self.save()
        self.rejects()

    def test_path_escape_and_symlink(self):
        for name in ("../result.json", "/etc/passwd"):
            with self.assertRaises(ValueError):
                evidence.regular_file(self.root, name)
        (self.root / "link").symlink_to(self.root / "result.json")
        with self.assertRaises(ValueError):
            evidence.regular_file(self.root, "link")

    def test_matches_upstream_receipt_contract(self):
        source = ROOT / "tests/procurement_mvp/release_acceptance.py"
        self.assertTrue(source.exists(), "upstream receipt contract is required")
        module = ast.parse(source.read_text())
        assignments = [node for node in module.body if isinstance(node, ast.Assign)
                       and any(isinstance(target, ast.Name) and target.id == "REQUIRED" for target in node.targets)]
        self.assertEqual(len(assignments), 1)
        self.assertEqual(evidence.CHECKS, ast.literal_eval(assignments[0].value.args[0]))


FAKE_DOCKER = r'''#!/usr/bin/python3
import json, os, pathlib, sys
args = sys.argv[1:]
record = pathlib.Path(os.environ["FAKE_RECORD"])
with record.open("a") as output: output.write(json.dumps(args) + "\n")
if args[0] == "context": print(os.environ.get("FAKE_ENDPOINT", "unix:///var/run/docker.sock"))
elif args[0] == "info": print("linux" if args[-1] == "{{.OSType}}" else "x86_64")
elif args[0] == "build":
    pathlib.Path(args[args.index("--iidfile") + 1]).write_text("sha256:" + "b"*64)
elif args[0] == "image": print("sha256:" + "b"*64 + " []")
elif args[0] == "create":
    mount = args[args.index("--mount")+1]
    source = pathlib.Path(mount.split("src=")[1].split(",dst=")[0])
    assert not (source / "ignored-secret").exists()
    assert "synthetic-private-token" not in (source / ".git/config").read_text()
    assert source.stat().st_mode & 0o005 == 0o005
    print("fake-container")
elif args[0] == "start":
    print("SYNTHETIC DOCKER FAILURE; NOT APPLICATION EXECUTION")
    sys.exit(int(os.environ.get("FAKE_EXIT", "7")))
elif args[0] == "inspect":
    print("false" if args[2] == "{{.State.Running}}" else os.environ.get("FAKE_EXIT", "7"))
elif args[0] == "cp":
    destination = pathlib.Path(args[-1]); destination.mkdir(parents=True, exist_ok=True)
    (destination / "result.json").write_text('{"status":"failed","synthetic_test":true}')
elif args[0] in {"rm", "stop"}: pass
else: raise SystemExit("unhandled fake Docker action: " + str(args))
'''


class WrapperTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.root = self.home / "repository"
        self.root.mkdir()
        for name in ("scripts", "tools/procurement-quickstart"):
            (self.root / name).mkdir(parents=True, exist_ok=True)
        shutil.copy(ROOT / "scripts/procurement-quickstart.sh", self.root / "scripts")
        for name in ("Dockerfile", "runner.py", "evidence.py"):
            shutil.copy(TOOLS / name, self.root / "tools/procurement-quickstart")
        (self.root / "scripts/test-procurement-host.sh").write_text("exit 1\n")
        (self.root / ".gitignore").write_text("ignored-secret\n")
        self.git("init", "-q")
        self.git("add", ".")
        self.git("-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-qm", "fixture")
        self.git("config", "http.extraHeader", "synthetic-private-token")
        (self.root / "ignored-secret").write_text("not copied")
        bindir = self.home / "bin"
        bindir.mkdir()
        docker = bindir / "docker"
        docker.write_text(FAKE_DOCKER)
        docker.chmod(0o755)
        self.env = {k: v for k, v in os.environ.items() if not k.startswith("DOCKER_")}
        self.env.update(PATH=str(bindir) + os.pathsep + os.environ["PATH"],
                        FAKE_RECORD=str(self.home / "docker.jsonl"), PYTHONDONTWRITEBYTECODE="1")

    def git(self, *args):
        subprocess.run(["git", "-C", str(self.root), *args], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)

    def run_wrapper(self, mode, success=False):
        result = subprocess.run(["bash", "scripts/procurement-quickstart.sh", mode],
                                cwd=self.root, env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
        return result

    def calls(self):
        return [json.loads(line) for line in (self.home / "docker.jsonl").read_text().splitlines()]

    def test_doctor_is_non_mutating(self):
        self.run_wrapper("doctor", success=True)
        self.assertFalse((self.root / ".artifacts").exists())
        self.assertFalse(any(call[0] in {"create", "build", "start"} for call in self.calls()))

    def test_dirty_source_refused(self):
        (self.root / "untracked.py").write_text("uncommitted")
        self.run_wrapper("run")
        self.assertFalse(any(call[0] == "build" for call in self.calls()))

    def test_tracked_edit_refused(self):
        (self.root / "scripts/test-procurement-host.sh").write_text("exit 0\n")
        self.run_wrapper("run")
        self.assertFalse(any(call[0] == "build" for call in self.calls()))

    def test_remote_daemon_refused(self):
        self.env["DOCKER_HOST"] = "tcp://remote:2376"
        self.run_wrapper("doctor")

    def test_remote_context_overrides_local_host_and_is_refused(self):
        self.env.update(DOCKER_CONTEXT="remote", DOCKER_HOST="unix:///var/run/docker.sock", FAKE_ENDPOINT="ssh://remote")
        self.run_wrapper("doctor")

    def test_install_does_not_run_application(self):
        self.run_wrapper("install", success=True)
        self.assertTrue(any(call[0] == "build" for call in self.calls()))
        self.assertFalse(any(call[0] in {"start", "create"} for call in self.calls()))

    def test_failure_retains_evidence_and_cleans_container(self):
        self.run_wrapper("run")
        runs = list((self.root / ".artifacts/procurement-quickstart").iterdir())
        self.assertEqual(len(runs), 1)
        self.assertTrue((runs[0] / "container/result.json").exists())
        calls = self.calls()
        self.assertTrue(any(call[0] == "rm" for call in calls))
        create = next(call for call in calls if call[0] == "create")
        self.assertIn("--cap-drop", create)
        self.assertIn("--security-opt", create)
        self.assertTrue(create[create.index("--mount")+1].endswith(",readonly"))
        self.assertNotIn("--privileged", create)
        self.assertNotIn("--publish", create)
        self.assertNotIn("-p", create)
        self.assertNotIn("--network=host", create)
        self.assertNotIn("docker.sock", " ".join(create))
        self.assertEqual(sum(value == "--env" for value in create), 2)

    def test_zero_exit_without_valid_receipt_is_not_success(self):
        self.env["FAKE_EXIT"] = "0"
        self.run_wrapper("run")

    def test_each_attempt_has_its_own_evidence(self):
        self.run_wrapper("run")
        self.run_wrapper("run")
        self.assertEqual(len(list((self.root / ".artifacts/procurement-quickstart").iterdir())), 2)


if __name__ == "__main__":
    unittest.main()
