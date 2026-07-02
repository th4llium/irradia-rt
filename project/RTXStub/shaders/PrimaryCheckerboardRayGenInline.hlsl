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

#include "Include/Renderer.hlsl"
#include "Include/Util.hlsl"
#include "Include/VolumetricLighting.hlsl"

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

[numthreads(4, 8, 1)]
void PrimaryCheckerboardRayGenInline(
    uint3 dispatchThreadID: SV_DispatchThreadID,
    uint3 groupThreadID: SV_GroupThreadID,
    uint groupIndex: SV_GroupIndex,
    uint3 groupID: SV_GroupID)
{
    if (any(dispatchThreadID.xy >= g_view.renderResolution)) return;

    outputBufferSunLightShadow[dispatchThreadID.xy] = 0.0;

    RayDesc rayDesc;
    rayDesc.Direction = rayDirFromNDC(getNDCjittered(dispatchThreadID.xy));
    rayDesc.Origin = g_view.viewOriginSteveSpace;
    rayDesc.TMin = 0;
    rayDesc.TMax = 10000;

    uint randSeed = GetPrimaryRaySeed(dispatchThreadID.xy);

    float pathDistance;
    float3 primaryMotion;
    float3 diffuseIrradiance;
    float3 specularRadiance;
    float3 albedo;
    float3 emission;
    float3 normal;
    float firstHitDistance;
    float roughness;
    float4 incomingIrradianceCache;
    bool hitGlass;

    RenderRayDenoised(
        dispatchThreadID.xy,
        rayDesc,
        randSeed,
        kDielectricPathRefract,
        pathDistance,
        firstHitDistance,
        primaryMotion,
        diffuseIrradiance,
        specularRadiance,
        albedo,
        emission,
        normal,
        roughness,
        incomingIrradianceCache,
        hitGlass);

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
    float3 primaryHitPosition =
        rayDesc.Origin + rayDesc.Direction * primaryDepth;
    float3 previousPrimaryHitPosition =
        primaryHitPosition - primaryMotion;
    float2 motionVector =
        computeMotionVector(primaryHitPosition, primaryMotion);
    float reprojectedPathLength = primaryDepth;
    if (primaryDepth < 65000.0) {
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
            GetPixelNdc(dispatchThreadID.xy),
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
        uint3 cloudNoiseCoord = uint3(
            dispatchThreadID.xy % uint2(256, 256),
            0);
        float cloudDither =
            blueNoiseTexture.Load(uint4(cloudNoiseCoord, 0)).r;
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
        albedo = GetDiagnosticCheckerboard(dispatchThreadID.xy, float3(1, 1, 0));
    }
    if (HasInvalidPrimaryResult(
        finalEstimate, motionVector, pathDistance, true))
    {
        diffuseIrradiance = 0.0;
        specularRadiance = 0.0;
        emission = 0.0;
        albedo = GetDiagnosticCheckerboard(dispatchThreadID.xy, float3(1, 0, 1));
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

    outputBufferIndirectDiffuse[dispatchThreadID.xy] = float4(diffuseIrradiance, 1.0);
    outputBufferIndirectSpecular[dispatchThreadID.xy] = float4(specularRadiance, 1.0);
    outputBufferNormal[dispatchThreadID.xy] = ndirToOct(normal);
    outputBufferRayThroughput[dispatchThreadID.xy] = albedo;
    outputBufferRayDirection[dispatchThreadID.xy] = float4(emission, roughness);
    outputBufferIncomingIrradianceCache[dispatchThreadID.xy] =
        float4(
            incomingIrradianceCache.rgb * transmittance,
            incomingIrradianceCache.a);
    outputBufferEmissiveAndLinearRoughness[dispatchThreadID.xy] =
        float4(emission, roughness);
    outputBufferPreviousLinearRoughness[dispatchThreadID.xy] = roughness;

    outputBufferFinal[dispatchThreadID.xy] =
        float4(albedo * diffuseIrradiance + specularRadiance + emission, 1);
    outputBufferMotionVectors[dispatchThreadID.xy] = motionVector;
    outputBufferReprojectedPathLength[dispatchThreadID.xy] = reprojectedPathLength;
    outputBufferPrimaryPathLength[dispatchThreadID.xy] = primaryDepth;
}

