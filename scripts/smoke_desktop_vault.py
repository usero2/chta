"""Exercise the Rust library shipped in the desktop package with an OS keyring."""

import ctypes
import json
from pathlib import Path
import subprocess
import sys


PIN = "619427"
HISTORY = '{"fixture":"desktop-package-smoke"}'


def bridge(path):
    lib = ctypes.CDLL(path)
    lib.cht_call.argtypes = [ctypes.c_char_p]
    lib.cht_call.restype = ctypes.c_void_p
    lib.cht_free_string.argtypes = [ctypes.c_void_p]
    lib.cht_free_string.restype = None

    def call(command, expect_ok=True, **args):
        result = lib.cht_call(json.dumps({"command": command, "args": args}).encode())
        try:
            response = json.loads(ctypes.string_at(result))
        finally:
            lib.cht_free_string(result)
        if response["ok"] != expect_ok:
            raise RuntimeError(f'{command}: {response.get("error", "unexpected success")}')
        return response.get("value")

    return call


def main():
    library = str(Path(sys.argv[1]).resolve())
    call = bridge(library)
    if len(sys.argv) > 2:
        owner = sys.argv[2]
        assert any(item["identityId"] == owner for item in call("listSavedIdentities"))
        call("unlockIdentity", expect_ok=False, identityId=owner, pin="000000")
        assert call("unlockIdentity", identityId=owner, pin=PIN)["id"] == owner
        assert call("loadPeerHistory", ownerId=owner) == HISTORY
        return

    phrase = " ".join(["abandon"] * 23 + ["art"])
    identity = call("restoreIdentity", phrase=phrase)
    owner = identity["id"]
    call("rememberIdentity", pin=PIN, displayName="Desktop smoke test")
    call("savePeerHistory", ownerId=owner, source=HISTORY)
    call("lockIdentity")
    assert not call("hasIdentity")
    call("loadPeerHistory", expect_ok=False, ownerId=owner)
    subprocess.run([sys.executable, __file__, library, owner], check=True)
    print("Verified desktop keyring, PIN and encrypted history across restarts")


if __name__ == "__main__":
    main()
