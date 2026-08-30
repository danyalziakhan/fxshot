"""Scene statistics and before/after metrics for tuning a tone mapping shader.

`scene_mean` reproduces what an eye adaptation pass actually measures, which is
not the average of the image. PHDRPlus stores log luminance, the mip chain box
averages it, and the adaptation samples one mip at the screen centre. So the
metric is a geometric mean over a centre weighted region, and anything
reasoning about pivots or thresholds has to use it rather than a plain mean.
"""

from __future__ import annotations

from pathlib import Path
from typing import NamedTuple, TypedDict

import numpy as np
from numpy.typing import NDArray
from PIL import Image

type Gray = NDArray[np.float64]
type Rgb = NDArray[np.float32]

LUMA = np.array([0.2126, 0.7152, 0.0722], dtype=np.float32)


class Metrics(TypedDict):
    """One frame's before and after comparison."""

    scene_mean: float
    mean_in: float
    mean_out: float
    mean_shift: float
    black_crush: float
    white_blow: float
    detail_shadow: float
    detail_mid: float
    detail_high: float
    p999_in: float
    p999_out: float
    overshoot: float
    ringing: float
    dark_rim: float
    crunch: float
    fringe: float
    outline: float
    haze: float
    fine: float
    coarse: float


def load(path: str | Path) -> Rgb:
    """Read an image as RGB floats in [0, 1]."""
    return np.asarray(Image.open(path).convert("RGB"), dtype=np.float32) / 255.0


def luma(img: Rgb) -> Gray:
    return img @ LUMA


def box_mips(x: Gray) -> list[Gray]:
    """Successive 2x2 box downsamples, the way GenerateMips builds a chain."""
    mips = [x]
    while (m := mips[-1]).shape[0] > 1 or m.shape[1] > 1:
        h, w = m.shape
        if h > 1:
            m = m[: h - 1] if h % 2 else m
            m = 0.5 * (m[0::2] + m[1::2])
        if w > 1:
            m = m[:, : w - 1] if w % 2 else m
            m = 0.5 * (m[:, 0::2] + m[:, 1::2])
        mips.append(m)
    return mips


def _bilinear(m: Gray, u: float, v: float) -> float:
    """One bilinear tap at normalised coordinates, as tex2Dlod would take it."""
    h, w = m.shape
    if h == 1 and w == 1:
        return float(m[0, 0])
    cy, cx = v * (h - 1), u * (w - 1)
    y0, x0 = int(np.floor(cy)), int(np.floor(cx))
    y1, x1 = min(y0 + 1, h - 1), min(x0 + 1, w - 1)
    fy, fx = cy - y0, cx - x0
    top = (1 - fx) * m[y0, x0] + fx * m[y0, x1]
    bot = (1 - fx) * m[y1, x0] + fx * m[y1, x1]
    return float((1 - fy) * top + fy * bot)


def scene_mean(img: Rgb, trigger_radius: int = 8) -> float:
    """Geometric mean of luminance, as the adaptation pass measures it: one
    bilinear tap at frame centre, from the mip the trigger radius selects.
    """
    mips = box_mips(np.log(np.maximum(luma(img), 1e-4)))
    m = mips[min(trigger_radius, len(mips) - 1)]
    return float(np.exp(_bilinear(m, 0.5, 0.5)))


class Integral:
    """Summed-area tables for an image and its square, shared across radii.

    Building the tables is nearly all the cost of a window standard deviation,
    and the window size barely matters. Edge padding replicates the nearest
    pixel, so a table padded by R holds the table for any r <= R as an offset
    sub-block, and one build serves every radius. The partial sums land
    differently in the last bits than a per-radius build, under 1e-9 in the
    final metrics.

    float64 on purpose: the running total reaches about 1.15 million over a
    full frame, and in float32 the window differences lose most of their
    significant digits.
    """

    __slots__ = ("_R", "_cache", "_sqsum", "_sum", "_x")

    MAX_R = 16

    def __init__(self, x: Gray, max_r: int = MAX_R) -> None:
        self._x = x
        self._R = max_r
        self._sum: Gray | None = None
        self._sqsum: Gray | None = None
        self._cache: dict[int, Gray] = {}

    def _tables(self) -> tuple[Gray, Gray]:
        if self._sum is None:
            R = self._R

            def table(a: Gray) -> Gray:
                pad = np.pad(a.astype(np.float64), R, mode="edge")
                return np.pad(
                    np.cumsum(np.cumsum(pad, axis=0), axis=1), ((1, 0), (1, 0))
                )

            self._sum = table(self._x)
            self._sqsum = table(self._x * self._x)
        return self._sum, self._sqsum

    def std(self, r: int = 4) -> Gray:
        hit = self._cache.get(r)
        if hit is not None:
            return hit
        if r > self._R:  # outside what the table covers
            return Integral(self._x, r).std(r)
        h, w = self._x.shape
        k, o = 2 * r + 1, self._R - r
        cs, cq = self._tables()

        def box(c: Gray) -> Gray:
            return (
                c[o + k : o + k + h, o + k : o + k + w]
                - c[o : o + h, o + k : o + k + w]
                - c[o + k : o + k + h, o : o + w]
                + c[o : o + h, o : o + w]
            ) / (k * k)

        mean = box(cs)
        out = np.sqrt(np.maximum(box(cq) - mean * mean, 0.0))
        self._cache[r] = out
        return out


