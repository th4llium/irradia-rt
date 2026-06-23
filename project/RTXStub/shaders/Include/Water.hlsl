#ifndef __WATER_HLSL__
#define __WATER_HLSL__

#include "Generated/Signature.hlsl"
#include "Util.hlsl"

float hash1_water(float2 p)
{
    p = 50.0 * frac(p * 0.3183099);
    return frac(p.x * p.y * (p.x + p.y));
}

float noise_water(float2 x)
{
    float2 p = floor(x);
    float2 w = frac(x);
    float2 u = w * w * w * (w * (w * 6.0 - 15.0) + 10.0);

    float a = hash1_water(p + float2(0, 0));
    float b = hash1_water(p + float2(1, 0));
    float c = hash1_water(p + float2(0, 1));
    float d = hash1_water(p + float2(1, 1));

    return -1.0 + 2.0 * (a + (b - a) * u.x + (c - a) * u.y + (a - b - c + d) * u.x * u.y);
}

float get_water_height(float2 p, float time)
{
    p *= 0.15;
    float f = 2.0;
    float s = 0.4;
    float a = 0.0;
    float b = 0.5;
    const float2x2 m2 = float2x2(0.866025, 0.5, -0.5, 0.866025);

    for (int i = 0; i < 5; i++)
    {
        float n = noise_water(p + time * float2(0.6, -1.2));
        a += b * n;
        b *= s;
        p = mul(m2, p) * f;
    }
    return 3.0 * a;
}

#ifndef WATER_CAUSTICS_SPEED
#define WATER_CAUSTICS_SPEED 0.18
#endif

#ifndef WATER_CAUSTICS_SCALE
#define WATER_CAUSTICS_SCALE 0.65
#endif

#ifndef WATER_CAUSTICS_WARP
#define WATER_CAUSTICS_WARP 0.07
#endif

#ifndef WATER_CAUSTICS_STRENGTH
#define WATER_CAUSTICS_STRENGTH 2.35
#endif

#ifndef WATER_CAUSTICS_BASE
#define WATER_CAUSTICS_BASE 0.35
#endif

#ifndef WATER_CAUSTICS_MAX
#define WATER_CAUSTICS_MAX 6.0
#endif

#ifndef WATER_CAUSTICS_DISTANCE_FADE
#define WATER_CAUSTICS_DISTANCE_FADE 0.035
#endif

float4 WaterCausticMod289(float4 x)
{
    return x - floor(x / 289.0) * 289.0;
}

float4 WaterCausticPermute(float4 x)
{
    return WaterCausticMod289((x * 34.0 + 1.0) * x);
}

float4 WaterCausticSimplex(float3 v)
{
    const float2 C = float2(1.0 / 6.0, 1.0 / 3.0);

    float3 i  = floor(v + dot(v, C.yyy));
    float3 x0 = v - i + dot(i, C.xxx);

    float3 g = step(x0.yzx, x0.xyz);
    float3 l = 1.0 - g;
    float3 i1 = min(g.xyz, l.zxy);
    float3 i2 = max(g.xyz, l.zxy);

    float3 x1 = x0 - i1 + C.x;
    float3 x2 = x0 - i2 + C.y;
    float3 x3 = x0 - 0.5;

    float4 p =
        WaterCausticPermute(WaterCausticPermute(WaterCausticPermute(i.z + float4(0.0, i1.z, i2.z, 1.0))
                                                         + i.y + float4(0.0, i1.y, i2.y, 1.0))
                                                         + i.x + float4(0.0, i1.x, i2.x, 1.0));

    float4 j = p - 49.0 * floor(p / 49.0);

    float4 x_ = floor(j / 7.0);
    float4 y_ = floor(j - 7.0 * x_);

    float4 x = (x_ * 2.0 + 0.5) / 7.0 - 1.0;
    float4 y = (y_ * 2.0 + 0.5) / 7.0 - 1.0;

    float4 h = 1.0 - abs(x) - abs(y);

    float4 b0 = float4(x.xy, y.xy);
    float4 b1 = float4(x.zw, y.zw);

    float4 s0 = floor(b0) * 2.0 + 1.0;
    float4 s1 = floor(b1) * 2.0 + 1.0;
    float4 sh = -step(h, float4(0.0, 0.0, 0.0, 0.0));

    float4 a0 = b0.xzyw + s0.xzyw * sh.xxyy;
    float4 a1 = b1.xzyw + s1.xzyw * sh.zzww;

    float3 g0 = float3(a0.xy, h.x);
    float3 g1 = float3(a0.zw, h.y);
    float3 g2 = float3(a1.xy, h.z);
    float3 g3 = float3(a1.zw, h.w);

    float4 m = max(0.6 - float4(dot(x0, x0), dot(x1, x1), dot(x2, x2), dot(x3, x3)), 0.0);
    float4 m2 = m * m;
    float4 m3 = m2 * m;
    float4 m4 = m2 * m2;
    float3 grad =
        -6.0 * m3.x * x0 * dot(x0, g0) + m4.x * g0 +
        -6.0 * m3.y * x1 * dot(x1, g1) + m4.y * g1 +
        -6.0 * m3.z * x2 * dot(x2, g2) + m4.z * g2 +
        -6.0 * m3.w * x3 * dot(x3, g3) + m4.w * g3;

    float4 px = float4(dot(x0, g0), dot(x1, g1), dot(x2, g2), dot(x3, g3));
    return 42.0 * float4(grad, dot(m4, px));
}

