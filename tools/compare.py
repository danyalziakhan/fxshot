"""Build before and after contact sheets so a preset can be judged by eye.

The metrics say whether local contrast went up. Only looking says whether the
result is pleasant. Crops are taken at 1:1 by default so detail is not
resampled away, which is the whole thing under examination.

These sheets are for reviewing candidates. They carry captions, so they are not
suitable for publishing as before and after screenshots. Use the renderer's own
output for that.
"""

from __future__ import annotations

import argparse
from pathlib import Path
from typing import NamedTuple

from PIL import Image, ImageDraw


class Crop(NamedTuple):
    x: int
    y: int
    w: int
    h: int


class Pair(NamedTuple):
    title: str
    before: Path
    after: Path


def _label(img: Image.Image, text: str) -> Image.Image:
    draw = ImageDraw.Draw(img)
    draw.rectangle((0, 0, 8 + 7 * len(text), 16), fill=(0, 0, 0))
    draw.text((4, 3), text, fill=(255, 255, 255))
    return img


def sheet(pairs: list[Pair], crop: Crop, out: Path, scale: int = 1) -> Path:
    """Stack each pair side by side into one image."""
    tiles: list[tuple[str, Image.Image, Image.Image]] = []
    box = (crop.x, crop.y, crop.x + crop.w, crop.y + crop.h)
    size = (crop.w * scale, crop.h * scale)
    for title, before, after in pairs:
        a = Image.open(before).convert("RGB").crop(box)
        b = Image.open(after).convert("RGB").crop(box)
        if scale != 1:
            a, b = a.resize(size, Image.NEAREST), b.resize(size, Image.NEAREST)
        tiles.append((title, a, b))

    tw, th = tiles[0][1].size
    gap = 8
    canvas = Image.new(
        "RGB", (tw * 2 + gap * 3, (th + gap + 20) * len(tiles) + gap), (24, 24, 24)
    )
    for i, (title, a, b) in enumerate(tiles):
        top = gap + i * (th + gap + 20)
        canvas.paste(_label(a, f"off  {title}"), (gap, top))
        canvas.paste(_label(b, f"on   {title}"), (gap * 2 + tw, top))
    canvas.save(out)
    return out


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--before", type=Path, required=True)
    ap.add_argument("--after", type=Path, required=True)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--title", default="")
    ap.add_argument("--crop", default="0,0,640,400", help="x,y,w,h in source pixels")
    ap.add_argument("--scale", type=int, default=1)
    args = ap.parse_args()

    crop = Crop(*(int(v) for v in args.crop.split(",")))
    print(
        sheet([Pair(args.title, args.before, args.after)], crop, args.out, args.scale)
    )


if __name__ == "__main__":
    main()