def local_std(x: Gray, r: int = 4) -> Gray:
    """Standard deviation in a (2r+1) window, via integral images. Before
    against after says whether local contrast was added or flattened.
    """
    return Integral(x).std(r)


def local_minmax(x: Gray, r: int = 2) -> tuple[Gray, Gray]:
    """Min and max over a (2r+1) square, done separably with shifts."""

    def run(a: Gray, op) -> Gray:
        for axis in (0, 1):
            acc = a
            for d in range(1, r + 1):
                acc = op(acc, np.roll(a, d, axis=axis))
                acc = op(acc, np.roll(a, -d, axis=axis))
            a = acc
        return a

    return run(x, np.minimum), run(x, np.maximum)


def overshoot(
    la: Gray,
    lb: Gray,
    r: int = 2,
    edges_only: bool = False,
    bounds: tuple[Gray, Gray] | None = None,
) -> float:
    """How far the result escapes its own neighbourhood's original range.

    Blind to the difference between a halo and a uniform shift, since a flat
    neighbourhood has a tiny range. Use ringing() instead when a change moves
    overall brightness.
    """
    lo, hi = bounds if bounds is not None else local_minmax(la, r)
    escaped = np.maximum(0.0, lb - hi) + np.maximum(0.0, lo - lb)
    if edges_only:
        edge = (hi - lo) > 0.02
        return float(escaped[edge].mean()) if edge.any() else 0.0
    return float(escaped.mean())


def dark_rim(
    la: Gray,
    lb: Gray,
    r: int = 2,
    edge: float = 0.05,
    bounds: tuple[Gray, Gray] | None = None,
) -> float:
    """Extra darkening on the shadow side of edges, in 8 bit levels.

    Each edge pixel is compared against how far pixels of the same input
    luminance moved in flat parts of the same frame, so a global tone change
    does not read as a rim. Positive means darker than the curve explains.
    """
    lo, hi = bounds if bounds is not None else local_minmax(la, r)
    span = hi - lo
    darkening = la - lb

    shadow_side = (span > edge) & (la < 0.5 * (lo + hi))
    flat = span < 0.01
    if not shadow_side.any() or flat.sum() < 1000:
        return 0.0

    # Expected darkening per luminance, learned from flat regions only.
    bins = np.linspace(0.0, 1.0, 33)
    idx_flat = np.clip(np.digitize(la[flat], bins) - 1, 0, len(bins) - 2)
    idx_edge = np.clip(np.digitize(la[shadow_side], bins) - 1, 0, len(bins) - 2)
    total = np.bincount(idx_flat, weights=darkening[flat], minlength=len(bins) - 1)
    count = np.bincount(idx_flat, minlength=len(bins) - 1)
    # Bins with too few flat samples cannot supply a control, so drop those
    # edge pixels rather than compare them against noise.
    usable = count >= 50
    expected = np.divide(total, np.maximum(count, 1))
    keep = usable[idx_edge]
    if not keep.any():
        return 0.0
    excess = darkening[shadow_side][keep] - expected[idx_edge][keep]
    return float(excess.mean()) * 255


def tone_curve(la: Gray, lb: Gray, bins: int = 64) -> Gray:
    """The frame's own global input to output luminance mapping. Whatever a
    pixel does beyond this is local, which is the part worth measuring.
    """
    edges = np.linspace(0.0, 1.0, bins + 1)
    idx = np.clip(np.digitize(la.ravel(), edges) - 1, 0, bins - 1)
    total = np.bincount(idx, weights=lb.ravel(), minlength=bins)
    count = np.bincount(idx, minlength=bins)
    curve = np.divide(total, np.maximum(count, 1))
    # Bins no pixel landed in get the nearest populated value, so the curve
    # stays usable where the histogram has holes.
    seen = count > 0
    if seen.any():
        curve = np.interp(np.arange(bins), np.flatnonzero(seen), curve[seen])
    return curve


def apply_curve(curve: Gray, x: Gray) -> Gray:
    centres = (np.arange(len(curve)) + 0.5) / len(curve)
    return np.interp(x, centres, curve)


