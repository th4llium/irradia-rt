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

#ifndef __RENDERER_HLSL__
#define __RENDERER_HLSL__

#include "Generated/Signature.hlsl"
#include "Material.hlsl"
#include "BRDF.hlsl"
#include "Util.hlsl"
#include "Water.hlsl"

struct LightData
{
    float3 color;
    float intensity;
    bool isLarge;
};

LightData UnpackLight(uint packedData)
{
    LightData lightData;
    lightData.isLarge = (packedData >> 24) & 0x80;
    lightData.color = float3(
        (float)((packedData >> 24) & 0x7f) / 127.0,
        (float)((packedData >> 16) & 0xff) / 255.0,
        (float)((packedData >> 8) & 0xff) / 255.0);
    lightData.intensity = (float)((packedData >> 0) & 0xff) / 255.0;
    return lightData;
}

static const uint kPrimaryLobeNone = 0;
static const uint kPrimaryLobeDiffuse = 1;
static const uint kPrimaryLobeSpecular = 2;

static const uint kDielectricPathSample = 0;
static const uint kDielectricPathReflect = 1;
static const uint kDielectricPathRefract = 2;

struct RayState
{
    RayDesc rayDesc;

    float3 color;
    float3 throughput;

    float3 diffuseIrradiance;
    float3 specular;
    float3 primaryAlbedo;
    float3 primaryEmission;
    float3 primaryNormal;
    float primaryRoughness;
    float primaryMetalness;
    float3 primaryCachedIrradiance;
    float primaryIrradianceCacheConfidence;

    float distance;
    float3 motion;

    bool foundPrimarySurface;
    float accumulatedDistance;

    uint instanceMask;

    uint randSeed;
    int bounceCount;
    bool terminate;
    bool inWater;
    uint mediumDepth;
    uint mediumStack[4];
    float3 mediumExtinctionStack[4];
    uint primaryLobe;
    bool hasRayCone;
    float rayConeRadius;
    float rayConeSpread;
    uint2 pixelCoord;
    int blueNoiseSequence;
    float globalExposure;
    uint dielectricPath;
    bool hitGlassPrimary;
    bool primaryDielectricSurfaceSeen;

    void Init(uint seed)
    {
        color = 0;
        throughput = 1;
        diffuseIrradiance = 0;
        specular = 0;
        primaryAlbedo = 0;
        primaryEmission = 0;
        primaryNormal = float3(0, 1, 0);
        primaryRoughness = 1.0;
        primaryMetalness = 0.0;
        primaryCachedIrradiance = 0.0;
        primaryIrradianceCacheConfidence = 0.0;
        distance = 0;
        motion = 0;
        foundPrimarySurface = false;
        accumulatedDistance = 0;
        instanceMask = 0xff & ~INSTANCE_MASK_SUN_OR_MOON;
        randSeed = seed;
        bounceCount = 0;
        terminate = false;
        inWater = g_view.cameraIsUnderWater;
        [unroll]
        for (int mediumIndex = 0; mediumIndex < 4; mediumIndex++) {
            mediumStack[mediumIndex] = MEDIA_TYPE_AIR;
            mediumExtinctionStack[mediumIndex] = 0.0;
        }
        mediumDepth = g_view.cameraIsUnderWater ? 2 : 1;
        if (g_view.cameraIsUnderWater) {
            mediumStack[1] = MEDIA_TYPE_WATER;
            float3 waterExtinction = max(g_view.mediaExtinction[MEDIA_TYPE_WATER].rgb, 0.0);
            mediumExtinctionStack[1] = any(waterExtinction > 0.0)
                ? min(
                    waterExtinction,
                    float3(0.8, 0.2, 0.05) * 0.025)
                : float3(0.8, 0.2, 0.05) * 0.0125;
        }
        primaryLobe = kPrimaryLobeNone;
        hasRayCone = false;
        rayConeRadius = 0.0;
        rayConeSpread = max(0.5 * g_view.primaryRaySpreadAngle, 0.0);
        blueNoiseSequence = 0;
        dielectricPath = kDielectricPathSample;
        hitGlassPrimary = false;
        primaryDielectricSurfaceSeen = false;
    }
};

bool ShouldDenoisePrimaryReflection(RayState rayState)
{
    return rayState.primaryRoughness >= 0.12
        || (rayState.primaryMetalness >= 0.5
            && rayState.primaryRoughness >= 0.06);
}

float GetDefaultMediumIor(uint mediumType)
{
    if (mediumType == MEDIA_TYPE_WATER)
        return 1.333;
    if (mediumType == MEDIA_TYPE_GLASS)
        return 1.5;
    return 1.0;
}

