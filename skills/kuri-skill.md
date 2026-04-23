---
name: kuri-skill
description: Use Kuri's HTTP server as a session-based browser skill. Prefer X-Kuri-Session with /tab/new, /tab/current, /page/info, /snapshot?filter=interactive, and /action for low-token agent loops. Use when an agent needs to browse, read, click, or fill through Kuri without managing raw CDP details.
---

# Kuri Skill

Use this when driving `kuri` over HTTP as an agent loop.

## Preferred loop

1. Start `kuri`.
2. Create or select a tab for your session.
3. Read live page state with `/page/info`.
4. Read actionable refs with `/snapshot?filter=interactive`.
5. Act with `/action`.
6. After navigation or DOM changes, re-run `/page/info` and take a fresh snapshot.

## Session-first pattern

```bash
SESSION=hn-demo
BASE=http://127.0.0.1:8080

curl -s -H "X-Kuri-Session: $SESSION" \
  "$BASE/tab/new?url=https%3A%2F%2Fnews.ycombinator.com"

curl -s -H "X-Kuri-Session: $SESSION" "$BASE/page/info"
SNAP=$(curl -s -H "X-Kuri-Session: $SESSION" "$BASE/snapshot?filter=interactive")
MORE_REF=$(printf '%s' "$SNAP" | python3 -c 'import json,sys; nodes=json.load(sys.stdin); print(next(n["ref"] for n in nodes if n.get("name") == "More"))')
curl -s -H "X-Kuri-Session: $SESSION" "$BASE/action?action=click&ref=$MORE_REF"
curl -s -H "X-Kuri-Session: $SESSION" "$BASE/page/info"
```

## Rules

- Prefer `X-Kuri-Session` over repeating `tab_id`.
- Use `/tab/current?tab_id=...` when you already know which tab should become current.
- Use `/page/info` before assuming the page moved.
- Use `filter=interactive` snapshots for agent loops.
- Treat refs as snapshot-local. Refresh them after navigation or major DOM updates.
- Use HAR only when you need network or API discovery.

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
