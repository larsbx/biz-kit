"""Stand-in for biz-kit-stack in the failure-injection suite.

Serves 127.0.0.1:18401 and :18400, or exits at once when the checkout contains
STACK_BROKEN or the flag file outside it exists.
"""
import http.server
import os
import sys
import threading

repo, flag = sys.argv[1], sys.argv[2]
if os.path.exists(os.path.join(repo, "STACK_BROKEN")) or os.path.exists(flag):
    sys.exit("broken on purpose")


class Ok(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(404)
        self.end_headers()

    def log_message(self, *args):
        pass


servers = [http.server.ThreadingHTTPServer(("127.0.0.1", p), Ok) for p in (18401, 18400)]
for s in servers[1:]:
    threading.Thread(target=s.serve_forever, daemon=True).start()
servers[0].serve_forever()