float GetMediumIor(uint mediumType)
{
    uint mediumIndex = min(mediumType, 4u);
    float engineIor = refractionIndicesBuffer[mediumIndex];
    return isfinite(engineIor) && engineIor >= 1.0 && engineIor <= 3.0
        ? engineIor
        : GetDefaultMediumIor(mediumIndex);
}

uint GetCurrentMediumType(RayState rayState)
{
    return rayState.mediumStack[max((int)rayState.mediumDepth - 1, 0)];
}

float GetCurrentMediumIor(RayState rayState)
{
    return GetMediumIor(GetCurrentMediumType(rayState));
}

float GetExitMediumIor(RayState rayState, uint exitingMediumType)
{
    if (rayState.mediumDepth > 1
        && rayState.mediumStack[rayState.mediumDepth - 1] == exitingMediumType)
    {
        return GetMediumIor(rayState.mediumStack[rayState.mediumDepth - 2]);
    }
    return GetMediumIor(MEDIA_TYPE_AIR);
}

float3 GetCurrentMediumExtinction(RayState rayState)
{
    return rayState.mediumExtinctionStack[
        max((int)rayState.mediumDepth - 1, 0)];
}

void UpdateMediumState(inout RayState rayState)
{
    rayState.inWater =
        GetCurrentMediumType(rayState) == MEDIA_TYPE_WATER;
}

void EnterMedium(
    inout RayState rayState,
    uint mediumType,
    float3 extinction)
{
    if (rayState.mediumDepth < 4) {
        uint stackIndex = rayState.mediumDepth;
        rayState.mediumStack[stackIndex] = mediumType;
        rayState.mediumExtinctionStack[stackIndex] = max(extinction, 0.0);
        rayState.mediumDepth++;
    } else {
        rayState.mediumStack[3] = mediumType;
        rayState.mediumExtinctionStack[3] = max(extinction, 0.0);
    }
    UpdateMediumState(rayState);
}

void ExitMedium(inout RayState rayState, uint mediumType)
{
    if (rayState.mediumDepth > 1) {
        uint topIndex = rayState.mediumDepth - 1;
        if (rayState.mediumStack[topIndex] == mediumType) {
            rayState.mediumDepth--;
        } else {
            [unroll]
            for (int stackIndex = 3; stackIndex >= 1; stackIndex--) {
                if ((uint)stackIndex < rayState.mediumDepth
                    && rayState.mediumStack[stackIndex] == mediumType)
                {
                    rayState.mediumDepth = stackIndex;
                    break;
                }
            }
        }
    }
    UpdateMediumState(rayState);
}

#include "Sky.hlsl"
#include "Shadows.hlsl"
#include "VolumetricLighting.hlsl"
#include "Water.hlsl"
#include "IrradianceCacheUpdate.hlsl"
#include "RenderVanilla.hlsl"

