"""Translate a ReShade FX effect into plain HLSL plus a resource manifest.

The point is fidelity. Pixel shader bodies are handed to the real HLSL compiler
untouched, so the arithmetic that runs is the arithmetic in the .fx file. Only
the declarations around them are rewritten, because those are ReShade FX syntax
that fxc does not accept.

Usage:
    python translate.py Effect.fx outdir WIDTH HEIGHT [--color-space N]

Buffer size is baked in, because effects branch on BUFFER_WIDTH at compile time,
so translate again to render at another resolution.
"""

from __future__ import annotations

import argparse
import re
from dataclasses import dataclass, field
from pathlib import Path

# ReShade texture formats to their DXGI equivalents.
FORMATS: dict[str, str] = {
    "R8": "R8_UNORM",
    "R16F": "R16_FLOAT",
    "R32F": "R32_FLOAT",
    "RG8": "R8G8_UNORM",
    "RG16F": "R16G16_FLOAT",
    "RG32F": "R32G32_FLOAT",
    "RGBA8": "R8G8B8A8_UNORM",
    "RGBA16F": "R16G16B16A16_FLOAT",
    "RGBA32F": "R32G32B32A32_FLOAT",
}

# D3D11 gives a shader stage 128 texture slots but only 16 sampler slots.
MAX_SAMPLER_STATES = 16

# ReShade's BUFFER_COLOR_SPACE to the swap chain format that goes with it. Only
# the two the host can load an image into are offered.
BACKBUFFER_FORMATS: dict[int, str] = {
    1: "R8G8B8A8_UNORM",
    2: "R16G16B16A16_FLOAT",
}


@dataclass(slots=True)
class Texture:
    name: str
    semantic: str | None = None
    width: int = 0
    height: int = 0
    format: str = "R8G8B8A8_UNORM"
    mips: int = 1
    source: str | None = None


@dataclass(slots=True)
class Sampler:
    name: str
    texture: str
    min_filter: str = "LINEAR"
    mag_filter: str = "LINEAR"
    mip_filter: str = "LINEAR"
    address_u: str = "CLAMP"
    address_v: str = "CLAMP"

    @property
    def state(self) -> tuple[str, ...]:
        """The parts that define a distinct D3D sampler state."""
        return (
            self.min_filter,
            self.mag_filter,
            self.mip_filter,
            self.address_u,
            self.address_v,
        )


@dataclass(slots=True)
class Uniform:
    type: str
    name: str
    default: str | None = None
    source: str | None = None


@dataclass(slots=True)
class Pass:
    name: str
    vertex_shader: str | None
    pixel_shader: str | None
    render_target: str | None  # None means the backbuffer


@dataclass(slots=True)
class Effect:
    technique: str
    width: int
    height: int
    textures: dict[str, Texture] = field(default_factory=dict)
    samplers: dict[str, Sampler] = field(default_factory=dict)
    uniforms: list[Uniform] = field(default_factory=list)
    passes: list[Pass] = field(default_factory=list)
    backbuffer_format: str = BACKBUFFER_FORMATS[1]

    def sampler_states(self) -> dict[tuple[str, ...], int]:
        """Distinct sampler configurations, mapped to register slots. Effects
        often declare more samplers than D3D11 has slots, but few distinct states.
        """
        states: dict[tuple[str, ...], int] = {}
        for sampler in self.samplers.values():
            states.setdefault(sampler.state, len(states))
        if len(states) > MAX_SAMPLER_STATES:
            raise SystemExit(
                f"effect needs {len(states)} distinct sampler states; "
                f"D3D11 allows {MAX_SAMPLER_STATES}"
            )
        return states


def strip_comments(source: str) -> str:
    """Remove comments, leaving string literals intact. Prose about textures
    would otherwise be scanned as declarations.
    """
    out: list[str] = []
    i, n = 0, len(source)
    in_string = False
    while i < n:
        c = source[i]
        if in_string:
            out.append(c)
            if c == "\\" and i + 1 < n:
                out.append(source[i + 1])
                i += 2
                continue
            if c == '"':
                in_string = False
            i += 1
        elif c == '"':
            in_string = True
            out.append(c)
            i += 1
        elif source.startswith("/*", i):
            j = source.find("*/", i + 2)
            i = n if j < 0 else j + 2
        elif source.startswith("//", i):
            j = source.find("\n", i)
            i = n if j < 0 else j
        else:
            out.append(c)
            i += 1
    return "".join(out)


