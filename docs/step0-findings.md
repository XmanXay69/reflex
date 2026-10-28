# Step 0: feasibility findings (Nikon D780 over USB)

Measured on 2026-10-28 with a Nikon D780 (firmware 1.02) on a MacBook Pro (Apple M5, macOS 27.0.1), using the
`ReflexSpike` app in this repo. Every number below comes from the camera, not from a spec sheet, unless it is
marked as a source quote. Raw logs and JSON reports are written to `spike-output/` (git-ignored).

**Caveat on the cable.** The camera negotiated **USB 2.0 (480 Mb/s)**, not USB 3. The D780 supports USB 3, so the
cable in use is a USB 2-only USB-C cable. Live view needs at most ~16 MB/s, so USB 2 was never the frame-rate
limit, but a USB 3 cable should shave a few milliseconds off each transfer at high JPEG quality.

## TL;DR

| Question | Answer |
|---|---|
| How does the D780 send live view over USB? | Nikon PTP vendor command `GetLiveViewImage` (0x9203): a 384-byte big-endian header plus one baseline JPEG per call. The host polls; there is no push stream. |
| Best resolution | **1024 × 680** (photo live view, 3:2) or **1024 × 576** (movie live view, 16:9). This is a hard ceiling: the size property only offers QVGA / VGA / XGA. |
| Best frame rate | **30.0 fps**, rock steady in photo live view at every size and quality level. |
| Lowest glass-to-glass latency | **56 ms median** (42 min, 67 p90) in photo live view. Movie live view is 112–231 ms depending on the movie mode. |
| Bottleneck | The camera itself: its live-view encoder caps output at 1024 px wide and 30 fps, and its internal pipeline is most of the latency. USB transfer (9–18 ms) and decoding (0.5–4.5 ms) are small. |
| Transport | Apple's ImageCaptureCore PTP passthrough. No libusb, no fighting macOS's camera daemon, no developer account. Needs a one-time **Removable Volumes** permission. |
| In-app camera control | Works during live view: settings change in 10–30 ms without interrupting the stream; autofocus, click-to-focus and manual focus nudging all work. |

## 1. How the D780 exposes live view

- The camera enumerates as USB `04b0:0446` ("NIKON DSC D780"), PTP class, vendor extension `0x0000000A` (Nikon).
- `GetDeviceInfo` lists **81 operations** and **280 device properties** (187 writable). Live-view relevant operations
  are all present: `StartLiveView` 0x9201, `EndLiveView` 0x9202, `GetLiveViewImage` 0x9203, `GetLiveViewImageEx`
  0x9428, `ChangeAfArea` 0x9205, `MfDrive` 0x9204, `AfDrive` 0x90C1, `GetEvent` 0x90C7, `GetEventEx` 0x941C.
- `StartLiveView` + `DeviceReady` polling enters live view in **~120 ms**.
- Each `GetLiveViewImage` returns the most recent frame. Polling faster than the camera's frame clock returns the
  same JPEG again (we polled at 80–100 requests/s and de-duplicate by hashing the JPEG bytes).
- `GetLiveViewImageEx` returns the same JPEG with a **512-byte** header (not 1024 as some open-source code assumes).
  It offers no extra resolution, so the plain command is used.

### Live-view header (verified, D780 fw 1.02)

Big-endian, unlike the rest of PTP. Identical layout in photo and movie live view:

| Offset | Type | Field | Photo LV example | Movie LV example |
|---|---|---|---|---|
| 0 | UINT32 | header length after this field | 376 | 376 |
| 4 | UINT32 | JPEG byte count | 17 239 | 23 334 |
| 8 | UINT16 ×2 | JPEG width, height | 1024 × 680 | 1024 × 576 |
| 12 | UINT16 ×2 | sensor coordinate space (for `ChangeAfArea`) | 6048 × 4024 | 6048 × 3400 |
| 16 | UINT16 ×2 | display area size | 6048 × 4024 | 6048 × 3400 |
| 20 | UINT16 ×2 | display area center | 3024, 2012 | 3024, 1700 |
| 24 | UINT16 ×2 | AF frame size | 285 × 308 | 285 × 308 |
| 28 | UINT16 ×2 | AF frame center | 3024, 2012 | 3024, 1700 |

