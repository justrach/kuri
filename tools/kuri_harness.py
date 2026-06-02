#!/usr/bin/env python3
"""Experimental Browser-Harness-style wrapper for Kuri.

This is intentionally thin. It keeps Kuri's existing HTTP API and eN-ref model,
but makes quick iterative scripting easier by preloading helpers into a Python
stdin session.

Usage:

  python3 tools/kuri_harness.py <<'PY'
  ensure_tab()
  goto("https://news.ycombinator.com")
  nodes = snap(interactive=True)
  print(nodes[:5])
  PY
"""

from __future__ import annotations

import base64
import json
import os
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any


BASE_URL = os.environ.get("KURI_BASE_URL", "http://127.0.0.1:8080")
SESSION_PATH = Path(os.environ.get("KURI_HARNESS_SESSION", "~/.kuri/harness_session.json")).expanduser()
SESSION_ID = os.environ.get("KURI_SESSION_ID", "kuri-harness")


class KuriHarnessError(RuntimeError):
    pass


def _load_session() -> dict[str, Any]:
    try:
        return json.loads(SESSION_PATH.read_text())
    except FileNotFoundError:
        return {}
    except json.JSONDecodeError:
        return {}


def _save_session(session: dict[str, Any]) -> None:
    SESSION_PATH.parent.mkdir(parents=True, exist_ok=True)
    SESSION_PATH.write_text(json.dumps(session, indent=2) + "\n")


_SESSION = _load_session()


def _request(path: str, **params: Any) -> Any:
    query: list[tuple[str, str]] = []
    for key, value in params.items():
        if value is None:
            continue
        if isinstance(value, bool):
            query.append((key, "true" if value else "false"))
        else:
            query.append((key, str(value)))

    url = f"{BASE_URL}{path}"
    if query:
        url += "?" + urllib.parse.urlencode(query)
    request = urllib.request.Request(url, headers={"X-Kuri-Session": SESSION_ID})

    try:
        with urllib.request.urlopen(request, timeout=30) as resp:
            body = resp.read().decode("utf-8", errors="replace")
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        raise KuriHarnessError(f"{exc.code} {exc.reason}: {body}") from exc
    except urllib.error.URLError as exc:
        raise KuriHarnessError(f"request failed for {url}: {exc}") from exc

    try:
        return json.loads(body)
    except json.JSONDecodeError:
        return body


def health() -> dict[str, Any]:
    return _request("/health")


def tabs() -> list[dict[str, Any]]:
    return _request("/tabs")


def discover() -> dict[str, Any]:
    return _request("/discover")


def api(path: str, **params: Any) -> Any:
    if not path.startswith("/"):
        path = "/" + path
    return _request(path, **params)


def _find_tab(tab_id: str) -> dict[str, Any] | None:
    for tab in tabs():
        if tab.get("id") == tab_id:
            return tab
    return None


def _clear_current_tab() -> None:
    if "tab_id" not in _SESSION:
        return
    _SESSION.pop("tab_id", None)
    _save_session(_SESSION)


def _require_tab_id(tab_id: str | None = None) -> str:
    tid = tab_id or current_tab_id()
    if not tid:
        raise KuriHarnessError("no current tab; call ensure_tab() or use(tab_id)")
    return tid


def _wait_for_tab(tab_id: str, timeout: float = 5.0, interval: float = 0.25) -> dict[str, Any] | None:
    def _probe() -> dict[str, Any] | None:
        tab = _find_tab(tab_id)
        if tab:
            return tab
        try:
            discover()
        except KuriHarnessError:
            return None
        return _find_tab(tab_id)

    return wait_for(_probe, timeout=timeout, interval=interval)


def _created_tab_id(payload: dict[str, Any]) -> str | None:
    tab_id = payload.get("tab_id")
    if isinstance(tab_id, str) and tab_id:
        return tab_id
    result = payload.get("result")
    if isinstance(result, dict):
        target_id = result.get("targetId")
        if isinstance(target_id, str) and target_id:
            return target_id
    return None


def use(tab_id: str) -> str:
    api("/tab/current", tab_id=tab_id)
    _SESSION["tab_id"] = tab_id
    _save_session(_SESSION)
    return tab_id


