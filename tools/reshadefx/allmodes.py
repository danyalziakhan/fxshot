"""Compile an effect's shaders the way ReShade does for D3D11, in every mode.

    python tools\\reshadefx\\allmodes.py [--dir FOLDER] EFFECT [EFFECT ...]

Each effect goes through ReShade's own front end in colour spaces 1, 2 and 3,
once with uniforms as uniforms and once with them as specialisation constants,
which is what ReShade's performance mode does. Then every entry point named with
PS_ or VS_ is compiled to DXBC. Only failures and X3554 branch attribute
warnings are printed.

Performance mode is the one that gets missed. It compiles every uniform as a
constant, so the shader fxc sees is a different one, and it can fail or warn
where the normal mode is clean.

EFFECT is a path to a .fx file, or a bare name looked up in --dir, which is the
current folder when not given. Includes are searched next to each effect.
"""

from __future__ import annotations

import argparse
import re
import subprocess
from pathlib import Path

HERE = Path(__file__).resolve().parent
EXE = HERE / "reshadefxc.exe"

# Scratch outputs, overwritten on every compile and ignored by git.
LISTING = HERE / "list.hlsl"
OBJECT = HERE / "o.cso"
ERRORS = HERE / "e.txt"


def resolve(arg: str, folder: Path) -> Path:
    return Path(arg) if arg.lower().endswith(".fx") else folder / f"{arg}.fx"


def check(path: Path) -> int:
    """Compile one effect in every mode and return the number of problems."""
    bad = 0
    fx = path.stem
    for cs in (1, 2, 3):
        for mode in ("normal", "perf"):
            base = [
                str(EXE),
                "-I", str(path.parent),
                "-D", f"BUFFER_COLOR_SPACE={cs}",
                "--width", "1920",
                "--height", "1200",
            ]  # fmt: skip
            if mode == "perf":
                base.append("--spec-constants")
            r = subprocess.run(
                [*base, "--hlsl", "-Fo", str(LISTING), str(path)],
                capture_output=True,
                text=True,
                check=False,
            )
            if r.returncode:
                detail = (r.stdout + r.stderr).strip()[:400]
                print(fx, cs, mode, "front end failed:", detail)
                bad += 1
                continue
            listing = LISTING.read_text()
            pattern = r"^\w+ (F__\w*(?:PS|VS)_\w+)\("
            for e in sorted(set(re.findall(pattern, listing, re.M))):
                ERRORS.unlink(missing_ok=True)
                r = subprocess.run(
                    [
                        *base,
                        "--dxbc",
                        "-E",
                        e,
                        "-Fo",
                        str(OBJECT),
                        "-Fe",
                        str(ERRORS),
                        str(path),
                    ],
                    capture_output=True,
                    text=True,
                    check=False,
                )
                msg = ERRORS.read_text() if ERRORS.exists() else ""
                errs = [ln for ln in msg.splitlines() if ": error" in ln]
                warns = [ln for ln in msg.splitlines() if "X3554" in ln]
                if r.returncode or errs or warns:
                    bad += 1
                    print(
                        fx, cs, mode, e, "exit", r.returncode, "errors", len(errs),
                        "branch warnings", len(warns),
                    )  # fmt: skip
                    for ln in (errs or warns)[:2]:
                        print("   ", ln.split("): ", 1)[-1])
    print(fx, "checked")
    return bad


def main() -> None:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("effects", nargs="+", metavar="EFFECT")
    ap.add_argument(
        "--dir", type=Path, default=Path.cwd(), help="folder for bare effect names"
    )
    args = ap.parse_args()
    effects = [resolve(a, args.dir) for a in args.effects]
    bad = sum(check(p) for p in effects)
    print("problems:", bad)


if __name__ == "__main__":
    main()
