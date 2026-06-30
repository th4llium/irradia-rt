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

    float3 transmittance;
    float3 inscatter;
    ComputeVolumetricFog(
        GetPixelNdc(dispatchThreadID.xy),
        primaryDepth,
        transmittance,
        inscatter);

    diffuseIrradiance *= transmittance;
    specularRadiance *= transmittance;
    emission = emission * transmittance + inscatter;

    float cloudTransmittance = 1.0;
    float3 cloudInscatter = 0.0;
    if (!hitGlass && !g_view.cameraIsUnderWater) {
        uint3 cloudNoiseCoord = uint3(
            dispatchThreadID.xy % uint2(256, 256),
            0);
        float cloudDither =
            blueNoiseTexture.Load(uint4(cloudNoiseCoord, 0)).r;
        ComputeDirectVolumetricClouds(
            rayDesc.Origin,
            rayDesc.Direction,
            primaryDepth,
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

    const float maxLuminance = 4096.0;
    diffuseIrradiance =
        ClampIndirectRadiance(diffuseIrradiance, maxLuminance);
    specularRadiance =
        ClampIndirectRadiance(specularRadiance, maxLuminance);

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

