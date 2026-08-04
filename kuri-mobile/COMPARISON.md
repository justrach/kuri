# kuri-mobile vs XcodeBuildMCP

Compared against [getsentry/XcodeBuildMCP](https://github.com/getsentry/XcodeBuildMCP) at `main`, July 2026 (82 tools).

The headline: these are **not the same kind of tool**. XcodeBuildMCP is an Xcode
*build* server that also drives the simulator. kuri-mobile is a *device driver*
that does not build anything. Most of the surface difference follows from that,
and most of it is deliberate rather than missing.

## Where kuri-mobile is genuinely behind

Everything in this section is a real gap, in rough order of how much it costs.

### 1. No MCP or HTTP transport — CLI only

*Update 2026-08: closed, the way this section predicted. `kuri-mobile mcp`
serves MCP stdio via the [mcp-zig](https://github.com/justrach/mcp-zig)
library — kuri supplies only a comptime registry generated from the two
platform tool tables plus `doctor` (79 tools); protocol machinery (version
negotiation, logging, notifications, the stateless 2026-07-28 mode) is the
dependency's. `tools/call` re-execs the binary so stdout stays the
protocol's. Measured on an M-series laptop against XcodeBuildMCP 2.7.0:
ready-to-serve in ~9 ms vs ~414 ms, `tools/list` in ~0.4 ms vs ~10-25 ms
(the list is a comptime constant), and a warm incremental `build-run` of the
same project ~2.2 s vs ~2.9–3.1 s through their `build_run_sim`.*

XcodeBuildMCP is an MCP server (plus a CLI and a background daemon with session
state). kuri-mobile was a CLI and nothing else, so every action paid a process
spawn and there was no session.

This was the largest structural gap. `common/toolinfo.zig` already held the full
command surface as data and rendered `--json`, which is exactly what the MCP
server is now generated from.

### 2. The entire build system

*Update 2026-08: the driver-adjacent slice now exists — `list-schemes`,
`build`, `build-run` (their `build_run_sim`), `test` (their `test_sim`),
`product` (their `get_sim_app_path` + `get_app_bundle_id`), and `clean` live
in `ios/xcodebuild.zig` and the shared tool table. Coverage reports, macOS
targets, scaffolding, and Swift Package tooling remain out of scope on
purpose.*

kuri-mobile has **none** of the rest, and adding it would be a different project:

| Area | XcodeBuildMCP |
|---|---|
| Build | `build_sim`, `build_device`, `build_macos`, `build_run_sim`, `build_run_device`, `build_run_macos` |
| Test | `test_sim`, `test_device`, `test_macos` |
| Coverage | `get_coverage_report`, `get_file_coverage` |
| Discovery | `discover_projs`, `list_schemes`, `show_build_settings`, `get_app_bundle_id`, `get_mac_bundle_id` |
| Artifacts | `get_sim_app_path`, `get_device_app_path`, `get_mac_app_path`, `clean` |
| Scaffolding | `scaffold_ios_project`, `scaffold_macos_project` |
| Swift Package | `swift_package_build/test/run/stop/list/clean` |

`build_run_sim` — build, install, launch, capture logs in one call — is the tool
their docs say agents reach for most. kuri-mobile expects you to hand it a
`.app` that already exists.

### 3. LLDB debugging

`debug_attach_sim`, `debug_breakpoint_add`/`remove`, `debug_continue`,
`debug_stack`, `debug_variables`, `debug_lldb_command`, `debug_detach`. No kuri
equivalent.

### 4. macOS app support

They build, launch, stop and test macOS apps. kuri-mobile is iOS + Android only.

### 5. Session defaults

*Update 2026-08: closed. `ios defaults set|show|clear` persists
project/scheme/configuration/udid (one flat file, `KURI_MOBILE_DEFAULTS` to
relocate it); the build-family commands fall back to them, explicit flags
always win, and no other command consults them.*

`session_set_defaults` lets a caller set scheme/project/device once and omit
them afterwards. kuri-mobile used to repeat `--udid` on every invocation.

### 6. Xcode IDE bridge

`xcode_ide_*` and `sync_xcode_defaults` talk to a running Xcode. No equivalent,
and no obvious reason to want one.

## Where kuri-mobile is ahead

- **Android.** 27 commands over a native Zig adb wire-protocol client. XcodeBuildMCP is Apple-only.
- **No driver binary.** Their UI automation shells out to a bundled **AXe** binary (`.axe-version`, `ui-automation/shared/axe-command.ts`). kuri talks to `AXUIElement` and `CGEvent` directly, so there is nothing to version-match or ship alongside.
- **Runs in the background.** As of 0.4.11 kuri drives the Simulator without taking the foreground or moving the cursor (`CGEventPostToPid`, Unicode `CGEvent`s, no `activate`). XcodeBuildMCP inherits AXe's behaviour here.
- **Device inspection.** `device-info`, `device-processes`, `lock-state`, `displays`, `reboot` have no XcodeBuildMCP counterpart. `lock-state` in particular explains a failure mode both tools hit — a locked phone refuses every launch.
- **One binary, no runtime.** Zig, no Node.

## Where they are level

UI automation is close to a one-to-one match:

| XcodeBuildMCP | kuri-mobile |
|---|---|
| `tap`, `long_press`, `swipe`, `drag`, `gesture`, `touch` | `tap`, `longpress`, `swipe`, `gesture`/`drag`, `touch`, `doubletap` |
| `type_text`, `key_press`, `key_sequence`, `button` | `type`, `key`, `key-sequence`, `button` |
| `screenshot`, `snapshot_ui`, `wait_for_ui`, `batch` | `screenshot`, `uitree`, `find`, `wait-for-ui`, `batch` |
| `boot_sim`, `open_sim`, `list_sims`, `erase_sims` | `boot`, `open-sim`, `list-devices`, `erase` |
| `set_sim_location`, `reset_sim_location`, `set_sim_appearance`, `sim_statusbar`, `toggle_*_keyboard`, `record_sim_video` | `set-location`, `reset-location`, `ui appearance`, `status-bar`, `keyboard`, `record-video` |
| `install_app_*`, `launch_app_*`, `stop_app_*`, `doctor` | `install`, `launch`, `terminate`, `doctor` |

**Physical-device UI automation: neither tool has it.** This is worth stating
plainly, because it reads like a kuri gap and is not. XcodeBuildMCP's device
tools are build, install, launch, stop and test — their `ui-automation`
category runs through AXe against the *simulator*. Tapping a real iPhone needs
XCUITest or WebDriverAgent, and neither project has taken that on.

## Test strategy — the sharpest difference

XcodeBuildMCP's device "e2e" tests are **mocked**. `e2e-mcp-device-macos.test.ts`
stands up a harness with canned command responses and asserts on the *captured
argv strings*:

```js
expect(commandStrs.some((c) => c.includes('devicectl') && c.includes('install'))).toBe(true);
```

Their CI runs on `ubuntu-latest`. No simulator and no device is touched in CI at
any point.

That buys speed, hermeticity and Linux CI, and it does catch command-construction
regressions. What it cannot catch is anything about how the tool behaves once the
command actually runs — which is precisely where both bugs fixed in kuri 0.4.11
lived:

- `devicectl device info apps` returning only developer apps is invisible to a mock; the argv is correct, the *result* is filtered.
- A locked device refusing every launch has no argv signature at all.

kuri-mobile now runs both tiers, which is the right answer:

- **Hermetic** — 21 real-device contract cases in `e2e-ios` that need no hardware, asserting exit codes and diagnostics against a fake udid. Two assert the *absence* of devicectl's argument-parser complaint, which is the mocked-test idea done through observable behaviour instead of captured strings.
- **Real** — `e2e-ios` against a booted simulator in CI, and `e2e-ios-device` against attached hardware locally. Both skip with a reason rather than failing when the machine cannot supply a precondition.

## If you want one thing next

The MCP/HTTP server (#1). It is the only gap that changes what kuri *is* rather
than how much it covers, `toolinfo.zig` already has the shape to generate it
from, and it removes the per-action process spawn that makes the CLI awkward for
agents. The build system (#2) is a bigger investment and a different product.
