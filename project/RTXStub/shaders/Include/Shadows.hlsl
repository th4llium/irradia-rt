#ifndef __SHADOWS_HLSL__
#define __SHADOWS_HLSL__

#include "Generated/Signature.hlsl"
#include "Material.hlsl"
#include "Water.hlsl"

#ifndef CULL_GLASS_BACK_FACES
#define CULL_GLASS_BACK_FACES 0
#endif

#ifndef CELESTIAL_SHADOW_TEMPORAL_ALPHA
#define CELESTIAL_SHADOW_TEMPORAL_ALPHA 0.035
#endif

#ifndef CELESTIAL_SHADOW_MAX_HISTORY_LENGTH
#define CELESTIAL_SHADOW_MAX_HISTORY_LENGTH 64.0
#endif

#ifndef CELESTIAL_SHADOW_DISAGREEMENT_START
#define CELESTIAL_SHADOW_DISAGREEMENT_START 0.18
#endif

#ifndef CELESTIAL_SHADOW_DISAGREEMENT_END
#define CELESTIAL_SHADOW_DISAGREEMENT_END 0.62
#endif

#ifndef CELESTIAL_SHADOW_DISAGREEMENT_ALPHA
#define CELESTIAL_SHADOW_DISAGREEMENT_ALPHA 0.82
#endif

#ifndef CELESTIAL_SHADOW_MAX_TEMPORAL_TRANSMISSION
#define CELESTIAL_SHADOW_MAX_TEMPORAL_TRANSMISSION 1.25
#endif

#ifndef CELESTIAL_SHADOW_TRANSMISSION_POWER
#define CELESTIAL_SHADOW_TRANSMISSION_POWER 1.38
#endif

#ifndef CELESTIAL_SHADOW_DARKENING_ALPHA
#define CELESTIAL_SHADOW_DARKENING_ALPHA 0.92
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

float3 ShapeSunShadowTransmission(float3 transmission)
{
    float3 shaped = pow(
        saturate(transmission),
        (CELESTIAL_SHADOW_TRANSMISSION_POWER).xxx);
    return shaped + max(transmission - 1.0, 0.0);
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
    bool hitWaterForCaustics = false;

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
            transmission *= CalcWaterCausticTransmission(
                GetWaterCausticPatternPosition(waterHitPosition),
                hitInfo.rayT);
            hitWaterForCaustics = true;
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

    if (!hitWaterForCaustics
        && query.CommittedStatus() == COMMITTED_NOTHING)
    {
        float3 projectedWaterTransmission;
        if (TryGetProjectedWaterCausticTransmission(
            ray.Origin,
            ray.Direction,
            projectedWaterTransmission))
        {
            transmission *= projectedWaterTransmission;
        }
    }

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
    return 0.05 + min(max(pathLength, 0.0) * 0.0025, 0.18);
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
    int2 basePixel = int2(floor(previousPixelCenter));
    int2 renderSize = int2(g_view.renderResolution);
    float previousPathLength = length(
        previousPosition - g_view.previousViewOriginSteveSpace);
    float depthTolerance =
        GetShadowHistoryDepthTolerance(previousPathLength);
    float historyFilterRadius =
        lerp(0.70, 1.05, smoothstep(96.0, 384.0, previousPathLength));

    float4 historySum = 0.0;
    float weightSum = 0.0;
    [loop]
    for (int sampleIndex = 0; sampleIndex < 9; ++sampleIndex)
    {
        int2 offset = int2(sampleIndex % 3, sampleIndex / 3) - 1;
        int2 samplePixel = basePixel + offset;
        if (any(samplePixel < 0) || any(samplePixel >= renderSize))
            continue;

        float2 sampleCenter = (float2)samplePixel + 0.5;
        float2 historyDelta = sampleCenter - previousPixelCenter;
        float weight =
            exp2(
                -dot(historyDelta, historyDelta)
                / max(historyFilterRadius * historyFilterRadius, 1.0e-4));
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
            0.82,
            0.97,
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
    currentTransmission = ShapeSunShadowTransmission(currentTransmission);
    outputBufferSunLightShadow[pixelCoord] =
        float4(currentTransmission, 1.0 / 255.0);
    return currentTransmission;
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
