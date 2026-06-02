---
name: kuri-browse
description: Use kuri-browse for quick terminal-based web browsing — fetch and read web pages as markdown, follow links, search in-page. No Chrome needed. Use when the user wants to quickly read a webpage, check documentation, or browse without launching a full browser. Trigger phrases include "read this page", "fetch the docs", "browse to", "what does this page say".
argument-hint: "[url]"
allowed-tools: Bash
---

# kuri-browse — Terminal Web Browser

A lightweight terminal browser. Fetches pages, renders to markdown, lets you navigate links. No Chrome or JS engine needed.

## Usage

```bash
# Browse a URL
./zig-out/bin/kuri-browse https://example.com

# Interactive REPL
./zig-out/bin/kuri-browse
> go https://example.com
> links              # show numbered links
> 3                  # follow link #3
> search "pricing"   # find text
> back               # go back
> quit
```

## Commands in REPL

| Command | Description |
|---|---|
| `go <url>` | Navigate to URL |
| `links` | Show all links with numbers |
| `<number>` | Follow link by number |
| `search <text>` | Find text on page |
| `back` | Go back in history |
| `forward` | Go forward |
| `quit` / `exit` | Exit browser |

## When to use kuri-browse vs kuri server

- **kuri-browse** — Quick page reads, documentation lookup, static content. No Chrome needed.
- **kuri server** — JS-heavy SPAs, form filling, login flows, screenshots, bot-protected sites.
