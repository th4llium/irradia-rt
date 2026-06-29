#ifndef __VOLUMETRIC_LIGHTING_HLSL__
#define __VOLUMETRIC_LIGHTING_HLSL__

#include "Generated/Signature.hlsl"
#include "Sky.hlsl"
#include "Shadows.hlsl"
#include "VolumetricClouds.hlsl"

static const int3 kVolumetricFogResolution = int3(256, 128, 64);
static const int3 kVolumetricFogMaxTexel = kVolumetricFogResolution - 1;

float HenyeyGreensteinPhase(float cosTheta, float g) {
    float g2 = g * g;
    return (1.0 - g2) / (4.0 * PI * pow(1.0 + g2 - 2.0 * g * cosTheta, 1.5));
}

float3 SampleFogVolume(Texture3D<float3> volume, float3 uvw)
{
    float3 texelPosition = uvw * (float3)kVolumetricFogResolution - 0.5;
    int3 baseTexel = floor(texelPosition);
    float3 blend = frac(texelPosition);
    
    float3 c000 = volume.Load(int4(clamp(baseTexel + int3(0, 0, 0), 0, kVolumetricFogMaxTexel), 0));
    float3 c100 = volume.Load(int4(clamp(baseTexel + int3(1, 0, 0), 0, kVolumetricFogMaxTexel), 0));
    float3 c010 = volume.Load(int4(clamp(baseTexel + int3(0, 1, 0), 0, kVolumetricFogMaxTexel), 0));
    float3 c110 = volume.Load(int4(clamp(baseTexel + int3(1, 1, 0), 0, kVolumetricFogMaxTexel), 0));
    float3 c001 = volume.Load(int4(clamp(baseTexel + int3(0, 0, 1), 0, kVolumetricFogMaxTexel), 0));
    float3 c101 = volume.Load(int4(clamp(baseTexel + int3(1, 0, 1), 0, kVolumetricFogMaxTexel), 0));
    float3 c011 = volume.Load(int4(clamp(baseTexel + int3(0, 1, 1), 0, kVolumetricFogMaxTexel), 0));
    float3 c111 = volume.Load(int4(clamp(baseTexel + int3(1, 1, 1), 0, kVolumetricFogMaxTexel), 0));
    
    float3 c00 = lerp(c000, c100, blend.x);
    float3 c10 = lerp(c010, c110, blend.x);
    float3 c01 = lerp(c001, c101, blend.x);
    float3 c11 = lerp(c011, c111, blend.x);
    
    float3 c0 = lerp(c00, c10, blend.y);
    float3 c1 = lerp(c01, c11, blend.y);
    
    return lerp(c0, c1, blend.z);
}

void ComputeVolumetricFog(float2 ndc, float hitDistance, out float3 outTransmittance, out float3 outInscatter)
{
    float maxDistance = GetVolumetricFogMaxDistance();
    float clampedDistance = min(hitDistance, maxDistance);
    if (clampedDistance < 0.1) {
        outTransmittance = 1.0;
        outInscatter = 0.0;
        return;
    }

    float3 uvw;
    uvw.xy = ndc * float2(0.5, -0.5) + 0.5;
    uvw.z = sqrt(saturate(clampedDistance / maxDistance));

    outTransmittance = SampleFogVolume(volumetricResolvedTransmission, uvw);
    outInscatter = SampleFogVolume(volumetricResolvedInscatter, uvw);
}

void ApplyVolumetricFog(float2 ndc, float hitDistance, inout float3 color)
{
    float3 transmittance, inscatter;
    ComputeVolumetricFog(ndc, hitDistance, transmittance, inscatter);
    color = color * transmittance + inscatter;
}

#endif
