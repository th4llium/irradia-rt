#ifndef __SHADOWS_HLSL__
#define __SHADOWS_HLSL__

#include "Generated/Signature.hlsl"
#include "Material.hlsl"
#include "Water.hlsl"

#ifndef CULL_GLASS_BACK_FACES
#define CULL_GLASS_BACK_FACES 0
#endif

#ifndef CELESTIAL_SHADOW_TEMPORAL_ALPHA
#define CELESTIAL_SHADOW_TEMPORAL_ALPHA 0.08
#endif

#ifndef CELESTIAL_SHADOW_MAX_HISTORY_LENGTH
#define CELESTIAL_SHADOW_MAX_HISTORY_LENGTH 12.0
#endif

#ifndef CELESTIAL_SHADOW_DISAGREEMENT_START
#define CELESTIAL_SHADOW_DISAGREEMENT_START 0.55
#endif

#ifndef CELESTIAL_SHADOW_DISAGREEMENT_END
#define CELESTIAL_SHADOW_DISAGREEMENT_END 0.95
#endif

#ifndef CELESTIAL_SHADOW_DISAGREEMENT_ALPHA
#define CELESTIAL_SHADOW_DISAGREEMENT_ALPHA 0.85
#endif

#ifndef CELESTIAL_SHADOW_MAX_TEMPORAL_TRANSMISSION
#define CELESTIAL_SHADOW_MAX_TEMPORAL_TRANSMISSION 1.05
#endif

bool AlphaTestHitLogic(HitInfo hitInfo)
{
    ObjectInstance object = objectInstances[hitInfo.objectInstanceIndex];
    bool isCloud =
        (object.flags & kObjectInstanceFlagClouds)
        || ((object.offsetPack5 >> 8) == MEDIA_TYPE_CLOUD);

#if !ENABLE_CLOUDS
    if (isCloud)
        return false;
#endif

#if CULL_GLASS_BACK_FACES
    if (hitInfo.materialType == MATERIAL_TYPE_ALPHA_BLEND
        && !hitInfo.frontFacing)
        return false;
#endif
    if (hitInfo.materialType != MATERIAL_TYPE_ALPHA_TEST)
        return true;

    float3 geometryNormal;
    float4 color = GetShadowColorAndAlpha(
        hitInfo, object, geometryNormal);
    bool usesHalfThreshold = object.flags
        & (kObjectInstanceFlagAlphaTestThresholdHalf
            | kObjectInstanceFlagChunk);
    return !(usesHalfThreshold ? color.a < 0.5 : color.a == 0.0);
}

struct ShadowPayload
{
    float3 transmission;
};

float3 GetShadowThinTransmittance(float3 color, float opacity)
{
    float3 thinTint = clamp(saturate(color), 0.04, 1.0);
    float opticalDepth = saturate(opacity) * 0.35;
    return exp(log(thinTint) * opticalDepth);
}

float3 GetShadowGlassExtinction(float3 color, float opacity)
{
    float3 clampedColor = max(saturate(color), 0.001);
    float maximumChannel = max(
        clampedColor.r, max(clampedColor.g, clampedColor.b));
    float minimumChannel = min(
        clampedColor.r, min(clampedColor.g, clampedColor.b));
    float saturation =
        (maximumChannel - minimumChannel) / maximumChannel;
    float tintStrength = saturate(opacity)
        * smoothstep(0.08, 0.35, saturation);
    float3 tint = clampedColor / maximumChannel;
    float3 transmittancePerBlock =
        lerp((1.0).xxx, tint, tintStrength);
    return -log(clamp(
        transmittancePerBlock, 0.02, 1.0)) * 0.65;
}

float GetShadowGlassInterfaceTransmission(
    float3 rayDirection,
    float3 localGeometryNormal,
    ObjectInstance object)
{
    float3 worldGeometryNormal = safeNormalize(
        mul(localGeometryNormal, (float3x3)object.modelToWorld),
        float3(0, 1, 0));
    float cosine = abs(dot(rayDirection, worldGeometryNormal));
    float fresnel =
        0.04 + 0.96 * pow(saturate(1.0 - cosine), 5.0);
    return 1.0 - fresnel;
}

