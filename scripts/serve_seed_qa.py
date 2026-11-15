"""Loopback-only coordinator for two disposable browser test identities."""
import argparse
import json
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

CARDS = {}
FLAGS = {name: set() for name in ("ready", "stopped", "done")}


class Handler(SimpleHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def reply(self, value, code=200):
        body = json.dumps(value).encode()
        self.send_response(code)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.send_header("cache-control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        count = int(self.headers.get("content-length", "0"))
        if not 0 < count <= 16384:
            return self.reply({}, 400)
        value = json.loads(self.rfile.read(count))
        role = value.get("role")
        if role not in ("a", "b"):
            return self.reply({}, 400)
        if self.path == "/qa/card" and isinstance(value.get("card"), str):
            CARDS[role] = value["card"]
        elif self.path.startswith("/qa/") and self.path[4:] in FLAGS:
            FLAGS[self.path[4:]].add(role)
        else:
            return self.reply({}, 404)
        self.reply({"ok": True})

    def do_GET(self):
        url = urlparse(self.path)
        if url.path == "/qa/peer":
            role = parse_qs(url.query).get("role", [""])[0]
            return self.reply({"card": CARDS.get("b" if role == "a" else "a")})
        if url.path.startswith("/qa/") and url.path[4:] in FLAGS:
            return self.reply({"both": FLAGS[url.path[4:]] == {"a", "b"}})
        super().do_GET()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", required=True)
    parser.add_argument("--port", type=int, default=41749)
    args = parser.parse_args()
    ThreadingHTTPServer(("127.0.0.1", args.port), lambda *a, **kw: Handler(*a, directory=args.directory, **kw)).serve_forever()
