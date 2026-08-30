"""Parameter sweep for a ReShade effect over a set of reference frames.

Renders every (config, image) pair through fxshot in a single batch, then scores
each config on what a tone mapping preset is supposed to achieve: more local
detail across the tonal range, without clipping either end, without flattening
the highlights, and without lifting night scenes toward daylight.

The score ranks candidates and catches failures. It cannot judge whether a
result looks over processed, so treat the top row as a shortlist rather than an
answer, and put renders in front of a person before deciding.
"""

from __future__ import annotations

import argparse
import itertools
import json
import os
import subprocess
import sys
from collections.abc import Iterator, Sequence
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path
from typing import Any, NamedTuple

import analyse
import numpy as np

WORKERS = max(1, (os.cpu_count() or 4) - 1)


HERE = Path(__file__).resolve().parent
FXSHOT = HERE.parent / "fxshot.exe"
BUILD = HERE.parent / "work" / "build"
SCENES = HERE.parent / "work" / "scenes"
DEFAULT_BASE = HERE.parent / "work" / "defaults.ini"
DEFAULT_NOISE = HERE.parent / "examples" / "dz_stbn_512x256.png"
NOISE = DEFAULT_NOISE

type Params = dict[str, str]
type Overrides = dict[str, float | int]

GRIDS: dict[str, dict[str, Sequence[float]]] = {
    "fade": {
        "DarkFadeThreshold": [0.20, 0.30, 0.40, 0.50],
        "DynamicIntensity": [0.65, 0.85, 1.00],
    },
    "strength": {"Strength": [0.20, 0.25, 0.30, 0.35, 0.40, 0.45]},
    "contrast": {
        "Contrast_Macro": [0.0, 0.10, 0.20, 0.30],
        "Contrast_Shadow_Strength": [0.8, 1.0, 1.2],
    },
    "bands": {
        "Contrast_Micro": [0.0, 0.15, 0.30, 0.45],
        "Contrast_Macro": [0.50, 0.65, 0.80],
    },
    # Radius is authored against 1080 lines, so on 1200 line frames these are
    # 1.11x wider in pixels. Four configs leave room for 50 frames under the
    # 200 image ceiling, the fewest that ranks dark_rim.
    "radius": {"Radius": [13.5, 20.0, 27.0, 36.0]},
    "radius_far": {"Radius": [36.0, 45.0, 54.0]},
    # Epsilon is the guided filter's edge versus texture decision, through
    # a = var / (var + eps): well above eps the base follows the edge, so it
    # cannot halo; below it the base smooths through and texture is extracted.
    # Radius sets the size a halo would have.
    "edge": {
        "Epsilon": [0.0005, 0.001, 0.002, 0.004],
        "Radius": [10.0, 15.0, 22.0],
    },
    "edge_wide": {
        "Epsilon": [0.002, 0.003, 0.004, 0.005],
        "Radius": [22.0, 26.0, 30.0],
    },
    # Cost does not change with Radius: every window is seven strided taps,
    # each read from the mip matching its stride.
    "edge_far": {
        "Epsilon": [0.002, 0.003, 0.005],
        "Radius": [30.0, 40.0, 50.0, 60.0],
    },
    "lift_deep": {
        "LiftMidtones": [0.30, 0.40, 0.55],
        "Strength": [0.25, 0.30, 0.35],
    },
    "detail_limit": {"DetailLimit": [0.0, 0.75, 1.0, 1.5, 2.0]},
    # Contrast_Shadow_Micro and _Macro are not in the current PHDRPlus, and
    # fxshot ignores a preset key the effect does not declare.
    "shadow_scope": {
        "Contrast_Shadow_Strength": [0.0, 0.6, 1.2],
        "Contrast_Shadow_Micro": [0.0, 0.5, 1.0],
        "Contrast_Shadow_Macro": [0.0, 1.0],
    },
    # Contrast_Shadow_Strength darkens the shadow side of bright edges by
    # design, so it is the first suspect when dark_rim is high.
    "rim_pull": {
        "Contrast_Shadow_Strength": [0.0, 0.6, 1.2],
        "PullMidtones": [1.0, 1.12, 1.24],
    },
    # Both pull night brightness down, and Lift costs about half as much detail
    # per unit removed, so the question is how little fade Lift leaves needed.
    "night_balance": {
        "DynamicIntensity": [0.0, 0.2, 0.4],
        "LiftMidtones": [0.55, 0.65, 0.75, 0.85],
    },
    # For a game whose day and night brightness nearly touch.
    "fade_low": {
        "DarkFadeThreshold": [0.08, 0.11, 0.15],
        "DynamicIntensity": [0.0, 0.35, 0.65],
    },
    # How much authority Lift has at night depends on where night sits against
    # the pivot, so the two are chosen together.
    "pivot_lift": {
        "TonalNeutralPoint": [0.15, 0.20, 0.25, 0.30],
        "LiftMidtones": [0.60, 0.70, 0.80],
    },
    "pivot": {
        "TonalNeutralPoint": [0.15, 0.20, 0.25, 0.30],
        "TonalResponseStops": [1.0, 1.5, 2.0],
    },
    "night": {
        "DynamicIntensity": [0.0, 0.35, 0.65, 1.0],
        "LiftMidtones": [0.80, 0.86, 0.92, 1.0],
    },
    "lift": {
        "LiftHighlights": [0.85, 0.92, 1.0],
        "LiftMidtones": [0.92, 1.0],
        "LiftShadows": [1.0, 1.08],
    },
    # The o2_ grids are the second Odyssey pass, around the v1.0 preset.
    "o2_fade": {
        "DarkFadeThreshold": [0.25, 0.40, 0.55],
        "DynamicIntensity": [0.0, 0.35, 0.65],
    },
    "o2_edge": {
        "Epsilon": [0.001, 0.002, 0.003],
        "Radius": [13.5, 20.0, 27.0, 36.0],
    },
    "o2_bands": {
        "Contrast_Micro": [0.20, 0.35, 0.50],
        "Contrast_Medium": [0.0, 0.15, 0.30],
    },
    "o2_pivot": {
        "TonalNeutralPoint": [0.20, 0.30, 0.40],
        "TonalResponseStops": [1.0, 1.5, 2.5],
    },
    # Trades the halo slider against band detail, with Detail Limit as the
    # alternative way to buy back rim.
    "o2_trade": {
        "Contrast_Shadow_Strength": [0.6, 1.2],
        "Contrast_Medium": [0.0, 0.30],
        "DetailLimit": [0.0, 0.75],
    },
    "pull": {
        "PullHighlights": [1.0, 1.06, 1.12],
        "PullMidtones": [1.0, 1.06, 1.12],
        "PullShadows": [0.94, 1.0],
    },
}