def mask_strings(source: str) -> str:
    """Blank string literals, keeping length so offsets still line up. Tooltips
    contain braces and angle brackets that would end a scan early.
    """
    out = list(source)
    i, n = 0, len(source)
    while i < n:
        if source[i] == '"':
            j = i + 1
            while j < n and source[j] != '"':
                if source[j] == "\\":
                    j += 1
                out[j] = " "
                j += 1
            i = j + 1
        else:
            i += 1
    return "".join(out)


def find_matching(text: str, i: int, open_ch: str, close_ch: str) -> int:
    """Index just past the delimiter matching the one at i."""
    depth = 0
    while i < len(text):
        match text[i]:
            case c if c == open_ch:
                depth += 1
            case c if c == close_ch:
                depth -= 1
                if depth == 0:
                    return i + 1
        i += 1
    raise ValueError(f"unbalanced {open_ch}{close_ch}")


def parse_state_block(body: str) -> dict[str, str]:
    """`{ Width = 5; Format = R16F; }` to a plain dict."""
    return {
        m[1].strip(): m[2].strip() for m in re.finditer(r"(\w+)\s*=\s*([^;]+);", body)
    }


def evaluate_condition(directive: str, arg: str, known: dict[str, str]) -> bool:
    """One #if, #ifdef or #ifndef test, the way the C preprocessor reads it."""
    match directive:
        case "ifdef":
            return arg.split()[0] in known
        case "ifndef":
            return arg.split()[0] not in known

    expr = re.sub(
        r"\bdefined\s*\(\s*(\w+)\s*\)|\bdefined\s+(\w+)",
        lambda m: "1" if (m[1] or m[2]) in known else "0",
        arg,
    )
    identifier = r"\b[A-Za-z_]\w*\b"
    for _ in range(8):
        expanded = re.sub(
            identifier,
            lambda m: f"({known[m[0]]})" if m[0] in known else m[0],
            expr,
        )
        if expanded == expr:
            break
        expr = expanded
    # An identifier nothing defines is 0 in a condition.
    expr = re.sub(identifier, "0", expr)
    expr = expr.replace("&&", " and ").replace("||", " or ")
    expr = re.sub(r"!(?!=)", " not ", expr)
    return bool(eval(expr))


def resolve_conditionals(source: str, defines: dict[str, str]) -> str:
    """Keep only the lines an #if chain selects. Without this a texture, pass or
    uniform declared for another colour space or resolution would be scanned
    and emitted as if it were live. Defines met along the way count toward
    later conditions, as they do in the real preprocessor.
    """
    known = dict(defines)
    out: list[str] = []
    # Per open #if: whether its parent was live, and whether a branch was taken.
    stack: list[tuple[bool, bool]] = []
    live = True
    for line in source.split("\n"):
        m = re.match(r"[ \t]*#[ \t]*(\w+)[ \t]*(.*)", line)
        directive, arg = (m[1], m[2].strip()) if m else ("", "")
        match directive:
            case "if" | "ifdef" | "ifndef":
                taken = live and evaluate_condition(directive, arg, known)
                stack.append((live, taken))
                live = taken
                continue
            case "elif":
                parent, done = stack[-1]
                live = parent and not done and evaluate_condition("if", arg, known)
                stack[-1] = (parent, done or live)
                continue
            case "else":
                parent, done = stack[-1]
                live = parent and not done
                stack[-1] = (parent, True)
                continue
            case "endif":
                live = stack.pop()[0]
                continue
            case "define" if live:
                if d := re.match(r"(\w+)(?:[ \t]+(.*))?$", arg):
                    known.setdefault(d[1], (d[2] or "").strip())
        if live:
            out.append(line)
    return "\n".join(out)


def make_evaluator(defines: dict[str, str]):
    """Resolve a size expression such as (BUFFER_WIDTH / SCALE)."""

    def evaluate(expr: str) -> int:
        for _ in range(8):
            expanded = expr
            for key, value in defines.items():
                expanded = re.sub(rf"\b{re.escape(key)}\b", f"({value})", expanded)
            if expanded == expr:
                break
            expr = expanded
        return int(eval(expr))

    return evaluate


