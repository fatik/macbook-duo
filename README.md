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
is when the app opens; press **Re-center** to anchor it at the current angle. Go full screen (**F**)
for the widest range of motion.

- **Facing you**: the card stays square to your line of sight.
- **Upright**: the card stays vertical, like a physical card standing on the desk.
- **As placed**: the card keeps the tilt the screen had when it was anchored, so at that angle it
  sits exactly on the screen.
- **Flat**: no correction, for comparison.

The controls are in three tabs. Press **X** to hide or show them, and **F** (or the button beside
the ×) to go full screen edge to edge: unlike macOS's own full screen, it also covers the strips
beside the camera notch, with the menu bar and Dock hidden. Press **F** or **Esc** to leave.

- **Card**: the mode, *Card width* (up to 2.5× the window), and **Choose Image…** to use your own
  picture instead of the checkerboard (or drop an image file on the window). The card takes the
  image's shape. **Fill Window** stretches the card over the whole window (cropping the image to
  fit), switches to *As placed*, and anchors at the current lid angle, so at that angle it covers
  the window edge to edge and the effects start from there. While filling, the effects come in
  from the window's edges, since the image's own edges move off-screen as the lid tilts.
- **Effects**: a progressive blur and a darkening gradient. Each has a *Strength*, a *Reach* (the
  furthest in from its edge it goes), the edge it *Starts from*, and a *Lid reaction* that lets the
  lid slide the gradient in and out: at 0% it stays put; at 100% there's none at the anchored angle,
  and a soft fade slides in from the edge as the lid moves, faint at first and all the way in after
  45°. *Grows when* picks whether that's
  opening the lid more, closing it more, or either. Both effects are applied to the card before it's
  warped, so they move with it.
- **Viewer**: *Eye distance* and *Eye height*, measured from the hinge. **Calibrate with Camera**
  sets them for you: keep your head still and slowly tilt the screen about 15° back and forth. The
  camera turns with the lid through angles the sensor knows exactly, so watching your pupils from a
  range of angles pins down where your eyes are. It uses the gap between your pupils as a ruler
  (6.3 cm, typical for adults), so if yours differs, the distance will be off by a few centimeters.

The effect is strongest with one eye closed, since your two eyes can otherwise tell the screen is flat.

## Build and run

```bash
./build.sh
open build/Lid.app
open build/Straight.app
```

Needs the Xcode command-line tools and macOS 14+. The sensor is present on recent MacBooks, but some
older models don't expose it. On a Mac without it, the app says so.
