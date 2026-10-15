#include <metal_stdlib>
using namespace metal;

// The Scope's phosphor display (owner: scope; SPEC-features §3b). A real persistence buffer:
//
//   1. accumulation   an rgba16Float texture that survives between frames. Each frame it is
//                     multiplied by k = exp(−Δt/τ) (blend with a constant colour, see
//                     ScopeRenderer) and the beam's new sweeps are added into it with the
//                     foundation's phosphor capsules (Shaders.metal phosphorVertex/Fragment).
//   2. scene          the 10 × 8 graticule (scopeGraticuleFragment), plus the accumulation,
//                     plus this frame's crisp overlay (current sweep, cursors, markers).
//   3. bloom          the foundation's prefilter / blur / copy chain at ½ and ¼ resolution.
//   4. composite      scopeCompositeFragment: scene + bloom, soft-clipped into the EDR headroom.
//
// Every colour is linear light; the drawable is extended linear Display P3.

struct ScopeUniforms {
    float4 viewport;   // width px, height px, content scale, unused
    float4 grid;       // columns, rows, intensity, inset (pt)
    float4 post;       // bloom, accumulation gain, EDR headroom, reduce motion
};

struct ScopeFSOut {
    float4 position [[position]];
    float2 uv;
};

constexpr sampler scopeSampler(filter::linear, address::clamp_to_edge);

static inline float3 scopeSRGBToLinear(float3 c) {
    float3 lo = c / 12.92;
    float3 hi = pow((c + 0.055) / 1.055, 2.4);
    return select(hi, lo, c <= 0.04045);
}

vertex ScopeFSOut scopeFullscreenVertex(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    ScopeFSOut o;
    o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    o.uv = float2(p.x, 1.0 - p.y);
    return o;
}

// Multiplied into the accumulation by the blend unit (destination × blend colour); the
// fragment itself contributes nothing.
fragment float4 scopeFadeFragment(ScopeFSOut in [[stage_in]]) {
    return float4(0.0);
}

// The graticule of a bench oscilloscope: 10 × 8 major divisions, the two centre axes with
// five minor ticks per division, a frame, and the plot-well ground with a soft vignette.
fragment float4 scopeGraticuleFragment(ScopeFSOut in [[stage_in]], constant ScopeUniforms& u [[buffer(0)]]) {
    float scale = max(u.viewport.z, 1.0);
    float2 size = u.viewport.xy / scale;
    float2 pt = in.position.xy / scale;
    float inset = u.grid.w;
    float2 area = max(size - 2.0 * inset, float2(1.0));
    float2 q = pt - inset;                       // points inside the graticule area
    float2 cols = u.grid.xy;
    float2 div = area / cols;                    // points per division
    float px = 1.0 / scale;                      // one device pixel in points
    float3 base = float3(0.016, 0.031, 0.027);
    float2 c = (pt - size * 0.5) / max(size.x, size.y);
    float vignette = clamp(1.0 - dot(c, c) * 1.2, 0.55, 1.0);
    float3 color = base * vignette;
    bool inside = all(q >= -0.5) && all(q <= area + 0.5);
    if (inside) {
        // Major division lines (dotted like a printed graticule).
        float2 cell = abs(fract(q / div + 0.5) - 0.5) * div;
        float line = 1.0 - smoothstep(0.35 * px, 0.35 * px + 0.75, min(cell.x, cell.y));
        float dots = 0.55 + 0.45 * step(0.5, fract((cell.x < cell.y ? q.y : q.x) / 3.0));
        // Centre axes, brighter and solid, with minor ticks every 1/5 division.
        float2 mid = area * 0.5;
        float2 dc = abs(q - mid);
        float axis = 1.0 - smoothstep(0.4 * px, 0.4 * px + 0.75, min(dc.x, dc.y));
        float2 minor = abs(fract(q / (div / 5.0) + 0.5) - 0.5) * (div / 5.0);
        float tickX = (dc.y < 3.0) ? 1.0 - smoothstep(0.3, 1.0, minor.x) : 0.0;
        float tickY = (dc.x < 3.0) ? 1.0 - smoothstep(0.3, 1.0, minor.y) : 0.0;
        // Frame.
        float2 e = min(q, area - q);
        float frame = 1.0 - smoothstep(0.4 * px, 0.4 * px + 0.8, min(e.x, e.y));
        float3 gridColor = float3(0.18, 0.42, 0.28);
        float k = u.grid.z;
        color += gridColor * k * (line * dots * 0.32 + axis * 0.42 + max(tickX, tickY) * 0.38 + frame * 0.5);
    }
    return float4(scopeSRGBToLinear(color), 1.0);
}

// Adds the persistence buffer into the scene with a gain.
fragment float4 scopeAccumulationFragment(ScopeFSOut in [[stage_in]],
                                          texture2d<float> accumulation [[texture(0)]],
                                          constant ScopeUniforms& u [[buffer(0)]]) {
    float3 c = accumulation.sample(scopeSampler, in.uv).rgb * u.post.y;
    return float4(c, 0.0);
}

static inline float scopeSoftClip(float x, float headroom) {
    float k = 0.8;
    float h = max(headroom, 1.0);
    if (x <= k) return x;
    if (h - k < 1e-3) return k;
    return k + (h - k) * (1.0 - exp(-(x - k) / (h - k)));
}

fragment float4 scopeCompositeFragment(ScopeFSOut in [[stage_in]],
                                       texture2d<float> scene [[texture(0)]],
                                       texture2d<float> bloomHalf [[texture(1)]],
                                       texture2d<float> bloomQuarter [[texture(2)]],
                                       constant ScopeUniforms& u [[buffer(0)]]) {
    float3 c = scene.sample(scopeSampler, in.uv).rgb;
    c += bloomHalf.sample(scopeSampler, in.uv).rgb * u.post.x;
    c += bloomQuarter.sample(scopeSampler, in.uv).rgb * u.post.x * 0.9;
    float headroom = min(u.post.z, 3.0);
    c = float3(scopeSoftClip(c.r, headroom), scopeSoftClip(c.g, headroom), scopeSoftClip(c.b, headroom));
    return float4(max(c, 0.0), 1.0);
}
