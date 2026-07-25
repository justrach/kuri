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
./zig-out/bin/kuri-mobile android wait-for-ui --label "Sign in" --timeout 10000
./zig-out/bin/kuri-mobile android find --label "Settings"
./zig-out/bin/kuri-mobile android batch tap:120,400 type:hi press:enter wait:500
./zig-out/bin/kuri-mobile android gesture 100,900 300,600 500,900 --for 600
./zig-out/bin/kuri-mobile android current-activity
./zig-out/bin/kuri-mobile android logcat --last 200 --predicate MyTag

./zig-out/bin/kuri-mobile ios list-devices
./zig-out/bin/kuri-mobile ios screenshot --udid <UDID> --simulator out.png
./zig-out/bin/kuri-mobile ios launch    --udid <UDID> --simulator com.apple.Preferences

# Simulator-only input (coordinates are device pixels, matching the screenshot)
./zig-out/bin/kuri-mobile ios tap   200 600
./zig-out/bin/kuri-mobile ios swipe 200 1500 200 500 400   # pan up; alias: pan/scroll
./zig-out/bin/kuri-mobile ios type  "hello world"

# Accessibility tree — role, a11y identifier, label, device-pixel bounds
./zig-out/bin/kuri-mobile ios uitree
#   @e3 AXButton #com.apple.settings.general [General] @113,1200-1092,1345 *clickable

# Act on labels instead of coordinates, so taps survive layout changes
./zig-out/bin/kuri-mobile ios tap --label "General"

# Hardware buttons and lifecycle transitions
./zig-out/bin/kuri-mobile ios button home          # also: lock volup voldown action rotate
./zig-out/bin/kuri-mobile ios background --for 3000 com.example.app

# Hardware-keyboard shortcuts (Command-Return and friends)
./zig-out/bin/kuri-mobile ios key return --cmd

# Accessibility / appearance sweep axes
./zig-out/bin/kuri-mobile ios ui appearance dark
./zig-out/bin/kuri-mobile ios ui content-size increment    # Dynamic Type
./zig-out/bin/kuri-mobile ios ui increase-contrast enabled

# Deterministic screenshots + bounded log assertions
./zig-out/bin/kuri-mobile ios status-bar override --time 9:41
./zig-out/bin/kuri-mobile ios log --last 30s --predicate 'subsystem == "com.example.app"'

# Wait on the UI instead of sleeping and hoping
./zig-out/bin/kuri-mobile ios wait-for-ui --label "Sign In" --timeout 10000
./zig-out/bin/kuri-mobile ios wait-for-ui --label "Spinner" --absent
./zig-out/bin/kuri-mobile ios find --label "General"   # all candidates + tap-ready centroids

# Several actions in one process — resolves the device and focuses the window once
./zig-out/bin/kuri-mobile ios batch tap:120,400 type:hello key:return wait:500 label:Done

# Paths whose shape matters, and raw touch for anything not covered
./zig-out/bin/kuri-mobile ios gesture 100,900 300,600 500,900 --for 600
./zig-out/bin/kuri-mobile ios touch down 200 600

# App and device state
./zig-out/bin/kuri-mobile ios install ./build/MyApp.app
./zig-out/bin/kuri-mobile ios set-location 37.3349 -122.0090
./zig-out/bin/kuri-mobile ios record-video demo.mp4 --for 5000
./zig-out/bin/kuri-mobile ios erase --udid <UDID>

# Check the preconditions before they bite
./zig-out/bin/kuri-mobile doctor
```

### Discovering the command surface

`ios tools` renders the whole surface from the same table the dispatcher and
the help text use, so it cannot drift out of date:

```sh
./zig-out/bin/kuri-mobile ios tools           # grouped, human-readable
./zig-out/bin/kuri-mobile ios tools --json    # name/aliases/args/flags/scope, for agents
./zig-out/bin/kuri-mobile android tools --json
```

Both platforms render from `common/toolinfo.zig`, so they describe themselves
identically and one parser handles either. 63 commands total — 36 iOS, 27
Android.

Each entry carries a `scope` of `simulator`, `device` or `simulator+device`, so
a caller can tell "not supported here" apart from "not configured yet" without
trying it first.

### iOS Simulator accessibility tree

Simulator.app bridges the running iOS app's a11y tree into the host macOS
Accessibility hierarchy, but only once app accessibility is enabled inside
the runtime. `uitree` turns it on (idempotently) before each dump, so this
is transparent. Without it the device-screen `AXGroup` is present but
childless — which looks exactly like "no bridge exists", and is why this
was previously documented as XCUITest-only.

Real devices remain XCUITest-only: there is no host process to inspect.

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
| iOS Simulator UI tree            | ✅ via host AX + `ApplicationAccessibilityEnabled` (no XCUITest) | ✅ via XCUITest |
| iOS Simulator tap-by-a11y-label  | ✅ `ios tap --label` (resolves through the a11y tree) | ✅ via XCUITest |
| iOS Simulator hardware buttons   | ✅ Home/Lock/Volume/Action/Rotate via host AX | ✅ |
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

## End-to-end tests

```sh
zig build e2e-ios            # drives a real booted Simulator
```

Runs against Settings by default, so it works on any machine. With no
simulator booted it prints SKIP and exits 0 rather than failing, which is why
it is kept out of `zig build test`. Point it at your own app with:

```sh
KURI_E2E_BUNDLE_ID=com.example.app \
KURI_E2E_LABEL="Hello, world!" \
KURI_E2E_APP=~/Library/Developer/Xcode/DerivedData/…/Debug-iphonesimulator/App.app \
  zig build e2e-ios
```

Only non-input commands are exercised — `tap`/`swipe`/`gesture` post real
CGEvents and would seize the cursor of whoever is running the suite.

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
