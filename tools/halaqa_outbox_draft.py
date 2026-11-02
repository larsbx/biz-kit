"""Offline sender custody and in-process two-database delivery experiment.

No Iroh or HTTP client. LocalReceiptPeer is a trusted synthetic callback, not
authenticated transport or a production identity/disclosure policy adapter.
"""
import base64
import json

from halaqa_receipt_draft import ReceiptDraft, sql_bytes, sql_text


def positive_integer(value):
    if type(value) is not int or not 1 <= value <= 2**63 - 1:
        raise ValueError("positive int64 required")
    return str(value)


class OutboxDraft(ReceiptDraft):
    def stage(self, wire, test_policy):
        self.signed.verify(wire, test_policy)
        candidate = base64.b64decode(json.loads(wire)["candidate"], validate=True)
        args = [sql_bytes(candidate), sql_bytes(wire), sql_text(json.dumps(test_policy)) + "::jsonb"]
        return self.query("SELECT halaqa_receipt_draft.stage_intent(" + ",".join(args) + ")")

    def intent(self, intent_id):
        return self.query("SELECT halaqa_receipt_draft.get_intent(" + positive_integer(intent_id) + ")")

    def begin(self, intent_id):
        return self.query("SELECT halaqa_receipt_draft.begin_attempt(" + positive_integer(intent_id) + ")")

    def finish(self, intent_id, generation, reply):
        args = [positive_integer(intent_id), positive_integer(generation),
                sql_text(json.dumps(reply)) + "::jsonb"]
        return self.query("SELECT halaqa_receipt_draft.finish_attempt(" + ",".join(args) + ")")

    def pending(self, sender, recipient, after=0, limit=16):
        if type(after) is not int or not 0 <= after <= 2**63 - 1:
            raise ValueError("invalid pending offset")
        if type(limit) is not int or not 1 <= limit <= 16:
            raise ValueError("pending limit must be 1..16")
        args = [sql_text(sender), sql_text(recipient), str(after), str(limit)]
        return self.query("SELECT halaqa_receipt_draft.pending_intents(" + ",".join(args) + ")")

    def advance(self, intent_id, peer, current_test_policy):
        # Commit UNKNOWN before any callback. A crash/timeout keeps this intent
        # reconcilable; it never becomes proof of non-delivery.
        item = self.begin(intent_id)
        if item["state"] in ("CONFIRMED_TEST_ONLY", "REMOTE_CONFLICT"):
            return item
        if peer.recipient != item["recipient"]:
            raise ValueError("fixture peer recipient mismatch")
        reply = peer.status(item["recipient"], item["sender"], item["message_id"],
                            bytes.fromhex(item["candidate_sha256"]))
        not_found = (type(reply) is dict
                     and set(reply) == {"status", "authority_verified", "production_receiver"}
                     and reply["status"] == "NOT_FOUND"
                     and reply["authority_verified"] is False
                     and reply["production_receiver"] is False)
        if not_found:
            # Inspect current fixture policy, not the captured staging clock.
            # An expired undelivered envelope requires explicit refresh work;
            # never silently re-sign it or invent a replacement message ID.
            wire = bytes.fromhex(item["wire_hex"])
            self.signed.verify(wire, current_test_policy)
            reply = peer.receive(wire)
        return self.finish(intent_id, item["generation"], reply)


class LocalReceiptPeer:
    """Explicitly bound in-process fixture peer with its own TEST policy.

    This does not prove endpoint/actor binding. Never expose it as ingress.
    """
    def __init__(self, client, test_policy):
        self.client = client
        self.test_policy = dict(test_policy)
        self.recipient = test_policy["recipient"]

    def status(self, recipient, sender, message_id, digest):
        if recipient != self.recipient or sender != self.test_policy["sender"]:
            raise ValueError("fixture status scope mismatch")
        return self.client.status(recipient, sender, message_id, digest)

    def receive(self, wire):
        return self.client.receive(wire, self.test_policy)
