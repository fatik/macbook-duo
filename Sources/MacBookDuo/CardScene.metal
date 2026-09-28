#include <metal_stdlib>
using namespace metal;

// Draws the card. `cardFragment` works out, for each pixel, where on the card it is (undoing the
// card's perspective), mixes the layers there, dims it, and shapes it by the card's rounded outline
// over the background. With nothing blurred that goes straight to the window.
//
// With blur, it instead draws the screen's picture sharp, with how blurred each pixel should be, and
// the renderer makes progressively blurrier copies of that whole picture; `glassFinish` then blends,
// for each pixel, the two copies nearest its blur. Blurring the picture of the screen rather than the
// card is like frosted glass on the screen with the card seen through it: the blur doesn't foreshorten
// with the card, and the card's outline blurs into what's around it. That picture runs past the
// window on every side, so the blur near the window's edges takes in what's really beyond them.
//
// `values` is packed by CardFrame in CardRenderer.swift:
//
//   0-8   window position (points) to card position (0 to 1 across it), a projection in
//         row-vector order
//   9-10  window size in points      11 pixels per point
//   12-13 card size in points        14 corner radius in points     15 blur strength
//   16    which frame of a live screen this is (only so each new one gets drawn)
//   17    1 for an outline exact to the pixel, for a live screen drawn back over itself
//   18-23 where the blur is: kind (0 none, 1 depth, 2 card edge, 3 edge of the part in view), edge (0 top,
//         1 bottom, 2 left, 3 right, 4 all), front, width, full depth, side (-1 nearer, 0 either,
//         1 farther)
//   24-29 where the dimming is, the same way           30 dim strength       31 number of layers
//   32-34 the background's color around the card (sRGB)   35 1 to draw for the blurred copies
//   36-50 in the world, in centimeters from a point on the screen's glass: the eye, the card's
//         top-left corner, the way to its top-right and bottom-left corners, and the facing of the
//         plane the eye is focused on (the glass)   51 the viewing distance depths are measured at
//   52 on, 10 for each layer, back to front:
//         0-1 picture scale  2-3 picture offset (card position to picture position)
//         4-5 texture size   6-9 where the picture sits in it (x, y, width, height)

constant int firstLayer = 52;
constant int layerLength = 10;

struct Rasterized {
    float4 position [[position]];
};

/// One triangle that covers the whole view.
vertex Rasterized cardVertex(uint id [[vertex_id]]) {
    float2 corner = float2(float((id << 1) & 2), float(id & 2));
    return { float4(corner * 2 - 1, 0, 1) };
}

static float smootherstep01(float x) {
    x = saturate(x);
    return x * x * x * (x * (6 * x - 15) + 10);
}

/// How out of focus the card is at `uv`: how much farther from the eye (or nearer) than where the eye
/// is focused along the same line of sight, in diopters, given as the centimeters that would be at
/// the reference viewing distance. Positive is farther.
static float defocus(constant float *values, float2 uv) {
    float3 eye = float3(values[36], values[37], values[38]);
    float3 corner = float3(values[39], values[40], values[41]);
    float3 across = float3(values[42], values[43], values[44]);
    float3 down = float3(values[45], values[46], values[47]);
    float3 facing = float3(values[48], values[49], values[50]);
    float reference = values[51];

    float2 onCard = saturate(uv);
    float3 ray = corner + onCard.x * across + onCard.y * down - eye;
    // Where the line of sight meets the plane in focus, as a share of the way to the card.
    float along = dot(facing, ray);
    if (abs(along) < 1e-5) { return 0; }
    float share = -dot(facing, eye) / along;
    if (share <= 0) { return 0; }
    // 1 / focused distance - 1 / distance to the card.
    return (1 / share - 1) / length(ray) * reference * reference;
}

