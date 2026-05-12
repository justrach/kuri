---
name: kuri-ios
description: Use kuri-ios to drive iOS Simulators from the CLI — list sims, boot/shutdown, navigate Safari to URLs (openurl), launch and terminate apps by bundle id, capture PNG screenshots, list installed apps, and (on the Simulator only) tap, swipe/pan, and type via native CGEvent into the Simulator window. Real iPhones over USB are supported for listing and launch/terminate via usbmuxd + xcrun devicectl. Tap/swipe/type/uitree on real devices and uitree on the Simulator are NOT supported in v1 (require XCUITest). Trigger phrases include "screenshot the iPhone sim", "tap on iOS simulator", "swipe up on iPhone sim", "pan the iOS simulator", "type into iOS simulator", "open Safari on simulator", "launch iOS Settings", "list booted simulators".
---

# kuri-ios

Drive iOS Simulators (and, where possible, real iPhones) through the
`kuri ios` subcommand. Implementation lives in
`kuri-mobile/src/ios/` and the main `kuri` binary forwards
`kuri ios …` to the `kuri-mobile` binary.

## When to use this skill

- Boot an iOS Simulator, open Safari to a URL, screenshot the result.
- Launch or terminate any iOS app by bundle id on the Simulator.
- List installed apps on the Simulator.
- Enumerate real iPhones plugged in over USB (via usbmuxd, native Zig).
- Launch / terminate an app on a real iPhone via `xcrun devicectl`.

- Tap, swipe, pan, or type into the booted iOS Simulator (CGEvent posts
  into the Simulator.app window; coords are device pixels matching the
  screenshot). The first run will trigger a macOS Accessibility prompt
  for your terminal — without that permission, taps are silently dropped.

Do **not** use this skill for:

- Tapping, swiping, typing, or reading UI tree on a real iPhone
  (requires XCUITest; intentionally not in v1).
- Reading the UI tree of the iOS Simulator (the macOS AX of Simulator.app
  does not expose the iOS app — that path is XCUITest only).
- Running JS inside a page — that's a browser task, use kuri-agent.
- Android — use the `kuri-android` skill instead.

## Prerequisites

- Xcode installed (`xcrun`, `simctl`, `devicectl`).
- At least one iOS Simulator runtime installed. `xcrun simctl runtime
  list` must show at least one `(Ready)` entry. If it's empty:
  `xcodebuild -downloadPlatform iOS` (one-time ~7 GB download).
- `kuri-mobile` built and either on `$PATH` or next to the `kuri`
  binary (`zig-out/bin/kuri-mobile`).

## Build

```sh
cd kuri-mobile
zig build
cp zig-out/bin/kuri-mobile ../zig-out/bin/
zig build test    # optional: unit tests for adb framing, uitree parser, usbmuxd plist scan
```

## Typical flow

```sh
# 1. List and boot a sim
kuri ios list-devices
xcrun simctl create "scratch" com.apple.CoreSimulator.SimDeviceType.iPhone-16 com.apple.CoreSimulator.SimRuntime.iOS-26-4
kuri ios boot --udid <UDID>

# 2. Navigate and screenshot (auto-resolves the booted sim — no --udid needed)
kuri ios openurl https://news.ycombinator.com
sleep 3   # let the page settle
kuri ios screenshot hn.png

# 3. Launch a built-in app, screenshot
kuri ios launch com.apple.Preferences
sleep 2
kuri ios screenshot settings.png

# 4. Open any URL scheme (not just https/http)
kuri ios openurl "maps://?q=San%20Francisco"
```

## Full command surface

| Command | Purpose |
|---|---|
| `kuri ios list-devices` | Sims (from simctl JSON) + real devices (from usbmuxd) |
| `kuri ios boot --udid <U>` | Boot a simulator |
| `kuri ios shutdown --udid <U>` | Shut down a simulator |
| `kuri ios openurl <url>` | Open URL (auto-resolves booted sim). Alias: `navigate` |
| `kuri ios launch <bundle-id>` | Launch app on booted sim |
| `kuri ios launch --device --udid <U> <bundle-id>` | Launch on real iPhone via devicectl |
| `kuri ios terminate <bundle-id>` | Kill app on booted sim |
| `kuri ios terminate --device --udid <U> <bundle-id>` | Kill on real device |
| `kuri ios screenshot [path.png]` | PNG from booted sim (auto-resolves) |
| `kuri ios list-apps --udid <U>` | List installed apps on sim |
| `kuri ios tap <x> <y>` | Tap at device pixel coords on the booted sim |
| `kuri ios swipe <x1> <y1> <x2> <y2> [ms]` | Swipe/pan on the sim. Aliases: `pan`, `scroll` |
| `kuri ios type <text...>` | Send keystrokes to the focused field on the sim |

## Intentional limits (don't claim parity with upstream)

- `tap`, `swipe`, `type` work on the iOS **Simulator only** (CGEvent into
  the Simulator.app window). On real iPhones they return an explicit
  "requires XCUITest" error — on purpose.
- `uitree` returns an explicit "requires XCUITest" error on both
  Simulator and real device. The macOS AX tree of Simulator.app only
  exposes the macOS window chrome, not the running iOS app.
- Real-device screenshot is unavailable for the same reason.
- There is no on-device `run_code` sandbox.

If a user needs any of the above, the route forward is the v2
"vendor on-device drivers" path described in `kuri-mobile/README.md`,
not this skill.

## Native vs shelled-out surfaces (honesty)

| Surface | How it's implemented |
|---|---|
| simctl device listing | libc fork/exec `xcrun simctl list devices --json`, parse JSON in Zig |
| usbmuxd real-device listing | native Zig Unix-socket client, plist scan |
| openurl / launch / terminate / screenshot | shell out to `xcrun simctl` / `xcrun devicectl` |
| Simulator tap / swipe / pan | **native Zig** — CGEvent via `ApplicationServices.framework`, with `osascript` only used to (a) activate Simulator.app and (b) read the front window's position+size for the device→screen coord mapping |
| Simulator type | shell out to `osascript` (`System Events keystroke`), Unicode-safe |
| Resolve "booted sim" | iterate parsed list in Zig, match `state == "Booted"` |

Apple's iOS Simulator runtime renders the screens — Kuri orchestrates.
