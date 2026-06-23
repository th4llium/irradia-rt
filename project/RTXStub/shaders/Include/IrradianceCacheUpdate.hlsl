#ifndef __IRRADIANCE_CACHE_UPDATE_HLSL__
#define __IRRADIANCE_CACHE_UPDATE_HLSL__

#include "IrradianceCache.hlsl"
#include "BRDF.hlsl"

#define SKY_NO_RAY_STATE 1
#include "Sky.hlsl"
#undef SKY_NO_RAY_STATE

#include "Shadows.hlsl"

#ifndef IRRADIANCE_CACHE_POINT_LIGHT_COUNT
#define IRRADIANCE_CACHE_POINT_LIGHT_COUNT 4
#endif

#ifndef IRRADIANCE_CACHE_MIN_UPDATE_ALPHA
#define IRRADIANCE_CACHE_MIN_UPDATE_ALPHA 0.04
#endif

#ifndef IRRADIANCE_CACHE_RAYS_PER_HEMISPHERE
#define IRRADIANCE_CACHE_RAYS_PER_HEMISPHERE 4
#endif

#ifndef IRRADIANCE_CACHE_EMISSIVE_SCALE
#define IRRADIANCE_CACHE_EMISSIVE_SCALE 0.8
#endif

struct IrradianceCacheLightData
{
    float3 color;
    float intensity;
};

IrradianceCacheLightData UnpackCacheLight(uint packedData)
{
    IrradianceCacheLightData lightData;
    lightData.color = float3(
        (float)((packedData >> 24) & 0x7f) / 127.0,
        (float)((packedData >> 16) & 0xff) / 255.0,
        (float)((packedData >> 8) & 0xff) / 255.0);
    lightData.intensity =
        (float)(packedData & 0xff) / 255.0;
    return lightData;
}

uint CacheHash(uint value)
{
    value ^= value >> 16;
    value *= 0x7feb352du;
    value ^= value >> 15;
    value *= 0x846ca68bu;
    value ^= value >> 16;
    return value;
}

float CacheRandom(inout uint state)
{
    state = CacheHash(state + 0x9e3779b9u);
    return (float)(state & 0x00ffffffu) / 16777216.0;
}

float2 CacheRandom2(inout uint state)
{
    return float2(
        CacheRandom(state),
        CacheRandom(state));
}

float2 GetCacheRaySample(
    uint sampleIndex,
    uint sampleCount,
    float2 rotation)
{
    const float goldenRatioConjugate = 0.61803398875;
    return frac(float2(
        ((float)sampleIndex + 0.5) / (float)sampleCount,
        (float)sampleIndex * goldenRatioConjugate)
        + rotation);
}

uint GetIrradianceCacheSeed(
    float3 worldPosition,
    float3 worldNormal,
    uint frameSeed)
{
    // Coincident mesh vertices share a sequence.
    int3 quantizedPosition = int3(round(worldPosition * 256.0));
    int3 quantizedNormal = int3(round(worldNormal * 1024.0));

    uint seed = CacheHash(frameSeed);
    seed = CacheHash(
        seed ^ asuint(quantizedPosition.x));
    seed = CacheHash(
        seed ^ asuint(quantizedPosition.y));
    seed = CacheHash(
        seed ^ asuint(quantizedPosition.z));
    seed = CacheHash(
        seed ^ asuint(quantizedNormal.x));
    seed = CacheHash(
        seed ^ asuint(quantizedNormal.y));
    return CacheHash(
        seed ^ asuint(quantizedNormal.z));
}

float GetIrradianceCacheHistoryLimit(ObjectInstance objectInstance)
{
    uint configuredLimit =
        objectInstance.irradianceCacheMaxHistoryLength;
    return (float)(
        configuredLimit != 0
            ? clamp(configuredLimit, 1u, 64u)
            : 24u);
}

