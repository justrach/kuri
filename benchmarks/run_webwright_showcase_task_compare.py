#!/usr/bin/env python3
"""Compare Kuri and Webwright-style Playwright on one Webwright showcase task.

This runner is intentionally deterministic: it does not call an LLM and does
not reproduce Webwright's full agent loop. It exercises the browser substrate on
the same live pages and scores whether task-critical facts are extractable.
"""

from __future__ import annotations

import argparse
import asyncio
import importlib.metadata as metadata
import json
import os
import re
import socket
import subprocess
import sys
import time
import urllib.request
from datetime import datetime
from pathlib import Path
from typing import Any

from playwright.async_api import async_playwright


WEBWRIGHT_REF = "1236f4d31186610d23badd997917f86712fe8bed"

DRIVING_WEATHER_SOURCES = [
    ("google_baltimore", "https://www.google.com/search?q=Baltimore+Maryland+weather&hl=en"),
    ("wunderground_syracuse", "https://www.wunderground.com/forecast/us/ny/syracuse"),
    ("nws_rittman", "https://forecast.weather.gov/MapClick.php?lat=40.978&lon=-81.7818"),
    ("nws_phi", "https://www.weather.gov/phi/"),
]

SLICKDEALS_SOURCES = [
    ("slickdeals_home", "https://slickdeals.net/"),
    ("cheapcharts_movie", "https://www.cheapcharts.com/us/itunes/movies/on-sale"),
    ("cheapcharts_tv", "https://www.cheapcharts.com/us/itunes/seasons/on-sale"),
    ("cheapcharts_audiobook", "https://www.cheapcharts.com/us/itunes/audiobooks/on-sale"),
    ("epic_home", "https://store.epicgames.com/en-US/"),
    ("epic_split_fiction", "https://store.epicgames.com/en-US/p/split-fiction"),
]

POKEMON_TCG_SOURCES = [
    ("bestbuy_pokemon", "https://www.bestbuy.com/site/searchpage.jsp?st=pokemon+trading+card&intl=nosplash"),
    ("barnesandnoble_pokemon", "https://www.barnesandnoble.com/s/pokemon+trading+card"),
    ("walmart_pokemon", "https://www.walmart.com/search?q=pokemon+trading+card"),
]

TASK_SOURCES = {
    "driving_weather": DRIVING_WEATHER_SOURCES,
    "slickdeals": SLICKDEALS_SOURCES,
    "pokemon_tcg": POKEMON_TCG_SOURCES,
}

TASK_META = {
    "driving_weather": {
        "task_id": "b6b8ad71aa3112840790066d7d62b498babdfa5c",
        "title": "This-week driving weather snapshot",
        "critical_points": [
            "Baltimore current temperature and condition from Google weather search",
            "Syracuse lowest temperature in next 7 days from Wunderground",
            "Rittman/Marshallville current forecast and active-alert status from NWS forecast page",
            "Mount Holly winter forecast graphic snowfall amount from NWS Mount Holly page",
        ],
    },
    "slickdeals": {
        "task_id": "0106b570440ffe4427d5e916f39ec986ab3de917",
        "title": "Slickdeals featured deal + CheapCharts iTunes picks",
        "critical_points": [
            "Slickdeals front-page featured/best deal title and price",
            "CheapCharts on-sale movie title and price",
            "CheapCharts on-sale TV season title and price",
            "CheapCharts on-sale audiobook title and price",
            "Epic Games Store homepage reached",
            "Split Fiction Epic product page reached",
        ],
    },
    "pokemon_tcg": {
        "task_id": "c6b29e8564a7ae86dc50a1f074bdc2b5abb3754a",
        "title": "Pokemon TCG availability sweep",
        "critical_points": [
            "Best Buy Pokemon trading-card search reached with product/price signal",
            "Best Buy shows at least two Pokemon card products",
            "Barnes & Noble Pokemon item reached with price/in-stock signal",
            "Walmart Pokemon item reached with Walmart-shipped or buyable signal",
        ],
    },
}


def run(args: list[str | Path], timeout: int = 45) -> dict[str, Any]:
    started = time.perf_counter()
    proc = subprocess.run(
        [str(arg) for arg in args],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=timeout,
    )
    return {
        "args": [str(arg) for arg in args],
        "returncode": proc.returncode,
        "stdout": proc.stdout,
        "elapsed_ms": int((time.perf_counter() - started) * 1000),
    }