void TraceShadowRay(in RayDesc ray, out ShadowPayload payload)
{
    RayQuery<
        RAY_FLAG_SKIP_PROCEDURAL_PRIMITIVES
        | RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH> query;
    const uint instanceMask =
        INSTANCE_MASK_OPAQUE_OR_ALPHA_TEST_SECONDARY
        | INSTANCE_MASK_ALPHA_BLEND_SECONDARY
        | INSTANCE_MASK_WATER;
    query.TraceRayInline(
        SceneBVH,
        RAY_FLAG_SKIP_PROCEDURAL_PRIMITIVES
            | RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH,
        instanceMask,
        ray);

    float3 transmission = 1.0;
    bool insideGlass = false;
    float glassEntryDistance = 0.0;
    float3 glassExtinction = 0.0;

    while (query.Proceed()) {
        HitInfo hitInfo;
        hitInfo.rayT = query.CandidateTriangleRayT();
        hitInfo.frontFacing = query.CandidateTriangleFrontFace();
        hitInfo.barycentric2 =
            query.CandidateTriangleBarycentrics();
        hitInfo.materialType = query.CandidateInstanceID();
        hitInfo.objectInstanceIndex =
            query.CandidateInstanceIndex();
        hitInfo.primitiveId = query.CandidatePrimitiveIndex();

        ObjectInstance object =
            objectInstances[hitInfo.objectInstanceIndex];
        bool isCloud =
            (object.flags & kObjectInstanceFlagClouds)
            || ((object.offsetPack5 >> 8) == MEDIA_TYPE_CLOUD);

#if !ENABLE_CLOUDS
        if (isCloud)
            continue;
#endif

        if (hitInfo.materialType == MATERIAL_TYPE_ALPHA_TEST) {
            if (!AlphaTestHitLogic(hitInfo))
                continue;

            float3 geometryNormal;
            float4 color = GetShadowColorAndAlpha(
                hitInfo, object, geometryNormal);
            if (color.a < 0.99) {
                transmission *= GetShadowThinTransmittance(
                    color.rgb, color.a);
            } else {
                query.CommitNonOpaqueTriangleHit();
            }
        }
#if ENABLE_CLOUDS
        else if (hitInfo.materialType == MATERIAL_TYPE_ALPHA_BLEND)
#else
        else if (hitInfo.materialType == MATERIAL_TYPE_ALPHA_BLEND
            && !isCloud)
#endif
        {
            float3 geometryNormal;
            float4 color = GetShadowColorAndAlpha(
                hitInfo, object, geometryNormal);
            bool isGlass =
                (object.offsetPack5 >> 8) == MEDIA_TYPE_GLASS;

            if (isGlass) {
                transmission *= GetShadowGlassInterfaceTransmission(
                    ray.Direction, geometryNormal, object);

                if (hitInfo.frontFacing) {
                    if (!insideGlass) {
                        insideGlass = true;
                        glassEntryDistance = hitInfo.rayT;
                        glassExtinction = GetShadowGlassExtinction(
                            color.rgb, color.a);
                    }
                } else if (insideGlass) {
                    float thickness = max(
                        hitInfo.rayT - glassEntryDistance, 0.0);
                    transmission *= exp(
                        -glassExtinction * thickness);
                    insideGlass = false;
                } else {
                    transmission *= exp(
                        -GetShadowGlassExtinction(
                            color.rgb, color.a) * 0.125);
                }
            } else {
                transmission *= GetShadowThinTransmittance(
                    color.rgb, color.a);
            }
        }
        else if (hitInfo.materialType == MATERIAL_TYPE_WATER) {
            float3 waterHitPosition =
                ray.Origin + ray.Direction * hitInfo.rayT;
            waterHitPosition -=
                g_view.waveWorksOriginInSteveSpace;
            waterHitPosition -=
                floor(waterHitPosition / 1024.0) * 1024.0;
            transmission *= CalcWaterCausticTransmission(
                waterHitPosition, hitInfo.rayT);
        }
        else {
            query.CommitNonOpaqueTriangleHit();
        }

        if (max(
            transmission.r,
            max(transmission.g, transmission.b)) < 0.001)
        {
            query.CommitNonOpaqueTriangleHit();
        }
    }

    if (insideGlass)
        transmission *= exp(-glassExtinction * 0.125);

    payload.transmission =
        query.CommittedStatus() == COMMITTED_NOTHING
        ? transmission
        : 0.0;
}

