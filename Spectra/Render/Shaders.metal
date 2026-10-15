#include <metal_stdlib>
using namespace metal;

// Spectra's one renderer (SPEC.md §3.3, gyre-integration.md §4.6): a half-float HDR scene,
// two glowing line materials sharing one bloom chain, and a composite soft-clipped into the
// display's EDR headroom.
//
//   holo      3D instanced segments with butt caps, depth-tested (Gyre lineVertex/Fragment)
//   phosphor  2D analytic capsules in screen points with glow, dashes and hollow dots
//             (Orbitals Phosphor.metal), added into HDR instead of blended over
//
// Every colour reaching the scene target is linear light; the drawable is extended linear
// Display P3, so values above 1 glow brighter than white on XDR panels.

// MARK: - Shared types (mirror Render/SceneBuffer.swift)

struct FrameUniforms {
    float4x4 viewProj;   // world → clip
    float4 viewport;     // width px, height px, content scale, time (s)
    float4 eye;          // camera position (world), unused
    float4 post;         // bloom strength, scanline depth, EDR headroom, reduce motion
    float4 background;   // mode (0 clear, 1 instrument grid, 2 plain well), grid pitch (pt), vignette, unused
};

struct GlowSegment {
    float4 a;      // holo: world xyz, width (pt) · phosphor: xy (pt), unused, radius (pt)
    float4 b;
    float4 ca;     // linear rgb × intensity, alpha
    float4 cb;
    float4 style;  // glow 0…1, dash period (pt), dash offset (pt), hollow radius (pt)
};

constexpr sampler linearClamp(filter::linear, address::clamp_to_edge);

static inline float3 srgbToLinear(float3 c) {
    float3 lo = c / 12.92;
    float3 hi = pow((c + 0.055) / 1.055, 2.4);
    return select(hi, lo, c <= 0.04045);
}

// MARK: - Fullscreen

struct FSOut {
    float4 position [[position]];
    float2 uv;
};

vertex FSOut fullscreenVertex(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    FSOut o;
    o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    o.uv = float2(p.x, 1.0 - p.y);
    return o;
}

// The instrument ground (Orbitals instrumentFragment): the plot-well colour with a 32 pt
// phosphor grid, a brighter centre cross, a vignette and faint scanlines.
fragment float4 backgroundFragment(FSOut in [[stage_in]], constant FrameUniforms& u [[buffer(0)]]) {
    float scale = max(u.viewport.z, 1.0);
    float2 size = u.viewport.xy / scale;
    float2 pt = in.position.xy / scale;
    float2 c = (pt - size * 0.5) / max(size.x, size.y);
    float vignette = mix(1.0, clamp(1.0 - dot(c, c) * 1.7, 0.35, 1.0), u.background.z);
    float3 base = float3(0.016, 0.031, 0.027);   // #040807 lifted a touch, sRGB
    float3 color = base;
    if (u.background.x > 0.5 && u.background.x < 1.5) {
        float pitch = max(u.background.y, 4.0);
        float2 cell = abs(fract((pt - size * 0.5) / pitch + 0.5) - 0.5) * pitch;
        float grid = 1.0 - smoothstep(0.2, 0.75, min(cell.x, cell.y));
        float major = 1.0 - smoothstep(0.25, 0.7, min(abs(pt.x - size.x * 0.5), abs(pt.y - size.y * 0.5)));
        float3 gridColor = float3(0.075, 0.13, 0.092);
        float scan = u.post.w > 0.5 ? 1.0 : 0.96 + 0.04 * cos(pt.y * 3.14159265);
        color = (base + gridColor * (grid * 0.22 + major * 0.15)) * scan;
    }
    return float4(srgbToLinear(color * vignette), 1.0);
}

// MARK: - Holo lines (3D)

struct HoloOut {
    float4 position [[position]];
    float2 px;
    float2 sa [[flat]];
    float2 sb [[flat]];
    float wa [[flat]];
    float wb [[flat]];
    float4 ca [[flat]];
    float4 cb [[flat]];
    float4 style [[flat]];
};

