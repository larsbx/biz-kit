#!/usr/bin/env python3
"""Read-only, non-authorizing preflight for a named TEST host.

This is a portable probe, not a deployment mechanism. Its JSON report has no
credentials, network endpoints, command output, environment variables or
application data. Never use it as a grant or proof of production readiness.
"""

import argparse
import datetime as dt
import json
import os
import platform
import re
import socket
import subprocess
import sys


UNIT_RE = re.compile(r"\A[a-zA-Z0-9_.@-]+\.service\Z")


def command(argv):
    """Run only fixed read-only commands, and never return raw stderr."""
    try:
        return subprocess.run(
            argv, check=False, capture_output=True, text=True, timeout=10
        )
    except (FileNotFoundError, PermissionError, subprocess.TimeoutExpired):
        return None


def record(checks, check_id, status, detail):
    checks.append({"check": check_id, "status": status, "detail": detail})


def parse_podman_rootless(output):
    try:
        info = json.loads(output)
        host = info.get("host", info.get("Host", {}))
        security = host.get("security", host.get("Security", {}))
        flag = security.get("rootless", security.get("Rootless"))
        return flag if isinstance(flag, bool) else None
    except (ValueError, AttributeError, TypeError):
        return None


def audit(expected_host, environment, min_free_gib=4, required_units=()):
    if environment != "test":
        raise ValueError("only the test environment is supported")
    if not expected_host or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9.-]{0,252}", expected_host):
        raise ValueError("invalid expected hostname")
    if min_free_gib < 1 or min_free_gib > 100_000:
        raise ValueError("invalid minimum free GiB")
    for unit in required_units:
        if not UNIT_RE.fullmatch(unit):
            raise ValueError("invalid systemd unit name")

    checks = []
    record(
        checks, "hostname", "pass" if socket.gethostname() == expected_host else "fail",
        "matches independently selected target" if socket.gethostname() == expected_host
        else "unexpected target hostname"
    )
    record(
        checks, "linux", "pass" if platform.system() == "Linux" else "fail",
        "Linux detected" if platform.system() == "Linux" else "host is not Linux"
    )
    record(
        checks, "non_root", "pass" if os.geteuid() != 0 else "fail",
        "not running as root" if os.geteuid() != 0 else "root execution refused"
    )

    try:
        stat = os.statvfs("/")
        free_bytes = stat.f_bavail * stat.f_frsize
        free_inodes = stat.f_favail
        free_ok = free_bytes >= min_free_gib * 1024 ** 3 and free_inodes > 1000
        record(checks, "root_filesystem_headroom", "pass" if free_ok else "fail",
               "free bytes and inodes meet minimum" if free_ok else "insufficient free bytes or inodes")
    except OSError:
        record(checks, "root_filesystem_headroom", "fail", "filesystem statistics unavailable")

    manager = command(
        ["systemctl", "--user", "list-units", "--type=service",
         "--no-pager", "--plain", "--no-legend"]
    )
    record(checks, "user_systemd", "pass" if manager is not None and manager.returncode == 0 else "fail",
           "user manager responsive" if manager is not None and manager.returncode == 0
           else "user manager unavailable")

    podman = command(["podman", "info", "--format", "json"])
    rootless = (
        parse_podman_rootless(podman.stdout) if podman is not None and podman.returncode == 0
        else None
    )
    record(checks, "podman_rootless", "pass" if rootless is True else "fail",
           "rootless runtime verified" if rootless is True else "rootless runtime not verified")

    for index, unit in enumerate(required_units, start=1):
        state = command(["systemctl", "--user", "is-active", unit])
        active = state is not None and state.returncode == 0 and state.stdout.strip() == "active"
        record(checks, "required_service_%d" % index, "pass" if active else "fail",
               "requested service active" if active else "requested service not active")

    sockets = command(["ss", "-H", "-ltn"])
    if sockets is None or sockets.returncode != 0:
        record(checks, "tcp_listener_review", "warn", "listener inventory unavailable")
    else:
        wildcard_count = 0
        for line in sockets.stdout.splitlines():
            columns = line.split()
            if len(columns) < 4:
                continue
            local = columns[3]
            if local.startswith("0.0.0.0:") or local.startswith("[::]:") or local.startswith("*:"):
                wildcard_count += 1
        record(checks, "tcp_listener_review", "warn" if wildcard_count else "pass",
               "wildcard listeners require separate firewall review" if wildcard_count
               else "no wildcard listeners observed")

    return {
        "schema": "biz-kit-test-host-preflight-v1",
        "environment": "test",
        "observed_at_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
        "deployment_authorized": False,
        "live_deployment_verified": False,
        "checks": checks,
        "result": "fail" if any(item["status"] == "fail" for item in checks)
        else "review" if any(item["status"] == "warn" for item in checks) else "pass",
    }


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--environment", choices=("test",), required=True)
    parser.add_argument("--expected-host", required=True,
                        help="Exact hostname chosen outside the host; do not use $(hostname)")
    parser.add_argument("--min-free-gib", type=int, default=4)
    parser.add_argument("--require-unit", action="append", default=[])
    args = parser.parse_args(argv)
    try:
        report = audit(args.expected_host, args.environment, args.min_free_gib,
                       args.require_unit)
    except ValueError as exc:
        parser.error(str(exc))
    print(json.dumps(report, sort_keys=True, separators=(",", ":")))
    return 2 if report["result"] == "fail" else 0


if __name__ == "__main__":
    sys.exit(main())
