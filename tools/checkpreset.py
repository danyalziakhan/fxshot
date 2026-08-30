"""Check preset values against the ranges the effect declares.

    python tools\\checkpreset.py EFFECT.fx PRESET.ini [PRESET.ini ...]

fxshot sets a uniform to whatever the ini says, so a sweep can wander outside a
slider's own ui_min and ui_max and produce a measurement nobody can reproduce
in ReShade. Run this before shipping a preset.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

NUM = r"[-+]?\d*\.?\d+(?:[eE][-+]?\d+)?"


def ranges(effect: Path) -> dict[str, tuple[float, float]]:
    """Every uniform that declares both a minimum and a maximum."""
    text = effect.read_text(encoding="utf-8", errors="replace")
    out: dict[str, tuple[float, float]] = {}
    for m in re.finditer(r"uniform\s+\w+\s+(\w+)\s*<(.*?)>\s*=", text, re.S):
        name, body = m.group(1), m.group(2)
        lo = re.search(r"ui_min\s*=\s*(" + NUM + r")", body)
        hi = re.search(r"ui_max\s*=\s*(" + NUM + r")", body)
        if lo and hi:
            out[name] = (float(lo.group(1)), float(hi.group(1)))
    return out


def values(preset: Path) -> dict[str, str]:
    out: dict[str, str] = {}
    for line in preset.read_text(encoding="utf-8").splitlines():
        if "=" in line and not line.startswith("["):
            k, _, v = line.partition("=")
            out[k.strip()] = v.strip()
    return out


def main() -> None:
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    lim = ranges(Path(sys.argv[1]))
    bad = 0
    for arg in sys.argv[2:]:
        p = Path(arg)
        problems = []
        for key, raw in values(p).items():
            if key not in lim:
                continue
            try:
                v = float(raw)
            except ValueError:
                continue
            lo, hi = lim[key]
            if v < lo or v > hi:
                problems.append(f"    {key} = {v:g}, outside [{lo:g}, {hi:g}]")
        if problems:
            bad += 1
            print(f"{p.name}:")
            print("\n".join(problems))
        else:
            print(f"{p.name}: ok")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
