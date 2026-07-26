---
name: kuri-android
description: Use kuri-android to drive Android devices and emulators from the CLI via a native Zig adb wire-protocol client. Read the screen with `state` (foreground app plus every actionable element, with tap-ready coordinates), tap by selector (--label/--id/--class/--desc/--index) rather than raw coordinates, swipe (scroll), double-tap, long-press, type text with --clear to replace a field, press hardware/navigation keys, take PNG screenshots, dump the UI tree, read notifications, launch/terminate apps by package, list installed packages, and list attached devices. Talks adb directly over TCP 127.0.0.1:5037 — never shells out to the `adb` binary at runtime. Trigger phrases include "tap on android phone", "screenshot the emulator", "list connected android devices", "dump the android ui tree", "what's on the android screen", "launch chrome on android".
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

# 3. Read the screen — start here, not with uitree
kuri android state
# app     mCurrentFocus=Window{... com.android.settings/.Settings}
# screen  Physical size: 1080x2400
# @e4  LinearLayout id=search_action_bar text=Search Settings  tap=540,178
# @e19 LinearLayout id=  text=Network & internet Mobile, Wi-Fi, hotspot  tap=540,666
# @e12 RecyclerView id=recycler_view text=  tap=540,1326  *scrollable

# Full tree when you need static labels too; --interactive trims it
kuri android uitree                 # everything meaningful (72 rows on Settings)
kuri android uitree --interactive   # only what can be acted on (14 rows)

# 4. Interact — prefer selectors over raw coordinates
kuri android tap --label "Network & internet"
kuri android tap --id search_action_bar
kuri android tap --class Button --index 1     # 2nd Button on screen
kuri android swipe 100 1500 100 500 250       # scroll up
kuri android type --clear "hello world"       # replaces the field's contents
kuri android press back
```

Coordinates shift between devices and after any layout change; a selector
survives both. `tap 540 1200` is still there for when you genuinely have a
point rather than an element.

## Full command surface

| Command | Purpose |
|---|---|
| `kuri android list-devices` | Enumerate via `host:devices` |
| `kuri android state` | Foreground app + screen size + every actionable element (alias: `snapshot`) |
| `kuri android uitree [--interactive]` | Flat element list from `uiautomator dump` |
| `kuri android find <selector>` | Matching elements with tap-ready centroids; non-zero exit on no match |
| `kuri android wait-for-ui --label <t>` | Block until an element appears (`--absent` to invert) |
| `kuri android notifications [--open]` | Read posted notifications; `--open` pulls the shade down |
| `kuri android current-activity` | Package/activity holding focus |
| `kuri android screen-info` | Physical size and density |
| `kuri android logcat [--last N] [--predicate T]` | Bounded log read |
| `kuri android getprop <name>` / `dumpsys <section>` | Raw system state |
| `kuri android tap <x> <y>` / `tap <selector>` | Tap a point or a resolved element |
| `kuri android double-tap <x> <y>` | Double tap |
| `kuri android long-press <x> <y> [ms]` | Long press, default 800 ms |
| `kuri android swipe <x1> <y1> <x2> <y2> [ms]` | Swipe / scroll (alias: `scroll`) |
| `kuri android gesture <x,y> <x,y> ...` | Multi-point drag via `input motionevent` (alias: `drag`) |
| `kuri android touch <down\|up\|move> <x> <y>` | Raw motion phase |
| `kuri android type <text...> [--clear]` | Type text; `--clear` replaces the field |
| `kuri android press <button>` | `home\|back\|menu\|enter\|tab\|space\|del\|recents\|volumeUp\|volumeDown\|power\|dpadUp\|dpadDown\|dpadLeft\|dpadRight\|dpadCenter` |
| `kuri android keyevent <KEYCODE_*>` | Raw keycode |
| `kuri android wait <ms>` | Sleep; needs no device |
| `kuri android batch <action> ...` | Several actions over one adb session |
| `kuri android screenshot [path.png]` | PNG from `exec:screencap -p` |
| `kuri android launch <package>` | `monkey -p <pkg> -c LAUNCHER 1` |
| `kuri android terminate <package>` | `am force-stop` |
| `kuri android openurl <url>` | VIEW intent (alias: `navigate`) |
| `kuri android list-apps` / `uninstall <pkg>` / `clear <pkg>` | Package management |

`kuri android tools --json` is the machine-readable version of this table and
is generated from the same source, so it cannot drift from the dispatcher.

Global flag: `--serial <id>` — target a specific device. Omit when
exactly one device is attached.

### Selectors

`find` and `tap` accept `--label`, `--id`, `--class`, `--desc` and `--index`,
AND-ed together so each one narrows the match:

- `--label` searches text, resource-id and content-desc at once
- `--id` takes either the short `btn_login` or the full
  `com.example.app:id/btn_login`; listings print the short form
- `--index N` picks the Nth match (0-based) when a selector is ambiguous —
  `find` prints the ordinal in its first column
- `--interactive` restricts to elements that can actually be acted on

### Element flags

`state` and `uitree` mark what an element's label cannot tell you:
`*clickable`, `*long-clickable`, `*scrollable`, `*checked` / `*unchecked`,
`*password`, `*focused`, `*selected`, `*disabled`.

## Native Zig surfaces (honesty)

- `adb` **wire protocol** is re-implemented in Zig. We open a libc
  TCP socket to `127.0.0.1:5037`, speak the 4-hex-digit length
  framing, issue `host:devices`, `host:transport:<serial>`, `shell:`
  and `exec:` services, and read framed or stream responses. We
  never shell out to the `adb` binary at runtime.
- **UI tree parser** is a Zig XML scanner that turns `uiautomator dump`
  XML into a stable `@e<n>` element list with bounds, text,
  content-desc, resource-id and the interactivity/state attributes.
  It tracks nesting, so a clickable row whose label lives in child
  `TextView`s is named from those children — that layout is everywhere
  on Android and such rows are otherwise unaddressable by label.
  Attribute values are XML-decoded, so "Network & internet" matches the
  string actually on screen rather than `Network &amp; internet`.
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
