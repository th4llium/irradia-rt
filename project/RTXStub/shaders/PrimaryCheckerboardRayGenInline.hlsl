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
    rayDesc.TMin = 0; rayDesc.TMax = 10000;

    uint3 noiseCoord = uint3(dispatchThreadID.xy % uint2(64, 32), g_view.frameCount % 8);
    float4 noise = blueNoiseTexture.Load(uint4(noiseCoord, 0));
    uint randSeed = (uint)(noise.x * 4294967295.0) ^ (uint)(noise.y * 4294967295.0) ^ (g_view.frameCount * 73856093u);
    rand_pcg(randSeed);

    float pathDistance;
    float3 primaryMotion;
    float3 diffuseIrradiance, specular, albedo, emission, normal;
    float firstHitDist, roughness;
    float4 incomingIrradianceCache;
    bool hitGlass;

    RenderRayDenoised(
        dispatchThreadID.xy,
        rayDesc,
        randSeed,
        kDielectricPathRefract,
        pathDistance,
        firstHitDist,
        primaryMotion,
        diffuseIrradiance, specular, albedo, emission, normal, roughness,
        incomingIrradianceCache, hitGlass);

    if (hitGlass) {
        float unusedPathDistance;
        float unusedFirstHitDistance;
        float reflectionRoughness;
        float3 unusedMotion;
        float3 reflectionDiffuse;
        float3 reflectionSpecular;
        float3 reflectionAlbedo;
        float3 reflectionEmission;
        float3 unusedNormal;
        float4 unusedCache;
        bool unusedGlassHit;

        RenderRayDenoised(
            dispatchThreadID.xy,
            rayDesc,
            randSeed ^ 0x9E3779B9u,
            kDielectricPathReflect,
            unusedPathDistance,
            unusedFirstHitDistance,
            unusedMotion,
            reflectionDiffuse,
            reflectionSpecular,
            reflectionAlbedo,
            reflectionEmission,
            unusedNormal,
            reflectionRoughness,
            unusedCache,
            unusedGlassHit);

        float3 reflectionRadiance =
            reflectionAlbedo * reflectionDiffuse
            + reflectionSpecular
            + reflectionEmission;
        if (reflectionRoughness >= 0.12)
            specular += reflectionRadiance;
        else
            emission += reflectionRadiance;
    }

    float3 primaryHitPosition = rayDesc.Origin + rayDesc.Direction * firstHitDist;
    float3 previousPrimaryHitPosition =
        primaryHitPosition - primaryMotion;
    float2 motionVector =
        computeMotionVector(primaryHitPosition, primaryMotion);
    float reprojectedPathLength = firstHitDist;
    if (firstHitDist < 65000.0) {
        reprojectedPathLength = length(
            previousPrimaryHitPosition - g_view.previousViewOriginSteveSpace);
    }

    float3 transmittance, inscatter;
    ComputeVolumetricFog(rayDesc.Origin, rayDesc.Direction, firstHitDist, transmittance, inscatter);

    diffuseIrradiance *= transmittance;
    specular *= transmittance;
    emission = emission * transmittance + inscatter;

    float3 combinedCheck = albedo * diffuseIrradiance + specular + emission;
    if (any(isinf(combinedCheck))
        || any(isinf(motionVector))
        || isinf(pathDistance))
    {
        diffuseIrradiance = 0; specular = 0; emission = 0;
        albedo = (dispatchThreadID.x / 32 + dispatchThreadID.y / 32) & 1 ? float3(1, 1, 0) : 0;
    }
    if (any(isnan(combinedCheck))
        || any(isnan(motionVector))
        || isnan(pathDistance))
    {
        diffuseIrradiance = 0; specular = 0; emission = 0;
        albedo = (dispatchThreadID.x / 32 + dispatchThreadID.y / 32) & 1 ? float3(1, 0, 1) : 0;
    }
    const float maxLuminance = 4096.0;
    float diffLum = dot(diffuseIrradiance, float3(0.2126, 0.7152, 0.0722));
    if (diffLum > maxLuminance) diffuseIrradiance *= maxLuminance / diffLum;
    
    float specLum = dot(specular, float3(0.2126, 0.7152, 0.0722));
    if (specLum > maxLuminance) specular *= maxLuminance / specLum;

    outputBufferIndirectDiffuse[dispatchThreadID.xy] = float4(diffuseIrradiance, 1.0);
    outputBufferIndirectSpecular[dispatchThreadID.xy] = float4(specular, 1.0);
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

    outputBufferFinal[dispatchThreadID.xy] = float4(albedo * diffuseIrradiance + specular + emission, 1);
    outputBufferMotionVectors[dispatchThreadID.xy] = motionVector;
    outputBufferReprojectedPathLength[dispatchThreadID.xy] = reprojectedPathLength;
    outputBufferPrimaryPathLength[dispatchThreadID.xy] = firstHitDist;
}