def current_tab_id() -> str | None:
    tab_id = _SESSION.get("tab_id")
    if tab_id:
        return tab_id
    try:
        payload = api("/tab/current")
    except KuriHarnessError:
        return None
    tab_id = payload.get("tab_id") if isinstance(payload, dict) else None
    if isinstance(tab_id, str) and tab_id:
        _SESSION["tab_id"] = tab_id
        _save_session(_SESSION)
        return tab_id
    return None


def current_tab() -> dict[str, Any] | None:
    tab_id = current_tab_id()
    if not tab_id:
        return None
    tab = _find_tab(tab_id)
    if tab is None:
        try:
            discover()
        except KuriHarnessError:
            pass
        tab = _find_tab(tab_id)
    if tab is None:
        _clear_current_tab()
        return None
    try:
        info = page_info(tab_id=tab_id)
        return {
            **tab,
            "url": info.get("url", tab.get("url", "")),
            "title": info.get("title", tab.get("title", "")),
        }
    except Exception:
        return tab
    return None


def ensure_tab(url: str = "about:blank") -> dict[str, Any]:
    existing = current_tab()
    if existing:
        return existing

    all_tabs = tabs()
    if not all_tabs:
        try:
            discover()
        except KuriHarnessError:
            pass
        all_tabs = tabs()
    if all_tabs:
        use(all_tabs[0]["id"])
        return current_tab() or all_tabs[0]

    created = new_tab(url)
    tab_id = created["tab_id"]
    refreshed = current_tab() or _wait_for_tab(tab_id)
    return refreshed or {"id": tab_id, "url": created.get("url", url), "title": created.get("title", "")}


def new_tab(
    url: str = "about:blank",
    switch: bool = True,
    wait_ready: bool = True,
    timeout: float = 5.0,
    interval: float = 0.25,
) -> dict[str, Any]:
    created = api("/tab/new", url=url)
    tab_id = _created_tab_id(created)
    if not tab_id:
        return created
    ready = _wait_for_tab(tab_id, timeout=timeout, interval=interval) if wait_ready else None
    if switch:
        use(tab_id)
    if ready:
        return {**created, **ready, "tab_id": tab_id}
    return created


def new_window(
    url: str = "about:blank",
    switch: bool = True,
    wait_ready: bool = True,
    timeout: float = 5.0,
    interval: float = 0.25,
) -> dict[str, Any]:
    created = api("/window/new", url=url)
    tab_id = _created_tab_id(created)
    if not tab_id:
        return created
    ready = _wait_for_tab(tab_id, timeout=timeout, interval=interval) if wait_ready else None
    if switch:
        use(tab_id)
    if ready:
        return {**created, **ready, "tab_id": tab_id}
    return created


def close_tab(tab_id: str | None = None) -> Any:
    tid = _require_tab_id(tab_id)
    result = api("/tab/close", tab_id=tid)
    if tid == current_tab_id():
        _clear_current_tab()
    return result


def goto(url: str, tab_id: str | None = None) -> Any:
    tid = tab_id or current_tab_id()
    if not tid:
        tid = ensure_tab()["id"]
    result = api("/navigate", tab_id=tid, url=url)
    use(tid)
    return result


def page_info(tab_id: str | None = None) -> dict[str, Any]:
    tid = tab_id or current_tab_id()
    payload = api("/page/info", tab_id=tid)
    if isinstance(payload, dict):
        return payload
    raise KuriHarnessError(f"unexpected page_info payload: {payload!r}")


def text(selector: str | None = None, tab_id: str | None = None) -> str:
    result = api("/text", tab_id=tab_id or current_tab_id(), selector=selector)
    if isinstance(result, dict):
        return result.get("result", {}).get("result", {}).get("value", "")
    return str(result)


def eval_js(expression: str, tab_id: str | None = None) -> Any:
    result = api("/evaluate", tab_id=tab_id or current_tab_id(), expression=expression)
    if isinstance(result, dict):
        inner = result.get("result", {}).get("result", {})
        if "value" in inner:
            return inner["value"]
    return result


def snap(*, interactive: bool = False, text_format: bool = False, depth: int | None = None, tab_id: str | None = None) -> Any:
    return api(
        "/snapshot",
        tab_id=tab_id or current_tab_id(),
        filter="interactive" if interactive else None,
        format="text" if text_format else None,
        depth=depth,
    )


