#!/usr/bin/env python3
"""Calibrate per-character glyph width tables against real Chrome.

This produces the FONT_SANS / FONT_SERIF tables and the mono ratio used by
``kuri-browser/src/engine.zig`` so SVG paint x-positions align with Chrome's
rasterized text.

Approach
--------
For each font family (sans-serif / Times / Courier) we generate an HTML page
containing a ``<span>`` per printable ASCII character (0x20..0x7E). A short
inline ``<script>`` measures each span's ``getBoundingClientRect().width`` at
font-size 16px and writes the JSON-encoded results into ``document.title``.
We then run Chrome in headless mode with ``--dump-dom``, parse the rendered
HTML, extract the title, and divide each measured width by 16 to get the
per-character ratio in font-size units.

If Chrome is not available the script falls back to known-good hand-tuned
ratios derived from public advance-width references (Helvetica / Arial,
Times, Courier) and prints the same Zig source block. The hand-tuned table
will produce the same output as a fresh checkout; rerun with Chrome present
to refresh.

Usage
-----
    python3 tools/calibrate_widths.py             # auto-detect Chrome, print Zig
    python3 tools/calibrate_widths.py --json      # also dump the raw measurements
    python3 tools/calibrate_widths.py --no-chrome # force fallback values

Equivalent manual command (if you want to reproduce by hand)::

    /Applications/Google\\ Chrome.app/Contents/MacOS/Google\\ Chrome \\
        --headless=new --disable-gpu --no-sandbox --hide-scrollbars \\
        --virtual-time-budget=2000 --dump-dom \\
        "file:///tmp/calib_sans.html"

Then read ``<title>...</title>`` out of the resulting stdout.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
from pathlib import Path


DEFAULT_CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
FONT_SIZE = 16
PRINTABLE = list(range(0x20, 0x7F))  # 0x20..0x7E inclusive


# ---------------------------------------------------------------------------
# Hand-tuned fallback values (used when Chrome is unavailable).
#
# Sources:
#   - Helvetica / Arial advance widths (Adobe Font Metrics, em 1000 units)
#   - Times Roman advance widths (Adobe AFM)
#   - Courier is monospace; advance is constant 600/1000 = 0.60
# Values are advance / em.
# ---------------------------------------------------------------------------

FALLBACK_SANS: dict[int, float] = {
    0x20: 0.278, 0x21: 0.278, 0x22: 0.355, 0x23: 0.556, 0x24: 0.556,
    0x25: 0.889, 0x26: 0.667, 0x27: 0.191, 0x28: 0.333, 0x29: 0.333,
    0x2A: 0.389, 0x2B: 0.584, 0x2C: 0.278, 0x2D: 0.333, 0x2E: 0.278,
    0x2F: 0.278,
    0x30: 0.556, 0x31: 0.556, 0x32: 0.556, 0x33: 0.556, 0x34: 0.556,
    0x35: 0.556, 0x36: 0.556, 0x37: 0.556, 0x38: 0.556, 0x39: 0.556,
    0x3A: 0.278, 0x3B: 0.278, 0x3C: 0.584, 0x3D: 0.584, 0x3E: 0.584,
    0x3F: 0.556, 0x40: 1.015,
    0x41: 0.667, 0x42: 0.667, 0x43: 0.722, 0x44: 0.722, 0x45: 0.667,
    0x46: 0.611, 0x47: 0.778, 0x48: 0.722, 0x49: 0.278, 0x4A: 0.500,
    0x4B: 0.667, 0x4C: 0.556, 0x4D: 0.833, 0x4E: 0.722, 0x4F: 0.778,
    0x50: 0.667, 0x51: 0.778, 0x52: 0.722, 0x53: 0.667, 0x54: 0.611,
    0x55: 0.722, 0x56: 0.667, 0x57: 0.944, 0x58: 0.667, 0x59: 0.667,
    0x5A: 0.611,
    0x5B: 0.278, 0x5C: 0.278, 0x5D: 0.278, 0x5E: 0.469, 0x5F: 0.556,
    0x60: 0.333,
    0x61: 0.556, 0x62: 0.556, 0x63: 0.500, 0x64: 0.556, 0x65: 0.556,
    0x66: 0.278, 0x67: 0.556, 0x68: 0.556, 0x69: 0.222, 0x6A: 0.222,
    0x6B: 0.500, 0x6C: 0.222, 0x6D: 0.833, 0x6E: 0.556, 0x6F: 0.556,
    0x70: 0.556, 0x71: 0.556, 0x72: 0.333, 0x73: 0.500, 0x74: 0.278,
    0x75: 0.556, 0x76: 0.500, 0x77: 0.722, 0x78: 0.500, 0x79: 0.500,
    0x7A: 0.500,
    0x7B: 0.334, 0x7C: 0.260, 0x7D: 0.334, 0x7E: 0.584,
}

FALLBACK_SERIF: dict[int, float] = {
    0x20: 0.250, 0x21: 0.333, 0x22: 0.408, 0x23: 0.500, 0x24: 0.500,
    0x25: 0.833, 0x26: 0.778, 0x27: 0.333, 0x28: 0.333, 0x29: 0.333,
    0x2A: 0.500, 0x2B: 0.564, 0x2C: 0.250, 0x2D: 0.333, 0x2E: 0.250,
    0x2F: 0.278,
    0x30: 0.500, 0x31: 0.500, 0x32: 0.500, 0x33: 0.500, 0x34: 0.500,
    0x35: 0.500, 0x36: 0.500, 0x37: 0.500, 0x38: 0.500, 0x39: 0.500,
    0x3A: 0.278, 0x3B: 0.278, 0x3C: 0.564, 0x3D: 0.564, 0x3E: 0.564,
    0x3F: 0.444, 0x40: 0.921,
    0x41: 0.722, 0x42: 0.667, 0x43: 0.667, 0x44: 0.722, 0x45: 0.611,
    0x46: 0.556, 0x47: 0.722, 0x48: 0.722, 0x49: 0.333, 0x4A: 0.389,
    0x4B: 0.722, 0x4C: 0.611, 0x4D: 0.889, 0x4E: 0.722, 0x4F: 0.722,
    0x50: 0.556, 0x51: 0.722, 0x52: 0.667, 0x53: 0.556, 0x54: 0.611,
    0x55: 0.722, 0x56: 0.722, 0x57: 0.944, 0x58: 0.722, 0x59: 0.722,
    0x5A: 0.611,
    0x5B: 0.333, 0x5C: 0.278, 0x5D: 0.333, 0x5E: 0.469, 0x5F: 0.500,
    0x60: 0.333,
    0x61: 0.444, 0x62: 0.500, 0x63: 0.444, 0x64: 0.500, 0x65: 0.444,
    0x66: 0.333, 0x67: 0.500, 0x68: 0.500, 0x69: 0.278, 0x6A: 0.278,
    0x6B: 0.500, 0x6C: 0.278, 0x6D: 0.778, 0x6E: 0.500, 0x6F: 0.500,
    0x70: 0.500, 0x71: 0.500, 0x72: 0.333, 0x73: 0.389, 0x74: 0.278,
    0x75: 0.500, 0x76: 0.500, 0x77: 0.722, 0x78: 0.500, 0x79: 0.500,
    0x7A: 0.444,
    0x7B: 0.480, 0x7C: 0.200, 0x7D: 0.480, 0x7E: 0.541,
}

# Courier / Menlo monospace advance is exactly 0.6 em.
FALLBACK_MONO = 0.600


# ---------------------------------------------------------------------------
# HTML generation
# ---------------------------------------------------------------------------

def make_html(font_css: str) -> str:
    """Build a measurement page for the given CSS ``font`` shorthand.

    Each printable ASCII codepoint is rendered inside its own ``<span>`` with a
    stable id ``g_0xNN``. After the document loads, JS measures every span and
    drops a JSON map ``{"NN": pixel_width, ...}`` into ``document.title``.
    """
    spans = []
    for cp in PRINTABLE:
        # Use HTML entity encoding so reserved chars don't break the markup,
        # and so leading whitespace renders. ``&#NN;`` works for everything.
        entity = f"&#{cp};"
        spans.append(f'<span id="g_{cp:02X}">{entity}</span>')
    body = "\n  ".join(spans)
    return f"""<!doctype html>
