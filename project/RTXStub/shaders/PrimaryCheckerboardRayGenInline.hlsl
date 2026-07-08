/* MIT License
 *
 * Copyright (c) 2025 veka0
 * Copyright (c) 2026 th4llium
 */

#define MCRTX_PRIMARY_GUIDE_ONLY 1
#include "Include/PrimaryRayCommon.hlsl"

[numthreads(4, 8, 1)]
void PrimaryCheckerboardRayGenInline(
    uint3 dispatchThreadID: SV_DispatchThreadID,
    uint3 groupThreadID: SV_GroupThreadID,
    uint groupIndex: SV_GroupIndex,
    uint3 groupID: SV_GroupID)
{
    uint2 pixelCoord = dispatchThreadID.xy;
    if (any(pixelCoord >= g_view.renderResolution)) return;

    outputBufferSunLightShadow[pixelCoord] = 0.0;

    RayDesc rayDesc = GetPrimaryRayDesc(pixelCoord);
    uint randSeed = GetPrimaryRaySeed(pixelCoord);

    float pathDistance;
    float firstHitDistance;
    float3 primaryMotion;
    float3 diffuseIrradiance;
    float3 specularRadiance;
    float3 baseColor;
    float3 albedo;
    float3 emission;
    float3 normal;
    float roughness;
    float metalness;
    float opacity;
    float subsurface;
    float3 primaryWorldPosition;
    float3 primaryViewDirection;
    float3 primaryThroughput;
    uint primaryMaterialClass;
    float4 incomingIrradianceCache;
    bool hitGlass;

    RenderRayDenoised(
        pixelCoord,
        rayDesc,
        randSeed,
        kDielectricPathRefract,
        pathDistance,
        firstHitDistance,
        primaryMotion,
        diffuseIrradiance,
        specularRadiance,
        baseColor,
        albedo,
        emission,
        normal,
        roughness,
        metalness,
        opacity,
        subsurface,
        primaryWorldPosition,
        primaryViewDirection,
        primaryThroughput,
        primaryMaterialClass,
        incomingIrradianceCache,
        hitGlass);

    StorePrimaryRayOutputs(
        pixelCoord,
        rayDesc,
        pathDistance,
        firstHitDistance,
        primaryMotion,
        diffuseIrradiance,
        specularRadiance,
        baseColor,
        albedo,
        emission,
        normal,
        roughness,
        metalness,
        opacity,
        subsurface,
        primaryWorldPosition,
        primaryViewDirection,
        primaryThroughput,
        primaryMaterialClass,
        incomingIrradianceCache,
        hitGlass);
}
