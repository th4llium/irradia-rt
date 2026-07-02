#include "Include/Generated/Signature.hlsl"
#include "Include/CloudWorldPosition.hlsl"

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

    bufferIncidentLight[0].rg = float2(1.0, 1.0);
    bufferIncidentLight[1].rg = float2(0.0, 0.0);
    bufferIncidentLight[2].rgb = 1;
    StoreCloudCameraWorldOriginEstimate();
}
