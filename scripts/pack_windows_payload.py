"""Build a bounded streaming runtime archive for the single-file launcher."""
import argparse
import gzip
import hashlib
import json
import os
import stat
import struct
from pathlib import Path

MAX_TOTAL = 2 * 1024**3


def _redirected(path):
    metadata = path.lstat()
    return path.is_symlink() or bool(getattr(metadata, "st_file_attributes", 0) & 0x400)


def _hash(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for part in iter(lambda: source.read(65536), b""):
            digest.update(part)
    return digest.hexdigest()


def build_payload(release, output, runtime_directory=None):
    release, output = Path(release).absolute(), Path(output).absolute()
    if _redirected(release) or release == output or release in output.parents:
        raise ValueError("Use a real release folder and an output outside it")
    for required in ["chta.exe", "cht_core.dll", "flutter_windows.dll", "data/app.so",
                     "cht-relay.exe", "cloudflared.exe", "licenses/cloudflared-LICENSE.txt"]:
        if not (release / required).is_file():
            raise ValueError(f"Missing desktop runtime: {required}")
    files = {}
    for directory, folders, names in os.walk(release, followlinks=False):
        for name in folders + names:
            if _redirected(Path(directory) / name):
                raise ValueError("Runtime links/reparse points are forbidden")
        for name in names:
            path = Path(directory) / name
            relative = path.relative_to(release).as_posix()
            if relative == "cht.exe" or path.suffix.lower() == ".pdb":
                continue
            files[relative] = path
    if runtime_directory is not None:
        runtime_directory = Path(runtime_directory)
        for path in runtime_directory.glob("*.dll"):
            if _redirected(path):
                raise ValueError("Redistributable links are forbidden")
            files.setdefault(path.name, path)
    if len(files) > 5000:
        raise ValueError("Too many runtime files")
    manifest_files, total = [], 0
    casefolded = set()
    for name, path in sorted(files.items()):
        if name.casefold() in casefolded:
            raise ValueError("Duplicate Windows filename")
        casefolded.add(name.casefold())
        size = path.stat().st_size
        total += size
        if size > 512 * 1024**2 or total > MAX_TOTAL:
            raise ValueError("Desktop runtime exceeds packaging limits")
        manifest_files.append({"path": name, "size": size, "sha256": _hash(path)})
    manifest = json.dumps({"version": 1, "entrypoint": "chta.exe", "files": manifest_files}, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    if len(manifest) > 1024**2:
        raise ValueError("Runtime manifest exceeds limit")
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_suffix(output.suffix + ".part")
    try:
        with temporary.open("wb") as destination:
            destination.write(b"CHTAAPP1" + struct.pack("<I", len(manifest)) + manifest)
            with gzip.GzipFile(filename="", mode="wb", fileobj=destination, mtime=0, compresslevel=6) as compressed:
                for entry in manifest_files:
                    digest, count = hashlib.sha256(), 0
                    with files[entry["path"]].open("rb") as source:
                        for part in iter(lambda: source.read(65536), b""):
                            count += len(part)
                            if count > entry["size"]:
                                raise ValueError("Runtime changed during packaging")
                            digest.update(part)
                            compressed.write(part)
                    if count != entry["size"] or digest.hexdigest() != entry["sha256"]:
                        raise ValueError("Runtime changed during packaging")
            destination.flush()
            os.fsync(destination.fileno())
        temporary.replace(output)
    except Exception:
        temporary.unlink(missing_ok=True)
        raise
    return {"files": len(files), "runtimeBytes": total, "archiveBytes": output.stat().st_size, "sha256": _hash(output)}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("release", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--runtime-directory", type=Path)
    arguments = parser.parse_args()
    print(json.dumps(build_payload(arguments.release, arguments.output, arguments.runtime_directory)))
