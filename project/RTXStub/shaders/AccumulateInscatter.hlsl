#include "Include/Renderer.hlsl"

[numthreads(16, 16, 1)]
void AccumulateInscatter(
    uint3 dispatchThreadID : SV_DispatchThreadID,
    uint3 groupThreadID : SV_GroupThreadID,
    uint groupIndex : SV_GroupIndex, 
    uint3 groupID : SV_GroupID
    )
{
    if (any(dispatchThreadID.xy >= uint2(256, 128))) return;

    float3 accumulatedScattering = 0.0;
    float3 accumulatedTransmission = 1.0;

    for (uint z = 0; z < 64; z++) {
        uint3 froxelCoord = uint3(dispatchThreadID.x, dispatchThreadID.y, z);

        float2 ndc = float2(
            (dispatchThreadID.x + 0.5) / 256.0 * 2.0 - 1.0,
            1.0 - (dispatchThreadID.y + 0.5) / 128.0 * 2.0
        );
        float3 rayDir = rayDirFromNDC(ndc);
        float zSlice = ((float)z + 0.5) / 64.0;
        float maxDist = GetVolumetricFogMaxDistance();
        float depth = zSlice * zSlice * maxDist;
        float3 pos = g_view.viewOriginSteveSpace + rayDir * depth;
        float4 prevClip = mul(g_view.prevViewProj, float4(pos, 1.0));
        float2 prevNdc = prevClip.xy / prevClip.w;
        float prevDepth = length(pos - g_view.previousViewOriginSteveSpace);
        float prevZSlice = sqrt(prevDepth / maxDist);

        float3 prevUvw = float3(
            prevNdc.x * 0.5 + 0.5,
            0.5 - prevNdc.y * 0.5,
            prevZSlice
        );

        float4 current = volumetricInscatterRW[froxelCoord];
        float4 previous = 0.0;

        float temporalAlpha = 0.08;
        if (g_view.previousVolumetricsAreValid == 0
            || g_view.numFramesSinceTeleport == 0
            || any(prevUvw < 0.0) || any(prevUvw > 1.0))
        {
            temporalAlpha = 1.0;
        } else {
            previous = volumetricInscatterPrevious.SampleLevel(linearSampler, prevUvw, 0);
            float disagreement =
                abs(previous.a - current.a)
                + getLuminance(abs(previous.rgb - current.rgb)) * 0.25;
            temporalAlpha = max(
                temporalAlpha,
                smoothstep(0.02, 0.24, disagreement));
        }

        float4 blended = lerp(previous, current, temporalAlpha);
        volumetricInscatterRW[froxelCoord] = blended;

        float3 stepScattering = max(blended.rgb, 0.0);
        float stepExtinction = max(blended.a, 0.0);

        float stepPrevZSlice = ((float)max(0, (int)z - 1) + 0.5) / 64.0;
        float stepPrevDepth = stepPrevZSlice * stepPrevZSlice * maxDist;
        if (z == 0) stepPrevDepth = 0.0;
        float stepSize = depth - stepPrevDepth;

        float3 transmission;
        float3 integratedScattering = 0.0;
        if (stepExtinction > 0.00001) {
            float transmittance = exp(-stepExtinction * stepSize);
            transmission = transmittance.xxx;
            integratedScattering =
                stepScattering
                * (1.0 - transmittance)
                / stepExtinction;
        } else {
            transmission = 1.0;
            integratedScattering = stepScattering * stepSize;
        }

        accumulatedScattering += accumulatedTransmission * integratedScattering;
        accumulatedTransmission *= transmission;

        volumetricResolvedInscatterRW[froxelCoord] = accumulatedScattering;
        volumetricResolvedTransmissionRW[froxelCoord] = accumulatedTransmission;
    }
}
