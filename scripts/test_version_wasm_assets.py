import hashlib
from pathlib import Path
import tempfile
import unittest

from scripts.version_wasm_assets import version_wasm_assets


class VersionWasmAssetsTest(unittest.TestCase):
    def test_each_binding_loads_its_own_content_addressed_binary(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            binding = directory / 'cht_core.js'
            binary = directory / 'cht_core_bg.wasm'
            original = "const url = new URL('cht_core_bg.wasm', import.meta.url);"
            old_name = None
            for payload in (b'old wasm fixture', b'new wasm fixture'):
                binary.write_bytes(payload)
                binding.write_text(original, encoding='utf-8')
                name = version_wasm_assets(directory)
                self.assertIn(hashlib.sha256(payload).hexdigest(), name)
                self.assertEqual((directory / name).read_bytes(), payload)
                self.assertIn(name, binding.read_text(encoding='utf-8'))
                self.assertEqual(version_wasm_assets(directory), name)
                if old_name:
                    self.assertNotEqual(old_name, name)
                    self.assertTrue((directory / old_name).exists())
                old_name = name


if __name__ == '__main__':
    unittest.main()
