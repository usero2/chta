"""Keep wasm-bindgen JavaScript and its binary paired across browser updates."""
import hashlib
from pathlib import Path
import re
import sys


def version_wasm_assets(directory: Path) -> str:
    binary = (directory / 'cht_core_bg.wasm').read_bytes()
    name = f'cht_core_bg.{hashlib.sha256(binary).hexdigest()}.wasm'
    binding = directory / 'cht_core.js'
    source = binding.read_text(encoding='utf-8')
    updated, count = re.subn(
        r"new URL\(['\"]cht_core_bg(?:\.[0-9a-f]{64})?\.wasm['\"], import\.meta\.url\)",
        f"new URL('{name}', import.meta.url)", source,
    )
    if count != 1:
        raise ValueError('Expected exactly one wasm-bindgen binary URL')
    (directory / name).write_bytes(binary)
    binding.write_text(updated, encoding='utf-8')
    return name


if __name__ == '__main__':
    print(version_wasm_assets(Path(sys.argv[1])))
