/* MIT License
 * 
 * Copyright (c) 2025 veka0
 * Copyright (c) 2026 th4llium
 * 
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 * 
 * The above copyright notice and this permission notice shall be included in all
 * copies or substantial portions of the Software.
 * 
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 */

#ifndef __UTIL_HLSL__
#define __UTIL_HLSL__

float sq(float x) { return x*x; }
float pow4(float x) { return sq(x)*sq(x); }
float pow8(float x) { return pow4(x)*pow4(x); }
float getLuminance(float3 color) { return dot(color, float3(0.2126, 0.7152, 0.0722)); }

float safeRcp(float x) {
    return abs(x) > 1.0e-6 ? rcp(x) : 0.0;
}

float3 safeNormalize(float3 v, float3 fallback) {
    float lenSq = dot(v, v);
    return lenSq > 1.0e-12 ? v * rsqrt(lenSq) : fallback;
}

float2 ndirToOct(float3 n) {
    float2 p = n.xy * (1.0 / (abs(n.x) + abs(n.y) + abs(n.z)));
    if (n.z < 0.0) {
        p = (1.0 - abs(p.yx)) * (step(0.0, p.xy) * 2.0 - 1.0);
    }
    return p;
}

float3 hash32(float2 p) {
    float3 p3 = frac(float3(p.xyx) * float3(.1031, .1030, .0973));
    p3 += dot(p3, p3.yxz+33.33);
    return frac((p3.xxy+p3.yzz)*p3.zyx);
}

uint rand_pcg(inout uint rng_state) {
    uint state = rng_state;
    rng_state = rng_state * 747796405u + 2891336453u;
    uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    return (word >> 22u) ^ word;
}

float randFloat(inout uint rng_state) {
    return float(rand_pcg(rng_state)) / 4294967296.0;
}

float2 randFloat2(inout uint rng_state) {
    return float2(randFloat(rng_state), randFloat(rng_state));
}

float3 randFloat3(inout uint rng_state) {
    return float3(randFloat(rng_state), randFloat(rng_state), randFloat(rng_state));
}


#include "Generated/Signature.hlsl"
#include "Constants.hlsl"

uint3 getDispatchDimensions() {
    return uint3(
        (g_dispatchDimensions >> 0*10) & 1023, 
        (g_dispatchDimensions >> 1*10) & 1023,
        g_dispatchDimensions >> 2*10
    );
}

float2 computeMotionVector(float3 steveSpacePosition, float3 steveSpaceMotion) {
    float4 clipPos = mul(float4(steveSpacePosition, 1), g_view.viewProj);
    float2 ndcPos = clipPos.xy * safeRcp(clipPos.w);

    float3 prevHitPos = steveSpacePosition - steveSpaceMotion;
    float4 prevClipPos = mul(float4(prevHitPos, 1), g_view.prevViewProj);
    float2 prevNdcPos = prevClipPos.xy * safeRcp(prevClipPos.w);

    return (prevNdcPos - ndcPos) * float2(0.5, -0.5);
}

float3 rayDirFromNDC(float2 ndc) {
    const float kNdcDepth = 0.5;
    float4 steveSpacePos = mul(
        float4(ndc, kNdcDepth, 1), g_view.invViewProj);
    steveSpacePos.xyz /= steveSpacePos.w;
    return normalize(steveSpacePos.xyz - g_view.viewOriginSteveSpace);
}

bool isUpscalingEnabled() {
    return !g_view.enableTAA;
}

float2 getNDCjittered(uint2 pixelCoord) {
    float2 ndc = g_view.recipRenderResolution * (pixelCoord + 0.5 + (isUpscalingEnabled() ? g_view.subPixelJitter : 0));
    return mad(ndc, float2(2, -2), float2(-1, 1));
}

float4 unpackNormal(uint packedNormal) {
    return float4(
        (int)((packedNormal << 8*3) & 0xff000000) >> 24, 
        (int)((packedNormal << 8*2) & 0xff000000) >> 24, 
        (int)((packedNormal << 8*1) & 0xff000000) >> 24, 
        (int)((packedNormal << 8*0) & 0xff000000) >> 24
    ) / 127.0;
}

uint packNormal(float4 normal) {
    int4 normalInt = int4(round(normal*127));
    return (
        ((uint)(normalInt.x << 24) >> 8*3) | 
        ((uint)(normalInt.y << 24) >> 8*2) | 
        ((uint)(normalInt.z << 24) >> 8*1) | 
        ((uint)(normalInt.w << 24) >> 8*0)
    );
}