def _measure(job: tuple[Path, list[Path]]) -> list[dict[str, Any]]:
    """One source frame against every config's render of it, so the source
    statistics are computed once per frame. Module level so it pickles.
    """
    src, outs = job
    stats = analyse.source(src)
    return [dict(analyse.compare(stats, o)) for o in outs]


class Scene(NamedTuple):
    category: str
    path: Path


class Config(NamedTuple):
    name: str
    overrides: Overrides


def read_ini(path: Path) -> Params:
    values: Params = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if "=" not in line or line.startswith("["):
            continue
        key, _, value = line.partition("=")
        values[key.strip()] = value.strip()
    return values


def write_ini(path: Path, values: Params, technique: str) -> None:
    body = "\n".join(f"{k}={values[k]}" for k in sorted(values))
    path.write_text(
        f"Techniques={technique}\nTechniqueSorting={technique}\n\n"
        f"[{technique.split('@')[-1]}]\n{body}\n",
        encoding="utf-8",
    )


def scenes(root: Path, subset: bool, limit: int | None = None) -> list[Scene]:
    """Reference frames, thinned to a representative sample.

    Filenames sort by brightness, so an even stride spans the whole range.
    Good enough to rank contrast and tonal settings, not good enough for
    dark_rim: confirm anything that turns on rim over the full set.
    """
    found = [
        Scene(cat, p)
        for cat in ("Day", "Night")
        for p in sorted((root / cat).glob("*.png"))
    ]
    target = 12 if subset else None
    if limit is not None:
        target = limit if target is None else min(target, limit)
    if target is None or target >= len(found):
        return found

    picked: list[Scene] = []
    for cat in ("Day", "Night"):
        group = [s for s in found if s.category == cat]
        n = min(len(group), max(3, round(target * len(group) / len(found))))
        picked += [group[round(i * (len(group) - 1) / max(n - 1, 1))] for i in range(n)]
    return picked