/// The card position that window point `point` shows, with its homogeneous weight in z: at or below
/// 0 the point is past the card's horizon.
static float3 cardPoint(constant float *values, float2 point) {
    float w = point.x * values[2] + point.y * values[5] + values[8];
    return float3(float2(point.x * values[0] + point.y * values[3] + values[6],
                         point.x * values[1] + point.y * values[4] + values[7]) / w, w);
}

/// On the line through card positions `a` and `b`, the v where u is `at` (`axis` 0), or the u where
/// v is (`axis` 1); `otherwise` if either is past the horizon or the line runs the other way.
static float along(float3 a, float3 b, float at, int axis, float otherwise) {
    if (a.z <= 0 || b.z <= 0) { return otherwise; }
    float run = axis == 0 ? b.x - a.x : b.y - a.y;
    if (abs(run) < 1e-6) { return otherwise; }
    float t = (at - (axis == 0 ? a.x : a.y)) / run;
    return axis == 0 ? mix(a.y, b.y, t) : mix(a.x, b.x, t);
}

/// Where card position `uv` is across the part of the card in view, from 0 to 1 each way: measured
/// from the card's own edges where they're in the window, and from the window's where the card runs
/// past them. A window edge is a straight line across the card too, through the corners' positions.
static float2 partInView(constant float *values, float2 uv) {
    float2 size = float2(values[9], values[10]);
    float3 topLeft = cardPoint(values, float2(0, 0)), topRight = cardPoint(values, float2(size.x, 0));
    float3 bottomLeft = cardPoint(values, float2(0, size.y)), bottomRight = cardPoint(values, size);
    float top = max(along(topLeft, topRight, uv.x, 0, 0), 0.0);
    float bottom = min(along(bottomLeft, bottomRight, uv.x, 0, 1), 1.0);
    float left = max(along(topLeft, bottomLeft, uv.y, 1, 0), 0.0);
    float right = min(along(topRight, bottomRight, uv.y, 1, 1), 1.0);
    return saturate((uv - float2(left, top)) / max(float2(right - left, bottom - top), 1e-4));
}

/// How much of the effect described at `slot` there is at card position `uv`, at `inView` across the
/// part of the card in view, and at defocus `depth`, from 0 to 1.
static float effectAmount(constant float *values, int slot, float2 uv, float2 inView, float depth) {
    int kind = int(values[slot]);
    if (kind == 1) {
        float side = values[slot + 5];
        float counted = side < -0.5 ? max(-depth, 0.0) : side > 0.5 ? max(depth, 0.0) : abs(depth);
        // Like a lens: it starts as soon as something leaves focus and grows steadily with
        // distance, easing into the full amount.
        float x = saturate(counted / values[slot + 4]);
        return 1 - (1 - x) * (1 - x);
    }
    if (kind >= 2) {
        float2 at = kind == 3 ? inView : saturate(uv);
        int edge = int(values[slot + 1]);
        float fromEdge = edge == 0 ? at.y
                       : edge == 1 ? 1 - at.y
                       : edge == 2 ? at.x
                       : edge == 3 ? 1 - at.x
                       : 1 - length(at * 2 - 1);
        float x = saturate((values[slot + 2] - max(fromEdge, 0.0)) / values[slot + 3]);
        // Blur comes in with the lid's first degrees, as an edge leaving focus does. Dimming eases in,
        // since a darkening that starts sharply shows as a line.
        return slot == 18 ? x : smootherstep01(x);
    }
    return 0;
}

/// The normal curve's cumulative share, approximated.
static float normalShare(float z) {
    return 1 / (1 + exp(-1.702 * z));
}

