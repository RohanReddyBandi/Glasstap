# Glasstap

Control your MacBook by pointing at the screen. Glasstap follows your hand with the built-in camera, so you can pinch to click, pinch and move to scroll, and swipe between Spaces. No extra hardware.

<!-- Demo GIF goes here. -->

## Download

Signed and notarized builds are on the [Releases page](https://github.com/RohanReddyBandi/Glasstap/releases). You need an Apple Silicon MacBook on macOS 14 Sonoma or later.

1. Download `Glasstap-<version>.dmg` and open it.
2. Drag **Glasstap** into **Applications**.
3. Open Glasstap from Applications. A setup assistant walks you through permissions and calibration.

Glasstap lives in the menu bar (the hand icon) and starts **off**. Press **⌃⌥T** (Control-Option-T) to turn touch mode on or off. You can change the shortcut in Settings.

## Gestures

| Gesture | What it does |
| --- | --- |
| Pinch thumb and index finger, let go | Click. Pinch twice for a double-click. |
| Pinch, move, let go | Scroll. The page follows your hand and keeps gliding if you flick. |
| Pinch, hold still for half a second, then move | Drag. Let go to drop. |
| Pinch thumb and middle finger | Right-click |
| Pinch with both hands, pull apart or push together | Zoom in or out (sends ⌘+ / ⌘−) |
| Open hand, quick swipe left or right | Switch Spaces |
| Open hand, quick swipe up or down | Mission Control, or the current app's windows |

You can turn each gesture on or off in **Settings → Gestures**, along with pinch sensitivity, scroll speed and scroll direction.

While touch mode is on:

- A glowing border runs around the screen.
- A ring follows your hand. It closes in as your fingers pinch and fills when they touch.
- The real pointer follows your hand too, so buttons light up as you point at them. Touch the trackpad and your hand lets go of the pointer for a second.

**Tap the glass (optional):** in **Settings → Tapping**, Glasstap can also click when the microphone hears your fingertip tap the screen. **Tune to My Taps…** sets the sensitivity from five sample taps.

## Calibration

The first-run setup includes a one-minute calibration. Nine dots appear one at a time. Hold your hand in front of each dot and pinch. Glasstap fits a mapping from where your hand appears in the camera image to where you were pointing on screen. It then rates the accuracy and offers a short practice round.

Recalibrate from the menu bar if you change how you sit or tilt the lid.

## Permissions

| Permission | Why |
| --- | --- |
| Camera | Follows your hand. Required. |
| Accessibility | Lets Glasstap post clicks, scrolls and shortcuts to other apps. Required. |
| Microphone | Hears taps on the glass. Only needed if you turn on tap-to-click. |

Video and audio are processed live on your Mac. Nothing is recorded, stored or sent anywhere. The only network request Glasstap makes is the update check, which asks GitHub for the latest release, and you can turn it off.

Glasstap isn't sandboxed, because posting input to other apps needs Accessibility access, which sandboxed apps can't get. It uses the Hardened Runtime with only the camera and microphone entitlements.

## Known limitations

A laptop webcam was never meant to track hands, so expect some rough edges.

- **Aim is good, not pixel-perfect.** With a good calibration, expect to land within roughly 10–30 points, which works for buttons, links and tabs. Tiny targets such as window corners are hard.
- **Your hand has to be in the camera's view.** The camera sits above the screen, so reaching for the bottom edge can take your hand out of frame. Hovering an arm's length away works best. The setup assistant and the calibration screen show a live preview.
- **Lighting matters.** A bright window behind you makes your hand hard to see.
- **Zoom is a keyboard shortcut.** macOS has no public API for posting a real pinch, so zoom sends ⌘+ / ⌘−, which most apps support.
- **Swipes use Mission Control's shortcuts.** If swipes do nothing, turn on the Control-arrow shortcuts in System Settings → Keyboard → Keyboard Shortcuts → Mission Control.
- **Tap-to-click can mishear.** Sharp sounds such as drum hits can click while your hand is in view. Taps next to key presses are ignored.

## Build from source

You need Xcode 16 or later.

```bash
git clone https://github.com/RohanReddyBandi/Glasstap.git
cd Glasstap
open Glasstap.xcodeproj
```

The project signs with the author's team. To build under your own account, pick your team in the Glasstap target's **Signing & Capabilities**. To build without an Apple account, sign ad hoc:

```bash
xcodebuild -project Glasstap.xcodeproj -scheme Glasstap -configuration Debug CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= build
```

Run the tests:

```bash
xcodebuild -project Glasstap.xcodeproj -scheme Glasstap test
```

Sign development builds with the same certificate every time. macOS ties the Camera and Accessibility grants to the signature, so an ad-hoc build asks again after every rebuild.

## Releasing

`scripts/release.sh <version>` builds a Developer ID–signed, notarized and stapled DMG in `dist/`. Pushing a `v<version>` tag does the same on GitHub Actions and publishes the release. [docs/RELEASING.md](docs/RELEASING.md) covers the one-time certificate and secrets setup.

## How it works

- **Hand tracking:** Vision's hand-pose model runs on 1024 px frames at the camera's full 30 fps. Center Stage is off, and the tallest 4:3 format is used, so the view stays fixed.
- **Cursor:** the cursor follows the point between your index and middle knuckles. Knuckles barely move when you pinch, so the cursor holds still while you click. A One Euro filter steadies it without adding lag.
- **Calibration:** a least-squares homography from the nine camera positions to the nine dots, checked for consistency and rated by its residual error.
- **Gestures:** pinch distance is measured relative to hand size, with hysteresis so it doesn't flicker. A click lands where the hand was just before the fingers started closing.
- **Tap detection (optional):** an `AVAudioSinkNode` hands each ~10 ms block from the built-in mic to a detector on the real-time thread. A tap must jump sharply above the last 10 ms of sound and die away within 30 ms. Speech and music keep going, so they don't pass.

## License

[MIT](LICENSE)
