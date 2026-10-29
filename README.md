# Reflex

Turn a Nikon D780 into a low-latency webcam on macOS, with full camera control in the app.

Reflex pulls live view from the camera over USB-C, renders it with Metal, and shares it with OBS through Syphon.
OBS's Virtual Camera then carries it to Zoom, Discord and browsers. No capture card and no Apple Developer account
are needed.

> **Status: Milestone 2 (viewfinder and live view) in testing**, with exposure controls pulled forward from
> Milestone 3. See [the Step 0 findings](docs/step0-findings.md) for what the D780 can actually do over USB.

## What it does (and will do)

- **Live view over USB** at the camera's ceiling: **1024 × 680 at 30 fps** in photo live view, measured at
  **~56 ms** glass-to-glass. That is about twice the frame rate Nikon quotes for its own Webcam Utility (10–15 fps).
- **Camera control in the app:** ISO, shutter, aperture, exposure compensation, white balance (presets and Kelvin),
  Picture Control, autofocus mode and area, click-to-focus, manual focus nudging. Only controls the camera reports
  are shown.
- **Picture:** live-view JPEG at the camera's highest quality, optional MetalFX-upscaled 1080p with
  contrast-adaptive sharpening, white balance and Picture Control applied in the camera.
- **Focus:** autofocus (⌘F) and click-to-focus on the viewfinder, with the camera's AF box shown.
- **Output:** Syphon → OBS (default); optional virtual camera later.
- **Viewfinder:** large Metal preview with toggleable grid, center cross, histogram, focus peaking, zebras and
  safe-area guides, plus a status bar (fps, latency, resolution, battery, connection).
- **Later:** a capture-card source for clean 1080p60 over HDMI while still controlling the camera over USB.

## Requirements

- macOS 14 or later, Apple Silicon recommended (developed on an M5, macOS 27).
- Xcode 26 and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).
- A Nikon D780 (other Nikon bodies with PTP live view may work, untested), a USB-C cable — ideally USB 3 — and
  OBS Studio 32 or later for streaming.

## Build and run

```bash
git clone https://github.com/XmanXay69/reflex.git
cd reflex
xcodegen generate
xcodebuild -project Reflex.xcodeproj -scheme Reflex -derivedDataPath build build
open build/Build/Products/Debug/Reflex.app
```

Shortcuts: ⌘L live view on/off, ⌘F autofocus, ⇧⌘S save frame, ⌥⌘S show/hide controls, ⇧⌘L measure latency.
Click the picture to focus there. **Quick setup** (Exposure section) sets f/2.8, a flicker-free shutter speed,
Auto ISO, and focuses.

Camera setup:

1. Mode dial on **P, S, A or M** (the camera refuses USB live view in AUTO and scene modes).
2. Live view selector on **photo** for the lowest latency.
3. Plug in, switch on. On first connect macOS asks to **allow the accessory**, then asks whether the app may
   **access removable volumes** — allow both (see [signing.md](docs/signing.md) for why).

Run the tests:

```bash
scripts/test.sh
```

### The spike app

`ReflexSpike` is the measurement tool used for Step 0. It can probe every camera property, benchmark live-view
sizes, quality levels and movie modes, change settings, and measure glass-to-glass latency with a flashing target.
It writes JSON reports to `spike-output/`. It can run unattended:

```bash
open build/Build/Products/Debug/ReflexSpike.app --args \
  --auto=probe,lv,bench,setting,decode,soak --out=$PWD/spike-output/my-run --quit
```

## Signing

| | Free (no account) | Paid Apple Developer Program |
|---|---|---|
| Build and run Reflex on your Mac | ✅ ad-hoc signed | ✅ |
| Syphon → OBS → Virtual Camera → Zoom/Discord/browsers | ✅ | ✅ |
| Capture-card source | ✅ | ✅ |
| Reflex as its own camera (CoreMediaIO extension) | ❌ entitlement not available | ✅ |
| Distribute to other people without warnings | ❌ (they must "Open Anyway") | ✅ Developer ID + notarization |

Details and step-by-step instructions: [docs/signing.md](docs/signing.md).

## Known limitations

- **USB live view tops out at ~1024 pixels wide and 30 fps.** That's the camera's live-view encoder, not the cable
  or the Mac. 1080p60 needs HDMI and a capture card.
- **Photo live view is 3:2**; Reflex crops to 16:9 (1024 × 576) by default.
- **Movie live view is much slower** (112–231 ms, depending on the movie mode) than photo live view (56 ms).
- **Exposure mode and the photo/movie selector are physical controls** and can't be changed from the Mac.
- **No audio** over USB live view.
- The first connection can take 6–10 s while macOS catalogs the memory card.
- **In dim light, live view needs about 10–20 s after connecting to reach 30 fps**, while the camera settles into
  exposure preview. Turning exposure preview off makes the camera brighten the picture itself, but then it runs at
  ~15 fps in dim light.
- Long sessions are limited by the battery; for long streams use a mains adapter (Nikon EP-5B power connector + EH-5 series adapter).

## Roadmap

1. ✅ **Feasibility spike**: PTP layer, live view, measurements ([findings](docs/step0-findings.md)).
2. 🧪 **Viewfinder and live view**: Metal pipeline, VideoToolbox decode, status bar, latency test.
3. **Camera controls**: exposure, white balance, Picture Control, autofocus, click-to-focus (done early) · AF mode
   and area, manual focus nudging, disconnect polish.
4. **OBS output**: Syphon server (NDI only if a network use case comes up).
5. **Polish**: presets ("Desk Stream", "Low Light", "IRL"), overlays, keyboard shortcuts, menu bar toggle.
6. **Capture-card source**: UVC/HDMI input behind the same `VideoSource` protocol, camera control kept on USB.
7. **Optional virtual webcam**: CoreMediaIO camera extension (needs the paid program to activate).

Architecture: [docs/architecture.md](docs/architecture.md).

## License

MIT. See [LICENSE](LICENSE). Nikon and D780 are trademarks of Nikon Corporation; this project is not affiliated
with Nikon.
