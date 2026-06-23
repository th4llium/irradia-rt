#ifndef __SHADOWS_HLSL__
#define __SHADOWS_HLSL__

#include "Generated/Signature.hlsl"
#include "Material.hlsl"
#include "Water.hlsl"

#ifndef CULL_GLASS_BACK_FACES
#define CULL_GLASS_BACK_FACES 0
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
