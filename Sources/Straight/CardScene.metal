#include <metal_stdlib>
using namespace metal;

// Draws the whole card in one pass, straight into the window. For each pixel it works out where on
// the card it is (undoing the card's perspective), how blurred and dimmed that spot is, blends each
// layer's two nearest blurred copies, mixes the layers, and shapes the result by the card's rounded
// outline over black. Each pixel is written once, with no textures in between.
//
// Each layer's atlas holds the sharp picture and copies blurred by maxBlur * (level / levels)^2.
// The outline softens as much as the blur is at that spot, fading in and spilling out the way an
// out-of-focus object's edge does.
//
// `values` is packed by CardFrame in CardRenderer.swift:
//
//   0-8   window position (points) to card position (0 to 1 across it), a projection in
//         row-vector order
//   9-10  window size in points      11 pixels per point
//   12-13 card size in points        14 corner radius in points     15 blur strength
//   16-17 depth at the card's top and bottom: how much farther away than the focus (negative is nearer)
//   18-23 where the blur is: kind (0 none, 1 depth, 2 card edge, 3 window edge), edge (0 top,
//         1 bottom, 2 left, 3 right, 4 all), front, width, full depth, side (-1 nearer, 0 either,
//         1 farther)
//   24-29 where the dimming is, the same way           30 dim strength       31 number of layers
//   32-34 the background's color around the card (sRGB)
//   36 on, 48 for each layer, back to front:
//         0-1 picture scale  2-3 picture offset (card position to picture position)
//         4 blur strength    5 opacity   6 blend (0 normal, 1 plus lighter, 2 screen, 3 soft light,
//         4 overlay)         7 levels    8-9 atlas size
//         10 on: for each copy, sharp first, where it sits in the atlas (x, y, width, height)

constant int firstLayer = 36;
constant int layerLength = 48;

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

/// How much of the effect described at `slot` there is at card position `uv`, window spot `spot`
/// (0 to 1 across the window), from 0 to 1.
static float effectAmount(constant float *values, int slot, float2 uv, float2 spot) {
    int kind = int(values[slot]);
    if (kind == 1) {
        // Distance from the screen only changes from the card's top to its bottom.
        float depth = mix(values[16], values[17], saturate(uv.y));
        float side = values[slot + 5];
        float counted = side < -0.5 ? max(-depth, 0.0) : side > 0.5 ? max(depth, 0.0) : abs(depth);
        // Like a lens: it starts as soon as something leaves focus and grows steadily with
        // distance, easing into the full amount.
        float x = saturate(counted / values[slot + 4]);
        return 1 - (1 - x) * (1 - x);
    }
    if (kind >= 2) {
        float2 at = kind == 3 ? spot : saturate(uv);
        int edge = int(values[slot + 1]);
        float fromEdge = edge == 0 ? at.y
                       : edge == 1 ? 1 - at.y
                       : edge == 2 ? at.x
                       : edge == 3 ? 1 - at.x
                       : 1 - length(at * 2 - 1);
        return smootherstep01((values[slot + 2] - max(fromEdge, 0.0)) / values[slot + 3]);
    }
    return 0;
}

/// The normal curve's cumulative share, approximated.
static float normalShare(float z) {
    return 1 / (1 + exp(-1.702 * z));
}

/// How much of the card covers this spot: its outline, blurred by `sigma` points. Only the top
/// corners are rounded, like a MacBook's screen. Where the picture is sharp it's crisp; where it's
/// blurred it fades inside and spills outside the edge.
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

/// One copy at picture position `picture`, its edges extended beyond the picture.
static half4 sampleCopy(texture2d<half> atlas, constant float *layer, int copy, float2 picture) {
    constexpr sampler linear(coord::normalized, filter::linear, address::clamp_to_edge);
    int base = 10 + copy * 4;
    float2 origin = float2(layer[base], layer[base + 1]);
    float2 extent = float2(layer[base + 2], layer[base + 3]);
    // Half a pixel in from the copy's edges, so filtering never reaches the neighboring copy.
    float2 pixel = origin + clamp(picture * extent, float2(0.5), extent - 0.5);
    return atlas.sample(linear, pixel / float2(layer[8], layer[9]));
}

