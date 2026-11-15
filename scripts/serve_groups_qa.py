"""Loopback-only coordinator for four synthetic group-browser QA roles."""

import argparse
import json
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse


ROLES = {"a", "b", "c", "d"}
PHASES = {
    "swarm-ready",
    "ready",
    "members",
    "messages",
    "seed-ready",
    "seed-offline",
    "reload-needed",
    "d-reloaded",
    "d-complete",
    "crossfill",
    "done",
}
CARDS = {}
ARRIVALS = {phase: set() for phase in PHASES}


class Handler(SimpleHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def reply(self, value, code=200):
        body = json.dumps(value, separators=(",", ":")).encode()
        self.send_response(code)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.send_header("cache-control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def read_json(self):
        try:
            count = int(self.headers.get("content-length", "0"))
            if not 0 < count <= 16384:
                return None
            value = json.loads(self.rfile.read(count))
            return value if isinstance(value, dict) else None
        except (ValueError, json.JSONDecodeError):
            return None

    def do_POST(self):
        value = self.read_json()
        if value is None:
            return self.reply({"error": "invalid request"}, 400)
        if self.path == "/qa/card":
            if set(value) != {"role", "card"}:
                return self.reply({"error": "invalid card request"}, 400)
            role, card = value["role"], value["card"]
            if role not in ROLES or not isinstance(card, str) or not card or len(card.encode()) > 12000:
                return self.reply({"error": "invalid public card"}, 400)
            if role in CARDS and CARDS[role] != card:
                return self.reply({"error": "role already registered"}, 409)
            CARDS[role] = card
            return self.reply({"ok": True})
        if self.path == "/qa/phase":
            if set(value) != {"role", "name"}:
                return self.reply({"error": "invalid phase request"}, 400)
            role, name = value["role"], value["name"]
            if role not in ROLES or name not in PHASES:
                return self.reply({"error": "invalid role or phase"}, 400)
            ARRIVALS[name].add(role)
            return self.reply({"ok": True})
        return self.reply({"error": "not found"}, 404)

    def do_GET(self):
        url = urlparse(self.path)
        query = parse_qs(url.query)
        if url.path == "/qa/peers":
            role = query.get("role", [""])[0]
            if role not in ROLES:
                return self.reply({"error": "invalid role"}, 400)
            visible = set(CARDS) - {role}
            if role != "a":
                visible &= {"a"}
            return self.reply({"cards": {peer: CARDS[peer] for peer in sorted(visible)}})
        if url.path == "/qa/phase":
            name = query.get("name", [""])[0]
            if name not in PHASES:
                return self.reply({"error": "invalid phase"}, 400)
            return self.reply({"roles": sorted(ARRIVALS[name])})
        if url.path.startswith("/qa/"):
            return self.reply({"error": "not found"}, 404)
        return super().do_GET()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", required=True)
    parser.add_argument("--port", type=int, default=41750)
    args = parser.parse_args()
    server = ThreadingHTTPServer(
        ("127.0.0.1", args.port),
        lambda *a, **kw: Handler(*a, directory=args.directory, **kw),
    )
    server.serve_forever()