float3 DecodeShadowHistoryNormal(float2 encoded)
{
    float3 normal = float3(
        encoded,
        1.0 - abs(encoded.x) - abs(encoded.y));
    if (normal.z < 0.0) {
        float2 signValue = float2(
            normal.x >= 0.0 ? 1.0 : -1.0,
            normal.y >= 0.0 ? 1.0 : -1.0);
        normal.xy = (1.0 - abs(normal.yx)) * signValue;
    }

    return safeNormalize(normal, float3(0, 1, 0));
}

float GetShadowHistoryDepthTolerance(float pathLength)
{
    return 0.08 + min(max(pathLength, 0.0) * 0.005, 0.35);
}

float4 LoadReprojectedSunShadowHistory(
    uint2 pixelCoord,
    float3 position,
    float3 previousPosition,
    float3 normal)
{
    float2 motionVector =
        computeMotionVector(position, position - previousPosition);
    float2 previousPixelCenter =
        (float2)pixelCoord + 0.5
        + motionVector * (float2)g_view.renderResolution;
    float2 previousPixelCorner = previousPixelCenter - 0.5;
    int2 basePixel = int2(floor(previousPixelCorner));
    float2 bilinear = frac(previousPixelCorner);
    int2 renderSize = int2(g_view.renderResolution);
    float previousPathLength = length(
        previousPosition - g_view.previousViewOriginSteveSpace);
    float depthTolerance =
        GetShadowHistoryDepthTolerance(previousPathLength);

    float4 historySum = 0.0;
    float weightSum = 0.0;
    [loop]
    for (int sampleIndex = 0; sampleIndex < 4; ++sampleIndex)
    {
        int2 offset = int2(sampleIndex & 1, sampleIndex >> 1);
        int2 samplePixel = basePixel + offset;
        if (any(samplePixel < 0) || any(samplePixel >= renderSize))
            continue;

        float2 bilinearWeight = lerp(
            1.0 - bilinear,
            bilinear,
            (float2)offset);
        float weight = bilinearWeight.x * bilinearWeight.y;

        float2 sampleCenter = (float2)samplePixel + 0.5;
        float2 previousNdc =
            (sampleCenter / (float2)g_view.renderResolution)
            * float2(2.0, -2.0)
            + float2(-1.0, 1.0);
        float4 previousSteveSpace = mul(
            float4(previousNdc, 0.5, 1.0),
            g_view.prevInvViewProj);
        previousSteveSpace.xyz *= safeRcp(previousSteveSpace.w);
        float3 previousRayDirection = safeNormalize(
            previousSteveSpace.xyz
                - g_view.previousViewOriginSteveSpace,
            float3(0, 0, 1));

        float sampleDepth = previousPrimaryPathLengthBuffer[samplePixel];
        if (sampleDepth >= 65000.0)
            continue;

        float3 samplePosition =
            g_view.previousViewOriginSteveSpace
            + previousRayDirection * sampleDepth;
        float positionError =
            length(samplePosition - previousPosition);
        float depthWeight =
            1.0 - smoothstep(
                depthTolerance * 0.5,
                depthTolerance,
                positionError);

        float3 sampleNormal = DecodeShadowHistoryNormal(
            previousPrimaryNormalBuffer[samplePixel]);
        float normalWeight = smoothstep(
            0.72,
            0.95,
            dot(normal, sampleNormal));
        weight *= depthWeight * normalWeight;
        if (weight <= 0.0)
            continue;

        historySum += previousSunLightShadowBuffer[samplePixel] * weight;
        weightSum += weight;
    }

    if (weightSum <= 0.0)
        return 0.0;

    float4 history = historySum / weightSum;
    history.a *= saturate(weightSum);
    return history;
}

