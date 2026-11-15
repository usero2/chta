#!/usr/bin/env python3
"""Serve the cht Web build and provide ephemeral local signaling rooms."""

from __future__ import annotations

import argparse
import json
import secrets
import threading
import time
from http import HTTPStatus
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse


ROOM_TTL_SECONDS = 10 * 60
MAX_SIGNAL_BYTES = 128 * 1024


class RoomStore:
    def __init__(self) -> None:
        self._rooms: dict[str, dict[str, object]] = {}
        self._lock = threading.Lock()

    def create(self, offer: str) -> str:
        with self._lock:
            self._prune()
            while True:
                code = f"{secrets.randbelow(1_000_000):06d}"
                if code not in self._rooms:
                    self._rooms[code] = {
                        "offer": offer,
                        "answer": None,
                        "created": time.monotonic(),
                    }
                    return code

    def offer(self, code: str) -> str | None:
        with self._lock:
            self._prune()
            room = self._rooms.get(code)
            return None if room is None else str(room["offer"])

    def set_answer(self, code: str, answer: str) -> bool:
        with self._lock:
            self._prune()
            room = self._rooms.get(code)
            if room is None:
                return False
            room["answer"] = answer
            return True

    def answer(self, code: str) -> str | None:
        with self._lock:
            self._prune()
            room = self._rooms.get(code)
            if room is None or room["answer"] is None:
                return None
            return str(room["answer"])

    def exists(self, code: str) -> bool:
        with self._lock:
            self._prune()
            return code in self._rooms

    def _prune(self) -> None:
        cutoff = time.monotonic() - ROOM_TTL_SECONDS
        expired = [
            code for code, room in self._rooms.items() if room["created"] < cutoff
        ]
        for code in expired:
            del self._rooms[code]


ROOMS = RoomStore()


def should_serve_app_shell(request_path: str, directory: Path) -> bool:
    """Return true for client-side routes that do not map to static files."""
    relative = request_path.lstrip("/")
    if not relative or request_path.startswith("/api/"):
        return False
    return Path(relative).suffix == "" and not (directory / relative).is_file()


class ChtDevHandler(SimpleHTTPRequestHandler):
    def end_headers(self) -> None:
        self.send_header("Cache-Control", "no-store, max-age=0")
        self.send_header("Pragma", "no-cache")
        super().end_headers()

    def do_POST(self) -> None:  # noqa: N802
        path = urlparse(self.path).path
        try:
            payload = self._read_json()
        except (ValueError, json.JSONDecodeError):
            self._json(HTTPStatus.BAD_REQUEST, {"error": "Invalid request"})
            return

        if path == "/api/rooms":
            offer = payload.get("offer")
            if not isinstance(offer, str) or not offer:
                self._json(HTTPStatus.BAD_REQUEST, {"error": "Offer is required"})
                return
            self._json(HTTPStatus.CREATED, {"code": ROOMS.create(offer)})
            return

        parts = path.strip("/").split("/")
        if len(parts) == 4 and parts[:2] == ["api", "rooms"] and parts[3] == "answer":
            code = parts[2]
            answer = payload.get("answer")
            if not isinstance(answer, str) or not answer:
                self._json(HTTPStatus.BAD_REQUEST, {"error": "Answer is required"})
            elif not ROOMS.set_answer(code, answer):
                self._json(HTTPStatus.NOT_FOUND, {"error": "Room not found"})
            else:
                self._json(HTTPStatus.OK, {"status": "ready"})
            return

        self._json(HTTPStatus.NOT_FOUND, {"error": "Not found"})

    def do_GET(self) -> None:  # noqa: N802
        path = urlparse(self.path).path
        parts = path.strip("/").split("/")
        if len(parts) == 4 and parts[:2] == ["api", "rooms"]:
            code, resource = parts[2], parts[3]
            if resource == "offer":
                offer = ROOMS.offer(code)
                if offer is None:
                    self._json(HTTPStatus.NOT_FOUND, {"error": "Room not found"})
                else:
                    self._json(HTTPStatus.OK, {"offer": offer})
                return
            if resource == "answer":
                if not ROOMS.exists(code):
                    self._json(HTTPStatus.NOT_FOUND, {"error": "Room not found"})
                    return
                answer = ROOMS.answer(code)
                if answer is None:
                    self._json(HTTPStatus.ACCEPTED, {"status": "waiting"})
                else:
                    self._json(HTTPStatus.OK, {"answer": answer})
                return
        if should_serve_app_shell(path, Path(self.directory)):
            self.path = "/index.html"
        super().do_GET()

    def _read_json(self) -> dict[str, object]:
        length = int(self.headers.get("Content-Length", "0"))
        if length <= 0 or length > MAX_SIGNAL_BYTES:
            raise ValueError("Invalid request size")
        value = json.loads(self.rfile.read(length))
        if not isinstance(value, dict):
            raise ValueError("Expected an object")
        return value

    def _json(self, status: HTTPStatus, payload: dict[str, object]) -> None:
        encoded = json.dumps(payload, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def log_message(self, message: str, *args: object) -> None:
        if not self.path.startswith("/api/"):
            super().log_message(message, *args)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=7357)
    parser.add_argument(
        "--directory",
        type=Path,
        default=Path(__file__).resolve().parents[1] / "apps" / "flutter_app" / "build" / "web",
    )
    args = parser.parse_args()
    directory = args.directory.resolve()
    if not directory.is_dir():
        raise SystemExit(f"Web build not found: {directory}")

    handler = lambda *handler_args, **handler_kwargs: ChtDevHandler(  # noqa: E731
        *handler_args,
        directory=str(directory),
        **handler_kwargs,
    )
    server = ThreadingHTTPServer(("127.0.0.1", args.port), handler)
    print(f"cht dev server: http://localhost:{args.port}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
