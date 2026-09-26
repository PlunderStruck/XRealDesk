# XRealDesk

> Independent open-source project, not affiliated with or endorsed by XREAL. "XREAL" and "Air" are trademarks of their owner.

Multiple virtual monitors for XREAL Air glasses on macOS, anchored in space with head tracking.

macOS normally mirrors one screen to the glasses. XRealDesk creates up to 8 real extra displays
(drag windows onto them like any monitor), and shows them in the glasses as curved screens that
stay put while you turn your head.

Works with: XREAL Air, Air 2, Air 2 Pro (tested), Air 2 Ultra. Not the XREAL One / One Pro, which use a different protocol.
macOS 14 or newer, Apple silicon or Intel with Metal.

## Install

```sh
./scripts/make-signing-cert.sh     # once: stable local signature so the permission sticks across rebuilds
./scripts/build-app.sh --install   # builds and copies XRealDesk.app to /Applications
open /Applications/XRealDesk.app
```

On first launch, allow **Screen Recording** when macOS asks. It's how the screens get into the glasses.
Also allow **Accessibility** (Settings shows a Grant button). It lets XRealDesk put windows back on the glasses screens and move keyboard focus to the screen you look at. Everything else works without it.
If you missed the prompt: System Settings → Privacy & Security → Screen & System Audio Recording → XRealDesk.

## Use

1. Plug the glasses into a USB-C port that carries video.
2. XRealDesk switches the glasses from mirroring to extended, creates the virtual screens, and starts tracking.
   Your laptop keeps its own resolution.
3. The virtual screens sit **above** your laptop screen in macOS's arrangement, left to right in the same
   order you see them in the glasses. Move the mouse up off the top of the laptop screen to reach them, or drag windows up.
4. Look around. The screens stay where they are. Press **⌃⌥R** to recenter them in front of you.

**Mirroring vs. extended:** while XRealDesk runs, the glasses must be an *extended* display, since that's the only way it can draw your screens on them, and it switches them automatically. When XRealDesk isn't running they should *mirror* your main screen (their normal behavior). XRealDesk sets them back to mirroring when it quits. If you ever see an empty desktop in the glasses, XRealDesk isn't drawing: reopen it, or replug the glasses.

Quitting XRealDesk (or unplugging) removes the virtual screens. macOS moves their windows back to
your laptop, and the glasses go back to mirroring. Every display change is made "for this app only",
so macOS undoes it automatically even if the app crashes.

### Opening the controls

- **Menu-bar glasses icon (👓):** left-click for the control panel, right-click for a quick menu.
- **Dock icon:** click it to open the control panel. You can turn it off in Settings.
- **⌃⌥X** from anywhere, which helps when the menu-bar icon is hidden behind the notch.
- While XRealDesk is the active app, its **Glasses** menu is in the top menu bar.

### Control panel

- **Presets:** Single, Dual, Triple, Ultrawide (one 32:9 curved screen), Quad (2×2), Command (3×2)
- **Live map:** where your screens are, which one you're looking at, and what the glasses can see (the dashed box). Click a screen to bring it in front of you.
- **Screens / rows**, **Size**, **Curve** (flat wall to wrapped around you), **Height**, **Brightness**
- **Mode:**
  - *Anchored*: screens stay fixed in space
  - *Smart*: look around the whole group freely; the screens don't move. Look past the group's edge on any side and it glides after you (speed set by **Follow speed**). Optional: turn on **Flick your head to reposition** to drag the screens with a quick head flick.
  - *Follow*: the screen you're on stays in front of you and glides after your head with a slight lag (a small dead zone keeps it still while you read). ⌃⌥←/→ switches which screen is in front. Good for walking or lying down.
  - *Locked*: screens move with your head, like mirroring
- **Stability:** screens ignore head wobble smaller than this (typing, breathing, pulse), so they're rock-steady while you work. Real head turns are never slowed down.
- **Tilt:** rotates the picture clockwise or counter-clockwise if the glasses sit crooked on your face.
- **Cursor follows gaze:** look at another screen and the cursor jumps there, back to where you left it on that screen. **The keyboard follows too:** once you've settled on the screen (about half a second) and aren't mid-typing, the window you last used there gets focus, so you can look and start typing.
- **Windows stay put:** XRealDesk remembers which windows are on which glasses screen and puts them back after a restart, unplugging, sleep or a resolution change. Windows you drag off the glasses yourself are forgotten.

### Keyboard shortcuts