/// How much of the card covers this spot: its outline, softened by `sigma` points. Only the top
/// corners are rounded, like a MacBook's screen.
static float cardCoverage(float2 uv, float2 points, float radius, float sigma) {
    // Switching halves at the middle is seamless: there the distance doesn't depend on the radius.
    radius = uv.y < 0.5 ? min(radius, min(points.x, points.y) / 2) : 0;
    sigma = max(sigma, 0.5);   // a point's worth of smoothing at the least
    float2 half_ = points / 2;
    float2 fromMiddle = abs(uv * points - half_);
    // Well inside, where most pixels are, it's simply covered.
    float2 edges = fromMiddle - half_;
    if (max(edges.x, edges.y) < -radius - 5 * sigma) { return 1; }

    // Exact for a sharp outline: the rounded rectangle's distance.
    float2 q = fromMiddle - (half_ - radius);
    float outside = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
    float rounded = normalShare(-outside / sigma);
    // Right for a wide blur, which rounds any corner off anyway: each edge blurred on its own. It has
    // no crease along the diagonals, where the distance above does.
    float square = normalShare(-edges.x / sigma) * normalShare(-edges.y / sigma);
    return radius > 0 ? mix(rounded, square, smoothstep(0.5 * radius, 2 * radius, sigma)) : square;
}

/// How much of the card covers this pixel, its outline smoothed over just the pixel. Where the card
/// lines up with the window, its straight edges run along the pixels' and cover them all fully.
static float pixelCoverage(float2 uv, float2 points, float radius, float pixelsPerPoint) {
    radius = uv.y < 0.5 ? min(radius, min(points.x, points.y) / 2) : 0;
    float2 half_ = points / 2;
    float2 q = abs(uv * points - half_) - (half_ - radius);
    float outside = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
    return saturate(0.5 - outside * pixelsPerPoint);
}

/// A layer at card position `uv`, its picture's edges extended beyond it.
static half4 sampleLayer(texture2d<half> picture, constant float *layer, float2 uv) {
    constexpr sampler linear(coord::normalized, filter::linear, address::clamp_to_edge);
    float2 at = uv * float2(layer[0], layer[1]) + float2(layer[2], layer[3]);
    float2 origin = float2(layer[6], layer[7]), extent = float2(layer[8], layer[9]);
    float2 pixel = origin + clamp(at * extent, float2(0.5), extent - 0.5);
    return picture.sample(linear, pixel / float2(layer[4], layer[5]));
}

/// A little noise for each pixel, from 0 to 1, evenly spread.
static float noise(float2 position) {
    return fract(52.9829189 * fract(dot(position, float2(0.06711056, 0.00583715))));
}

// Each layer's picture is bound to its own slot rather than an array: picking a texture by index in
// a loop is a third slower.
/// How much of the card covers card position `uv`.
static float outline(constant float *values, float2 uv) {
    float2 card = float2(values[12], values[13]);
    return values[17] > 0.5 ? pixelCoverage(uv, card, values[14], values[11]) : cardCoverage(uv, card, values[14], 0.5);
}

