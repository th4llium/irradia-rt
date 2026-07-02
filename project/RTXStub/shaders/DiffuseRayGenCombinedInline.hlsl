#include "Include/IrradianceCacheUpdate.hlsl"
#include "Include/DenoisingCommon.hlsl"

#ifndef IRRADIANCE_CACHE_RECONSTRUCTION_RADIUS
#define IRRADIANCE_CACHE_RECONSTRUCTION_RADIUS 1
#endif

#ifndef IRRADIANCE_CACHE_RECONSTRUCTION_FAR_STEP
#define IRRADIANCE_CACHE_RECONSTRUCTION_FAR_STEP 4
#endif

#ifndef IRRADIANCE_CACHE_RECONSTRUCTION_SCALE_COUNT
#define IRRADIANCE_CACHE_RECONSTRUCTION_SCALE_COUNT PERF_IRRADIANCE_CACHE_RECONSTRUCTION_SCALE_COUNT
#endif

#ifndef IRRADIANCE_CACHE_RECONSTRUCTION_STRENGTH
#define IRRADIANCE_CACHE_RECONSTRUCTION_STRENGTH PERF_IRRADIANCE_CACHE_RECONSTRUCTION_STRENGTH
#endif

#ifndef IRRADIANCE_CACHE_FALLBACK_STRENGTH
#define IRRADIANCE_CACHE_FALLBACK_STRENGTH PERF_IRRADIANCE_CACHE_FALLBACK_STRENGTH
#endif

#ifndef IRRADIANCE_CACHE_PRIMARY_STRENGTH
#define IRRADIANCE_CACHE_PRIMARY_STRENGTH PERF_IRRADIANCE_CACHE_PRIMARY_STRENGTH
#endif

#ifndef HIGH_RES_GI_RAY_COUNT
#define HIGH_RES_GI_RAY_COUNT PERF_HIGH_RES_GI_RAY_COUNT
#endif

#ifndef HIGH_RES_GI_RAY_DISTANCE
#define HIGH_RES_GI_RAY_DISTANCE 10000.0
#endif

#ifndef HIGH_RES_GI_STRENGTH
#define HIGH_RES_GI_STRENGTH 1.0
#endif

#ifndef HIGH_RES_GI_MIN_BLEND
#define HIGH_RES_GI_MIN_BLEND PERF_HIGH_RES_GI_MIN_BLEND
#endif

#ifndef HIGH_RES_GI_MULTIBOUNCE_STRENGTH
#define HIGH_RES_GI_MULTIBOUNCE_STRENGTH PERF_HIGH_RES_GI_CACHE_BOUNCE_STRENGTH
#endif

float3 GetPrimaryWorldPosition(
    uint2 pixelPosition,
    float depth)
{
    return g_view.viewOriginSteveSpace
        + rayDirFromNDC(getNDCjittered(pixelPosition))
        * depth;
}

float3 ApproximatePrimaryTransmittance(float depth)
{
    float distance = min(depth, 150.0);
    if (g_view.cameraIsUnderWater != 0)
    {
        float3 extinction =
            float3(0.8, 0.2, 0.05) * 0.0125;
        return exp(-extinction * distance);
    }

    return exp(-0.0015 * distance).xxx;
}

float3 TraceDetailedCacheRadiance(RayDesc ray)
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
        IrradianceCacheSample incoming =
            SampleIncomingIrradianceCache(
                hitInfo, objectInstance);

        return EvaluateCachedOutgoingRadiance(
            hitInfo,
            objectInstance,
            incoming.irradiance
                * incoming.confidence
                * HIGH_RES_GI_MULTIBOUNCE_STRENGTH);
    }

    return GetCacheSkyRadiance(
        ray.Origin, ray.Direction);
}

bool ShouldTraceHighResolutionGI(uint2 pixelPosition)
{
#if HIGH_RES_GI_RAY_COUNT <= 0
    return false;
#elif PERF_HIGH_RES_GI_CHECKERBOARD
    return (((pixelPosition.x + pixelPosition.y + g_view.frameCount) & 1) != 0);
#else
    return true;
#endif
}