def command_output(args: list[str], default: str = "") -> str:
    try:
        return subprocess.run(args, text=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=5).stdout.strip()
    except Exception:
        return default


def wait_json(port: int, path: str = "/json", timeout: float = 15.0) -> Any:
    deadline = time.time() + timeout
    url = f"http://127.0.0.1:{port}{path}"
    last_error: Exception | None = None
    while time.time() < deadline:
        try:
            with urllib.request.urlopen(url, timeout=1) as response:
                return json.loads(response.read().decode())
        except Exception as exc:
            last_error = exc
            time.sleep(0.25)
    raise RuntimeError(f"timed out waiting for {url}: {last_error}")


def free_port(start: int = 9333) -> int:
    for port in range(start, start + 100):
        with socket.socket() as sock:
            try:
                sock.bind(("127.0.0.1", port))
                return port
            except OSError:
                continue
    raise RuntimeError("no free local CDP port found")


def cache_bust(url: str, stamp: int) -> str:
    separator = "&" if "?" in url else "?"
    return f"{url}{separator}kuri_task_bench={stamp}"


def count_tokens(text: str) -> int | None:
    try:
        import tiktoken

        return len(tiktoken.get_encoding("cl100k_base").encode(text))
    except Exception:
        return None


def first_match(pattern: str, text: str, flags: int = 0) -> str | None:
    match = re.search(pattern, text, flags)
    return match.group(1).strip() if match else None


def parse_driving_weather(name: str, text: str) -> dict[str, Any]:
    result: dict[str, Any] = {"name": name, "status": "unknown", "fields": {}, "evidence": []}
    lower = text.lower()
    if "unusual traffic" in lower or "security check" in lower or "performing security verification" in lower:
        result["status"] = "blocked"
        result["evidence"].append("bot/security interstitial detected")
        return result

    if name == "google_baltimore":
        temp = first_match(r"(-?\d{1,3})\s*°\s*F", text) or first_match(r"(-?\d{1,3})\s*°", text)
        condition = None
        for word in ["Partly sunny", "Partly cloudy", "Sunny", "Cloudy", "Rain", "Showers", "Fair", "Clear", "Fog"]:
            if word.lower() in lower:
                condition = word
                break
        result["fields"] = {"temperature_f": temp, "condition": condition}
        result["status"] = "success" if temp and condition else "missing"
        result["evidence"].append(text[:500])
        return result

    if name == "wunderground_syracuse":
        labels = re.findall(r"(?:Mon|Tue|Wed|Thu|Fri|Sat|Sun)\s+\d{1,2}/\d{1,2}", text)
        temps = re.findall(r"(\d{1,3})°\s*\|\s*(\d{1,3})°?F", text)
        pairs = []
        for index, (high, low) in enumerate(temps[:7]):
            pairs.append({
                "day": labels[index] if index < len(labels) else f"day_{index + 1}",
                "high_f": int(high),
                "low_f": int(low),
            })
        if pairs:
            low = min(pairs, key=lambda pair: pair["low_f"])
            result["fields"] = {
                "lowest_next_7_days_f": low["low_f"],
                "day": low["day"],
                "daily_pairs": pairs,
            }
            result["status"] = "success"
        else:
            result["status"] = "missing"
            result["evidence"].append(text[:800])
        return result

    if name == "nws_rittman":
        current = first_match(r"Current conditions at\n(.*?)\n\nMore Information", text, re.S)
        detailed = first_match(r"Detailed Forecast\n(.*?)\nAdditional Forecasts", text, re.S)
        active_alert = None
        for phrase in [
            "Dense Fog Advisory",
            "Hazardous Weather Outlook",
            "Winter Storm Warning",
            "Flood Watch",
            "Severe Thunderstorm Warning",
        ]:
            if phrase.lower() in lower:
                active_alert = phrase
                break
        result["fields"] = {
            "current_conditions": current,
            "detailed_forecast_start": detailed[:500] if detailed else None,
            "active_alert_seen": active_alert or "none visible on page",
        }
        result["status"] = "success" if current or detailed else "missing"
        return result

    if name == "nws_phi":
        snow_lines = [line.strip() for line in text.splitlines() if "snow" in line.lower() or "winter" in line.lower()]
        amount = first_match(r"(\d+(?:\.\d+)?)\s*(?:in|inch|inches|\")", "\n".join(snow_lines), re.I)
        result["fields"] = {"snow_or_winter_lines": snow_lines[:20], "snowfall_amount_in": amount}
        result["status"] = "success" if amount else ("missing_seasonal_graphic" if not snow_lines else "missing_amount")
        return result

    return result


