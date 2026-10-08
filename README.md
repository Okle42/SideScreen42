# SideScreen42 — use any laptop with a browser as a wireless extended display for your Mac

Part of the **42 series** by [Okle42](https://github.com/Okle42) — follow for more tools that actually ship.

[繁體中文說明](README.zh-TW.md)

**In one line: the Mac creates a real virtual display, streams it as hardware H.264 over your home Wi‑Fi, and the laptop next to it shows it full-screen in a browser tab. It shows up in System Settings like a real monitor: you can arrange it and drag windows onto it.**

I had a Surface Laptop 2 sitting next to my Mac mini doing nothing. Its Mini DisplayPort can only send video out, not take it in, so a cable won't work. Commercial apps exist, but I wanted something small enough to read in one sitting, with no installer on the Windows side, and that costs nothing while nobody is watching.

![macOS](https://img.shields.io/badge/macOS-14%2B-lightgrey) ![Swift](https://img.shields.io/badge/Swift-5.9%2B-orange) ![deps](https://img.shields.io/badge/dependencies-0-brightgreen) ![license](https://img.shields.io/badge/license-MIT-green)

---

## How it works

```
 Mac (sender, this repo)                           Laptop (receiver)
┌───────────────────────────────────┐            ┌──────────────────────────────┐
│ CGVirtualDisplay  virtual monitor │            │ Edge / Chrome, full screen   │
│   ↓                               │            │   ↑                          │
│ ScreenCaptureKit  NV12 + cursor   │ WebSocket  │ WebCodecs VideoDecoder (HW)  │
│   ↓                               │ ─────────► │   ↑                          │
│ VideoToolbox  H.264 High, no B    │   :8765    │ receiver/index.html          │
│   ↓                               │ ◄───────── │ hello / keyframe requests    │
│ Network.framework  WebSocket      │            │                              │
└───────────────────────────────────┘            └──────────────────────────────┘
```

- **Sender**: a Swift package using Apple frameworks only, no third-party dependencies: a shared core (`SideScreenCore`), a **menu bar app** (`SideScreen42.app`) and a command-line tool (`sidescreen`). It builds with the Command Line Tools; you don't need an Xcode project.
- **Receiver**: a single HTML file. Open it from disk in Edge or Chrome (`file://` counts as a secure context, so WebCodecs works). Nothing to install on the laptop, and it isn't tied to Windows.

## Measured

Mac mini M4, macOS 27.0.1. The receiver is a Surface Laptop 2 (i5‑8250U, Intel UHD 620) running Edge 154. The display is 2256 × 1504, streamed at up to 60 fps.

Sender cost, from `tools/bench.sh`: 20 s idle, then 20 s with a full-screen 60 fps test pattern (`tools/testpattern.swift`) and a local client. CPU is a percentage of one core, from `ps` cumulative CPU time.

| | before tuning | after tuning |
|---|---|---|
| CPU, nobody connected | 1.8 % | **0.1 %** |
| CPU, streaming 60 fps | 5.8 % | 5.7–6.1 % |
| Frames delivered at 60 fps content | 57.5 fps | **60.0 fps** |
| Encode time per frame (avg / max) | — | **9.0 / 10.7 ms** |
| Socket hand-off → sent, worst frame | — | **≤ 1 ms** (local) |
| Memory (RSS) | 44 MB | 44 MB |

Encode and send times are measured inside the process with one monotonic clock. Across Wi‑Fi, the "worst frame" figure is what tells you if the network stalled.

**A correction.** The first version of this README said "capture → frame on the socket, 1.2 ms". That number came from comparing each frame's timestamp with the local client's clock. ScreenCaptureKit's timestamp turned out to carry an offset that drifts over time (the same build read −4 ms a few hours later), so the absolute value was wrong. The real Mac-side cost is about 10 ms: encode plus send. The before/after comparison still holds, because both runs shared the same offset: fixing the capture interval removed about 8 ms of p95 jitter. I also tried the regular hardware encoder (`ave.avc`) instead of the low-latency one (`h264.rtvc`): 15–16 ms per frame, slower, so the low-latency one stays.

Receiver side (Edge on the Surface, reported by its own stats): hardware decoding, **1–2 ms per frame** (about 43 ms for the very first keyframe), no decode errors, no dropped frames in the test run.

**Not measured yet:** true glass-to-glass latency across Wi‑Fi. The two machines' clocks aren't synchronised, so that needs a slow-motion phone video of both screens. Subjectively, dragging windows feels immediate.

### From a night of real use

The log of one 4-hour evening (one connection, never dropped):

- The screen was mostly still: median capture rate **3 fps**, average 8.4. Idling when nothing changes is where the savings are.
- 438 frames were dropped by the sender's backpressure, in 43 five-second windows, clustered in a few busy minutes. A few happened at only 2–3 fps, which means a single frame sat on Wi‑Fi for over a second. That looks like the laptop's Wi‑Fi power saving, not the Mac.
- The log exposed a bug: when backpressure dropped a frame, the keyframe request **re-encoded the last (stale) frame as an extra keyframe**, the largest kind of frame, at exactly the moment the network was congested. Now the next fresh frame becomes the keyframe, and the stale frame is re-encoded only if nothing new arrives within 50 ms (a static screen).
- The stats line now records keyframes, encode time and the slowest send, and only logs when something is moving (plus a heartbeat), so a whole night stays readable.

### What the tuning was

1. **Idle when nobody is watching.** With no client connected, nothing is encoded and capture drops to 2 fps, just enough to always hold the latest frame. When a client connects, capture goes back to 60 fps and that held frame is encoded as a keyframe right away, so the picture appears in about 40 ms even if the screen is static.
2. **Capture interval 10 % looser than 1/fps.** With `minimumFrameInterval` set to exactly 1/60 s, tiny jitter in display timing made ScreenCaptureKit skip about 4 % of frames, and the skipped frames delayed the ones after them. The display still caps capture at 60 Hz. This one change removed about 8 ms of p95 jitter.
3. **Zero-copy packet assembly.** The encoder writes the 9-byte header, SPS/PPS and the Annex B body straight into the final WebSocket message. Before, it was copied twice.
4. **`serviceClass = .interactiveVideo`** on the socket, so Wi‑Fi (WMM) puts it in the video queue.
5. **Backpressure.** If 3 frames are still unsent, non-key frames are dropped and the next frame is forced to a keyframe. It drops frames rather than letting latency build up.

## Run it

### Menu bar app

```bash
git clone https://github.com/Okle42/SideScreen42.git
cd SideScreen42
scripts/make-app.sh          # builds, signs and installs /Applications/SideScreen42.app, then opens it
```

The first time, macOS asks for **Screen & System Audio Recording** permission for SideScreen42. Allow it and choose **Quit & Reopen**. After that the app starts sharing on its own.

The menu bar icon shows the state by shape: one display = sharing, waiting for a viewer; two displays = someone is watching; crossed out = stopped. The menu has the current viewer and fps, **Copy receiver address**, **Stop / Start sharing**, **Show receiver page in Finder**, About, Settings… (⌘,) and Quit.

Settings: resolution, bitrate, port (changing them restarts sharing; the receiver reconnects by itself), **Open at Login** (off by default), start sharing when the app opens, show in menu bar, and the log file (`~/Library/Logs/SideScreen42/sidescreen.log`, appended, rotated at 5 MB).

The script signs with your Apple Development or Developer ID certificate if you have one, so the Screen Recording permission survives rebuilds. Without one it signs ad hoc, and you may have to allow it again after each rebuild.

### Command line

```bash
swift build -c release
.build/release/sidescreen
```

It prints something like:

```
➜ 在接收端連線：ws://192.168.1.20:8765/stream
```

### On the laptop

Open `receiver/index.html` in Edge or Chrome, paste that address and press Connect. Press **F** (or double-click) for full screen, **S** for stats, **C** to show or hide the connection panel. The address is remembered, and the page reconnects on its own.

Then open **System Settings → Displays → Arrange** on the Mac and drag `SideScreen (Surface)` to where the laptop physically sits. macOS remembers the position, because the virtual display always uses the same serial number.

Command-line Options:

| | |
|---|---|
| `--port 8765` | WebSocket port |
| `--bitrate 12` | average bitrate in Mbps (peaks capped at 1.5×) |
| `--fps 60` | frame rate |
| `--mode 1504x1003` | default mode in points (HiDPI): `1504x1003` looks like Windows at 150 %, `1128x752` is pixel-exact and sharpest, `1880x1253` gives more room |
| `--dump out.h264` | also write the raw stream to a file (`ffplay out.h264`) |

Quitting (or Ctrl+C) removes the virtual display, and its windows move back to your other screens. If capture is stopped from outside (for example the **Stop Sharing** button in the macOS menu bar, which names the app that is recording), it restarts after 3 seconds. To actually stop, use **Stop sharing** in the menu, or Ctrl+C for the command-line tool.

### Permissions

- **Screen Recording**: System Settings → Privacy & Security → Screen & System Audio Recording. Allow SideScreen42, or for the command-line tool the terminal app you run it from (Terminal, Ghostty, iTerm…).
- **Firewall**: allow incoming connections if macOS asks the first time.

### Tests and tools

| | |
|---|---|
| `node tools/test_client.mjs ws://<ip>:8765/stream` | protocol self-test: config before the first frame, first frame is a keyframe with SPS/PPS/IDR, `codec` string matches the SPS, monotonic timestamps, keyframe-on-request, reconnect |
| `tools/bench.sh` | the CPU / memory / encode-time measurement above |
| `swift tools/testpattern.swift 20` | full-screen 60 fps test pattern on the virtual display for 20 s (a moving bar, 60 blinking cells for counting dropped frames, a millisecond clock) |

## Protocol

It's small enough to write a receiver in any language. See [docs/PROTOCOL.md](docs/PROTOCOL.md).

## Limits

- **`CGVirtualDisplay` is a private CoreGraphics API.** The package targets macOS 14+, but I have only tested it on macOS 27.0.1, and Apple could change the API in any release. The declarations are in `Sources/CVirtualDisplay/include/CGVirtualDisplay.h`, checked against the Objective‑C runtime on macOS 27.0.1.
- **One way only.** Touch, mouse and keyboard on the laptop are not sent back. The Mac's own mouse and keyboard drive the extended display.
- **No audio, no encryption, no password.** It's meant for a home LAN. Anyone on the same network who knows the port can watch, so don't run it on public Wi‑Fi.
- **One viewer.** A new connection replaces the old one. If two receiver tabs are open, they keep kicking each other off.
- **The WebSocket path isn't checked.** Network.framework doesn't expose the request path, so any path connects.
- The receiver page's UI text is Traditional Chinese.

## How it was built

Two Claude Code sessions built it in one afternoon, one on each machine. The Windows session checked the laptop's real specs, wrote a handoff document with the protocol and division of labour, and built the receiver. The Mac session built the sender. They talked only through Markdown files in a shared folder, which the Mac side reached over SSH: a handoff, a report, and a reply. Each side caught a bug in its own half from the other side's test data. The receiver was dropping the first keyframe because it arrived before the decoder was configured. The sender let a half-open connection replace a working one.

## Credits

The virtual display approach and the private-API declarations follow [DeskPad](https://github.com/Stengo/DeskPad) by Stengo (MIT).

## License

MIT © 2026 Okle42
