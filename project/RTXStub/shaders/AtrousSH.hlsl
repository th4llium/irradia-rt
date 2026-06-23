#include "Include/Generated/Signature.hlsl"
#include "Include/DenoisingCommon.hlsl"

[numthreads(16, 8, 1)]
void AtrousSH(
    uint3 dispatchThreadID : SV_DispatchThreadID,
    uint3 groupThreadID : SV_GroupThreadID,
    uint groupIndex : SV_GroupIndex,
    uint3 groupID : SV_GroupID)
{
    int2 pixel = int2(dispatchThreadID.xy);
    if (any(pixel >= int2(g_view.renderResolution)))
        return;

    FilterAtrousPixel(pixel);
}