def blocked(text: str) -> bool:
    lower = text.lower()
    return (
        "unusual traffic" in lower
        or "security check" in lower
        or "performing security verification" in lower
        or "just a moment" in lower
        or "verify you are human" in lower
        or "access denied" in lower
    )


def money_values(text: str) -> list[str]:
    return re.findall(r"\$\s?\d+(?:\.\d{2})?", text)


def parse_storefront(name: str, text: str) -> dict[str, Any]:
    result: dict[str, Any] = {"name": name, "status": "unknown", "fields": {}, "evidence": []}
    lower = text.lower()
    if blocked(text):
        result["status"] = "blocked"
        result["evidence"].append("bot/security interstitial detected")
        return result

    prices = money_values(text)
    result["fields"] = {
        "prices_seen": prices[:10],
        "title_or_heading": next((line.strip() for line in text.splitlines() if line.strip()), ""),
    }

    if name == "slickdeals_home":
        deal_signal = bool(prices) and any(word in lower for word in ["deal", "off", "save", "coupon", "featured"])
        result["status"] = "success" if deal_signal else "missing"
    elif name.startswith("cheapcharts_"):
        category_words = {
            "cheapcharts_movie": ["movie", "movies"],
            "cheapcharts_tv": ["season", "tv"],
            "cheapcharts_audiobook": ["audiobook", "audiobooks"],
        }[name]
        category_signal = any(word in lower for word in category_words)
        result["status"] = "success" if prices and category_signal else "missing"
    elif name.startswith("epic_"):
        epic_signal = "epic games" in lower or "epic" in lower
        if name == "epic_split_fiction":
            epic_signal = epic_signal and "split fiction" in lower
        result["status"] = "success" if epic_signal else "missing"
    elif name == "bestbuy_pokemon":
        add_to_cart_count = lower.count("add to cart")
        product_count = lower.count("pokémon -") + lower.count("pokemon -")
        pokemon_signal = "pokemon" in lower or "pokémon" in lower
        result["fields"]["product_count"] = product_count
        result["fields"]["add_to_cart_count"] = add_to_cart_count
        result["status"] = "success" if pokemon_signal and (prices or product_count >= 1) else "missing"
    elif name == "barnesandnoble_pokemon":
        bn_signal = ("pokemon" in lower or "pokémon" in lower) and (prices or "in stock" in lower or "available" in lower)
        result["status"] = "success" if bn_signal else "missing"
    elif name == "walmart_pokemon":
        walmart_signal = ("pokemon" in lower or "pokémon" in lower) and (
            "sold and shipped by walmart" in lower
            or "sold & shipped by walmart" in lower
            or "add to cart" in lower
            or prices
        )
        result["status"] = "success" if walmart_signal else "missing"
    else:
        result["status"] = "success" if text.strip() else "missing"

    result["evidence"].append(text[:1000])
    return result


def parse_task(task: str, name: str, text: str) -> dict[str, Any]:
    if task == "driving_weather":
        return parse_driving_weather(name, text)
    return parse_storefront(name, text)


def score(task: str, parsed: dict[str, dict[str, Any]]) -> dict[str, Any]:
    statuses = {name: item["status"] for name, item in parsed.items()}
    if task == "pokemon_tcg":
        bestbuy = parsed.get("bestbuy_pokemon", {})
        add_to_cart_count = int(bestbuy.get("fields", {}).get("add_to_cart_count", 0) or 0)
        product_count = int(bestbuy.get("fields", {}).get("product_count", 0) or 0)
        points = 0
        points += 1 if statuses.get("bestbuy_pokemon") == "success" else 0
        points += 1 if product_count >= 2 or add_to_cart_count >= 2 else 0
        points += 1 if statuses.get("barnesandnoble_pokemon") == "success" else 0
        points += 1 if statuses.get("walmart_pokemon") == "success" else 0
        statuses["bestbuy_two_items"] = "success" if product_count >= 2 or add_to_cart_count >= 2 else "missing"
        return {"points": points, "total": 4, "statuses": statuses}
    points = sum(1 for status in statuses.values() if status == "success")
    return {"points": points, "total": len(parsed), "statuses": statuses}