def parse(source: str, defines: dict[str, str], width: int, height: int) -> Effect:
    """Pull textures, samplers, uniforms and the technique out of the source."""
    scan = mask_strings(source)
    evaluate = make_evaluator(defines)

    technique_match = re.search(r"\btechnique\s+(\w+)\s*(<[^>]*>)?\s*\{", scan)
    if technique_match is None:
        raise SystemExit("no technique found in effect")
    effect = Effect(technique_match[1], width, height)

    for m in re.finditer(r"\btexture\s+(\w+)\s*(<[^>]*>)?\s*", scan):
        name = m[1]
        rest = scan[m.end() :]
        if rest.lstrip().startswith(":"):
            if semantic := re.match(r"\s*:\s*(\w+)\s*;", rest):
                effect.textures[name] = Texture(name, semantic=semantic[1].upper())
            continue
        if not rest.lstrip().startswith("{"):
            continue
        start = m.end() + (len(rest) - len(rest.lstrip()))
        state = parse_state_block(
            scan[start + 1 : find_matching(scan, start, "{", "}") - 1]
        )
        # The annotation is blanked in the mask, so read the real one.
        annotation = re.search(rf"\btexture\s+{name}\s*<([^>]*)>", source)
        file_ref = (
            re.search(r'source\s*=\s*"([^"]+)"', annotation[1]) if annotation else None
        )
        effect.textures[name] = Texture(
            name=name,
            width=evaluate(state.get("Width", "1")),
            height=evaluate(state.get("Height", "1")),
            format=FORMATS[state.get("Format", "RGBA8")],
            mips=evaluate(state.get("MipLevels", "1")),
            source=file_ref[1] if file_ref else None,
        )

    for m in re.finditer(r"\bsampler\s+(\w+)\s*\{", scan):
        state = parse_state_block(
            scan[m.end() : find_matching(scan, m.end() - 1, "{", "}") - 1]
        )
        effect.samplers[m[1]] = Sampler(
            name=m[1],
            texture=state["Texture"],
            min_filter=state.get("MinFilter", "LINEAR").upper(),
            mag_filter=state.get("MagFilter", "LINEAR").upper(),
            mip_filter=state.get("MipFilter", "LINEAR").upper(),
            address_u=state.get("AddressU", "CLAMP").upper(),
            address_v=state.get("AddressV", "CLAMP").upper(),
        )

    for m in re.finditer(
        r"\buniform\s+(\w+)\s+(\w+)\s*(<[^>]*>)?\s*(=\s*([^;]+))?;", scan, re.S
    ):
        name = m[2]
        annotation = re.search(rf"\buniform\s+\w+\s+{name}\s*<(.*?)>", source, re.S)
        engine = (
            re.search(r'source\s*=\s*"(\w+)"', annotation[1]) if annotation else None
        )
        effect.uniforms.append(
            Uniform(
                type=m[1],
                name=name,
                default=m[5].strip() if m[5] else None,
                source=engine[1] if engine else None,
            )
        )

    body = scan[
        technique_match.end() : find_matching(scan, technique_match.end() - 1, "{", "}")
        - 1
    ]
    for m in re.finditer(r"\bpass\s+(\w+)?\s*\{([^}]*)\}", body):
        state = parse_state_block(m[2])
        effect.passes.append(
            Pass(
                name=m[1] or f"pass{len(effect.passes)}",
                vertex_shader=state.get("VertexShader"),
                pixel_shader=state.get("PixelShader"),
                render_target=state.get("RenderTarget"),
            )
        )

    return effect


