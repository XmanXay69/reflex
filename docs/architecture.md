# Architecture

Status: proposed after the Step 0 spike (see [step0-findings.md](step0-findings.md)). Milestone 1 implements the
`ReflexPTP` layer and the spike; the rest is the plan for milestones 2–7.

## Goals that drive the design

1. **Lowest latency.** Never queue frames. Every stage keeps at most one frame in flight and drops stale ones.
2. **Swappable edges.** The camera transport, the video source and the output sinks each sit behind a protocol, so
   USB live view, a capture card, Syphon, NDI or a camera extension can be swapped without touching the rest.
3. **Honest controls.** The UI is built from what the camera reports (`GetDevicePropDesc`), not from a hard-coded
   list, so it never shows a control the body can't apply.

## Modules

```
┌────────────────────────── Reflex.app (SwiftUI) ──────────────────────────┐
│  Viewfinder (MTKView) · Side panel · Status bar · Menu bar item · Presets │
└───────────────┬───────────────────────────────┬──────────────────────────┘
                │ observes / sends intents      │ frames (MTLTexture)
┌───────────────▼──────────────┐   ┌────────────▼───────────────────────────┐
│ CameraService                │   │ VideoPipeline                          │
│  CameraControlling protocol  │   │  decode (VideoToolbox → IOSurface)     │
│  NikonPTPCamera              │   │  Metal: YUV→RGB, crop 3:2→16:9, scale  │
│   • property catalog         │   │  latest-wins frame clock, stats        │
│   • photo/movie mapping      │   │  preview overlays (never in output)    │
│   • events, presets          │   └───────▲──────────────────┬─────────────┘
└───────────────┬──────────────┘           │ frames           │ output texture
                │                  ┌───────┴───────────┐ ┌────▼──────────────┐
                │                  │ VideoSource       │ │ OutputSinks       │
                │                  │  USBLiveView      │ │  Syphon (M4)      │
                │                  │  CaptureCard (M6) │ │  NDI (optional)   │
                │                  └───────┬───────────┘ │  CameraExt (M7)   │
                │                          │             └───────────────────┘
┌───────────────▼──────────────────────────▼───────────┐
│ ReflexPTP: PTP codec · Nikon extensions · PTPTransport│
│  ImageCaptureTransport (ICC passthrough, own thread)  │
└───────────────────────────────────────────────────────┘
```

Each box becomes a library target in `Packages/ReflexKit` (`ReflexPTP`, `ReflexCamera`, `ReflexVideo`,
`ReflexOutput`), with the SwiftUI app on top. Logic that doesn't need hardware is unit-tested.

### ReflexPTP (done in Milestone 1)

- PTP containers, datasets (DeviceInfo, DevicePropDesc, events) and values, little-endian.
- Nikon live-view frame and header parsing (big-endian header, JPEG found by its start marker).
- `PTPTransport` protocol. `ImageCaptureTransport` implements it over ImageCaptureCore's passthrough, issues every
  call from a dedicated run-loop thread, and runs transactions strictly one at a time in FIFO order with a timeout.
  Control commands therefore slot in between live-view fetches and wait at most one frame (~10–18 ms).

### CameraService (Milestone 3)

- `CameraControlling` protocol: connection state, a catalog of `CameraControl`s (exposure, focus, color), apply,
  focus-at-point, nudge focus, battery, and an event stream. `NikonPTPCamera` implements it; another brand or a
  libgphoto2 transport could implement it later.
- On connect: read DeviceInfo + vendor property codes, fetch descriptors, set live-view size to XGA, enable exposure
  preview in photo live view, start live view.
- **Photo/movie mapping.** The D780 uses different properties in photo and movie live view (for example ISO 0x500F
  vs 0xD1AA, white balance 0x5005 vs 0xD23A). A logical control resolves to the right property from the
  live-view selector (0xD1A6), and the panel refreshes when the selector changes.
- **Staying in sync with the body.** `GetEvent` every 250 ms plus interrupt events. On `DevicePropChanged` the
  descriptor is re-read, so turning a dial on the camera updates the app.
- Read-only controls (exposure mode, LV selector) show their value but can't be changed.
- Disconnects: the transport fails pending calls with `.disconnected`; the service shows "Reconnect the camera"
  and rebuilds everything on the next connect.

### VideoSource (Milestone 2; capture card in Milestone 6)

```swift
protocol VideoSource {
    var frames: AsyncStream<SourceFrame> { get }   // latest-wins
    func start() async throws
    func stop() async
}
```

