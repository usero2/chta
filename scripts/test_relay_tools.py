import hashlib
import io
from pathlib import Path
import tempfile
import unittest

from scripts.fetch_windows_relay_tools import download_verified


class RelayToolsTests(unittest.TestCase):
    def test_verified_download_is_reused_without_network(self):
        data = b"synthetic executable"
        digest = hashlib.sha256(data).hexdigest()
        calls = []
        def open_fixture(request, **kwargs):
            calls.append(request.full_url)
            return io.BytesIO(data)
        with tempfile.TemporaryDirectory(prefix="chta-tools-") as temporary:
            target = Path(temporary) / "tool.exe"
            download_verified("https://github.com/example/tool.exe", target, digest, len(data), opener=open_fixture)
            download_verified("https://github.com/example/tool.exe", target, digest, len(data), opener=open_fixture)
            self.assertEqual(target.read_bytes(), data)
            self.assertEqual(len(calls), 1)

    def test_wrong_hash_does_not_replace_the_existing_file(self):
        with tempfile.TemporaryDirectory(prefix="chta-tools-") as temporary:
            target = Path(temporary) / "tool.exe"
            target.write_bytes(b"preserve")
            with self.assertRaisesRegex(ValueError, "checksum"):
                download_verified("https://github.com/example/tool.exe", target, "0" * 64, 64,
                                  opener=lambda *a, **k: io.BytesIO(b"wrong"))
            self.assertEqual(target.read_bytes(), b"preserve")
            self.assertFalse(target.with_suffix(".exe.part").exists())

    def test_oversize_download_is_not_installed(self):
        with tempfile.TemporaryDirectory(prefix="chta-tools-") as temporary:
            target = Path(temporary) / "tool.exe"
            with self.assertRaisesRegex(ValueError, "size"):
                download_verified("https://github.com/example/tool.exe", target, "0" * 64, 4,
                                  opener=lambda *a, **k: io.BytesIO(b"too large"))
            self.assertFalse(target.exists())


if __name__ == "__main__":
    unittest.main()
