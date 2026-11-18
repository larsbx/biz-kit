"""Independent native-process acceptance for the fixed local workload.

Core start/crash/fence checks invoke the real CLI and worker. The test observer
independently checks the fixed argv, kernel identity, pidfd and work artifact.
Only the separate barrier fixture inserts scheduling pauses; it replaces no
provider state transition, work calculation, kernel observation or signal.
"""

import array
from datetime import datetime, timedelta, timezone
import hashlib
import json
import os
from pathlib import Path
import select
import signal
import socket
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest


HERE = Path(__file__).resolve().parent
PROVIDER = HERE / "provider.py"
WORKER = HERE / "worker.py"
BARRIER = HERE / "barrier_provider.py"
REQUEST_SCHEMA = "bizkit.agent-local-worker-request.v1"
RECEIPT_SCHEMA = "bizkit.agent-local-worker-receipt.v1"
ERROR_SCHEMA = "bizkit.agent-local-worker-error.v1"
RECEIPT_KEYS = {
    "schema", "operation", "store_id", "effect_id", "state", "backend_id",
    "admission_id", "plan_digest", "execution_deadline", "disposition",
    "execution_started", "termination_verified", "future_creates_refused",
    "worker_identity", "work_count", "result_digest", "ambiguity",
}
BINDING_KEYS = ("store_id", "effect_id", "backend_id", "admission_id", "plan_digest",
                "execution_deadline", "worker_identity", "work_count", "result_digest")


def kernel_identity(pid):
    fields = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()
    return {"boot_id": Path("/proc/sys/kernel/random/boot_id").read_text().strip(),
            "pid": pid, "start_ticks": int(fields[19])}


def exited(descriptor, timeout_ms=0):
    observer = select.poll()
    observer.register(descriptor, select.POLLIN | select.POLLHUP)
    observations = observer.poll(timeout_ms)
    if any(events & (select.POLLERR | select.POLLNVAL) for _fd, events in observations):
        raise AssertionError("invalid or errored pidfd is not a verified exit")
    return any(events & (select.POLLIN | select.POLLHUP) for _fd, events in observations)


class ProviderTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not (sys.platform == "linux" and hasattr(os, "pidfd_open")
                and hasattr(signal, "pidfd_send_signal")):
            raise RuntimeError("native local-worker acceptance requires Linux pidfds")

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="agent-worker-")
        self.addCleanup(self.directory.cleanup)
        self.db = Path(self.directory.name) / "worker.sqlite"
        self.addCleanup(self.cleanup_recorded_worker)
        response, status = self.invoke("init")
        self.assertEqual(status, 0, response)
        self.assertEqual(set(response), {"schema", "store_id"})
        self.assertEqual(response["schema"], "bizkit.agent-local-worker-store.v1")
        self.store_id = response["store_id"]
        self.assertRegex(self.store_id, r"\Aagent-backend-store:[0-9a-f]{32}\Z")
        self.deadline = self.after(20)
        self.effect = "agent-run:fixed-local-test"

    @staticmethod
    def after(seconds):
        return (datetime.now(timezone.utc) + timedelta(seconds=seconds)).isoformat(
            timespec="microseconds").replace("+00:00", "Z")

    def request(self, operation="create", **changes):
        request = {"schema": REQUEST_SCHEMA, "operation": operation,
                   "store_id": self.store_id, "effect_id": self.effect}
        if operation == "create":
            request.update(admission_id="agent-admission:" + hashlib.sha256(self.effect.encode()).hexdigest(),
                           plan_digest="a" * 64, execution_deadline=self.deadline)
        request.update(changes)
        return request

    def invoke(self, operation, request=None, *, raw=None):
        data = raw if raw is not None else json.dumps(request).encode() if request is not None else b""
        completed = subprocess.run(
            [sys.executable, str(PROVIDER), operation, "--db", str(self.db)],
            input=data, capture_output=True, timeout=8, check=False)
        self.assertEqual(completed.stderr, b"", completed.stderr.decode(errors="replace"))
        self.assertEqual(len(completed.stdout.splitlines()), 1, completed.stdout)
        return json.loads(completed.stdout), completed.returncode

    def send(self, request):
        return self.invoke("request", request)

    def receipt(self, operation="lookup", **changes):
        response, status = self.send(self.request(operation, **changes))
        self.assertEqual(status, 0, response)
        self.assertEqual(set(response), RECEIPT_KEYS)
        self.assertEqual(response["schema"], RECEIPT_SCHEMA)
        self.assertEqual(response["operation"], operation)
        self.assertEqual(response["store_id"], self.store_id)
        self.assertEqual(response["effect_id"], self.effect)
        return response

    def assert_error(self, result, code, status=2):
        response, actual = result
        self.assertEqual(actual, status, response)
        self.assertEqual(response, {"schema": ERROR_SCHEMA, "error": code,
                                    "store_id": self.store_id})

    def row(self):
        with sqlite3.connect(self.db) as connection:
            connection.row_factory = sqlite3.Row
            row = connection.execute("SELECT * FROM local_workers WHERE effect_id=?",
                                     (self.effect,)).fetchone()
            return None if row is None else dict(row)

    def rows_count(self):
        with sqlite3.connect(self.db) as connection:
            return connection.execute("SELECT COUNT(*) FROM local_workers").fetchone()[0]

    def spawn(self, request, *, mode=None, observer=None):
        args = ([sys.executable, str(BARRIER), str(self.db), mode] if mode else
                [sys.executable, str(PROVIDER), "request", "--db", str(self.db)])
        environment = os.environ.copy()
        inherited = ()
        if observer is not None:
            environment["BIZKIT_TEST_OBSERVER_FD"] = str(observer.fileno())
            inherited = (observer.fileno(),)
        process = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, env=environment, pass_fds=inherited)
        self.addCleanup(self.stop_manager, process)
        process.stdin.write(json.dumps(request).encode())
        process.stdin.close()
        process.stdin = None
        return process

    @staticmethod
    def stop_manager(process):
        if process.poll() is None:
            process.kill()  # Owned, unreaped direct child; never a recovered numeric PID.
        process.communicate(timeout=5)

    def marker(self, process, expected):
        self.assertTrue(select.select([process.stderr], [], [], 6)[0],
                        "provider never reached the real fault boundary")
        self.assertEqual(process.stderr.readline(), expected + b"\n")
        self.assertIsNone(process.poll())

    def finish(self, process):
        stdout, stderr = process.communicate(timeout=8)
        self.assertEqual(stderr, b"", stderr.decode(errors="replace"))
        return json.loads(stdout), process.returncode

    def retain(self, descriptor):
        os.set_inheritable(descriptor, False)
        self.addCleanup(self.stop_worker, descriptor)
        return descriptor

    @staticmethod
    def stop_worker(descriptor):
        try:
            if not exited(descriptor):
                try:
                    signal.pidfd_send_signal(descriptor, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                if not exited(descriptor, 3_000):
                    raise AssertionError("owned worker did not exit during pidfd cleanup")
        finally:
            os.close(descriptor)

    def cleanup_recorded_worker(self):
        """Also clean a real child when a negative control fails before capture."""
        if not self.db.exists():
            return
        try:
            with sqlite3.connect(self.db) as connection:
                connection.row_factory = sqlite3.Row
                rows = connection.execute("SELECT * FROM local_workers WHERE pid IS NOT NULL").fetchall()
        except sqlite3.Error:
            return
        for row in rows:
            descriptor = None
            identity = {key: row[key] for key in ("boot_id", "pid", "start_ticks")}
            try:
                command = json.loads(row["worker_argv"])
                if (len(command) != 6 or command[:2] != [sys.executable, "-I"]
                        or command[2] not in (str(WORKER), str(BARRIER))
                        or command[3:] != [str(self.db), row["effect_id"], row["launch_nonce"]]):
                    continue
                expected = b"\0".join(argument.encode() for argument in command) + b"\0"

                def matches():
                    process = Path(f"/proc/{identity['pid']}")
                    return (kernel_identity(identity["pid"]) == identity
                            and process.stat().st_uid == os.getuid()
                            and (process / "cmdline").read_bytes() == expected)

                if not matches():
                    continue
                descriptor = os.pidfd_open(identity["pid"])
                if not matches():
                    continue
                if not exited(descriptor):
                    signal.pidfd_send_signal(descriptor, signal.SIGKILL)
                    self.assertTrue(exited(descriptor, 3_000), "owned fixture worker did not exit")
            except (OSError, ValueError):
                pass  # Missing or mismatched identity never becomes a signal target.
            finally:
                if descriptor is not None:
                    os.close(descriptor)

    def worker_descriptor(self, response):
        """Independent proc-bound observer; no provider identity helpers."""
        row = self.row()
        identity = response["worker_identity"]
        self.assertEqual(set(identity), {"boot_id", "pid", "start_ticks"})
        expected = [sys.executable, "-I", str(WORKER), str(self.db), self.effect, row["launch_nonce"]]
        self.assertEqual(json.loads(row["worker_argv"]), expected)

        def check_process():
            self.assertEqual(kernel_identity(identity["pid"]), identity)
            process = Path(f"/proc/{identity['pid']}")
            self.assertEqual(process.stat().st_uid, os.getuid())
            self.assertEqual((process / "cmdline").read_bytes().split(b"\0")[:-1],
                             [argument.encode() for argument in expected])

        check_process()
        descriptor = self.retain(os.pidfd_open(identity["pid"], 0))
        fdinfo = dict(line.split(":", 1) for line in
                      Path(f"/proc/self/fdinfo/{descriptor}").read_text().splitlines())
        self.assertEqual(int(fdinfo["Pid"]), identity["pid"])
        check_process()
        signal.pidfd_send_signal(descriptor, 0)
        self.assertFalse(exited(descriptor), "worker must actually be live before the fence")
        return descriptor

    def assert_work(self, response):
        self.assertIs(response["execution_started"], True)
        self.assertEqual(response["work_count"], 1)
        self.assertIsNone(response["ambiguity"])
        seed = hashlib.sha256(("bizkit.fixed-local-worker.v1\n" + self.effect + "\n"
                               + response["plan_digest"] + "\n").encode()).digest()
        digest = hashlib.sha256()
        for number in range(4096):
            digest.update(seed + number.to_bytes(4, "big"))
        self.assertEqual(response["result_digest"], digest.hexdigest())
        artifact = self.db.parent / ("w-" + response["backend_id"].split(":", 1)[1] + ".sha256")
        self.assertEqual(artifact.read_bytes(), (digest.hexdigest() + "\n").encode("ascii"))
        self.assertEqual(artifact.stat().st_mode & 0o777, 0o600)
        self.assertEqual(response["worker_identity"], kernel_identity(response["worker_identity"]["pid"]))

    def started(self):
        response = self.receipt("create")
        self.assert_work(response)
        return response, self.worker_descriptor(response)

    def assert_binding(self, left, right):
        self.assertEqual({key: left[key] for key in BINDING_KEYS},
                         {key: right[key] for key in BINDING_KEYS})

    def matching_worker_pids(self):
        matching = []
        for path in Path("/proc").glob("[0-9]*/cmdline"):
            try:
                arguments = path.read_bytes().split(b"\0")
            except (OSError, ProcessLookupError):
                continue
            if (str(self.db).encode() in arguments and self.effect.encode() in arguments
                    and any(str(script).encode() in arguments for script in (WORKER, BARRIER))):
                matching.append(int(path.parent.name))
        return sorted(matching)

    def evidence(self, name, fields):
        target = os.environ.get("AGENT_LOCAL_WORKER_EVIDENCE_DIR")
        if target is None:
            return
        revision = os.environ["AGENT_LAUNCH_SOURCE_REVISION"]
        value = {"schema": "bizkit.agent-local-worker-native-evidence.v1",
                 "source_revision": revision, "store_id": self.store_id,
                 "effect_id": self.effect, **fields}
        encoded = json.dumps(value, indent=2, sort_keys=True) + "\n"
        self.assertLessEqual(len(encoded.encode()), 32768)
        directory = Path(target)
        directory.mkdir(parents=True, exist_ok=True)
        (directory / ("provider-" + name + ".json")).write_text(encoded)

    def test_explicit_private_store_and_unknown_lookup_do_not_claim_execution_absence(self):
        self.assertEqual(self.db.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.db.parent.stat().st_mode & 0o777, 0o700)
        unknown = self.receipt()
        self.assertEqual(unknown["state"], "unknown")
        self.assertIsNone(unknown["execution_started"])
        self.assertEqual(unknown["ambiguity"], "no_record")
        self.assertFalse(unknown["termination_verified"])
        response, status = self.invoke("init")
        self.assertEqual((status, response["error"]), (2, "store_exists"))

    def test_concurrent_and_replayed_create_execute_one_fixed_workload_in_one_live_child(self):
        managers = [self.spawn(self.request()) for _ in range(4)]
        responses = []
        for manager in managers:
            response, status = self.finish(manager)
            self.assertEqual(status, 0, response)
            responses.append(response)
        self.assertEqual(len({response["backend_id"] for response in responses}), 1)
        self.assertEqual(sorted(response["disposition"] for response in responses),
                         ["created", "existing", "existing", "existing"])
        observed = self.receipt()
        self.assert_work(observed)
        descriptor = self.worker_descriptor(observed)
        for _ in range(2):
            repeated = self.receipt("create")
            self.assertEqual(repeated["disposition"], "existing")
            self.assert_binding(repeated, observed)
        self.assertEqual(self.rows_count(), 1)
        self.assertEqual(self.matching_worker_pids(), [observed["worker_identity"]["pid"]])
        self.assertFalse(exited(descriptor))
        self.evidence("concurrent-once", {"manager_pids": [p.pid for p in managers],
                      "observed": observed, "matching_live_worker_count": 1,
                      "independent_fixed_artifact_verified": True})

    def test_killed_manager_after_durable_reservation_before_spawn_never_respawns_on_retry(self):
        manager = self.spawn(self.request(), mode="before_spawn")
        self.marker(manager, b"RESERVED")
        reserved = self.row()
        self.assertIsNone(reserved["pid"])
        self.assertEqual(reserved["work_count"], 0)
        manager.kill()
        stdout, stderr = manager.communicate(timeout=5)
        self.assertEqual((manager.returncode, stdout, stderr), (-signal.SIGKILL, b"", b""))
        for operation in ("create", "lookup", "create"):
            response = self.receipt(operation)
            self.assertEqual(response["backend_id"], reserved["backend_id"])
            self.assertEqual(response["state"], "starting")
            self.assertIsNone(response["execution_started"])
            self.assertEqual(response["ambiguity"], "unregistered_start")
            self.assertIsNone(response["worker_identity"])
        self.assertEqual(self.matching_worker_pids(), [])
        self.assertEqual(self.row(), reserved)
        self.evidence("reserved-crash", {"manager_pid": manager.pid, "manager_exit": manager.returncode,
                      "ordinary_reply_bytes": len(stdout), "observed": response,
                      "matching_live_worker_count": 0, "retry_did_not_spawn": True})

    def test_real_work_survives_manager_sigkill_before_reply_and_fresh_retry_keeps_same_process(self):
        manager = self.spawn(self.request(), mode="after_work")
        self.marker(manager, b"WORKED")
        before = self.receipt()
        self.assert_work(before)
        descriptor = self.worker_descriptor(before)
        manager.kill()
        lost, stderr = manager.communicate(timeout=5)
        self.assertEqual((manager.returncode, lost, stderr), (-signal.SIGKILL, b"", b""))
        self.assertFalse(exited(descriptor), "actual worker must survive its manager's death")
        replay = self.receipt("create")
        observed = self.receipt()
        self.assert_binding(before, replay)
        self.assert_binding(before, observed)
        self.assert_work(observed)
        self.assertEqual(self.matching_worker_pids(), [before["worker_identity"]["pid"]])
        terminated = self.receipt("terminate")
        self.assertTrue(terminated["termination_verified"])
        self.assertTrue(exited(descriptor, 2_000))
        self.assert_binding(before, terminated)
        self.evidence("worked-crash", {"killed_manager_pid": manager.pid,
                      "manager_exit": manager.returncode, "ordinary_reply_bytes": len(lost),
                      "before_crash": before, "after_retry": replay, "termination": terminated,
                      "independent_pidfd_exit_observed": True,
                      "independent_fixed_artifact_verified": True})

    def test_fence_before_reservation_retains_tombstone_and_prevents_any_child(self):
        fenced = self.receipt("fence")
        self.assertEqual(fenced["state"], "fenced")
        self.assertIs(fenced["execution_started"], False)
        self.assertFalse(fenced["termination_verified"])
        self.assertTrue(fenced["future_creates_refused"])
        self.assertIsNone(fenced["backend_id"])
        for _ in range(2):
            self.assert_error(self.send(self.request()), "effect_fenced", 1)
            self.assertTrue(self.receipt()["future_creates_refused"])
        self.assertEqual(self.matching_worker_pids(), [])
        self.assertEqual(self.rows_count(), 1)

    def test_fence_after_reservation_but_before_spawn_prevents_the_delayed_manager_start(self):
        manager = self.spawn(self.request(), mode="before_spawn")
        self.marker(manager, b"RESERVED")
        reserved = self.row()
        fenced = self.receipt("fence")
        self.assertTrue(fenced["future_creates_refused"])
        manager.send_signal(signal.SIGUSR1)
        self.assert_error(self.finish(manager), "effect_fenced", 1)
        self.assertEqual(self.matching_worker_pids(), [])
        row = self.row()
        self.assertEqual(row["backend_id"], reserved["backend_id"])
        self.assertIsNone(row["pid"])
        self.assertEqual(row["work_count"], 0)

    def test_fence_after_spawn_before_registration_prevents_work_and_allows_verified_cleanup(self):
        observed, inherited = socket.socketpair(socket.AF_UNIX, socket.SOCK_DGRAM)
        self.addCleanup(observed.close)
        self.addCleanup(inherited.close)
        observed.settimeout(5)
        manager = self.spawn(self.request(), mode="before_registration", observer=inherited)
        self.marker(manager, b"UNREGISTERED")
        body, ancillary, flags, _address = observed.recvmsg(1024, socket.CMSG_SPACE(4))
        self.assertFalse(flags & (socket.MSG_TRUNC | socket.MSG_CTRUNC))
        self.assertEqual(len(ancillary), 1)
        self.assertEqual(ancillary[0][:2], (socket.SOL_SOCKET, socket.SCM_RIGHTS))
        descriptors = array.array("i")
        descriptors.frombytes(ancillary[0][2])
        self.assertEqual(len(descriptors), 1)
        descriptor = self.retain(descriptors[0])
        child_pid = json.loads(body)["pid"]
        self.assertFalse(exited(descriptor))
        self.assertIsNone(self.row()["pid"])
        fenced = self.receipt("fence")
        self.assertIsNone(fenced["execution_started"])
        self.assertTrue(fenced["future_creates_refused"])
        manager.send_signal(signal.SIGUSR1)
        response, status = self.finish(manager)
        self.assertEqual(status, 0, response)
        until = time.monotonic() + 3
        while self.row()["pid"] is None and time.monotonic() < until:
            time.sleep(0.01)
        self.assertEqual(self.row()["pid"], child_pid)
        self.assertEqual(self.row()["work_count"], 0)
        self.assertEqual(list(self.db.parent.glob("*.sha256")), [])
        terminated = self.receipt("terminate")
        self.assertTrue(terminated["termination_verified"])
        self.assertIsNone(terminated["execution_started"])
        self.assertTrue(exited(descriptor, 2_000))

    def test_fence_after_live_work_retains_binding_and_only_terminate_confirms_kernel_exit(self):
        running, descriptor = self.started()
        fenced = self.receipt("fence")
        self.assert_binding(running, fenced)
        self.assertTrue(fenced["future_creates_refused"])
        self.assertFalse(fenced["termination_verified"])
        self.assertFalse(exited(descriptor), "fence acknowledgement is not a termination observation")
        self.assert_error(self.send(self.request()), "effect_fenced", 1)
        terminated = self.receipt("terminate")
        self.assertEqual(terminated["state"], "terminated")
        self.assertTrue(terminated["termination_verified"])
        self.assertTrue(exited(descriptor, 2_000))
        self.assert_binding(running, terminated)
        self.assert_binding(terminated, self.receipt())
        self.assertEqual(self.receipt("terminate"), terminated)
        self.assert_error(self.send(self.request()), "effect_fenced", 1)
        self.evidence("live-fence-terminate", {"running": running, "fence": fenced,
                      "termination": terminated, "live_after_fence_observed": True,
                      "independent_pidfd_exit_observed": True})

    def replace_identity(self, identity):
        # Explicit corruption in this test's own database, with the original
        # schema restored before the real provider observes the forged row.
        with sqlite3.connect(self.db) as connection:
            trigger = connection.execute(
                "SELECT sql FROM sqlite_schema WHERE type='trigger' AND name='worker_binding'").fetchone()[0]
            connection.execute("DROP TRIGGER worker_binding")
            connection.execute("UPDATE local_workers SET boot_id=?,pid=?,start_ticks=? WHERE effect_id=?",
                               (identity["boot_id"], identity["pid"], identity["start_ticks"], self.effect))
            connection.execute(trigger)

    def test_forged_or_stale_identity_never_signals_an_unrelated_child(self):
        running, descriptor = self.started()
        unrelated = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(20)"])
        self.addCleanup(self.stop_manager, unrelated)
        unrelated_descriptor = self.retain(os.pidfd_open(unrelated.pid))
        original = running["worker_identity"]
        for forged in ({**original, "start_ticks": original["start_ticks"] + 1},
                       kernel_identity(unrelated.pid)):
            with self.subTest(forged=forged):
                self.replace_identity(forged)
                try:
                    refused = self.receipt("terminate")
                    self.assertFalse(refused["termination_verified"])
                    self.assertEqual(refused["ambiguity"], "worker_unreachable")
                    self.assertFalse(exited(unrelated_descriptor))
                    self.assertFalse(exited(descriptor))
                    self.assertIsNone(unrelated.poll())
                finally:
                    self.replace_identity(original)
        self.assertTrue(self.receipt("terminate")["termination_verified"])
        self.assertTrue(exited(descriptor, 2_000))
        self.assertFalse(exited(unrelated_descriptor))

    def test_missing_or_replaced_store_cannot_resume_or_terminate_under_the_old_pin(self):
        running, descriptor = self.started()
        self.db.rename(self.db.with_suffix(".retained"))
        for operation in ("create", "lookup", "fence", "terminate"):
            self.assert_error(self.send(self.request(operation)), "store_missing")
        self.assertFalse(self.db.exists())
        replacement, status = self.invoke("init")
        self.assertEqual(status, 0)
        self.assertNotEqual(replacement["store_id"], self.store_id)
        for operation in ("create", "lookup", "fence", "terminate"):
            self.assert_error(self.send(self.request(operation)), "store_identity_mismatch")
        self.assertEqual(self.rows_count(), 0)
        self.assertFalse(exited(descriptor), "old pin must not signal the original live child")
        self.evidence("store-replacement", {"original": running,
                      "replacement_store_id": replacement["store_id"],
                      "old_pinned_operations_refused": True,
                      "original_child_still_live_via_pidfd": True})

    def test_fixed_worker_deadline_is_observed_by_kernel_exit_without_fabricated_termination(self):
        self.deadline = self.after(2)
        running, descriptor = self.started()
        self.assertTrue(exited(descriptor, 5_000), "fixed child exceeded its bounded deadline")
        observed = self.receipt()
        self.assert_binding(running, observed)
        self.assertFalse(observed["termination_verified"])
        self.assertEqual(observed["ambiguity"], "worker_unreachable")
        self.assert_error(self.send(self.request()), "deadline_expired", 1)
        self.evidence("deadline", {"running": running, "after_deadline": observed,
                      "independent_pidfd_exit_observed": True,
                      "provider_did_not_infer_verified_termination": True})

    def test_expired_create_and_conflicting_binding_do_not_allocate_or_replace_worker(self):
        self.assert_error(self.send(self.request(execution_deadline=self.after(-1))), "deadline_expired", 1)
        self.assertEqual(self.rows_count(), 0)
        running, descriptor = self.started()
        self.assert_error(self.send(self.request(plan_digest="b" * 64)), "binding_conflict", 1)
        self.assert_error(self.send(self.request(execution_deadline=self.deadline.replace("Z", "+00:00"))),
                          "binding_conflict", 1)
        self.assert_binding(running, self.receipt())
        self.assertFalse(exited(descriptor))

    def test_closed_protocol_never_accepts_arbitrary_workload_or_command(self):
        cases = [self.request(command="anything"), self.request(workload="arbitrary"),
                 self.request(operation="exec"), self.request(plan_digest="A" * 64),
                 self.request(effect_id="agent-run:../elsewhere"),
                 {**self.request("terminate"), "pid": os.getpid()}]
        for request in cases:
            with self.subTest(request=request):
                self.assert_error(self.send(request), "invalid_request")
        for raw in (b"{} {}", b"[]", b"x" * 8193,
                    b'{"store_id":"x","store_id":"y"}'):
            response, status = self.invoke("request", raw=raw)
            self.assertEqual((status, response), (2, {"schema": ERROR_SCHEMA,
                             "error": "invalid_request", "store_id": None}))
        self.assertEqual(self.rows_count(), 0)


if __name__ == "__main__":
    unittest.main()
