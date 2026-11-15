import gzip
import hashlib
import json
import tempfile
import unittest
from pathlib import Path

from scripts.pack_windows_payload import build_payload


class WindowsPayloadTests(unittest.TestCase):
    def test_payload_roundtrip_omits_old_launcher_and_symbols(self):
        with tempfile.TemporaryDirectory(prefix="chta-payload-") as temporary:
            root = Path(temporary)
            release = root / "release"
            (release / "data").mkdir(parents=True)
            for name in ["chta.exe", "cht.exe", "cht-relay.exe", "cht_core.dll", "flutter_windows.dll", "debug.pdb", "data/app.so"]:
                (release / name).write_bytes(name.encode() * 1024)
            output = root / "payload.bin"
            result = build_payload(release, output)
            archive = output.read_bytes()
            self.assertEqual(archive[:8], b"CHTAAPP1")
            length = int.from_bytes(archive[8:12], "little")
            manifest = json.loads(archive[12:12 + length])
            names = [entry["path"] for entry in manifest["files"]]
            self.assertIn("cht-relay.exe", names)
            self.assertNotIn("cht.exe", names)
            self.assertNotIn("debug.pdb", names)
            data = gzip.decompress(archive[12 + length:])
            position = 0
            for entry in manifest["files"]:
                part = data[position:position + entry["size"]]
                self.assertEqual(hashlib.sha256(part).hexdigest(), entry["sha256"])
                position += entry["size"]
            self.assertEqual(position, len(data))
            self.assertEqual(result["sha256"], hashlib.sha256(archive).hexdigest())

    def test_refuses_missing_runtime_and_output_inside_source(self):
        with tempfile.TemporaryDirectory(prefix="chta-payload-") as temporary:
            root = Path(temporary)
            with self.assertRaises(ValueError):
                build_payload(root, root / "payload.bin")


if __name__ == "__main__":
    unittest.main()
