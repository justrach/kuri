---
name: kuri-mobile
description: Umbrella skill for mobile device control in the kuri ecosystem. Points to kuri-ios (iOS Simulator + real-device listing) and kuri-android (native Zig adb client). Use this when the user asks about "mobile automation" generally, or hasn't specified a platform. For platform-specific work prefer the `kuri-ios` or `kuri-android` skill directly.
---

# kuri-mobile (umbrella)

`kuri-mobile` is the Zig-native subproject at `kuri-mobile/` that
adds mobile device control to the kuri browser-automation stack.
Inspired by [`mobile-device-mcp`](https://github.com/srmorete/mobile-device-mcp),
reimplemented in Zig with no Bun, Node, Gradle, or Xcode in the
build path.

**Use the platform-specific skills** for actual work:

- **`kuri-ios`** — iOS Simulator (boot, openurl, launch, terminate,
  screenshot, list-apps) + real-iPhone listing (usbmuxd) +
  real-iPhone launch/terminate (devicectl).
- **`kuri-android`** — Android devices and emulators (tap, swipe,
  type, press, screenshot, uitree, launch, terminate, list-apps)
  via a native Zig adb wire-protocol client.

## Build once, use everywhere

```sh
cd kuri-mobile
zig build
zig build test
cp zig-out/bin/kuri-mobile ../zig-out/bin/    # so `kuri ios` / `kuri android` work
```

The main `kuri` binary forwards `kuri android <cmd>` and
`kuri ios <cmd>` to `kuri-mobile` (it `execvp`s it from the same
directory or `$PATH`). So either invocation works:

```sh
kuri android list-devices
kuri-mobile android list-devices
```

## Driverless scope (important)

We deliberately do **not** install an on-device driver app.
Consequences you must be honest about:

- No `run_code` JavaScript sandbox.
- No tap / swipe / type / uitree on real iOS devices (that would
  require a vendored XCUITest bundle; intentionally out of scope).
- Android gets nearly the full upstream tool surface because its
  shell already exposes `input`, `screencap`, `uiautomator dump`,
  `monkey`, `am`, `pm`.

Full parity matrix vs `mobile-device-mcp`: see
`kuri-mobile/README.md`.

## When to reach for which skill

| User asks about… | Invoke |
|---|---|
| "iPhone", "iOS", "sim", "Safari on simulator", "iPad" | `kuri-ios` |
| "Android", "adb", "emulator", "Pixel", "Galaxy", "APK" | `kuri-android` |
| "mobile" without specifying | either — ask first, or default to this umbrella note |
| Browser automation (Chrome, CDP) | **not** a mobile skill — use `kuri-server`, `kuri-agent`, or `kuri-browse` |