Later bytes change frame to frame and look like level/tilt angles; they are not decoded yet and the app will not
rely on them. The JPEG is located by scanning for its `FF D8 FF` start marker rather than trusting the offset.

## 2. Resolution and frame rate

### Live-view size (property 0xD1AC: 1 = QVGA, 2 = VGA, 3 = XGA)

The camera resets this to VGA on every new USB session, so the app must set it on connect.

| Live view | QVGA | VGA | XGA |
|---|---|---|---|
| Photo (3:2) | 320 × 212, 30.0 fps | 640 × 424, 30.0 fps | **1024 × 680, 30.0 fps** |
| Movie (16:9), 4K24 mode | 320 × 180, 23.4 fps | 640 × 360, 24.0 fps | 1024 × 576, 24.0 fps |

### Movie live view follows the movie frame-rate setting (property 0xD0A0)

| Movie mode | Live view fps (1024 × 576) | Glass-to-glass latency (median) |
|---|---|---|
| 3840 × 2160 p24 (the camera's setting on arrival) | 23.9 | 231 ms |
| 1920 × 1080 p30 | 30.0 | 213 ms |
| 1920 × 1080 p60 | 29.4 | 143 ms |
| 1920 × 1080 p120 | 23.7 | 112 ms |

Photo live view runs at 30.0 fps no matter which movie mode is selected.

### JPEG quality (property 0xD1BC, 0–5) in photo live view, lit scene

| Level | KB / frame | fps | Transfer RTT p50 / p95 | Decode (ImageIO) |
|---|---|---|---|---|
| 0 (camera default) | 47 | 30.0 | 10.6 / 26.9 ms | 3.1 ms |
| 1 | 98 | 30.0 | 12.3 / 28.9 ms | 3.2 ms |
| 2 | 180 | 30.0 | 14.4 / 30.2 ms | 3.3 ms |
| 3 | 217 | 29.9 | 16.1 / 31.5 ms | 3.8 ms |
| 4 | 323 | 29.9 | 17.5 / 30.7 ms | 4.4 ms |
| 5 | 341 | 29.8 | 17.9 / 31.7 ms | 4.5 ms |

Level 0 visibly smears skin and fabric texture into blocks; level 5 keeps fine detail. In 7-second runs the higher
levels cost ~7 ms of transfer time on USB 2 and nothing in frame rate. (In movie live view, quality 5 dropped the
rate to ~23.5 fps.)

### Sustained run: 12 minutes, photo live view, XGA, quality 5, USB 2

| Metric | Result |
|---|---|
| Average unique frame rate | 27.8 fps |
| Frame interval mean / p95 / σ | 35.9 / 63.3 / 17.0 ms |
| Transfer round trip p95 / max | 37.3 / 156.9 ms |
| Errors, bad frames, decoder drops | 0 / 0 / 0 |
| Live view timed out? | No — ran the full 12 minutes |

Over minutes, quality 5 on a USB 2 cable sits right at the edge: the p95 transfer (37 ms) exceeds the 33 ms frame
budget, so roughly one frame in twenty is skipped. Milestone 2 will pick the default quality from a sustained test
(likely level 3–4 on USB 2) and re-test level 5 on a USB 3 cable.

### Comparison with Nikon Webcam Utility

Nikon's own page for Webcam Utility 1.2.0 states "1024 x 768 pixels (XGA)" and a maximum of "about 10 to 15 fps"
([source](https://downloadcenter.nikonimglib.com/en/download/sw/269.html)). Over the same USB link this approach
delivers **30 fps** — roughly double — at the same ~1024-pixel ceiling. No latency figure for Nikon's utility could
be found or measured here.

## 3. Latency

Method: the spike flips a full-window Metal surface between black and white and records the exact host time each
flip reached the display (`CAMetalDrawable.presentedTime`). The camera films that window. The latency is the time
from presentation to the arrival (over USB) of the first frame whose luma crossed the midpoint. Flips are spaced
randomly (350–750 ms) so they don't phase-lock with the camera's frame clock. 16–24 trials per configuration,
zero timeouts.

It measures **display → sensor → camera processing → USB → host**. It includes the MacBook display's own response
time, and excludes the final step of showing the frame (≈ 1 display refresh, 8–17 ms) and OBS's own frame pacing.

| Configuration | Median | Min | p90 | Max |
|---|---|---|---|---|
| **Photo LV, XGA** | **56 ms** | 42 | 67 | 68 |
| Movie LV 1080p120 | 112 ms | 85 | 150 | 160 |
| Movie LV 1080p60 | 143 ms | 127 | 166 | 169 |
| Movie LV 1080p30 (two runs) | 204–213 ms | 179 | 215–278 | 221–282 |
| Movie LV 1080p30 at VGA size | 203 ms | 179 | 232 | 236 |
| Movie LV 4K24 | 231 ms | 208 | 260 | 265 |

Live-view size makes no difference to latency; the camera's mode does. USB transfer is 9–18 ms of the total,
and JPEG decoding adds 0.5–4.5 ms.

## 4. Pipeline costs on the Mac

JPEG decode of one live-view frame (Apple M5):

| Decoder | 1024 × 576, 22 KB | 1024 × 683, 87 KB |
|---|---|---|
| ImageIO → CGImage | 0.68 ms | 1.85 ms |
| VideoToolbox → BGRA | 0.90 ms | 1.43 ms |
| **VideoToolbox → native 4:2:0 (`420f`)** | **0.50 ms** | **0.78 ms** |

VideoToolbox writes straight into an IOSurface-backed `CVPixelBuffer` that Metal can sample without a copy, so the
whole host-side path (decode, color conversion, crop, publish) fits in a few milliseconds of a 33 ms frame.

## 5. Transport: ImageCaptureCore vs libgphoto2

macOS's camera daemon (`ptpcamerad`) claims every PTP camera. A libusb-based client (libgphoto2, gphoto2,
PTPWebcam's current extension) has to get exclusive access to the USB interface away from that daemon, which in
practice means repeatedly killing it.

ImageCaptureCore's `ICCameraDevice.requestSendPTPCommand(_:outData:completion:)` sends raw PTP operations through the
daemon instead. It worked for everything tried here — device info, property descriptors, get/set, events, live view
at 30 fps — with round trips of 9–18 ms on USB 2. Details that matter:

- The command is a full PTP USB command container; the data phase goes in `outData` as a raw payload; the
  completion returns the inbound payload first and the response container second. The transaction ID is the
  daemon's own (ours is ignored).
- **Permission:** when an app opens a camera, `ptpcamerad` checks the **Removable Volumes** privacy permission
  (`kTCCServiceSystemPolicyRemovableVolumes`) for that app and blocks until the user answers the prompt. Without an
  answer the device never appears. The app ships an `NSRemovableVolumesUsageDescription` so the prompt explains
  itself. In testing, rebuilding the app did not re-trigger the prompt.
- **Accessory security:** on Apple Silicon laptops a never-seen USB device first has to be approved in macOS's
  "Allow accessory to connect?" dialog. Until then it stays half-enumerated and invisible to every app.
- **Connect time:** the first PTP command after opening a session can wait 6–10 s while ImageCaptureCore catalogs
  the memory card. A card with fewer files connects faster.
- Events arrive both ways: `GetEvent` polling (every 250 ms) returns `DevicePropChanged` events, and interrupt
  events (`StorageInfoChanged`, `DevicePropChanged`) arrive through `ptpEventHandler`.

libgphoto2 was not benchmarked: ImageCaptureCore met every requirement, and libgphoto2 would add an LGPL dependency
plus the daemon fight. The transport sits behind a `PTPTransport` protocol, so a libusb/libgphoto2 transport can
still be added later if ever needed.

## 6. Camera control during live view

| Test | Result |
|---|---|
| Set white balance during live view | Applied, set round trip 10 ms, stream uninterrupted, image color changes (red/blue 1.19 → 0.84) |
| Set exposure compensation during live view | Applied, 31 ms, stream uninterrupted |
| ISO change visible in photo live view | **Only with exposure preview on.** Default (0xD1A5 = 0) auto-brightens the preview, so ISO −2 EV changed nothing. With 0xD1A5 = 1 the image follows real exposure. |
| Exposure mode (P/S/A/M) | **Read-only.** The D780 has a physical mode dial. Live view over USB is refused unless the dial is on P/S/A/M. |
| Shutter speed | Read-only in some modes (writable in S and M). |
| Photo vs movie settings | Movie live view uses a separate property set (movie ISO 0xD1AA, shutter 0xD1A8, aperture 0xD1A9, WB 0xD23A, Picture Control 0xD237, focus mode 0xD1FA, AF area 0xD1F8). The control layer must pick the set that matches the live-view selector. |
| `ChangeAfArea` (click-to-focus) | Works in all 5 live-view AF-area modes; the header's AF frame moves to the point (snapped to the camera's grid). Two modes are wide-area (769 × 887 and 1643 × 1100 frame). |
| `AfDrive` (autofocus) | OK, camera ready again after ~180 ms |
| `MfDrive` (manual focus nudge, both directions) | OK |
| Live-view selector (photo/movie) | Read-only: a physical switch on the body. |

## 7. What is not possible over USB on the D780

- **More than ~1024 pixels wide, or more than 30 fps.** The live-view encoder is the ceiling. Upscaling to 720p or
  1080p is possible for apps that insist on standard sizes, but it adds no detail. Clean 1080p60 needs HDMI and a
  capture card (Milestone 6).
- **Changing the exposure mode or the photo/movie selector.** Both are physical controls.
- **Audio.** Live view over PTP carries no audio.

## 8. What changes in the plan

1. **Default to photo live view**, not movie live view: 4× lower latency and a steady 30 fps. Output is center-cropped
   from 3:2 (1024 × 680) to 16:9 (1024 × 576), with a 3:2 option.
2. **Turn on exposure preview** automatically in photo live view, or exposure controls will appear to do nothing.
3. **Default to high JPEG quality** in photo live view, chosen from a sustained test (level 5 skips ~5% of frames on
   USB 2 over 12 minutes; level 3–4 or a USB 3 cable should hold 30 fps).
4. **Set the live-view size to XGA on every connect** (the camera resets it).
5. **Mode-aware controls**: one logical "ISO" control maps to the photo or movie property depending on the selector.
6. **The resolution ceiling is real**, which makes the capture-card path (Milestone 6) the upgrade route for 1080p60.
7. **Recommend a USB 3 cable** (5 Gb/s or better) for the extra transfer headroom at high quality.

## Addendum: findings while building Milestone 2 (same evening, dimmer room)

**Exposure preview controls the live-view frame rate in dim light.** With exposure preview off, the D780 brightens
a dim scene by slowing live view: 14–16 fps, each `GetLiveViewImage` blocking ~50–70 ms until the next frame.
With exposure preview on (0xD1A5 = 1) it holds 30 fps at the chosen exposure (tested at 1/25 s and 1/60 s, and live
view still ran at 30 fps with the shutter set to 1/3 s). In daylight, preview-off live view also ran at 30 fps,
which is why Step 0 didn't see this.

**Switching preview on takes the camera ~9–20 s to settle.** Measured second by second after turning preview on:
`15 16 16 15 14 17 17 17 17 27 30 30 …`. Restarting live view within the same USB session after it had settled
gave 30 fps from the second second; a new session (app relaunch) ramps again. Setting preview before
`StartLiveView` does not skip the ramp. Reflex therefore keeps preview on by default and shows the frame rate, and
the ramp only appears in dim light.

**A frame pacer can't beat flat-out polling here.** `GetLiveViewImage` returns the newest frame, so polling faster
than the camera re-transfers the same JPEG. Timing requests to the camera's clock would save bandwidth, but there is
no cheap "new frame ready" signal: `GetLiveViewCompressedSize` (0x9423) returns a constant 4-byte value and takes
~56 ms. A first pacer that learned the frame period from its own request timing locked onto every other frame
(14 fps). Reflex polls back to back, which holds 30 fps.

**Connect time.** The first command after a session opens waited up to ~8 s on this card. Reflex now allows 45 s for
that first command, retries once, and shows a Try Again button instead of failing.

**Exposure controls work in photo live view** (M mode): shutter (0x500D, 55 values), aperture (0x5007, f/1.8–f/16),
ISO (0x500F, 31 values), Auto ISO (0xD054) and exposure compensation (0x5010) all apply during live view without
interrupting it, and the image follows them with exposure preview on. 0x500D is in whole 1/10 000 s, so 1/160 s
arrives as 62; the app snaps labels to the standard 1/3-stop speeds.
