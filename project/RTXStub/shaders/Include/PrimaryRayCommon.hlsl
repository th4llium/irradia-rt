#ifndef __PRIMARY_RAY_COMMON_HLSL__
#define __PRIMARY_RAY_COMMON_HLSL__

#include "Renderer.hlsl"
#include "VolumetricLighting.hlsl"

uint GetPrimaryRaySeed(uint2 pixelCoord)
{
    uint3 noiseCoord = uint3(
        pixelCoord % uint2(64, 32),
        g_view.frameCount % 8);
    float4 noise = blueNoiseTexture.Load(uint4(noiseCoord, 0));
    uint seed =
        (uint)(noise.x * 4294967295.0)
        ^ (uint)(noise.y * 4294967295.0)
        ^ (g_view.frameCount * 73856093u);
    rand_pcg(seed);
    return seed;
}

float2 GetPixelNdc(uint2 pixelCoord)
{
    float2 ndc =
        ((float2)pixelCoord + 0.5)
        / g_view.renderResolution
        * 2.0
        - 1.0;
    ndc.y = -ndc.y;
    return ndc;
}

RayDesc GetPrimaryRayDesc(uint2 pixelCoord)
{
    RayDesc rayDesc;
    rayDesc.Direction = rayDirFromNDC(getNDCjittered(pixelCoord));
    
    if (g_view.cameraIsUnderWater) {
        float t = g_view.time * 2.0;
        float3 noisePos = g_view.viewOriginSteveSpace * 0.5 + rayDesc.Direction * 2.0;
        float3 wobble = sin(noisePos * float3(2.5, 2.0, 2.2) + float3(-t, t, t*1.1));
        rayDesc.Direction = normalize(rayDesc.Direction + wobble * 0.005);
    }
    
    rayDesc.Origin = g_view.viewOriginSteveSpace;
    rayDesc.TMin = 0;
    rayDesc.TMax = 10000;
    return rayDesc;
}

bool HasInvalidPrimaryResult(
    float3 colorEstimate,
    float2 motionVector,
    float pathDistance,
    bool checkNaN)
{
    return checkNaN
        ? any(isnan(colorEstimate))
            || any(isnan(motionVector))
            || isnan(pathDistance)
        : any(isinf(colorEstimate))
            || any(isinf(motionVector))
            || isinf(pathDistance);
}

float3 GetDiagnosticCheckerboard(uint2 pixelCoord, float3 color)
{
    return ((pixelCoord.x / 32 + pixelCoord.y / 32) & 1)
        ? color
        : (0.0).xxx;
}

void ComputePrimaryUnderwaterFog(
    float3 rayOrigin,
    float3 rayDirection,
    float rayDistance,
    out float3 outTransmittance,
    out float3 outInscatter)
{
    float fogDistance =
        rayDistance >= 65000.0
            ? GetVolumetricFogMaxDistance()
            : rayDistance;
    fogDistance = min(max(fogDistance, 0.0), GetVolumetricFogMaxDistance());

    float3 waterExtinction =
        GetWaterExtinctionCoefficient(
            max(g_view.mediaExtinction[MEDIA_TYPE_WATER].rgb, 0.0));
    float scalarExtinction =
        max(getLuminance(waterExtinction), 1.0e-4);

    outTransmittance = exp(-waterExtinction * fogDistance);

    float fogAmount =
        1.0 - exp(-scalarExtinction * fogDistance);
    float3 sunDir = getOffsetTrueDirectionToSun();
    float3 moonDir = getOffsetTrueDirectionToMoon();
    float sunFade = GetSunAmount(sunDir);
    float moonFade = GetMoonAmount(sunDir, moonDir);
    float isSun = step(moonFade, sunFade);
    float3 mainLightDir = lerp(moonDir, sunDir, isSun);
    float mainLightFade = lerp(moonFade, sunFade, isSun);

    float3 sunRadiance;
    float sunLux;
    GetSunColorAndLux(rayOrigin, sunDir, sunRadiance, sunLux);
    float3 moonRadiance;
    float moonLux;
    GetMoonColorAndLux(rayOrigin, sunDir, moonDir, moonRadiance, moonLux);
    float3 mainRadiance = lerp(moonRadiance, sunRadiance, isSun);

    float3 skyAmbient;
    float skyLux;
    GetSkyAmbientAndLux(
        rayOrigin,
        float3(0.0, 1.0, 0.0),
        sunDir,
        moonDir,
        skyAmbient,
        skyLux);

    float cosTheta = dot(rayDirection, mainLightDir);
    float g = 0.6;
    float phaseHG =
        (1.0 - g * g)
        / (4.0 * PI
            * pow(max(1.0 + g * g - 2.0 * g * cosTheta, 0.001), 1.5));
    float uniformPhase = 1.0 / (4.0 * PI);
    float3 waterScattering = GetWaterScatteringCoefficient();
    float3 baseBlue = float3(0.010, 0.050, 0.080);
    float3 sourceLight =
        mainRadiance * mainLightFade * phaseHG * 1.35
        + skyAmbient * uniformPhase * 2.0
        + baseBlue;

    outInscatter =
        sourceLight
        * waterScattering
        * (fogAmount / scalarExtinction);

    if (any(isnan(outInscatter)) || any(isinf(outInscatter)))
        outInscatter = 0.0;
}

