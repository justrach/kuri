# pi-kuri-skill — Maintainer's Guide

This document covers how to publish and maintain `pi-kuri-skill` as a
[pi.dev](https://pi.dev) skill package on npm.

## Quick Reference

| What | Where |
|------|-------|
| Package directory | `skills/pi-kuri-plugin/` |
| npm package name | `pi-kuri-skill` |
| Install command | `pi install npm:pi-kuri-skill` |
| pi.dev catalog | [pi.dev/packages](https://pi.dev/packages) (auto-discovered from npm) |
| Example packages | `pi install npm:pi-subagents`, `pi install npm:pi-web-access` |

## Directory Layout

```
skills/pi-kuri-plugin/
├── package.json          # npm manifest — name, version, pi manifest, bin
├── pi-kuri.ts            # Pi extension — registers all Kuri tools for agents
├── SKILL.md              # Pi agent skill (two-tier: core + advanced)
├── README.md             # User-facing install/config docs
├── scripts/
│   └── kuri.js           # CLI binary — kuri-skill command
├── references/
│   └── ADVANCED.md  →    # Symlink → ../../pi-kuri-advanced.md (canonical source)
└── .npmignore            # Excludes package-lock.json, node_modules
```

## How Publishing Works

pi.dev auto-discovers packages from the npm registry. When you publish (or
update) an npm package with the `pi-package` keyword and a `pi` manifest in
`package.json`, it appears on the [pi.dev package catalog](https://pi.dev/packages)
within minutes. No separate submission is needed.

### What pi.dev looks for in `package.json`

```json
{
  "name": "pi-kuri-skill",
  "version": "1.0.0",
  "keywords": ["pi-package", "agent-skills", "kuri", "browser-automation"],
  "pi": {
    "skills": ["."]           ← tells pi.dev to find SKILL.md in package root
  }
}
```

The `pi-package` keyword is the **discovery signal**. Without it, the package
won't appear on the catalog.

For gallery previews, you can add optional metadata:

```json
{
  "pi": {
    "skills": ["."],
    "image": "https://kuri.gg/screenshot.png",
    "video": "https://kuri.gg/demo.mp4"
  }
}
```

## Step-by-Step: Publish a Release

### 1. Bump the version

```bash
cd skills/pi-kuri-plugin

# Choose one:
npm version patch   # 1.0.0 → 1.0.1 (bug fixes)
npm version minor   # 1.0.0 → 1.1.0 (new features, backward-compatible)
npm version major   # 1.0.0 → 2.0.0 (breaking changes)
```

This updates `package.json`, creates a git tag, and commits.

### 2. Smoke-test the package

```bash
# Verify the CLI works
node scripts/kuri.js health

# Verify the package tarball is clean
npm pack --dry-run
```

Check that `npm pack --dry-run` lists only the files you intend to ship.
The `.npmignore` file excludes `package-lock.json` and `node_modules`.

### 3. Push the tag

```bash
git push --tags
```

### 4. Publish to npm

```bash
cd skills/pi-kuri-plugin
npm publish
```

> **Note**: You need npm publish access for the `pi-kuri-skill` package name.
> If you haven't published before, run `npm login` first and ensure the name
> is available (or use a scoped name like `@your-org/pi-kuri-skill`).

### 5. Verify on pi.dev

```bash
# Install from npm in a test project
pi install npm:pi-kuri-skill

# Check it's listed
pi list
```

If the package is listed, it will appear on [pi.dev/packages](https://pi.dev/packages)
within a few minutes.

## Maintaining the Skill

### Keeping docs in sync

The two-tier skill documentation lives at two levels:

| File | Purpose |
|------|---------|
| `skills/pi-kuri-skills.md` | Canonical core skill docs (repo-level) |
| `skills/pi-kuri-advanced.md` | Canonical advanced reference (repo-level) |
| `skills/pi-kuri-plugin/SKILL.md` | Plugin skill entrypoint — references both tiers |
| `skills/pi-kuri-plugin/references/ADVANCED.md` | **Symlink** → `../../pi-kuri-advanced.md` — always in sync |

The symlink at `references/ADVANCED.md` ensures the npm package always ships
the same advanced reference as the repo-level canonical file. **Do not replace
it with a copy** — that's how drift happens.

### Updating the Pi extension

The extension file `pi-kuri.ts` registers Kuri tools for the Pi agent. When
you add, remove, or change tool signatures:

1. Update `pi-kuri.ts`
2. Update `SKILL.md` if the user-facing instructions change
3. Bump a patch version and publish

### Version convention

| Change | Version bump | Example |
|--------|-------------|---------|
| Bug fix, docs, tool description | `patch` | 1.0.0 → 1.0.1 |
| New tool, new parameter, backward-compatible | `minor` | 1.0.0 → 1.1.0 |
| Breaking tool API change, removed tool | `major` | 1.0.0 → 2.0.0 |

## Example: Other pi.dev Packages for Reference

Browse the [pi.dev package catalog](https://pi.dev/packages) for real examples.
Notable packages with similar structure (skill + CLI/extension):

| Package | Type | What to learn |
|---------|------|---------------|
| `pi-subagents` | extension | Multi-file extension with TUI, well-structured `package.json` |
| `pi-web-access` | extension | Tool registration pattern, multi-tool extension |
| `pi-mcp-adapter` | extension | Extension with MCP protocol integration |
| `pi-package-search` | skill | Skill-only package, `/skill:` invocation pattern |
| `@juicesharp/rpiv-*` | extension | Scoped package + comprehensive test suite |

Install any of them to inspect their structure:

```bash
pi install npm:pi-subagents
pi install npm:pi-web-access
pi install npm:pi-mcp-adapter
pi install npm:pi-package-search

# Then inspect:
cat ~/.pi/agent/npm/node_modules/pi-subagents/package.json
```

## Troubleshooting

### Package not appearing on pi.dev

1. Check that `keywords` in `package.json` includes `"pi-package"`
2. Verify the `pi` manifest section is present
3. Confirm the package is publicly accessible on npm
4. Wait a few minutes — the catalog refreshes periodically

### `pi install npm:pi-kuri-skill` fails

```bash
# Try with explicit version
pi install npm:pi-kuri-skill@1.0.0

# Check npm for the package
npm view pi-kuri-skill

# Install from local path for testing
pi install ./skills/pi-kuri-plugin
```

### Symlink broken after clone

The `references/ADVANCED.md` symlink targets `../../pi-kuri-advanced.md`
relative to the plugin directory. On a fresh clone, verify:

```bash
ls -la skills/pi-kuri-plugin/references/ADVANCED.md
readlink -f skills/pi-kuri-plugin/references/ADVANCED.md
# Should resolve to: /path/to/kuri/skills/pi-kuri-advanced.md
```

If the symlink is broken, re-create it:

```bash
rm skills/pi-kuri-plugin/references/ADVANCED.md
ln -s ../../pi-kuri-advanced.md skills/pi-kuri-plugin/references/ADVANCED.md
```

> **For Windows users**: Git may not handle symlinks by default. Enable them
> with `git config --global core.symlinks true` before cloning, or replace
> the symlink with a copy script in a prepublish step.
