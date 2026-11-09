# Glasstap

Turn your MacBook's screen into a (pretend) touchscreen, using only the built-in camera and microphone.

Point at the screen and tap the glass. The camera follows your hand to work out where you're pointing, and the microphone hears your fingertip hit the display. A click happens only when both agree.

> **Status: early prototype.** Hand tracking, the cursor dot, and tap-to-click work. Calibration, gestures (drag, scroll, right-click, zoom), settings and signed releases are next.

<!-- Demo GIF goes here once there's something worth recording. -->

## Download

Signed and notarized builds will be on the [Releases page](https://github.com/RohanReddyBandi/Glasstap/releases). Until the first release, build from source (below).

Requires an Apple Silicon MacBook on macOS 14 Sonoma or later.

## Using it

- Glasstap lives in the menu bar and starts **off**.
- Press **⌃⌥T** (Control-Option-T) to turn touch mode on or off, or use the menu bar icon.
- While it's on, a glowing border runs around the screen, and a translucent dot shows where Glasstap thinks you're pointing. The camera and mic run only while touch mode is on.
- Tap the screen where the dot is. A tap next to a key press or trackpad click is ignored, and so is a tap with no hand in view.

**Camera & Mic Debug…** in the menu shows the camera view with the tracked hand joints, the mic level against the tap threshold, and a log of every tap and why it did or didn't click.

## Permissions

| Permission | Why |
| --- | --- |
| Camera | Follows your hand to see where you're pointing. |
| Microphone | Hears the tap of your finger on the glass. |
| Accessibility | Lets Glasstap post clicks to other apps. |

Video and audio are processed live on your Mac. Nothing is recorded, stored or sent anywhere. Glasstap isn't sandboxed, because system-wide input needs Accessibility access, which sandboxed apps can't get. It does use the Hardened Runtime, with only the camera and microphone entitlements.

## Known limitations

A front-facing webcam was never meant to see a finger on the screen, so accuracy is limited.

- **The camera can't see the moment of touch.** It sits in the same plane as the display, so your fingertip leaves its view in the last few centimeters before it touches the glass. Glasstap uses the last position it saw and matches it to the moment of the sound. Expect accuracy of a few centimeters, which suits big targets better than small buttons.
- **The bottom of the screen is the hardest part to reach.** The lower the target, the sooner your hand drops out of the camera's view.
- **Typing and music can sound like taps.** Taps next to key presses are ignored. Sharp sounds such as drum hits can still click while your hand is up.
- **Lid angle matters.** Calibration (coming next) assumes the lid stays at the same angle.

## Build from source

You need Xcode 16 or later.

```bash
git clone https://github.com/RohanReddyBandi/Glasstap.git
cd Glasstap
open Glasstap.xcodeproj
```

The project signs with the author's team. To build under your own account, open the Glasstap target's **Signing & Capabilities** and pick your team. To build without an Apple account, sign ad hoc:

```bash
xcodebuild -project Glasstap.xcodeproj -scheme Glasstap -configuration Debug \
  CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= build
```

Run the tests with:

```bash
xcodebuild -project Glasstap.xcodeproj -scheme Glasstap test
```

Tip: sign development builds with the same certificate every time. macOS ties the Accessibility, Camera and Microphone grants to the signature, so an ad-hoc build asks again after every rebuild.

## How it works

- **Hand tracking:** Vision's hand-pose model runs on 1024 px frames from the camera, at the camera's full 30 fps. Center Stage is turned off, and the tallest 4:3 format is used, so the view stays fixed and covers as much of the area below the camera as possible.
- **Smoothing:** a One Euro filter steadies the cursor when your hand is still, without adding lag when it moves fast.
- **Tap detection:** an `AVAudioSinkNode` hands each ~10 ms block from the built-in mic to a detector on the real-time thread. A tap must jump sharply above the noise floor and then die away within 30 ms. Speech and music keep going, so they don't pass.
- **Matching the two:** each tap is matched to where the hand was just before the sound, not after it, because tapping the lid shakes the camera.

## License

[MIT](LICENSE)
