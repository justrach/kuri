---
name: kuri-android
description: Use kuri-android to drive Android devices and emulators from the CLI via a native Zig adb wire-protocol client. Tap, swipe (scroll), double-tap, long-press, type text, press hardware/navigation keys, take PNG screenshots, dump the UI tree as a flat element list, launch/terminate apps by package, list installed packages, and list attached devices. Talks adb directly over TCP 127.0.0.1:5037 — never shells out to the `adb` binary at runtime. Trigger phrases include "tap on android phone", "screenshot the emulator", "list connected android devices", "dump the android ui tree", "launch chrome on android".
---

# kuri-android

Drive Android devices and emulators through the `kuri android`
subcommand. Implementation lives in `kuri-mobile/src/android/` and
the main `kuri` binary forwards `kuri android …` to the
`kuri-mobile` binary.

## When to use this skill

- Enumerate attached Android devices / running emulators.
- Send taps, swipes, long-presses, key events, or text to a phone.
- Capture a PNG screenshot with `screencap -p`.
- Dump the UI tree (via `uiautomator dump`) and act on element refs.
- Launch / terminate Android apps by package name.
- List installed packages.

Do **not** use this skill for:

- iOS — use the `kuri-ios` skill instead.
- Running arbitrary JavaScript on-device (no on-device driver in v1).

## Prerequisites

- `adb` on `$PATH` and an adb server reachable on `127.0.0.1:5037`.
  Install on macOS with `brew install android-platform-tools` then
  run `adb start-server` once.
- A connected device with USB debugging enabled, or a running emulator.
- `kuri-mobile` built and either on `$PATH` or next to the `kuri`
  binary (`zig-out/bin/kuri-mobile`).

## Build

```sh
cd kuri-mobile
zig build
cp zig-out/bin/kuri-mobile ../zig-out/bin/
zig build test    # unit tests: adb framing, uitree parser, usbmuxd plist
```

## Typical flow

```sh
# 1. Confirm adb is reachable and a device is listed
adb start-server
kuri android list-devices
# emulator-5554	device

# 2. Launch an app, wait, screenshot
kuri android launch com.android.chrome
sleep 3
kuri android screenshot chrome.png

# 3. Read the UI as a flat element list
kuri android uitree
# @e0 Button "Sign in" @100,200-980,300 *clickable
# @e1 TextView "Welcome" @40,120-700,180
# ...

# 4. Interact
kuri android tap 540 1200
kuri android swipe 100 1500 100 500 250       # scroll up
kuri android type "hello world"
kuri android press back
```

## Full command surface

| Command | Purpose |
|---|---|
| `kuri android list-devices` | Enumerate via `host:devices` |
| `kuri android tap <x> <y>` | Single tap at coords |
| `kuri android double-tap <x> <y>` | Double tap |
| `kuri android long-press <x> <y> [ms]` | Long press, default 800 ms |
| `kuri android swipe <x1> <y1> <x2> <y2> [ms]` | Swipe / scroll (alias: `scroll`) |
| `kuri android type <text...>` | Type text via `input text` |
| `kuri android press <button>` | `home|back|menu|enter|tab|space|del|volumeUp|volumeDown|power|dpadUp|dpadDown|dpadLeft|dpadRight|dpadCenter` |
| `kuri android screenshot [path.png]` | PNG from `exec:screencap -p` |
| `kuri android uitree` | Flat element list from `uiautomator dump` |
| `kuri android launch <package>` | `monkey -p <pkg> -c LAUNCHER 1` |
| `kuri android terminate <package>` | `am force-stop` |
| `kuri android list-apps` | `pm list packages` |

Global flag: `--serial <id>` — target a specific device. Omit when
exactly one device is attached.

## Native Zig surfaces (honesty)

- `adb` **wire protocol** is re-implemented in Zig. We open a libc
  TCP socket to `127.0.0.1:5037`, speak the 4-hex-digit length
  framing, issue `host:devices`, `host:transport:<serial>`, `shell:`
  and `exec:` services, and read framed or stream responses. We
  never shell out to the `adb` binary at runtime.
- **UI tree parser** is a Zig XML scanner that flattens
  `uiautomator dump` XML into a stable `@e<n>` element list with
  bounds, text, content-desc, resource-id, clickable, enabled.
- Device-side commands (`screencap`, `uiautomator dump`, `input`,
  `monkey`, `am`, `pm`) are Android OS binaries that the device's
  shell runs — we just frame the requests over adb from Zig.

## Intentional limits

- ASCII-only text typing. Non-ASCII needs an IME workaround, not
  bundled.
- No on-device driver, so no `run_code` JavaScript sandbox.
- No bundled emulator image — you provide the device or the emulator.

## Common errors and what they mean

| Message | Fix |
|---|---|
| `could not reach adb server on 127.0.0.1:5037. Is 'adb start-server' running?` | Run `adb start-server`. |
| `no device attached. Plug in a phone with USB debugging enabled, or boot an emulator.` | Connect a device or boot an emulator; confirm with `adb devices`. |
| `adb returned FAIL — see the warning log above for details.` | Check the preceding warn-level log line; usually device state (unauthorized, offline). |
| `unknown button name; see 'kuri-mobile android' for the supported list.` | Use one of the documented button names. |
