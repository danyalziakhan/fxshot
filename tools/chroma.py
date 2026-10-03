"""Metrics for the two things a luminance based score cannot see.

A scotopic color shift barely moves luminance, and dithering is deliberately
sub quantisation noise. Both are invisible to the detail and clipping measures
in analyse.py, so they need their own.
"""

from __future__ import annotations

from pathlib import Path
from typing import TypedDict

import analyse
import numpy as np
from analyse import Gray, Rgb
from numpy.typing import NDArray


class ChannelDrift(TypedDict):
    dR: float
    dG: float
    dB: float
    dSat: float


class Grain(TypedDict):
    flat_frac: float
    grain: float


def _saturation(img: Rgb) -> Gray:
    return img.max(axis=-1) - img.min(axis=-1)


def channel_drift(
    src: str | Path,
    out: str | Path,
    reference: str | Path | None = None,
    quantile: float = 25.0,
) -> ChannelDrift:
    """Per channel drift and saturation change in the darkest pixels, in 8 bit
    levels. Pass `reference` as the same preset with the shift disabled,
    otherwise the numbers carry every other change the preset makes too.
    """
    base = analyse.load(reference if reference is not None else src)
    cur = analyse.load(out)
    la = analyse.luma(analyse.load(src))
    mask = la < np.percentile(la, quantile)

    d = (cur - base)[mask]
    sat_delta = (_saturation(cur)[mask] - _saturation(base)[mask]).mean()
    return ChannelDrift(
        dR=float(d[:, 0].mean()) * 255,
        dG=float(d[:, 1].mean()) * 255,
        dB=float(d[:, 2].mean()) * 255,
        dSat=float(sat_delta) * 255,
    )


def _box_mean(x: Gray, r: int) -> Gray:
    k = 2 * r + 1
    h, w = x.shape
    pad = np.pad(x.astype(np.float64), r, mode="edge")
    c = np.pad(np.cumsum(np.cumsum(pad, axis=0), axis=1), ((1, 0), (1, 0)))
    return (
        c[k : k + h, k : k + w] - c[0:h, k : k + w] - c[k : k + h, 0:w] + c[0:h, 0:w]
    ) / (k * k)


def grain(src: str | Path, out: str | Path, flat_threshold: float = 0.004) -> Grain:
    """Noise added where the image was already flat, in 8 bit levels. Only
    featureless neighbourhoods count, or real detail gets counted as grain.
    """
    la, lb = analyse.luma(analyse.load(src)), analyse.luma(analyse.load(out))
    flat: NDArray[np.bool_] = analyse.local_std(la, r=2) < flat_threshold
    if flat.sum() < 1000:
        return Grain(flat_frac=float(flat.mean()), grain=float("nan"))

    # Remove the local mean shift first, so a smooth brightness change is not
    # counted as grain.
    diff = lb - la
    residual = diff - _box_mean(diff, 2)
    return Grain(flat_frac=float(flat.mean()), grain=float(residual[flat].std()) * 255)
