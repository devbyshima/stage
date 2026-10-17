# Stage

![Stage](design/Stage-logo.png)

A Mac app for showing and recording your iPhone screen, like QuickTime Player's
movie recording but made for demos: plug the phone in, share the Stage window in
a meeting, and record when you want to.

Needs macOS 27 or later, and an iPhone or iPad on a cable (USB). Over Wi-Fi
there is no way in for an app of its own, so Stage doesn't offer one.

## Use it

1. Connect the iPhone with a cable, unlock it, and tap **Trust** if asked.
2. Open Stage. The phone's screen appears within a few seconds.
3. Press **Space** (or ⌘R, or the red button) to start and stop recording.

Recordings are the phone's own video stream at its full native resolution.
The window holds only that picture, edge to edge. The controls float on a
Liquid Glass strip of their own just under the window, never over the picture,
and fade away with nothing left behind; a meeting sharing the window never
sees them. Each recording is kept in Stage's library as
`<Device> 2026-10-15 at 15.03.12.mov`; when it stops, **Edit** opens it in the
Studio (⌘L does too, and **File › Recent Recordings** lists the last ten).

## Studio

The Studio edits a recording and exports a new file; the recording itself is
never changed. Exports go to `~/Movies/Stage` unless you choose another folder
in Settings.

- **Cut**: split at the playhead (⌘B), select a piece and delete it, drag a
  selected piece's yellow ends to trim, undo and redo (⌘Z, ⇧⌘Z). Space plays.
- **Sound**: keep the recording's sound or leave it out.
- **Mockup**: put the video on a 3D iPhone 18 Pro, 18 Pro Max or Duo Fold in
  any of its finishes, or on a USDZ model of your own.
  - **Shots**: twelve product-shoot framings (Front, Turn, Lean, Hero, Lying,
    Corner, Landscape, Pair, Stack, Mirror, Trio, Float). Drag the preview to
    turn and tilt the phones, scroll or pinch to size them, double-click to
    put them back. Shots with more than one phone can use a second finish.
  - **Motion**: the camera can push in, pull back, orbit, drift, rise, or
    travel from the top of the screen to the bottom over the video.
  - **Light**: Studio, Soft, Dramatic or Bright, brought round to any angle.
  - **Lens**: depth of field, glow, grain, vignette, saturation and contrast.
  - **Background**: the studio sweep, night, white, black, any colour,
    gradient or image, or **Clear** for phones alone to lay over slides.
  - **Templates**: save a setup and start the next mockup from it.
- **Export** a video (H.264, HEVC or ProRes, 1080p or 4K; with a clear
  background, HEVC with alpha or ProRes 4444), or the frame at the playhead
  as a 5K PNG.

A recording on its side turns to fill the screen, and starts on the
Landscape shot. The fold opens wide, so an upright recording sits on it with
bars at the sides.

### The 3D iPhones

Stage's own iPhones are USDZ files in `Stage/Resources/Mockups`, named
`<model> - <finish>.usdz` (for example `iPhone 18 Pro - Silver.usdz`); add a
file named that way and it joins the list. You can also use a USDZ model of
your own: any works if its screen is a part of its own, which Stage finds by
name or lets you choose.

## Keynote and video calls: Stage Camera

Stage Camera is a virtual camera with the phone's screen in it, for live
demos inside Keynote (**Insert › Live Video**) or in Zoom, Meet and FaceTime.
It is a system extension, and macOS only runs one signed by a team in the
Apple Developer Program, so it's left out of builds by default:

```bash
STAGE_CAMERA=1 ./scripts/build.sh release
```

Put that Stage in Applications, choose **Install** under Settings › Virtual
Camera, and allow it in System Settings. Stage feeds it while an app is using
it.

### Presenting in a meeting

- Share the **Stage** window in Zoom, Meet or Teams: the meeting sees only the
  phone's screen. The controls strip and the menu bar's recording timer are
  kept out of screen sharing, even when you share the whole screen. With
  Stage Manager on, Stage's window stays beside the app in front instead of
  shrinking into the side strip, so the meeting can list and share it.
- The controls and pointer fade out after a moment; move the pointer over the
  window to bring them back. The window buttons stay hidden while the phone is
  showing (use ⌘W to close, ⌘M to minimize, ⌃⌘F for full screen).
