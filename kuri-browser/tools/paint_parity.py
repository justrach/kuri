#!/usr/bin/env python3
"""Compare kuri-browser native SVG paint against real Chrome pixels.

This intentionally uses only the Python standard library so it can run on a
fresh checkout. It renders the target URL in Chrome, renders kuri-browser's SVG
paint output in Chrome at the same viewport, then computes exact-pixel and RGB
delta metrics.
"""

from __future__ import annotations

import argparse
import math
import os
from pathlib import Path
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import zlib


DEFAULT_CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("url", nargs="?", default="https://example.com")
    parser.add_argument("--kuri-browser", default="./zig-out/bin/kuri-browser")
    parser.add_argument("--chrome", default=os.environ.get("CHROME", DEFAULT_CHROME))
    parser.add_argument("--viewport", default="1280x720")
    parser.add_argument("--timeout", type=float, default=15.0)
    parser.add_argument("--out-dir")
    parser.add_argument("--keep-artifacts", action="store_true")
    parser.add_argument("--direct-svg", action="store_true", help="rasterize the SVG file directly instead of through a no-margin HTML wrapper")
    parser.add_argument("--chrome-virtual-time-ms", type=int, default=0, help="pass --virtual-time-budget to Chrome screenshots for heavy JS pages")
    parser.add_argument("--chrome-user-agent", help="override Chrome's user agent for the reference and SVG-raster screenshots")
    parser.add_argument("--paint-js", action="store_true", help="enable kuri-browser JS execution before native paint")
    parser.add_argument("--paint-wait-selector", help="wait for a selector in the native paint JS runtime")
    parser.add_argument("--paint-wait-eval", help="wait for a JS expression in the native paint JS runtime")
    parser.add_argument("--require-exact", type=float, default=None, help="fail if exact pixel match percent is below this threshold")
    return parser.parse_args()


def parse_viewport(value: str) -> tuple[int, int]:
    parts = value.lower().split("x", 1)
    if len(parts) != 2:
        raise SystemExit(f"invalid viewport {value!r}; expected WIDTHxHEIGHT")
    return int(parts[0]), int(parts[1])


def run_checked(cmd: list[str], timeout: float, expected_file: Path | None = None) -> subprocess.CompletedProcess[str]:
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
        if expected_file is None or not expected_file.exists():
            raise SystemExit(f"command timed out before producing output: {' '.join(cmd)}\n{stderr}")
    if proc.returncode not in (0, -signal.SIGKILL) and (expected_file is None or not expected_file.exists()):
        raise SystemExit(f"command failed: {' '.join(cmd)}\n{stderr}")
    return subprocess.CompletedProcess(cmd, proc.returncode, stdout, stderr)


def chrome_screenshot(
    chrome: Path,
    url: str,
    png_path: Path,
    profile_dir: Path,
    width: int,
    height: int,
    timeout: float,
    virtual_time_ms: int = 0,
    user_agent: str | None = None,
) -> None:
    cmd = [
        str(chrome),
        "--headless=new",
        "--disable-gpu",
        "--hide-scrollbars",
        "--disable-background-networking",
        "--disable-component-update",
        "--no-first-run",
        "--no-default-browser-check",
        f"--user-data-dir={profile_dir}",
        f"--window-size={width},{height}",
        f"--screenshot={png_path}",
    ]
    if virtual_time_ms > 0:
        cmd.append(f"--virtual-time-budget={virtual_time_ms}")
    if user_agent:
        cmd.append(f"--user-agent={user_agent}")
    cmd.append(url)
    run_checked(cmd, timeout, png_path)
    if not png_path.exists() or png_path.stat().st_size == 0:
        raise SystemExit(f"Chrome did not write screenshot: {png_path}")


def svg_background(svg_path: Path) -> str:
    text = svg_path.read_text(errors="replace")
    marker = 'fill="'
    marker_pos = text.find(marker)
    if marker_pos == -1:
        return "#ffffff"
    start = marker_pos + len(marker)
    end = text.find('"', start)
    if end == -1:
        return "#ffffff"
    return text[start:end]