- `USBLiveViewSource` polls `GetLiveViewImage` back-to-back, de-duplicates repeats, and hands on the JPEG plus the
  parsed header (AF frame, sensor coordinate space).
- `CaptureCardSource` (M6) reads a UVC capture card through AVFoundation and delivers `CVPixelBuffer`s directly.
  The camera stays under USB control at the same time: `CameraService` keeps the PTP session for settings and focus
  but stops fetching live-view frames.

### VideoPipeline (Milestone 2)

- VideoToolbox decodes JPEG into an IOSurface-backed 4:2:0 `CVPixelBuffer` (0.5–0.8 ms measured), wrapped as Metal
  textures through `CVMetalTextureCache` with no copies.
- One Metal pass does YUV→RGB, crop (3:2 → 16:9 by default) and optional scaling into an IOSurface-backed BGRA
  output texture. Overlays (grid, histogram, peaking, zebras, safe area) render only into the viewfinder, never into
  the output feed.
- Latest-wins at every hop: if decode or render is busy, the older frame is dropped. Nothing is ever queued behind
  a stale frame.
- Stats: fps, request round trip, decode time, dropped frames, and a built-in latency test (the spike's flash
  method) the user can run from the app.

### OutputSinks (Milestone 4, then 7)

```swift
protocol FrameSink {
    func publish(_ texture: MTLTexture, on commandBuffer: MTLCommandBuffer)
}
```

**Default: Syphon.** Syphon shares the GPU texture with OBS through an IOSurface: no copy, no encode, no network
stack, so it adds no measurable latency. OBS 32 on macOS ships a built-in **Syphon Client** source that builds its
texture straight from that IOSurface. OBS's own **Virtual Camera** then carries the feed to Zoom, Discord and
browsers, with no Apple account needed anywhere.

- OBS 32.0.0/32.0.1 showed blank Syphon sources on macOS 26 because Syphon's IOSurfaces reported pixel format 0;
  OBS fixed this for its OpenGL renderer (shipped in 32.0.4, which is installed here). Syphon fixed it at the
  source in Syphon-Framework PR #103 (commit `71351d4`, 2025-10-06), so Reflex will build Syphon from `main` at or
  after that commit. OBS's experimental Metal renderer still rejects format 0 surfaces; use the default renderer.
- Syphon-Framework is BSD-licensed and has a Metal server (`SyphonMetalServer`).

**NDI (optional, not planned by default).** NDI is the better choice only when OBS runs on a different machine. It
compresses every frame (SpeedHQ), adds sender and receiver buffering, and needs the NDI runtime plus the DistroAV
plugin in OBS. On the same Mac it can only be slower and less reliable than Syphon.

**Camera extension (Milestone 7).** A CoreMediaIO camera extension would show "Reflex" directly in Zoom and FaceTime
without OBS. It needs the System Extension entitlement, which a free Apple ID can't get (see
[signing.md](signing.md)). It stays a later, optional milestone; OBS Virtual Camera covers the same need for free.

## Threading

| Thread | Work |
|---|---|
| `reflex.camera` (run loop, user-interactive QoS) | every ImageCaptureCore call and callback |
| Swift concurrency task | live-view polling loop, control commands, event polling |
| `reflex.decode` (serial queue) | VideoToolbox decode, latest-wins |
| Metal / display link | render, publish to sinks |
| Main | SwiftUI only; receives throttled stats (2–4 Hz), never per-frame work |

## Latency budget (photo live view, measured where possible)

| Stage | Time |
|---|---|
| Display → sensor → camera processing → USB arrival | 56 ms median (measured; includes the source display's own lag) |
| JPEG decode (VideoToolbox) | ~1–2 ms at high quality |
| Metal convert/crop/publish | < 1 ms (estimate, verify in M2) |
| Syphon → OBS | 0 copies; OBS shows it on its next render tick (≤ 1 OBS frame) |
| Preview window | ≤ 1 display refresh |

## Capture-card path (Milestone 6)

A UVC HDMI capture card gives clean 1080p60 (the D780 can output it over HDMI) without the 1024-pixel live-view
ceiling. The app will:

1. Offer "USB live view" or "Capture card" as the video source.
2. In capture-card mode, keep the PTP session for control only, and stop fetching live-view frames.
3. Still have to start live view on the camera over USB, because the D780 only outputs HDMI video while in live
   view. Whether HDMI output works while a USB PTP session is open, and whether the camera's HDMI overlay settings
   can be controlled over USB, has to be verified with a card in hand.
