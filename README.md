# Lid

Two small macOS experiments driven by your MacBook's lid angle.

## Lid

Fills the window with a color driven by the lid angle.

It reads Apple's built-in hinge sensor (HID device `0x05AC:0x8104`, Sensor / Orientation usage),
eases the reading every frame, and maps it onto a palette blended in OKLab.

The sensor reports the angle two ways: report 1 in whole degrees, and report 7 in hundredths of a
degree. Both apps read report 7 and fall back to report 1 if it's missing. At rest, the fine reading
wobbles within about 0.05°, so changes smaller than that are ignored.

- **Dawn**: night when the lid is nearly closed, sunrise as it opens, full sun when wide open.
- **Spectrum**: a hue sweep from red through green and blue to violet.

Click anywhere in the window to switch palettes.

## Straight

Draws a checkerboard card that looks like it's facing you straight on, whatever the lid angle.
As the screen tilts, the app works out where your eye is and draws the card as it would look
projected onto the tilted screen. Your viewing angle then undoes the distortion, and the squares
look square again.

The card is also held still in space, not stuck to the screen. As the lid closes, the screen comes
toward you, so the card is drawn smaller and shifted to stay on the same line of sight, even if that
takes it out of the window, like something seen through a window frame. It anchors wherever the lid
is when the app opens; press **Re-center** to anchor it at the current angle. Go full screen for the
widest range of motion.

## Build and run

```bash
./build.sh
open build/Lid.app
open build/Straight.app
```

Needs the Xcode command-line tools and macOS 14+. The sensor is present on recent MacBooks, but some
older models don't expose it. On a Mac without it, the app says so.