float4 unpackVertexColor(uint packedColor) {
    return float4(
        (packedColor >> 8 * 0) & 0xff, 
        (packedColor >> 8 * 1) & 0xff, 
        (packedColor >> 8 * 2) & 0xff, 
        (packedColor >> 8 * 3) & 0xff
    ) / 255.0;
}

float4 unpackObjectInstanceTintColor(uint packedColor) {
    return float4(
        (packedColor >> 8 * 3) & 0xff, 
        (packedColor >> 8 * 2) & 0xff, 
        (packedColor >> 8 * 1) & 0xff, 
        (packedColor >> 8 * 0) & 0xff
    ) / 255.0;
}

float2 unpackVertexUV(uint packedUV, bool packedUvIncludesBias = false) {
    const float uvScale = 1.0 / 65535.0;
    const float biasScale = 1.0 / 32768.0;

    if (packedUvIncludesBias) {
        float2 uv = float2(packedUV << 1u & 0xfffeu, packedUV >> 15u & 0xfffeu) * uvScale;
        float2 bias = (float2(packedUV >> 15u & 1u, packedUV >> 31u) * 2.0 - 1.0) * biasScale;

        return uv + bias;
    } else {
        float2 uv = float2(packedUV & 0xffff, packedUV >> 16) * uvScale;

        uv = round(uv * 32768) * (1.0 / 32768.0);

        return uv;
    }
}

#ifndef SKY_BACKGROUND_TYPE_END
#define SKY_BACKGROUND_TYPE_END 2u
#endif

#ifndef SKY_LIGHTING_TYPE_END
#define SKY_LIGHTING_TYPE_END 2u
#endif

#ifndef END_CELESTIAL_DIRECTION
#define END_CELESTIAL_DIRECTION float3(-0.36, 0.86, 0.36)
#endif

float3 GetEndCelestialDirection()
{
    return safeNormalize(
        END_CELESTIAL_DIRECTION,
        float3(-0.36, 0.86, 0.36));
}

bool IsEndSky()
{
    float overrideLuminance =
        getLuminance(max(g_view.finalCombineSkyColourOverride, 0.0));
    float skyLuminance =
        getLuminance(
            max(g_view.skyColor, 0.0)
            + max(g_view.skyColorUp, 0.0)
            + max(g_view.skyColorDown, 0.0))
        * (1.0 / 3.0);

    bool explicitEndBackground =
        g_view.skyBackgroundType == SKY_BACKGROUND_TYPE_END
        || g_view.skyLightingType == SKY_LIGHTING_TYPE_END;
    bool blackSkyOverride =
        g_view.finalCombineSkyColourOverrideStrength > 0.50
        && overrideLuminance < 0.015;
    bool blackEngineSky =
        g_view.skyColorBlend > 0.50
        && g_view.skyTextureW <= 0.02
        && skyLuminance < 0.018;

    return explicitEndBackground || blackSkyOverride || blackEngineSky;
}

bool isMoonPrimaryLight() {
    if (IsEndSky())
        return false;

    if (abs(g_view.directionToSun.y) > 0.999) return g_view.skyTextureW > 0.9;
    float angle1 = g_view.sunAzimuth - PI;
    float angle2 = atan2(g_view.directionToSun.z, g_view.directionToSun.x);
    float angleDiff = abs(angle1-angle2);
    return min(angleDiff, (2*PI)-angleDiff) > 0.001;
}

float3 getTrueDirectionToSun() {
    if (IsEndSky())
        return GetEndCelestialDirection();

    return isMoonPrimaryLight() ? -g_view.directionToSun : g_view.directionToSun;
}

float3 getTrueDirectionToMoon() {
    if (IsEndSky())
        return -GetEndCelestialDirection();

    return isMoonPrimaryLight() ? g_view.directionToSun : -g_view.directionToSun;
}

float3 offsetCelestialDirection(float3 direction) {
    float sine;
    float cosine;
    sincos(CELESTIAL_AZIMUTH_OFFSET_RADIANS, sine, cosine);
    return safeNormalize(
        float3(
            cosine * direction.x - sine * direction.z,
            direction.y,
            sine * direction.x + cosine * direction.z),
        direction);
}

float3 getOffsetPrimaryCelestialDirection() {
    if (IsEndSky())
        return GetEndCelestialDirection();

    return offsetCelestialDirection(g_view.directionToSun);
}

float3 getOffsetTrueDirectionToSun() {
    if (IsEndSky())
        return GetEndCelestialDirection();

    return offsetCelestialDirection(getTrueDirectionToSun());
}

float3 getOffsetTrueDirectionToMoon() {
    if (IsEndSky())
        return -GetEndCelestialDirection();

    return offsetCelestialDirection(getTrueDirectionToMoon());
}

#ifndef WEATHER_RAIN_CLOUD_BASE_HEIGHT
#define WEATHER_RAIN_CLOUD_BASE_HEIGHT 300.0
#endif