vertex HoloOut holoVertex(uint vid [[vertex_id]],
                          uint iid [[instance_id]],
                          const device GlowSegment* lines [[buffer(0)]],
                          constant FrameUniforms& u [[buffer(1)]]) {
    GlowSegment L = lines[iid];
    float scale = max(u.viewport.z, 1.0);
    float4 ka = u.viewProj * float4(L.a.xyz, 1.0);
    float4 kb = u.viewProj * float4(L.b.xyz, 1.0);
    HoloOut o;
    o.px = 0.0;
    o.sa = 0.0;
    o.sb = 0.0;
    o.wa = L.a.w * scale;
    o.wb = L.b.w * scale;
    o.ca = L.ca;
    o.cb = L.cb;
    o.style = L.style;
    // Behind the camera: move off screen.
    if (ka.w < 0.01 || kb.w < 0.01) {
        o.position = float4(10.0, 10.0, 0.5, 1.0);
        return o;
    }
    float2 sa = (ka.xy / ka.w * float2(0.5, -0.5) + 0.5) * u.viewport.xy;
    float2 sb = (kb.xy / kb.w * float2(0.5, -0.5) + 0.5) * u.viewport.xy;
    float2 d = sb - sa;
    float len = length(d);
    float2 dir = len > 1e-3 ? d / len : float2(1.0, 0.0);
    float2 nrm = float2(-dir.y, dir.x);
    float wmax = max(o.wa, o.wb);
    float half_ = wmax * 0.5 + wmax * 2.2 + 2.0;
    float t = (vid & 1) ? 1.0 : 0.0;
    float s = (vid & 2) ? 1.0 : -1.0;
    // Segments of a polyline butt together without caps, so additive joints don't double
    // up into beads; a lone point gets a round dot (Gyre).
    float cap = len > 1.5 ? 0.0 : half_;
    float2 p = mix(sa, sb, t) + dir * (t * 2.0 - 1.0) * cap + nrm * s * half_;
    float z = mix(ka.z / ka.w, kb.z / kb.w, len > 1.5 ? t : 0.0);
    o.position = float4(p.x / u.viewport.x * 2.0 - 1.0, 1.0 - p.y / u.viewport.y * 2.0, clamp(z, 0.0, 1.0), 1.0);
    o.px = p;
    o.sa = sa;
    o.sb = sb;
    return o;
}

fragment float4 holoFragment(HoloOut in [[stage_in]], constant FrameUniforms& u [[buffer(1)]]) {
    float scale = max(u.viewport.z, 1.0);
    float2 d = in.sb - in.sa;
    float len2 = dot(d, d);
    float along = len2 > 1e-6 ? dot(in.px - in.sa, d) / len2 : 0.0;
    float t = saturate(along);
    float dist = length(in.px - (in.sa + d * (len2 > 2.25 ? along : t)));
    float w = mix(in.wa, in.wb, t) * 0.5;
    float4 c = mix(in.ca, in.cb, t);
    float core = 1.0 - smoothstep(w - 0.6, w + 0.9, dist);
    float g = w * 2.2 + 1.5;
    float glow = exp(-dist * dist / (g * g)) * 0.45 * in.style.x;
    float alpha = c.a;
    if (in.style.y > 0.0) {
        float period = in.style.y * scale;
        float pos = t * sqrt(len2) + in.style.z * scale;
        float dash = fmod(pos, period);
        alpha *= 1.0 - smoothstep(period * 0.56 - 1.0, period * 0.56 + 1.0, dash);
    }
    return float4(c.rgb * alpha * (core + glow), 0.0);
}

// MARK: - Phosphor capsules (2D)

struct PhosphorOut {
    float4 position [[position]];
    float2 point;
    float2 start [[flat]];
    float2 end [[flat]];
    float radius [[flat]];
    float4 ca [[flat]];
    float4 cb [[flat]];
    float4 style [[flat]];
};

vertex PhosphorOut phosphorVertex(uint vid [[vertex_id]],
                                  uint iid [[instance_id]],
                                  const device GlowSegment* segments [[buffer(0)]],
                                  constant FrameUniforms& u [[buffer(1)]]) {
    GlowSegment S = segments[iid];
    float scale = max(u.viewport.z, 1.0);
    float2 size = u.viewport.xy / scale;
    float2 a = S.a.xy;
    float2 b = S.b.xy;
    float radius = max(S.a.w, 0.25);
    float2 delta = b - a;
    float lineLength = length(delta);
    float2 tangent = lineLength > 0.0001 ? delta / lineLength : float2(1, 0);
    float2 normal = float2(-tangent.y, tangent.x);
    float glowRadius = S.style.x > 0 ? 3 + 7 * S.style.x : 0;
    float padding = radius + glowRadius + 1.5;
    float2 corner = float2(float(vid & 1), float((vid >> 1) & 1));
    float2 p = a + tangent * mix(-padding, lineLength + padding, corner.x) + normal * mix(-padding, padding, corner.y);
    PhosphorOut o;
    o.position = float4(p.x / size.x * 2 - 1, 1 - p.y / size.y * 2, 0, 1);
    o.point = p;
    o.start = a;
    o.end = b;
    o.radius = radius;
    o.ca = S.ca;
    o.cb = S.cb;
    o.style = S.style;
    return o;
}

