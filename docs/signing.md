# Signing, permissions and the Apple Developer Program

Short version: **everything through Milestone 6 builds and runs on your own Mac with no Apple Developer account.**
Only the optional camera extension (Milestone 7), and notarized distribution to other people, need the paid program.

## What works for free

| Thing | How it's signed | Notes |
|---|---|---|
| Reflex app (and the spike) | Ad-hoc ("Sign to Run Locally", `CODE_SIGN_IDENTITY = -`) | Builds and runs locally. No Apple ID needed. This is what `project.yml` does. |
| Syphon output to OBS | Syphon.framework embedded and ad-hoc signed with the app | No entitlement needed. |
| OBS Virtual Camera → Zoom / Discord / browsers | OBS's own, already signed | No account needed on our side. |
| Capture-card source | Uses AVFoundation | Needs the macOS **Camera** permission prompt (one click). |

### Permissions the app asks for

1. **"Allow accessory to connect?"** (first time the D780 is plugged into this Mac). Until it's allowed, the camera
   stays half-connected and invisible to every app.
2. **Removable Volumes** ("Reflex would like to access files on a removable volume"). macOS's camera daemon checks
   this before letting any app talk to a USB camera. Reflex doesn't read your photos; the daemon just files cameras
   under removable media. You can review it later in System Settings → Privacy & Security → Files & Folders.
3. **Camera** (capture-card source only, Milestone 6).

### Optional: a stable free signing identity

macOS remembers permissions per app identity. An ad-hoc build's identity is its code hash, which changes on every
rebuild. In testing the Removable Volumes grant survived rebuilds anyway, but if macOS ever starts asking again
after each build, sign with your free **Personal Team** instead:

1. Xcode → Settings → Accounts → add your Apple ID (free). Xcode creates an "Apple Development" certificate.
2. Copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` (git-ignored; added in Milestone 2) and set your
   team ID there.
3. Regenerate and build. Your team ID never goes into the public repo.

## What needs the paid Apple Developer Program ($99/year)

### Camera extension (Milestone 7)

A CoreMediaIO camera extension (the way Reflex could appear as a camera directly in Zoom/FaceTime without OBS) is a
**system extension**. Activating one requires:

- the `com.apple.developer.system-extension.install` entitlement, which Apple restricts: it must be authorized by a
  provisioning profile. Apple's capability table lists System Extension for the paid program and Developer ID only,
  not for free accounts ([Apple](https://developer.apple.com/help/account/reference/supported-capabilities-macos),
  [Quinn, Apple DTS](https://developer.apple.com/forums/thread/762614));
- the host app living in `/Applications`;
- the user approving the extension in System Settings.

`systemextensionsctl developer on` (which skips the `/Applications` check) **requires System Integrity Protection
to be disabled**; this Mac reports exactly that. Turning off SIP (plus code-signing enforcement) to load an
unentitled extension is a real security downgrade and is not something this project will recommend.

**Bottom line:** with a free account the camera extension can be written but not activated on a normal Mac. OBS
Virtual Camera gives Zoom, Discord and browsers the same feed for free. Milestone 7 will try a Personal Team build to
confirm the exact failure and document it.

### With the paid program

| Goal | What changes |
|---|---|
| Develop the camera extension | Enable the System Extension capability; Xcode's development profile authorizes it. Activate from `/Applications`, approve in System Settings. |
| Give Reflex to other people | Sign with **Developer ID Application**, enable the hardened runtime, **notarize** with `notarytool`, staple the ticket. Without this, other Macs block the app ("cannot verify the developer"). |
| Ship the camera extension to others | Same Developer ID + notarization; the extension is distributed inside the app bundle. |

### Sharing an unsigned build without the paid program

Possible but clunky: the recipient must right-click → Open, or allow it in System Settings → Privacy & Security
("Open Anyway"). Fine for a friend, not for the public.