#ifndef WEATHER_RAIN_CLOUD_THICKNESS
#define WEATHER_RAIN_CLOUD_THICKNESS 160.0
#endif

#ifndef WEATHER_RAIN_CLOUD_COVERAGE
#define WEATHER_RAIN_CLOUD_COVERAGE 0.95
#endif

#ifndef WEATHER_RAIN_FOG_DENSITY_MULTIPLIER
#define WEATHER_RAIN_FOG_DENSITY_MULTIPLIER 9.25
#endif

#ifndef WEATHER_RAIN_NIGHT_FOG_DENSITY_MULTIPLIER
#define WEATHER_RAIN_NIGHT_FOG_DENSITY_MULTIPLIER 12.0
#endif

#ifndef WEATHER_RAIN_PUDDLE_SKY_TEST_DISTANCE
#define WEATHER_RAIN_PUDDLE_SKY_TEST_DISTANCE 256.0
#endif

#ifndef WEATHER_RAIN_PUDDLE_NOISE_SCALE
#define WEATHER_RAIN_PUDDLE_NOISE_SCALE 0.075
#endif

#ifndef WEATHER_RAIN_PUDDLE_STRENGTH
#define WEATHER_RAIN_PUDDLE_STRENGTH 1.15
#endif

#ifndef WEATHER_RAIN_PUDDLE_REFLECTION_STRENGTH
#define WEATHER_RAIN_PUDDLE_REFLECTION_STRENGTH 1.35
#endif

#ifndef WEATHER_RAIN_DAY_COLOR
#define WEATHER_RAIN_DAY_COLOR float3(0.38, 0.395, 0.410)
#endif

#ifndef WEATHER_RAIN_NIGHT_COLOR
#define WEATHER_RAIN_NIGHT_COLOR float3(0.040, 0.045, 0.052)
#endif

float GetWeatherRainAmount()
{
    return smoothstep(0.02, 0.85, saturate(g_view.rainLevel));
}

float GetWeatherSurfaceWetness()
{
    return saturate(max(g_view.surfaceWetness, g_view.rainLevel));
}

float GetWeatherRainCloudTopHeight()
{
    return WEATHER_RAIN_CLOUD_BASE_HEIGHT + WEATHER_RAIN_CLOUD_THICKNESS;
}

float GetWeatherUnderRainCloudAmount(float3 position)
{
    return 1.0 - smoothstep(
        GetWeatherRainCloudTopHeight() - 8.0,
        GetWeatherRainCloudTopHeight() + 64.0,
        position.y);
}

float GetWeatherRainOnSurfaceAmount(float3 position)
{
    return GetWeatherRainAmount() * GetWeatherUnderRainCloudAmount(position);
}

float3 GetWeatherGreyRadiance(float3 color, float3 tint)
{
    return max(getLuminance(max(color, 0.0)), 0.0) * tint;
}

float3 GetWeatherRainPalette(float nightAmount)
{
    return lerp(
        WEATHER_RAIN_DAY_COLOR,
        WEATHER_RAIN_NIGHT_COLOR,
        saturate(nightAmount));
}

float GetWeatherRainLuminanceScale(float nightAmount)
{
    return lerp(0.68, 0.42, saturate(nightAmount));
}

float WeatherNoise2D(float2 x)
{
    float2 p = floor(x);
    float2 f = frac(x);
    float2 u = f * f * (3.0 - 2.0 * f);

    float a = hash32(p).x;
    float b = hash32(p + float2(1.0, 0.0)).x;
    float c = hash32(p + float2(0.0, 1.0)).x;
    float d = hash32(p + float2(1.0, 1.0)).x;
    return lerp(lerp(a, b, u.x), lerp(c, d, u.x), u.y);
}

float3 sampleCelestialLightDisk(float3 lightDirection, float2 sampleValue) {
    float3 basisAxis = abs(lightDirection.y) < 0.999
        ? float3(0, 1, 0)
        : float3(1, 0, 0);
    float3 tangent = safeNormalize(
        cross(basisAxis, lightDirection),
        float3(1, 0, 0));
    float3 bitangent = cross(lightDirection, tangent);

    float diskRadius =
        sqrt(saturate(sampleValue.x))
        * tan(CELESTIAL_SHADOW_ANGULAR_RADIUS_RADIANS);
    float diskAngle = sampleValue.y * 2.0 * PI;
    float2 diskOffset =
        float2(cos(diskAngle), sin(diskAngle)) * diskRadius;

    return safeNormalize(
        lightDirection
            + tangent * diskOffset.x
            + bitangent * diskOffset.y,
        lightDirection);
}

#endif