def action(name: str, ref: str | None = None, value: str | None = None, *, tab_id: str | None = None) -> Any:
    tid = tab_id or current_tab_id()
    if ref is None and name not in {"press", "scroll"}:
        raise KuriHarnessError(f"action {name!r} requires ref")
    return api("/action", tab_id=tid, action=name, ref=ref, value=value)


def click(ref: str, *, tab_id: str | None = None) -> Any:
    return action("click", ref=ref, tab_id=tab_id)


def dblclick(ref: str, *, tab_id: str | None = None) -> Any:
    return action("dblclick", ref=ref, tab_id=tab_id)


def hover(ref: str, *, tab_id: str | None = None) -> Any:
    return action("hover", ref=ref, tab_id=tab_id)


def fill(ref: str, value: str, *, tab_id: str | None = None) -> Any:
    return action("fill", ref=ref, value=value, tab_id=tab_id)


def type_text(ref: str, value: str, *, tab_id: str | None = None) -> Any:
    return action("type", ref=ref, value=value, tab_id=tab_id)


def select(ref: str, value: str, *, tab_id: str | None = None) -> Any:
    return action("select", ref=ref, value=value, tab_id=tab_id)


def check(ref: str, *, tab_id: str | None = None) -> Any:
    return action("check", ref=ref, tab_id=tab_id)


def uncheck(ref: str, *, tab_id: str | None = None) -> Any:
    return action("uncheck", ref=ref, tab_id=tab_id)


def press(key: str, *, tab_id: str | None = None) -> Any:
    return action("press", value=key, tab_id=tab_id)


def scroll(*, tab_id: str | None = None) -> Any:
    return action("scroll", tab_id=tab_id)


def scroll_into_view(ref: str, *, tab_id: str | None = None) -> Any:
    return api("/scrollintoview", tab_id=tab_id or current_tab_id(), ref=ref)


def screenshot(path: str = "/tmp/kuri-harness.png", *, full: bool = False, tab_id: str | None = None) -> str:
    result = api("/screenshot", tab_id=tab_id or current_tab_id(), full=full)
    data = result.get("result", {}).get("data") if isinstance(result, dict) else None
    if not data:
        raise KuriHarnessError(f"unexpected screenshot response: {result!r}")
    Path(path).write_bytes(base64.b64decode(data))
    return path


def wait(seconds: float = 1.0) -> None:
    time.sleep(seconds)


def wait_for(predicate, timeout: float = 15.0, interval: float = 0.5) -> Any:
    deadline = time.time() + timeout
    last = None
    while time.time() < deadline:
        last = predicate()
        if last:
            return last
        time.sleep(interval)
    return last


HELP = """kuri-harness prototype

Helpers preloaded:
  health(), tabs(), discover(), api(path, **params), use(tab_id), current_tab(), page_info(), ensure_tab()
  new_tab(url='about:blank'), new_window(url='about:blank'), close_tab(), goto(url)
  snap(interactive=False, text_format=False), action(name, ref=None, value=None)
  click(ref), dblclick(ref), hover(ref), fill(ref, value), type_text(ref, value), select(ref, value)
  check(ref), uncheck(ref), press(key), scroll(), scroll_into_view(ref)
  text(selector=None), eval_js(expression), screenshot(path='/tmp/kuri-harness.png')
  wait(seconds), wait_for(predicate, timeout=15.0, interval=0.5)

Environment:
  KURI_BASE_URL=http://127.0.0.1:8080   override Kuri server URL
  KURI_HARNESS_SESSION=~/.kuri/harness_session.json
  KURI_SESSION_ID=kuri-harness          server-side current-tab session id

Example:
  python3 tools/kuri_harness.py <<'PY'
  ensure_tab()
  goto("https://news.ycombinator.com")
  print(snap(interactive=True)[:5])
  PY
"""


def main() -> None:
    args = sys.argv[1:]
    if args and args[0] in {"-h", "--help"}:
        print(HELP)
        return
    if sys.stdin.isatty():
        sys.exit(
            "kuri_harness.py reads Python from stdin. Example:\n"
            "  python3 tools/kuri_harness.py <<'PY'\n"
            "  ensure_tab()\n"
            "  print(health())\n"
            "  PY"
        )
    exec(compile(sys.stdin.read(), "<stdin>", "exec"), globals())


if __name__ == "__main__":
    main()
