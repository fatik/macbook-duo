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

Draws a card that stays still in space while the lid moves. When the card is anchored, it sits
exactly on the screen; as the screen tilts away from that, the app works out where your eye is
and draws the card as it would look from there, projected onto the tilted screen, so it keeps
looking like the same card, held where the screen was.

As the lid closes, the screen comes toward you, so the card is drawn smaller and shifted to stay on
the same line of sight, even if that takes it out of the window, like something seen through a
window frame. It anchors wherever the lid is when the app opens; press **Re-center** to anchor it at
the current angle. Go full screen (**F**) for the widest range of motion.

The controls float in the bottom-right corner. **X** hides or shows them, **R** re-centers the
card at the current angle, and **F** goes full screen edge to edge: unlike macOS's own full screen,
it also covers the strips beside the camera notch, with the menu bar and Dock hidden (**F** or
**Esc** to leave). The panel's header shows the lid angle as it moves, where the card is held and
the frame rate, with buttons for the same three actions. Below it are four tabs:

- **Picture**: what the card shows. Pick the **Checkerboard**, the **Desert** scene (sky, mountains
  and sand, from `Resources/Scene`) or **Your Image** (or drop an image on the window; the card
  takes its shape). *Size*: **Fill the window** stretches the card over the whole window (cropping
  the image to fit) and anchors at the current angle, so there it covers the window edge to edge;
  otherwise *Width* sets its size, up to 2.5× the window. *Frame*: *Corners* rounds the card's top
  corners to match the screen's own (the bottom ones stay square, like the screen's; macOS doesn't
  report them, so it starts at an estimated 3 mm), and *Background* is the color around the card,
  black to start.
- **Scene**: for the Desert.
  - *Parallax*: as the lid moves away from the anchored angle, the layers move at different speeds,
    the sand fastest, the mountains less and the sky barely. *Strength* sets how much, *Direction*
    which way and *Moves when* on which lid movement. *Toward you* brings the layers closer; *Away*
    plays that backward: at the anchored angle they start as close as they come and move back to
    the picture as it is, so they never shrink past the card's edges.
  - *Clock*: the date and time sit between the sky and the mountains, in SF Pro's variable font set
    like a phone's lock screen, with *Width*, *Weight*, *Height*, *Opacity* and *Blend*. They dim
    with the rest of the scene. Under *Motion*, *Depth* lets them move with the parallax like a
    layer (0% keeps them fixed) and *Blur* lets them blur (0% keeps them sharp).
