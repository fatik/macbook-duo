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
for the widest range of motion. With **Stands on the bottom edge** (on by default), the card's bottom
edge stays on the screen's instead, and the card leans from there the way its mode says, like a card
standing on the screen's bottom edge: no black shows below it as the lid moves.

- **Facing you**: the card stays square to your line of sight.
- **Upright**: the card stays vertical, like a physical card standing on the desk.
- **As placed**: the card keeps the tilt the screen had when it was anchored, so at that angle it
  sits exactly on the screen.
- **Flat**: no perspective correction; the picture stays flat on the screen, like a phone's
  wallpaper. Depth blur still works: it comes from how far each part of the screen has moved away
  since the anchored angle, which depends only on its height up the screen and the lid angle.

The controls float in the bottom-right corner. **X** hides or shows them, **R** re-centers the
card at the current angle, and **F** goes full screen edge to edge: unlike macOS's own full screen,
it also covers the strips beside the camera notch, with the menu bar and Dock hidden (**F** or
**Esc** to leave). The panel's header shows the lid angle as it moves, where the card is held and
the frame rate, with buttons for the same three actions. Below it are four tabs:

- **Picture**: what the card shows. Pick the **Checkerboard**, the **Desert** scene (sky, mountains
  and sand, from `Resources/Scene`) or **Your Image** (or drop an image on the window; the card
  takes its shape). For the desert:
  - *Parallax*: as the lid moves away from the anchored angle, the layers move at different speeds,
    the sand fastest, the mountains less and the sky barely. *Strength* sets how much, *Direction*
    which way and *Moves when* on which lid movement. *Toward you* brings the layers closer; *Away*
    plays that backward: at the anchored angle they start as close as they come and move back to
    the picture as it is, so they never shrink past the card's edges.
  - *Clock*: the date and time sit between the sky and the mountains, in SF Pro's variable font set
    like a phone's lock screen, with *Width*, *Weight*, *Height*, *Opacity* and *Blend*. They dim
    with the rest of the scene. Under *Motion*, *Depth* lets them move with the parallax like a
    layer (0% keeps them fixed) and *Blur* lets them blur (0% keeps them sharp).
- **Placement**: how the card is held in space, as one of the modes above, and its *Size*. **Fill
  the window** stretches the card over the whole window (cropping the image to fit), switches to
  *As placed* and anchors at the current angle, so there it covers the window edge to edge.
  Otherwise *Width* sets its size, up to 2.5× the window. **Stand on the bottom edge** (on by
  default) keeps the card's bottom edge on the screen's while it leans the way its mode says, so
  nothing shows below it as the lid moves.
- **Look**: a blur and a dim, set up separately. Each has a *Strength* and what it *Follows*, with
  the finer settings under *More*. The dim comes down from the top edge by default, sliding in as
  the lid moves.
  - **Depth (3D)** works like a lens focused on the screen: parts that end up farther away than
    where your eyes are focused go soft, starting as soon as they leave focus and growing steadily
    with distance. The card's outline softens with it, fading in and spilling out the way an
    out-of-focus object's edge does, and stays crisp wherever the picture is sharp. In *Flat* mode
    that's the parts of the screen tipping away from you as the lid opens; in the other modes it's
    the card as the screen moves in front of it. *Full at* sets how far gives the full effect, and
    under *More*, *Blurs* (or *Dims*) picks what it applies to: things farther away, closer, or both.
  - An **edge** (top, bottom, left, right or all) fades in from that edge; *Reach* sets how far in
    it goes. Under *More*, *Lid reaction* lets the lid slide it in and out (at 0% it stays put; at
    100% there's none at the anchored angle and it slides in as the lid moves, fully after 45°) and
    *Grows when* picks opening, closing or either. While the card fills the window, edge fades come
    in from the window's edges, since the image's own edges move off-screen as the lid tilts.
  - *Frame*: *Corners* rounds the card's top corners to match the screen's own (the bottom ones
    stay square, like the screen's; macOS doesn't report them, so it starts at an estimated 3 mm),
    and *Background* is the color around the card, black to start.
- **Viewer**: whom the card is drawn for.
  - **From the screen** (the default) needs no settings: everything comes from the display's real
    size, which macOS reports (29.05 × 18.89 cm on a 13.6-inch M4 MacBook Air), and the lid angle.
    It assumes that when the card was anchored, the screen faced you, about 1.6 screen diagonals
    away. Re-center at the angle you'd normally use. To fine-tune, *Distance* sets how far away you
    are and *Looking down* how far above square-on you look from.
  - **Your eyes** uses *Eye distance* and *Eye height*, measured from the hinge.
  - *Sensitivity* scales how much the lid's movement counts, for either viewpoint; **Reset** puts
    it back to 100%.
  - To calibrate, **Line Up by Eye** goes by what looks right to you. Set the lid where you usually
    have it and start: the card is re-centered there and shows a target (a grid of squares, a
    rectangle and a circle), with a guide in the middle of the screen. Its little side view of the
    lid shows where to move it, and it tells you how far ("Close the lid 12° more") until it's
    enough, first about 20° closed, then about 20° open past where you started. There, if the
    circle doesn't look round or the squares square, use *Lean* (toward you or away) and *Height*
    until it looks like a card standing still in front of you, and press **Looks Right**. After
    each save it finds the eye position and sensitivity that would have drawn the card just
    where you put it at every saved angle, and switches to *Your eyes* with those; two angles are
    enough to pin down all three, and more average out an unsteady hand. It starts from the *From
    the screen* viewpoint at 100% sensitivity and only strays far from a typical viewpoint when your
    line-ups clearly call for it, since a very close eye with a low sensitivity can explain small
    inconsistencies too, and draws the card squeezed instead of running off the screen. If only an
    unbelievable viewpoint would fit, it says so instead of using it. **Cancel** puts the old
    viewpoint back.
  - Or **Use the Camera**: keep your head still and slowly tilt the screen about 15° back and forth.
    The camera turns with the lid through angles the sensor knows exactly, so watching your pupils
    from a range of angles pins down where your eyes are. It uses the gap between your pupils as a
    ruler (6.3 cm, typical for adults), so if yours differs, the distance will be off by a few
    centimeters.

The card is drawn with Metal in a single pass, straight into the window, on its own display link:
moving the lid doesn't rebuild any SwiftUI views. When a picture loads, Core Image makes the sharp
copy and eight progressively blurrier ones once and packs them into one texture per layer. Each
frame, for every pixel on screen, the shader works out where on the card it is (undoing the card's
perspective), how blurred and dimmed that spot is, blends each layer's two nearest copies, mixes the
layers (the clock with its blend mode), and softens the card's outline to match. Each pixel is
written once, with no textures in between, and nothing is drawn while nothing moves.

The effect is strongest with one eye closed, since your two eyes can otherwise tell the screen is flat.

## Build and run

```bash
./build.sh
```

This builds both apps into `build/` and installs copies in `~/Applications`, so you can open them
from Spotlight or Launchpad, or drag them to the Dock. Each build replaces the installed copies.

Needs Xcode (for the Swift and Metal compilers) and macOS 14+. The sensor is present on recent MacBooks, but some
older models don't expose it. On a Mac without it, the app says so.