def make_hlsl(source: str, effect: Effect, defines: dict[str, str]) -> str:
    """Rewrite declarations to HLSL, leaving function bodies alone. Searching
    runs on a string-masked copy so every cut is decided on code.
    """
    body, mask = source, mask_strings(source)

    def cut(start: int, end: int) -> None:
        nonlocal body, mask
        body = body[:start] + body[end:]
        mask = mask[:start] + mask[end:]

    while m := re.search(r"\btexture\s+\w+\s*(<[^>]*>)?\s*:\s*\w+\s*;", mask):
        cut(m.start(), m.end())

    for pattern in (r"\btexture\s+\w+\s*(<[^>]*>)?\s*\{", r"\bsampler\s+\w+\s*\{"):
        while m := re.search(pattern, mask):
            end = find_matching(mask, m.end() - 1, "{", "}")
            while end < len(mask) and mask[end] in " \t\r\n":
                end += 1
            if end < len(mask) and mask[end] == ";":
                end += 1
            cut(m.start(), end)

    while m := re.search(
        r"\buniform\s+\w+\s+\w+\s*(<[^>]*>)?\s*(=\s*[^;]+)?;", mask, re.S
    ):
        cut(m.start(), m.end())

    if m := re.search(r"\btechnique\s+\w+\s*(<[^>]*>)?\s*\{", mask):
        cut(m.start(), find_matching(mask, m.end() - 1, "{", "}"))

    # fxc has no namespaces. Members reached through a qualified name have to
    # be renamed at their declaration too, not just at the use site.
    while m := re.search(r"\bnamespace\s+(\w+)\s*\{", mask):
        namespace = m[1]
        end = find_matching(mask, m.end() - 1, "{", "}")
        if members := set(re.findall(rf"\b{namespace}::(\w+)", body)):
            inner_body, inner_mask = body[m.end() : end - 1], mask[m.end() : end - 1]
            for member in members:
                # A sampler or texture reached this way is renamed in the
                # effect's own tables as well, since those name the registers.
                flat = f"{namespace}_{member}"
                if member in effect.samplers:
                    effect.samplers[flat] = effect.samplers.pop(member)
                    effect.samplers[flat].name = flat
                if member in effect.textures:
                    effect.textures[flat] = effect.textures.pop(member)
                    effect.textures[flat].name = flat
                    for s in effect.samplers.values():
                        if s.texture == member:
                            s.texture = flat
                pattern = rf"\b{re.escape(member)}\b"
                inner_body = re.sub(pattern, f"{namespace}_{member}", inner_body)
                inner_mask = re.sub(pattern, f"{namespace}_{member}", inner_mask)
            body = body[: m.end()] + inner_body + body[end - 1 :]
            mask = mask[: m.end()] + inner_mask + mask[end - 1 :]
            end = m.end() + len(inner_body) + 1
        cut(end - 1, end)
        cut(m.start(), m.end())
        body = body.replace(f"{namespace}::", f"{namespace}_")
        mask = mask.replace(f"{namespace}::", f"{namespace}_")

    out = ["// Generated by translate.py, do not edit.", ""]

    # Only inject defines the effect does not set for itself, or fxc reports a
    # redefinition for every one it already has.
    own = set(re.findall(r"^[ \t]*#define[ \t]+(\w+)", body, re.M))
    out += [f"#define {k} ({v})" for k, v in defines.items() if k not in own]
    out.append("")

    # One Texture2D per FX sampler, named after it so the intrinsic macros can
    # reach both halves from a single identifier.
    out += [
        f"Texture2D    {s.name}_t : register(t{slot});"
        for slot, s in enumerate(effect.samplers.values())
    ]
    out.append("")

    states = effect.sampler_states()
    out += [
        f"SamplerState _smp{idx} : register(s{idx});   // {' '.join(key)}"
        for key, idx in states.items()
    ]
    out += [
        f"#define {s.name}_s _smp{states[s.state]}" for s in effect.samplers.values()
    ]
    # A sampler parameter becomes a texture and a state named the way the
    # intrinsic macros expect, and a sampler passed as an argument is spelled
    # out as both, except as the first argument of an intrinsic. This has to be
    # a source rewrite: fxc expands a bare name inside a macro argument list
    # before counting the arguments.
    params = set(re.findall(r"\bsampler(?:2D)?\s+(\w+)(?=\s*[,)])", body))
    body = re.sub(
        r"\bsampler(?:2D)?\s+(\w+)(?=\s*[,)])",
        r"Texture2D \1_t, SamplerState \1_s",
        body,
    )
    passable = set(effect.samplers) | params

    def split_sampler(m: re.Match) -> str:
        if re.search(r"\btex2D\w*\s*\(\s*$", body[max(0, m.start() - 40) : m.start()]):
            return m[0]
        return f"{m[1]}_t, {m[1]}_s"

    if passable:
        names = "|".join(sorted(map(re.escape, passable), key=len, reverse=True))
        body = re.sub(
            rf"(?<![\w.])({names})\b(?!_[ts]\b)(?=\s*[,)])", split_sampler, body
        )
    out += [
        "",
        "#define tex2D(s, uv)      s##_t.Sample(s##_s, (uv))",
        "#define tex2Dlod(s, c)    s##_t.SampleLevel(s##_s, (c).xy, (c).w)",
        "#define tex2Dfetch(s, c)  s##_t.Load(int3((int2)(c), 0))",
        "#define tex2Dsize(s)      _tex2Dsize(s##_t)",
        "int2 _tex2Dsize(Texture2D t) { uint w, h; t.GetDimensions(w, h); return int2(w, h); }",
        "",
        "cbuffer Uniforms : register(b0) {",
    ]
    for u, o in zip(effect.uniforms, pack_offsets(effect.uniforms), strict=True):
        slot = f"c{o // 4}.{'xyzw'[o % 4]}"
        out.append(
            f"    {u.type.replace('bool', 'int')} {u.name} : packoffset({slot});"
        )
    out += ["};", "", body]
    return "\n".join(out)