<html><head><meta charset="utf-8"><title>pending</title>
<style>
  html,body {{ margin:0; padding:0; }}
  body {{ font: {font_css}; }}
  span {{ white-space: pre; }}
</style>
</head><body>
  {body}
<script>
(function(){{
  var out = {{}};
  for (var cp = 0x20; cp <= 0x7E; cp++) {{
    var key = ('00' + cp.toString(16).toUpperCase()).slice(-2);
    var el = document.getElementById('g_' + key);
    if (!el) continue;
    var rect = el.getBoundingClientRect();
    out[key] = rect.width;
  }}
  document.title = '__W__' + JSON.stringify(out) + '__E__';
}})();
</script>
</body></html>
"""


# ---------------------------------------------------------------------------
# Chrome driver
# ---------------------------------------------------------------------------

def chrome_dump_dom(chrome: str, html_path: Path, timeout: float) -> str:
    """Run ``chrome --dump-dom`` against ``html_path`` and return the rendered
    HTML stdout. Raises if Chrome fails or produces no usable output."""
    with tempfile.TemporaryDirectory(prefix="kuri-calib-") as profile_dir:
        cmd = [
            chrome,
            "--headless=new",
            "--disable-gpu",
            "--no-sandbox",
            "--hide-scrollbars",
            "--disable-background-networking",
            "--disable-component-update",
            "--no-first-run",
            "--no-default-browser-check",
            f"--user-data-dir={profile_dir}",
            "--virtual-time-budget=2000",
            "--run-all-compositor-stages-before-draw",
            "--dump-dom",
            f"file://{html_path}",
        ]
        proc = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            start_new_session=True,
        )
        try:
            stdout, stderr = proc.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            stdout, stderr = proc.communicate()
        if proc.returncode not in (0, -signal.SIGKILL):
            raise SystemExit(
                f"Chrome --dump-dom failed (rc={proc.returncode}):\n{stderr}"
            )
        return stdout


_TITLE_RE = re.compile(r"<title>__W__(.*?)__E__</title>", re.DOTALL)


def parse_widths(html: str) -> dict[int, float]:
    m = _TITLE_RE.search(html)
    if not m:
        # Try a broader fallback: hunt for the marker anywhere.
        m2 = re.search(r"__W__(.*?)__E__", html, re.DOTALL)
        if not m2:
            raise SystemExit("Could not find width payload in Chrome output.")
        payload = m2.group(1)
    else:
        payload = m.group(1)
    raw = json.loads(payload)
    out: dict[int, float] = {}
    for k, v in raw.items():
        out[int(k, 16)] = float(v)
    return out


def measure(chrome: str | None, font_css: str, timeout: float) -> dict[int, float]:
    """Return measured pixel widths keyed by codepoint for ``font_css``."""
    if chrome is None:
        raise RuntimeError("chrome path is required for measure()")
    html = make_html(font_css)
    with tempfile.NamedTemporaryFile(
        mode="w", suffix=".html", delete=False, encoding="utf-8"
    ) as fh:
        fh.write(html)
        path = Path(fh.name)
    try:
        rendered = chrome_dump_dom(chrome, path, timeout)
        return parse_widths(rendered)
    finally:
        try:
            path.unlink()
        except OSError:
            pass


# ---------------------------------------------------------------------------
# Zig source emission
# ---------------------------------------------------------------------------

def _zig_char_literal(cp: int) -> str:
    """Return the Zig source token used to index the table, e.g. ``' '`` or
    ``'A'`` or ``0x7E`` for chars that need no special escape but where the
    Zig literal is awkward."""
    c = chr(cp)
    if c == "\\":
        return "'\\\\'"
    if c == "'":
        return "'\\''"
    if 0x20 <= cp <= 0x7E:
        return f"'{c}'"
    return f"0x{cp:02X}"


SANS_DEFAULT = 0.55
SERIF_DEFAULT = 0.50


def emit_table(name: str, ratios: dict[int, float], default: float) -> str:
    lines = [
        f"const {name}: [128]f64 = blk: {{",
        "    var t: [128]f64 = undefined;",
        "    var i: usize = 0;",
        f"    while (i < 128) : (i += 1) t[i] = {default:.2f};",
        "    i = 0;",
        "    while (i < 0x20) : (i += 1) t[i] = 0;",
        "    t[0x7F] = 0;",
    ]
    for cp in PRINTABLE:
        lit = _zig_char_literal(cp)
        ratio = ratios.get(cp, default)
        lines.append(f"    t[{lit}] = {ratio:.3f};")
    lines.append("    break :blk t;")
    lines.append("};")
    return "\n".join(lines)


def widths_to_ratios(widths: dict[int, float]) -> dict[int, float]:
    return {cp: w / FONT_SIZE for cp, w in widths.items()}


def emit_all(sans: dict[int, float], serif: dict[int, float], mono_ratio: float) -> str:
    parts = [
        "// Per-character glyph width tables tuned to Chrome's macOS UA fonts.",
        "// Widths are in units of font_size. Bold adds ~6%. Italic does not widen",
        "// (real italic fonts have the same advance widths as upright).",
        "//",
        "// Three families:",
        "//   - sans-serif (Helvetica/Arial-style proportions, default)",
        "//   - serif      (Times-style, slightly narrower lowercase, wider some uppercase)",
        f"//   - monospace  (every char same width, ~{mono_ratio:.2f})",
        "",
        emit_table("FONT_SANS", sans, SANS_DEFAULT),
        "",
        emit_table("FONT_SERIF", serif, SERIF_DEFAULT),
        "",
        f"// Mono ratio (Courier/Menlo advance width / em): {mono_ratio:.4f}",
    ]
    return "\n".join(parts)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--chrome", default=os.environ.get("CHROME", DEFAULT_CHROME))
    p.add_argument("--no-chrome", action="store_true",
                   help="skip Chrome and emit hand-tuned fallback values")
    p.add_argument("--timeout", type=float, default=30.0)
    p.add_argument("--json", action="store_true",
                   help="also print raw measured pixel widths as JSON")
    return p.parse_args()


def main() -> int:
    args = parse_args()

    chrome_path: str | None = args.chrome
    use_chrome = not args.no_chrome
    if use_chrome and (not chrome_path or not Path(chrome_path).exists()):
        # Try $PATH lookup for ``google-chrome``.
        alt = shutil.which("google-chrome") or shutil.which("chromium")
        if alt:
            chrome_path = alt
        else:
            print(
                f"warning: Chrome not found at {chrome_path!r} — "
                "falling back to hand-tuned values",
                file=sys.stderr,
            )
            use_chrome = False

    if use_chrome:
        print(f"calibrating against {chrome_path}", file=sys.stderr)
        sans_widths = measure(
            chrome_path,
            f"{FONT_SIZE}px system-ui, -apple-system, 'Helvetica Neue', Arial, sans-serif",
            args.timeout,
        )
        serif_widths = measure(
            chrome_path,
            f"{FONT_SIZE}px Times, 'Times New Roman', serif",
            args.timeout,
        )
        mono_widths = measure(
            chrome_path,
            f"{FONT_SIZE}px Menlo, Courier, 'Courier New', monospace",
            args.timeout,
        )
        sans = widths_to_ratios(sans_widths)
        serif = widths_to_ratios(serif_widths)
        mono_map = widths_to_ratios(mono_widths)
        # All chars should be the same width; take the median of printable
        # (skip 0x20 which some fonts render at half-width).
        ratios = sorted(mono_map[cp] for cp in PRINTABLE if cp != 0x20)
        mono = ratios[len(ratios) // 2]
        if args.json:
            print(json.dumps({
                "sans_px": sans_widths,
                "serif_px": serif_widths,
                "mono_px": mono_widths,
                "mono_ratio": mono,
            }, indent=2, sort_keys=True))
    else:
        print("using hand-tuned fallback values", file=sys.stderr)
        sans = dict(FALLBACK_SANS)
        serif = dict(FALLBACK_SERIF)
        mono = FALLBACK_MONO

    print(emit_all(sans, serif, mono))
    return 0


if __name__ == "__main__":
    sys.exit(main())
