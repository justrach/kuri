#!/usr/bin/env python3
"""Capture the Playwright observation shape used by Webwright-style scripts.

This is intentionally not the full Webwright agent loop. It measures the
Playwright page observation that Webwright prompts agents to inspect while
writing browser scripts, so benchmark reports can compare observation payload
size without spending model tokens or claiming task-success parity.
"""

from __future__ import annotations

import argparse
import asyncio
import os
import platform
import sys
import time


async def capture(url: str, timeout_ms: int) -> int:
    try:
        from playwright.async_api import async_playwright
    except Exception as exc:  # pragma: no cover - exercised by shell runner.
        print(f"playwright unavailable: {exc}")
        return 2

    viewport = {"width": 1280, "height": 1800}
    chrome_bin = os.environ.get("CHROME_BIN") or None
    launch_args: list[str] = []
    if platform.system() == "Linux":
        launch_args.extend(["--no-sandbox", "--disable-dev-shm-usage"])

    started = time.perf_counter()
    async with async_playwright() as playwright:
        browser = await playwright.chromium.launch(
            headless=True,
            executable_path=chrome_bin,
            args=launch_args,
        )
        context = await browser.new_context(viewport=viewport)
        page = await context.new_page()
        try:
            await page.goto(url, wait_until="domcontentloaded", timeout=timeout_ms)
            # Keep this bounded; live pages can keep long-polling forever.
            try:
                await page.wait_for_load_state("networkidle", timeout=3_000)
            except Exception:
                pass

            body = page.locator("body")
            try:
                observation = await body.aria_snapshot(timeout=5_000)
                observation_kind = "aria_snapshot"
            except Exception as exc:
                observation = await body.inner_text(timeout=5_000)
                observation_kind = f"inner_text fallback ({type(exc).__name__})"

            elapsed_ms = int((time.perf_counter() - started) * 1000)
            print("webwright_playwright_observation")
            print(f"url: {page.url}")
            print(f"title: {await page.title()}")
            print(f"observation: {observation_kind}")
            print(f"viewport: {viewport['width']}x{viewport['height']}")
            print(f"elapsed_ms: {elapsed_ms}")
            print(
                "scope: Playwright observation baseline only; "
                "not the Webwright LLM agent loop or task-success score"
            )
            print("---")
            print(observation)
        finally:
            await context.close()
            await browser.close()

    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("url")
    parser.add_argument("--timeout-ms", type=int, default=30_000)
    args = parser.parse_args()
    return asyncio.run(capture(args.url, args.timeout_ms))


if __name__ == "__main__":
    raise SystemExit(main())