def ringing(
    la: Gray,
    lb: Gray,
    r: int = 2,
    edge: float = 0.02,
    bounds: tuple[Gray, Gray] | None = None,
    *,
    curve: Gray | None = None,
) -> float:
    """Local escape beyond what the frame's own tone curve explains.

    The neighbourhood bounds go through that curve before being compared, so
    what is left depends on a pixel's surroundings and not its brightness.
    This is the one to use when a change moves overall brightness.
    """
    lo, hi = bounds if bounds is not None else local_minmax(la, r)
    if curve is None:
        curve = tone_curve(la, lb)
    lo_m, hi_m = apply_curve(curve, lo), apply_curve(curve, hi)
    lo_m, hi_m = np.minimum(lo_m, hi_m), np.maximum(lo_m, hi_m)
    escaped = np.maximum(0.0, lb - hi_m) + np.maximum(0.0, lo_m - lb)
    mask = (hi - lo) > edge
    return float(escaped[mask].mean()) if mask.any() else 0.0


class Source(NamedTuple):
    """Everything a comparison needs from the source frame. A sweep measures
    one source against many outputs, so this is computed once per frame.
    """

    la: Gray
    sa: Gray
    bounds: tuple[Gray, Gray]
    scene_mean: float
    q25: float
    q75: float
    p999: float


def source(src_path: str | Path) -> Source:
    a = load(src_path)
    la = luma(a)
    q25, q75 = np.percentile(la, [25, 75])
    return Source(
        la=la,
        sa=local_std(la),
        bounds=local_minmax(la, 2),
        scene_mean=scene_mean(a),
        q25=float(q25),
        q75=float(q75),
        p999=float(np.percentile(la, 99.9)),
    )


def crunch(
    la: Gray,
    lb: Gray,
    r: int = 2,
    top: float = 90.0,
    *,
    ia: Integral | None = None,
    ib: Integral | None = None,
    iref: Integral | None = None,
) -> float:
    """Detail added where the source was already at its detail ceiling,
    beyond what the frame's own tone curve explains.

    A low resolution texture magnified on screen is already as sharp as it can
    be, so amplifying it cannot add information and reads as sharpening.

    Compared against the source put through the frame's global curve, not
    against the source itself. Any curve that steepens contrast raises local
    standard deviation everywhere with nothing sharpened, which is the same
    blind spot overshoot has and ringing exists to fix. 1.0 means the busiest
    tenth gained no more than the tone curve alone would give it.
    """
    sa = (ia or Integral(la)).std(r)
    ref = (iref or Integral(apply_curve(tone_curve(la, lb), la))).std(r)
    sb = (ib or Integral(lb)).std(r)
    m = sa >= np.percentile(sa, top)
    if m.sum() < 100:
        return 1.0
    return float(sb[m].mean() / max(ref[m].mean(), 1e-6))


def outline(
    la: Gray,
    lb: Gray,
    r: int = 2,
    edge: float = 0.06,
    *,
    bounds: tuple[Gray, Gray] | None = None,
    ref: Gray | None = None,
) -> float:
    """Extra darkening of pixels already at the bottom of their neighbourhood.

    A texture with dark lines painted into it already sits at its local
    minimum along those lines. Pushing them further down is what turns drawn
    detail into an ink outline. Measured against the frame's own tone curve so
    a global darkening does not count, and reported in 8 bit levels.
    """
    lo, hi = bounds if bounds is not None else local_minmax(la, r)
    span = hi - lo
    expected = ref if ref is not None else apply_curve(tone_curve(la, lb), la)
    # Near the local floor of a neighbourhood that has range, so flat areas
    # cannot qualify.
    m = (span > edge) & (la <= lo + 0.15 * span)
    if m.sum() < 100:
        return 0.0
    return float((expected[m] - lb[m]).mean()) * 255


def haze(
    la: Gray,
    lb: Gray,
    r: int = 16,
    quiet: float = 25.0,
    *,
    ia: Integral | None = None,
    ib: Integral | None = None,
    iref: Integral | None = None,
) -> float:
    """Contrast added to the smooth bright veil that reads as atmosphere.

    Distant haze is low contrast at a coarse scale and brighter than the
    scene's midpoint. Stretching it is what makes a hazy valley snap into
    focus and lose its depth. Measured against the frame's own tone curve for
    the same reason crunch is. 1.0 leaves the veil as the curve alone would.
    """
    sa = (ia or Integral(la)).std(r)
    ref = (iref or Integral(apply_curve(tone_curve(la, lb), la))).std(r)
    sb = (ib or Integral(lb)).std(r)
    m = (sa <= np.percentile(sa, quiet)) & (la >= np.median(la))
    if m.sum() < 100:
        return 1.0
    return float(sb[m].mean() / max(ref[m].mean(), 1e-6))