fragment float4 phosphorFragment(PhosphorOut in [[stage_in]], constant FrameUniforms& u [[buffer(1)]]) {
    float2 delta = in.end - in.start;
    float lengthSquared = dot(delta, delta);
    float t = lengthSquared > 0.0001 ? clamp(dot(in.point - in.start, delta) / lengthSquared, 0.0, 1.0) : 0;
    float distance = length(in.point - (in.start + t * delta));
    float edge = max(0.5 / max(u.viewport.z, 1.0), fwidth(distance) * 0.6);
    float radius = in.radius;
    float hollow = in.style.w;
    float core = 1 - smoothstep(radius - edge, radius + edge, distance);
    if (hollow > 0) {
        core *= smoothstep(hollow - edge, hollow + edge, distance);
    }
    float outside = max(0.0, distance - radius);
    float spread = 1.4 + in.style.x * 3.1;
    float glow = exp(-outside * outside / (spread * spread)) * in.style.x * 0.34;
    if (hollow > 0 && distance < hollow) {
        glow *= smoothstep(max(0.0, hollow - 2), hollow, distance);
    }
    float4 c = mix(in.ca, in.cb, t);
    float alpha = (core + glow * (1 - core)) * c.a;
    if (in.style.y > 0) {
        float along = t * sqrt(lengthSquared) + in.style.z;
        float dash = fmod(along, in.style.y);
        alpha *= 1 - smoothstep(in.style.y * 0.56 - edge, in.style.y * 0.56 + edge, dash);
    }
    float3 color = c.rgb;
    // A lone dot gets a hot white core (Orbitals particles).
    if (lengthSquared < 0.0001 && hollow == 0) {
        color = mix(color, float3(max(max(color.r, color.g), color.b)), 0.52 * (1 - smoothstep(0.0, radius, distance)));
    }
    return float4(color * alpha, 0.0);
}

// MARK: - Bloom (Gyre)

fragment float4 prefilterFragment(FSOut in [[stage_in]], texture2d<float> src [[texture(0)]]) {
    float3 c = src.sample(linearClamp, in.uv).rgb;
    float peak = max(c.r, max(c.g, c.b));
    return float4(c * smoothstep(0.35, 1.3, peak), 1.0);
}

fragment float4 copyFragment(FSOut in [[stage_in]], texture2d<float> src [[texture(0)]]) {
    return float4(src.sample(linearClamp, in.uv).rgb, 1.0);
}

// A 5-tap linear-sampled Gaussian along `texelStep`.
fragment float4 blurFragment(FSOut in [[stage_in]],
                             texture2d<float> src [[texture(0)]],
                             constant float2& texelStep [[buffer(0)]]) {
    float3 c = src.sample(linearClamp, in.uv).rgb * 0.2270270270;
    float2 o1 = texelStep * 1.3846153846;
    float2 o2 = texelStep * 3.2307692308;
    c += src.sample(linearClamp, in.uv + o1).rgb * 0.3162162162;
    c += src.sample(linearClamp, in.uv - o1).rgb * 0.3162162162;
    c += src.sample(linearClamp, in.uv + o2).rgb * 0.0702702703;
    c += src.sample(linearClamp, in.uv - o2).rgb * 0.0702702703;
    return float4(c, 1.0);
}

// MARK: - Composite

// Highlights roll off smoothly from 0.8 up to the display's EDR headroom (≤ 3× SDR white).
static inline float softClip(float x, float headroom) {
    float k = 0.8;
    float h = max(headroom, 1.0);
    if (x <= k) return x;
    if (h - k < 1e-3) return k;
    return k + (h - k) * (1.0 - exp(-(x - k) / (h - k)));
}

fragment float4 compositeFragment(FSOut in [[stage_in]],
                                  texture2d<float> scene [[texture(0)]],
                                  texture2d<float> bloomHalf [[texture(1)]],
                                  texture2d<float> bloomQuarter [[texture(2)]],
                                  constant FrameUniforms& u [[buffer(0)]]) {
    float2 uv = in.uv;
    float3 c = scene.sample(linearClamp, uv).rgb;
    c += bloomHalf.sample(linearClamp, uv).rgb * u.post.x;
    c += bloomQuarter.sample(linearClamp, uv).rgb * u.post.x * 0.9;
    c *= 1.0 - u.post.y * (0.5 + 0.5 * sin(in.position.y * 2.0944 + u.viewport.w * 4.0));
    float headroom = min(u.post.z, 3.0);
    c = float3(softClip(c.r, headroom), softClip(c.g, headroom), softClip(c.b, headroom));
    return float4(max(c, 0.0), 1.0);
}