float3 TraceHighResolutionGI(
    uint2 pixelPosition,
    float3 position,
    float3 normal,
    float depth)
{
#if HIGH_RES_GI_RAY_COUNT <= 0
    return (0.0).xxx;
#else
    uint3 noiseCoord = uint3(
        pixelPosition % uint2(256, 256),
        g_view.frameCount % 128);
    float2 rotation =
        blueNoiseTexture.Load(uint4(noiseCoord, 0)).xy;

    float3 radiance = 0.0;
    [unroll]
    for (uint rayIndex = 0;
        rayIndex < HIGH_RES_GI_RAY_COUNT;
        ++rayIndex)
    {
        float2 sample = GetCacheRaySample(
            rayIndex,
            HIGH_RES_GI_RAY_COUNT,
            rotation);

        RayDesc ray;
        ray.Origin = position + normal * 1.0e-3;
        ray.Direction =
            SampleCosineHemisphere(sample, normal);
        ray.TMin = 0.0;
        ray.TMax = HIGH_RES_GI_RAY_DISTANCE;
        radiance += TraceDetailedCacheRadiance(ray);
    }

    radiance /= (float)HIGH_RES_GI_RAY_COUNT;
    return ClampCachedIrradiance(radiance)
        * ApproximatePrimaryTransmittance(depth);
#endif
}

float3 ClampHighResolutionGIDetail(
    float3 detailRadiance,
    float3 coarseRadiance,
    float3 primaryCacheRadiance,
    float centerConfidence)
{
    detailRadiance = ClampCachedIrradiance(detailRadiance);

    float localSupport = max(
        getLuminance(max(coarseRadiance, 0.0)),
        getLuminance(max(primaryCacheRadiance, 0.0)));
    float confidence = smoothstep(0.05, 0.65, centerConfidence);
    float supportedMaxLuminance = max(
        localSupport * PERF_HIGH_RES_GI_FIREFLY_SUPPORT_SCALE
            + PERF_HIGH_RES_GI_FIREFLY_BIAS,
        PERF_HIGH_RES_GI_FIREFLY_BIAS);
    float maxDetailLuminance = lerp(
        supportedMaxLuminance,
        PERF_HIGH_RES_GI_FIREFLY_MAX_LUMINANCE,
        confidence);

    float detailLuminance = getLuminance(max(detailRadiance, 0.0));
    if (detailLuminance > maxDetailLuminance)
    {
        detailRadiance *=
            maxDetailLuminance / max(detailLuminance, 1.0e-4);
    }

    return detailRadiance;
}

