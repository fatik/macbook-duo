#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// Draws the card in one pass. The atlas holds the sharp picture and copies blurred by
// maxBlur * (level / levels)^2, each with a clear margin the blur spills into, so each pixel works
// out how blurred it should be and blends the two nearest copies, like a lens focused on the screen.
// The same amount can also darken it.
//
// The view is the card plus a margin on every side, so blur can spread past the card's edges.
// `values` is packed by blurShaderValues in BlurAtlas.swift:
//
//   0 strength           1 kind (0 none, 1 depth, 2 edge on the card, 3 edge on the window)
//   2 edge (0 top, 1 bottom, 2 left, 3 right, 4 all)                3 front   4 width
//   5 depth at top       6 depth at bottom (how much farther away than the focus; negative is nearer)
//   7 full depth         8 side (-1 nearer only, 0 either, 1 farther only)
//   9-17 view position to window position (a projection, row-vector order)   18-19 window size
//   20-21 picture scale  22-23 picture offset (card to picture coordinates, for cropping)
//   24 levels            25-26 atlas size
//   27 dim                28-29 margin, as a fraction of the card's width and height
//   32 on: for each copy, sharp first, where the picture sits (x, y, width, height) and its margin

static float smootherstep01(float x) {
    x = saturate(x);
    return x * x * x * (x * (6 * x - 15) + 10);
}

/// One copy at card position `uv`; clear outside the copy's margin.
static half4 sampleCopy(texture2d<half> atlas, device const float *values, int copy, float2 uv, float2 cardPoints) {
    constexpr sampler linear(coord::normalized, filter::linear, address::clamp_to_edge);
    int base = 32 + copy * 5;
    float2 origin = float2(values[base], values[base + 1]);
    float2 extent = float2(values[base + 2], values[base + 3]);
    float margin = values[base + 4];

    float2 pixel = origin + uv * extent;
    float2 low = origin - margin + 0.5, high = origin + extent + margin - 0.5;
    if (any(pixel < low - 1) || any(pixel > high + 1)) { return half4(0); }
    half4 color = atlas.sample(linear, clamp(pixel, low, high) / float2(values[25], values[26]));

    if (copy == 0) {
        // The sharp copy stops at the card's edge, softened over about a point.
        float2 inside = min(uv, 1 - uv) * cardPoints;
        color *= half(saturate(min(inside.x, inside.y) + 0.5));
    }
    return color;
}

/// The picture at `uv`, blurred to `level` (a fractional copy number).
static half4 sampleBlurred(texture2d<half> atlas, device const float *values, float level, float2 uv, float2 cardPoints) {
    int levels = int(values[24]);
    int lower = min(int(level), levels);
    int upper = min(lower + 1, levels);
    float2 picture = uv * float2(values[20], values[21]) + float2(values[22], values[23]);
    half4 low = sampleCopy(atlas, values, lower, picture, cardPoints);
    if (upper == lower) { return low; }
    return mix(low, sampleCopy(atlas, values, upper, picture, cardPoints), half(level - float(lower)));
}

[[ stitchable ]] half4 cardBlur(float2 position, half4 color, float2 size, texture2d<half> atlas,
                               device const float *values, int count) {
    float2 margin = float2(values[28], values[29]);
    float2 uv = position / size * (1 + 2 * margin) - margin;   // on the card: 0 to 1
    float2 cardPoints = size / (1 + 2 * margin);
    float2 onCard = saturate(uv);
    int kind = int(values[1]);
    float amount = 0;

    if (kind == 1) {
        // Distance from the screen only changes from the card's top to its bottom.
        float depth = mix(values[5], values[6], onCard.y);
        float side = values[8];
        float counted = side < -0.5 ? max(-depth, 0.0) : side > 0.5 ? max(depth, 0.0) : abs(depth);
        // Like a lens: blur starts as soon as something leaves focus and grows steadily with
        // distance, easing into the full amount.
        float x = saturate(counted / values[7]);
        amount = 1 - (1 - x) * (1 - x);
    } else if (kind >= 2) {
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
        amount = smootherstep01((values[3] - max(fromEdge, 0.0)) / values[4]);
    }

    // Copies are spaced by the square of their share of the full blur, so this lands on the level
    // matching strength * amount.
    float level = float(int(values[24])) * sqrt(saturate(values[0] * amount));
    half4 shown = sampleBlurred(atlas, values, level, uv, cardPoints);
    // Colors are premultiplied, so darkening scales color and leaves coverage alone.
    shown.rgb *= half(1 - saturate(values[27] * amount));
    return shown;
}