void StorePrimaryRayOutputs(
    uint2 pixelCoord,
    RayDesc rayDesc,
    float pathDistance,
    float firstHitDistance,
    float3 primaryMotion,
    float3 diffuseIrradiance,
    float3 specularRadiance,
    float3 baseColor,
    float3 albedo,
    float3 emission,
    float3 normal,
    float roughness,
    float metalness,
    float opacity,
    float subsurface,
    float3 primaryWorldPosition,
    float3 primaryViewDirection,
    float3 primaryThroughput,
    uint primaryMaterialClass,
    float4 incomingIrradianceCache,
    bool hitGlass)
{
    float primaryDepth =
        pathDistance > 0.0
            ? pathDistance
            : firstHitDistance;
    const float SKY_DISTANCE = 65000.0;
    bool primaryHitSky =
        primaryDepth >= SKY_DISTANCE
        && firstHitDistance >= SKY_DISTANCE;
    float primaryCloudDepth =
        firstHitDistance > 0.0
            ? firstHitDistance
            : primaryDepth;

    bool hasStoredSurface =
        primaryMaterialClass != kPrimaryMaterialSky
        && primaryDepth < SKY_DISTANCE
        && all(isfinite(primaryWorldPosition));
    float3 primaryHitPosition =
        hasStoredSurface
            ? primaryWorldPosition
            : rayDesc.Origin + rayDesc.Direction * primaryDepth;
    float3 previousPrimaryHitPosition =
        primaryHitPosition - primaryMotion;
    float2 motionVector =
        computeMotionVector(primaryHitPosition, primaryMotion);
    float reprojectedPathLength = primaryDepth;
    if (primaryDepth < SKY_DISTANCE) {
        reprojectedPathLength = length(
            previousPrimaryHitPosition - g_view.previousViewOriginSteveSpace);
    }
    if (primaryHitSky) {
        motionVector = 0.0;
        reprojectedPathLength = SKY_DISTANCE;
    }

    float3 transmittance = 1.0;
    float3 inscatter = 0.0;
    if (g_view.cameraIsUnderWater != 0)
    {
        ComputePrimaryUnderwaterFog(
            rayDesc.Origin,
            rayDesc.Direction,
            primaryDepth,
            transmittance,
            inscatter);
    }
    else if (!primaryHitSky)
    {
        ComputeVolumetricFog(
            GetPixelNdc(pixelCoord),
            primaryDepth,
            transmittance,
            inscatter);
    }

    diffuseIrradiance *= transmittance;
    specularRadiance *= transmittance;
    emission = emission * transmittance + inscatter;

    float cloudTransmittance = 1.0;
    float3 cloudInscatter = 0.0;
    if (primaryHitSky
        && primaryCloudDepth >= SKY_DISTANCE
        && !hitGlass
        && !g_view.cameraIsUnderWater)
    {
        float cloudDither = GetVolumetricCloudDither(pixelCoord);
        ComputeDirectVolumetricClouds(
            rayDesc.Origin,
            rayDesc.Direction,
            primaryCloudDepth,
            cloudDither,
            cloudTransmittance,
            cloudInscatter);
    }
    diffuseIrradiance *= cloudTransmittance;
    specularRadiance *= cloudTransmittance;
    emission = emission * cloudTransmittance + cloudInscatter;

    float3 finalEstimate =
        albedo * diffuseIrradiance
        + specularRadiance
        + emission;
    if (HasInvalidPrimaryResult(
        finalEstimate, motionVector, pathDistance, false))
    {
        diffuseIrradiance = 0.0;
        specularRadiance = 0.0;
        emission = 0.0;
        albedo = GetDiagnosticCheckerboard(pixelCoord, float3(1, 1, 0));
        baseColor = albedo;
    }
    if (HasInvalidPrimaryResult(
        finalEstimate, motionVector, pathDistance, true))
    {
        diffuseIrradiance = 0.0;
        specularRadiance = 0.0;
        emission = 0.0;
        albedo = GetDiagnosticCheckerboard(pixelCoord, float3(1, 0, 1));
        baseColor = albedo;
    }

    float farFireflyClamp =
        smoothstep(96.0, 384.0, primaryDepth);
    float maxDiffuseLuminance =
        lerp(256.0, 64.0, farFireflyClamp);
    float maxSpecularLuminance =
        lerp(512.0, 96.0, farFireflyClamp);
    diffuseIrradiance =
        ClampIndirectRadiance(diffuseIrradiance, maxDiffuseLuminance);
    specularRadiance =
        ClampIndirectRadiance(specularRadiance, maxSpecularLuminance);

    float3 storedPrimaryViewDirection =
        dot(primaryViewDirection, primaryViewDirection) > 1.0e-8
            ? safeNormalize(primaryViewDirection, rayDesc.Direction)
            : rayDesc.Direction;
    float3 storedPrimaryThroughput =
        all(isfinite(primaryThroughput))
            ? max(primaryThroughput, 0.0)
            : (1.0).xxx;

    outputBufferIndirectDiffuse[pixelCoord] = float4(diffuseIrradiance, 1.0);
    outputBufferIndirectSpecular[pixelCoord] = float4(specularRadiance, 1.0);
    outputBufferNormal[pixelCoord] = ndirToOct(normal);
    outputGeometryNormal[pixelCoord] = ndirToOct(normal);
    outputBufferRayThroughput[pixelCoord] = albedo;
    outputBufferRayDirection[pixelCoord] = float4(emission, roughness);
    outputBufferIncomingIrradianceCache[pixelCoord] =
        float4(
            incomingIrradianceCache.rgb * transmittance,
            incomingIrradianceCache.a);
    outputBufferEmissiveAndLinearRoughness[pixelCoord] =
        float4(emission, roughness);
    outputBufferPreviousLinearRoughness[pixelCoord] = roughness;
    outputBufferColourAndMetallic[pixelCoord] =
        float4(saturate(baseColor), saturate(metalness));
    outputBufferSurfaceOpacityAndObjectCategory[pixelCoord] =
        float2(saturate(opacity), saturate(subsurface));
    outputPrimaryWorldPosition[pixelCoord] =
        float4(primaryHitPosition, (float)primaryMaterialClass);
    outputPrimaryViewDirection[pixelCoord] =
        float4(storedPrimaryViewDirection, primaryDepth);
    outputPrimaryThroughput[pixelCoord] =
        float4(storedPrimaryThroughput, (float)primaryMaterialClass);
    outputBufferPrimaryPosLowPrecision[pixelCoord] =
        float4(primaryHitPosition, 1.0);

    outputBufferFinal[pixelCoord] =
        float4(albedo * diffuseIrradiance + specularRadiance + emission, 1);
    outputBufferMotionVectors[pixelCoord] = motionVector;
    outputBufferReprojectedPathLength[pixelCoord] = reprojectedPathLength;
    outputBufferPrimaryPathLength[pixelCoord] = primaryDepth;
}

#endif