void RenderRayDenoised(
    uint2 pixelCoord,
    RayDesc rayDesc,
    uint randSeed,
    uint dielectricPath,
    out float outputDistance,
    out float outFirstHitDistance,
    out float3 outputMotion,
    out float3 outDiffuseIrradiance,
    out float3 outSpecular,
    out float3 outAlbedo,
    out float3 outEmission,
    out float3 outNormal,
    out float outRoughness,
    out float4 outIncomingIrradianceCache,
    out bool outHitGlassPrimary)
{
    RayState rayState;
    rayState.Init(randSeed);
    rayState.dielectricPath = dielectricPath;
    float3 exposureSunDirection =
        getOffsetTrueDirectionToSun();
    float3 exposureMoonDirection =
        getOffsetTrueDirectionToMoon();
    rayState.globalExposure = GetAutoExposureMultiplier(
        rayDesc.Origin,
        exposureSunDirection,
        exposureMoonDirection);
    rayState.pixelCoord = pixelCoord;
    rayState.rayDesc = rayDesc;

    outFirstHitDistance = -1.0;

    [loop]
    for (int iteration = 0; iteration < 100; iteration++)
    {
        if (rayState.terminate) break;
        
        RayQuery<RAY_FLAG_NONE> q;
        
        q.TraceRayInline(SceneBVH, RAY_FLAG_SKIP_PROCEDURAL_PRIMITIVES, rayState.instanceMask, rayState.rayDesc);
        while (q.Proceed())
        {
            HitInfo hitInfo = GetCandidateHitInfo(q);
            if (AlphaTestHitLogic(hitInfo))
            {
                q.CommitNonOpaqueTriangleHit();
            }
        }

        if (q.CommittedStatus() == COMMITTED_TRIANGLE_HIT)
        {
            float dist = q.CommittedRayT();
            float3 mediumExtinction = GetCurrentMediumExtinction(rayState);
            rayState.throughput *= exp(-mediumExtinction * dist);
            if (rayState.inWater) {
                float3 sunDir = getOffsetTrueDirectionToSun();
                float3 moonDir = getOffsetTrueDirectionToMoon();
                float sunFade = GetSunAmount(sunDir);
                float moonFade = GetMoonAmount(sunDir, moonDir);
                float isSun = step(moonFade, sunFade);
                float3 mainLightDir = lerp(moonDir, sunDir, isSun);
                float cosTheta = dot(rayState.rayDesc.Direction, mainLightDir);
                float g = 0.6;
                float phaseHG = (1.0 - g*g) / pow(max(1.0 + g*g - 2.0*g*cosTheta, 0.001), 1.5);
                
                float3 sunRadiance; float sunLux;
                GetSunColorAndLux(rayState.rayDesc.Origin, sunDir, sunRadiance, sunLux);
                float3 moonRadiance; float moonLux;
                GetMoonColorAndLux(rayState.rayDesc.Origin, sunDir, moonDir, moonRadiance, moonLux);
                
                float3 mainRadiance = lerp(moonRadiance, sunRadiance, isSun);
                
                float3 scatterColor = float3(0.1, 0.8, 0.9) * 0.05 * phaseHG * (1.0 - exp(-0.025 * dist));
                float3 scatter = scatterColor * rayState.throughput * mainRadiance * lerp(moonFade, sunFade, isSun);
                
                rayState.color += scatter;
                if (rayState.bounceCount == 0) {
                    rayState.primaryEmission += scatter;
                }
            }

            HitInfo hitInfo = GetCommittedHitInfo(q);
            if (outFirstHitDistance < 0.0) outFirstHitDistance = hitInfo.rayT;
            RenderVanilla(hitInfo, rayState);
        }
        else
        {
            if (outFirstHitDistance < 0.0) outFirstHitDistance = 65504.0;
            float3 colorBefore = rayState.color;
            RenderSky(rayState);
            float3 skyContribution = rayState.color - colorBefore;
            if ((rayState.hitGlassPrimary || rayState.inWater)
                && getLuminance(skyContribution) < 1.0e-5)
            {
                skyContribution =
                    rayState.throughput
                    * GetTransparentEnvironmentSky(
                        rayState.rayDesc.Direction);
                rayState.color = colorBefore + skyContribution;
            }
            
            if (!rayState.foundPrimarySurface) {
                rayState.primaryEmission += skyContribution;
                rayState.distance = 65504.0;
                rayState.foundPrimarySurface = true;
            } else {
                float3 primaryAlbedo = max(
                    rayState.primaryAlbedo, 0.001);
                if (rayState.primaryLobe == kPrimaryLobeSpecular) {
                    if (ShouldDenoisePrimaryReflection(rayState))
                        rayState.specular += skyContribution;
                    else
                        rayState.primaryEmission += skyContribution;
                } else {
                    rayState.diffuseIrradiance +=
                        skyContribution / primaryAlbedo;
                }
            }
            
            rayState.accumulatedDistance += 65504.0;
            rayState.terminate = true;
        }
        
        if (all(rayState.throughput == 0)) {
            rayState.terminate = true;
        }
    }

    outputDistance = min(rayState.distance, 65504.0);
    outputMotion = rayState.motion;

    outDiffuseIrradiance = rayState.diffuseIrradiance;
    outSpecular = rayState.specular;
    outAlbedo = rayState.primaryAlbedo;
    outEmission = rayState.primaryEmission;
    outNormal = rayState.primaryNormal;
    outRoughness = rayState.primaryRoughness;
    outIncomingIrradianceCache = float4(
        rayState.primaryCachedIrradiance,
        rayState.primaryIrradianceCacheConfidence);
    outHitGlassPrimary = rayState.hitGlassPrimary;
}

float3 RenderRay(uint2 pixelCoord, RayDesc rayDesc, uint randSeed, out float outputDistance, out float3 outputMotion)
{
    float3 diffuseIrradiance;
    float3 specular;
    float3 albedo;
    float3 emission;
    float3 normal;
    float firstHitDistance;
    float roughness;
    float4 cacheSample;
    bool hitGlass;
    RenderRayDenoised(
        pixelCoord,
        rayDesc,
        randSeed,
        kDielectricPathSample,
        outputDistance,
        firstHitDistance,
        outputMotion,
        diffuseIrradiance,
        specular,
        albedo,
        emission,
        normal,
        roughness,
        cacheSample,
        hitGlass);
    return albedo * diffuseIrradiance + specular + emission;
}

#endif
