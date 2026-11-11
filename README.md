# Fluke FC Control

A native macOS (SwiftUI) app that shows the live readings of **Fluke Connect** multimeters and
adapters over Bluetooth Low Energy: big readout, graph window with CSV export, and a connection dialog
for choosing the meter.

![platform](https://img.shields.io/badge/platform-macOS%2026%2B-blue)

> Built with AI for personal use with a specific device on hand (a Fluke 1587 FC): no promised
> support or roadmap. Not affiliated with or endorsed by Fluke. See [Status](#status) for exactly
> what has and hasn't been checked against real hardware.

## What it does

- **Live readout** exactly as the meter's own display shows it: the meter sends counts, decimal places
  and an SI prefix, so the digits (and `mV` / `kΩ` / `MΩ`) match the display, including auto-ranging.
- Names the **function** the meter is set to (DC Voltage, Insulation, Low Ohms, Capacitance…) and shows
  its **qualifier** as a badge: Short circuit, Open circuit, Good diode, **Hazardous voltage**…
- A **second line** when the device sends one, for example an insulation test's test voltage.
- `OL`, `----` and similar states are shown the way the meter shows them. If the stream stops (meter asleep or
  out of range), the last value stays on screen, dimmed, with a note, instead of blanking it.
- **Several meters at once.** Every meter you add connects independently and gets **its own window**.
  Merge them into one tabbed window with Window → Merge All Windows. Each meter
  has its own **ID#**: the lowest free number (1, 2, 3…), stored with the meter so it stays the same across
  launches. It is written to the meter, which shows it on its display, and the window title reads
  "FLUKE 1587FC · ID# 2" so a window and a meter on the bench can be matched. Closing a meter's window
  disconnects that meter (a meter holds only one connection, and shouldn't be tied up by a window you can't see);
  quitting keeps the meters you had open, and they reconnect at the next launch.
- **Graph window** per meter (Start / Stop / Clear / Export CSV) with min / max / average, over-range readings
  drawn as gaps and exported as `OL`. Values are recorded in base units (V, A, Ω), so auto-ranging
  doesn't distort the chart. Recording stops by itself if the meter changes to a different measurement.
- **Connection dialog** (the Bluetooth button in a meter window; also the content of File → New Window):
  your saved meters, each with its ID#, serial number and firmware (remembered, so they show while the meter
  is off), with Open / Connect, and Disconnect / Reconnect / Forget in the "…" menu; and Fluke devices in
  range (Add, which opens the new meter's window). If exactly one device advertising the Fluke service is in
  range on first launch, it is added automatically. An "Other Bluetooth devices" section lists any named
  device, in case a meter doesn't advertise the Fluke service.
- Reconnects by itself when the link drops or the meter wakes up again.
- **Localized** into English, German, Spanish, Catalan, French, European Portuguese, Brazilian Portuguese,
  Dutch, Italian, Polish, Czech, Danish, Swedish, Norwegian (Bokmål), Finnish, Chinese (Simplified), Japanese
  and Korean, following the Mac's language. Not translated, on purpose: what the meter itself shows (`OL`,
  `----`, units such as `mV` and `MΩ`), device names, `ID#`, and the unit label on the graph (`V DC`).
- **Diagnostics** (app menu → Diagnostics… for the meter in front): every service and characteristic the device
  offers, and each reading's raw bytes next to what the app decoded. *Copy* puts the whole log on the clipboard;
  the full log of all meters (lines marked with their ID#) is also kept in `~/Library/Logs/Fluke FC Control/`.

### What it deliberately doesn't do

- **No HOLD / MIN MAX / AVG indicator, because the meter doesn't say.** Checked on the 1587 FC: pressing HOLD
  or stepping through MIN MAX AVG changes nothing in the reading record (its range, decade, attribute and
  capture bits stay constant) or in any of the meter's other characteristics, which were watched while the
  buttons were pressed. The meter simply keeps streaming whatever its display shows, so a held or min/max
  value looks exactly like a live one (Fluke's own app behaves the same). Guessing from "the value stopped
  changing" would be wrong for any steady signal. (Diagnostics has a switch to watch those characteristics
  again, in case a future firmware exposes something.)
- **No control.** There is nothing to set from the Mac: as far as anyone has
  published, Fluke Connect meters only *stream* their display. Function and range are chosen on the
  meter. The one thing the app writes is its **connection ID** (one byte, shown as *ID#* on the meter's
  display, like Fluke's own app); it resets when the link drops. There is no other write path.
- No download of logged/saved measurements (the protocol notes don't cover it).
- No firmware update support, and none of those characteristics are ever touched.

## Using it

> A meter accepts **one** connection at a time. Don't run a `--probe` (or a second copy of the app, or Fluke
> Connect on a phone) while another session is connected: they take the slot from each other.

1. Turn **Bluetooth on at the meter** (Fluke Connect symbol on its display) and keep it near the Mac.
2. **Close Fluke Connect on your phone**: a meter talks to one app at a time.
3. Open the app. Fluke devices advertise slowly (about every 10 s), so finding one can take a moment.
4. Click *Add* next to your meter. Its window opens and readings start immediately; there is no pairing step.
5. For more meters, click the Bluetooth button in any meter window and *Add* the next one: it gets the next ID#.

Closing the last window quits the app.

Only ID# 1 has been checked on real hardware so far (there was one meter to test with). The number is a plain
byte written to the same characteristic, so other numbers should behave the same, but that is untested.

## Status

**Confirmed on a real Fluke 1587 FC (2026-11-10), for the read path.** A probe found the meter
by its advertised service, connected without pairing, subscribed to the reading characteristic and decoded
live readings that matched the meter's display (AC mV settling from 5.8 to 5.1 mV), plus model, serial,
and firmware. The full capture, including the meter's whole GATT table, is in
[docs/1587FC-capture.md](docs/1587FC-capture.md).

**The connection has been stable in use.** Early on, the link sometimes died about 30 s after connecting while
CoreBluetooth still reported "connected", with a stray `didConnect` at the same moment. What fixed it, and what
the app does now: (a) it writes the connection ID so the meter shows *ID#*, (b) it reuses a link that is
already up instead of cancelling and reconnecting (cancelling back-to-back made the meter drop each new link
within seconds), (c) it rebuilds its session on top of a link the system re-established, and (d) when
readings stop, it polls the reading characteristic and reconnects if it gets no answer. If it ever drops, *Copy*
the Diagnostics log; the timestamps around the drop are what's needed.

Also confirmed on the 1587 FC: DC voltage and millivolts, resistance, continuity, and the **insulation test**
(the voltage-detection and spot-test phases, readings into the gigaohms, and the **test voltage on the second
line**).

Not yet checked on hardware: a session of many hours, reconnecting after the meter has fully gone to sleep, and
the function codes the 1587 FC can produce that haven't come up yet (polarization index, DAR; the rest of the
installation-tester and pressure codes belong to other models). Those names come from a community table.

The Fluke Connect protocol is not published by Fluke. This app is built on community reverse-engineering;
three independent sources agree on the parts used here:

| Source | Tested on |
|---|---|
| [`jwanga/fluke-connect-client`](https://github.com/jwanga/fluke-connect-client) (Rust) | ir3000 FC adapter + Fluke 289 |
| [`FrostFlops/open289`](https://github.com/FrostFlops/open289) (Python) | ir3000 FC adapter + Fluke 289 |
| [`AntoineMugnier/mutekh`](https://github.com/AntoineMugnier/mutekh/tree/master/libble/profile/fluke) (C profile) | Fluke BLE module family, source only |

What they agree on, and what this app relies on (the 1587 FC matches all of it):

- Service `B6981800-7562-11E2-B50D-00163E46F8FE` (advertised by the device).
- Characteristic `B698290F-…`, *notify*: 8 bytes per notification (16 on the ir3000 FC: primary +
  secondary). Two little-endian 32-bit words:
  - word 0: bits 0–20 counts (`0x1FFFFF` = none), 21–24 state, 25–27 decimals, 28–30 SI prefix, 31 sign
  - word 1: bits 0–7 unit, 8–15 function, 16–22 range, 23–25 decade, 26–30 attribute, 31 capture flag
- No pairing or bonding. Writing a connection ID to `B6982902-…` (one byte, resets on disconnect) and subscribing
  to notifications is the whole handshake. Without the ID the 1587 FC streams for a while and then drops the
  connection (and its display never shows *ID#*), so the app writes `1` there on every connection, first.

The 1587 FC also has two services (`B6981802-…`, `B6981803-…`) that none of those projects document. The
app only *reads* their readable characteristics once into the Diagnostics log; it never subscribes to or
writes anything there. The ASCII display characteristic (`B6982901`) is implemented only as a fallback,
from public clamp-meter captures; the 1587 FC exposes it too but streams on the binary one.

If something doesn't look right on your meter, open **Diagnostics…** and *Copy* the log: it has the
services the meter offers and the raw bytes of every reading next to what the app decoded.

The decoder (`FlukeCore`) is covered by 30 unit tests built from published capture vectors, including
hand-checked bit math.

### Hardware probe

To test without opening the UI (launch the bundle with `open -n`, so the Bluetooth permission is
attributed to the app, not the shell):

```bash
open -n "Fluke FC Control.app" --args --probe /tmp/fluke-probe.txt
```

It scans for ~25 s, connects to the strongest Fluke-looking device, listens ~75 s, writes
a report (devices seen, GATT table, raw and decoded readings, reading count) to that file and quits. Nothing is saved.

### Demo mode

`--demo` runs two simulated meters (ID# 1 and 2, no Bluetooth) in their own windows, cycling through typical
readings; `--demo --scenario <n>` holds one; `--demo --render <dir>` renders the main views to PNGs and quits.
With the environment variable `FLUKE_CHECK_WINDOWS=<file>` the demo reports its windows and titles, merges them
into tabs, closes them one by one and writes what happened (the path goes in an environment variable because
AppKit treats a path on the command line as a file to open, and then opens no windows):

```bash
open -n --env FLUKE_CHECK_WINDOWS=/tmp/windows.txt "Fluke FC Control.app" --args --demo
```

## Requirements / building

macOS 26+, Swift 6 language mode, SwiftPM only (no Xcode project).

```bash
./build_app.sh        # release build → "Fluke FC Control.app" (ad-hoc signed)
./test.sh             # FlukeCore unit tests (Command-Line-Tools-only Macs need the flags in here)
python3 Tools/check_localization.py   # every language file: same keys, same format specifiers, valid syntax
```

### Localization

Strings are ordinary `Text("…")` / `String(localized: "…")` literals; the English text is the key. The 17
translations live in `Localization/<code>.lproj/Localizable.strings` and `build_app.sh` copies them into the
bundle. To add or change a string, edit `Localization/en.lproj/Localizable.strings` and the other files, then run
`python3 Tools/check_localization.py`. The Swift compiler can list every localizable string in the code (it
is how the 186 keys were collected):

```bash
swift build -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc /tmp/strings
```

### First launch (Gatekeeper)

The app is ad-hoc signed, not notarized. If macOS refuses to open a copy that was downloaded or moved
from another Mac: System Settings → Privacy & Security → *Open Anyway*, or

```bash
xattr -dr com.apple.quarantine "Fluke FC Control.app"
```

The first launch also asks for Bluetooth permission; allow it, or enable it later under System Settings →
Privacy & Security → Bluetooth.

## Layout

```
Sources/FlukeCore/        pure protocol layer: UUIDs, reading decoding, code tables, device info, ID# assignment
Sources/FlukeFCControl/   the app
  BLETransport.swift        CoreBluetooth wrapper: shared central, per-meter link, reads plus the one connection-ID write
  FlukeMeter.swift          one meter: ID#, connection loop, latest reading, graph recorder, diagnostics log
  FlukeHub.swift            saved meters, ID# assignment, discovery, persistence, window bookkeeping
  Windows.swift             per-meter window (claims its meter), picker window, graph/diagnostics windows, close tracking
  GraphRecorder.swift       recording, statistics, CSV export
  DiagnosticsFile.swift     the log file in ~/Library/Logs
  MeasurementCardView.swift / ContentView.swift / ConnectionView.swift / GraphView.swift / DiagnosticsView.swift
Localization/<code>.lproj/  Localizable.strings per language (copied into the bundle by build_app.sh)
Tests/FlukeCoreTests/     decoder tests from published vectors
docs/1587FC-capture.md    the first real capture from a 1587 FC
Tools/make_icon.swift     renders the icon
Tools/check_localization.py  checks the language files against English
```

## License

MIT, see [LICENSE](LICENSE).