float CalcProceduralWaterCaustics(float3 waterHitPosition, float receiverToWaterDistance)
{
    float3 pos = float3(
        waterHitPosition.x * WATER_CAUSTICS_SCALE,
        g_view.time * WATER_CAUSTICS_SPEED,
        waterHitPosition.z * WATER_CAUSTICS_SCALE);

    float4 n = WaterCausticSimplex(pos);
    pos -= WATER_CAUSTICS_WARP * n.xyz;
    n = WaterCausticSimplex(pos);
    pos -= WATER_CAUSTICS_WARP * n.xyz;
    n = WaterCausticSimplex(pos);

    float lineIntensity = exp(n.w * 3.0 - 1.5);
    float caustics = lineIntensity * WATER_CAUSTICS_STRENGTH + WATER_CAUSTICS_BASE;
    caustics = clamp(caustics, 0.25, WATER_CAUSTICS_MAX);

    float distanceFade = exp2(-max(receiverToWaterDistance, 0.0) * WATER_CAUSTICS_DISTANCE_FADE);
    return lerp(1.0, caustics, distanceFade);
}

float3 CalcWaterCausticTransmission(float3 waterHitPosition, float receiverToWaterDistance)
{
    float caustics = CalcProceduralWaterCaustics(waterHitPosition, receiverToWaterDistance);
    float3 waterExtinction =
        float3(0.8, 0.2, 0.05) * 0.0125;
    float3 waterTransmittance = exp(-waterExtinction * max(receiverToWaterDistance, 0.0));
    return waterTransmittance * caustics;
}

float3 GetWaterNormal(float3 p, float time, float3 geomNormal) {
    float2 n = float2(0.0, 0.0);
    float2 d1 = float2(0.8944, 0.4472);
    float f1 = dot(p.xz, d1) * 1.5 + time * 1.5;
    n += d1 * cos(f1) * 0.025;
    
    float2 d2 = float2(-0.5299, 0.8480);
    float f2 = dot(p.xz, d2) * 2.0 + time * 2.0;
    n += d2 * cos(f2) * 0.020;
    
    float2 d3 = float2(0.2873, -0.9578);
    float f3 = dot(p.xz, d3) * 3.0 + time * 2.5;
    n += d3 * cos(f3) * 0.015;
    
    float2 d4 = float2(-0.8, -0.6);
    float f4 = dot(p.xz, d4) * 4.0 + time * 3.0;
    n += d4 * cos(f4) * 0.010;
    
    float3 tangentNormal = normalize(float3(n.x, 1.0, n.y));
    
    float dist = length(p - g_view.viewOriginSteveSpace);
    float fade = saturate((dist - 30.0) / 70.0);
    tangentNormal = normalize(lerp(tangentNormal, float3(0.0, 1.0, 0.0), fade));
    
    float3 up = abs(geomNormal.y) < 0.999 ? float3(0,1,0) : float3(1,0,0);
    float3 right = normalize(cross(up, geomNormal));
    float3 forward = cross(geomNormal, right);
    return normalize(right * tangentNormal.x + geomNormal * tangentNormal.y + forward * tangentNormal.z);
}

#endif
