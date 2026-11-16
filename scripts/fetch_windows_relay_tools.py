"""Fetch the checksum-pinned public-relay dependency into the desktop build."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import urllib.request


def digest(path):
    value = hashlib.sha256()
    with Path(path).open("rb") as source:
        for block in iter(lambda: source.read(65536), b""):
            value.update(block)
    return value.hexdigest()


def download_verified(url, target, expected_hash, max_size, *, opener=urllib.request.urlopen):
    target = Path(target)
    if not url.startswith("https://"):
        raise ValueError("Relay tools require HTTPS")
    if target.is_symlink():
        raise ValueError("Relay tool links are forbidden")
    if target.is_file() and target.stat().st_size <= max_size and digest(target) == expected_hash:
        return target
    target.parent.mkdir(parents=True, exist_ok=True)
    temporary = target.with_suffix(target.suffix + ".part")
    if temporary.is_symlink():
        raise ValueError("Relay tool links are forbidden")
    try:
        total, value = 0, hashlib.sha256()
        request = urllib.request.Request(url, headers={"User-Agent": "chta-release-build"})
        with opener(request, timeout=45) as response, temporary.open("wb") as output:
            for block in iter(lambda: response.read(65536), b""):
                total += len(block)
                if total > max_size:
                    raise ValueError("Relay tool exceeds its pinned size")
                value.update(block)
                output.write(block)
        if value.hexdigest() != expected_hash:
            raise ValueError("Relay tool checksum mismatch")
        temporary.replace(target)
    finally:
        temporary.unlink(missing_ok=True)
    return target


def prepare(output, cache=None):
    repo = Path(__file__).resolve().parent.parent
    vendor = repo / "third_party/cloudflared"
    metadata = json.loads((vendor / "artifact.json").read_text(encoding="utf-8"))
    cache = Path(cache) if cache else repo / "target/vendor/cloudflared" / metadata["version"]
    binary = download_verified(metadata["url"], cache / "cloudflared.exe", metadata["sha256"], metadata["size"])
    license_file = vendor / "LICENSE"
    if digest(license_file) != metadata["licenseSha256"]:
        raise ValueError("cloudflared license checksum mismatch")
    output = Path(output)
    output.mkdir(parents=True, exist_ok=True)
    (output / "licenses").mkdir(exist_ok=True)
    for source, destination in [(binary, output / "cloudflared.exe"),
                                (license_file, output / "licenses/cloudflared-LICENSE.txt")]:
        if destination.is_symlink():
            raise ValueError("Relay tool output links are forbidden")
        shutil.copyfile(source, destination)
    return {"component": "cloudflared", "version": metadata["version"], "sha256": digest(binary)}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--cache", type=Path)
    args = parser.parse_args()
    print(json.dumps(prepare(args.output, args.cache)))
