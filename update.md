# Kuri v0.6.0 — the mobile side grows a build system, session defaults, and an MCP server

kuri-mobile used to be a device driver: hand it a built `.app` and it would
install, launch, tap, type, and read the screen. As of v0.6.0 it owns the
whole loop — **source code to running simulator app to test results, one
binary, one command** — and every one of its commands is now callable over
MCP by any agent client.

---

## Xcode build commands

Six new commands delegate to `xcodebuild` and hand the product straight to
the existing install/launch path:

```
kuri ios list-schemes MyApp.xcodeproj
kuri ios build        MyApp.xcodeproj --scheme MyApp
kuri ios build-run    MyApp.xcodeproj --scheme MyApp   # build → install → launch
kuri ios test         MyApp.xcodeproj --scheme MyApp   # XCTest on the booted sim
kuri ios product      MyApp.xcodeproj --scheme MyApp   # app path + bundle id, no build
kuri ios clean        MyApp.xcodeproj --scheme MyApp
```

`build-run` is the one agents reach for: on a small SwiftUI project it goes
from source to a running app on the booted simulator in **7.4 seconds**
(warm build), printing the built `.app` path and bundle id on the way.

A detail that matters on real machines: these commands resolve the Xcode
toolchain themselves. If `xcode-select` points at CommandLineTools — the
default after installing CLT, and a state that breaks bare `xcodebuild`
before it reads its arguments — kuri finds Xcode.app and works anyway.

## Session defaults

Repeating a project path and scheme on every call is agent-hostile, so:

```
kuri ios defaults set project ~/code/MyApp.xcodeproj
kuri ios defaults set scheme MyApp
kuri ios build-run          # no arguments
kuri ios test               # no arguments
```

Four keys (`project`, `scheme`, `configuration`, `udid`), one flat file,
three rules that keep hidden state from becoming a footgun: explicit flags
always win, only the build-family commands consult the defaults, and
`defaults show` / `defaults clear` make the state inspectable and
disposable.

## MCP server, built on mcp-zig

```
kuri-mobile mcp
```

Every iOS and Android command plus `doctor` — **79 tools** — served over
MCP stdio. The protocol machinery (JSON-RPC loop, version negotiation
across four spec revisions, logging, the stateless 2026-07-28 mode) comes
from [mcp-zig](https://github.com/justrach/mcp-zig) as a package
dependency; kuri contributes only a registry generated **at comptime** from
the same tool tables that render the CLI help. Add a command to the table
and it is an MCP tool. There is no second list to forget.

Measured against XcodeBuildMCP 2.7.0 on the same machine, same project,
same MCP traffic:

| | kuri-mobile | XcodeBuildMCP 2.7.0 |
|---|---|---|
| Server ready (spawn → initialize) | **9 ms** | 414 ms |
| `tools/list` answered | **0.4 ms** | 10–25 ms |
| Warm incremental build-run | **2.2 s** | 2.9–3.1 s |

The `tools/list` number is not a trick: the list is a comptime constant
baked into the binary. The build-run gap is pure orchestration overhead —
both tools run the same `xcodebuild`.

Register it with Claude Code:

```
claude mcp add kuri-mobile -- kuri-mobile mcp
```

## Removed: the connect feature

The `/connect/*` routes, `kuri-agent connect`, `kuri-connect-broker`, and
relay-fetch mode are gone. They depended on a private sibling library that
made every build require a private checkout, and its pinned commit did not
compile on the project's Zig toolchain. Building kuri now needs only this
repo. `KURI_VAULT_PASSPHRASE`, `KURI_RELAY`, and `KURI_BROKER*` no longer
have any effect.

## Signed and notarized

The macOS assets in this release are signed with a Developer ID and
notarized by Apple. No quarantine prompt, no `xattr` incantation.

## Get it

```
curl -fsSL https://raw.githubusercontent.com/justrach/kuri/release-channel/stable/install.sh | sh
```

Already installed? `kuri update`. Full details in
[CHANGELOG.md](CHANGELOG.md); the honest feature-by-feature comparison with
XcodeBuildMCP — including what kuri deliberately does not do — lives in
[kuri-mobile/COMPARISON.md](kuri-mobile/COMPARISON.md).
