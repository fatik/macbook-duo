#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// Draws the card in one pass. The atlas holds the sharp picture and copies blurred by
// maxBlur * (level / levels)^2, so each pixel works out how blurred it should be and blends the two
// nearest copies, like a lens focused on the screen. The same amount can also darken it.
//
// The card's rounded outline softens as much as the blur is at that spot, fading in and spilling out
// the way an out-of-focus object's edge does. The view reaches past the card by a margin for that.
// A single picture is shaped by it directly; a stack of layers is drawn whole and then shaped once by
// `cardOutside` on top, so the layers don't show through each other at the edge.
//
// `values` is packed by blurShaderValues in BlurAtlas.swift:
//
//   0 strength           1 kind (0 none, 1 depth, 2 edge on the card, 3 edge on the window)
//   2 edge (0 top, 1 bottom, 2 left, 3 right, 4 all)                3 front   4 width
//   5 depth at top       6 depth at bottom (how much farther away than the focus; negative is nearer)
//   7 full depth         8 side (-1 nearer only, 0 either, 1 farther only)
//   9-17 view position to window position (a projection, row-vector order)   18-19 window size
//   20-21 picture scale  22-23 picture offset (card to picture coordinates, for cropping or for a
//         layer that covers only part of the card)
//   24 levels            25-26 atlas size
//   27 dim               28-29 margin, as a fraction of the card's width and height
//   30 corner radius of the card, in points     31 1 to shape the picture by the card's outline
//   32 on: for each copy, sharp first, where it sits in the atlas (x, y, width, height)

static float smootherstep01(float x) {
    x = saturate(x);
    return x * x * x * (x * (6 * x - 15) + 10);
}

/// Where this pixel is on the card (0 to 1, beyond that in the margin), and the card's size in points.
static void cardSpace(float2 position, float2 size, device const float *values, thread float2 &uv, thread float2 &points) {
    float2 margin = float2(values[28], values[29]);
    uv = position / size * (1 + 2 * margin) - margin;
    points = size / (1 + 2 * margin);
}

/// How much of the effect there is at this pixel, from 0 to 1.
static float effectAmount(float2 position, float2 uv, device const float *values) {
    float2 onCard = saturate(uv);
    int kind = int(values[1]);
    if (kind == 1) {
        // Distance from the screen only changes from the card's top to its bottom.
        float depth = mix(values[5], values[6], onCard.y);
        float side = values[8];
        float counted = side < -0.5 ? max(-depth, 0.0) : side > 0.5 ? max(depth, 0.0) : abs(depth);
        // Like a lens: blur starts as soon as something leaves focus and grows steadily with
        // distance, easing into the full amount.
        float x = saturate(counted / values[7]);
        return 1 - (1 - x) * (1 - x);
    }
    if (kind >= 2) {
        float2 spot = onCard;
        if (kind == 3) {
            float x = position.x * values[9] + position.y * values[12] + values[15];
            float y = position.x * values[10] + position.y * values[13] + values[16];
            float w = position.x * values[11] + position.y * values[14] + values[17];
            spot = saturate(float2(x, y) / w / float2(values[18], values[19]));
        }
        int edge = int(values[2]);
        float fromEdge = edge == 0 ? spot.y
                       : edge == 1 ? 1 - spot.y
                       : edge == 2 ? spot.x
                       : edge == 3 ? 1 - spot.x
                       : 1 - length(spot * 2 - 1);
        return smootherstep01((values[3] - max(fromEdge, 0.0)) / values[4]);
    }
    return 0;
}

/// The normal curve's cumulative share, approximated.
static float normalShare(float z) {
    return 1 / (1 + exp(-1.702 * z));
}

/// How much of the card covers this pixel: its rounded outline, blurred by `sigma` points. Where the
/// picture is sharp it's crisp; where it's blurred it fades inside and spills outside the edge.
static float cardCoverage(float2 uv, float2 points, float radius, float sigma) {
    radius = min(radius, min(points.x, points.y) / 2);
    sigma = max(sigma, 0.5);   // a point's worth of smoothing at the least
    float2 half_ = points / 2;
    float2 fromMiddle = abs(uv * points - half_);

    // Exact for a sharp outline: the rounded rectangle's distance.
    float2 q = fromMiddle - (half_ - radius);
    float outside = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
    float rounded = normalShare(-outside / sigma);
    // Right for a wide blur, which rounds any corner off anyway: each edge blurred on its own. It has
    // no crease along the diagonals, where the distance above does.
    float2 edges = fromMiddle - half_;
    float square = normalShare(-edges.x / sigma) * normalShare(-edges.y / sigma);
    return mix(rounded, square, smoothstep(0.5 * radius, 2 * radius, sigma));
}

/// The blur at this pixel, in points: up to an eighth of the card's shorter side.
static float blurSigma(float amount, float2 points, device const float *values) {
    return min(points.x, points.y) / 8 * saturate(values[0] * amount);
}

/// One copy at picture position `uv`, its edges extended beyond the picture.
static half4 sampleCopy(texture2d<half> atlas, device const float *values, int copy, float2 uv) {
    constexpr sampler linear(coord::normalized, filter::linear, address::clamp_to_edge);
    int base = 32 + copy * 4;
    float2 origin = float2(values[base], values[base + 1]);
    float2 extent = float2(values[base + 2], values[base + 3]);
    // Half a pixel in from the copy's edges, so filtering never reaches the neighboring copy.
    float2 pixel = origin + clamp(uv * extent, float2(0.5), extent - 0.5);
    return atlas.sample(linear, pixel / float2(values[25], values[26]));
}

/// The picture at card position `uv`, blurred to `level` (a fractional copy number).
static half4 sampleBlurred(texture2d<half> atlas, device const float *values, float level, float2 uv) {
    int levels = int(values[24]);
    int lower = min(int(level), levels);
    int upper = min(lower + 1, levels);
    float2 picture = uv * float2(values[20], values[21]) + float2(values[22], values[23]);
    half4 low = sampleCopy(atlas, values, lower, picture);
    if (upper == lower) { return low; }
    return mix(low, sampleCopy(atlas, values, upper, picture), half(level - float(lower)));
}

[[ stitchable ]] half4 cardBlur(float2 position, half4 color, float2 size, texture2d<half> atlas,
                               device const float *values, int count) {
    float2 uv, points;
    cardSpace(position, size, values, uv, points);
    float amount = effectAmount(position, uv, values);

    // Copies are spaced by the square of their share of the full blur, so this lands on the level
    // matching strength * amount.
    float level = float(int(values[24])) * sqrt(saturate(values[0] * amount));
    half4 shown = sampleBlurred(atlas, values, level, uv);
    // Colors are premultiplied, so darkening scales color and leaves coverage alone.
    shown.rgb *= half(1 - saturate(values[27] * amount));

    if (values[31] > 0.5) {
        shown *= half(cardCoverage(uv, points, values[30], blurSigma(amount, points, values)));
    }
    return shown;
}

/// Black wherever the card doesn't cover, drawn over a stack of layers on a black background: the
/// same as shaping the whole stack by the card's outline at once.
[[ stitchable ]] half4 cardOutside(float2 position, half4 color, float2 size, device const float *values, int count) {
    float2 uv, points;
    cardSpace(position, size, values, uv, points);
    float amount = effectAmount(position, uv, values);
    float covered = cardCoverage(uv, points, values[30], blurSigma(amount, points, values));
    return half4(0, 0, 0, half(1 - covered));
}
