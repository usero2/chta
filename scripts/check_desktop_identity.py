"""Exercise the built Windows DLL in separate processes with isolated APPDATA."""
from __future__ import annotations

import ctypes
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor


def run_child(library_path: str, mode: str) -> None:
    library = ctypes.CDLL(library_path)
    library.cht_call.argtypes = [ctypes.c_char_p]
    library.cht_call.restype = ctypes.c_void_p
    library.cht_free_string.argtypes = [ctypes.c_void_p]
    library.cht_free_string.restype = None

    def call(command: str, **args: object) -> object:
        pointer = library.cht_call(json.dumps({"command": command, "args": args}).encode())
        try:
            result = json.loads(ctypes.string_at(pointer))
        finally:
            library.cht_free_string(pointer)
        if not result["ok"]:
            raise RuntimeError(result["error"])
        return result["value"]

    if mode == "save":
        created = call("createIdentity")
        identity = call("confirmRecovery", phrase=created["mnemonic"])
        call("rememberIdentity", pin="123456789", displayName="Desktop test identity")
        call("sendText", conversationId="general", text="Persisted desktop fixture", sentAtMilliseconds=1)
        for file in (Path(os.environ["APPDATA"]) / "cht" / "identities").glob("*.json"):
            source = file.read_text()
            assert created["mnemonic"] not in source
            assert "123456789" not in source
            assert '"entropy"' not in source
        print(json.dumps({"identityId": identity["id"]}))
    else:
        identities = call("listSavedIdentities")
        assert len(identities) == 1
        assert not call("hasIdentity")
        with ThreadPoolExecutor(max_workers=1) as executor:
            identity = executor.submit(
                lambda: call("unlockIdentity", identityId=identities[0]["identityId"], pin="123456789")
            ).result()
        assert identity["id"] == identities[0]["identityId"]
        assert call("hasIdentity"), "Native runtime must be shared across FFI worker threads"
        assert call("loadDesktopProfile")["name"] == "Desktop test identity"
        assert "Persisted desktop fixture" in json.dumps(call("snapshot"))
        call("lockIdentity")
        assert not call("hasIdentity")
        print(json.dumps({"restoredAfterRestart": True, "workerThreadUnlock": True, "locked": True}))


def main() -> None:
    if len(sys.argv) == 4 and sys.argv[1] == "--child":
        run_child(sys.argv[2], sys.argv[3])
        return
    root = Path(__file__).resolve().parents[1]
    library = root / "apps/flutter_app/build/windows/x64/runner/Release/cht_core.dll"
    if len(sys.argv) == 2:
        library = Path(sys.argv[1]).resolve()
    with tempfile.TemporaryDirectory(prefix="cht-desktop-login-check-") as directory:
        environment = {**os.environ, "APPDATA": directory}
        for mode in ("save", "unlock"):
            result = subprocess.run(
                [sys.executable, __file__, "--child", str(library), mode],
                env=environment, text=True, capture_output=True, check=True,
            )
            if mode == "unlock":
                print(result.stdout.strip())


if __name__ == "__main__":
    main()
