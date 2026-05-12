# kuri-mobile

Native Zig CLI for driving Android and iOS devices, integrated into the
`kuri` ecosystem alongside `kuri-browser`.

Inspired by [`mobile-device-mcp`](https://github.com/srmorete/mobile-device-mcp);
the host-side surface (tap, screenshot, uitree, launch/terminate, etc.)
is reimplemented in Zig with no Bun, Node, Gradle, or Xcode build
dependencies. See **Honest scope** below for what we deliberately do
*not* implement.

## Layout

```
kuri-mobile/
  src/
    main.zig                 # `kuri-mobile <android|ios> ...`
    common/
      io.zig                 # libc-backed stdout/stderr/runCommand
      uitree.zig             # unified flat element list (Android XML parser)
    android/
      adb.zig                # native Zig client for the adb wire protocol
      driver.zig             # tap/swipe/type/screencap/uitree/launch/...
      cli.zig                # `kuri-mobile android` dispatcher
    ios/
      simctl.zig             # iOS Simulator via `xcrun simctl`
      usbmux.zig             # native Zig usbmuxd ListDevices client
      devicectl.zig          # real-device launch/terminate via `xcrun devicectl`
      cli.zig                # `kuri-mobile ios` dispatcher
```

## Usage

```sh
zig build
./zig-out/bin/kuri-mobile android list-devices
./zig-out/bin/kuri-mobile android tap 540 1200
./zig-out/bin/kuri-mobile android screenshot screen.png
./zig-out/bin/kuri-mobile android uitree

./zig-out/bin/kuri-mobile ios list-devices
./zig-out/bin/kuri-mobile ios screenshot --udid <UDID> --simulator out.png
./zig-out/bin/kuri-mobile ios launch    --udid <UDID> --simulator com.apple.Preferences

# Simulator-only input (coordinates are device pixels, matching the screenshot)
./zig-out/bin/kuri-mobile ios tap   200 600
./zig-out/bin/kuri-mobile ios swipe 200 1500 200 500 400   # pan up; alias: pan/scroll
./zig-out/bin/kuri-mobile ios type  "hello world"
```

The main `kuri` binary also forwards `kuri android …` and `kuri ios …`
to this binary (it execvp's `kuri-mobile` from the same directory or
$PATH), so both invocations work:

```sh
kuri android list-devices
kuri-mobile android list-devices
```

## Prerequisites

- Android: a running `adb server` on `127.0.0.1:5037`. Install Android
  platform-tools (`brew install android-platform-tools`) and run
  `adb start-server` once.
- iOS Simulator: Xcode (`xcrun`, `simctl`). For `tap`/`swipe`/`pan`/`type`,
  macOS will prompt to grant your terminal **Accessibility** permission the
  first time CGEvent posts a synthetic event (System Settings → Privacy &
  Security → Accessibility). Without it, taps are silently dropped by
  WindowServer.
- iOS real device: Xcode (`devicectl`). The `kuri-mobile` binary itself
  does not require `libimobiledevice`; we only speak usbmuxd's
  `ListDevices` message natively, then delegate launch/terminate to
  Apple's `devicectl`.

## Honest scope (read this before comparing to upstream)

This is the **driverless** flavor: we never install an on-device app.
Compared to `mobile-device-mcp`:

| Capability                       | kuri-mobile v1 | upstream `mobile-device-mcp` |
|----------------------------------|---|---|
| Android tap/swipe/type           | ✅ via `input` | ✅ via UIAutomator |
| Android screenshot               | ✅ via `screencap` | ✅ |
| Android UI tree                  | ✅ via `uiautomator dump` | ✅ via UIAutomator |
| Android launch / terminate / list-apps | ✅ via `monkey`/`am`/`pm` | ✅ |
| iOS Simulator screenshot/launch  | ✅ via `simctl`        | ✅ |
| iOS Simulator tap/swipe/pan/type | ✅ via CGEvent + AppleScript window targeting | ✅ via XCUITest |
| iOS Simulator UI tree            | ❌ requires XCUITest (macOS AX of Simulator.app does not expose the iOS app's controls) | ✅ via XCUITest |
| iOS real-device tap/swipe/uitree | ❌ requires XCUITest    | ✅ via XCUITest bundle |
| `run_code` JS sandbox (Rhino/JSC)| ❌ requires on-device driver | ✅ |
| MCP server (JSON-RPC stdio)      | ❌ not yet (CLI only)   | ✅ |
| Multi-device port allocation/auth| ❌ not needed (no on-device server) | ✅ |

If you need feature-parity with on-device execution and rich iOS UI
trees on real devices, you have to either:

1. Vendor `mobile-device-mcp` upstream and run it as a subprocess, or
2. Add a future v2 to kuri-mobile that ships its own Kotlin/Swift
   on-device drivers (significantly larger build).

## Native Zig surfaces vs delegated surfaces

| Layer                      | Implementation                                |
|----------------------------|-----------------------------------------------|
| adb host protocol          | **native Zig** (libc sockets, `host:` + `host:transport:` + `shell:` + `exec:`) |
| Android UI tree XML parse  | **native Zig** scanner                        |
| iOS usbmuxd `ListDevices`  | **native Zig** (libc Unix socket, plist scan) |
| iOS Simulator commands     | shell out to `xcrun simctl`                   |
| iOS Simulator tap/swipe/pan | **native Zig** (CGEvent via ApplicationServices.framework) targeting the Simulator.app window |
| iOS Simulator type         | shell out to `osascript` (System Events `keystroke`, Unicode-safe) |
| iOS real device launch     | shell out to `xcrun devicectl`                |
| Android `screencap`/`uiautomator dump` etc | server-side commands the device's own shell runs; we just frame them over adb in Zig |

## Tests

```sh
zig build test
```

Covers adb framing, parseDevices, uitree parser, and usbmuxd plist
scanning. No live device required.

## Cache / benchmark honesty

This subproject does not yet have published benchmarks. If you add any,
follow the rules in `../AGENTS.md` (Benchmark Honesty + Cache
Disclosure) and clearly label which path was exercised:

- adb-native (Zig) vs `adb` shell-out (we never shell out to `adb`)
- simctl-shellout (iOS sim)
- devicectl-shellout (iOS real-device launch/terminate)
- usbmuxd-native (Zig) for `ios list-devices`