- **View › Float on Top** (⌥⌘T) keeps it above your other windows. Browsers
  such as Chrome and Arc can't share a floating window, so leave it off to
  present Stage in Google Meet.
- Full screen (⌃⌘F) shows the picture on black.
- While recording, a red timer sits in the menu bar, outside the shared
  window. Click it to stop.
- The phone's sound is muted on the Mac by default, so your meeting mic doesn't
  pick it up twice. Use the speaker slider to hear it.

### Options (the ⌄ button, or Settings ⌘,)

- **Show**: switch between connected iPhones and iPads.
- **Record Sound From**: the phone, a microphone (to narrate), or no sound.
- **Video format**: H.264 (plays everywhere), HEVC (smaller), or ProRes 422 HQ
  (near-lossless for editing, much larger files).
- **Export to**: where the Studio's exports go.

## Build

Needs Xcode 27 and XcodeGen (`brew install xcodegen`). `project.yml` signs with
the author's team; set `DEVELOPMENT_TEAM` to your own to build it yourself.

```bash
./scripts/build.sh            # Debug build, .build/main
./scripts/build.sh test       # unit tests
./scripts/build.sh release    # build/Stage.app
```

`Stage.xcodeproj` is generated from `project.yml`; don't edit it by hand.

The empty screen follows StarHash's empty states: a doodle drawn by
`python3 scripts/make_doodles.py` (StarHash's drawing engine and style) and a
title in Gochi Hand (`Stage/Resources/Fonts`), a marker hand that matches the
doodle's pen. The same script draws the logo, a portrait screen with the
record dot on its corner, in parts under `design/logo`. `scripts/make_icon.swift`
turns them into `Stage/AppIcon.icon`, an Icon Composer document: in light mode
the screen in white with the red dot on the brand green, in dark mode the logo
in its own colours on the system's dark background (the gap round the dot is a
real hole, so either shows through). It renders both to `design/AppIcon-light.png` and
`design/AppIcon-dark.png`, and writes the logo with its wordmark to
`design/Stage-logo.png`.

### Checking without a phone (Debug builds)

```bash
Stage.app/Contents/MacOS/Stage -demo idle -snapshot /tmp/stage.png
```

`-demo` takes `idle`, `recording`, `saved`, `landscape`, `connecting` or `empty`
and draws a fake phone. `-look light|dark` sets the appearance, and
`-capturableControls YES` leaves the controls in screenshots. `-autoRecord <seconds>` records the live source, then quits. Every
flag needs a value: a lone word is read as a file to open, and macOS then
skips opening the window.

The Studio has its own: `-studio <movie>` opens one, `-studioMockup <iPhone or
file>`, `-studioShot <shot>`, `-studioMotion <motion>` and `-studioBackground
clear` set the mockup up, and `-studioExport <file.mov>` or `-studioStill
<file.png>` export it and quit. `-snapshotInspector <file.png>` saves the whole
mockup inspector.

## How it works

macOS hides iPhone screens from apps until one opts in through CoreMediaIO
(`kCMIOHardwarePropertyAllowScreenCaptureDevices`), the same switch QuickTime
uses. The phone then appears as an AVFoundation capture device carrying picture
and sound. `CaptureEngine` runs one `AVCaptureSession` feeding the preview, an
`AVCaptureMovieFileOutput` and a speaker monitor; a frame output watches the
picture size, so the window follows the phone when it rotates, and passes
frames to Stage Camera when an app is watching it.

The Studio keeps the kept pieces as time ranges and builds an
`AVMutableComposition` from them for playback and export. Mockups are SceneKit
scenes: each shot clones the model, the video plays on the screen's material
as emitted light (so the studio light never greys it), and an export renders
every frame at twice its size and scales it down before writing it with the
sound.

## License

Stage is source-available under the [PolyForm Noncommercial License 1.0.0](LICENSE).
You may use, study and change it for any non-commercial purpose. Selling it, or using it in
anything that earns money, is not allowed.

The Stage name and icon are not covered by the license: a modified version must use its own
name and icon. Nor are the 3D iPhone models in `Stage/Resources/Mockups`, which are licensed
separately.

## Credits

Gochi Hand by Juan Pablo del Peral (Huerta Tipográfica), under the SIL Open Font License 1.1
(`Stage/Resources/Fonts/OFL.txt`). The doodle drawing engine comes from
[StarHash](https://github.com/devbyshima/starhash).