[numthreads(4, 8, 1)]
void DiffuseRayGenCombinedInline(
    uint3 dispatchThreadID : SV_DispatchThreadID,
    uint3 groupThreadID : SV_GroupThreadID,
    uint groupIndex : SV_GroupIndex,
    uint3 groupID : SV_GroupID
    )
{
    uint2 pixelPosition = dispatchThreadID.xy;
    if (any(pixelPosition >= g_view.renderResolution))
        return;

    float4 centerCache =
        inputBufferIncomingIrradianceCache[pixelPosition];
    float centerDepth =
        inputBufferPrimaryPathLength[pixelPosition];
    if (centerCache.a <= 0.0 || centerDepth >= 65000.0)
        return;

    float3 centerNormal = DecodeDenoiserNormal(
        inputBufferNormal[pixelPosition]);
    float3 centerPosition =
        GetPrimaryWorldPosition(
            pixelPosition, centerDepth);
    float3 centerSignal =
        max(centerCache.rgb, 0.0) * centerCache.a;

    float3 filteredSignal = centerSignal * 3.0;
    float totalWeight = 3.0;
    int2 renderSize = int2(g_view.renderResolution);

    [unroll]
    for (uint scaleIndex = 0;
        scaleIndex < IRRADIANCE_CACHE_RECONSTRUCTION_SCALE_COUNT;
        ++scaleIndex)
    {
        int sampleStep = scaleIndex == 0
            ? 1
            : IRRADIANCE_CACHE_RECONSTRUCTION_FAR_STEP;
        float scaleWeight = scaleIndex == 0
            ? 1.0
            : 0.55;

        [unroll]
        for (int y = -IRRADIANCE_CACHE_RECONSTRUCTION_RADIUS;
            y <= IRRADIANCE_CACHE_RECONSTRUCTION_RADIUS;
            ++y)
        {
            [unroll]
            for (int x = -IRRADIANCE_CACHE_RECONSTRUCTION_RADIUS;
                x <= IRRADIANCE_CACHE_RECONSTRUCTION_RADIUS;
                ++x)
            {
                if (x == 0 && y == 0)
                    continue;

                int2 samplePosition = int2(pixelPosition)
                    + int2(x, y) * sampleStep;
                if (any(samplePosition < 0)
                    || any(samplePosition >= renderSize))
                {
                    continue;
                }

                float4 sampleCache =
                    inputBufferIncomingIrradianceCache[
                        samplePosition];
                float sampleDepth =
                    inputBufferPrimaryPathLength[samplePosition];
                if (sampleCache.a <= 0.0
                    || sampleDepth >= 65000.0)
                {
                    continue;
                }

                float3 sampleNormal =
                    DecodeDenoiserNormal(
                        inputBufferNormal[samplePosition]);
                float normalAgreement =
                    saturate(dot(centerNormal, sampleNormal));
                if (normalAgreement < 0.92)
                    continue;

                float3 samplePositionWorld =
                    GetPrimaryWorldPosition(
                        samplePosition, sampleDepth);
                float3 positionDelta =
                    samplePositionWorld - centerPosition;
                float planeDistance =
                    abs(dot(positionDelta, centerNormal));
                if (planeDistance > 0.12)
                    continue;

                float2 pixelOffset =
                    float2(x, y) * sampleStep;
                float spatialWeight = exp2(
                    -dot(pixelOffset, pixelOffset) / 64.0);
                float normalWeight =
                    pow(normalAgreement, 32.0);
                float planeWeight = exp2(
                    -planeDistance * planeDistance * 160.0);
                float confidenceWeight =
                    lerp(0.2, 1.0, sampleCache.a);
                float weight = spatialWeight
                    * normalWeight
                    * planeWeight
                    * confidenceWeight
                    * scaleWeight;

                filteredSignal += max(sampleCache.rgb, 0.0)
                    * sampleCache.a * weight;
                totalWeight += weight;
            }
        }
    }

    filteredSignal /= max(totalWeight, 0.0001);

    float3 coarseRadiance = lerp(
        centerSignal,
        filteredSignal,
        IRRADIANCE_CACHE_RECONSTRUCTION_STRENGTH)
        * (IRRADIANCE_CACHE_FALLBACK_STRENGTH / PI);
    float3 primaryCacheRadiance =
        centerSignal * (IRRADIANCE_CACHE_PRIMARY_STRENGTH / PI);
    float3 detailRadiance = coarseRadiance;
    float detailWeight = 0.0;
    if (ShouldTraceHighResolutionGI(pixelPosition))
    {
        detailRadiance = TraceHighResolutionGI(
            pixelPosition,
            centerPosition,
            centerNormal,
            centerDepth);
        detailRadiance = ClampHighResolutionGIDetail(
            detailRadiance,
            coarseRadiance,
            primaryCacheRadiance,
            centerCache.a);
        float confidenceWeight =
            smoothstep(0.0, 0.35, centerCache.a);
        detailWeight = saturate(
            HIGH_RES_GI_STRENGTH
            * lerp(
                HIGH_RES_GI_MIN_BLEND,
                1.0,
                confidenceWeight));
    }
    float3 resolvedRadiance = lerp(
        coarseRadiance,
        detailRadiance,
        detailWeight);
    float3 cacheCorrection =
        resolvedRadiance - primaryCacheRadiance;

    float4 diffuse =
        outputBufferIndirectDiffuse[pixelPosition];
    diffuse.rgb = max(diffuse.rgb + cacheCorrection, 0.0);
    outputBufferIndirectDiffuse[pixelPosition] = diffuse;
}