float3 ResolveTemporalSunShadow(
    uint2 pixelCoord,
    float3 position,
    float3 previousPosition,
    float3 normal,
    float3 currentTransmission)
{
    float4 previousShadow = LoadReprojectedSunShadowHistory(
        pixelCoord,
        position,
        previousPosition,
        normal);
    float previousHistoryLength = previousShadow.a * 255.0;
    float maximumCurrentTransmission = max(
        currentTransmission.r,
        max(currentTransmission.g, currentTransmission.b));

    if (previousHistoryLength <= 0.0
        || g_view.numFramesSinceTeleport == 0
        || maximumCurrentTransmission
            > CELESTIAL_SHADOW_MAX_TEMPORAL_TRANSMISSION)
    {
        outputBufferSunLightShadow[pixelCoord] =
            float4(currentTransmission, 1.0 / 255.0);
        return currentTransmission;
    }

    previousHistoryLength = min(
        previousHistoryLength,
        CELESTIAL_SHADOW_MAX_HISTORY_LENGTH - 1.0);
    float alpha = max(
        1.0 / (previousHistoryLength + 1.0),
        CELESTIAL_SHADOW_TEMPORAL_ALPHA);
    float disagreement = max(
        abs(previousShadow.r - currentTransmission.r),
        max(
            abs(previousShadow.g - currentTransmission.g),
            abs(previousShadow.b - currentTransmission.b)));
    float disagreementWeight = smoothstep(
        CELESTIAL_SHADOW_DISAGREEMENT_START,
        CELESTIAL_SHADOW_DISAGREEMENT_END,
        disagreement);
    alpha = max(
        alpha,
        disagreementWeight * CELESTIAL_SHADOW_DISAGREEMENT_ALPHA);

    float3 resolvedTransmission =
        lerp(previousShadow.rgb, currentTransmission, saturate(alpha));
    float historyLength = lerp(
        min(
            previousHistoryLength + 1.0,
            CELESTIAL_SHADOW_MAX_HISTORY_LENGTH),
        1.0,
        disagreementWeight);

    outputBufferSunLightShadow[pixelCoord] =
        float4(resolvedTransmission, historyLength / 255.0);
    return resolvedTransmission;
}

bool TraceOcclusionRay(in RayDesc ray)
{
    RayQuery<
        RAY_FLAG_SKIP_PROCEDURAL_PRIMITIVES
        | RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH> query;
    query.TraceRayInline(
        SceneBVH,
        RAY_FLAG_SKIP_PROCEDURAL_PRIMITIVES
            | RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH,
        INSTANCE_MASK_OPAQUE_OR_ALPHA_TEST_SECONDARY,
        ray);

    while (query.Proceed()) {
        HitInfo hitInfo;
        hitInfo.rayT = query.CandidateTriangleRayT();
        hitInfo.frontFacing = query.CandidateTriangleFrontFace();
        hitInfo.barycentric2 =
            query.CandidateTriangleBarycentrics();
        hitInfo.materialType = query.CandidateInstanceID();
        hitInfo.objectInstanceIndex =
            query.CandidateInstanceIndex();
        hitInfo.primitiveId = query.CandidatePrimitiveIndex();
        if (AlphaTestHitLogic(hitInfo))
            query.CommitNonOpaqueTriangleHit();
    }
    return query.CommittedStatus() != COMMITTED_NOTHING;
}

#endif