float3 BlendCacheHistory(
    float3 previousValue,
    float3 sampleValue,
    float historyLength,
    float historyLimit)
{
    previousValue = ClampCachedIrradiance(previousValue);
    sampleValue = ClampCachedIrradiance(sampleValue);

    float alpha = max(
        1.0 / (min(historyLength, historyLimit - 1.0) + 1.0),
        IRRADIANCE_CACHE_MIN_UPDATE_ALPHA);

    float previousLuminance =
        dot(previousValue, float3(0.2126, 0.7152, 0.0722));
    float sampleLuminance =
        dot(sampleValue, float3(0.2126, 0.7152, 0.0722));
    float relativeLuminanceChange =
        abs(sampleLuminance - previousLuminance)
        / max(max(previousLuminance, sampleLuminance), 0.05);
    float relativeColorChange =
        length(sampleValue - previousValue)
        / max(max(length(sampleValue), length(previousValue)), 0.05);
    float signalChange = max(
        relativeLuminanceChange,
        relativeColorChange);
    alpha = max(
        alpha,
        saturate((signalChange - 0.12) * 1.4) * 0.55);

    return ClampCachedIrradiance(
        lerp(previousValue, sampleValue, saturate(alpha)));
}

float3 GetCacheSkyRadiance(
    float3 rayOrigin,
    float3 rayDirection)
{
    float3 sunDirection = getOffsetPrimaryCelestialDirection();
    float3 moonDirection = -sunDirection;
    float3 atmosphereOrigin = rayOrigin;
    atmosphereOrigin.y = max(atmosphereOrigin.y, CAM_HEIGHT);

    float3 sunRadiance;
    float sunLux;
    GetSunColorAndLux(
        atmosphereOrigin, sunDirection, sunRadiance, sunLux);

    float4 transmittance;
    float3 radiance = GetAtmosphere(
        atmosphereOrigin,
        rayDirection,
        INFINITY,
        sunDirection,
        sunRadiance,
        transmittance);
    radiance *= transmittance.w;

    float3 moonRadiance;
    float moonLux;
    GetMoonColorAndLux(
        atmosphereOrigin,
        sunDirection,
        moonDirection,
        moonRadiance,
        moonLux);
    radiance += GetAtmosphere(
        atmosphereOrigin,
        rayDirection,
        INFINITY,
        moonDirection,
        moonRadiance);

    radiance *= GetAutoExposureMultiplier(
        rayOrigin, sunDirection, moonDirection);
    return ClampCachedIrradiance(radiance);
}

float3 EvaluateCacheDirectIrradiance(
    float3 position,
    float3 normal)
{
    float3 sunDirection = getOffsetPrimaryCelestialDirection();
    float3 moonDirection = -sunDirection;
    float isSun = step(0.0, sunDirection.y);
    float3 mainLightDirection =
        lerp(moonDirection, sunDirection, isSun);
    float mainLightFade = lerp(
        saturate(moonDirection.y),
        saturate(sunDirection.y),
        isSun);
    float exposure = GetAutoExposureMultiplier(
        position, sunDirection, moonDirection);

    float3 irradiance = 0.0;

    float2 shadowSample = hash32(
        position.xz * 0.173
        + float2(
            (float)g_view.frameCount * 0.754877666,
            (float)g_view.frameCount * 0.569840296)).xy;
    float3 sampledMainLightDirection = sampleCelestialLightDisk(
        mainLightDirection,
        shadowSample);
    float mainNdotL = dot(normal, sampledMainLightDirection);
    if (mainNdotL > 0.0)
    {
        RayDesc shadowRay;
        shadowRay.Origin = position + normal * 1.0e-3;
        shadowRay.Direction = sampledMainLightDirection;
        shadowRay.TMin = 0.0;
        shadowRay.TMax = 10000.0;

        ShadowPayload shadowPayload;
        TraceShadowRay(shadowRay, shadowPayload);

        float3 sunRadiance;
        float sunLux;
        GetSunColorAndLux(
            position, sunDirection, sunRadiance, sunLux);
        float3 moonRadiance;
        float moonLux;
        GetMoonColorAndLux(
            position,
            sunDirection,
            moonDirection,
            moonRadiance,
            moonLux);
        float3 mainRadiance =
            lerp(moonRadiance, sunRadiance, isSun);
        irradiance += mainRadiance
            * 0.75
            * mainLightFade
            * shadowPayload.transmission
            * mainNdotL
            * PI
            * exposure;
    }

    int lightCount = min(
        IRRADIANCE_CACHE_POINT_LIGHT_COUNT,
        (int)g_view.cpuLightsCount);
    [loop]
    for (int lightIndex = 0; lightIndex < lightCount; ++lightIndex)
    {
        LightInfo lightInfo = inputLightsBuffer[lightIndex];
        IrradianceCacheLightData lightData =
            UnpackCacheLight(lightInfo.packedData);
        float3 toLight = lightInfo.position - position;
        float lightDistance = length(toLight);
        float3 lightDirection =
            toLight / max(lightDistance, 0.001);
        float NdotL = dot(normal, lightDirection);
        if (NdotL <= 0.0)
            continue;

        RayDesc shadowRay;
        shadowRay.Origin = position + normal * 1.0e-3;
        shadowRay.Direction = lightDirection;
        shadowRay.TMin = 0.0;
        shadowRay.TMax = max(lightDistance - 0.55, 0.0);

        ShadowPayload shadowPayload;
        TraceShadowRay(shadowRay, shadowPayload);

        float attenuation =
            1.0 / max(lightDistance * lightDistance, 0.001);
        irradiance += shadowPayload.transmission
            * attenuation
            * lightData.intensity
            * lightData.color
            * NdotL
            * PI
            * 700.0;
    }

    return ClampCachedIrradiance(irradiance);
}