def score(rows: list[dict[str, Any]]) -> dict[str, float]:
    """Collapse per image metrics into one comparable set of numbers."""
    day = [r for r in rows if r["cat"] == "Day"]
    night = [r for r in rows if r["cat"] == "Night"]

    def avg(subset: list[dict[str, Any]], key: str) -> float:
        return float(np.nanmean([r[key] for r in subset])) if subset else float("nan")

    s = {
        "day_shadow": avg(day, "detail_shadow"),
        "day_mid": avg(day, "detail_mid"),
        "day_high": avg(day, "detail_high"),
        "night_shadow": avg(night, "detail_shadow"),
        "night_mid": avg(night, "detail_mid"),
        "night_high": avg(night, "detail_high"),
        "night_lift": avg(night, "mean_shift"),
        "day_lift": avg(day, "mean_shift"),
        "crush": avg(rows, "black_crush"),
        "blow": avg(rows, "white_blow"),
        "overshoot": avg(rows, "overshoot"),
        "ringing": avg(rows, "ringing"),
        "dark_rim": avg(rows, "dark_rim"),
        "p999_drop": avg(day, "p999_in") - avg(day, "p999_out"),
    }

    # Credit for added detail saturates at +18%, because past that a higher
    # ratio means a more processed image rather than a better one. Averaging
    # both times of day stops a config winning by helping daylight at night's
    # expense. Once every candidate clears +18% the gain term is flat and the
    # ranking falls to the penalties alone, which can put an effect that does
    # nothing above one that works, so read the columns when gain is flat.
    bands = (
        "day_shadow",
        "day_mid",
        "day_high",
        "night_shadow",
        "night_mid",
        "night_high",
    )
    gain = float(np.nanmean([min(s[k], 1.18) for k in bands]))

    penalty = 0.0
    # Night must not drift toward daylight. A few thousandths is invisible, so
    # only charge for what exceeds that, or this term drowns out the rest.
    penalty += 25.0 * max(0.0, s["night_lift"] - 0.003)
    penalty += 200.0 * (s["crush"] + s["blow"])
    penalty += 8.0 * max(0.0, s["p999_drop"])
    penalty += 60.0 * s["ringing"]
    # Dark rims tracing bright objects are the etched look. Measured in
    # levels, so a much smaller coefficient than the fractional terms.
    penalty += 0.08 * max(0.0, s["dark_rim"])
    # Lost local contrast in the bright band flattens lit surfaces and does
    # not show in a histogram, so charge for it directly.
    penalty += 6.0 * max(0.0, 1.0 - s["night_high"])
    penalty += 6.0 * max(0.0, 1.0 - s["day_high"])

    return s | {"gain": gain, "penalty": penalty, "score": gain - penalty}


def build_configs(stage: str, fixed: Overrides) -> list[Config]:
    grid = GRIDS[stage]
    keys = list(grid)
    configs: list[Config] = []
    for combo in itertools.product(*(grid[k] for k in keys)):
        name = " ".join(f"{k}={v:g}" for k, v in zip(keys, combo, strict=True))
        configs.append(Config(name, fixed | dict(zip(keys, combo, strict=True))))
    return configs


