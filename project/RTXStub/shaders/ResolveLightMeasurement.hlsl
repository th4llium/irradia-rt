#include "Include/Generated/Signature.hlsl"

static const float kDesiredBrightness = 0.095;
static const float kMinExposureEv = -16.0;
static const float kMaxExposureEv = 1.20;

[numthreads(1, 1, 1)]
void ResolveLightMeasurement(
    uint3 dispatchThreadID : SV_DispatchThreadID,
    uint3 groupThreadID : SV_GroupThreadID,
    uint groupIndex : SV_GroupIndex, 
    uint3 groupID : SV_GroupID
    )
{
    if (dispatchThreadID.x != 0)
        return;

    float autoExposureSpeed = g_lightMeterSamples.lightAccumulationAlpha;

    float totalWeight = 0;
    float logLuminanceSum = 0;
    for (int i = 0; i < 512; i++)
    {
        float weight = bufferIncidentLight[i + 3].a;
        float3 color = bufferIncidentLight[i + 3].rgb;
        
        float luminance = dot(color, float3(0.2126, 0.7152, 0.0722));
        
        logLuminanceSum += log2(max(luminance, 1e-6)) * weight;
        totalWeight += weight;
    }

    float averageLogLuminance = logLuminanceSum / max(totalWeight, 1e-6);
    float brightness = exp2(averageLogLuminance);

    float desiredEv = log2(kDesiredBrightness / brightness);
    float targetEv = clamp(
        desiredEv, kMinExposureEv, kMaxExposureEv);
    float currentEv = bufferIncidentLight[1].r;
    float nextEv = lerp(currentEv, targetEv, autoExposureSpeed);
    float desiredExposure = exp2(desiredEv);
    float nextExposure = exp2(nextEv);

    bufferIncidentLight[0].rg = float2(nextExposure, desiredExposure);
    bufferIncidentLight[1].rg = float2(nextEv, desiredEv);
    bufferIncidentLight[2].rgb = 1;
}
