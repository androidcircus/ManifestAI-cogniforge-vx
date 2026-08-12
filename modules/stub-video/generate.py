#!/usr/bin/env python3
# modules/stub-video/generate.py
# Placeholder "video generator" for the emulator / no-GPU dev path.
#
# Produces a real .mp4 from procedurally-drawn frames so the rack UI ->
# Rack Engine -> Argo workflow path can be exercised end-to-end without a
# GPU or the ~14B Wan 2.1 model download. The scheduler drives it with the
# same CLI contract as wan21:
#
#   python generate.py --image-url https://example.com/cat.jpg \
#     --duration 5 --output /app/outputs/out.mp4
#
# Dependencies are tiny (pillow + imageio + imageio-ffmpeg) and CPU-only.
import argparse
import hashlib
import os
import sys
import time

from PIL import Image, ImageDraw

try:
    import imageio.v2 as imageio
except Exception:  # pragma: no cover - imageio is a hard dep of this module
    imageio = None


def parse_args():
    parser = argparse.ArgumentParser(description="Stub video generator (no GPU)")
    parser.add_argument("--image-url", default="", help="input image URL (used only as a seed)")
    parser.add_argument("--duration", type=int, default=5, help="video length in seconds")
    parser.add_argument("--output", default="/app/outputs/out.mp4", help="output mp4 path")
    parser.add_argument("--fps", type=int, default=16)
    parser.add_argument("--width", type=int, default=832)
    parser.add_argument("--height", type=int, default=480)
    return parser.parse_args()


def _palette(seed: str):
    """Deterministic hue pair from the input URL so outputs vary by job."""
    h = int(hashlib.sha256(seed.encode("utf-8")).hexdigest()[:6], 16)
    base = (h >> 16) & 0xFF, (h >> 8) & 0xFF, h & 0xFF
    accent = (255 - base[0], (base[1] + 90) % 256, (base[2] + 120) % 256)
    return base, accent


def _frame(t: float, args, base, accent):
    img = Image.new("RGB", (args.width, args.height), base)
    draw = ImageDraw.Draw(img)
    bar_w = max(40, args.width // 8)
    x = int(((t * 100) % (args.width + bar_w)) - bar_w)
    draw.rectangle([x, 0, x + bar_w, args.height], fill=accent)
    draw.rectangle([0, args.height - 36, args.width, args.height], fill=(10, 10, 14))
    label = f"COGNIFORGE STUB VIDEO  t={t:+.1f}s"
    draw.text((16, args.height - 30), label, fill="white")
    draw.text((16, 16), f"{args.width}x{args.height} {args.fps}fps", fill="white")
    return img


def main() -> int:
    args = parse_args()
    if imageio is None:
        print("error: imageio not installed (pip install imageio imageio-ffmpeg)", file=sys.stderr)
        return 1

    os.makedirs(os.path.dirname(os.path.abspath(args.output)), exist_ok=True)
    base, accent = _palette(args.image_url or "cogniforge")

    start = time.time()
    frames = [
        _frame(i / args.fps, args, base, accent)
        for i in range(int(args.duration * args.fps))
    ]
    frames[0].load()
    imageio.mimsave(args.output, frames, fps=args.fps)

    print(f"[stub-video] wrote {os.path.getsize(args.output)} bytes to "
          f"{args.output} in {time.time() - start:.1f}s")
    return 0


if __name__ == "__main__":
    sys.exit(main())