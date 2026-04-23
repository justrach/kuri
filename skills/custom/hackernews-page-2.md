---
name: hackernews-page-2
description: Example custom Kuri skill for Hacker News. Use when you want a concrete session-based browse flow: open Hacker News, take an interactive snapshot, click the More link, and verify that the browser reached page 2.
---

# Hacker News Page 2

This is an example of a narrow custom skill built on top of `skills/kuri-skill.md`.

Use it when you want a simple end-to-end browse check against a real site.

## Flow

1. Start `kuri`.
2. Create a fresh session-scoped tab at `https://news.ycombinator.com`.
3. Call `/page/info` and confirm the URL is page 1.
4. Call `/snapshot?filter=interactive`.
5. Find the ref whose `name` is `More`.
6. Click it with `/action?action=click&ref=eN`.
7. Call `/page/info` again and confirm the URL is `https://news.ycombinator.com/?p=2`.

## Raw HTTP example

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

## Wrapper example

```python
tab = new_tab("https://news.ycombinator.com")
info1 = page_info()
nodes = snap(interactive=True)
more = next(node["ref"] for node in nodes if node.get("name") == "More")
click(more)
info2 = page_info()
assert info2["url"] == "https://news.ycombinator.com/?p=2"
```

## Notes

- Do not reuse old refs after navigation. Take a fresh snapshot on page 2 if you want to keep browsing.
- This skill is intentionally site-specific. Put other site workflows next to it in `skills/custom/`.
