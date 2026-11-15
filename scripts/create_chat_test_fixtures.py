"""Create synthetic attachment fixtures; requires ffmpeg on PATH."""
from pathlib import Path
import struct
import subprocess
import wave
import zlib

root = Path(__file__).resolve().parents[1] / "target" / "media-fixtures"
root.mkdir(parents=True, exist_ok=True)

def chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))

pixels = (b"\0" + bytes([116, 210, 94]) * 128) * 96
png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 128, 96, 8, 2, 0, 0, 0))
png += chunk(b"IDAT", zlib.compress(pixels)) + chunk(b"IEND", b"")
(root / "sample-image.png").write_bytes(png)
with wave.open(str(root / "sample-audio.wav"), "wb") as audio:
    audio.setnchannels(1)
    audio.setsampwidth(2)
    audio.setframerate(16000)
    audio.writeframes(bytes(32000))
(root / "sample-file.bin").write_bytes(bytes(range(256)) * 512)
subprocess.run(["ffmpeg", "-y", "-f", "lavfi", "-i", "color=c=green:s=160x90:d=1",
                "-c:v", "libx264", "-pix_fmt", "yuv420p", str(root / "sample-video.mp4"),
                "-loglevel", "error"], check=True)

# A second image/video exercises explicit album grouping; all fixtures are synthetic.
(root / "sample-image-2.png").write_bytes(png)
(root / "sample-video-2.mp4").write_bytes((root / "sample-video.mp4").read_bytes())
(root / "sample-empty.bin").write_bytes(b"")