def machine_os() -> str:
    if sys.platform == "darwin":
        return command_output(["sw_vers"]).replace("\n", "; ")
    return command_output(["uname", "-srm"], "unknown")


def version(package_name: str) -> str:
    try:
        return metadata.version(package_name)
    except Exception:
        return ""


def run_kuri(
    root: Path,
    raw_dir: Path,
    task: str,
    sources: list[tuple[str, str]],
    chrome_bin: str,
    stamp: int,
    settle_seconds: float,
) -> dict[str, Any]:
    kuri_bin = Path(os.environ.get("KURI_AGENT_BIN", root / "zig-out/bin/kuri-agent"))
    if not kuri_bin.exists():
        raise RuntimeError(f"kuri-agent binary not found at {kuri_bin}")

    port = free_port(int(os.environ.get("KURI_TASK_PORT", "9333")))
    profile = raw_dir.parent / "kuri-chrome-profile"
    chrome_args = [
        chrome_bin,
        "--headless=new",
        "--disable-gpu",
        f"--remote-debugging-port={port}",
        "--remote-debugging-address=127.0.0.1",
        f"--user-data-dir={profile}",
        "--no-first-run",
        "--no-default-browser-check",
        "about:blank",
    ]
    chrome = subprocess.Popen(chrome_args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    commands: list[dict[str, Any]] = []
    pages: dict[str, dict[str, Any]] = {}
    try:
        tabs = wait_json(port, "/json")
        ws = next(tab["webSocketDebuggerUrl"] for tab in tabs if tab.get("type") == "page" and tab.get("webSocketDebuggerUrl"))
        commands.append(run([kuri_bin, "use", ws]))
        commands.append(run([kuri_bin, "viewport", "1280", "1800"]))
        for name, url in sources:
            target = cache_bust(url, stamp)
            go = run([kuri_bin, "go", target], timeout=60)
            time.sleep(settle_seconds)
            title = run([kuri_bin, "eval", "document.title"], timeout=20)
            text = run([kuri_bin, "text"], timeout=30)
            screenshot = raw_dir / f"kuri_{name}.png"
            shot = run([kuri_bin, "shot", "--out", screenshot], timeout=30)
            commands.extend([go, title, text, shot])
            (raw_dir / f"kuri_{name}.txt").write_text(text["stdout"], errors="replace")
            pages[name] = {
                "url": target,
                "title": title["stdout"].strip(),
                "tokens": count_tokens(text["stdout"]),
                "screenshot": str(screenshot),
                "text": text["stdout"],
            }
    finally:
        chrome.terminate()
        try:
            chrome.wait(timeout=5)
        except subprocess.TimeoutExpired:
            chrome.kill()

    parsed = {name: parse_task(task, name, page["text"]) for name, page in pages.items()}
    return {
        "score": score(task, parsed),
        "pages": {name: {key: value for key, value in page.items() if key != "text"} for name, page in pages.items()},
        "parsed": parsed,
        "command_count": len(commands),
        "commands": commands,
    }


async def run_webwright_playwright(
    raw_dir: Path,
    task: str,
    sources: list[tuple[str, str]],
    chrome_bin: str,
    stamp: int,
    settle_seconds: float,
) -> dict[str, Any]:
    pages: dict[str, dict[str, Any]] = {}
    commands: list[dict[str, Any]] = []
    started_all = time.perf_counter()
    async with async_playwright() as playwright:
        browser = await playwright.chromium.launch(headless=True, executable_path=chrome_bin)
        context = await browser.new_context(viewport={"width": 1280, "height": 1800})
        page = await context.new_page()
        for name, url in sources:
            target = cache_bust(url, stamp)
            started = time.perf_counter()
            error = None
            text = ""
            title = ""
            try:
                await page.goto(target, wait_until="domcontentloaded", timeout=60_000)
                try:
                    await page.wait_for_load_state("networkidle", timeout=5_000)
                except Exception:
                    pass
                await page.wait_for_timeout(int(settle_seconds * 1000))
                title = await page.title()
                text = await page.locator("body").inner_text(timeout=10_000)
                await page.screenshot(path=str(raw_dir / f"webwright_{name}.png"))
            except Exception as exc:
                error = f"{type(exc).__name__}: {exc}"
            elapsed_ms = int((time.perf_counter() - started) * 1000)
            commands.append({"action": "goto+inner_text+screenshot", "name": name, "url": target, "elapsed_ms": elapsed_ms, "error": error})
            (raw_dir / f"webwright_{name}.txt").write_text(text, errors="replace")
            pages[name] = {
                "url": target,
                "title": title,
                "tokens": count_tokens(text),
                "screenshot": str(raw_dir / f"webwright_{name}.png"),
                "error": error,
                "text": text,
            }
        await context.close()
        await browser.close()

    parsed = {name: parse_task(task, name, page["text"]) for name, page in pages.items()}
    return {
        "score": score(task, parsed),
        "pages": {name: {key: value for key, value in page.items() if key != "text"} for name, page in pages.items()},
        "parsed": parsed,
        "command_count": len(commands),
        "commands": commands,
        "elapsed_ms": int((time.perf_counter() - started_all) * 1000),
    }


def extracted_result(name: str, parsed: dict[str, Any]) -> str:
    fields = parsed.get("fields", {})
    if name == "google_baltimore":
        return f"{fields.get('temperature_f')} F, {fields.get('condition')}" if fields else ""
    if name == "wunderground_syracuse":
        return f"{fields.get('lowest_next_7_days_f')} F on {fields.get('day')}" if fields else ""
    if name == "nws_rittman":
        return fields.get("active_alert_seen", "") if fields else ""
    if name == "nws_phi":
        return fields.get("snowfall_amount_in") or "; ".join(fields.get("snow_or_winter_lines", [])[:3])
    if name == "bestbuy_pokemon":
        return f"prices={fields.get('prices_seen', [])[:3]}, products={fields.get('product_count', 0)}, add_to_cart_count={fields.get('add_to_cart_count', 0)}"
    if name.startswith("cheapcharts_") or name in {"slickdeals_home", "barnesandnoble_pokemon", "walmart_pokemon"}:
        return f"prices={fields.get('prices_seen', [])[:5]}"
    if name.startswith("epic_"):
        return fields.get("title_or_heading", "")
    return ""


def result_table(task: str, tool: dict[str, Any], title: str) -> str:
    common_labels = {
        "google_baltimore": "Baltimore Google weather",
        "wunderground_syracuse": "Syracuse Wunderground low",
        "nws_rittman": "Rittman NWS forecast/alerts",
        "nws_phi": "Mount Holly winter/snowfall",
        "slickdeals_home": "Slickdeals featured deal",
        "cheapcharts_movie": "CheapCharts movie",
        "cheapcharts_tv": "CheapCharts TV season",
        "cheapcharts_audiobook": "CheapCharts audiobook",
        "epic_home": "Epic Games homepage",
        "epic_split_fiction": "Split Fiction product page",
        "bestbuy_pokemon": "Best Buy Pokemon search",
        "barnesandnoble_pokemon": "Barnes & Noble Pokemon search",
        "walmart_pokemon": "Walmart Pokemon search",
        "bestbuy_two_items": "Best Buy two product listings",
    }
    lines = [
        f"### {title}",
        "",
        f"Score: **{tool['score']['points']}/{tool['score']['total']}** critical points",
        "",
        "| Critical point | Status | Extracted result |",
        "|---|---|---|",
    ]
    rows = [(name, parsed["status"], extracted_result(name, parsed)) for name, parsed in tool["parsed"].items()]
    if task == "pokemon_tcg":
        rows.insert(1, ("bestbuy_two_items", tool["score"]["statuses"].get("bestbuy_two_items", "missing"), ""))
    for name, status, result in rows:
        lines.append(f"| {common_labels[name]} | `{status}` | {result.replace('|', '/')} |")
    return "\n".join(lines)


def write_reports(out_dir: Path, task: str, summary: dict[str, Any]) -> None:
    (out_dir / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    lines = [
        f"# Webwright Showcase Task Compare: {task}",
        "",
        f"- Date: `{summary['date']}`",
        f"- Task source: `{summary['task_source']}`",
        f"- Webwright ref: `{summary['task_ref']}`",
        f"- Kuri branch/commit: `{summary['kuri_branch']} {summary['kuri_commit']}`",
        f"- Machine/OS: `{summary['machine_os']}`",
        f"- Zig: `{summary['zig_version']}`",
        f"- Chrome: `{summary['chrome_version']}`",
        f"- Webwright/Playwright: `webwright {summary['webwright_version']}, playwright {summary['playwright_version']}`",
        f"- Run mode: `{summary['run_mode']}`",
        f"- Settle wait: `{summary['settle_seconds']}s after each navigation`",
        f"- Cache disclosure: `{summary['cache_state']}`",
        "",
        "## Results",
        "",
        result_table(task, summary["kuri"], "Kuri/CDP"),
        "",
        result_table(task, summary["webwright_playwright"], "Webwright-Style Playwright"),
        "",
        "## Interpretation",
        "",
        "- Live site blocking and missing seasonal/dynamic content are counted as task failures.",
        "- Success here means the deterministic script extracted the required visible signal; it does not judge answer quality from an LLM agent.",
        "- This run compares browser substrate behavior, not LLM planning quality or Webwright published task-success results.",
        "",
        "## Artifacts",
        "",
        "- Raw text and screenshots: [`raw/`](./raw)",
        "- Machine summary: [`summary.json`](./summary.json)",
    ]
    (out_dir / "summary.md").write_text("\n".join(lines) + "\n")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("task", choices=sorted(TASK_SOURCES))
    parser.add_argument("--results-root", default=os.environ.get("RESULTS_ROOT"))
    parser.add_argument("--settle-seconds", type=float, default=float(os.environ.get("TASK_SETTLE_SECONDS", "5")))
    args = parser.parse_args()

    root = Path(__file__).resolve().parents[1]
    results_root = Path(args.results_root) if args.results_root else root / ".benchmarks/results"
    out_dir = results_root / f"webwright-task-{args.task}-{datetime.now().strftime('%Y%m%d-%H%M%S')}"
    raw_dir = out_dir / "raw"
    raw_dir.mkdir(parents=True, exist_ok=True)

    chrome_bin = os.environ.get("CHROME_BIN") or "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
    stamp = int(time.time() * 1000)
    sources = TASK_SOURCES[args.task]
    meta = TASK_META[args.task]

    kuri = run_kuri(root, raw_dir, args.task, sources, chrome_bin, stamp, args.settle_seconds)
    webwright_playwright = asyncio.run(run_webwright_playwright(raw_dir, args.task, sources, chrome_bin, stamp, args.settle_seconds))

    summary = {
        "date": datetime.now().date().isoformat(),
        "task_source": f"microsoft/Webwright assets/task_showcase/tasks/{args.task}/task.json",
        "task_ref": os.environ.get("WEBWRIGHT_REF", WEBWRIGHT_REF),
        "task_id": meta["task_id"],
        "task_short_id": args.task,
        "task_title": meta["title"],
        "run_mode": "live single-run deterministic task extraction; no LLM calls; sample_size=1; warmups=0; fresh browser/profile per tool; cache-busted top-level URLs",
        "settle_seconds": args.settle_seconds,
        "machine_os": machine_os(),
        "zig_version": command_output(["zig", "version"]),
        "chrome_version": command_output([chrome_bin, "--version"]),
        "webwright_version": version("webwright"),
        "playwright_version": version("playwright"),
        "kuri_commit": command_output(["git", "-C", str(root), "rev-parse", "--short", "HEAD"]),
        "kuri_branch": command_output(["git", "-C", str(root), "branch", "--show-current"]),
        "cache_state": "fresh Kuri Chrome profile and fresh Playwright context; top-level URLs appended with kuri_task_bench timestamp; remote site/CDN/server-side cache unknown",
        "critical_points": meta["critical_points"],
        "kuri": kuri,
        "webwright_playwright": webwright_playwright,
        "notes": [
            "This compares Kuri/CDP and a Webwright-style Playwright script on one Webwright showcase task; it is not a Webwright LLM agent-loop reproduction.",
            "Live site blocking and seasonal page content are counted as task failures.",
        ],
    }
    write_reports(out_dir, args.task, summary)
    print(out_dir)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
