"""Replay Biz-kit's URL against Ship's real HTTP handler with a disposable bundle."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import threading
import unittest
from tempfile import TemporaryDirectory
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

from control.api import Server
from control.core import Store, token_hash
from control.graft import INTEGRITY_ONLY
from control.graft_source import source_url


TASK_HOST = Path(__file__).resolve().parents[2]
REVIEWER = "reviewer-" + "r" * 40
OUTSIDER = "outsider-" + "o" * 40


class ReviewHandoff(unittest.TestCase):
    def test_exact_review_scope_catalog_change_and_outage(self):
        with TemporaryDirectory() as temp:
            root = Path(temp)
            repo = root / "repo"
            repo.mkdir()
            bundles = root / "bundles"
            bundles.mkdir(mode=0o700)

            def git(*args):
                return subprocess.check_output(
                    ["git", "-C", str(repo), "-c", "user.name=Review Fixture",
                     "-c", "user.email=fixture@example.test", "-c", "commit.gpgsign=false",
                     "-c", "core.hooksPath=/dev/null", *args],
                    text=True,
                ).strip()

            git("init", "-q", "--template=")
            (repo / "README.md").write_text("Synthetic review fixture\n")
            git("add", "README.md")
            git("commit", "-qm", "review fixture")
            bundle = bundles / "candidate.bundle"
            git("bundle", "create", str(bundle), "HEAD")
            digest = hashlib.sha256(bundle.read_bytes()).hexdigest()
            bundle.rename(bundles / f"{digest}.bundle")
            record = {
                "repository": "larsbx/biz-kit",
                "destination": "fixture",
                "verifier": "a" * 40,
                "report": {
                    "commit": git("rev-parse", "HEAD"),
                    "tree": git("rev-parse", "HEAD^{tree}"),
                    "bundle_sha256": digest,
                    "status": INTEGRITY_ONLY,
                },
            }
            catalog = {"fixture": record}
            credentials = {
                "reviewer": {"token_sha256": token_hash(REVIEWER), "roles": [], "targets": [],
                             "graft_baselines": ["fixture"]},
                "outsider": {"token_sha256": token_hash(OUTSIDER), "roles": [], "targets": []},
            }

            with Server(("127.0.0.1", 0), Store(root / "state"), credentials, "http://127.0.0.1",
                        graft_fixtures=bundles, graft_loader=lambda: catalog) as server:
                origin = f"http://127.0.0.1:{server.server_port}"
                server.origin = origin
                thread = threading.Thread(target=server.serve_forever, daemon=True)
                thread.start()
                try:
                    url = self.biz_link(origin, record)
                    self.assertEqual(url, origin + source_url("fixture", record))
                    self.assertEqual(self.request(url)[0], 403)
                    self.assertEqual(self.request(url, OUTSIDER)[0], 404)

                    status, body = self.request(url, REVIEWER)
                    self.assertEqual(status, 200)
                    for binding in record["report"].values():
                        if binding != INTEGRITY_ONLY:
                            self.assertIn(binding, body)
                    self.assertIn("Deployment authorization: Outside this review", body)

                    catalog["fixture"] = {**record, "verifier": "b" * 40}
                    status, body = self.request(url, REVIEWER)
                    self.assertEqual(status, 409)
                    self.assertIn("graft_evidence_changed", body)
                    self.assertNotIn(record["report"]["commit"], body)
                finally:
                    server.shutdown()
                    thread.join()

            # The same link remains pinned during an outage. It never falls
            # back to the unbound baseline or a deployment route.
            self.assertEqual(self.biz_link(origin, record), url)
            with self.assertRaises(URLError) as error:
                self.request(url, REVIEWER)
            self.assertIsInstance(error.exception.reason, ConnectionRefusedError)

    def biz_link(self, origin, record):
        review = {"origin": origin, "key": "fixture", "record": record}
        env = {**os.environ, "REVIEW_FIXTURE_JSON": json.dumps(review)}
        return subprocess.check_output(
            ["elixir", "-r", str(TASK_HOST / "lib/task_host/infrastructure_review.ex"),
             "-e", """
review = System.fetch_env!("REVIEW_FIXTURE_JSON") |> :json.decode()
{:ok, url} = TaskHost.InfrastructureReview.ship_link(review, "localhost")
IO.puts(url)
"""],
            text=True, env=env,
        ).strip()

    def request(self, url, token=None):
        headers = {"Authorization": f"Bearer {token}"} if token else {}
        try:
            with urlopen(Request(url, headers=headers), timeout=3) as response:
                return response.status, response.read().decode()
        except HTTPError as error:
            with error:
                return error.code, error.read().decode()


if __name__ == "__main__":
    unittest.main()
