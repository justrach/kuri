---
name: kuri-skill
description: Use Kuri's HTTP server as a session-based browser skill. Prefer X-Kuri-Session with /tab/new, /tab/current, /page/info, /snapshot?filter=interactive&format=compact, and /action for low-token agent loops. Use when an agent needs to browse, read, click, or fill through Kuri without managing raw CDP details.
---

# Kuri Skill

Use this when driving `kuri` over HTTP as an agent loop.

## Preferred loop

1. Start `kuri`.
2. Create or select a tab for your session.
3. Read live page state with `/page/info`.
4. Read actionable refs with `/snapshot?filter=interactive&format=compact`.
5. Act with `/action`.
6. After navigation or DOM changes, re-run `/page/info` and take a fresh snapshot.

## Which browser path to use

- Use `kuri` plus the HTTP API for real browser automation. This is the production path: Chrome/CDP, sessions, snapshots, actions, HAR, cookies, screenshots, and bot-detection handling.
- Use `kuri-fetch` for standalone no-Chrome text extraction.
- Use `kuri-browse` for an interactive terminal browser.
- Use `kuri-agent` for scriptable CLI automation against the Kuri server.
- Use `kuri-browser/` only when developing or evaluating the experimental Zig-native browser runtime. It is a separate build and is not wired into Kuri's root build.

## Session-first pattern

```bash
SESSION=hn-demo
BASE=http://127.0.0.1:8080

curl -s -H "X-Kuri-Session: $SESSION" \
  "$BASE/tab/new?url=https%3A%2F%2Fnews.ycombinator.com"

curl -s -H "X-Kuri-Session: $SESSION" "$BASE/page/info"
SNAP=$(curl -s -H "X-Kuri-Session: $SESSION" "$BASE/snapshot?filter=interactive&format=compact")
MORE_REF=$(printf '%s' "$SNAP" | python3 -c 'import re,sys; print(re.search(r"\"More\" @(e\\d+)", sys.stdin.read()).group(1))')
curl -s -H "X-Kuri-Session: $SESSION" "$BASE/action?action=click&ref=$MORE_REF"
curl -s -H "X-Kuri-Session: $SESSION" "$BASE/page/info"
```

## Experimental `kuri-browser` CLI

Run these from the separate `kuri-browser/` workspace:

```bash
cd kuri-browser
zig build run -- render https://news.ycombinator.com --selector ".titleline a" --dump text
zig build run -- render https://todomvc.com/examples/react/dist/ --js --wait-eval "document.querySelectorAll('.todo-list li').length >= 1"
zig build run -- bench --offline
zig build run -- parity --offline
```

Screenshots currently use the existing Kuri/CDP renderer as a fallback, so start the normal Kuri server first:

```bash
# terminal 1, repo root
zig build
./zig-out/bin/kuri

# terminal 2
cd kuri-browser
zig build run -- screenshot https://example.com --out example.jpg --compress --kuri-base http://127.0.0.1:8080
```

`--compress` captures a PNG baseline and a JPEG candidate, writes the smaller file, and reports `original-bytes`, `bytes`, `saved-bytes`, and `saved-percent`. Current local measurement on `https://example.com`: `20,523` bytes PNG to `18,183` bytes JPEG quality 50, saving `2,340` bytes or `11%`.

## Rules

- Prefer `X-Kuri-Session` over repeating `tab_id`.
- Use `/tab/current?tab_id=...` when you already know which tab should become current.
- Use `/page/info` before assuming the page moved.
- Use `filter=interactive&format=compact` snapshots for agent loops unless you need JSON.
- Read snapshot `state` before acting on controls. Examples: `checked=false`, `disabled`, `readonly`, `expanded=false`, `selected`.
- Treat refs as snapshot-local. Refresh them after navigation or major DOM updates.
- Use HAR only when you need network or API discovery.
- Treat `kuri-browser` screenshots as fallback-rendered by Kuri/CDP, not proof of native layout or paint.

## Optional wrapper

If you want Python helper functions on top of the same flow, use:

```bash
KURI_BASE_URL=http://127.0.0.1:8080 \
KURI_SESSION_ID=hn-demo \
python3 tools/kuri_harness.py
```

## Custom project skills

Put your own project-specific skill notes in `skills/custom/`.

Good custom skills are narrow. Add site-specific login steps, selectors, or workflows there instead of bloating the base Kuri skill.

See `skills/custom/hackernews-page-2.md` for a concrete example.