def make_manifest(effect: Effect) -> str:
    """Flat line based manifest, so the C++ host needs no JSON dependency."""
    lines = [f"SIZE {effect.width} {effect.height}"]
    for t in effect.textures.values():
        if t.semantic == "COLOR":
            lines.append(f"TEX {t.name} BACKBUFFER 0 0 {effect.backbuffer_format} 1 -")
        elif t.semantic:
            # Any other semantic is one an add-on binds, and with no add-on here
            # ReShade leaves it on its 1x1 empty texture.
            lines.append(f"TEX {t.name} NORMAL 1 1 R16_FLOAT 1 -")
        else:
            lines.append(
                f"TEX {t.name} NORMAL {t.width} {t.height} {t.format} "
                f"{t.mips} {t.source or '-'}"
            )

    states = effect.sampler_states()
    lines += [
        f"SAMSTATE {idx} {' '.join(key)}"
        for key, idx in sorted(states.items(), key=lambda kv: kv[1])
    ]
    lines += [
        f"SAM {s.name} {s.texture} {states[s.state]}" for s in effect.samplers.values()
    ]
    # The last two fields are the packed offset in 4-byte slots and the
    # component count.
    lines += [
        f"UNI {components(u.type)[0]} {u.name} {u.source or '-'} "
        f"{literal(u) if not u.source else '-'} {o} {components(u.type)[1]}"
        for u, o in zip(effect.uniforms, pack_offsets(effect.uniforms), strict=True)
    ]
    lines += [
        f"PASS {p.name} {p.vertex_shader or 'PostProcessVS'} "
        f"{p.pixel_shader} {p.render_target or '-'}"
        for p in effect.passes
    ]
    return "\n".join(lines) + "\n"


def components(type_name: str) -> tuple[str, int]:
    """Scalar type and component count: float2 is ("float", 2)."""
    m = re.fullmatch(r"(bool|int|uint|float)([1-4])?", type_name)
    if not m:
        raise SystemExit(f"uniform type {type_name} is not supported")
    return m.group(1), int(m.group(2) or 1)