/// `margin` is how far, in pixels, the window's top-left corner is into what's drawn.
fragment float4 cardFragment(Rasterized in [[stage_in]], constant float *values [[buffer(0)]],
                             constant float2 &margin [[buffer(1)]],
                             texture2d<half> atlas0 [[texture(0)]], texture2d<half> atlas1 [[texture(1)]],
                             texture2d<half> atlas2 [[texture(2)]], texture2d<half> atlas3 [[texture(3)]],
                             texture2d<half> atlas4 [[texture(4)]], texture2d<half> atlas5 [[texture(5)]]) {
    bool forGlass = values[35] > 0.5;
    float2 point = (in.position.xy - margin) / values[11];
    float3 background = float3(values[32], values[33], values[34]);
    // Past the card's horizon, the card's plane is behind the eye.
    float w = point.x * values[2] + point.y * values[5] + values[8];
    if (w <= 0) { return float4(background, forGlass ? 0 : 1); }
    float2 uv = float2(point.x * values[0] + point.y * values[3] + values[6],
                       point.x * values[1] + point.y * values[4] + values[7]) / w;

    // Worked out once, for both effects, only if either follows depth.
    float depth = values[18] == 1 || values[24] == 1 ? defocus(values, uv) : 0;
    float2 inView = values[18] == 3 || values[24] == 3 ? partInView(values, uv) : 0;
    float amount = forGlass ? effectAmount(values, 18, uv, inView, depth) : 0;
    float covered = outline(values, uv);
    // Around the card, the blur carries on as it is at the card's edge, so the outline blurs too.
    if (covered < 0.002) { return float4(background, forGlass ? saturate(values[15] * amount) : 1); }

    // The layers, each over the ones behind it. Colors are premultiplied.
    float4 color = 0;
    int count = int(values[31]);
    #define MIX_LAYER(index, atlas) \
        if (count > index) { \
            float4 top = float4(sampleLayer(atlas, values + firstLayer + index * layerLength, uv)); \
            color = top + color * (1 - top.a); \
        }
    MIX_LAYER(0, atlas0) MIX_LAYER(1, atlas1) MIX_LAYER(2, atlas2)
    MIX_LAYER(3, atlas3) MIX_LAYER(4, atlas4) MIX_LAYER(5, atlas5)

    // Colors are premultiplied, so darkening scales color and leaves coverage alone.
    if (values[30] > 0) { color.rgb *= 1 - saturate(values[30] * effectAmount(values, 24, uv, inView, depth)); }
    // The card over the background, which also shows through any clear parts of the picture.
    float3 shown = color.rgb * covered + background * (1 - covered * color.a);
    // For the blurred copies: how much of the full blur this pixel gets.
    if (forGlass) { return float4(shown, saturate(values[15] * amount)); }
    // A little noise, under a step of 8-bit color, so slow dark fades don't band.
    return float4(shown + (noise(in.position.xy) - 0.5) / 255, 1);
}

/// The screen's picture `sharp` (with each pixel's share of the full blur as its alpha), blurred as
/// much as each pixel asks by blending the two nearest of its progressively blurrier copies, which are
/// blurred by the full blur times (level / 8)^2. The window is the part of them `margin` pixels in from
/// the top-left.
fragment half4 glassFinish(Rasterized in [[stage_in]], constant float2 &margin [[buffer(0)]],
                           texture2d<float> sharp [[texture(0)]],
                           texture2d<float> copy1 [[texture(1)]], texture2d<float> copy2 [[texture(2)]],
                           texture2d<float> copy3 [[texture(3)]], texture2d<float> copy4 [[texture(4)]],
                           texture2d<float> copy5 [[texture(5)]], texture2d<float> copy6 [[texture(6)]],
                           texture2d<float> copy7 [[texture(7)]], texture2d<float> copy8 [[texture(8)]]) {
    constexpr sampler smooth(coord::normalized, filter::linear, address::clamp_to_edge);
    float2 at = in.position.xy + margin;
    float2 uv = at / float2(sharp.get_width(), sharp.get_height());
    float4 center = sharp.read(uint2(at));
    // Copies are spaced by the square of their share of the full blur.
    float level = 8 * sqrt(saturate(center.a));
    int lower = min(int(level), 8);
    #define COPY(index) \
        (index == 0 ? center.rgb : index == 1 ? copy1.sample(smooth, uv).rgb : index == 2 ? copy2.sample(smooth, uv).rgb \
         : index == 3 ? copy3.sample(smooth, uv).rgb : index == 4 ? copy4.sample(smooth, uv).rgb \
         : index == 5 ? copy5.sample(smooth, uv).rgb : index == 6 ? copy6.sample(smooth, uv).rgb \
         : index == 7 ? copy7.sample(smooth, uv).rgb : copy8.sample(smooth, uv).rgb)
    float3 color = COPY(lower);
    float between = level - float(lower);
    if (lower < 8 && between > 0.002) { color = mix(color, COPY(lower + 1), between); }
    #undef COPY
    // A little noise, under a step of 8-bit color, so slow dark fades don't band.
    return half4(half3(color + (noise(in.position.xy) - 0.5) / 255), 1);
}