| Keys | Action |
|---|---|
| ⌃⌥X | Open the control panel |
| ⌃⌥R | Recenter |
| ⌃⌥← / ⌃⌥→ | Bring the previous / next screen in front of you |
| ⌃⌥F | Cycle mode (anchored → smart → follow → locked) |
| ⌃⌥, / ⌃⌥. | Tilt the picture counter-clockwise / clockwise |
| ⌃⌥= / ⌃⌥- | Bigger / smaller screens |
| ⌃⌥↑ / ⌃⌥↓ | Raise / lower screens |
| ⌃⌥[ / ⌃⌥] | Less / more curve |
| ⌃⌥G | Toggle cursor-follows-gaze |

### Picture quality

- **Lens correction** (Settings → Look, on by default): your glasses carry a factory map of their lens distortion (up to ~20 px at the corners). XRealDesk warps the image through it, so content sits exactly where the optics expect all the way to the edges, and stays world-locked there, not just in the middle.
- **Render quality**: screens are rendered at 1×, 1.5× or 2× (Ultra, the default) with bicubic filtering, then scaled onto the glasses. Ultra measured ~10% crisper text edges than 1× and uses ~2 ms of GPU per frame on an M4 Pro.

### Getting the sharpest text

The Air 2 Pro shows about 49 pixels per degree (1920 px across ~39°). A 1600×900 screen at 33° maps
one screen pixel to one glasses pixel, which is the default. In Settings, **Sharpest size for this
resolution** computes this for any resolution. **HiDPI** renders each screen at 2× and filters it down,
which gives the smoothest text at some GPU cost. **Text sharpening** helps when screens are scaled.

## Troubleshooting

- **The glasses show my laptop screen, squashed.** That's macOS mirroring, and the app isn't running. Launch XRealDesk.
- **"Glasses display not detected".** The cable or port isn't carrying video. Use a USB-C port directly on the Mac and the glasses' own cable.
- **Screens are black or show a grid.** Screen Recording permission is missing, or macOS needs a relaunch after granting it (Settings has a Relaunch button).
- **Screens drift slowly.** Press ⌃⌥R. Drift correction learns your headset's gyro bias whenever you hold still, and remembers it per headset.
- **Screens lag or overshoot when you turn fast.** Adjust **Prediction** in Settings → Tracking.
- **Log:** ~/Library/Logs/XRealDesk.log (menu → Show Log). **Save Glasses Snapshot** writes what the glasses show to ~/Library/Logs/XRealDesk/snapshot.png.

## How it works

| Part | File |
|---|---|
| XREAL USB HID protocol (IMU stream, factory calibration download, MCU) | `Sources/XRCore/XRealProtocol.swift`, `GlassesHIDService.swift` |
| Sensor fusion: 1 kHz gyro integration, gravity correction, online gyro-bias learning, zero-velocity lock | `Sources/XRCore/OrientationFilter.swift` |
| Curved layout geometry, gaze hit-testing, projection from the glasses' factory intrinsics | `Sources/XRCore/SpatialMath.swift` |
| Virtual monitors (CoreGraphics `CGVirtualDisplay`) | `Sources/XRealDesk/VirtualDisplays.swift` |
| Mirroring → extended, display arrangement | `Sources/XRealDesk/DisplayConfigurator.swift` |
| Zero-copy capture (ScreenCaptureKit → IOSurface → Metal) | `Sources/XRealDesk/ScreenCapturer.swift` |
| Rendering: curved meshes, mipmapped anisotropic sampling, sharpening, 120 Hz display link, pose prediction | `Sources/XRealDesk/Renderer.swift`, `AppController.swift` |

The IMU protocol comes from the community reverse-engineering in
[nrealAirLinuxDriver](https://gitlab.com/TheJackiMonster/nrealAirLinuxDriver). XRealDesk talks to the glasses directly and doesn't need the XREAL SDK or any driver.

### Develop

```sh
swift build                                  # debug build
swift run xrcheck testdata/air2pro-calibration.json   # self-checks (protocol, fusion, layout, projection)
swift run xrcheck live 20                    # stream live head tracking from connected glasses
.build/debug/XRealDesk --preview             # render into a window instead of the glasses
```

## Credits

- XREAL Air USB protocol: community reverse-engineering in [nrealAirLinuxDriver](https://gitlab.com/TheJackiMonster/nrealAirLinuxDriver) (thejackimonster, wheaney).
- Private `CGVirtualDisplay` declarations: originally by Khaos Tian, as used in [DeskPad](https://github.com/Stengo/DeskPad).

## License

MIT, see [LICENSE](LICENSE).
