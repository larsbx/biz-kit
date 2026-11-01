"""Explicit loopback Iroh fixture transport; no production activation.

Endpoint pins and their actor mappings are local TEST configuration. They do
not implement real identity succession, grants, fresh revocation or authority.
"""
import base64
import json
import secrets
import subprocess
import tempfile
import threading

from halaqa_outbox_draft import LocalReceiptPeer


def strict_json(raw, limit):
    if type(raw) is not bytes or not 1 <= len(raw) <= limit:
        raise ValueError("transport JSON bound")
    depth, quoted, escaped = 0, False, False
    for char in raw:
        if quoted:
            if escaped:
                escaped = False
            elif char == 92:
                escaped = True
            elif char == 34:
                quoted = False
        elif char == 34:
            quoted = True
        elif char in (123, 91):
            depth += 1
            if depth > 8:
                raise ValueError("transport JSON depth")
        elif char in (125, 93):
            depth -= 1

    def unique(pairs):
        value = {}
        for key, item in pairs:
            if key in value:
                raise ValueError("duplicate transport key")
            value[key] = item
        return value

    def invalid(_):
        raise ValueError("invalid transport constant")

    return json.loads(raw.decode("utf8"), object_pairs_hook=unique, parse_constant=invalid)


def canonical(value, limit):
    if type(value) is not str or len(value) > ((limit + 2) // 3) * 4:
        raise ValueError("transport encoding bound")
    raw = base64.b64decode(value, validate=True)
    if not raw or len(raw) > limit or base64.b64encode(raw).decode() != value:
        raise ValueError("transport body encoding")
    return raw


def identity(binary, key_file):
    result = subprocess.run([str(binary), "identity"],
                            input=json.dumps({"key_file": str(key_file)}).encode() + b"\n",
                            capture_output=True, timeout=10, check=True)
    return strict_json(result.stdout, 1024)["endpoint"]


def check_path(value, relay):
    mode = "relay_only" if relay else "direct"
    if (type(value) is not dict or set(value) != {"mode", "ip_bound_sockets", "paths"}
            or value["mode"] != mode or type(value["ip_bound_sockets"]) is not int
            or (relay and value["ip_bound_sockets"] != 0)
            or type(value["paths"]) is not list or not 1 <= len(value["paths"]) <= 4):
        raise ValueError("missing or mismatched path evidence")
    selected = False
    for path in value["paths"]:
        if (type(path) is not dict
                or set(path) != {"kind", "selected", "address", "tx_bytes", "rx_bytes", "stream_rx"}
                or path["kind"] != ("relay" if relay else "direct")
                or type(path["selected"]) is not bool
                or type(path["address"]) is not str or len(path["address"]) > 512
                or any(type(path[k]) is not int or path[k] < 0 for k in ("tx_bytes", "rx_bytes", "stream_rx"))):
            raise ValueError("invalid path evidence")
        if relay and path["address"] != "relay:" + relay["url"].rstrip("/") + "/":
            raise ValueError("unexpected relay path")
        selected |= path["selected"] and path["stream_rx"] > 0 and path["rx_bytes"] > 0
    if not selected:
        raise ValueError("no selected receiving path")
    return value


class IrohReceiptPeer:
    def __init__(self, binary, key_file, target, sender, recipient, relay=None):
        self.binary, self.key_file = str(binary), str(key_file)
        self.target = target
        self.sender, self.recipient = sender, recipient
        self.relay = relay
        self.path_evidence = []
        self.challenges = []  # bounded to the last two requests, test inspection only

    def request(self, request):
        challenge = secrets.token_hex(32)
        request = {**request, "challenge": challenge}
        self.challenges = (self.challenges + [challenge])[-2:]
        config = {"key_file": self.key_file, "bind": "127.0.0.1:0",
                  "target": self.target, "request": request}
        if self.relay is not None:
            config["relay"] = self.relay
        result = subprocess.run([self.binary, "client"], input=json.dumps(config).encode() + b"\n",
                                capture_output=True, timeout=20, check=True)
        response = strict_json(result.stdout, 16_000)
        if (type(response) is not dict or set(response) != {"event", "peer", "challenge", "reply", "path"}
                or response["event"] != "reply" or response["peer"] != self.target["id"]
                or response["challenge"] != challenge):
            raise ValueError("unbound transport response")
        evidence = check_path(response["path"], self.relay)
        self.path_evidence = (self.path_evidence + [evidence])[-8:]
        return strict_json(canonical(response["reply"], 8192), 8192)

    def status(self, recipient, sender, message_id, digest):
        if recipient != self.recipient or sender != self.sender or len(digest) != 32:
            raise ValueError("fixture status scope mismatch")
        return self.request({"op": "status", "recipient": recipient, "sender": sender,
                             "message_id": message_id, "candidate_sha256": digest.hex()})

    def receive(self, wire):
        if type(wire) is not bytes or not 1 <= len(wire) <= 12_288:
            raise ValueError("wire limit")
        return self.request({"op": "deliver", "wire": base64.b64encode(wire).decode()})


class IrohReceiverFixture:
    """Owns a test sidecar and its private stdin/stdout, not a deployment API."""
    def __init__(self, binary, key_file, allowed_endpoint, receiver, policy, relay=None):
        self.peer = LocalReceiptPeer(receiver, policy)
        self.allowed_endpoint = allowed_endpoint
        self.relay = relay
        self.path_evidence = []
        self.ready = threading.Event()
        self.delivery_count = 0
        self.error = None
        self.address = None
        self.requests = []  # bounded recent metadata, never original payload storage
        self.drop_next_delivery_reply = False
        self.corrupt_next_challenge = False
        self.stderr = tempfile.TemporaryFile()
        self.process = subprocess.Popen([str(binary), "server"], stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=self.stderr)
        config = {"key_file": str(key_file), "bind": "127.0.0.1:0",
                  "allowed_endpoint": allowed_endpoint, "sender": policy["sender"],
                  "recipient": policy["recipient"]}
        if relay is not None:
            config["relay"] = relay
        self.process.stdin.write(json.dumps(config).encode() + b"\n")
        self.process.stdin.flush()
        self.thread = threading.Thread(target=self._serve, daemon=True)
        self.thread.start()
        if not self.ready.wait(10) or self.error or self.address is None:
            self.close()
            raise RuntimeError("Iroh fixture startup failed") from self.error

    def _serve(self):
        try:
            while raw := self.process.stdout.readline(32_001):
                event = strict_json(raw, 32_000)
                if event.get("event") == "ready":
                    if (event.get("application_http") is not False
                            or event.get("relay") is not bool(self.relay)
                            or (self.relay and event.get("ip_bound_sockets") != 0)):
                        raise ValueError("unexpected transport activation")
                    self.address = event["address"]
                    self.ready.set()
                    continue
                if event.get("event") != "request":
                    raise ValueError("unknown sidecar event")
                if event["peer"] != self.allowed_endpoint:
                    raise ValueError("sidecar endpoint binding mismatch")
                self.path_evidence = (self.path_evidence + [check_path(event["path"], self.relay)])[-8:]
                request = event["request"]
                self.delivery_count += request["op"] == "deliver"
                self.requests = (self.requests + [(event["peer"], request["op"], request["challenge"])])[-8:]
                command = {"op": "drop", "request_id": event["request_id"]}
                try:
                    if request["op"] == "status":
                        result = self.peer.status(request["recipient"], request["sender"],
                                                  request["message_id"], bytes.fromhex(request["candidate_sha256"]))
                    else:
                        result = self.peer.receive(canonical(request["wire"], 12_288))
                    if self.drop_next_delivery_reply and request["op"] == "deliver":
                        self.drop_next_delivery_reply = False  # SQL has committed; lose only its reply.
                    else:
                        challenge = request["challenge"]
                        if self.corrupt_next_challenge:
                            challenge = "ff" * 32
                            self.corrupt_next_challenge = False
                        command = {"op": "respond", "request_id": event["request_id"],
                                   "challenge": challenge,
                                   "reply": base64.b64encode(json.dumps(result).encode()).decode()}
                except (ValueError, subprocess.SubprocessError):
                    pass  # No ACK for refused verification or an unknown SQL outcome.
                self.process.stdin.write(json.dumps(command).encode() + b"\n")
                self.process.stdin.flush()
        except Exception as error:
            self.error = error
        finally:
            self.ready.set()

    def close(self):
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=5)
        self.thread.join(timeout=5)
        self.process.stdin.close()
        self.process.stdout.close()
        self.stderr.close()