- **Look**: a blur and a dim, set up separately. Each has a *Strength* and what it *Follows*, with
  the finer settings under *More*. The dim comes down from the top edge by default, sliding in as
  the lid moves.
  - **Depth (3D)** works like your eye focused on the screen. For every pixel, it follows the line
    of sight from your eye to the part of the card it shows, and compares how far that is with how
    far the screen is along the same line: the difference in focus (in diopters, so a gap blurs
    more the nearer it is to you) is how soft that pixel goes, starting as soon as it leaves focus.
    The card's outline softens with it, fading in and spilling out the way an out-of-focus object's
    edge does, and stays crisp wherever the picture is sharp. *Full at* sets how
    far out of focus gives the full effect, in centimeters at your viewing distance, and under
    *More*, *Blurs* (or *Dims*) picks what it applies to: things farther away, closer, or both.
  - An **edge** (top, bottom, left, right or all) fades in from that edge; *Reach* sets how far in
    it goes. A blur's fade rises evenly from nothing, so it shows from the first degrees the lid
    moves; a dim's eases in, so its front doesn't show as a line. Under *More*, *Lid reaction* lets the lid slide it in and out (at 0% it stays put; at
    100% there's none at the anchored angle and it slides in as the lid moves, fully after 45°) and
    *Grows when* picks opening, closing or either. While the card fills the window, edge fades come
    in from the edge of whatever part of it is in view: the card's own edge while it's on screen,
    and the window's once the card runs past it as the lid tilts.
- **Viewer**: whom the card is drawn for.
  - **From the screen** (the default) needs no settings: everything comes from the display's real
    size, which macOS reports (29.05 × 18.89 cm on a 13.6-inch M4 MacBook Air), and the lid angle.
    It assumes that when the card was anchored, the screen faced you, about 1.6 screen diagonals
    away. Re-center at the angle you'd normally use. To fine-tune, *Distance* sets how far away you
    are and *Looking down* how far above square-on you look from.
  - **Your eyes** uses *Eye distance* and *Eye height*, measured from the hinge.
  - To calibrate, **Line Up by Eye** goes by what looks right to you. Set the lid where you usually
    have it and start: the card is re-centered there and shows a target (a grid of squares, a
    rectangle and a circle), with a guide in the middle of the screen. Its little side view of the
    lid shows where to move it, and it tells you how far ("Close the lid 12° more") until it's
    enough, first about 20° closed, then about 20° open past where you started. There, if the
    circle doesn't look round or the squares square, use *Lean* (toward you or away) and *Height*
    until it looks like a card standing still in front of you, and press **Looks Right**. After
    each save it finds the eye position that would have drawn the card just where you put it at
    every saved angle, and switches to *Your eyes* with it; two angles are enough, and more average
    out an unsteady hand. It starts from the *From the screen* viewpoint and only strays far from a
    typical one when your line-ups clearly call for it; if only an unbelievable viewpoint would fit,
    it says so instead of using it. **Cancel** puts the old viewpoint back.
  - Or **Use the Camera**: keep your head still and slowly tilt the screen about 15° back and forth.
    The camera turns with the lid through angles the sensor knows exactly, so watching your pupils
    from a range of angles pins down where your eyes are. It uses the gap between your pupils as a
    ruler (6.3 cm, typical for adults), so if yours differs, the distance will be off by a few
    centimeters.

The lid itself is modeled from Apple's dimension drawing of the 13-inch M4 MacBook Air. The hinge
turns around an axis inside the back of the base, and the lid's lower end swings down behind it, so
the display's glass lies about 4 mm behind the axis and its lit area starts 16.6 mm up the lid from
it. Getting those right matters: a card held still is drawn a few millimeters off otherwise, more
the further the lid moves.

The card is drawn with Metal, straight into the window, on its own display link: moving the lid
doesn't rebuild any SwiftUI views, and nothing is drawn while nothing moves. Each frame, for every
pixel on screen, the shader works out where on the card it is (undoing the card's perspective),
mixes the layers there (the clock with its blend mode), dims it and shapes it by the card's outline.
With nothing blurred, that's the whole frame. With blur, it's the picture of the whole screen that
gets blurred, as the very first versions did, rather than the card: it's drawn sharp, along with how
much blur each pixel should get, then shrunk and blurred into eight progressively blurrier copies,
and each pixel blends the two copies nearest its blur. That reads like frosted glass on the screen
with the card seen through it: the blur doesn't foreshorten with the card, and the card's outline
blurs into what's around it.

### Holding the real screen still

The laptop icon in the menu bar has **Hold the Screen Still** (⌥⌘S from anywhere), which does the
same to the whole screen instead of a picture: your actual desktop and apps, drawn for the viewpoint
set in the Viewer tab, with the blur, dimming and corner radius set in the Look tab. It only steps in
while the lid moves. The moment the lid starts to move, the
screen is held where it was; once the lid has been still for half a second, the held screen eases back
onto the real one, over about half a second, and steps aside, so you're back on your real screen
until the lid moves again.

It captures the built-in display live with ScreenCaptureKit and, while the lid moves, draws it back
over itself in a window above everything, including the menu bar and Dock. At rest that window is
invisible. It lets clicks through to what's really there, and the real cursor stays on top, where
clicks land; while the screen is held, what you see drifts from where you click, until it eases
back. The capture is drawn back in the display's own colors and lands exactly on the real screen's
pixels, and the blur and dimming always follow the lid here, fading out as the screen eases back, so
handing back doesn't show. While the lid rests it captures only 15 frames a second, and
at full speed again as soon as the lid moves.

While it's on, Straight runs from the menu bar alone. Choosing Stop Sharing in macOS's
screen-recording indicator turns it off too. The first time, macOS asks for Screen Recording
permission; allow it in System Settings, then open Straight again. The build signs the app with your
Apple Development certificate if you have one, so the permission outlasts rebuilds.

The effect is strongest with one eye closed, since your two eyes can otherwise tell the screen is flat.

## Build and run

```bash
./build.sh
```

This builds both apps into `build/` and installs copies in `~/Applications`, so you can open them
from Spotlight or Launchpad, or drag them to the Dock. Each build replaces the installed copies.

Needs Xcode (for the Swift and Metal compilers) and macOS 14+. The sensor is present on recent MacBooks, but some
older models don't expose it. On a Mac without it, the app says so.