def write_svg_wrapper(svg_path: Path, wrapper_path: Path, width: int, height: int) -> None:
    background = svg_background(svg_path)
    wrapper_path.write_text(
        "<!doctype html>"
        f'<html><body style="margin:0;background:{background}">'
        f'<img src="{svg_path.resolve().as_uri()}" style="display:block;width:{width}px;height:{height}px">'
        "</body></html>"
    )


def read_png(path: Path) -> tuple[int, int, int, list[list[int]]]:
    data = path.read_bytes()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise SystemExit(f"{path}: not a PNG")

    pos = 8
    width = height = bit_depth = color_type = None
    raw = b""
    while pos < len(data):
        length = struct.unpack(">I", data[pos : pos + 4])[0]
        pos += 4
        chunk_type = data[pos : pos + 4]
        pos += 4
        chunk = data[pos : pos + length]
        pos += length + 4
        if chunk_type == b"IHDR":
            width, height, bit_depth, color_type, compression, filter_method, interlace = struct.unpack(">IIBBBBB", chunk)
            if bit_depth != 8 or color_type not in (2, 6) or compression or filter_method or interlace:
                raise SystemExit(f"{path}: unsupported PNG bit={bit_depth} color={color_type} interlace={interlace}")
        elif chunk_type == b"IDAT":
            raw += chunk
        elif chunk_type == b"IEND":
            break

    if width is None or height is None or color_type is None:
        raise SystemExit(f"{path}: missing PNG header")

    channels = 4 if color_type == 6 else 3
    stride = width * channels
    decoded = zlib.decompress(raw)
    rows: list[list[int]] = []
    previous = [0] * stride
    offset = 0

    for _ in range(height):
        filter_type = decoded[offset]
        offset += 1
        scan = list(decoded[offset : offset + stride])
        offset += stride
        row = [0] * stride
        for i, value in enumerate(scan):
            left = row[i - channels] if i >= channels else 0
            up = previous[i]
            upper_left = previous[i - channels] if i >= channels else 0
            if filter_type == 0:
                decoded_value = value
            elif filter_type == 1:
                decoded_value = (value + left) & 0xFF
            elif filter_type == 2:
                decoded_value = (value + up) & 0xFF
            elif filter_type == 3:
                decoded_value = (value + ((left + up) // 2)) & 0xFF
            elif filter_type == 4:
                p = left + up - upper_left
                pa = abs(p - left)
                pb = abs(p - up)
                pc = abs(p - upper_left)
                predictor = left if pa <= pb and pa <= pc else (up if pb <= pc else upper_left)
                decoded_value = (value + predictor) & 0xFF
            else:
                raise SystemExit(f"{path}: unsupported PNG filter {filter_type}")
            row[i] = decoded_value
        rows.append(row)
        previous = row

    return width, height, channels, rows


def compare_pngs(actual_path: Path, native_path: Path) -> dict[str, float | int]:
    actual = read_png(actual_path)
    native = read_png(native_path)
    if actual[:2] != native[:2]:
        raise SystemExit(f"dimension mismatch: actual={actual[0]}x{actual[1]} native={native[0]}x{native[1]}")

    width, height = actual[0], actual[1]
    total = width * height
    exact = 0
    changed = 0
    sum_abs = 0
    sum_squared = 0
    max_delta = 0

    for y in range(height):
        actual_row = actual[3][y]
        native_row = native[3][y]
        for x in range(width):
            actual_i = x * actual[2]
            native_i = x * native[2]
            dr = abs(actual_row[actual_i] - native_row[native_i])
            dg = abs(actual_row[actual_i + 1] - native_row[native_i + 1])
            db = abs(actual_row[actual_i + 2] - native_row[native_i + 2])
            if dr == 0 and dg == 0 and db == 0:
                exact += 1
            else:
                changed += 1
            sum_abs += dr + dg + db
            sum_squared += dr * dr + dg * dg + db * db
            max_delta = max(max_delta, dr, dg, db)

    return {
        "width": width,
        "height": height,
        "total_pixels": total,
        "exact_pixels": exact,
        "exact_percent": exact * 100.0 / total,
        "changed_percent": changed * 100.0 / total,
        "mean_abs_rgb_delta": sum_abs / (total * 3),
        "rms_rgb_delta": math.sqrt(sum_squared / (total * 3)),
        "max_channel_delta": max_delta,
    }


def main() -> int:
    args = parse_args()
    width, height = parse_viewport(args.viewport)
    chrome = Path(args.chrome)
    kuri_browser = Path(args.kuri_browser)
    if not chrome.exists():
        raise SystemExit(f"Chrome binary not found: {chrome}")
    if not kuri_browser.exists():
        raise SystemExit(f"kuri-browser binary not found: {kuri_browser}; run `zig build` first")

    owned_tmp = args.out_dir is None
    out_dir = Path(args.out_dir) if args.out_dir else Path(tempfile.mkdtemp(prefix="kuri-paint-parity."))
    out_dir.mkdir(parents=True, exist_ok=True)
    actual_png = out_dir / "actual-chrome.png"
    native_svg = out_dir / "native-paint.svg"
    native_wrapper = out_dir / "native-paint-wrapper.html"
    native_png = out_dir / "native-paint-rasterized.png"

    try:
        paint_cmd = [str(kuri_browser), "paint", args.url, "--out", str(native_svg)]
        if args.paint_js:
            paint_cmd.append("--js")
        if args.paint_wait_selector:
            paint_cmd.extend(["--wait-selector", args.paint_wait_selector])
        if args.paint_wait_eval:
            paint_cmd.extend(["--wait-eval", args.paint_wait_eval])
        run_checked(paint_cmd, args.timeout, native_svg)
        chrome_screenshot(
            chrome,
            args.url,
            actual_png,
            out_dir / "chrome-actual-profile",
            width,
            height,
            args.timeout,
            args.chrome_virtual_time_ms,
            args.chrome_user_agent,
        )
        native_url = native_svg.resolve().as_uri()
        raster_mode = "direct-svg"
        if not args.direct_svg:
            write_svg_wrapper(native_svg, native_wrapper, width, height)
            native_url = native_wrapper.resolve().as_uri()
            raster_mode = "html-wrapper"
        chrome_screenshot(
            chrome,
            native_url,
            native_png,
            out_dir / "chrome-native-profile",
            width,
            height,
            args.timeout,
            args.chrome_virtual_time_ms,
            args.chrome_user_agent,
        )
        metrics = compare_pngs(actual_png, native_png)

        print("kuri-browser native paint pixel parity")
        print(f"url: {args.url}")
        print(f"viewport: {width}x{height}")
        print(f"native-raster-mode: {raster_mode}")
        print(f"native-js: {'yes' if args.paint_js or args.paint_wait_selector or args.paint_wait_eval else 'no'}")
        print(f"chrome-virtual-time-ms: {args.chrome_virtual_time_ms}")
        print(f"chrome-user-agent: {'custom' if args.chrome_user_agent else 'default'}")
        print(f"artifacts: {out_dir}")
        print(f"actual-png-bytes: {actual_png.stat().st_size}")
        print(f"native-svg-bytes: {native_svg.stat().st_size}")
        print(f"native-rasterized-png-bytes: {native_png.stat().st_size}")
        print(f"exact-pixels: {metrics['exact_pixels']}/{metrics['total_pixels']} ({metrics['exact_percent']:.2f}%)")
        print(f"changed-pixels: {metrics['changed_percent']:.2f}%")
        print(f"mean-abs-rgb-delta: {metrics['mean_abs_rgb_delta']:.2f}/255")
        print(f"rms-rgb-delta: {metrics['rms_rgb_delta']:.2f}/255")
        print(f"max-channel-delta: {metrics['max_channel_delta']}/255")

        if args.require_exact is not None and metrics["exact_percent"] < args.require_exact:
            print(f"verdict: fail, below required exact-pixel threshold {args.require_exact:.2f}%")
            return 1
        print("verdict: measured, not a 1:1 renderer unless exact-pixel threshold is explicitly met")
        return 0
    finally:
        if owned_tmp and not args.keep_artifacts:
            shutil.rmtree(out_dir, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
