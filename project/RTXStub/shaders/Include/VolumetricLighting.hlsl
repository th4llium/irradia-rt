#ifndef __VOLUMETRIC_LIGHTING_HLSL__
#define __VOLUMETRIC_LIGHTING_HLSL__

#include "Generated/Signature.hlsl"
#include "Sky.hlsl"
#include "Shadows.hlsl"

float HenyeyGreensteinPhase(float cosTheta, float g) {
    float g2 = g * g;
    return (1.0 - g2) / (4.0 * PI * pow(1.0 + g2 - 2.0 * g * cosTheta, 1.5));
}

void ComputeVolumetricFog(float3 rayOrigin, float3 rayDir, float hitDistance, out float3 outTransmittance, out float3 outInscatter)
{
    const int STEPS = 16;
    float maxDist = min(hitDistance, 150.0); 
    if (maxDist < 0.1) {
        outTransmittance = 1.0;
        outInscatter = 0.0;
        return;
    }

    float stepSize = maxDist / (float)STEPS;
    
    float3 totalScattering = 0;
    float3 transmittance = 1.0;
    
    float dither = frac(sin(dot(rayDir.xy, float2(12.9898, 78.233))) * 43758.5453);
    
    float3 sunDir = getOffsetPrimaryCelestialDirection();
    float3 moonDir = -sunDir;
    
    float3 sunRadiance; float sunLux;
    GetSunColorAndLux(rayOrigin, sunDir, sunRadiance, sunLux);
    float3 moonRadiance; float moonLux;
    GetMoonColorAndLux(rayOrigin, sunDir, moonDir, moonRadiance, moonLux);
    
    float3 mainLightDir = sunDir.y > 0.0 ? sunDir : moonDir;
    float3 mainRadiance = sunDir.y > 0.0 ? sunRadiance : moonRadiance;
    
    float cosTheta = dot(rayDir, mainLightDir);
    bool isUnderwater = g_view.cameraIsUnderWater > 0;
    float phase = HenyeyGreensteinPhase(cosTheta, isUnderwater ? 0.6 : 0.75);
    
    
    float3 baseFogColor = GetFogColor(rayOrigin, rayDir, 50.0, sunDir, moonDir);
    float3 normalizedFogColor = baseFogColor / (max(getLuminance(baseFogColor), 0.001));

    float exposure = GetAutoExposureMultiplier(rayOrigin, sunDir, moonDir);
    
    float3 waterExtinction = float3(0.8, 0.2, 0.05) * 0.025;
    float3 waterScattering = float3(0.1, 0.8, 0.9) * 0.025;
    for (int i = 0; i < STEPS; i++)
    {
        float t = (float(i) + dither) * stepSize;
        float3 pos = rayOrigin + rayDir * t;
        
        float2 noiseCoord = pos.xy * 100.0 + g_view.time * 10.0;
        float3 noise = hash32(noiseCoord);
        float3 jitteredDir =
            sampleCelestialLightDisk(mainLightDir, noise.xy);

        RayDesc shadowRay;
        shadowRay.Origin = pos + 1.0e-5 * float3(0,1,0);
        shadowRay.Direction = jitteredDir;
        shadowRay.TMin = 0.0;
        shadowRay.TMax = 10000.0;
        ShadowPayload payload;
        TraceShadowRay(shadowRay, payload);
        float3 shadow = payload.transmission;
        
        float3 stepExtinction;
        float3 inScatteredLight;
        
        if (isUnderwater) {
            stepExtinction = waterExtinction;
            float3 sunScattering = mainRadiance * shadow * phase * waterScattering;
            float3 ambientScattering = float3(0.01, 0.05, 0.08) * waterScattering * 0.5;
            inScatteredLight = sunScattering + ambientScattering;
        } else {
            float currentHeight = pos.y - 62.0;
            float densityMultiplier = hitDistance > 2000.0 ? 0.2 : 1.0;
            float currentDensity = 0.0015 * exp(-max(0.0, currentHeight) * 0.04) * densityMultiplier;
            stepExtinction = (currentDensity).xxx;
            float3 sunScattering = mainRadiance * shadow * phase * currentDensity;
            float3 ambientScattering = normalizedFogColor * 0.05 * currentDensity;
            inScatteredLight = sunScattering + ambientScattering;
        }
        
        float3 stepTransmittance = exp(-stepExtinction * stepSize);
        totalScattering += transmittance * inScatteredLight * stepSize;
        transmittance *= stepTransmittance;
    }
    
    outTransmittance = transmittance;
    outInscatter = totalScattering * exposure;
}

void ApplyVolumetricFog(float3 rayOrigin, float3 rayDir, float hitDistance, inout float3 color)
{
    float3 transmittance, inscatter;
    ComputeVolumetricFog(rayOrigin, rayDir, hitDistance, transmittance, inscatter);
    color = color * transmittance + inscatter;
}

#endif