def run(
    configs: list[Config],
    frames: list[Scene],
    n_frames: int,
    outdir: Path,
    base_file: Path,
    keep: bool,
) -> list[tuple[str, dict[str, float]]]:
    outdir.mkdir(parents=True, exist_ok=True)
    base = read_ini(base_file)
    technique = base.pop("Techniques", "DZ_PerceptualHDR@PHDRPlus.fx")
    base.pop("TechniqueSorting", None)

    # The dither is under one 8 bit level and invisible in play, but it
    # perturbs every local statistic differently per config, which is noise on
    # top of the difference being measured. Validate the final preset with it
    # back on.
    base["EnableDithering"] = "0"

    jobs: list[str] = []
    plan: list[tuple[int, str, Scene, Path]] = []
    for ci, (name, overrides) in enumerate(configs):
        values = base | {
            k: (f"{v:.6f}" if isinstance(v, float) else str(v))
            for k, v in overrides.items()
        }
        ini = outdir / f"cfg{ci:03d}.ini"
        write_ini(ini, values, technique)
        for ii, frame in enumerate(frames):
            out = outdir / f"c{ci:03d}_i{ii:02d}.png"
            jobs.append(f"{ini}\t{frame.path}\t{out}")
            plan.append((ci, name, frame, out))

    batch = outdir / "batch.txt"
    batch.write_text("\n".join(jobs) + "\n", encoding="utf-8")

    print(
        f"rendering {len(jobs)} images ({len(configs)} configs x {n_frames} frames)...",
        file=sys.stderr,
    )
    result = subprocess.run(
        [
            str(FXSHOT),
            "--hlsl",
            str(BUILD / "effect.hlsl"),
            "--manifest",
            str(BUILD / "manifest.txt"),
            "--noise",
            str(NOISE),
            "--frames",
            str(n_frames),
            "--batch",
            str(batch),
        ],
        stderr=subprocess.DEVNULL,
        check=False,
    )
    if result.returncode != 0:
        raise SystemExit(f"fxshot failed with code {result.returncode}")

    # Analysis, not rendering, is what a long run waits on, and every source
    # frame is independent, so it runs one process per core.
    results: dict[tuple[int, str], list[dict[str, Any]]] = {}
    print(f"analysing {len(plan)} images on {WORKERS} processes...", file=sys.stderr)
    by_frame: dict[Path, list[tuple[int, str, Scene, Path]]] = {}
    for item in plan:
        by_frame.setdefault(item[2].path, []).append(item)
    groups = list(by_frame.items())
    work = [(src, [o for _, _, _, o in items]) for src, items in groups]
    with ProcessPoolExecutor(max_workers=WORKERS) as pool:
        measured = pool.map(_measure, work, chunksize=1)
        for (_, items), rows in zip(groups, measured, strict=True):
            for (ci, name, frame, _), row in zip(items, rows, strict=True):
                row = dict(row)
                row["cat"] = frame.category
                results.setdefault((ci, name), []).append(row)

    if not keep:
        for png in outdir.glob("c*_i*.png"):
            png.unlink()
    return [(name, score(rows)) for (_, name), rows in sorted(results.items())]


def parse_overrides(pairs: list[str]) -> Iterator[tuple[str, float | int]]:
    for pair in pairs:
        key, _, raw = pair.partition("=")
        yield key, float(raw) if "." in raw else int(raw)


def main() -> None:
    global NOISE
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--stage", required=True, choices=sorted(GRIDS))
    ap.add_argument("--frames", type=int, default=20)
    ap.add_argument("--subset", action="store_true")
    ap.add_argument("--keep", action="store_true", help="keep the rendered PNGs")
    ap.add_argument(
        "--outdir", type=Path, required=True, help="one per sweep, never shared"
    )
    ap.add_argument("--base", type=Path, default=DEFAULT_BASE)
    ap.add_argument(
        "--noise",
        type=Path,
        default=DEFAULT_NOISE,
        help="image for the effect's source texture",
    )
    ap.add_argument(
        "--scenes",
        type=Path,
        default=SCENES,
        help="directory holding Day/ and Night/ reference frames",
    )
    ap.add_argument("--set", action="append", default=[], metavar="KEY=VALUE")
    ap.add_argument(
        "--max-images",
        type=int,
        default=200,
        help="hard ceiling on configs x frames for one run (default 200)",
    )
    args = ap.parse_args()
    NOISE = args.noise

    configs = build_configs(args.stage, dict(parse_overrides(args.set)))

    # The ceiling is on images rather than configs because per-image analysis
    # is what costs. Thin the frames to fit rather than refusing to run.
    per_config = args.max_images // len(configs)
    if per_config < 3:
        raise SystemExit(
            f"{len(configs)} configs against a {args.max_images} image ceiling "
            f"leaves {per_config} frames each. Narrow the grid or raise "
            f"--max-images."
        )
    frames = scenes(args.scenes, args.subset, per_config)
    print(
        f"{len(configs)} configs x {len(frames)} frames = "
        f"{len(configs) * len(frames)} images",
        file=sys.stderr,
    )

    scored = run(
        configs,
        frames,
        args.frames,
        args.outdir,
        args.base,
        args.keep,
    )
    scored.sort(key=lambda kv: -kv[1]["score"])

    cols = [
        "score",
        "gain",
        "ringing",
        "dark_rim",
        "day_shadow",
        "day_high",
        "night_shadow",
        "night_high",
        "night_lift",
        "crush",
        "blow",
        "p999_drop",
    ]
    print(f"{'config':<46} " + " ".join(f"{c[:9]:>9}" for c in cols))
    for name, s in scored:
        print(f"{name:<46} " + " ".join(f"{s[c]:>9.4f}" for c in cols))

    report = args.outdir / f"stage_{args.stage}.json"
    report.write_text(json.dumps(dict(scored), indent=1), encoding="utf-8")


if __name__ == "__main__":
    main()
