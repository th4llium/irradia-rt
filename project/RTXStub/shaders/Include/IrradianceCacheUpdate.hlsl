#ifndef __IRRADIANCE_CACHE_UPDATE_HLSL__
#define __IRRADIANCE_CACHE_UPDATE_HLSL__

#include "IrradianceCache.hlsl"
#include "BRDF.hlsl"

#define SKY_NO_RAY_STATE 1
#include "Sky.hlsl"
#undef SKY_NO_RAY_STATE

#include "Shadows.hlsl"

#ifndef IRRADIANCE_CACHE_POINT_LIGHT_COUNT
#define IRRADIANCE_CACHE_POINT_LIGHT_COUNT PERF_CACHE_POINT_LIGHT_COUNT
#endif

#ifndef IRRADIANCE_CACHE_MIN_UPDATE_ALPHA
#define IRRADIANCE_CACHE_MIN_UPDATE_ALPHA 0.025
#endif

#ifndef IRRADIANCE_CACHE_RAYS_PER_HEMISPHERE
#define IRRADIANCE_CACHE_RAYS_PER_HEMISPHERE PERF_CACHE_RAYS_PER_HEMISPHERE
#endif

#ifndef IRRADIANCE_CACHE_EMISSIVE_SCALE
#define IRRADIANCE_CACHE_EMISSIVE_SCALE PERF_EMISSIVE_CACHE_SURFACE_SCALE
#endif

#ifndef IRRADIANCE_CACHE_BRIGHT_SAMPLE_CLAMP
#define IRRADIANCE_CACHE_BRIGHT_SAMPLE_CLAMP 4.0
#endif

#ifndef IRRADIANCE_CACHE_BRIGHT_SAMPLE_BIAS
#define IRRADIANCE_CACHE_BRIGHT_SAMPLE_BIAS 2.0
#endif

#ifndef IRRADIANCE_CACHE_BRIGHT_CHANGE_ALPHA
#define IRRADIANCE_CACHE_BRIGHT_CHANGE_ALPHA 0.55
#endif

#ifndef IRRADIANCE_CACHE_DARK_CHANGE_ALPHA
#define IRRADIANCE_CACHE_DARK_CHANGE_ALPHA 0.65
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

    float previousLuminance =
        dot(previousValue, float3(0.2126, 0.7152, 0.0722));
    float sampleLuminance =
        dot(sampleValue, float3(0.2126, 0.7152, 0.0722));
    float brightRise =
        saturate(
            (sampleLuminance - previousLuminance)
            / max(max(sampleLuminance, previousLuminance), 0.05));

    if (historyLength >= 3.0
        && sampleLuminance > previousLuminance
        && brightRise < 0.70)
    {
        float maxBrightSample = max(
            previousLuminance * IRRADIANCE_CACHE_BRIGHT_SAMPLE_CLAMP
                + IRRADIANCE_CACHE_BRIGHT_SAMPLE_BIAS,
            IRRADIANCE_CACHE_BRIGHT_SAMPLE_BIAS);
        if (sampleLuminance > maxBrightSample)
        {
            sampleValue *=
                maxBrightSample / max(sampleLuminance, 1.0e-4);
            sampleLuminance = maxBrightSample;
        }
    }

    float alpha = max(
        1.0 / (min(historyLength, historyLimit - 1.0) + 1.0),
        IRRADIANCE_CACHE_MIN_UPDATE_ALPHA);
    float relativeLuminanceChange =
        abs(sampleLuminance - previousLuminance)
        / max(max(previousLuminance, sampleLuminance), 0.05);
    float relativeColorChange =
        length(sampleValue - previousValue)
        / max(max(length(sampleValue), length(previousValue)), 0.05);
    float signalChange = max(
        relativeLuminanceChange,
        relativeColorChange);
    float changeAlpha =
        saturate((signalChange - 0.12) * 1.4)
        * (sampleLuminance > previousLuminance
            ? IRRADIANCE_CACHE_BRIGHT_CHANGE_ALPHA
            : IRRADIANCE_CACHE_DARK_CHANGE_ALPHA);
    changeAlpha = max(
        changeAlpha,
        smoothstep(0.18, 0.75, brightRise) * 0.75);
    alpha = max(
        alpha,
        changeAlpha);

    return ClampCachedIrradiance(
        lerp(previousValue, sampleValue, saturate(alpha)));
}

