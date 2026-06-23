#include "Include/Generated/Signature.hlsl"

[numthreads(4, 4, 2)]
void IncidentLightMeterInline(
    uint3 dispatchThreadID : SV_DispatchThreadID,
    uint3 groupThreadID : SV_GroupThreadID,
    uint groupIndex : SV_GroupIndex, 
    uint3 groupID : SV_GroupID
    )
{
    uint threadsDispatchedX = g_rootConstant0 & 0xffff;
    uint threadsDispatchedY = g_rootConstant0 >> 16;
    uint2 launchDimensions = uint2(threadsDispatchedX, threadsDispatchedY);

    // 1D index of each thread (not counting Z)
    uint threadId = (threadsDispatchedX * dispatchThreadID.y) + dispatchThreadID.x;

    if (dispatchThreadID.z != 0)
        return;

    float2 recipLaunchDimensions = 1.0 / (float2)launchDimensions;
    uint2 samplingCoord = (uint2)((((float2)dispatchThreadID.xy) + 0.5) * recipLaunchDimensions * g_view.renderResolution);

    float weight = 1.0;

    // Use outputBufferFinal for the light measurement
    // In Vanilla RTX this buffer is available as SRV or UAV. Since we are computing after the primary ray,
    // we can read it to get the scene brightness.
    float3 incomingLight = outputBufferFinal[samplingCoord].rgb;

    int writeIndex = threadId + 3;
    bufferIncidentLight[writeIndex] = float4(incomingLight, weight);
}