/// A layer at card position `uv`, blurred by its strength times `amount`.
static half4 sampleLayer(texture2d<half> atlas, constant float *layer, float2 uv, float amount) {
    int levels = int(layer[7]);
    // Copies are spaced by the square of their share of the full blur, so this lands on the level
    // matching strength * amount.
    float level = float(levels) * sqrt(saturate(layer[4] * amount));
    int lower = min(int(level), levels);
    float2 picture = uv * float2(layer[0], layer[1]) + float2(layer[2], layer[3]);
    half4 low = sampleCopy(atlas, layer, lower, picture);
    float between = level - float(lower);
    if (lower == levels || between < 0.002) { return low; }
    return mix(low, sampleCopy(atlas, layer, lower + 1, picture), half(between));
}

static float3 softLight(float3 below, float3 top) {
    float3 lifted = select(sqrt(below), ((16 * below - 12) * below + 4) * below, below <= 0.25);
    return select(below + (2 * top - 1) * (lifted - below), below - (1 - 2 * top) * below * (1 - below), top <= 0.5);
}

static float3 overlay(float3 below, float3 top) {
    return select(1 - 2 * (1 - top) * (1 - below), 2 * top * below, below <= 0.5);
}

/// `top` mixed onto `below`, both with premultiplied alpha.
static float4 blend(float4 top, float4 below, int mode) {
    if (mode == 1) { return min(top + below, 1.0); }
    if (mode == 2) { return top + below - top * below; }
    if (mode == 3 || mode == 4) {
        float3 s = top.rgb / max(top.a, 1e-4), b = below.rgb / max(below.a, 1e-4);
        float3 mixed = mode == 3 ? softLight(b, s) : overlay(b, s);
        return float4((1 - top.a) * below.rgb + (1 - below.a) * top.rgb + top.a * below.a * mixed,
                      top.a + below.a - top.a * below.a);
    }
    return top + below * (1 - top.a);
}

// Each layer's atlas is bound to its own slot rather than an array: picking a texture by index in a
// loop is a third slower.
fragment half4 cardFragment(Rasterized in [[stage_in]], constant float *values [[buffer(0)]],
                            texture2d<half> atlas0 [[texture(0)]], texture2d<half> atlas1 [[texture(1)]],
                            texture2d<half> atlas2 [[texture(2)]], texture2d<half> atlas3 [[texture(3)]],
                            texture2d<half> atlas4 [[texture(4)]], texture2d<half> atlas5 [[texture(5)]]) {
    float2 point = in.position.xy / values[11];
    half4 background = half4(half3(values[32], values[33], values[34]), 1);
    // Past the card's horizon, the card's plane is behind the eye.
    float w = point.x * values[2] + point.y * values[5] + values[8];
    if (w <= 0) { return background; }
    float2 uv = float2(point.x * values[0] + point.y * values[3] + values[6],
                       point.x * values[1] + point.y * values[4] + values[7]) / w;
    float2 spot = saturate(point / float2(values[9], values[10]));
    float2 card = float2(values[12], values[13]);

    float amount = effectAmount(values, 18, uv, spot);
    float sigma = min(card.x, card.y) / 8 * saturate(values[15] * amount);
    float covered = cardCoverage(uv, card, values[14], sigma);
    if (covered < 0.002) { return background; }

    float4 color = 0;
    int count = int(values[31]);
    #define MIX_LAYER(index, atlas) \
        if (count > index) { \
            constant float *layer = values + firstLayer + index * layerLength; \
            color = blend(float4(sampleLayer(atlas, layer, uv, amount)) * layer[5], color, int(layer[6])); \
        }
    MIX_LAYER(0, atlas0) MIX_LAYER(1, atlas1) MIX_LAYER(2, atlas2)
    MIX_LAYER(3, atlas3) MIX_LAYER(4, atlas4) MIX_LAYER(5, atlas5)

    // Colors are premultiplied, so darkening scales color and leaves coverage alone.
    if (values[30] > 0) { color.rgb *= 1 - saturate(values[30] * effectAmount(values, 24, uv, spot)); }
    // The card over the background, which also shows through any clear parts of the picture.
    float3 shown = color.rgb * covered + float3(background.rgb) * (1 - covered * color.a);
    // A little noise, under a step of 8-bit color, so slow dark fades don't band.
    float noise = fract(52.9829189 * fract(dot(in.position.xy, float2(0.06711056, 0.00583715))));
    return half4(half3(shown + (noise - 0.5) / 255), 1);
}