def fringe(
    la: Gray,
    lb: Gray,
    r: int = 2,
    top: float = 90.0,
    bounds: tuple[Gray, Gray] | None = None,
    *,
    curve: Gray | None = None,
    ia: Integral | None = None,
) -> float:
    """Overshoot past the neighbourhood range, in the busiest tenth of the frame.

    This is the sharpening signature: a light or dark rim appearing along the
    edges of texture that was already as detailed as its source allows. A ratio
    of local contrast cannot see it, because raising contrast smoothly and
    ringing at an edge both raise the ratio. Escape past the bounds separates
    them. Carried through the frame's tone curve like ringing, and reported in
    8 bit levels.
    """
    lo, hi = bounds if bounds is not None else local_minmax(la, r)
    if curve is None:
        curve = tone_curve(la, lb)
    lo_m, hi_m = apply_curve(curve, lo), apply_curve(curve, hi)
    escaped = np.maximum(0.0, lb - hi_m) + np.maximum(0.0, lo_m - lb)
    sa = (ia or Integral(la)).std(r)
    m = sa >= np.percentile(sa, top)
    if m.sum() < 100:
        return 0.0
    return float(escaped[m].mean()) * 255


def scale_split(
    la: Gray,
    lb: Gray,
    fine_r: int = 2,
    coarse_r: int = 12,
    *,
    ib: Integral | None = None,
    iref: Integral | None = None,
) -> tuple[float, float]:
    """How much local contrast was added, at the pixel grid and at object scale.

    A single detail ratio cannot say which of the two happened, and that is the
    whole difference between an image that reads as sharpened and one that
    reads as deep. Both radii are measured against the source put through the
    frame's own global tone curve, so a brightness move does not count.

    `fine` is how processed the frame looks. `fine / coarse` is how much of
    that sits on the pixel grid. An untouched frame gives 1.0 for both.
    """
    ib = ib or Integral(lb)
    iref = iref or Integral(apply_curve(tone_curve(la, lb), la))
    f = ib.std(fine_r).mean() / max(iref.std(fine_r).mean(), 1e-6)
    c = ib.std(coarse_r).mean() / max(iref.std(coarse_r).mean(), 1e-6)
    return float(f), float(c)


def metrics(src_path: str | Path, out_path: str | Path) -> Metrics:
    """Compare a rendered frame against the source it came from."""
    return compare(source(src_path), out_path)


def compare(src: Source, out_path: str | Path) -> Metrics:
    """As metrics(), but reusing source statistics across many outputs."""
    la, sa = src.la, src.sa
    lb = luma(load(out_path))

    # Several metrics need the same tone curve and tables, and building them
    # is most of the cost, so they are built once here and passed in.
    ia, ib = Integral(la), Integral(lb)
    curve = tone_curve(la, lb)
    ref = apply_curve(curve, la)
    iref = Integral(ref)
    sb = ib.std()

    # Bands are chosen on the source, so the effect cannot redefine the regions
    # it is judged on. They are quantiles of this frame rather than fixed luma
    # values: a night frame has almost nothing above 0.6, so a fixed highlight
    # band would measure a few lamps and miss the moonlit stone.
    q25, q75 = src.q25, src.q75
    shadow = la < q25
    mid = (la >= q25) & (la < q75)
    high = la >= q75

    def detail(mask: NDArray[np.bool_]) -> float:
        if mask.sum() < 100:
            return float("nan")
        return float(sb[mask].mean() / max(sa[mask].mean(), 1e-6))

    fine, coarse = scale_split(la, lb, ib=ib, iref=iref)

    return Metrics(
        scene_mean=src.scene_mean,
        mean_in=float(la.mean()),
        mean_out=float(lb.mean()),
        mean_shift=float(lb.mean() - la.mean()),
        # Clipping: share of pixels pinned at the ends that were not already.
        black_crush=float(((lb < 0.004) & (la >= 0.004)).mean()),
        white_blow=float(((lb > 0.996) & (la <= 0.996)).mean()),
        detail_shadow=detail(shadow),
        detail_mid=detail(mid),
        detail_high=detail(high),
        # Headroom at the top end: if the whites lose their peak, this falls.
        p999_in=src.p999,
        p999_out=float(np.percentile(lb, 99.9)),
        overshoot=overshoot(la, lb, bounds=src.bounds),
        ringing=ringing(la, lb, bounds=src.bounds, curve=curve),
        dark_rim=dark_rim(la, lb, bounds=src.bounds),
        crunch=crunch(la, lb, ia=ia, ib=ib, iref=iref),
        fringe=fringe(la, lb, bounds=src.bounds, curve=curve, ia=ia),
        outline=outline(la, lb, bounds=src.bounds, ref=ref),
        haze=haze(la, lb, ia=ia, ib=ib, iref=iref),
        fine=fine,
        coarse=coarse,
    )