def pack_offsets(uniforms: list[Uniform]) -> list[int]:
    """Each uniform's offset in 4-byte slots under HLSL cbuffer packing, where
    a vector may not straddle a 16-byte register."""
    offsets, at = [], 0
    for u in uniforms:
        n = components(u.type)[1]
        if n > 1 and at // 4 != (at + n - 1) // 4:
            at = (at // 4 + 1) * 4
        offsets.append(at)
        at += n
    return offsets


def literal(u: Uniform) -> str:
    """A uniform's declared default, in the form a preset .ini uses: vector
    components comma separated, as ReShade writes them."""
    value = (u.default or "").strip()
    base, n = components(u.type)
    if n > 1:
        nums = re.findall(
            r"[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?", value.split("(", 1)[-1]
        ) or ["0"]
        if len(nums) == 1:
            nums *= n
        if base == "float":
            return ",".join(f"{float(v):.6f}" for v in nums[:n])
        return ",".join(str(int(float(v))) for v in nums[:n])
    match base:
        case "bool":
            return "1" if value == "true" else "0"
        case "int" | "uint":
            return value or "0"
        case _:
            return f"{float(value or 0.0):.6f}"


def write_defaults(effect: Effect) -> str:
    """A preset with every uniform at the effect's own default. Engine-fed
    uniforms are skipped, since the host supplies those.
    """
    section = effect.technique.split("@")[-1]
    body = "\n".join(
        f"{u.name}={literal(u)}"
        for u in sorted(effect.uniforms, key=lambda u: u.name.lower())
        if not u.source
    )
    return (
        f"Techniques={effect.technique}\n"
        f"TechniqueSorting={effect.technique}\n\n"
        f"[{section}]\n{body}\n"
    )


def base_defines(width: int, height: int, color_space: int) -> dict[str, str]:
    biggest = max(width, height)
    # Enough mip levels for a full resolution chain to reach 1x1. Effects pick
    # this with an #if chain on buffer size, so resolve it before harvesting
    # their #defines, or the first branch wins regardless of resolution.
    luma_mips = (
        13
        if biggest >= 4096
        else 12
        if biggest >= 2048
        else 11
        if biggest >= 1024
        else 10
    )
    return {
        "BUFFER_WIDTH": str(width),
        "BUFFER_HEIGHT": str(height),
        "BUFFER_RCP_WIDTH": f"(1.0/{width})",
        "BUFFER_RCP_HEIGHT": f"(1.0/{height})",
        "BUFFER_COLOR_BIT_DEPTH": "16" if color_space == 2 else "8",
        "BUFFER_COLOR_SPACE": str(color_space),
        "__RESHADE__": "60000",
        "SCALE": "2",
        "LUMA_FULLRES_MIPS": str(luma_mips),
    }


def inline_includes(path: Path, seen: set[Path] | None = None) -> str:
    """The effect with each #include "file" replaced by that file's text,
    resolved relative to the including file. Each file is inlined once, which
    also covers #pragma once."""
    seen = set() if seen is None else seen
    seen.add(path.resolve())

    def expand(m: re.Match) -> str:
        target = (path.parent / m.group(1)).resolve()
        if target in seen:
            return ""
        if not target.exists():
            raise SystemExit(f"{path.name}: cannot find include {m.group(1)}")
        return inline_includes(target, seen)

    text = path.read_text(encoding="utf-8", errors="replace")
    text = re.sub(r"^\s*#\s*pragma\s+once\s*$", "", text, flags=re.M)
    return re.sub(
        r'^[ \t]*#[ \t]*include[ \t]*"([^"]+)"[ \t]*$', expand, text, flags=re.M
    )


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("effect", type=Path, help="the .fx file to translate")
    ap.add_argument(
        "outdir", type=Path, help="where to write effect.hlsl and manifest.txt"
    )
    ap.add_argument("width", type=int)
    ap.add_argument("height", type=int)
    ap.add_argument(
        "--defaults",
        type=Path,
        help="also write a preset .ini holding every uniform at its default",
    )
    ap.add_argument(
        "--color-space",
        type=int,
        choices=sorted(BACKBUFFER_FORMATS),
        default=1,
        help="BUFFER_COLOR_SPACE to compile for: 1 is 8 bit sRGB, 2 is float scRGB",
    )
    args = ap.parse_args()
    args.outdir.mkdir(parents=True, exist_ok=True)

    defines = base_defines(args.width, args.height, args.color_space)
    source = strip_comments(inline_includes(args.effect))
    source = resolve_conditionals(source, defines)

    # The source is comment free by now, so an object-like define runs to end
    # of line. Function-like ones would need real macro expansion.
    for m in re.finditer(r"^[ \t]*#define[ \t]+(\w+)[ \t]+([^\n]+)", source, re.M):
        defines.setdefault(m[1].strip(), m[2].strip())

    effect = parse(source, defines, args.width, args.height)
    effect.backbuffer_format = BACKBUFFER_FORMATS[args.color_space]
    (args.outdir / "effect.hlsl").write_text(
        make_hlsl(source, effect, defines), encoding="utf-8"
    )
    (args.outdir / "manifest.txt").write_text(make_manifest(effect), encoding="utf-8")
    print(
        f"technique {effect.technique}: {len(effect.passes)} passes, "
        f"{len(effect.textures)} textures, {len(effect.samplers)} samplers, "
        f"{len(effect.uniforms)} uniforms"
    )
    if engine := [u.name for u in effect.uniforms if u.source]:
        print("engine-fed uniforms:", ", ".join(engine))

    if args.defaults:
        args.defaults.write_text(write_defaults(effect), encoding="utf-8")
        print(f"wrote {args.defaults}")


if __name__ == "__main__":
    main()
