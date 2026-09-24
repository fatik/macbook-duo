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
- **Flat**: no perspective correction; the picture stays flat on the screen, like a phone's
  wallpaper. Depth blur still works: it comes from how far each part of the screen has moved away
  since the anchored angle, which depends only on its height up the screen and the lid angle.

The controls are in four tabs. Press **X** to hide or show them, and **F** (or the button beside
the ×) to go full screen edge to edge: unlike macOS's own full screen, it also covers the strips
beside the camera notch, with the menu bar and Dock hidden. Press **F** or **Esc** to leave.

- **Card**: the mode, *Card width* (up to 2.5× the window), *Corners* (the card's corner radius, to
  match the screen's own rounded corners; macOS doesn't report them, so it starts at an estimated
  3 mm), and **Choose Image…** to use your own
  picture instead of the checkerboard (or drop an image file on the window). The card takes the
  image's shape. **Desert Scene** shows a layered picture instead (sky, mountains and sand, from
  `Resources/Scene`). **Fill Window** stretches the card over the whole window (cropping the image to
  fit), switches to *As placed*, and anchors at the current lid angle, so at that angle it covers
  the window edge to edge and the effects start from there.
- **Scene**: for the Desert Scene. As the lid moves away from the anchored angle, the layers come
  toward you at different speeds, the sand fastest, the mountains less and the sky barely; *Parallax*
  sets how strongly and *Comes closer* which lid movement does it. The date and time sit between the
  sky and the mountains, in SF Pro's variable font set like a phone's lock screen (narrow, medium
  weight, fading slightly toward the bottom), adjustable with *Width*, *Weight*, a *Height* stretch,
  *Opacity* and a *Blend* mode. They dim with the rest of the scene. *Depth* lets them come closer
  with the parallax like a layer (0% keeps them fixed), and *Blur* lets them blur (0% keeps them sharp).
- **Effects**: a blur and a dim, set up separately. Each has a *Strength* and what it's *Based on*.
  The dim comes down from the top edge by default, sliding in as the lid moves:
  - **Depth (3D)** works like a lens focused on the screen: parts that end up farther away than
    where your eyes are focused go soft, starting as soon as they leave focus and growing steadily
    with distance. The card's rounded outline softens with it, fading in and spilling out the way an
    out-of-focus object's edge does, and stays crisp wherever the picture is sharp. In *Flat* mode that's the parts of
    the screen tipping away from you as the lid opens; in the other modes it's the card as the screen
    moves in front of it. *Full at* sets how far gives the full effect, and *Blurs* (or *Dims*) picks
    what it applies to: things farther away (the default), closer, or both.
  - An **edge** (top, bottom, left, right or all) fades in from that edge. *Reach* sets how far in
    it goes and *Lid reaction* lets the lid slide it in and out: at 0% it stays put; at 100% there's
    none at the anchored angle, and a soft fade slides in as the lid moves, all the way after 45°.
    *Grows when* picks opening, closing or either. While the card fills the window, edge fades
    come in from the window's edges, since the image's own edges move off-screen as the lid tilts.

  The blur is drawn by a Metal shader in one pass. When a picture loads, Core Image makes the sharp
  copy and eight progressively blurrier ones once and packs them into one texture. Each frame the
  shader works out how blurred each pixel should be, blends the two nearest copies, and softens the
  card's rounded outline to match. A layered scene is drawn whole first and then shaped by the
  outline once, so its layers don't show through each other at the edge.
- **Viewer**: where the card is drawn for.
  - **From the screen** (the default) needs no settings: everything comes from the display's real
    size, which macOS reports (29.05 × 18.89 cm on a 13.6-inch M4 MacBook Air), and the lid angle.
    It assumes that when the card was anchored, the screen faced you, about 1.6 screen diagonals
    away. Re-center at the angle you'd normally use. To fine-tune, *Distance* sets how far away you
    are and *Looking down* how far above square-on you look from.
  - *Sensitivity* scales how much the lid's movement counts, for either viewpoint.
  - **Your eyes** uses *Eye distance* and *Eye height*, measured from the hinge.
    **Calibrate with Camera** sets them for you: keep your head still and slowly tilt the screen
    about 15° back and forth. The camera turns with the lid through angles the sensor knows
    exactly, so watching your pupils from a range of angles pins down where your eyes are. It uses
    the gap between your pupils as a ruler (6.3 cm, typical for adults), so if yours differs, the
    distance will be off by a few centimeters.

The effect is strongest with one eye closed, since your two eyes can otherwise tell the screen is flat.

## Build and run

```bash
./build.sh
```

This builds both apps into `build/` and installs copies in `~/Applications`, so you can open them
from Spotlight or Launchpad, or drag them to the Dock. Each build replaces the installed copies.

Needs Xcode (for the Swift and Metal compilers) and macOS 14+. The sensor is present on recent MacBooks, but some
older models don't expose it. On a Mac without it, the app says so.
