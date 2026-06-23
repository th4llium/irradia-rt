#include "Include/Generated/Signature.hlsl"
#include "Include/DenoisingCommon.hlsl"

[numthreads(16, 16, 1)]
void DiffuseFireflyFilter(
    uint3 dispatchThreadID : SV_DispatchThreadID,
    uint3 groupThreadID : SV_GroupThreadID,
    uint groupIndex : SV_GroupIndex, 
    uint3 groupID : SV_GroupID
    )
{
    int2 pixel = int2(dispatchThreadID.xy);
    if (any(pixel >= int2(g_view.renderResolution)))
        return;

    uint inputIndex = g_rootConstant0 & 0xff;
    uint outputIndex = (g_rootConstant0 >> 8) & 0xff;
    uint paramsIndex = (g_rootConstant0 >> 24) % 2;
    float relativeEpsilon = max(
        g_view.denoisingParams[paramsIndex]
            .despeckleFilterRelativeDifferenceEpsilon,
        0.1);

    denoisingOutputs[outputIndex][pixel] = ClampFirefly(
        denoisingInputs[inputIndex],
        pixel,
        false,
        4.0,
        relativeEpsilon);
}