float3 GetCacheSkyRadiance(
    float3 rayOrigin,
    float3 rayDirection)
{
    float3 sunDirection = getOffsetTrueDirectionToSun();
    float3 moonDirection = getOffsetTrueDirectionToMoon();
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
        sunRadiance * GetDaySkyAmount(sunDirection),
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
        moonRadiance * GetMoonAmount(sunDirection, moonDirection));

    radiance *= GetAutoExposureMultiplier(
        rayOrigin, sunDirection, moonDirection);
    return ClampCachedIrradiance(radiance);
}

float3 EvaluateCacheDirectIrradiance(
    float3 position,
    float3 normal)
{
    float3 sunDirection = getOffsetTrueDirectionToSun();
    float3 moonDirection = getOffsetTrueDirectionToMoon();
    float sunFade = GetSunAmount(sunDirection);
    float moonFade = GetMoonAmount(sunDirection, moonDirection);
    float isSun = step(moonFade, sunFade);
    float3 mainLightDirection =
        lerp(moonDirection, sunDirection, isSun);
    float mainLightFade = lerp(
        moonFade,
        sunFade,
        isSun);
    float exposure = GetAutoExposureMultiplier(
        position, sunDirection, moonDirection);

    float3 irradiance = 0.0;

    float3 sampledMainLightDirection = mainLightDirection;
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
        float3 shadowTransmission =
            ShapeSunShadowTransmission(shadowPayload.transmission);

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
            * shadowTransmission
            * mainNdotL
            * PI
            * exposure;
    }

    int totalLightCount =
        (int)g_view.cpuLightsCount;
    int lightCount = min(
        IRRADIANCE_CACHE_POINT_LIGHT_COUNT,
        totalLightCount);
    uint cacheLightSeed =
        GetIrradianceCacheSeed(
            position,
            normal,
            g_view.frameCount ^ 0xa2f1u);
    int lightStart = 0;
    int lightStride = 1;
    float lightSelectionWeight = 1.0;
    if (totalLightCount > lightCount && lightCount > 0)
    {
        lightStart = min(
            (int)floor(CacheRandom(cacheLightSeed)
                * (float)totalLightCount),
            totalLightCount - 1);
        lightStride = max(totalLightCount / lightCount, 1);
        lightSelectionWeight = min(
            (float)totalLightCount / (float)lightCount,
            4.0);
    }

    [loop]
    for (int lightIndex = 0; lightIndex < lightCount; ++lightIndex)
    {
        int selectedLightIndex =
            totalLightCount > lightCount
                ? (lightStart + lightIndex * lightStride)
                    % totalLightCount
                : lightIndex;
        LightInfo lightInfo = inputLightsBuffer[selectedLightIndex];
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
        shadowRay.TMax = GetEmissiveLightShadowTMax(lightDistance);

        ShadowPayload shadowPayload;
        TraceShadowRay(shadowRay, shadowPayload);

        float attenuation =
            GetEmissiveLightAttenuation(lightDistance)
            * PERF_EMISSIVE_CACHE_LIGHT_SCALE;
        float lightIntensity =
            GetLocalLightIntensityWeight(lightData.intensity);
        irradiance += shadowPayload.transmission
            * attenuation
            * lightIntensity
            * lightData.color
            * NdotL
            * PI
            * PERF_LOCAL_LIGHT_RADIANCE_SCALE
            * lightSelectionWeight;
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
        return ClampCachedIrradiance(
            lerp(
                uncachedRadiance,
                cachedRadiance,
                cacheConfidence));
    }

    return GetCacheSkyRadiance(ray.Origin, ray.Direction);
}

#endif