float3 EvaluateCachedOutgoingRadiance(
    HitInfo hitInfo,
    ObjectInstance objectInstance,
    float3 incomingIrradiance)
{
    GeometryInfo geometryInfo =
        GetGeometryInfo(hitInfo, objectInstance);
    SurfaceInfo surfaceInfo =
        MaterialVanilla(hitInfo, geometryInfo, objectInstance);

    if (surfaceInfo.shouldDiscard)
        return (0.0).xxx;

    float3 diffuseColor =
        surfaceInfo.color * (1.0 - surfaceInfo.metalness);
    float3 directIrradiance =
        EvaluateCacheDirectIrradiance(
            surfaceInfo.position,
            surfaceInfo.normal);

    float3 emission = 0.0;
    if (objectInstance.flags
        & (kObjectInstanceFlagSun | kObjectInstanceFlagMoon))
    {
        float intensity =
            (objectInstance.flags & kObjectInstanceFlagSun)
                ? g_view.sunMeshIntensity
                : g_view.moonMeshIntensity;
        emission =
            surfaceInfo.color * intensity * surfaceInfo.alpha;
    }
    else if (surfaceInfo.emissive > 0.0)
    {
        float indirectEmissiveBoost = max(
            g_view.indirectEmissiveBoostMultiplier,
            1.0);
        emission =
            surfaceInfo.color
            * surfaceInfo.emissive
            * IRRADIANCE_CACHE_EMISSIVE_SCALE
            * indirectEmissiveBoost;
    }

    float3 outgoing = emission
        + diffuseColor
            * (directIrradiance + incomingIrradiance)
            * (1.0 / PI);
    return ClampCachedIrradiance(outgoing);
}

float3 TraceCacheRadiance(RayDesc ray)
{
    RayQuery<RAY_FLAG_NONE> query;
    query.TraceRayInline(
        SceneBVH,
        RAY_FLAG_SKIP_PROCEDURAL_PRIMITIVES,
        INSTANCE_MASK_OPAQUE_OR_ALPHA_TEST_SECONDARY,
        ray);

    while (query.Proceed())
    {
        HitInfo candidate = GetCandidateHitInfo(query);
        if (AlphaTestHitLogic(candidate))
            query.CommitNonOpaqueTriangleHit();
    }

    if (query.CommittedStatus() == COMMITTED_TRIANGLE_HIT)
    {
        HitInfo hitInfo = GetCommittedHitInfo(query);
        ObjectInstance objectInstance =
            objectInstances[hitInfo.objectInstanceIndex];
        float cacheConfidence;
        float3 cachedRadiance = SampleOutgoingRadianceCache(
            hitInfo, objectInstance, cacheConfidence);

        if (cacheConfidence >= 1.0)
            return cachedRadiance;

        float3 uncachedRadiance = EvaluateCachedOutgoingRadiance(
            hitInfo, objectInstance, (0.0).xxx);
        return lerp(
            uncachedRadiance,
            cachedRadiance,
            cacheConfidence);
    }

    return GetCacheSkyRadiance(ray.Origin, ray.Direction);
}

#endif
